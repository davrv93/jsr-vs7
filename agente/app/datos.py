"""Carga de los conjuntos de datos de jsrbot (sintéticos, ver data/README.md) y vocabulario cerrado.

Todo lo que entrena o consulta el agente sale de aquí, para que lo que se entrena en el build
(entrenar.py) y lo que sirve el servidor (main.py) lean lo mismo.

Vocabulario cerrado: docs/CONTRATOS.md §3. Si cambia allí, cambia aquí.
"""
from __future__ import annotations

import csv
import os
import re
import unicodedata
from dataclasses import dataclass

DATA_DIR = os.environ.get("AGENTE_DATA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data"))

INTENCIONES = ("reportar_falla", "solicitar_acceso", "solicitar_equipo", "restablecer_clave", "consultar_estado",
               "aportar_dato", "confirmar_solucion", "sigue_igual", "pedir_tecnico", "queja", "agradecer", "saludo",
               "fuera_de_alcance")
# SUPUESTO: categorías iniciales (ARQUITECTURA §4) hasta conocer la organización.
CATEGORIAS = ("correo", "cuentas_accesos", "red_wifi", "vpn", "impresoras", "equipo", "software_oficina",
              "sistema_interno", "telefonia", "otro")
ETAPAS = ("recepcion", "diagnostico", "guia", "incidencia", "seguimiento", "cierre", "encuesta", "consulta_estado")
TIPOS_ACCION = ("ninguna", "crear_incidencia", "agregar_dato", "consultar_estado", "pedir_tecnico",
                "confirmar_solucion", "sigue_igual", "encuesta")
IMPACTOS = ("persona", "area", "sede", "organizacion")
URGENCIAS = ("baja", "media", "alta", "critica")
TIPOS_INCIDENCIA = ("incidente", "solicitud", "consulta", "problema")
MOTIVOS = ("guia_agotada", "p1", "pidio_tecnico", "sin_articulo")

# Intenciones que describen algo que le pasa a la persona (tiene sentido preguntar la categoría y buscar un artículo).
INTENCIONES_CASO = {"reportar_falla", "solicitar_acceso", "solicitar_equipo", "restablecer_clave"}


def plano(s: str) -> str:
    """Minúsculas y sin tildes: la forma en que se comparan textos en todo el agente."""
    s = unicodedata.normalize("NFD", (s or "").lower())
    return "".join(c for c in s if unicodedata.category(c) != "Mn").strip()


def _csv(nombre: str) -> list[dict]:
    with open(os.path.join(DATA_DIR, nombre), encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


@dataclass
class Ejemplo:
    texto: str
    etiqueta: str
    variante: str = ""
    grupo: str = ""


def ejemplos_intencion() -> list[Ejemplo]:
    """Frases etiquetadas con la intención (data/intenciones_soporte.csv, en tríos)."""
    out = []
    for r in _csv("intenciones_soporte.csv"):
        out.append(Ejemplo(r["mensaje"].strip(), r["intencion"].strip(), r.get("variante", "").strip(), r.get("grupo_id", "").strip()))
    extra = os.path.join(DATA_DIR, "extra_revisados.csv")   # lo confirmado por la cola de revisión (F8), si existe
    if os.path.exists(extra):
        for k, r in enumerate(_csv("extra_revisados.csv")):
            if r.get("intencion", "").strip() in INTENCIONES and r.get("mensaje", "").strip():
                out.append(Ejemplo(r["mensaje"].strip(), r["intencion"].strip(), "revisado", f"R{k:04d}"))
    return out


def ejemplos_categoria() -> list[Ejemplo]:
    """Frases etiquetadas con la categoría (data/categorias.csv, en tríos)."""
    out = [Ejemplo(r["mensaje"].strip(), r["categoria"].strip(), r.get("variante", "").strip(), r.get("grupo_id", "").strip())
           for r in _csv("categorias.csv")]
    extra = os.path.join(DATA_DIR, "extra_revisados.csv")
    if os.path.exists(extra):
        for k, r in enumerate(_csv("extra_revisados.csv")):
            if r.get("categoria", "").strip() in CATEGORIAS and r.get("mensaje", "").strip():
                out.append(Ejemplo(r["mensaje"].strip(), r["categoria"].strip(), "revisado", f"RC{k:04d}"))
    return out


def prueba() -> list[dict]:
    """El conjunto RESERVADO (data/prueba_soporte.csv): no entra al entrenamiento. Mide intención y categoría."""
    return [{"mensaje": r["mensaje"].strip(), "intencion": r["intencion"].strip(), "categoria": r.get("categoria", "").strip()}
            for r in _csv("prueba_soporte.csv")]


def solapes() -> list[str]:
    """Frases del reservado que están (casi) copiadas en el entrenamiento: tiene que salir vacío."""
    norm = lambda t: re.sub(r"[^\w ]", "", plano(t))
    vistas = {norm(e.texto) for e in ejemplos_intencion() + ejemplos_categoria()}
    return [p["mensaje"] for p in prueba() if norm(p["mensaje"]) in vistas]
