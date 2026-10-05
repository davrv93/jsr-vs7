"""Mide Jev local contra el CONJUNTO DORADO (juez/dorado/*.jsonl, sintético: lo escribió una sola persona, ver su README).

    python -m app.evaluar_juez                                        # clasificador local + verificador (sin juez ni NLI)
    python -m app.evaluar_juez --nli                                  # además el backend NLI (necesita modelos/nli; ver LEEME.md)
    python -m app.evaluar_juez --juez-url http://127.0.0.1:8080       # además la cascada contra un llama-server (o cualquier servidor compatible con OpenAI)
    python -m app.evaluar_juez --juez-url http://localhost:11434 --juez-modelo qwen2.5:3b   # p. ej. Ollama, como sustituto

Qué imprime (ARQUITECTURA §6, «Medición»):
- **Clasificación** sobre `clasificacion.jsonl` (turnos CON contexto: respuestas cortas a una pregunta pendiente, seguimientos…): exactitud, macro-F1 y ECE del
  clasificador local solo, del local + las reglas de lenguaje (lo que de verdad hace el agente), del juez (si hay URL) y de la cascada; la curva
  cobertura/precisión y cuántos errores arregla (y cuántos aciertos rompe) la cascada.
- **Grounding** sobre `grounding.jsonl` (pares respuesta-fuente con CADA frase marcada, con alucinaciones plausibles): recall y precisión de alucinaciones,
  tasa de falsos positivos, AUROC, recall por tipo de alucinación. Los umbrales se calibran con la mitad `cal` y se informa sobre la mitad `test`, que no
  entró a la calibración. Con `--nli`, lo mismo para el backend NLI.
- **¿Contestó?**: exactitud con el umbral por defecto, sobre los pares del dorado y sobre pares desordenados (pregunta de un tema, respuesta de otro).
- **Latencias**: p50 y p95 de cada pieza, medidas en ESTA máquina (no son las del servidor de referencia).

Cifras honestas: si el recall de alucinaciones sale por debajo de 0,9, el informe lo dice.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import defaultdict

import numpy as np

os.environ.setdefault("LOG_LEVEL", "WARNING")

from . import conocimiento, etapas, juez, medidas, memoria, modelo
from . import verificar as V

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DORADO = os.environ.get("JUEZ_DORADO_DIR", os.path.join(REPO, "juez", "dorado"))


def jsonl(nombre: str) -> list[dict]:
    with open(os.path.join(DORADO, nombre), encoding="utf-8") as f:
        return [json.loads(ln) for ln in f if ln.strip()]


def fila(nombre: str, d: dict) -> str:
    return f"  {nombre:<34s} exactitud {d['exactitud']:.3f}   macro-F1 {d['f1']:.3f}   ECE {d['ece']:.3f}"


# --- clasificación ----------------------------------------------------------------------------------------------------------
def _contexto(t: dict) -> tuple[dict, list]:
    """La memoria y las incidencias abiertas que corresponden al contexto del turno del dorado."""
    mem = memoria.nueva()
    mem["etapa"], mem["pendiente"] = t["etapa"], t["pendiente"]
    if t["etapa"] == "guia":
        mem.update(articulos_mostrados=["KB-001"], intentos_guia=1, categoria="correo")
        mem["sabemos"]["sintoma"] = "no me abre el correo"
    if t["etapa"] == "diagnostico":
        mem["categoria"] = "correo"
        mem["sabemos"]["sintoma"] = "no me abre el correo"
    abiertas = [{"numero": "INC-000142", "estado": "en_curso", "titulo": "Outlook no recibe correos", "categoria": "correo"}] if t["etapa"] == "seguimiento" else []
    return mem, abiertas


def evaluar_clasificacion(emb, args) -> dict:
    turnos = jsonl("clasificacion.jsonl")
    ci = modelo.cargar("intencion.pkl")
    X = emb([t["mensaje"] for t in turnos])
    P = ci.predict_proba(X)
    esp = [t["intencion"] for t in turnos]
    loc = [str(ci.classes_[int(np.argmax(p))]) for p in P]
    conf_loc = [float(p.max()) for p in P]
    reg, conf_reg = [], []
    for t, p, c in zip(turnos, loc, conf_loc):
        mem, abiertas = _contexto(t)
        tmp = memoria.copia(mem)
        resp = memoria.leer(tmp, t["mensaje"])["respondio"]
        i, cf = etapas.intencion_efectiva(t["etapa"], p, c, t["mensaje"], pendiente=t["pendiente"], respondio_pendiente=resp, mem=mem, abiertas=abiertas)
        reg.append(i)
        conf_reg.append(cf)
    res = {"n": len(turnos), "local": None, "reglas": None, "juez": None, "cascada": None}
    def paquete(pred, conf):
        ok = [a == b for a, b in zip(esp, pred)]
        return {"exactitud": medidas.exactitud(esp, pred), "f1": medidas.macro_f1(esp, pred), "ece": medidas.ece(conf, ok), "pred": pred, "conf": conf}
    res["local"], res["reglas"] = paquete(loc, conf_loc), paquete(reg, conf_reg)
    lat_local = []
    for m in [t["mensaje"] for t in turnos][:40]:
        t0 = time.perf_counter(); emb([m]); lat_local.append(time.perf_counter() - t0)
    res["lat_local"] = lat_local
    if args.juez_url:
        juez.configurar(url=args.juez_url, modo="activo", timeout=args.juez_timeout)
        juez.MODELO = args.juez_modelo or juez.MODELO
        jp, jc, lat, vacios = [], [], [], 0
        for t in turnos:
            mem, _ = _contexto(t)
            est = juez.estado(t["mensaje"], t["historial"], t["etapa"], t["pendiente"], memoria.lo_que_sabemos(mem), mem.get("categoria", ""))
            t0 = time.perf_counter()
            j = juez.clasificar(est)
            lat.append(time.perf_counter() - t0)
            if j is None:
                vacios += 1
                jp.append("fuera_de_alcance"); jc.append(0.0)
            else:
                jp.append(j["intent"]); jc.append(j["confianza"])
        res["juez"] = paquete(jp, jc) | {"vacios": vacios, "lat": lat}
        # cascada sobre lo que de verdad hace el agente (local + reglas): si duda, se usa al juez cuando está más seguro
        cp, cc, consultas = [], [], 0
        for pr, cr, pj, cj in zip(reg, conf_reg, jp, jc):
            if cr < args.juez_umbral:
                consultas += 1
                if cj >= cr:
                    cp.append(pj); cc.append(cj); continue
            cp.append(pr); cc.append(cr)
        res["cascada"] = paquete(cp, cc) | {"consultas": consultas, "umbral": args.juez_umbral}
        arregla = sum(1 for e, r, c in zip(esp, reg, cp) if r != e and c == e)
        rompe = sum(1 for e, r, c in zip(esp, reg, cp) if r == e and c != e)
        res["cascada"] |= {"arregla": arregla, "rompe": rompe}
        # curva de umbrales de la cascada
        curva = []
        for u in (0.5, 0.6, 0.7, 0.8, 0.9):
            pp = [pj if (cr < u and cj >= cr) else pr for pr, cr, pj, cj in zip(reg, conf_reg, jp, jc)]
            curva.append((u, sum(1 for cr in conf_reg if cr < u) / len(turnos), medidas.exactitud(esp, pp), medidas.macro_f1(esp, pp)))
        res["curva_cascada"] = curva
    return res


# --- grounding -----------------------------------------------------------------------------------------------------------------
def _puntajes(v: dict, usar_nli: bool) -> float:
    """Puntaje continuo de «esta frase está inventada» para el AUROC (0 = no afirma nada)."""
    if not v["afirma"] and not v["datos_sin_respaldo"]:
        return 0.0
    base = (1.0 - v["nli"][0]) if (usar_nli and v["nli"]) else (1.0 - v["sim"])
    return base + (1.0 if v["datos_sin_respaldo"] else 0.0)


def _marca(vs: list[dict], etiquetas: list[bool], tau_sim: float, tau_nli: float, usar_nli: bool) -> dict:
    flag = [bool(V.motivo_de(v["datos_sin_respaldo"], v["afirma"], v["nli"] if usar_nli else None, v["sim"], tau_sim, tau_nli)) for v in vs]
    tp = sum(1 for f, e in zip(flag, etiquetas) if f and e)
    fp = sum(1 for f, e in zip(flag, etiquetas) if f and not e)
    fn = sum(1 for f, e in zip(flag, etiquetas) if not f and e)
    tn = sum(1 for f, e in zip(flag, etiquetas) if not f and not e)
    rec = tp / (tp + fn) if tp + fn else float("nan")
    pre = tp / (tp + fp) if tp + fp else float("nan")
    return {"recall": rec, "precision": pre, "f1": (2 * pre * rec / (pre + rec)) if pre + rec else 0.0, "fpr": fp / (fp + tn) if fp + tn else 0.0, "tp": tp, "fp": fp, "fn": fn, "tn": tn, "flag": flag}


def evaluar_grounding(emb, args) -> dict:
    pares = jsonl("grounding.jsonl")
    arts = {a["clave"]: conocimiento.normalizar(a) for a in json.load(open(conocimiento.SEED, encoding="utf-8"))}
    ver = V.Verificador(emb, nli=V.NLI() if args.nli else None)
    nli_ok = bool(args.nli and ver.nli.disponible())
    filas, lat = [], []
    for p in pares:
        textos = [f["texto"] for f in p["frases"]]
        t0 = time.perf_counter()
        vs = ver.puntuar(textos, [arts[p["articulo"]]["cuerpo"]], [p["pregunta"]])
        lat.append(time.perf_counter() - t0)
        for v, f in zip(vs, p["frases"]):
            filas.append(v | {"alucinacion": f["alucinacion"], "tipo_h": f["tipo"], "split": p["split"], "par": p["id"]})
    res = {"n_pares": len(pares), "n_frases": len(filas), "n_alucinaciones": sum(1 for f in filas if f["alucinacion"]), "lat": lat, "nli": nli_ok, "backends": {}}
    for backend, usar in (("local", False),) + ((("local+NLI", True),) if nli_ok else ()):
        cal = [f for f in filas if f["split"] == "cal"]
        test = [f for f in filas if f["split"] == "test"]
        def medir(sub, ts, tn):
            return _marca(sub, [f["alucinacion"] for f in sub], ts, tn, usar)
        # calibración: de los umbrales de la malla, el de mejor F1 entre los que alcanzan recall ≥ 0,9 en `cal` (si ninguno, el de mayor recall)
        malla = [(ts, tn) for ts in (np.arange(0.78, 0.97, 0.01) if not usar else [V.TAU_SIM]) for tn in ((np.arange(0.05, 0.96, 0.05)) if usar else [V.TAU_NLI])]
        cand = []
        for ts, tn in malla:
            m = medir(cal, float(ts), float(tn))
            cand.append((m["recall"] >= 0.9, m["f1"] if m["recall"] >= 0.9 else m["recall"], float(ts), float(tn)))
        cand.sort(key=lambda c: (c[0], c[1]), reverse=True)
        _, _, ts_c, tn_c = cand[0]
        por_tipo = defaultdict(lambda: [0, 0])
        mt = medir(test, ts_c, tn_c)
        for f, fl in zip(test, mt["flag"]):
            if f["alucinacion"]:
                por_tipo[f["tipo_h"]][1] += 1
                por_tipo[f["tipo_h"]][0] += int(fl)
        todos = medir(filas, ts_c, tn_c)
        defecto = medir(filas, V.TAU_SIM, V.TAU_NLI)
        auc = medidas.auroc([_puntajes(f, usar) for f in filas], [f["alucinacion"] for f in filas])
        res["backends"][backend] = {"tau_sim": ts_c, "tau_nli": tn_c, "defecto": defecto, "calibrado_cal": medir(cal, ts_c, tn_c), "calibrado_test": mt, "todos": todos, "auroc": auc,
                                    "por_tipo_test": {k: tuple(v) for k, v in por_tipo.items()}, "filas": filas}
    if nli_ok:
        t = []
        for v in filas[:60]:
            if v["afirma"]:
                t0 = time.perf_counter(); ver.nli.probs("Abre Excel en modo seguro: pulsa Windows + R, escribe excel /safe y pulsa Enter.", v["texto"]); t.append(time.perf_counter() - t0)
        res["lat_nli_par"] = t
    # ¿contestó? : pares del dorado y pares desordenados
    ok_pos = [ver.contesta(p["pregunta"], p["respuesta"]) for p in pares]
    verdad = [p["contesta"] for p in pares]
    desordenados = []
    for i, p in enumerate(pares):
        q = pares[(i + 17) % len(pares)]
        if q["articulo"] != p["articulo"]:
            desordenados.append(ver.contesta(p["pregunta"], q["respuesta"]))
    auc_c = medidas.auroc([-s for s in ok_pos + desordenados], [False] * len(ok_pos) + [True] * len(desordenados))   # ¿separa lo correcto de lo desordenado?
    res["contesta"] = {"auroc_desordenados": auc_c, "tau": V.TAU_CONTESTA, "dorado": sum((s >= V.TAU_CONTESTA) == v for s, v in zip(ok_pos, verdad)) / len(pares),
                       "dorado_negativos": sum(1 for s, v in zip(ok_pos, verdad) if not v and s < V.TAU_CONTESTA), "n_negativos": sum(1 for v in verdad if not v),
                       "desordenados": sum(1 for s in desordenados if s < V.TAU_CONTESTA) / max(len(desordenados), 1), "n_desordenados": len(desordenados),
                       "aciertos_positivos": sum(1 for s, v in zip(ok_pos, verdad) if v and s >= V.TAU_CONTESTA) / max(sum(verdad), 1)}
    return res


# --- informe -------------------------------------------------------------------------------------------------------------------
def p(vals, q):
    return f"{medidas.percentil(vals, q) * 1000:.0f} ms"


def informe(cl: dict | None, gr: dict | None, args) -> int:
    print(f"CONJUNTO DORADO: {DORADO}  (sintético: ver juez/dorado/README.md)\n")
    avisos = []
    if cl:
        print(f"== Clasificación con contexto ({cl['n']} turnos)")
        print(fila("local solo (e5 + regresión)", cl["local"]))
        print(fila("local + reglas de lenguaje (el agente)", cl["reglas"]))
        if cl["juez"]:
            print(fila(f"juez solo ({args.juez_modelo or juez.MODELO})", cl["juez"]) + f"   sin respuesta: {cl['juez']['vacios']}")
            c = cl["cascada"]
            print(fila(f"cascada (umbral {c['umbral']})", c) + f"   consultó al juez en {c['consultas']}/{cl['n']} turnos · arregla {c['arregla']} errores y rompe {c['rompe']} aciertos")
            print("  curva de la cascada (umbral · % de turnos que consulta · exactitud · macro-F1):")
            for u, cov, ex, f1 in cl["curva_cascada"]:
                print(f"     {u:.1f} · {cov * 100:4.0f} % · {ex:.3f} · {f1:.3f}")
            print(f"  latencia del juez: p50 {p(cl['juez']['lat'], 50)}, p95 {p(cl['juez']['lat'], 95)}  (en esta máquina, con {args.juez_modelo or juez.MODELO}; NO es el servidor de referencia)")
        else:
            print("  (sin --juez-url: no se midió el juez ni la cascada; no hay llama-server en esta ejecución)")
        print(f"  latencia del clasificador local: p50 {p(cl['lat_local'], 50)}, p95 {p(cl['lat_local'], 95)}")
        errs = [(t, a, b) for t, a, b in zip(jsonl('clasificacion.jsonl'), cl["reglas"]["pred"], [t["intencion"] for t in jsonl('clasificacion.jsonl')]) if a != b]
        if errs:
            print("  errores del agente (local + reglas):")
            for t, a, b in errs[:12]:
                print(f"     «{t['mensaje']}» [{t['pendiente'] or t['etapa']}] → {a} (esperado {b})")
        print()
    if gr:
        print(f"== Grounding por frase ({gr['n_pares']} pares, {gr['n_frases']} frases, {gr['n_alucinaciones']} alucinaciones)  · mitad `cal` para calibrar, mitad `test` para informar")
        for nombre, b in gr["backends"].items():
            d, t, a = b["defecto"], b["calibrado_test"], b["todos"]
            def lin(m):
                return f"recall {m['recall']:.3f}  precisión {m['precision']:.3f}  F1 {m['f1']:.3f}  falsos positivos {m['fpr'] * 100:.1f} % (TP {m['tp']} FP {m['fp']} FN {m['fn']} TN {m['tn']})"
            print(f"  [{nombre}] umbrales por defecto (τ_sim {V.TAU_SIM}{', τ_NLI ' + str(V.TAU_NLI) if nombre != 'local' else ''}), todo el dorado:\n      {lin(d)}")
            print(f"  [{nombre}] calibrado en `cal` (τ_sim {b['tau_sim']:.2f}{', τ_NLI ' + format(b['tau_nli'], '.2f') if nombre != 'local' else ''}), informado en `test`:\n      {lin(t)}")
            print(f"  [{nombre}] AUROC {b['auroc']:.3f}")
            tipos = ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(b["por_tipo_test"].items()))
            print(f"  [{nombre}] recall por tipo de alucinación en `test`: {tipos}")
            if t["recall"] < 0.9:
                avisos.append(f"[{nombre}] el recall de alucinaciones en `test` es {t['recall']:.3f}: MENOS de 0,9. No cumple la salida de F4 (recall ≥ 0,9 con precisión ≥ 0,7).")
            elif t["precision"] < 0.7:
                avisos.append(f"[{nombre}] la precisión en `test` es {t['precision']:.3f}: menos de 0,7.")
        print(f"  latencia de verificar un par (≈3 frases): p50 {p(gr['lat'], 50)}, p95 {p(gr['lat'], 95)}" + (f" · un par NLI: p50 {p(gr['lat_nli_par'], 50)}, p95 {p(gr['lat_nli_par'], 95)}" if gr.get("lat_nli_par") else ""))
        c = gr["contesta"]
        print(f"== ¿Contestó? (cobertura + embeddings, τ {c['tau']}): respuestas correctas aprobadas {c['aciertos_positivos'] * 100:.0f} %; respuestas que no contestan detectadas: "
              f"dorado {c['dorado_negativos']}/{c['n_negativos']}, desordenadas (otro tema) {c['desordenados'] * 100:.0f} % de {c['n_desordenados']}; AUROC contra las desordenadas {c['auroc_desordenados']:.2f} (separación débil: un cross-encoder o el juez la mejorarían)")
        print()
    for a in avisos:
        print("AVISO:", a)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--solo", default="clasificacion,grounding")
    ap.add_argument("--nli", action="store_true", help="medir también el backend NLI (necesita modelos/nli)")
    ap.add_argument("--juez-url", default=os.environ.get("JUEZ_URL", ""), help="llama-server (o servidor compatible con OpenAI) para medir el juez y la cascada")
    ap.add_argument("--juez-modelo", default="")
    ap.add_argument("--juez-umbral", type=float, default=juez.UMBRAL)
    ap.add_argument("--juez-timeout", type=float, default=30.0)
    ap.add_argument("--json", default="", help="guarda las cifras en este archivo")
    a = ap.parse_args(argv)
    solo = {x.strip() for x in a.solo.split(",")}
    emb = modelo.Embedder()
    cl = evaluar_clasificacion(emb, a) if "clasificacion" in solo else None
    gr = evaluar_grounding(emb, a) if "grounding" in solo else None
    rc = informe(cl, gr, a)
    if a.json:
        def limpio(o):
            if isinstance(o, dict):
                return {k: limpio(v) for k, v in o.items() if k not in ("filas", "pred", "conf", "flag", "lat", "lat_local", "lat_nli_par")}
            if isinstance(o, (list, tuple)):
                return [limpio(x) for x in o]
            if isinstance(o, (np.floating, np.integer)):
                return o.item()
            return o
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(limpio({"clasificacion": cl, "grounding": gr}), f, ensure_ascii=False, indent=1)
    return rc


if __name__ == "__main__":
    sys.exit(main())
