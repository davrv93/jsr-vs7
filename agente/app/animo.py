"""Ánimo y urgencia de un mensaje: cómo se siente la persona y cuánta prisa tiene.

Reglas, no modelo. Alimentan las señales de la respuesta (`animo`, `queja`) que el backend usa para el escalamiento
(ARQUITECTURA §3.3: «sentimiento muy negativo o queja explícita» avisa al supervisor). No cambian la etapa ni deciden
nada: el agente propone; el backend dispone.

- animo: `neutro` | `molesto` | `muy_negativo`.
- queja: pide o hace un reclamo del servicio (la regla es la misma que usa etapas.py).
- urgencia: 0..1; sube con «urgente», «ya», plazos cortos y con lo que se sabe de la ficha.

Sin dependencias pesadas: se prueba con `python -m app.prueba_animo`.
"""
from __future__ import annotations

import re

from .lenguaje import es_queja
from .memoria import _plano

MOLESTO = re.compile(
    r"\b(?:molest\w*|enojad\w*|fastidi\w*|harto|arto|harta|cansad\w*|decepcion\w*|disgust\w*|queja|reclam\w*|lent[ií]simo|no sirve\w*|no funciona nada|"
    r"siempre falla\w*|otra vez|de nuevo|ya (?:van|llevo|llevamos) \w+|nadie (?:me )?(?:responde|contesta|atiende|hace nada)|mal servicio|pesim\w*|que (?:mal|lata|fastidio)|"
    r"increible|que desastre|es una lata|ya no aguanto|me urge)\b")
MUY_NEGATIVO = re.compile(
    r"\b(?:inaceptable|inutil\w*|incompetent\w*|estafa\w*|burla|verguenza|asqueros\w*|porqueria|basura|ridicul\w*|falta de respeto|indignad\w*|furios\w*|"
    r"denunci\w*|me (?:harte|canse)|ya me (?:harte|canse)|nunca mas|peor servicio|pesimo servicio|pesima atencion|desastre|mierda|carajo|maldit\w*|estupid\w*|idiot\w*|"
    r"voy a (?:reclamar|denunciar|quejarme|escalar)|queja formal|que asco|harto de)\b")
URGENTE = re.compile(
    r"\b(?:urgent\w*|cuanto antes|lo antes posible|de inmediato|ahora mismo|ya mismo|apurad\w*|urge|para hoy|es hoy|hoy mismo|cierre contable|tengo (?:una )?(?:entrega|reunion|presentacion)|"
    r"no puedo trabajar|no podemos trabajar|emergencia|critic\w*|paralizad\w*)\b")
EMOJI_NEG = re.compile("[\U0001F620\U0001F621\U0001F624\U0001F92C\U0001F61E\U0001F622\U0001F62D\U0001F629\U0001F62B\U0001F644\U0001F612\U0001F44E]")


def _mayusculas(texto: str) -> bool:
    letras = [c for c in texto if c.isalpha()]
    return len(letras) >= 10 and sum(c.isupper() for c in letras) / len(letras) > 0.7


def evaluar(texto: str, mem: dict | None = None) -> dict:
    """Devuelve {"animo", "queja", "sentimiento", "urgencia", "motivo"}."""
    texto = (texto or "")[:2000]
    t = _plano(texto)
    marcas = []
    fuertes = len(MUY_NEGATIVO.findall(t))
    suaves = len(MOLESTO.findall(t)) + len(EMOJI_NEG.findall(texto))
    gritos = _mayusculas(texto) or bool(re.search(r"!{3,}", texto))
    queja = es_queja(texto)
    if fuertes:
        marcas.append("lenguaje muy negativo")
    if suaves:
        marcas.append("molestia")
    if gritos:
        marcas.append("mayúsculas o exclamaciones")
    if queja:
        marcas.append("queja del servicio")
    if fuertes >= 2 or (fuertes and (gritos or queja)) or (queja and gritos and suaves):
        animo, sent = "muy_negativo", -min(1.0, 0.8 + 0.1 * (fuertes + suaves - 1))
    elif fuertes or suaves or queja or gritos:
        animo, sent = "molesto", -min(0.7, 0.4 + 0.1 * (suaves + fuertes))
    else:
        animo, sent = "neutro", 0.0
    urgencia, n_urg = 0.0, len(URGENTE.findall(t))
    if n_urg:
        urgencia = min(0.9, 0.5 + 0.2 * (n_urg - 1))
        marcas.append("plazo corto")
    sab = (mem or {}).get("sabemos", {}) if isinstance(mem, dict) else {}
    nivel = {"baja": 0.1, "media": 0.3, "alta": 0.7, "critica": 1.0}.get(sab.get("urgencia") or "", 0.0)
    urgencia = max(urgencia, nivel)
    if sab.get("caida"):
        urgencia = max(urgencia, 0.8)
    return {"animo": animo, "queja": bool(queja), "sentimiento": round(sent, 3), "urgencia": round(urgencia, 3), "motivo": "; ".join(marcas) if marcas else "sin señales"}
