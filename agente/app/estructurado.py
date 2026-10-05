"""Respuesta estructurada: piezas separadas, el código arma el mensaje.

Medido en Baruka (50 conversaciones reservadas): lo que quedaba mal no era la clasificación sino la redacción. Con texto
libre no hay forma de obligar al LLM a no inventar, a no repetir y a no perder el hilo. Aquí el mensaje se arma así, en
este orden:

1. `responde`: lo que contesta a SU mensaje (máx. 2 frases). Va primero y no se puede saltar. Lo redacta el LLM si hay
   uno; si no, una plantilla (plantillas.py).
2. `pasos`: **solo salen del artículo, nunca los escribe un LLM.** El código copia los pasos del artículo tal cual (menos
   los que la persona ya probó) y los numera.
3. `pregunta`: la elige el código (`memoria.siguiente`). La del LLM solo se usa cuando el código no tiene ninguna.

Cada pieza es un párrafo; cada párrafo sale como un mensaje de WhatsApp. Las preguntas que el LLM meta en `responde` se
quitan: una sola pregunta por mensaje, y la decide el código. Si el JSON del LLM no se puede leer, no se usa su texto.

Sin dependencias: se prueba con `python -m app.prueba_estructurado`.
"""
from __future__ import annotations

import json
import os
import re

ACTIVO = os.environ.get("RESPUESTA_ESTRUCTURADA", "1") == "1"
MAX_RESPONDE = (2, 300)      # frases, caracteres
MAX_PREGUNTA = 160
MAX_PASOS = 8

RE_FRASE = re.compile(r"[^.!?¡¿]*(?:¿[^?]*\?|¡[^!]*!|[^.!?]+[.!?]+|[^.!?]+$)", re.S)
RE_JSON = re.compile(r"\{.*\}", re.S)

# Qué paso del artículo corresponde a cada cosa que la persona dice haber probado (memoria.PASOS_PROBADOS).
_PASO_DE = {
    "reiniciar el equipo": re.compile(r"\breinicia (?:el )?(?:equipo|la pc|la computadora)|\breiniciar\b|inicio > reiniciar|reinicia el equipo", re.I),
    "reiniciar el router": re.compile(r"\brouter\b", re.I),
    "cerrar y abrir la aplicación": re.compile(r"\bcierra (?:outlook|teams|excel|el cliente|la aplicaci)\w*[^.]*\b(?:vuelve a abrirlo|abrirlo|ábrelo)|\bcierra \w+ por completo y vuelve a abrir", re.I),
    "cerrar sesión": re.compile(r"\bcierra sesi[oó]n\b", re.I),
    "probar otro navegador": re.compile(r"\botro navegador\b|\bedge o chrome\b", re.I),
    "actualizar": re.compile(r"\bwindows update\b|\bactualizaciones\b", re.I),
}


def formato(pregunta_codigo: str, permitir_pregunta: bool = False) -> str:
    """La instrucción de salida que se añade al final del prompt del LLM (manda sobre cualquier otra de formato)."""
    if pregunta_codigo:
        cierre = (f'El código cierra el mensaje con esta pregunta: «{pregunta_codigo}». NO la escribas tú ni hagas otra: deja "pregunta" vacío.')
    elif permitir_pregunta:
        cierre = 'Si hace falta UNA pregunta, ponla en "pregunta"; si no, déjalo vacío. Nunca repitas algo que ya contestó.'
    else:
        cierre = 'No hagas preguntas: deja "pregunta" vacío.'
    return ("FORMATO DE SALIDA: responde SOLO con un objeto JSON:\n"
            '{"responde": "...", "pregunta": "..."}\n'
            '- "responde": contesta lo que la persona acaba de escribir, directo y con empatía, en máximo 2 frases cortas, sin preguntas. '
            "NO escribas pasos, números de incidencia, plazos, nombres de técnicos ni datos de la organización: el código los añade. "
            "Si no sabes un dato, no lo inventes.\n"
            f"- {cierre}\n"
            "Tono de mesa de ayuda peruana: cálido, breve y sin tecnicismos; sin emojis.")


def _frases(texto: str) -> list[str]:
    # El punto de un decimal o de una hora no termina la frase: «10.0.19045» o «S/ 20.00» no se parten.
    t = re.sub(r"(?<=\d)\.(?=\d)", "․", texto or "")
    return [f.strip().replace("․", ".") for f in RE_FRASE.findall(t) if f.strip()]


def _recortar(texto: str, max_frases: int, max_chars: int, sin_preguntas: bool = True) -> str:
    out = []
    for f in _frases(texto):
        if sin_preguntas and "?" in f:
            continue
        if out and len(" ".join(out + [f])) > max_chars:
            break
        out.append(f)
        if len(out) >= max_frases:
            break
    return " ".join(out).strip()


def leer(texto: str) -> dict | None:
    """El JSON del LLM, tolerante a ```json``` y a texto alrededor. None si no hay objeto legible.
    Cualquier campo `pasos` que mande se ignora: los pasos no los escribe el LLM."""
    t = (texto or "").strip()
    t = re.sub(r"^```(?:json)?|```$", "", t, flags=re.M).strip()
    m = RE_JSON.search(t)
    if not m:
        return None
    try:
        js = json.loads(m.group(0))
    except ValueError:
        return None
    if not isinstance(js, dict):
        return None
    return {k: str(js.get(k) or "").strip() for k in ("responde", "pregunta")}


def pasos_para(articulo: dict | None, probados: list[str] | tuple = ()) -> tuple[list[str], list[str]]:
    """Los pasos que se le muestran: los del artículo, sin los que ya probó (si quedan al menos dos). Devuelve
    (pasos, saltados) y cada paso es EXACTAMENTE un paso del artículo."""
    pasos = list((articulo or {}).get("pasos") or [])[:MAX_PASOS]
    saltados: list[str] = []
    if not pasos or not probados:
        return pasos, saltados
    quedan = list(pasos)
    for etiqueta in probados:
        rx = _PASO_DE.get(etiqueta)
        if not rx:
            continue
        for p in list(quedan):
            if rx.search(p) and len(quedan) > 2:
                quedan.remove(p)
                if etiqueta not in saltados:
                    saltados.append(etiqueta)
    return quedan, saltados


def solo_del_articulo(mostrados: list[str], articulo: dict | None) -> bool:
    """Comprobación de seguridad: todo paso que se muestra es un paso del artículo (ni uno inventado)."""
    ok = set((articulo or {}).get("pasos") or [])
    return all(p in ok for p in mostrados)


def numerar(pasos: list[str]) -> str:
    return "\n".join(f"{i}. {p}" for i, p in enumerate(pasos, 1))


def armar(responde: str = "", pasos: list[str] | None = None, pregunta: str = "") -> str:
    """El mensaje final, un párrafo por pieza. Una sola pregunta, la del código."""
    partes = [p for p in (responde.strip(), numerar(pasos or []), pregunta.strip()) if p]
    return "\n\n".join(partes)


def armar_desde_llm(texto_llm: str, pasos: list[str] | None = None, pregunta_codigo: str = "", permitir_pregunta: bool = False) -> str | None:
    """El mensaje con lo que redactó el LLM, o None si no devolvió JSON utilizable (entonces se usa la plantilla)."""
    js = leer(texto_llm)
    if js is None:
        return None
    responde = _recortar(js["responde"], *MAX_RESPONDE)
    pregunta = pregunta_codigo
    if not pregunta and permitir_pregunta:
        q = next((f for f in _frases(js["pregunta"]) if "?" in f), "")
        pregunta = q if len(q) <= MAX_PREGUNTA else ""
    if not responde:
        return None
    return armar(responde, pasos, pregunta)


def responde_de_llm(texto_llm: str) -> str | None:
    """Solo la parte «responde» ya recortada (para verificarla frase por frase antes de armar el mensaje)."""
    js = leer(texto_llm)
    if js is None:
        return None
    r = _recortar(js["responde"], *MAX_RESPONDE)
    return r or None


def sin_json(texto: str) -> str:
    """Si el LLM mandó JSON roto, que no llegue a la persona con llaves y comillas."""
    js = leer(texto)
    if js:
        return "\n\n".join(p for p in (js["responde"], js["pregunta"]) if p) or texto
    if texto.strip().startswith("{"):
        return re.sub(r'[{}"]|\b(responde|pregunta)\b\s*:', "", texto).strip()
    return texto
