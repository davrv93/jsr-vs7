"""Pruebas de juez.py (Jev local, clasificación con contexto) contra un servidor SIMULADO compatible con OpenAI (llama-server), sin red externa.

    python -m app.prueba_juez

Comprueba el contrato con el servidor (esquema JSON con enum cerrado, caché de prefijo, temperatura 0), los tres modos (apagado, sombra, activo),
que NUNCA bloquea (tiempo máximo, cortacircuitos) y cómo se integra en el turno del agente: en `sombra` registra y no cambia nada; en `activo`
corrige solo cuando el clasificador local duda y el juez está más seguro.
"""
from __future__ import annotations

import json
import math
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

os.environ.setdefault("LOG_LEVEL", "WARNING")

import logging

logging.getLogger("agente.juez").setLevel(logging.CRITICAL)      # esta prueba provoca fallos a propósito: sin ruido en el log del build

from . import juez
from .datos import INTENCIONES

fallos: list[str] = []
total = 0


def caso(nombre, obtenido, esperado):
    global total
    total += 1
    if obtenido != esperado:
        fallos.append(f"   ✗ {nombre}: {obtenido!r} (esperado {esperado!r})")


# --- el servidor simulado --------------------------------------------------------------------------------------------
class Estado:
    escenario = "ok"
    pedidos: list[dict] = []
    respuesta: dict = {"intencion": "confirmar_solucion", "confianza": 0.9, "datos": {}}
    intencion_logprob = "confirmar_solucion"


def _logprobs(intencion: str, otras: dict[str, float]) -> dict:
    """logprobs con la forma de OpenAI: el token donde empieza el valor de «intencion» trae las alternativas."""
    fijo = ['{"', 'intencion', '":"']
    toks = [{"token": t, "logprob": -0.001, "top_logprobs": []} for t in fijo]
    alts = [{"token": intencion[:6], "logprob": math.log(max(1e-9, 1 - sum(otras.values())))}] + [{"token": k[:6], "logprob": math.log(v)} for k, v in otras.items()]
    toks.append({"token": intencion[:6], "logprob": alts[0]["logprob"], "top_logprobs": alts})
    toks.append({"token": intencion[6:], "logprob": -0.0001, "top_logprobs": []})
    return {"content": toks}


class Manejador(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        cuerpo = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
        Estado.pedidos.append(cuerpo)
        e = Estado.escenario
        if e == "lento":
            time.sleep(1.5)
        if e == "500":
            self.send_response(500); self.end_headers(); return
        if e == "roto":
            contenido = "{no es json"
        elif e == "fuera_de_vocabulario":
            contenido = json.dumps({"intencion": "reclamar_algo", "confianza": 0.99, "datos": {}})
        else:
            contenido = json.dumps(Estado.respuesta, ensure_ascii=False)
        eleccion = {"message": {"content": contenido}}
        if e == "logprobs":
            eleccion["logprobs"] = _logprobs(Estado.respuesta["intencion"], {"sigue_igual": 0.2, "aportar_dato": 0.1})
        resp = json.dumps({"choices": [eleccion]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


class Servidor(HTTPServer):
    def handle_error(self, request, client_address):      # el cliente cerró la conexión antes de tiempo (escenario «lento»): no es un error de la prueba
        pass


srv = Servidor(("127.0.0.1", 0), Manejador)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{srv.server_port}"

ESTADO = juez.estado("sí", [{"rol": "asistente", "texto": "¿Quedó resuelto?"}], "guia", "resolvio", "problema: no abre el correo")

# --- modos ----------------------------------------------------------------------------------------------------------
juez.configurar(url="")
caso("sin URL: apagado", (juez.modo(), juez.activo(), juez.clasificar(ESTADO)), ("apagado", False, None))
juez.configurar(url=URL)
caso("con URL y sin modo: sombra", (juez.modo(), juez.activo()), ("sombra", True))
juez.configurar(url=URL, modo="activo")
caso("modo activo", juez.modo(), "activo")
juez.configurar(url=URL, modo="inventado")
caso("modo inventado: sombra", juez.modo(), "sombra")
juez.configurar(url=URL, modo="apagado")
caso("modo apagado no consulta", (juez.activo(), juez.clasificar(ESTADO)), (False, None))
juez.configurar(url=URL, modo="activo", timeout=1.0)

# --- el contrato con el servidor ------------------------------------------------------------------------------------------
Estado.escenario, Estado.pedidos = "ok", []
r = juez.clasificar(ESTADO)
caso("clasifica", (r["intent"], r["confianza"], r["fuente"]), ("confirmar_solucion", 0.9, "autoinforme"))
p = Estado.pedidos[0]
esquema = p["response_format"]["json_schema"]["schema"]
caso("esquema: enum cerrado con las 13 intenciones", esquema["properties"]["intencion"]["enum"], list(INTENCIONES))
caso("esquema: confianza, datos y nada más", (esquema["required"], esquema["additionalProperties"]), (["intencion", "confianza", "datos"], False))
caso("esquema estricto", (p["response_format"]["type"], p["response_format"]["json_schema"]["strict"]), ("json_schema", True))
caso("temperatura 0 y caché de prefijo", (p["temperature"], p["cache_prompt"]), (0, True))
caso("sin modo de razonamiento (Qwen3)", p["chat_template_kwargs"], {"enable_thinking": False})
caso("tokens de salida acotados", p["max_tokens"] <= 120, True)
caso("las instrucciones fijas van primero (prefijo cacheable)", (p["messages"][0]["role"], p["messages"][0]["content"].startswith("Eres el clasificador")), ("system", True))
caso("la conversación va al final, en español claro", "ESTADO:" in p["messages"][1]["content"] and "¿quedó resuelto?" in p["messages"][1]["content"] and "ÚLTIMO MENSAJE DE LA PERSONA: «sí»" in p["messages"][1]["content"], True)
caso("hay ejemplos en el prefijo fijo (se cachean)", "Ejemplos:" in p["messages"][0]["content"] and p["messages"][0]["content"].count("→") >= 10, True)
Estado.pedidos = []
juez.clasificar(juez.estado("otro", [], "guia"))
caso("el prefijo fijo es idéntico entre mensajes", Estado.pedidos[0]["messages"][0] == p["messages"][0], True)

# --- probabilidades desde los logprobs ----------------------------------------------------------------------------------------
Estado.escenario = "logprobs"
r = juez.clasificar(ESTADO)
caso("logprobs: la confianza sale de la distribución", (r["fuente"], round(r["confianza"], 1), set(r["probabilidades"])), ("logprobs", 0.7, {"confirmar_solucion", "sigue_igual", "aportar_dato"}))
caso("logprobs: la confianza propia se conserva aparte", r["confianza_propia"], 0.9)
Estado.escenario = "ok"

# --- datos propuestos --------------------------------------------------------------------------------------------------------
Estado.respuesta = {"intencion": "aportar_dato", "confianza": 0.8, "datos": {"equipo": "PC-CONT-07", "impacto": "persona", "desde": ""}}
r = juez.clasificar(juez.estado("es la PC-CONT-07", [], "diagnostico"))
caso("datos: solo los que traen texto", r["datos"], {"equipo": "PC-CONT-07", "impacto": "persona"})
Estado.respuesta = {"intencion": "confirmar_solucion", "confianza": 0.9, "datos": {}}

# --- nunca bloquea -------------------------------------------------------------------------------------------------------------
for esc in ("roto", "fuera_de_vocabulario", "500"):
    juez.reiniciar()
    Estado.escenario = esc
    caso(f"servidor «{esc}»: degrada a None", juez.clasificar(ESTADO), None)
juez.reiniciar()
Estado.escenario = "lento"
t0 = time.time()
caso("servidor lento: None", juez.clasificar(ESTADO), None)
caso("servidor lento: no pasa del tiempo máximo (1 s) ni siquiera con holgura", time.time() - t0 < 1.4, True)
# Cortacircuitos: tras 3 fallos seguidos no se vuelve a llamar.
juez.reiniciar()
Estado.escenario, Estado.pedidos = "500", []
for _ in range(juez.FALLOS_PARA_CORTAR):
    juez.clasificar(ESTADO)
n_antes = len(Estado.pedidos)
caso("cortacircuitos: abierto tras 3 fallos", juez.activo(), False)
t0 = time.time()
juez.clasificar(ESTADO)
juez.clasificar(ESTADO)
caso("cortacircuitos: ya no llama al servidor ni espera", (len(Estado.pedidos) == n_antes, time.time() - t0 < 0.05), (True, True))
juez.reiniciar()
Estado.escenario = "ok"
caso("cortacircuitos: se cierra con reiniciar()", juez.clasificar(ESTADO) is not None, True)
# Un éxito pone a cero los fallos seguidos.
juez.reiniciar()
Estado.escenario = "500"
juez.clasificar(ESTADO); juez.clasificar(ESTADO)
Estado.escenario = "ok"
juez.clasificar(ESTADO)
Estado.escenario = "500"
juez.clasificar(ESTADO); juez.clasificar(ESTADO)
caso("un éxito reinicia la cuenta de fallos", juez.activo(), True)
juez.reiniciar()
Estado.escenario = "ok"

# --- «¿contestó?» con el mismo servidor ----------------------------------------------------------------------------------------------
Estado.respuesta = {"contesta": False, "falta": "no dice cómo reiniciar"}
r = juez.contesta("¿cómo reinicio el router?", "Tu incidencia está en curso.")
caso("contesta · veredicto del juez", r, {"contesta": False, "falta": "no dice cómo reiniciar"})
Estado.respuesta = {"intencion": "confirmar_solucion", "confianza": 0.9, "datos": {}}

# --- integración en el turno del agente ---------------------------------------------------------------------------------------------
from fastapi.testclient import TestClient
from .main import app

CUERPO = {"caso_id": 3, "mensaje": "mmm creo que sí, qué sé yo", "historial": [], "etapa": "recepcion", "memoria": {}, "perfil": {"nombre": "Ana"}, "incidencias_abiertas": [], "usar_llm": False}
with TestClient(app) as c:
    juez.configurar(url="")
    base = c.post("/chat", json=CUERPO).json()
    caso("sin juez: modo apagado en la respuesta", base["juez"], {"modo": "apagado", "veredictos": {}} | {"veredictos": base["juez"]["veredictos"]})
    caso("sin juez: /salud lo dice", c.get("/salud").json()["juez"], "apagado")
    juez.UMBRAL = 1.01       # consulta siempre (el clasificador nunca llega a 1,01)
    Estado.respuesta = {"intencion": "pedir_tecnico", "confianza": 0.97, "datos": {}}
    Estado.escenario = "ok"
    # sombra: registra el veredicto y no cambia nada
    juez.configurar(url=URL, modo="sombra", timeout=2.0)
    s = c.post("/chat", json=CUERPO).json()
    caso("sombra: la respuesta no cambia", (s["intencion"], s["etapa"], s["accion"]["tipo"]), (base["intencion"], base["etapa"], base["accion"]["tipo"]))
    caso("sombra: queda el veredicto", s["juez"]["modo"] == "sombra" and s["juez"]["veredictos"]["clasificacion"]["intent"] == "pedir_tecnico", True)
    caso("sombra: /salud", c.get("/salud").json()["juez"], "sombra")
    # activo: el juez corrige porque está más seguro que el local
    juez.configurar(url=URL, modo="activo", timeout=2.0)
    a = c.post("/chat", json=CUERPO).json()
    caso("activo: el juez corrige la intención", (a["intencion"], a["accion"]["tipo"]), ("pedir_tecnico", "pedir_tecnico"))
    caso("activo: queda dicho en la bitácora", any("juez local" in x for x in a["analisis"]["bitacora"]), True)
    # activo pero el juez está menos seguro: no cambia
    Estado.respuesta = {"intencion": "pedir_tecnico", "confianza": 0.01, "datos": {}}
    a = c.post("/chat", json=CUERPO).json()
    caso("activo: si el juez está menos seguro, manda el local", a["intencion"], base["intencion"])
    # activo y el servidor cae: el chat sigue
    Estado.escenario = "500"
    a = c.post("/chat", json=CUERPO).json()
    caso("activo con el juez caído: el chat sigue igual", (a["intencion"], a["etapa"]), (base["intencion"], base["etapa"]))
    # el juez no se consulta cuando el local está seguro
    juez.UMBRAL = 0.80
    juez.reiniciar()
    Estado.escenario, Estado.pedidos = "ok", []
    seguro = dict(CUERPO, mensaje="quiero hablar con un técnico, por favor")
    c.post("/chat", json=seguro)
    caso("el juez no se consulta si el local está seguro", len(Estado.pedidos), 0)
    # datos que propone el juez: solo si están, tal cual, en el mensaje
    juez.UMBRAL = 1.01
    Estado.respuesta = {"intencion": "aportar_dato", "confianza": 0.99, "datos": {"equipo": "LAP-INVENTADA-1", "aplicacion": "Outlook"}}
    Estado.pedidos = []
    a = c.post("/chat", json=dict(CUERPO, mensaje="mmm uso Outlook creo")).json()
    caso("datos del juez: solo los que están en el mensaje", a["juez"]["veredictos"].get("datos_propuestos"), {"aplicacion": "Outlook"})
    juez.configurar(url="")
    juez.UMBRAL = 0.80

srv.shutdown()
print(f"prueba_juez: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
