"""Pruebas de las rutas del agente que NO son /chat (CONTRATOS §1): /salud, /metricas, /clasificar, /conocimiento/recargar, /conocimiento/articulos, /reentrenar, /modelos, la sugerencia al técnico y la interfaz.

    python -m app.prueba_api

Trabaja sobre una COPIA de los artefactos entrenados (carpeta temporal): reentrenar crea versiones nuevas y no debe ensuciar index/.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile

# Antes de importar la app: la copia de los artefactos.
_ORIGEN = os.environ.get("AGENTE_INDEX_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "index")
_TMP = tempfile.mkdtemp(prefix="jsrbot_index_")
shutil.copytree(_ORIGEN, _TMP, dirs_exist_ok=True)
os.environ["AGENTE_INDEX_DIR"] = _TMP
os.environ.setdefault("LOG_LEVEL", "WARNING")

from fastapi.testclient import TestClient

from . import datos, memoria as M
from .main import app

fallos: list[str] = []
total = 0


def caso(nombre, obtenido, esperado):
    global total
    total += 1
    if obtenido != esperado:
        fallos.append(f"   ✗ {nombre}: {obtenido!r} (esperado {esperado!r})")


try:
    with TestClient(app) as c:
        # --- /salud -----------------------------------------------------------------------------------------------
        j = c.get("/salud").json()
        caso("/salud · exactamente {ok, modelo, juez}", (set(j), j["ok"], j["modelo"], j["juez"]), ({"ok", "modelo", "juez"}, True, "v1", "apagado"))

        # --- /metricas -----------------------------------------------------------------------------------------------
        m = c.get("/metricas").json()
        caso("/metricas · trae las cifras del reservado", (m["modelo"], "reservado" in m["entrenamiento"]["intencion"], m["rag"]["articulos"]), ("v1", True, 20))
        caso("/metricas · la exactitud de intención supera la meta del 90 %", m["entrenamiento"]["intencion"]["reservado"]["exactitud"] >= 0.90, True)

        # --- /clasificar -----------------------------------------------------------------------------------------------
        j = c.post("/clasificar", json={"texto": "la impresora no imprime"}).json()
        caso("/clasificar · intención y categoría", (j["intencion"], j["categoria"]), ("reportar_falla", "impresoras"))
        caso("/clasificar · vacío no revienta", c.post("/clasificar", json={"texto": ""}).status_code, 200)

        # --- GET / ---------------------------------------------------------------------------------------------------
        r = c.get("/")
        caso("GET / · sirve el chat de depuración", (r.status_code, "text/html" in r.headers["content-type"], "POST /chat" in r.text), (200, True, True))

        # --- /chat · campos de la raíz y sugerencia al técnico -----------------------------------------------------------------
        perfil = {"nombre": "Ana Ríos", "sede": "Centro"}

        def chat(mensaje, etapa="recepcion", memoria=None):
            return c.post("/chat", json={"mensaje": mensaje, "etapa": etapa, "memoria": memoria or {}, "perfil": perfil, "usar_llm": False}).json()

        todos_los_pasos = {p for a in __import__("json").load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "seed", "articulos.json"), encoding="utf-8")) for p in a["pasos"]}
        j = chat("hola")
        caso("/chat · regenerada, frases_quitadas y costo_usd están en la raíz", (j["regenerada"], j["frases_quitadas"], j["costo_usd"]), (False, 0, 0))
        caso("/chat · sugerencia_tecnico es null cuando no hay caso", ("sugerencia_tecnico" in j, j["sugerencia_tecnico"]), (True, None))
        g = chat("no me abre el correo")
        caso("/chat · mientras el asistente atiende (diagnóstico o guía) no hay sugerencia", (g["etapa"] in ("diagnostico", "guia"), g["sugerencia_tecnico"]), (True, None))
        # El caso en manos de la mesa: la ficha se arma a mano (no depende de cómo clasifique cada plataforma) y «quiero un técnico» se respeta siempre.
        ficha = M.nueva()
        ficha["sabemos"]["sintoma"], ficha["categoria"], ficha["intencion_caso"] = "Outlook no baja los correos nuevos", "correo", "reportar_falla"
        i = chat("quiero un técnico", "guia", ficha)
        sug_obj = i["sugerencia_tecnico"] or {}
        sug = sug_obj.get("texto", "")
        caso("/chat · la sugerencia es {texto, articulo?} (la forma que lee la pasarela)", (i["accion"]["tipo"], set(sug_obj) <= {"texto", "articulo"}, "texto" in sug_obj), ("pedir_tecnico", True, True))
        caso("/chat · lleva el nombre de pila y no el apellido", (sug.startswith("Hola, Ana."), "Ríos" in sug), (True, False))
        pasos = [ln.split(". ", 1)[1] for ln in sug.splitlines() if ln[:1].isdigit() and ". " in ln]
        caso("/chat · la sugerencia trae 1 a 3 pasos y todos son de un artículo", (1 <= len(pasos) <= 3, all(p in todos_los_pasos for p in pasos)), (True, True))
        art_sug = next((x for x in __import__("json").load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "seed", "articulos.json"), encoding="utf-8")) if x["clave"] == sug_obj.get("articulo")), None)
        caso("/chat · la sugerencia con pasos cita el artículo del que salen", (art_sug is not None, art_sug is not None and all(p in art_sug["pasos"] for p in pasos)), (True, True))
        ficha["articulos_mostrados"] = [sug_obj.get("articulo")]
        otra = (chat("quiero un técnico", "guia", ficha)["sugerencia_tecnico"] or {})
        caso("/chat · no sugiere un artículo que la persona ya vio", otra.get("articulo") != sug_obj.get("articulo"), True)
        caso("/chat · la sugerencia no promete plazos", any(x in sug for x in ("minutos", "horas", "hoy", "mañana")), False)
        caso("/chat · la sugerencia es breve", len(sug) <= 700, True)
        p1 = chat("se cayó el internet en toda la sede")
        caso("/chat · en un P1 no se sugieren pasos al usuario", ("\n1. " in ((p1["sugerencia_tecnico"] or {}).get("texto") or ""), p1["accion"]["tipo"]), (False, "crear_incidencia"))
        caso("/chat · consultar estado no lleva sugerencia", chat("¿cómo va mi incidencia?")["sugerencia_tecnico"], None)

        # --- /conocimiento/recargar ----------------------------------------------------------------------------------------
        nuevos = [{"clave": "KB-901", "titulo": "El lector de huellas no reconoce a nadie", "categoria": "otro", "sintomas": ["el lector de huellas no marca", "el reloj biométrico no lee mi huella"],
                   "pasos": ["Limpia el sensor con un paño seco.", "Registra de nuevo tu huella en el equipo de asistencia."], "cuerpo": ""},
                  {"clave": "KB-902", "titulo": "Solo cuerpo en Markdown", "categoria": "correo", "sintomas": "no abre el correo\nno sincroniza", "pasos": [],
                   "cuerpo": "# Solo cuerpo\n\n## Pasos\n1. Cierra Outlook.\n2. Ábrelo otra vez.\n\n## Cuándo pasar a un técnico\nSi sigue igual."},
                  {"clave": "", "titulo": "sin clave"}, "no es un artículo", None, {"clave": "KB-901", "titulo": "duplicado"}]
        r = c.post("/conocimiento/recargar", json={"articulos": nuevos})
        caso("/recargar · cuenta los válidos y descarta el resto", (r.status_code, r.json()["articulos"], r.json()["descartados"]), (200, 2, 4))
        arts = {a["clave"]: a for a in c.get("/conocimiento").json()["articulos"]}
        caso("/recargar · reemplaza los artículos", set(arts), {"KB-901", "KB-902"})
        caso("/recargar · saca los pasos del cuerpo en Markdown", arts["KB-902"]["pasos"], 2)
        j = c.post("/chat", json={"mensaje": "el reloj biométrico de asistencia no lee mi huella", "usar_llm": False}).json()
        caso("/recargar · el agente usa el artículo nuevo", (j["etapa"], j["articulos_usados"]), ("guia", ["KB-901"]))
        caso("/recargar · los pasos son los del artículo nuevo", "Limpia el sensor con un paño seco." in (j["respuesta"] or ""), True)
        for malo in ({}, {"articulos": "x"}, [], "texto"):
            r = c.post("/conocimiento/recargar", json=malo)
            caso(f"/recargar · cuerpo {str(malo)[:12]!r} no da 500", r.status_code in (200, 400), True)
        c.post("/conocimiento/recargar", json={"articulos": []})
        j = c.post("/chat", json={"mensaje": "no me abre el correo", "usar_llm": False}).json()
        caso("/recargar · sin artículos el agente sigue (abre incidencia o pregunta, nunca inventa)", (j["articulos_usados"], j["etapa"] in ("diagnostico", "incidencia")), ([], True))
        # GET /conocimiento/articulos devuelve SIEMPRE los del seed, aunque en este momento no haya ninguno cargado
        ar = c.get("/conocimiento/articulos")
        lista = ar.json()["articulos"]
        caso("/conocimiento/articulos · los 20 del seed aunque no haya cargados", (ar.status_code, len(lista), lista[0]["clave"], lista[-1]["clave"]), (200, 20, "KB-001", "KB-020"))
        caso("/conocimiento/articulos · claves del contrato y supuesto:true", (all(set(a) == {"clave", "titulo", "categoria", "sintomas", "pasos", "cuerpo", "supuesto"} for a in lista), all(a["supuesto"] is True for a in lista)), (True, True))
        caso("/conocimiento/articulos · cada uno con síntomas, pasos y cuerpo", all(a["sintomas"] and a["pasos"] and a["cuerpo"] for a in lista), True)
        caso("/conocimiento/articulos · sirve para recargar", c.post("/conocimiento/recargar", json={"articulos": lista}).json()["articulos"], 20)
        # restaurar el seed
        import json as _json
        from .conocimiento import SEED
        c.post("/conocimiento/recargar", json={"articulos": _json.load(open(SEED, encoding="utf-8"))})
        # los usos de cada artículo (bandido) llegan con el artículo
        arts = _json.load(open(SEED, encoding="utf-8"))
        arts[0]["usos"] = {"correo": {"exitos": 9, "fracasos": 1}}
        c.post("/conocimiento/recargar", json={"articulos": arts})
        from .main import E
        caso("/recargar · los usos del backend alimentan al bandido", E.conocimiento.stats.get("KB-001|correo"), [9, 1])

        # --- /reentrenar y /modelos -------------------------------------------------------------------------------------------
        reservada = datos.prueba()[0]["mensaje"]
        r = c.post("/reentrenar", json={"ejemplos": [
            {"mensaje": "el escáner del primer piso no manda los archivos", "intencion": "reportar_falla", "categoria": "impresoras"},
            {"mensaje": reservada, "intencion": "saludo", "categoria": "otro"},       # coincide con el reservado: se descarta
            {"mensaje": "", "intencion": "saludo"}, {"intencion": "saludo"}, "basura"]})
        j = r.json()
        caso("/reentrenar · responde con el contrato", (r.status_code, {"ok", "modelo", "publicado", "candidato", "no_empeora", "actual", "intencion", "categoria", "ejemplos_extra", "motivo"} <= set(j)), (200, True))
        caso("/reentrenar · descarta lo que contamina el reservado y lo vacío", j["ejemplos_extra"], 1)
        caso("/reentrenar · versión nueva", j["modelo"], "v2")
        # Por defecto NO publica: queda como candidato con sus cifras (la aprobación la hace una persona desde la consola).
        caso("/reentrenar · por defecto queda como candidato", (j["publicado"], j["candidato"], j["actual"], c.get("/salud").json()["modelo"]), (False, True, "v1", "v1"))
        caso("/reentrenar · el motivo dice cómo publicarlo", "/modelos/v2/publicar" in j["motivo"], True)
        v2_ok = j["no_empeora"]      # según la plataforma (int8) el candidato puede mejorar o no el reservado: se prueban las dos salidas
        m = c.get("/modelos").json()
        v2 = next((x for x in m["modelos"] if x["version"] == "v2"), {})
        caso("/modelos · publicada y candidatos", (m["publicada"], m["candidatos"], [x["version"] for x in m["modelos"]]), ("v1", ["v2"], ["v1", "v2"]))
        caso("/modelos · cada versión trae sus cifras del reservado", (v2["estado"], v2["intencion"]["exactitud"] == j["intencion"]["exactitud"], v2["categoria"]["f1_macro"] == j["categoria"]["f1_macro"], m["cifras_publicada"]["intencion"]["exactitud"] > 0), ("candidata", True, True, True))
        caso("/modelos · no_empeora coincide con el reentrenamiento", v2["no_empeora"], j["no_empeora"])
        caso("/modelos/vN/publicar · una versión que no existe da 404", (c.post("/modelos/v99/publicar").status_code, c.post("/modelos/abc/publicar").status_code, c.post("/modelos/v1x/publicar").status_code), (404, 404, 404))
        caso("/modelos/vN/publicar · la ya publicada no cambia nada", c.post("/modelos/v1/publicar").json()["motivo"], "ya es la versión publicada")
        r = c.post("/modelos/v2/publicar")
        if j["no_empeora"]:
            caso("/modelos/v2/publicar · publica el candidato que no empeora", (r.status_code, r.json()["publicado"], r.json()["actual"], c.get("/salud").json()["modelo"]), (200, True, "v2", "v2"))
            caso("/modelos · tras publicar no quedan candidatos", (c.get("/modelos").json()["publicada"], c.get("/modelos").json()["candidatos"]), ("v2", []))
            caso("el chat sigue funcionando tras el cambio en caliente", c.post("/chat", json={"mensaje": "la impresora no imprime", "usar_llm": False}).json()["intencion"], "reportar_falla")
        else:
            caso("/modelos/v2/publicar · un candidato que empeora da 409", (r.status_code, r.json()["codigo"], c.get("/salud").json()["modelo"]), (409, "empeora", "v1"))
        # Un reentrenamiento que EMPEORA el reservado no se publica ni siquiera pidiendo `publicar`.
        antes = c.get("/salud").json()["modelo"]
        envenenados = [{"mensaje": e.texto, "intencion": "agradecer", "categoria": "otro"} for e in datos.ejemplos_intencion() if e.etiqueta == "reportar_falla"][:60]
        r = c.post("/reentrenar", json={"ejemplos": envenenados, "publicar": True})
        j = r.json()
        caso("/reentrenar · datos envenenados con publicar: no se publica", (j["publicado"], j["candidato"], j["no_empeora"], c.get("/salud").json()["modelo"]), (False, True, False, antes))
        caso("/reentrenar · dice por qué", "no mejora" in j["motivo"], True)
        envenenada = j["modelo"]
        r = c.post(f"/modelos/{envenenada}/publicar")
        caso("/modelos/vN/publicar · el candidato que empeora da 409 con sus cifras", (r.status_code, r.json()["codigo"], r.json()["no_empeora"], "antes" in r.json()["intencion"], c.get("/salud").json()["modelo"]), (409, "empeora", False, True, antes))
        caso("/modelos · el que empeora sigue como candidato", (c.get("/modelos").json()["candidatos"], next(x for x in c.get("/modelos").json()["modelos"] if x["version"] == envenenada)["no_empeora"]),
             ([envenenada] if v2_ok else ["v2", envenenada], False))
        # forzar publica aunque empeore (decisión de una persona), tanto al reentrenar como al publicar un candidato.
        r = c.post(f"/modelos/{envenenada}/publicar", json={"forzar": True})
        caso("/modelos/vN/publicar · forzar publica aunque empeore (lo decide una persona)", (r.status_code, r.json()["publicado"], c.get("/salud").json()["modelo"]), (200, True, envenenada))
        r = c.post("/reentrenar", json={"ejemplos": envenenados, "forzar": True})
        caso("/reentrenar · forzar publica (lo decide una persona)", r.json()["publicado"], True)
finally:
    shutil.rmtree(_TMP, ignore_errors=True)

print(f"prueba_api: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
