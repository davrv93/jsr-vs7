"""RAG sobre la base de conocimiento (artículos de soporte) con embeddings e5 y un bandido de Thompson en sombra.

- Los artículos llegan de seed/articulos.json al arrancar y de `POST /conocimiento/recargar` (el backend manda los
  que están publicados). Todo vive en memoria: el agente no guarda estado propio (CONTRATOS §1).
- Índice: cada artículo se indexa dos veces como «passage: »: la ficha (título + síntomas, lo que la persona describe)
  y el cuerpo (pasos). El parecido de un artículo es el mayor de los dos; un acierto en la ficha pesa algo más.
- Dos umbrales, medidos sobre los 20 artículos de ejemplo (ver LEEME.md; con otros artículos hay que volver a medirlos):
  · `UMBRAL_MINIMO` (0,845): por debajo no hay artículo.
  · `UMBRAL_SUFICIENTE` (0,875): desde aquí el artículo basta para guiar sin hacer más preguntas.
  El parecido de e5 es muy comprimido (lo relevante cae entre 0,83 y 0,95): por eso se suma un empujón de categoría y se afinan estos valores.
- Bandido (ARQUITECTURA §7.3): cada artículo lleva su tasa de éxito por categoría, Beta(éxitos+1, fracasos+1). El orden
  alternativo es parecido × muestra de Thompson. **Modo sombra por defecto**: se calcula y se registra, pero el orden que
  se usa es el del parecido puro. `BANDIDO_MODO=activo` lo enciende; hay que tener una cifra que lo justifique
  (AGENTS.md §1.4, regla 6).
"""
from __future__ import annotations

import json
import os
import random
import re
import threading

import numpy as np

from . import datos

UMBRAL_MINIMO = float(os.environ.get("RAG_UMBRAL_MINIMO", "0.845"))
UMBRAL_SUFICIENTE = float(os.environ.get("RAG_UMBRAL_SUFICIENTE", "0.875"))
BANDIDO_MODO = os.environ.get("BANDIDO_MODO", "sombra").strip().lower()    # sombra | activo | apagado
SEED = os.environ.get("SEED_ARTICULOS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "seed", "articulos.json"))
BONO_CATEGORIA = 0.015     # empuja a los artículos de la categoría que ya se sabe…
PENAL_CATEGORIA = 0.025    # …y aparta a los de otra categoría (un artículo de impresoras no sirve a quien dice que falla Word)

RE_PASO = re.compile(r"^\s*(?:\d+[.)]|[-*•])\s+(.*\S)\s*$")


def _lista(v) -> list[str]:
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    if isinstance(v, str):
        return [x.strip() for x in re.split(r"[\n;]+", v) if x.strip()]
    return []


def normalizar(a: dict) -> dict | None:
    """Un artículo del backend o del seed, con la forma que usa el agente. None si no sirve (sin clave o sin título)."""
    if not isinstance(a, dict) or not str(a.get("clave") or "").strip() or not str(a.get("titulo") or "").strip():
        return None
    cuerpo = str(a.get("cuerpo") or "")
    pasos = _lista(a.get("pasos"))
    if not pasos and cuerpo:   # el backend puede mandar solo el cuerpo en Markdown con pasos numerados
        sec = cuerpo.split("## Pasos", 1)[-1].split("\n## ", 1)[0] if "## Pasos" in cuerpo else cuerpo
        pasos = [m.group(1) for ln in sec.splitlines() if (m := RE_PASO.match(ln)) and re.match(r"^\s*\d+[.)]", ln)]
    cat = str(a.get("categoria") or "otro").strip()
    usos = a.get("usos") if isinstance(a.get("usos"), dict) else {}
    return {"clave": str(a["clave"]).strip(), "titulo": str(a["titulo"]).strip(), "categoria": cat if cat in datos.CATEGORIAS else "otro",
            "sintomas": _lista(a.get("sintomas")), "pasos": pasos[:12], "cuerpo": cuerpo, "escalar": str(a.get("escalar") or ""),
            "supuesto": str(a.get("supuesto") or ""), "usos": usos}


def _texto_ficha(a: dict) -> str:
    return f"{a['titulo']}. Síntomas: " + "; ".join(a["sintomas"])


def _texto_cuerpo(a: dict) -> str:
    return f"{a['titulo']}. " + " ".join(a["pasos"])


class Conocimiento:
    def __init__(self, emb):
        self.emb = emb
        self.lock = threading.Lock()
        self.articulos: list[dict] = []
        self.Xf = np.zeros((0, 384), dtype=np.float32)
        self.Xc = np.zeros((0, 384), dtype=np.float32)
        self.por_clave: dict[str, int] = {}
        self.stats: dict[str, list[int]] = {}      # «clave|categoria» -> [éxitos, fracasos]
        self.rng = random.Random()

    # --- carga -------------------------------------------------------------------------------------------
    def cargar(self, articulos: list[dict]) -> int:
        """Reemplaza los artículos y los indexa. Devuelve cuántos quedaron. Los de forma inválida se descartan."""
        lista = [x for x in (normalizar(a) for a in (articulos or [])) if x]
        vistos, unicos = set(), []
        for a in lista:
            if a["clave"] not in vistos:
                vistos.add(a["clave"])
                unicos.append(a)
        Xf = self.emb.pasajes([_texto_ficha(a) for a in unicos]) if unicos else np.zeros((0, 384), dtype=np.float32)
        Xc = self.emb.pasajes([_texto_cuerpo(a) for a in unicos]) if unicos else np.zeros((0, 384), dtype=np.float32)
        with self.lock:
            self.articulos, self.Xf, self.Xc = unicos, Xf, Xc
            self.por_clave = {a["clave"]: k for k, a in enumerate(unicos)}
            for a in unicos:   # los usos que manda el backend son la fuente de verdad
                for cat, par in (a["usos"] or {}).items():
                    if isinstance(par, (list, tuple)) and len(par) == 2:
                        self.stats[f"{a['clave']}|{cat}"] = [int(par[0]), int(par[1])]
                    elif isinstance(par, dict):
                        self.stats[f"{a['clave']}|{cat}"] = [int(par.get("exitos", 0)), int(par.get("fracasos", 0))]
        return len(unicos)

    def cargar_seed(self, ruta: str = SEED) -> int:
        try:
            with open(ruta, encoding="utf-8") as f:
                return self.cargar(json.load(f))
        except (OSError, ValueError):
            return 0

    def seed_articulos(self, ruta: str = SEED) -> list[dict]:
        """Los artículos del archivo seed, normalizados (sin indexar ni tocar los cargados)."""
        try:
            with open(ruta, encoding="utf-8") as f:
                return [a for a in (normalizar(x) for x in json.load(f)) if a]
        except (OSError, ValueError, TypeError):
            return []

    def articulo(self, clave: str) -> dict | None:
        k = self.por_clave.get(clave)
        return self.articulos[k] if k is not None else None

    # --- búsqueda ----------------------------------------------------------------------------------------
    def parecidos(self, consulta: str) -> np.ndarray:
        """Parecido (coseno) de la consulta con cada artículo: el mayor entre su ficha y su cuerpo."""
        with self.lock:
            if not self.articulos:
                return np.zeros(0, dtype=np.float32)
            q = self.emb([consulta])[0]
            return np.maximum(self.Xf @ q, 0.985 * (self.Xc @ q))

    def muestra(self, clave: str, categoria: str) -> float:
        e, f = self.stats.get(f"{clave}|{categoria}", [0, 0])
        return self.rng.betavariate(e + 1, f + 1)

    def registrar_uso(self, clave: str, categoria: str, exito: bool) -> None:
        """Cuenta un éxito («ya funcionó») o un fracaso («sigue igual») del artículo para esa categoría. Es solo en
        memoria: la fuente de verdad es `articulo_usos` del backend, que los manda al recargar."""
        par = self.stats.setdefault(f"{clave}|{categoria}", [0, 0])
        par[0 if exito else 1] += 1

    def buscar(self, consulta: str, k: int = 3, categoria: str | None = None, excluir=()) -> dict:
        """Los `k` artículos más parecidos. Devuelve:
        {"resultados": [{clave, titulo, categoria, score, ...}], "suficiente": bool, "orden_puro": [...],
         "orden_bandido": [...], "modo_bandido": str}
        `score` es el parecido (con el pequeño empuje de categoría). Con BANDIDO_MODO=activo el orden de `resultados`
        es el del bandido; en sombra (por defecto) es el del parecido puro y el alternativo solo se informa."""
        sims = self.parecidos(consulta)
        if not len(sims):
            return {"resultados": [], "suficiente": False, "orden_puro": [], "orden_bandido": [], "modo_bandido": BANDIDO_MODO}
        puntos = []
        for i, a in enumerate(self.articulos):
            if a["clave"] in excluir:
                continue
            s = float(sims[i])
            if categoria and categoria != "otro":
                s += BONO_CATEGORIA if a["categoria"] == categoria else -PENAL_CATEGORIA
            puntos.append((s, a))
        puntos.sort(key=lambda t: -t[0])
        top = [(s, a) for s, a in puntos if s >= UMBRAL_MINIMO][: max(k, 1) + 2]
        puro = [a["clave"] for s, a in top[:k]]
        cat_caso = categoria or (top[0][1]["categoria"] if top else "otro")
        bandido = sorted(top, key=lambda t: -(t[0] * self.muestra(t[1]["clave"], cat_caso)))
        orden_b = [a["clave"] for s, a in bandido[:k]]
        elegidos = bandido[:k] if BANDIDO_MODO == "activo" else top[:k]
        res = [{"clave": a["clave"], "titulo": a["titulo"], "categoria": a["categoria"], "score": round(s, 4),
                "pasos": list(a["pasos"]), "escalar": a["escalar"], "sintomas": list(a["sintomas"])} for s, a in elegidos]
        return {"resultados": res, "suficiente": bool(res and res[0]["score"] >= UMBRAL_SUFICIENTE), "orden_puro": puro,
                "orden_bandido": orden_b, "modo_bandido": BANDIDO_MODO}

    def parecido_textos(self, a: str, b: str) -> float:
        """Coseno entre dos textos cortos (por ejemplo, el síntoma nuevo y el título de una incidencia abierta)."""
        v = self.emb([a, b])
        return float(v[0] @ v[1])
