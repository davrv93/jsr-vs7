"""Redacción con un LLM por API (OpenRouter), con respaldo por código SIEMPRE disponible.

- Variable `OPENROUTER_API_KEY` (o `LLM_API_KEY`). Si no existe, `disponible()` es False y todo el agente funciona 100 % por
  plantillas y código (plantillas.py): ese es el modo de la regresión y del build.
- Al LLM solo le llega el caso ENMASCARADO (seguridad.preparar_para_llm): síntoma, pasos probados, título del artículo y
  los últimos turnos, sin nombres, correos, DNI, teléfonos, IP, contraseñas ni tokens (AGENTS.md §4).
- El LLM solo redacta la pieza «responde» (y a veces la pregunta); los pasos, los números, los plazos y los técnicos no son suyos.
- Cada llamada suma su costo en gasto.py.
"""
from __future__ import annotations

import logging
import os

import httpx

from . import gasto

log = logging.getLogger("agente.redactor")

URL = os.environ.get("LLM_URL", "https://openrouter.ai/api/v1/chat/completions")
CLAVE = (os.environ.get("OPENROUTER_API_KEY") or os.environ.get("LLM_API_KEY") or "").strip()
MODELOS = [m.strip() for m in os.environ.get("LLM_MODEL", "deepseek/deepseek-chat-v3.1,deepseek/deepseek-v4-flash").split(",") if m.strip()]
MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "300"))
TIMEOUT = float(os.environ.get("LLM_TIMEOUT_SECONDS", "8"))
HABILITADO = os.environ.get("LLM_ENABLED", "1") == "1"

_http = httpx.Client(timeout=TIMEOUT, headers={"HTTP-Referer": "https://jsrbot.local", "X-Title": "jsrbot agente"})

SISTEMA = ("Eres el asistente de soporte técnico de una mesa de ayuda. Hablas español de Perú, de «tú», cálido, breve y sin tecnicismos. "
           "Reglas que no puedes romper: no inventes pasos, plazos, nombres de técnicos, números de incidencia ni datos de la organización; "
           "no pidas contraseñas ni datos personales; no prometas nada que no esté en el contexto; si no sabes algo, no lo digas. "
           "Los pasos de la solución los añade el sistema desde la base de conocimiento: tú no los escribes.")


def disponible() -> bool:
    return HABILITADO and bool(CLAVE)


def estado() -> dict:
    return {"configurado": bool(CLAVE), "habilitado": HABILITADO, "modelos": MODELOS}


def llamar(mensajes: list[dict], temperatura: float = 0.4) -> tuple[str, str]:
    """Llama al LLM probando los modelos en orden. Devuelve (texto, modelo). Lanza RuntimeError si ninguno responde."""
    if not CLAVE:
        raise RuntimeError("OPENROUTER_API_KEY vacío")
    es_openrouter = "openrouter.ai" in URL
    ultimo = None
    for modelo in MODELOS:
        try:
            cuerpo = {"model": modelo, "messages": mensajes, "temperature": temperatura, "max_tokens": MAX_TOKENS,
                      "response_format": {"type": "json_object"}}
            if es_openrouter:
                cuerpo["reasoning"] = {"enabled": False}      # los modelos que razonan tardan 5 veces más en un chat de 2 frases
                cuerpo["usage"] = {"include": True}           # trae usage.cost: lo suma gasto.py
            r = _http.post(URL, headers={"Authorization": f"Bearer {CLAVE}"}, json=cuerpo)
            if r.status_code >= 400:
                raise RuntimeError(f"{modelo}: HTTP {r.status_code}")
            js = r.json()
            gasto.sumar(js.get("usage"))
            texto = (js["choices"][0]["message"].get("content") or "").strip()
            if texto:
                return texto, modelo
            raise RuntimeError(f"{modelo}: respuesta vacía")
        except Exception as e:  # noqa: BLE001
            ultimo = e
            log.warning("LLM falló: %s", e)
    raise RuntimeError(str(ultimo))


def mensajes(caso: dict, instruccion_formato: str) -> list[dict]:
    """El prompt. `caso` YA viene enmascarado: etapa, intención, categoría, ficha, mensaje, turnos, artículo, pregunta."""
    partes = [f"ETAPA: {caso.get('etapa')}", f"INTENCIÓN DE LA PERSONA: {caso.get('intencion')}", f"CATEGORÍA: {caso.get('categoria')}",
              f"LO QUE SABEMOS DEL CASO: {caso.get('ficha') or 'nada todavía'}"]
    if caso.get("articulo"):
        partes.append(f"GUÍA QUE EL SISTEMA LE VA A MOSTRAR (no la repitas): «{caso['articulo']}»")
    if caso.get("turnos"):
        partes.append("ÚLTIMOS MENSAJES:\n" + "\n".join(f"- {t}" for t in caso["turnos"]))
    partes.append(f"MENSAJE DE LA PERSONA: {caso.get('mensaje')}")
    partes.append(instruccion_formato)
    return [{"role": "system", "content": SISTEMA}, {"role": "user", "content": "\n".join(partes)}]
