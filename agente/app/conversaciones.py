"""Conversaciones completas de soporte para la regresión (app/regresion.py), y el «backend de bolsillo» que las conduce.

Cada conversación es un guion: lo que escribe la persona en cada turno y lo que se espera del agente (etapa, acción, motivo de la
incidencia, datos de la ficha, frases que debe o no debe decir). Los guiones NO entran al entrenamiento: si uno falla por
clasificación, se agregan frases distintas a data/*.csv (nunca se copian los guiones).

`Chat` emula lo mínimo del backend Go: guarda la etapa, la memoria y el historial de un turno al siguiente; crea la incidencia cuando
el agente la propone (con un número, un técnico y un estado) y la cierra cuando se confirma. El flujo real del backend se prueba con
`go test`; aquí se prueba que el agente, conducido así, hace lo que dice ARQUITECTURA §2.

Reglas universales (se comprueban en TODOS los turnos de TODAS las conversaciones, además de lo que pida cada guion):
- el vocabulario es el cerrado de CONTRATOS §3 (intención, categoría, etapa, acción);
- ni la acción ni la propuesta de incidencia traen prioridad, plazo, técnico ni estado (eso lo decide el backend);
- una sola pregunta por mensaje y nunca una ya contestada ni ya hecha (salvo «¿qué pasa?», que se repite una vez);
- los pasos que se muestran son EXACTAMENTE pasos de un artículo (nunca inventados);
- ninguna promesa de plazo que no salga del sistema («en 10 minutos», «antes de las 11»);
- el mensaje que se guarda no trae ninguna contraseña; si había una, la señal `contrasena_oculta` está activa y se le avisa;
- una incidencia nunca se cierra ni se encuesta sin que la persona lo confirme.
"""
from __future__ import annotations

import re

from . import datos, memoria

PERFIL = {"nombre": "Ana Ríos", "sede": "Centro", "area": "Contabilidad", "vip": False, "equipos": ["PC-CONT-07"]}
INC_CORREO = {"numero": "INC-000142", "estado": "en_curso", "titulo": "Outlook no recibe correos", "categoria": "correo", "tecnico": "Luis Paz",
              "vence_resolucion_en": "2026-10-05T16:40:00Z"}
INC_IMPRESORA = {"numero": "INC-000231", "estado": "asignada", "titulo": "La impresora del tercer piso no imprime", "categoria": "impresoras", "tecnico": "Rosa Quispe",
                 "vence_resolucion_en": "2026-10-06T14:00:00Z"}
TECNICOS = ["Luis Paz", "Rosa Quispe"]
RE_PROMESA_PLAZO = re.compile(r"\b(?:en|dentro de|antes de|hasta)\s+(?:las\s+)?\d+\s*(?:min|minutos|horas|hs|h|dias|días)\b|\bhoy mismo\b|\ben breve\b|\bde inmediato\b|\ben unos minutos\b", re.I)
RE_NUMERADO = re.compile(r"^\s*\d+\.\s+")
CAMPOS_PROHIBIDOS = {"prioridad", "plazo", "plazos", "sla", "tecnico", "tecnico_id", "estado", "asignado", "asignada", "vence", "vence_resolucion_en"}


class Chat:
    """El backend de bolsillo: lleva etapa, memoria e historial entre turnos y atiende lo que el agente propone."""

    def __init__(self, cliente, perfil: dict | None = None, abiertas: list[dict] | None = None, etapa: str = "recepcion", memoria_: dict | None = None, caso_id: int = 1):
        self.c, self.perfil = cliente, dict(PERFIL if perfil is None else perfil)
        self.abiertas = [dict(i) for i in (abiertas or [])]
        self.etapa, self.memoria, self.historial, self.caso_id = etapa, dict(memoria_ or {}), [], caso_id
        self.n_inc = max([int(i["numero"][4:]) for i in self.abiertas] + [141])
        self.turnos: list[dict] = []     # (usuario, respuesta completa del agente, texto final)

    def cuerpo(self, texto: str) -> dict:
        return {"caso_id": self.caso_id, "canal": "web", "mensaje": texto, "historial": self.historial[-12:], "etapa": self.etapa, "memoria": self.memoria,
                "perfil": self.perfil, "incidencias_abiertas": self.abiertas, "ahora": "2026-10-05T14:30:00Z", "usar_llm": False}

    def decir(self, texto: str) -> dict:
        r = self.c.post("/chat", json=self.cuerpo(texto))
        if r.status_code != 200:
            raise AssertionError(f"POST /chat devolvió {r.status_code}: {r.text[:200]}")
        j = r.json()
        acc = j["accion"]
        creada = None
        if acc["tipo"] == "crear_incidencia" or (acc["tipo"] == "pedir_tecnico" and acc.get("incidencia")):
            self.n_inc += 1
            creada = f"INC-{self.n_inc:06d}"
            self.abiertas.append({"numero": creada, "estado": "nueva", "titulo": acc["incidencia"]["titulo"], "categoria": acc["incidencia"]["categoria"],
                                  "tecnico": TECNICOS[len(self.abiertas) % 2], "vence_resolucion_en": "2026-10-06T14:00:00Z"})
            j["memoria"]["incidencia"] = creada      # el backend la guarda en la memoria del caso
        if acc["tipo"] == "confirmar_solucion" and acc.get("numero"):
            self.abiertas = [i for i in self.abiertas if i["numero"] != acc["numero"]]
        j["_creada"] = creada
        # El texto que ve la persona: lo del agente más lo fijo que añade el backend.
        extra = ""
        if creada:
            extra = f" Registré {creada}."
        elif acc["tipo"] in ("consultar_estado", "pedir_tecnico", "sigue_igual", "agregar_dato") and acc.get("numero"):
            inc = next((i for i in self.abiertas if i["numero"] == acc["numero"]), None)
            extra = f" {acc['numero']} está {inc['estado'] if inc else 'abierta'}." if inc else ""
        j["_texto"] = ((j["respuesta"] or "") + extra).strip()
        self.etapa, self.memoria = j["etapa"], j["memoria"]
        self.historial.append({"rol": "usuario", "texto": j["texto_usuario_guardar"]})
        self.historial.append({"rol": "asistente", "texto": j["_texto"]})
        self.turnos.append({"usuario": texto, "j": j})
        return j


# ---------------------------------------------------------------------------
# Reglas universales

def norm(t: str) -> str:
    return datos.plano(t)


def universales(j: dict, antes: dict | None, texto_usuario: str, articulos: dict) -> list[str]:
    """Lo que se cumple en cada turno de cada conversación. Devuelve las faltas (vacío = todo bien)."""
    fa = []
    if j.get("etapa") not in datos.ETAPAS:
        fa.append(f"etapa fuera del vocabulario: {j.get('etapa')!r}")
    if j.get("intencion") not in datos.INTENCIONES:
        fa.append(f"intención fuera del vocabulario: {j.get('intencion')!r}")
    if j.get("categoria") is not None and j["categoria"] not in datos.CATEGORIAS:
        fa.append(f"categoría fuera del vocabulario: {j.get('categoria')!r}")
    acc = j.get("accion") or {}
    if acc.get("tipo") not in datos.TIPOS_ACCION:
        fa.append(f"acción fuera del vocabulario: {acc.get('tipo')!r}")
    prohibidos = (CAMPOS_PROHIBIDOS & set(acc)) | (CAMPOS_PROHIBIDOS & set(acc.get("incidencia") or {}))
    if prohibidos:
        fa.append(f"el agente no decide {sorted(prohibidos)}")
    inc = acc.get("incidencia")
    if inc:
        if inc.get("tipo") not in datos.TIPOS_INCIDENCIA or inc.get("categoria") not in datos.CATEGORIAS or inc.get("impacto") not in datos.IMPACTOS \
                or inc.get("urgencia") not in datos.URGENCIAS or (inc.get("motivo") not in datos.MOTIVOS):
            fa.append(f"propuesta de incidencia fuera del vocabulario: {inc}")
        if not inc.get("titulo") or not inc.get("resumen"):
            fa.append("propuesta de incidencia sin título o sin resumen")
    for dato in ([acc["dato"]] if acc.get("dato") else []) + list(acc.get("datos") or []):
        if not isinstance(dato.get("clave"), str) or not isinstance(dato.get("valor"), str):
            fa.append(f"el dato de la acción debe ser {{clave: texto, valor: texto}}: {dato}")
    texto = j.get("respuesta") or ""
    # las preguntas que cuentan son las del asistente; un paso del artículo puede citar un botón con signos de pregunta
    preguntas = memoria.preguntas_en("\n".join(ln for ln in texto.splitlines() if not RE_NUMERADO.match(ln)))
    if len(preguntas) > 1:
        fa.append(f"más de una pregunta en el mismo mensaje: {preguntas}")
    # los pasos que se muestran son pasos de un artículo
    for linea in texto.splitlines():
        if RE_NUMERADO.match(linea):
            paso = RE_NUMERADO.sub("", linea).strip()
            if not any(paso in (a["pasos"]) for a in articulos.values()):
                fa.append(f"paso inventado (no está en ningún artículo): {paso[:80]!r}")
    sin_pasos = "\n".join(ln for ln in texto.splitlines() if not RE_NUMERADO.match(ln))
    if RE_PROMESA_PLAZO.search(sin_pasos):
        fa.append(f"promete un plazo que no sale del sistema: {RE_PROMESA_PLAZO.search(sin_pasos).group(0)!r}")
    # no repite una pregunta ya contestada ni una ya hecha (salvo «qué pasa»)
    pre = j["memoria"].get("preguntado", [])
    dup = {k for k in pre if pre.count(k) > 1 and k not in memoria.REPETIBLES}
    if dup:
        fa.append(f"se preguntó más de una vez: {sorted(dup)}")
    sab = j["memoria"]["sabemos"]
    for k in preguntas:
        c = memoria.clave_de(k)
        if c in memoria.DATO_DE and c not in ("que_pasa",) and all(sab.get(x) for x in memoria.datos_de_pregunta(c)) and c in (antes or {}).get("preguntado", []):
            fa.append(f"pregunta algo que ya sabe: {c}")
    # las contraseñas nunca se guardan
    for secreto in re.findall(r"(?:clave|contraseña|password|pass)\s*(?:es|:|=)\s*(\S+)", texto_usuario, re.I):
        if secreto in j.get("texto_usuario_guardar", "") or secreto in texto:
            fa.append("una contraseña llegó al texto guardado o a la respuesta")
    if j.get("senales", {}).get("contrasena_oculta") and "No compartas tu contraseña" not in texto:
        fa.append("pegó una contraseña y no se le avisó")
    # nunca cierra ni encuesta solo
    if acc.get("tipo") in ("confirmar_solucion", "encuesta") and not (memoria.confirma(texto_usuario) or memoria.afirma(texto_usuario) or memoria.puntaje_en(texto_usuario)
                                                                         or (antes or {}).get("memoria", {}).get("pendiente") in ("resolvio", "puntaje")):
        fa.append(f"cierra o encuesta sin que la persona lo confirme ({acc.get('tipo')})")
    return fa


def evaluar_turno(j: dict, esp: dict, articulos: dict) -> list[str]:
    """Compara un turno con lo que pide el guion. `esp` admite: etapa, accion, intencion, categoria, motivo, tipo, impacto, urgencia, numero, pendiente,
    animo, queja, pide_tecnico, secreto, p1, articulo, contiene, no_contiene, sabe, sin_incidencia, creada."""
    fa = []
    acc = j["accion"]
    inc = acc.get("incidencia") or {}
    def uno(nombre, obtenido, esperado):
        if isinstance(esperado, list) and isinstance(obtenido, list):
            ok = obtenido == esperado
        else:
            ok = obtenido in esperado if isinstance(esperado, (list, tuple, set)) else obtenido == esperado
        if not ok:
            fa.append(f"{nombre}: {obtenido!r} (esperado {esperado!r})")
    for clave, obtenido in (("etapa", j["etapa"]), ("intencion", j["intencion"]), ("categoria", j.get("categoria"))):
        if clave in esp:
            uno(clave, obtenido, esp[clave])
    if "accion" in esp:
        uno("accion", acc["tipo"], esp["accion"])
    for clave, campo in (("motivo", "motivo"), ("tipo", "tipo"), ("impacto", "impacto"), ("urgencia", "urgencia")):
        if clave in esp:
            uno(f"incidencia.{clave}", inc.get(campo), esp[clave])
    if "numero" in esp:
        uno("accion.numero", acc.get("numero"), esp["numero"])
    if "pendiente" in esp:
        uno("memoria.pendiente", j["memoria"]["pendiente"], esp["pendiente"])
    for clave, obtenido in (("animo", j["senales"]["animo"]), ("queja", j["senales"]["queja"]), ("pide_tecnico", j["senales"]["pide_tecnico"]), ("secreto", j["senales"]["contrasena_oculta"])):
        if clave in esp:
            uno(f"senales.{clave}", obtenido, esp[clave])
    if "p1" in esp:
        uno("p1", j["analisis"]["p1"], esp["p1"])
    if "articulo" in esp:
        uno("articulo usado", (j["articulos_usados"] or [None])[0], esp["articulo"])
    if "sin_incidencia" in esp and esp["sin_incidencia"] and inc:
        fa.append("no debía proponer una incidencia")
    if "creada" in esp:
        uno("incidencia creada", bool(j["_creada"]), esp["creada"])
    texto = norm(j["_texto"])
    for frase in esp.get("contiene", []):
        if norm(frase) not in texto:
            fa.append(f"la respuesta debía decir «{frase}»: {j['_texto'][:140]!r}")
    for frase in esp.get("no_contiene", []):
        if norm(frase) in texto:
            fa.append(f"la respuesta no debía decir «{frase}»")
    sab = j["memoria"]["sabemos"]
    for k, v in (esp.get("sabe") or {}).items():
        uno(f"memoria.sabemos.{k}", sab.get(k), v)
    return fa


# ---------------------------------------------------------------------------
# Los guiones. Cada turno: ("lo que escribe", {lo que se espera}).

G = "guia"
CONVERSACIONES: list[dict] = [
    # ===== Falla resuelta con guía ========================================================================
    {"id": "C01", "titulo": "Correo que no abre: pregunta, guía y cierre confirmado con encuesta", "turnos": [
        ("el correo no me carga desde temprano", {"etapa": ["diagnostico", "guia"], "intencion": "reportar_falla", "categoria": "correo", "accion": "ninguna", "sabe": {"desde": "desde temprano"}}),
        ("uso Outlook", {"etapa": "guia", "intencion": "aportar_dato", "articulo": "KB-001", "pendiente": "resolvio", "contiene": ["Prueba los pasos que te envié"], "sabe": {"aplicacion": "Outlook"}}),
        ("ya está, funcionó perfecto, gracias", {"etapa": "cierre", "accion": "confirmar_solucion", "pendiente": "puntaje", "contiene": ["del 1 al 5"]}),
        ("5", {"etapa": "encuesta", "accion": "encuesta"}),
    ]},
    {"id": "C02", "titulo": "Impresora: la sede ya se sabe por el perfil, se pregunta el piso", "turnos": [
        ("la impresora que está en el piso 3 no saca nada", {"etapa": ["diagnostico", "guia"], "categoria": "impresoras", "sabe": {"piso": "piso 3"}}),
        ("es la HP-Piso3", {"etapa": "guia", "articulo": "KB-011", "pendiente": "resolvio"}),
        ("listo, ya imprime", {"etapa": "cierre", "accion": "confirmar_solucion", "sin_incidencia": True}),
        ("4", {"etapa": "encuesta", "accion": "encuesta"}),
    ]},
    {"id": "C03", "titulo": "WiFi lento: guía y «sí» a ¿quedó resuelto?", "turnos": [
        ("el wifi de mi piso va muy lento desde el mediodía", {"etapa": ["diagnostico", "guia"], "categoria": "red_wifi"}),
        ("por wifi, no por cable", {"etapa": "guia", "articulo": "KB-009", "pendiente": "resolvio"}),
        ("sí", {"etapa": "cierre", "accion": "confirmar_solucion", "intencion": "confirmar_solucion"}),
    ]},
    {"id": "C04", "titulo": "Teams sin audio: guía directa", "turnos": [
        ("en el teams no se escucha el audio de las reuniones", {"etapa": ["diagnostico", "guia"], "categoria": "software_oficina"}),
        ("solo me pasa a mí", {"etapa": "guia", "articulo": "KB-017", "sabe": {"impacto": "persona"}}),
        ("ahora sí escucho, se arregló", {"etapa": "cierre", "accion": "confirmar_solucion"}),
    ]},
    {"id": "C05", "titulo": "Olvidé mi contraseña: guía de autoservicio y cierre", "turnos": [
        ("olvidé mi contraseña", {"etapa": ["diagnostico", "guia"], "intencion": "restablecer_clave", "categoria": "cuentas_accesos"}),
        ("de windows", {"etapa": "guia", "articulo": "KB-004", "contiene": ["No compartas"] if False else []}),
        ("ya pude entrar, gracias", {"etapa": "cierre", "accion": "confirmar_solucion"}),
    ]},
    {"id": "C06", "titulo": "VPN que no conecta desde casa: guía y cierre", "turnos": [
        ("la VPN no me deja entrar desde mi casa", {"etapa": ["diagnostico", "guia"], "categoria": "vpn"}),
        ("me sale error de autenticación", {"etapa": "guia", "articulo": "KB-007", "sabe": {"mensaje_error": "error de autenticación"}}),
        ("con eso ya me conecta", {"etapa": "cierre", "accion": "confirmar_solucion"}),
    ]},
    {"id": "C07", "titulo": "Equipo lento: la persona ya probó reiniciar, la guía lo salta", "turnos": [
        ("mi computadora está muy lenta y se queda pegada, ya reinicié y no cambió nada", {"etapa": ["diagnostico", "guia"], "categoria": "equipo", "sabe": {"pasos_probados": ["reiniciar el equipo"]},
                                                                                              "contiene": ["Salté lo que ya hiciste", "reiniciar el equipo"], "no_contiene": ["Guarda tu trabajo y reinicia"]}),
        ("mejoró, ya quedó", {"etapa": "cierre", "accion": "confirmar_solucion"}),
    ]},
    {"id": "C08", "titulo": "Excel que se cierra solo: la persona da todos los datos de golpe y no se le pregunta nada de eso", "turnos": [
        ("el excel se cierra solo cuando abro un archivo grande, desde ayer, mi equipo es PC-CONT-07, solo me pasa a mí",
         {"etapa": ["diagnostico", "guia"], "categoria": "software_oficina", "sabe": {"equipo": "PC-CONT-07", "impacto": "persona", "aplicacion": "Excel"}, "no_contiene": ["código de tu equipo", "Desde cuándo"]}),
    ]},

    # ===== Falla que acaba en incidencia =====================================================================
    {"id": "C09", "titulo": "Correo: guía, sigue igual, incidencia con guía agotada; después aporta un dato y pregunta por el estado", "turnos": [
        ("no me abre el correo, uso Outlook, desde esta mañana", {"etapa": "guia", "articulo": "KB-001", "pendiente": "resolvio"}),
        ("sigue igual", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "guia_agotada", "tipo": "incidente", "creada": True,
                         "contiene": ["Registré INC-"]}),
        ("el mensaje que sale es 0x800CCC0E", {"etapa": "seguimiento", "accion": "agregar_dato", "numero": "INC-000142", "sabe": {"mensaje_error": "0x800CCC0E"}}),
        ("¿cómo va mi ticket?", {"etapa": "consulta_estado", "accion": "consultar_estado", "numero": "INC-000142"}),
    ]},
    {"id": "C10", "titulo": "Impresora: guía, «no funcionó», incidencia y la persona agradece", "turnos": [
        ("la impresora no imprime, es la del piso 2, sede Surco", {"etapa": ["diagnostico", "guia"], "categoria": "impresoras", "sabe": {"sede": "Surco", "piso": "piso 2"}}),
        ("se llama HP-Piso2", {"etapa": "guia", "articulo": "KB-011"}),
        ("no funcionó", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "guia_agotada", "categoria": "impresoras"}),
        ("gracias", {"accion": "ninguna", "intencion": "agradecer", "sin_incidencia": True}),
    ]},
    {"id": "C11", "titulo": "Sin artículo: se pregunta lo que falta y se abre la incidencia (sin_articulo)", "turnos": [
        ("el aire acondicionado de la oficina no enfría", {"etapa": "diagnostico", "intencion": "reportar_falla", "accion": "ninguna"}),
        ("en el segundo piso", {"etapa": ["diagnostico", "incidencia"]}),
        ("desde hace dos días", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "sin_articulo", "categoria": "otro"}),
    ]},
    {"id": "C12", "titulo": "Sistema interno: guía y «sigue igual»", "turnos": [
        ("el sistema de ventas se queda en pantalla blanca y no entra", {"etapa": ["diagnostico", "guia"], "categoria": "sistema_interno"}),
        ("me aparece error 500", {"etapa": ["guia", "diagnostico"], "sabe": {"mensaje_error": "error 500"}}),
        ("a todos en mi piso les pasa lo mismo", {"etapa": "guia", "accion": "ninguna", "sabe": {"impacto": "area"}}),
        ("hice los pasos y nada", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "guia_agotada", "impacto": "area"}),
    ]},
    {"id": "C13", "titulo": "«No» a ¿quedó resuelto? abre la incidencia", "turnos": [
        ("no me conecta la VPN, me sale un error", {"etapa": ["diagnostico", "guia"], "categoria": "vpn"}),
        ("error 619", {"etapa": "guia", "articulo": "KB-007", "pendiente": "resolvio"}),
        ("no", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "guia_agotada"}),
    ]},
    {"id": "C14", "titulo": "Ya hay una incidencia abierta del mismo síntoma: se agrega, no se crea otra", "perfil_abiertas": [INC_CORREO], "turnos": [
        ("no me abre el correo", {"etapa": "seguimiento", "accion": "agregar_dato", "numero": "INC-000142", "sin_incidencia": True, "creada": False}),
        ("sigue igual", {"accion": "sigue_igual", "numero": "INC-000142", "creada": False}),
    ]},
    {"id": "C15", "titulo": "Dos guías sin resolver: segunda guía y luego incidencia", "turnos": [
        ("mis mensajes no salen, quedan en la bandeja de salida", {"etapa": ["diagnostico", "guia"], "categoria": "correo"}),
        ("uso Outlook", {"etapa": "guia", "articulo": "KB-002"}),
        ("me sale el código 0x800CCC0E", {"etapa": ["guia"], "sabe": {"mensaje_error": "0x800CCC0E"}}),
        ("todo sigue como estaba, no me sirvió", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "guia_agotada"}),
    ]},

    # ===== Consulta de estado =============================================================================
    {"id": "C16", "titulo": "Consulta de estado con una sola incidencia abierta", "perfil_abiertas": [INC_CORREO], "turnos": [
        ("¿qué novedades hay de mi incidencia?", {"etapa": "consulta_estado", "accion": "consultar_estado", "numero": "INC-000142", "intencion": "consultar_estado", "contiene": ["INC-000142"]}),
    ]},
    {"id": "C17", "titulo": "Consulta de estado con dos abiertas: la que nombra", "perfil_abiertas": [INC_CORREO, INC_IMPRESORA], "turnos": [
        ("qué pasó con el INC-000231", {"etapa": "consulta_estado", "accion": "consultar_estado", "numero": "INC-000231"}),
        ("¿y ya asignaron a alguien a mi caso del correo?", {"accion": "consultar_estado", "intencion": "consultar_estado"}),
    ]},
    {"id": "C18", "titulo": "Consulta de estado sin incidencias: se dice con claridad", "turnos": [
        ("¿cómo va mi ticket?", {"etapa": "consulta_estado", "accion": "consultar_estado", "numero": None, "contiene": ["No veo incidencias abiertas"]}),
    ]},

    # ===== P1 de sede ======================================================================================
    {"id": "C19", "titulo": "P1: caída del internet en toda la sede, directo a incidencia, sin guía", "turnos": [
        ("se cayó el internet en toda la sede, nadie puede trabajar", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "p1", "impacto": "sede", "urgencia": "critica",
                                                                       "p1": True, "no_contiene": ["Pruébala en orden"], "creada": True}),
    ]},
    {"id": "C20", "titulo": "P1: sistema caído para toda la empresa", "turnos": [
        ("no funciona el sistema de ventas para nadie en toda la empresa", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "p1", "impacto": "organizacion", "p1": True}),
    ]},
    {"id": "C21", "titulo": "P1 que se descubre al responder cuántos afectados hay", "turnos": [
        ("no tengo internet en mi computadora", {"etapa": ["diagnostico", "guia"], "categoria": "red_wifi"}),
        ("estoy por cable", {"etapa": ["diagnostico", "guia"]}),
        ("a todos en toda la sede, se cayó la red", {"etapa": "incidencia", "accion": "crear_incidencia", "motivo": "p1", "impacto": "sede", "p1": True}),
    ]},

    # ===== La persona pide un técnico ========================================================================
    {"id": "C22", "titulo": "Quiero hablar con un técnico, desde el primer mensaje", "turnos": [
        ("quiero hablar con un técnico", {"etapa": "incidencia", "accion": "pedir_tecnico", "motivo": "pidio_tecnico", "pide_tecnico": True, "intencion": "pedir_tecnico"}),
    ]},
    {"id": "C23", "titulo": "En plena guía pide una persona: se respeta", "turnos": [
        ("no me abre el correo, uso Outlook, desde esta mañana", {"etapa": "guia", "articulo": "KB-001"}),
        ("mejor pásame con una persona", {"etapa": "incidencia", "accion": "pedir_tecnico", "motivo": "pidio_tecnico", "pide_tecnico": True}),
    ]},
    {"id": "C24", "titulo": "Pide un técnico con una incidencia abierta: se suma a esa", "perfil_abiertas": [INC_CORREO], "turnos": [
        ("necesito que me llame un técnico", {"accion": "pedir_tecnico", "numero": "INC-000142", "sin_incidencia": True, "creada": False, "pide_tecnico": True}),
    ]},

    # ===== Contraseña pegada =================================================================================
    {"id": "C25", "titulo": "Pega su contraseña: se oculta, se avisa y no se guarda", "turnos": [
        ("no puedo entrar, mi clave es Perro123", {"secreto": True, "contiene": ["No compartas tu contraseña por aquí; ya la oculté"], "no_contiene": ["Perro123"]}),
    ]},
    {"id": "C26", "titulo": "Pega 'password:' a mitad de la conversación", "turnos": [
        ("no me abre el correo, uso Outlook", {"etapa": ["diagnostico", "guia"]}),
        ("password: Abc#1234x, mira si te sirve", {"secreto": True, "contiene": ["No compartas tu contraseña"], "no_contiene": ["Abc#1234x"]}),
    ]},
    {"id": "C27", "titulo": "Pega un token", "turnos": [
        ("mi token es eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U y no entra", {"secreto": True, "no_contiene": ["eyJhbGci"]}),
    ]},

    # ===== Cambio de tema =====================================================================================
    {"id": "C28", "titulo": "Del correo a la impresora: caso nuevo, ficha nueva", "turnos": [
        ("no me abre el correo, uso Outlook", {"etapa": ["diagnostico", "guia"], "categoria": "correo"}),
        ("mejor olvídalo, ahora la impresora del piso 2 no imprime", {"etapa": ["diagnostico", "guia"], "categoria": "impresoras", "sabe": {"aplicacion": None, "piso": "piso 2"}}),
    ]},
    {"id": "C29", "titulo": "Con una incidencia abierta del correo, reporta otro problema (teléfono): no se mezcla", "perfil_abiertas": [INC_CORREO], "turnos": [
        ("mi teléfono del escritorio no tiene tono", {"categoria": "telefonia", "etapa": ["diagnostico", "guia"], "accion": "ninguna", "creada": False, "no_contiene": ["INC-000142"]}),
    ]},

    # ===== Solicitudes =======================================================================================
    {"id": "C30", "titulo": "Solicitud de acceso concreta: incidencia de tipo solicitud", "turnos": [
        ("necesito acceso a la carpeta compartida de Logística", {"etapa": "incidencia", "accion": "crear_incidencia", "tipo": "solicitud", "intencion": "solicitar_acceso", "no_contiene": ["Pruébala"]}),
    ]},
    {"id": "C31", "titulo": "Solicitud de equipo concreta", "turnos": [
        ("requiero una laptop nueva para trabajar en remoto", {"etapa": "incidencia", "accion": "crear_incidencia", "tipo": "solicitud", "intencion": "solicitar_equipo"}),
    ]},
    {"id": "C32", "titulo": "Solicitud vaga: se pregunta qué acceso y luego se registra", "turnos": [
        ("necesito acceso", {"etapa": "diagnostico", "intencion": "solicitar_acceso", "pendiente": "que_solicita"}),
        ("al sistema de planillas", {"etapa": "incidencia", "accion": "crear_incidencia", "tipo": "solicitud"}),
    ]},

    # ===== Quejas ==============================================================================================
    {"id": "C33", "titulo": "Queja con una incidencia abierta: constancia para el supervisor", "perfil_abiertas": [INC_CORREO], "turnos": [
        ("es la tercera vez que reporto esto y nadie hace nada, pésima atención", {"intencion": "queja", "queja": True, "animo": "muy_negativo", "numero": "INC-000142", "etapa": "seguimiento",
                                                                                     "contiene": ["queja"], "creada": False}),
    ]},
    {"id": "C34", "titulo": "Queja sin incidencia: se ofrece un técnico y el «sí» lo pide", "turnos": [
        ("estoy muy molesto, nadie me responde", {"intencion": "queja", "queja": True, "pendiente": "ofrecer_tecnico", "contiene": ["¿Quieres que un técnico te contacte?"]}),
        ("sí", {"accion": "pedir_tecnico", "motivo": "pidio_tecnico", "pide_tecnico": True}),
    ]},

    # ===== Varios ===============================================================================================
    {"id": "C35", "titulo": "Saluda y después cuenta su problema", "turnos": [
        ("hola buenas tardes", {"etapa": "recepcion", "intencion": "saludo", "accion": "ninguna", "contiene": ["Hola, Ana"]}),
        ("no puedo imprimir", {"etapa": ["diagnostico", "guia"], "categoria": "impresoras"}),
    ]},
    {"id": "C36", "titulo": "Fuera de alcance: se dice qué sí se hace", "turnos": [
        ("dime algo gracioso", {"intencion": "fuera_de_alcance", "etapa": "recepcion", "accion": "ninguna", "contiene": ["soporte técnico"]}),
    ]},
    {"id": "C37", "titulo": "Mensajes ilegibles: se pide repetir y a la segunda se ofrece un técnico", "turnos": [
        ("asdkjh qwe", {"etapa": "recepcion", "accion": "ninguna", "contiene": ["No te entendí"], "pendiente": "que_pasa"}),
        ("zzzz xxxx", {"contiene": ["No te entendí", "¿Quieres que un técnico te contacte?"], "pendiente": "ofrecer_tecnico"}),
        ("sí", {"accion": "pedir_tecnico", "motivo": "pidio_tecnico"}),
    ]},
    {"id": "C38", "titulo": "Agradece sin más: de nada", "turnos": [
        ("gracias por todo", {"etapa": "recepcion", "intencion": "agradecer", "accion": "ninguna", "contiene": ["De nada"]}),
    ]},
    {"id": "C39", "titulo": "Impresora con datos de golpe: no se repregunta nada de lo dicho", "turnos": [
        ("la impresora HP-Piso3 de la sede Surco, tercer piso, no imprime desde ayer y nadie más puede imprimir",
         {"categoria": "impresoras", "sabe": {"impresora": "HP-Piso3", "sede": "Surco", "piso": "piso 3"}, "no_contiene": ["En qué sede", "En qué piso", "Cómo se llama la impresora"]}),
    ]},
    {"id": "C40", "titulo": "Cambia el cierre: tras la encuesta, un problema nuevo empieza un caso nuevo", "turnos": [
        ("el wifi se me va cada rato", {"etapa": ["diagnostico", "guia"], "categoria": "red_wifi"}),
        ("desde hace dos días", {"etapa": "guia", "articulo": "KB-009"}),
        ("listo, ya quedó", {"etapa": "cierre", "accion": "confirmar_solucion"}),
        ("4", {"etapa": "encuesta", "accion": "encuesta"}),
        ("ahora no me abre el excel", {"etapa": ["diagnostico", "guia"], "categoria": "software_oficina", "sabe": {"tipo_red": None}}),
    ]},
    {"id": "C41", "titulo": "El pedido de un técnico durante la encuesta", "turnos": [
        ("no me abre el correo, uso Outlook, desde esta mañana", {"etapa": "guia"}),
        ("ya funcionó", {"etapa": "cierre", "accion": "confirmar_solucion", "pendiente": "puntaje"}),
        ("mejor quiero hablar con un técnico", {"accion": "pedir_tecnico", "pide_tecnico": True}),
    ]},
    {"id": "C42", "titulo": "Un acuse corto no cambia nada", "turnos": [
        ("mi pc está lenta", {"etapa": ["diagnostico", "guia"], "categoria": "equipo"}),
        ("ok", {"etapa": ["diagnostico", "guia"], "accion": "ninguna"}),
    ]},
]
