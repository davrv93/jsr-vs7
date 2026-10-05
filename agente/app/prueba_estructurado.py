"""Pruebas de la respuesta estructurada (app/estructurado.py), de las plantillas y de la redacción con LLM (con un LLM simulado: no hay red).

    python -m app.prueba_estructurado

Lo que más importa aquí: los PASOS solo salen del artículo, el LLM nunca recibe datos personales ni contraseñas, y cualquier fallo del LLM
(HTTP 500, JSON roto, frases inventadas) acaba en el respaldo por código, nunca en un error ni en un texto inventado.
"""
from __future__ import annotations

import json
import os
import sys

os.environ.setdefault("LOG_LEVEL", "WARNING")
os.environ["VERIFICAR_MODO"] = "activo"      # el verificador arranca en `sombra`; esta prueba mide lo que hace en `activo` (quitar, regenerar) y fija el modo ella misma

import logging

import httpx

logging.getLogger("agente.redactor").setLevel(logging.CRITICAL)      # la prueba hace fallar al LLM simulado a propósito
logging.getLogger("agente").setLevel(logging.CRITICAL)

from . import estructurado as X, gasto, memoria as M, plantillas as P, redactor, verificar

fallos: list[str] = []
total = 0


def caso(nombre, obtenido, esperado):
    global total
    total += 1
    if obtenido != esperado:
        fallos.append(f"   ✗ {nombre}: {obtenido!r} (esperado {esperado!r})")


ART = {"clave": "KB-018", "titulo": "Excel se cierra solo o se congela", "categoria": "software_oficina",
       "pasos": ["Abre Excel en modo seguro: pulsa Windows + R, escribe excel /safe y pulsa Enter.", "Guarda una copia del archivo con otro nombre en Archivo > «Guardar como».",
                 "Cierra los demás programas pesados mientras trabajas con archivos grandes.", "Reinicia el equipo con Inicio > Reiniciar."]}

# --- armar ---------------------------------------------------------------------------------------------------------
caso("armar · piezas en párrafos", X.armar("Entiendo.", ["uno", "dos"], "¿Quedó resuelto?"), "Entiendo.\n\n1. uno\n2. dos\n\n¿Quedó resuelto?")
caso("armar · sin pasos ni pregunta", X.armar("Hola."), "Hola.")
caso("armar · todo vacío", X.armar(), "")
caso("numerar", X.numerar(["a", "b"]), "1. a\n2. b")

# --- leer el JSON del LLM --------------------------------------------------------------------------------------------
caso("leer · JSON limpio", X.leer('{"responde": "Hola", "pregunta": "¿Cómo?"}'), {"responde": "Hola", "pregunta": "¿Cómo?"})
caso("leer · con ```json```", X.leer('```json\n{"responde": "Hola"}\n```'), {"responde": "Hola", "pregunta": ""})
caso("leer · con texto alrededor", X.leer('Claro: {"responde": "Hola"} listo'), {"responde": "Hola", "pregunta": ""})
caso("leer · el campo «pasos» se ignora", X.leer('{"responde": "Hola", "pasos": ["inventado"]}'), {"responde": "Hola", "pregunta": ""})
caso("leer · roto", X.leer("{responde: Hola"), None)
caso("leer · no es objeto", X.leer("[1,2]"), None)
caso("leer · vacío", X.leer(""), None)
caso("armar_desde_llm · recorta a 2 frases y quita preguntas", X.armar_desde_llm('{"responde": "Uno. Dos. Tres. ¿Cuatro?"}', [], "¿Pregunta del código?"), "Uno. Dos.\n\n¿Pregunta del código?")
caso("armar_desde_llm · la pregunta del LLM solo si el código no tiene", X.armar_desde_llm('{"responde": "Hola.", "pregunta": "¿Qué pasó?"}', [], "", permitir_pregunta=True), "Hola.\n\n¿Qué pasó?")
caso("armar_desde_llm · sin permiso no se cuela", X.armar_desde_llm('{"responde": "Hola.", "pregunta": "¿Qué pasó?"}', [], ""), "Hola.")
caso("armar_desde_llm · JSON roto → None", X.armar_desde_llm("hola sin json"), None)
caso("armar_desde_llm · responde vacío → None", X.armar_desde_llm('{"responde": "", "pregunta": "¿Y?"}', [], "¿X?"), None)
caso("sin_json · no deja llaves", "{" in X.sin_json('{"responde": "Hola", "pregunta": ""}'), False)
caso("formato · con pregunta del código", "NO la escribas tú" in X.formato("¿X?"), True)

# --- los pasos salen del artículo ------------------------------------------------------------------------------------
pasos, saltados = X.pasos_para(ART, [])
caso("pasos_para · sin probados, todos", (pasos, saltados), (ART["pasos"], []))
pasos, saltados = X.pasos_para(ART, ["reiniciar el equipo"])
caso("pasos_para · salta lo ya probado", (len(pasos), saltados, "Reinicia el equipo con Inicio > Reiniciar." in pasos), (3, ["reiniciar el equipo"], False))
caso("pasos_para · cada paso es del artículo", X.solo_del_articulo(pasos, ART), True)
caso("pasos_para · nunca deja menos de 2", len(X.pasos_para({"pasos": ["Reinicia el equipo.", "Abre Excel."]}, ["reiniciar el equipo"])[0]), 2)
caso("pasos_para · sin artículo", X.pasos_para(None, ["reiniciar el equipo"]), ([], []))
caso("solo_del_articulo · un paso inventado", X.solo_del_articulo(["Reinstala Windows."], ART), False)

# --- plantillas -----------------------------------------------------------------------------------------------------
mem = M.nueva()
perfil = {"nombre": "Ana Ríos"}
def comp(accion, **kw):
    d = {"accion": accion, "etapa": "diagnostico", "intencion": "reportar_falla", "entendido": True, "guia": False, "preguntar": False, "motivo_incidencia": None,
         "incidencia_tipo": None, "numero": None, "puntaje": None, "dato": None} | kw
    return P.componer(d, {"mem": mem, "perfil": perfil, "categoria": "correo", "articulo": ART, "pasos": ART["pasos"], "saltados": [], "pregunta_clave": "aplicacion", "secreto": False})
caso("plantilla · saludo con nombre de pila", "Hola, Ana" in comp("ninguna", intencion="saludo", etapa="recepcion")["responde"], True)
caso("plantilla · guía lleva pasos, pregunta y pendiente", (comp("ninguna", guia=True, etapa="guia")["pasos"] == ART["pasos"], comp("ninguna", guia=True, etapa="guia")["pendiente"]), (True, "resolvio"))
caso("plantilla · diagnóstico pregunta la elegida por el código", comp("ninguna", preguntar=True)["pendiente"], "aplicacion")
caso("plantilla · confirmar pide la encuesta", comp("confirmar_solucion", etapa="cierre")["pendiente"], "puntaje")
caso("plantilla · crear incidencia: frase previa y el backend arma el resto", comp("crear_incidencia", motivo_incidencia="guia_agotada", etapa="incidencia")["texto_null"], True)
caso("plantilla · P1 no promete plazos", "plazo" in comp("crear_incidencia", motivo_incidencia="p1", etapa="incidencia")["responde"].lower(), False)
caso("plantilla · estado sin número", "No veo incidencias abiertas" in comp("consultar_estado", etapa="consulta_estado")["responde"], True)
caso("plantilla · estado con número deja el dato al backend", comp("consultar_estado", etapa="consulta_estado", numero="INC-000142")["texto_null"], True)
caso("plantilla · el aviso de contraseña va primero", P.componer({"accion": "ninguna", "etapa": "diagnostico", "intencion": "reportar_falla", "entendido": True, "guia": False, "preguntar": True},
     {"mem": mem, "perfil": perfil, "categoria": "correo", "pregunta_clave": "aplicacion", "secreto": True})["responde"].startswith("No compartas tu contraseña por aquí; ya la oculté."), True)
caso("plantilla · no se entendió", comp("ninguna", entendido=False)["pendiente"], "que_pasa")
caso("plantilla · queja ofrece técnico", comp("ninguna", intencion="queja", ofrecer_tecnico=True)["pendiente"], "ofrecer_tecnico")
for accion in ("encuesta", "sigue_igual", "agregar_dato", "pedir_tecnico"):
    caso(f"plantilla · {accion} dice algo", bool(comp(accion, puntaje=4, dato={"clave": "equipo", "valor": "PC-1"})["responde"]), True)
for t in ("fuera_de_alcance", "agradecer", "saludo"):
    caso(f"plantilla · {t} dice algo", bool(comp("ninguna", intencion=t, etapa="recepcion")["responde"]), True)
# Ninguna plantilla promete un plazo ni un nombre de técnico.
import re
for accion in ("crear_incidencia", "pedir_tecnico", "consultar_estado", "sigue_igual", "agregar_dato", "confirmar_solucion", "encuesta"):
    t = comp(accion, motivo_incidencia="p1", etapa="incidencia", numero=None, puntaje=5)["responde"]
    caso(f"plantilla · {accion} no promete plazos", bool(re.search(r"\b\d+\s*(?:min|minutos|horas|días)\b|antes de las", t)), False)

# --- el LLM, simulado ------------------------------------------------------------------------------------------------
from fastapi.testclient import TestClient
from .main import app

PETICIONES: list[dict] = []
RESPUESTAS: list = []        # cada elemento: dict JSON del LLM, o un código HTTP (int), o un texto crudo


def manejador(request: httpx.Request) -> httpx.Response:
    cuerpo = json.loads(request.content)
    PETICIONES.append(cuerpo)
    r = RESPUESTAS.pop(0) if RESPUESTAS else {"responde": "Entiendo.", "pregunta": ""}
    if isinstance(r, int):
        return httpx.Response(r, json={"error": "x"})
    texto = r if isinstance(r, str) else json.dumps(r, ensure_ascii=False)
    return httpx.Response(200, json={"choices": [{"message": {"content": texto}}], "usage": {"prompt_tokens": 400, "completion_tokens": 60, "cost": 0.00031}})


def con_llm():
    redactor.CLAVE, redactor.HABILITADO = "clave-de-prueba", True
    redactor.MODELOS = ["modelo-a"]
    redactor._http = httpx.Client(transport=httpx.MockTransport(manejador))


def sin_llm():
    redactor.CLAVE = ""


def turno(c, mensaje, etapa="recepcion", memoria=None, **extra):
    cuerpo = {"caso_id": 7, "canal": "web", "mensaje": mensaje, "historial": [], "etapa": etapa, "memoria": memoria or {}, "perfil": {"nombre": "Ana Ríos", "sede": "Centro", "area": "Contabilidad", "equipos": ["PC-CONT-07"]},
              "incidencias_abiertas": [], "usar_llm": True} | extra
    r = c.post("/chat", json=cuerpo)
    assert r.status_code == 200, r.text
    return r.json()


with TestClient(app) as c:
    # Sin clave: todo por código.
    sin_llm()
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
    caso("sin clave · no se usa LLM", (j["analisis"]["llm"]["usado"], j["costo_usd"], len(PETICIONES)), (False, 0, 0))

    # Con un LLM que contesta bien: usa su «responde», y los pasos siguen siendo los del artículo.
    con_llm()
    RESPUESTAS[:] = [{"responde": "Entiendo que tu Excel se cierra solo con archivos grandes; vamos a revisarlo.", "pregunta": "", "pasos": ["Formatea el disco duro."]}]
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
    caso("LLM bueno · se usa su redacción", "Entiendo que tu Excel se cierra solo" in (j["respuesta"] or ""), True)
    caso("LLM bueno · no cuela los pasos que mandó", "Formatea" in (j["respuesta"] or ""), False)
    caso("LLM bueno · los pasos son los del artículo", "Abre Excel en modo seguro" in (j["respuesta"] or ""), True)
    caso("LLM bueno · costo y uso", (j["analisis"]["llm"]["usado"], j["costo_usd"] > 0, j["regenerada"], j["frases_quitadas"]), (True, True, False, 0))

    # Lo que sale hacia el LLM no trae datos personales ni contraseñas.
    PETICIONES.clear()
    RESPUESTAS[:] = [{"responde": "Entiendo, vamos a revisar tu Excel.", "pregunta": ""}]
    j = turno(c, "soy Ana Ríos, mi correo es ana@x.pe, DNI 45678912, cel 987654321, mi clave es Perro123 y el excel se cierra solo",
              historial=[{"rol": "usuario", "texto": "hola, soy Ana Ríos, escríbeme a ana@x.pe"}])
    enviado = json.dumps(PETICIONES[0], ensure_ascii=False) if PETICIONES else ""
    for dato in ("Perro123", "ana@x.pe", "45678912", "987654321", "Ana Ríos", "Ríos"):
        caso(f"al LLM no le llega «{dato}»", dato in enviado, False)
    caso("al LLM sí le llega el síntoma", "excel se cierra solo" in enviado, True)
    caso("se avisa de la contraseña aunque redacte el LLM", (j["respuesta"] or "").startswith("No compartas tu contraseña por aquí; ya la oculté."), True)
    caso("la contraseña no se guarda", "Perro123" in j["texto_usuario_guardar"], False)

    # Frases inventadas: el verificador las quita y se regenera una vez.
    PETICIONES.clear()
    RESPUESTAS[:] = [{"responde": "Entiendo. Esto suele deberse a un virus. Espera 15 minutos y reinstala Windows.", "pregunta": ""},
                     {"responde": "Entiendo, vamos a revisar tu Excel.", "pregunta": ""}]
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
    caso("inventado · se regenera una vez", (j["regenerada"], len(PETICIONES)), (True, 2))
    caso("inventado · no llega al usuario", any(x in (j["respuesta"] or "") for x in ("virus", "15 minutos", "reinstala")), False)
    caso("inventado · se cuentan las frases quitadas", j["frases_quitadas"] >= 1, True)
    caso("inventado · el prompt de regeneración lo advierte", "OJO" in PETICIONES[1]["messages"][1]["content"], True)

    # En sombra (el modo por defecto) el verificador solo registra: el texto pasa, no se regenera y no se cuenta nada como quitado.
    verificar.MODO = "sombra"
    PETICIONES.clear()
    RESPUESTAS[:] = [{"responde": "Entiendo. Esto suele deberse a un virus. Espera 15 minutos y reinstala Windows.", "pregunta": ""}]
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
    caso("sombra · no regenera", (j["regenerada"], len(PETICIONES)), (False, 1))
    caso("sombra · el texto pasa tal cual", "virus" in (j["respuesta"] or ""), True)
    caso("sombra · no cuenta frases quitadas", j["frases_quitadas"], 0)
    ver = j["juez"]["veredictos"]["verificacion"]
    caso("sombra · deja registrado lo que habría quitado", (ver["modo"], len(ver["quitadas"]) >= 1), ("sombra", True))
    verificar.MODO = "activo"

    # Si la regeneración también inventa, cae a la plantilla.
    PETICIONES.clear()
    RESPUESTAS[:] = [{"responde": "Reinstala Windows y listo.", "pregunta": ""}, {"responde": "Borra la carpeta C:\\Windows y espera 15 minutos.", "pregunta": ""}]
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
    caso("dos veces inventado · cae a la plantilla", (any(x in (j["respuesta"] or "") for x in ("Windows y listo", "C:\\")), "Encontré esta guía" in (j["respuesta"] or "")), (False, True))
    caso("dos veces inventado · los pasos siguen siendo del artículo", "Abre Excel en modo seguro" in (j["respuesta"] or ""), True)

    # El LLM falla: HTTP 500, JSON roto, texto suelto, respuesta vacía.
    for nombre, r in (("HTTP 500", 500), ("JSON roto", "{responde: hola"), ("texto suelto", "Claro, te ayudo con eso"), ("vacío", {"responde": "", "pregunta": ""})):
        RESPUESTAS[:] = [r, r]
        j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
        caso(f"LLM {nombre} · respaldo por código", ("Encontré esta guía" in (j["respuesta"] or ""), "{" in (j["respuesta"] or "")), (True, False))

    # Los flujos fijos no pasan por el LLM (número, plazo, técnico, estado y encuesta los escribe código).
    PETICIONES.clear()
    RESPUESTAS[:] = [{"responde": "Tu incidencia INC-999999 la atiende Pedro y estará lista en 10 minutos.", "pregunta": ""}]
    j = turno(c, "se cayó el internet en toda la sede")
    caso("flujo fijo · no se llama al LLM", (len(PETICIONES), j["accion"]["tipo"]), (0, "crear_incidencia"))
    caso("flujo fijo · nada de números ni plazos inventados", any(x in (j["respuesta"] or "") for x in ("INC-999999", "Pedro", "10 minutos")), False)
    j = turno(c, "quiero hablar con un técnico")
    caso("pedir técnico · no se llama al LLM", (len(PETICIONES), j["accion"]["tipo"]), (0, "pedir_tecnico"))

    # Con usar_llm falso no se llama aunque haya clave.
    RESPUESTAS[:] = [{"responde": "Hola.", "pregunta": ""}]
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande", usar_llm=False)
    caso("usar_llm false · no se llama", (len(PETICIONES), j["analisis"]["llm"]["usado"]), (0, False))

    # Un LLM que repite un marcador de privacidad: no llega a la persona.
    RESPUESTAS[:] = [{"responde": "Hola [nombre], vamos a revisar tu [correo].", "pregunta": ""}]
    j = turno(c, "el excel se cierra solo cuando abro un archivo grande")
    caso("marcadores [nombre]/[correo] no llegan a la persona", ("[nombre]" in (j["respuesta"] or "") or "[correo]" in (j["respuesta"] or "")), False)
    sin_llm()

# gasto
gasto.iniciar()
gasto.sumar({"cost": 0.001})
gasto.sumar({"prompt_tokens": 1_000_000, "completion_tokens": 0})
caso("gasto · suma el costo y estima por tokens", gasto.total(), round(0.001 + gasto.PRECIO_ENTRADA, 6))
gasto.sumar(None)
gasto.sumar({"cost": "x"})
caso("gasto · ignora lo raro", gasto.total(), round(0.001 + gasto.PRECIO_ENTRADA, 6))

print(f"prueba_estructurado: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
