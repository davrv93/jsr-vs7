"""Jev local (parte a): clasificación con contexto cuando el clasificador local duda, contra un `llama-server` local.

Mismo contrato que `jev.py` de kddesign (activo / estado / clasificar / sombra), para poder cambiar uno por otro. Lo que cambia:
en vez de un servicio de pago, un LLM pequeño (Qwen3-1.7B Q4_K_M, ver juez/README.md) que corre en el servidor, sin GPU, y al
que se le fuerza la salida con un esquema JSON de enum cerrado. Como no sale del servidor, SÍ puede recibir el mensaje sin enmascarar
(AGENTS.md §1.4 regla 2); aun así el agente le manda el texto ya sin contraseñas.

El juez PROPONE (intención, confianza, datos); el código decide. Nunca decide la etapa, la prioridad ni el escalamiento.

Variables:
- `JUEZ_URL`      p. ej. http://juez:8080 (llama-server, API compatible con OpenAI). Sin URL, el juez está apagado.
- `JUEZ_MODO`     apagado | sombra | activo. Por defecto: apagado sin JUEZ_URL, sombra con JUEZ_URL (AGENTS.md §1.4 regla 6).
                  · sombra: consulta en segundo plano y registra [JUEZ] junto a la decisión local; no cambia nada.
                  · activo: si el local duda (confianza < JUEZ_UMBRAL), se usa lo del juez cuando está más seguro.
- `JUEZ_UMBRAL`   por debajo de esta confianza local se consulta (0,80).
- `JUEZ_TIMEOUT_SECONDS` tiempo máximo de una consulta (1,8 s). **Nunca bloquea**: pasado ese tiempo se degrada al local.
- `JUEZ_MODEL`    nombre del modelo (llama-server lo ignora; otros servidores lo piden).

Dos defensas para que un juez lento o caído no tumbe el chat: el tiempo máximo, y un cortacircuitos (tras 3 fallos seguidos no se
vuelve a intentar durante 30 s).

El prompt lleva las instrucciones y el esquema FIJOS al inicio y la conversación al final, para que `llama-server` reutilice la caché
del prefijo (`cache_prompt`): es lo que baja la latencia de ~8 s a 1–2 s en CPU (ARQUITECTURA §6).
"""
from __future__ import annotations

import json
import logging
import math
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import httpx

from .datos import IMPACTOS, INTENCIONES

log = logging.getLogger("agente.juez")

URL = os.environ.get("JUEZ_URL", "").strip().rstrip("/")
_MODO_ENV = os.environ.get("JUEZ_MODO", "").strip().lower()
MODO = _MODO_ENV if _MODO_ENV in ("apagado", "sombra", "activo") else ("sombra" if URL else "apagado")
if not URL:
    MODO = "apagado"
UMBRAL = float(os.environ.get("JUEZ_UMBRAL", "0.80"))
TIMEOUT = float(os.environ.get("JUEZ_TIMEOUT_SECONDS", "1.8"))
MODELO = os.environ.get("JUEZ_MODEL", "qwen3-1.7b")
N_PREDICT = int(os.environ.get("JUEZ_N_PREDICT", "80"))
FALLOS_PARA_CORTAR = 3
SEGUNDOS_CORTADO = 30.0

_http = httpx.Client(timeout=TIMEOUT)
_fondo = ThreadPoolExecutor(max_workers=2, thread_name_prefix="juez")
_lock = threading.Lock()
_fallos = 0
_cortado_hasta = 0.0

# Las 13 intenciones, descritas (las mismas etiquetas del clasificador: la máquina de etapas no distingue de dónde vino).
DESCRIPCION = {
    "reportar_falla": "Cuenta que algo dejó de funcionar o funciona mal (correo, impresora, red, VPN, equipo, programa, sistema, teléfono).",
    "solicitar_acceso": "Pide un acceso, permiso, usuario o cuenta nueva (carpeta, sistema, VPN, correo).",
    "solicitar_equipo": "Pide un equipo, periférico o la instalación de un programa o licencia.",
    "restablecer_clave": "Olvidó, perdió o tiene bloqueada o vencida su contraseña o su usuario, y pide recuperarlo.",
    "consultar_estado": "Pregunta cómo va una incidencia o solicitud que ya hizo.",
    "aportar_dato": "Da un dato suelto (equipo, sede, desde cuándo, mensaje de error, programa, a quién afecta) o responde a lo que se le preguntó.",
    "confirmar_solucion": "Dice que ya se resolvió o que ya funciona.",
    "sigue_igual": "Dice que el problema continúa tras probar algo.",
    "pedir_tecnico": "Pide hablar con una persona o que un técnico lo atienda.",
    "queja": "Se queja de la demora, del servicio o de la atención.",
    "agradecer": "Agradece o cierra la conversación con cortesía.",
    "saludo": "Solo saluda o llama, sin pedir nada todavía.",
    "fuera_de_alcance": "Habla de algo que no es soporte técnico.",
}
ESQUEMA = {
    "type": "object",
    "properties": {
        "intencion": {"type": "string", "enum": list(INTENCIONES)},
        "confianza": {"type": "number", "minimum": 0, "maximum": 1},
        "datos": {"type": "object", "properties": {
            "equipo": {"type": "string"}, "aplicacion": {"type": "string"}, "desde": {"type": "string"},
            "mensaje_error": {"type": "string"}, "impacto": {"type": "string", "enum": list(IMPACTOS)}},
            "additionalProperties": False},
    },
    "required": ["intencion", "confianza", "datos"], "additionalProperties": False,
}
# Esta parte NO cambia entre mensajes: es el prefijo que se cachea (instrucciones, reglas y ejemplos).
EJEMPLOS = [   # (lo último que dijo el asistente, lo que escribió la persona, intención)
    ("Cuando los pruebes, cuéntame: ¿quedó resuelto?", "sí, gracias", "confirmar_solucion"),
    ("Cuando los pruebes, cuéntame: ¿quedó resuelto?", "no, sigue fallando igual", "sigue_igual"),
    ("¿Desde cuándo te pasa?", "desde el lunes", "aportar_dato"),
    ("¿Cuál es el código de tu equipo?", "LAP-GER-09", "aportar_dato"),
    ("¿A alguien más le pasa lo mismo, o solo a ti?", "a mi jefa también", "aportar_dato"),
    ("¿Te aparece algún mensaje de error?", "ninguno, solo se congela", "aportar_dato"),
    ("¿Quieres que un técnico te contacte?", "sí por favor", "pedir_tecnico"),
    ("¿Quieres que un técnico te contacte?", "no, ya no hace falta", "agradecer"),
    ("Anoté tu incidencia.", "¿ya la vio alguien?", "consultar_estado"),
    ("Anoté tu incidencia.", "sigue sin funcionar", "sigue_igual"),
    ("", "mi pantalla se ve negra", "reportar_falla"),
    ("", "necesito que creen un correo para un practicante", "solicitar_acceso"),
    ("", "hola, una pregunta", "saludo"),
    ("", "¿cuánto cuesta un pasaje a Piura?", "fuera_de_alcance"),
]
INSTRUCCIONES = ("Eres el clasificador de una mesa de ayuda de TI. Lees el ESTADO de una conversación y eliges la INTENCIÓN del ÚLTIMO MENSAJE DE LA PERSONA.\n"
                 "Intenciones posibles:\n" + "\n".join(f"- {k}: {v}" for k, v in DESCRIPCION.items()) + "\n"
                 "Reglas: (1) Si el asistente acaba de hacer una pregunta y el mensaje la responde (un dato, un «sí», un «no», un «no sé»), la intención es aportar_dato; "
                 "las únicas excepciones son «sí»/«no» a «¿quedó resuelto?» (confirmar_solucion o sigue_igual) y a «¿quieres que un técnico te contacte?» (pedir_tecnico, o agradecer si dice que no). "
                 "(2) Una frase corta como «igual», «nada» o «lo mismo» tras unos pasos significa que el problema sigue (sigue_igual). "
                 "(3) Usa el historial solo para entender respuestas cortas. "
                 "Responde SOLO un JSON con intencion, confianza (0 a 1) y datos (solo los que el mensaje dice, con las mismas palabras; omite los que no).\n"
                 "Ejemplos:\n" + "\n".join(f"Asistente: «{a}» · Persona: «{m}» → {i}" if a else f"Persona: «{m}» → {i}" for a, m, i in EJEMPLOS))
_ETAPA_TXT = {"recepcion": "inicio de la conversación", "diagnostico": "el asistente está preguntando datos para diagnosticar", "guia": "el asistente acaba de dar pasos para probar",
              "incidencia": "se está registrando una incidencia", "seguimiento": "ya hay una incidencia abierta", "cierre": "el asistente pidió la calificación", "encuesta": "terminó el caso",
              "consulta_estado": "la persona preguntó por el estado de una incidencia"}
_PENDIENTE_TXT = {"resolvio": "«¿quedó resuelto?»", "ofrecer_tecnico": "«¿quieres que un técnico te contacte?»", "puntaje": "«¿cómo calificas la atención del 1 al 5?»",
                  "aplicacion": "en qué programa o sistema le pasa", "mensaje_error": "si le aparece un mensaje de error", "desde": "desde cuándo le pasa", "equipo": "el código del equipo",
                  "sede_piso": "la sede y el piso", "piso": "el piso", "area": "el área", "afecta_otros": "si le pasa a alguien más", "imprime_otro": "si otros pueden imprimir",
                  "impresora": "el nombre de la impresora", "tipo_red": "si usa WiFi o cable", "anexo": "el número de anexo", "que_solicita": "qué acceso o equipo necesita", "que_pasa": "qué problema tiene"}


def modo() -> str:
    return MODO


def configurar(url: str | None = None, modo: str | None = None, timeout: float | None = None) -> None:
    """Cambia la configuración en caliente (pruebas y `evaluar_juez`). Sin URL, el juez queda apagado."""
    global URL, MODO, TIMEOUT, _http
    if url is not None:
        URL = url.strip().rstrip("/")
    if timeout is not None:
        TIMEOUT = timeout
        _http = httpx.Client(timeout=TIMEOUT)
    MODO = (modo if modo in ("apagado", "sombra", "activo") else ("sombra" if URL else "apagado")) if URL else "apagado"
    reiniciar()


def activo() -> bool:
    """¿Hay juez al que consultar? (sombra o activo, con URL y sin el cortacircuitos abierto)."""
    return MODO in ("sombra", "activo") and bool(URL) and time.time() >= _cortado_hasta


def _registrar_resultado(ok: bool) -> None:
    global _fallos, _cortado_hasta
    with _lock:
        if ok:
            _fallos = 0
            return
        _fallos += 1
        if _fallos >= FALLOS_PARA_CORTAR:
            _cortado_hasta = time.time() + SEGUNDOS_CORTADO
            _fallos = 0
            log.warning("juez: %d fallos seguidos, se deja de consultar %ds", FALLOS_PARA_CORTAR, int(SEGUNDOS_CORTADO))


def reiniciar() -> None:
    """Para las pruebas: cierra el cortacircuitos."""
    global _fallos, _cortado_hasta
    with _lock:
        _fallos, _cortado_hasta = 0, 0.0


def estado(mensaje: str, historial: list[dict], etapa: str, pendiente: str = "", sabemos: str = "", categoria: str = "") -> dict:
    """El estado que ve el juez (conversación al final del prompt). El nombre de la persona no va."""
    st = {"etapa": etapa or "recepcion", "historial": [{"rol": t.get("rol", ""), "texto": str(t.get("texto", ""))[:300]} for t in (historial or [])[-6:] if isinstance(t, dict)],
          "mensaje": mensaje[:600]}
    if pendiente:
        st["pregunta_pendiente_del_asistente"] = pendiente
    if sabemos:
        st["lo_que_ya_sabemos"] = sabemos
    if categoria:
        st["categoria"] = categoria
    return st


def _prompt(st: dict) -> list[dict]:
    """La conversación, en español claro y al final: lo que cambia en cada mensaje va después del prefijo fijo (para la caché)."""
    lineas = [f"ETAPA: {_ETAPA_TXT.get(st.get('etapa'), st.get('etapa'))}"]
    if st.get("pregunta_pendiente_del_asistente"):
        k = st["pregunta_pendiente_del_asistente"]
        lineas.append(f"EL ASISTENTE ESPERA RESPUESTA A: {_PENDIENTE_TXT.get(k, k)}")
    if st.get("lo_que_ya_sabemos"):
        lineas.append(f"LO QUE YA SABEMOS: {st['lo_que_ya_sabemos']}")
    hist = st.get("historial") or []
    if hist:
        lineas.append("CONVERSACIÓN RECIENTE:")
        lineas += [f"{'Asistente' if t.get('rol') != 'usuario' else 'Persona'}: {t.get('texto', '')}" for t in hist]
    lineas.append(f"ÚLTIMO MENSAJE DE LA PERSONA: «{st.get('mensaje', '')}»")
    return [{"role": "system", "content": INSTRUCCIONES}, {"role": "user", "content": "ESTADO:\n" + "\n".join(lineas)}]


def _cuerpo(mensajes: list[dict], esquema: dict, nombre: str, n_predict: int, logprobs: bool = False) -> dict:
    cuerpo = {"model": MODELO, "messages": mensajes, "temperature": 0, "max_tokens": n_predict, "stream": False,
              "response_format": {"type": "json_schema", "json_schema": {"name": nombre, "strict": True, "schema": esquema}},
              "cache_prompt": True,                                  # llama-server: reutiliza el prefijo fijo
              "chat_template_kwargs": {"enable_thinking": False},    # Qwen3: sin modo de razonamiento (lento e innecesario aquí)
              "reasoning_effort": "none"}
    if logprobs:
        cuerpo |= {"logprobs": True, "top_logprobs": 12}
    return cuerpo


def _llamar(cuerpo: dict) -> dict | None:
    """POST al servidor del juez. None si falla o tarda más del tiempo máximo (se degrada al clasificador local)."""
    if not activo():
        return None
    try:
        r = _http.post(f"{URL}/v1/chat/completions", json=cuerpo)
        r.raise_for_status()
        js = r.json()
        _registrar_resultado(True)
        return js
    except Exception as e:  # noqa: BLE001  (timeout, conexión, 5xx, JSON roto: da igual, no se bloquea)
        log.warning("el juez no respondió: %s", e)
        _registrar_resultado(False)
        return None


def _probabilidades(js: dict, elegido: str) -> dict[str, float] | None:
    """Con logprobs, la distribución sobre las intenciones sale del token donde empieza el valor de `intencion`: es mucho más
    fiable que la confianza que el modelo dice tener. None si el servidor no devolvió logprobs."""
    try:
        toks = js["choices"][0]["logprobs"]["content"]
    except (KeyError, IndexError, TypeError):
        return None
    acumulado = ""
    for t in toks:
        pieza = t.get("token", "")
        limpio = acumulado.replace(" ", "").replace("\n", "")
        acumulado += pieza
        # el token que abre el valor de «intencion» es el que sigue a «"intencion":"»
        if limpio.endswith('"intencion":"') and pieza:
            masas: dict[str, float] = {}
            for alt in (t.get("top_logprobs") or []):
                prefijo = str(alt.get("token", "")).strip()
                if not prefijo:
                    continue
                for it in INTENCIONES:
                    if it.startswith(prefijo) or prefijo.startswith(it):
                        masas[it] = masas.get(it, 0.0) + math.exp(float(alt.get("logprob", -30)))
                        break
            total = sum(masas.values())
            if total > 0:
                return {k: round(v / total, 3) for k, v in sorted(masas.items(), key=lambda x: -x[1])[:4]}
            return None
    return None


def clasificar(st: dict, usar_logprobs: bool = True) -> dict | None:
    """Intención con contexto. Devuelve {intent, confianza, probabilidades, datos, ms, fuente} o None si el juez no respondió.
    `confianza` sale de los logprobs si el servidor los trae (más fiable); si no, de la que dice el modelo."""
    if not activo():
        return None
    t0 = time.time()
    js = _llamar(_cuerpo(_prompt(st), ESQUEMA, "clasificacion", N_PREDICT, logprobs=usar_logprobs))
    if js is None:
        return None
    try:
        crudo = js["choices"][0]["message"]["content"]
        out = json.loads(crudo)
        intent = out["intencion"]
        if intent not in INTENCIONES:
            raise ValueError(f"intención fuera del vocabulario: {intent!r}")
        propia = max(0.0, min(1.0, float(out.get("confianza", 0.0))))
    except (KeyError, IndexError, TypeError, ValueError) as e:
        log.warning("el juez devolvió algo ilegible: %s", e)
        _registrar_resultado(False)
        return None
    probs = _probabilidades(js, intent) if usar_logprobs else None
    conf, fuente = (probs.get(intent, propia), "logprobs") if probs and intent in probs else (propia, "autoinforme")
    datos = {k: str(v)[:100] for k, v in (out.get("datos") or {}).items() if isinstance(v, str) and v.strip()}
    return {"intent": intent, "confianza": round(conf, 3), "confianza_propia": round(propia, 3), "probabilidades": probs or {intent: round(propia, 3)},
            "datos": datos, "ms": int((time.time() - t0) * 1000), "fuente": fuente}


def sombra(st: dict, local: dict, conversacion: str = "") -> None:
    """Modo sombra: el juez clasifica en segundo plano y queda registrado junto a la decisión local. No cambia nada."""
    def tarea():
        j = clasificar(st)
        if j:
            log.info("[JUEZ] %s", json.dumps({"conversacion": conversacion, "mensaje": st.get("mensaje", "")[:200],
                                              "local": {"intent": local.get("intent"), "confianza": round(float(local.get("confianza", 0)), 3)},
                                              "juez": {k: j[k] for k in ("intent", "confianza", "probabilidades", "ms", "fuente")},
                                              "coincide": j["intent"] == local.get("intent")}, ensure_ascii=False))
    _fondo.submit(tarea)


# --- «¿contestó?» con el mismo servidor (respaldo del reranker, ARQUITECTURA §6 fila c) --------------------------------------
ESQUEMA_CONTESTA = {"type": "object", "properties": {"contesta": {"type": "boolean"}, "falta": {"type": "string"}}, "required": ["contesta", "falta"], "additionalProperties": False}
INSTRUCCIONES_CONTESTA = ("Eres un revisor de una mesa de ayuda. Te doy la PREGUNTA de una persona y la RESPUESTA que se le va a enviar. "
                          "Responde SOLO un JSON: contesta=true si la respuesta atiende lo que la persona pidió (aunque sea para decir que lo revisará un técnico); "
                          "falta=lo que no contesta, en una frase corta, o cadena vacía.")


def contesta(pregunta: str, respuesta: str) -> dict | None:
    """{contesta: bool, falta: str} del juez, o None si no respondió."""
    if not activo():
        return None
    msgs = [{"role": "system", "content": INSTRUCCIONES_CONTESTA},
            {"role": "user", "content": json.dumps({"pregunta": pregunta[:500], "respuesta": respuesta[:800]}, ensure_ascii=False)}]
    js = _llamar(_cuerpo(msgs, ESQUEMA_CONTESTA, "contesta", 60))
    if js is None:
        return None
    try:
        out = json.loads(js["choices"][0]["message"]["content"])
        return {"contesta": bool(out["contesta"]), "falta": str(out.get("falta", ""))[:200]}
    except (KeyError, IndexError, TypeError, ValueError):
        _registrar_resultado(False)
        return None
