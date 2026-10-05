"""Pruebas de la máquina de etapas de atención (app/etapas.py). Sin red ni modelos. Se ejecutan al construir la imagen y a mano:

    python -m app.prueba_etapas

Cada caso: la situación (etapa, intención del clasificador, confianza, mensaje y contexto) y lo que debe decidirse
(etapa, acción, motivo de la incidencia, si se guía, si se pregunta…). Lo que nunca debe pasar tiene su propio bloque.
"""
from __future__ import annotations

import sys

from . import memoria as M
from .etapas import decidir, numero_en, pide_tecnico, pregunta_por_estado, es_queja

fallos: list[str] = []
total = 0

ART = {"clave": "KB-001", "score": 0.92, "suficiente": True}
ART_MEDIO = {"clave": "KB-001", "score": 0.86, "suficiente": False}
INC = {"numero": "INC-000142", "estado": "en_curso", "titulo": "Outlook no recibe correos", "categoria": "correo", "tecnico": "Luis Paz"}
INC_RESUELTA = {**INC, "estado": "resuelta"}


def mem(**kw) -> dict:
    m = M.nueva()
    top = {k: kw.pop(k) for k in list(kw) if k in ("intentos_guia", "turnos_guia", "articulos_mostrados", "preguntado", "categoria", "intencion_caso", "pendiente")}
    m.update(top)
    m["sabemos"].update(kw)
    return m


def caso(nombre, etapa, intent, conf, msg, esperado: dict, **ctx):
    global total
    total += 1
    d = decidir(etapa, intent, conf, msg, **ctx)
    mal = {k: (d.get(k), v) for k, v in esperado.items() if d.get(k) != v}
    if mal:
        fallos.append(f"   ✗ {nombre}: " + "; ".join(f"{k}={o!r} (esperado {e!r})" for k, (o, e) in mal.items()) + f"\n       bitácora: {d['motivo']}")
    elif not d["bitacora"] and esperado.get("etapa") not in (None,):
        fallos.append(f"   ✗ {nombre}: sin bitácora")


# --- Recepción y diagnóstico ----------------------------------------------------------------------------------
caso("saludo no cambia nada", "recepcion", "saludo", 0.99, "hola buenas", {"etapa": "recepcion", "accion": "ninguna", "guia": False})
caso("falla con artículo suficiente: guía", "recepcion", "reportar_falla", 0.93, "no me abre el correo", {"etapa": "guia", "guia": True, "accion": "ninguna"}, articulo=ART)
caso("falla con artículo a medias y preguntas: diagnóstico", "recepcion", "reportar_falla", 0.93, "no me abre el correo",
     {"etapa": "diagnostico", "preguntar": True, "guia": False}, articulo=ART_MEDIO, hay_pregunta=True)
caso("falla con artículo a medias y sin preguntas: guía con el mejor", "diagnostico", "aportar_dato", 0.9, "desde ayer",
     {"etapa": "guia", "guia": True}, articulo=ART_MEDIO, hay_pregunta=False, pendiente="desde", respondio_pendiente=True)
caso("falla sin artículo y con preguntas: diagnóstico", "recepcion", "reportar_falla", 0.9, "se fue la luz",
     {"etapa": "diagnostico", "preguntar": True}, hay_pregunta=True)
caso("falla sin artículo y sin preguntas: incidencia sin_articulo", "diagnostico", "reportar_falla", 0.9, "se fue la luz",
     {"etapa": "incidencia", "accion": "crear_incidencia", "motivo_incidencia": "sin_articulo", "incidencia_tipo": "incidente"})
caso("responder la pendiente es aportar un dato (aunque el clasificador diga otra cosa)", "diagnostico", "reportar_falla", 0.8, "es la PC-CONT-07",
     {"intencion": "aportar_dato", "etapa": "guia", "guia": True}, pendiente="equipo", respondio_pendiente=True, articulo=ART)
caso("restablecer clave con artículo: guía", "recepcion", "restablecer_clave", 0.9, "olvidé mi contraseña", {"etapa": "guia", "guia": True}, articulo=ART)
caso("restablecer clave sin artículo: incidencia", "diagnostico", "restablecer_clave", 0.9, "olvidé mi contraseña",
     {"etapa": "incidencia", "accion": "crear_incidencia", "motivo_incidencia": "sin_articulo"})
caso("falla con confianza baja: no se mueve y no se entendió", "recepcion", "reportar_falla", 0.3, "mmm", {"etapa": "recepcion", "entendido": False})
caso("falla con confianza media se atiende igual", "recepcion", "reportar_falla", 0.5, "el correo anda raro", {"etapa": "guia", "guia": True}, articulo=ART)

# --- Solicitudes ------------------------------------------------------------------------------------------------
caso("acceso concreto: incidencia de tipo solicitud", "recepcion", "solicitar_acceso", 0.9, "necesito acceso a la carpeta de Contabilidad",
     {"etapa": "incidencia", "accion": "crear_incidencia", "incidencia_tipo": "solicitud", "guia": False}, es_solicitud_concreta=True, articulo=ART)
caso("acceso sin decir qué: se pregunta", "recepcion", "solicitar_acceso", 0.9, "necesito acceso", {"etapa": "diagnostico", "preguntar": True}, hay_pregunta=True)
caso("acceso sin preguntas que hacer: incidencia", "diagnostico", "solicitar_acceso", 0.9, "necesito acceso", {"etapa": "incidencia", "incidencia_tipo": "solicitud"})
caso("equipo concreto: incidencia de tipo solicitud", "recepcion", "solicitar_equipo", 0.9, "necesito una laptop nueva",
     {"etapa": "incidencia", "accion": "crear_incidencia", "incidencia_tipo": "solicitud"}, mem=mem(solicitud="necesito una laptop nueva"))
caso("una solicitud nunca recibe guía de artículo", "recepcion", "solicitar_equipo", 0.9, "quiero un mouse", {"guia": False}, es_solicitud_concreta=True, articulo=ART)

# --- P1 sin guía ------------------------------------------------------------------------------------------------
caso("P1: caída que afecta a la sede, directo a incidencia", "recepcion", "reportar_falla", 0.95, "se cayó el internet en toda la sede",
     {"etapa": "incidencia", "accion": "crear_incidencia", "motivo_incidencia": "p1", "p1": True, "urgencia_sugerida": "critica", "guia": False},
     mem=mem(impacto="sede", caida=True), articulo=ART)
caso("P1: toda la organización", "recepcion", "reportar_falla", 0.95, "no hay sistema en toda la empresa",
     {"etapa": "incidencia", "motivo_incidencia": "p1", "p1": True, "urgencia_sugerida": "critica"}, mem=mem(impacto="organizacion", caida=True))
caso("P1: afecta a la sede pero no es caída: sin guía, urgencia alta", "recepcion", "reportar_falla", 0.9, "el sistema va lento en toda la sede",
     {"etapa": "incidencia", "motivo_incidencia": "p1", "urgencia_sugerida": "alta", "guia": False}, mem=mem(impacto="sede"), articulo=ART)
caso("afecta solo al área: no es P1, se guía", "recepcion", "reportar_falla", 0.9, "a todos en mi piso les pasa", {"etapa": "guia", "p1": False, "guia": True},
     mem=mem(impacto="area"), articulo=ART)
caso("afecta a una persona: se guía", "recepcion", "reportar_falla", 0.9, "solo me pasa a mí", {"etapa": "guia", "p1": False},
     mem=mem(impacto="persona"), articulo=ART)
caso("P1 en medio del diagnóstico (lo dice al responder)", "diagnostico", "aportar_dato", 0.9, "sí, a toda la sede",
     {"etapa": "incidencia", "motivo_incidencia": "p1", "p1": True}, mem=mem(impacto="sede", caida=True), pendiente="afecta_otros", respondio_pendiente=True, articulo=ART)
caso("una solicitud con impacto de sede no es P1", "recepcion", "solicitar_acceso", 0.9, "necesito acceso para toda la sede", {"p1": False, "incidencia_tipo": "solicitud"},
     mem=mem(impacto="sede"), es_solicitud_concreta=True)

# --- Pedir un técnico: siempre ----------------------------------------------------------------------------------
caso("pedir técnico sin incidencia abierta: se propone una", "recepcion", "pedir_tecnico", 0.95, "quiero hablar con un técnico",
     {"etapa": "incidencia", "accion": "pedir_tecnico", "motivo_incidencia": "pidio_tecnico", "pide_tecnico": True})
for msg in ("quiero hablar con un técnico", "pásame con una persona", "que me llame alguien de sistemas", "no quiero un bot, quiero un humano",
            "necesito soporte presencial", "¿puede venir un técnico a mi escritorio?", "escalen mi caso a un técnico", "prefiero que me atienda una persona"):
    caso(f"«{msg}» se respeta aunque el clasificador diga otra cosa", "guia", "reportar_falla", 0.9, msg, {"intencion": "pedir_tecnico", "accion": "pedir_tecnico", "pide_tecnico": True}, articulo=ART)
caso("pedir técnico con confianza baja del clasificador, igual", "recepcion", "fuera_de_alcance", 0.2, "quiero hablar con un tecnico", {"accion": "pedir_tecnico", "etapa": "incidencia"})
caso("pedir técnico con una incidencia abierta: se suma a esa", "seguimiento", "pedir_tecnico", 0.9, "quiero hablar con un técnico",
     {"etapa": "seguimiento", "accion": "pedir_tecnico", "numero": "INC-000142", "motivo_incidencia": None}, abiertas=[INC])
caso("pedir técnico en pleno P1", "incidencia", "reportar_falla", 0.9, "pásenme con alguien ya", {"accion": "pedir_tecnico"}, mem=mem(impacto="sede"))
caso("pedir técnico en la encuesta también", "cierre", "agradecer", 0.9, "mejor quiero hablar con un técnico", {"accion": "pedir_tecnico"}, pendiente="puntaje")
caso("«sí» a ¿quieres que un técnico te contacte?", "recepcion", "saludo", 0.4, "sí", {"intencion": "pedir_tecnico", "accion": "pedir_tecnico"}, pendiente="ofrecer_tecnico")
caso("«no» a ¿quieres que un técnico te contacte? no lo pide", "recepcion", "saludo", 0.4, "no", {"accion": "ninguna"}, pendiente="ofrecer_tecnico")
caso("mencionar al técnico no es pedirlo", "seguimiento", "agradecer", 0.9, "gracias al técnico por venir", {"accion": "ninguna", "pide_tecnico": False}, abiertas=[INC])
caso("«el técnico ya lo arregló» sí confirma la solución", "seguimiento", "agradecer", 0.9, "gracias, el técnico ya lo arregló", {"accion": "confirmar_solucion", "etapa": "cierre", "numero": "INC-000142"}, abiertas=[INC_RESUELTA])

# --- Una sola incidencia por síntoma ------------------------------------------------------------------------------
caso("mismo síntoma con incidencia abierta: se agrega a esa", "recepcion", "reportar_falla", 0.95, "no me abre el correo",
     {"etapa": "seguimiento", "accion": "agregar_dato", "numero": "INC-000142"}, abiertas=[INC], mismo_sintoma=INC, articulo=ART)
caso("mismo síntoma, ahora dice que afecta a toda la sede", "seguimiento", "reportar_falla", 0.95, "no me abre el correo, a toda la sede",
     {"accion": "agregar_dato", "numero": "INC-000142", "p1": False}, abiertas=[INC], mismo_sintoma=INC, mem=mem(impacto="sede"))
caso("otro síntoma con una incidencia abierta: caso nuevo", "seguimiento", "reportar_falla", 0.95, "la impresora no imprime",
     {"etapa": "guia", "accion": "ninguna", "guia": True}, abiertas=[INC], mismo_sintoma=None, articulo=ART, cambio_tema=True)
caso("etapa «incidencia» con la incidencia ya creada: seguimiento", "incidencia", "aportar_dato", 0.9, "es la PC-CONT-07",
     {"etapa": "seguimiento", "accion": "agregar_dato", "numero": "INC-000142", "dato": {"clave": "equipo", "valor": "PC-CONT-07"}},
     abiertas=[INC], mismo_sintoma=INC, datos_nuevos={"equipo": "PC-CONT-07"}, respondio_pendiente=False)

# --- Guía: sigue igual, agotada, confirmada ---------------------------------------------------------------------
caso("«sigue igual» tras la guía: incidencia con guía agotada", "guia", "sigue_igual", 0.95, "sigue igual",
     {"etapa": "incidencia", "accion": "crear_incidencia", "motivo_incidencia": "guia_agotada"}, mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1))
for msg in ("hice los pasos y nada", "no funcionó", "sigue sin abrir", "lo mismo de antes", "el problema persiste", "ni así"):
    caso(f"«{msg}» tras la guía (aunque el clasificador dude)", "guia", "reportar_falla", 0.6, msg,
         {"intencion": "sigue_igual", "etapa": "incidencia", "motivo_incidencia": "guia_agotada"}, mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1))
caso("«no» a ¿quedó resuelto?: guía agotada", "guia", "saludo", 0.3, "no", {"intencion": "sigue_igual", "motivo_incidencia": "guia_agotada"},
     pendiente="resolvio", mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1))
caso("«sigue igual» y ya había una abierta del mismo síntoma: se agrega", "guia", "sigue_igual", 0.95, "sigue igual",
     {"etapa": "seguimiento", "accion": "sigue_igual", "numero": "INC-000142"}, mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1), abiertas=[INC], mismo_sintoma=INC)
caso("«sigue igual» con una incidencia en curso: avisa a esa", "seguimiento", "sigue_igual", 0.95, "sigue igual",
     {"etapa": "seguimiento", "accion": "sigue_igual", "numero": "INC-000142"}, abiertas=[INC])
caso("«sigue igual» con la incidencia resuelta: el backend la reabre", "seguimiento", "sigue_igual", 0.95, "sigue igual",
     {"accion": "sigue_igual", "numero": "INC-000142"}, abiertas=[INC_RESUELTA])
caso("«sigue igual» sin ningún caso: se pregunta de qué", "recepcion", "sigue_igual", 0.95, "sigue igual", {"etapa": "recepcion", "accion": "ninguna"})
caso("dos guías sin resolver y aporta otro dato: incidencia", "guia", "aportar_dato", 0.9, "me sale el error 0x80", {"etapa": "incidencia", "motivo_incidencia": "guia_agotada"},
     mem=mem(articulos_mostrados=["KB-001", "KB-002"], intentos_guia=2), datos_nuevos={"mensaje_error": "0x80"})
caso("aporta un dato y hay otro artículo que encaja: segundo intento", "guia", "aportar_dato", 0.9, "me sale error 0x80", {"etapa": "guia", "guia": True},
     mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1), articulo={"clave": "KB-002", "score": 0.92, "suficiente": True}, datos_nuevos={"mensaje_error": "0x80"})
caso("aporta un dato sin artículo nuevo: recuerda probar los pasos", "guia", "aportar_dato", 0.9, "uso Windows 11", {"etapa": "guia", "accion": "ninguna", "guia": False},
     mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1))
caso("demasiados turnos en la guía sin resolver: incidencia", "guia", "aportar_dato", 0.9, "uso Windows 11", {"etapa": "incidencia", "motivo_incidencia": "guia_agotada"},
     mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1, turnos_guia=2))
caso("«ya funcionó» tras la guía: cierre confirmado", "guia", "confirmar_solucion", 0.95, "ya funcionó, gracias", {"etapa": "cierre", "accion": "confirmar_solucion"},
     mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1))
for msg in ("listo, ya quedó", "ahora sí abre el correo", "ya pude imprimir", "se solucionó, gracias", "ya está resuelto"):
    caso(f"«{msg}» tras la guía (aunque el clasificador dude)", "guia", "agradecer", 0.5, msg, {"intencion": "confirmar_solucion", "etapa": "cierre", "accion": "confirmar_solucion"},
         mem=mem(articulos_mostrados=["KB-001"]))
caso("«sí» a ¿quedó resuelto?: cierre", "guia", "saludo", 0.3, "sí", {"etapa": "cierre", "accion": "confirmar_solucion"}, pendiente="resolvio", mem=mem(articulos_mostrados=["KB-001"]))
caso("«ya funcionó» con la incidencia en curso: cierre confirmado con su número", "seguimiento", "confirmar_solucion", 0.95, "ya funcionó",
     {"etapa": "cierre", "accion": "confirmar_solucion", "numero": "INC-000142"}, abiertas=[INC_RESUELTA])
caso("«ya funcionó» sin nada abierto: no se cierra nada", "recepcion", "confirmar_solucion", 0.95, "ya funcionó",
     {"etapa": "recepcion", "accion": "ninguna"})
caso("«no funcionó» no es confirmar", "guia", "confirmar_solucion", 0.8, "no funcionó", {"intencion": "sigue_igual"}, mem=mem(articulos_mostrados=["KB-001"]))

# --- Encuesta y cierre --------------------------------------------------------------------------------------------
caso("la nota cierra el caso con la encuesta", "cierre", "agradecer", 0.5, "5", {"etapa": "encuesta", "accion": "encuesta", "puntaje": 5, "dato": {"clave": "puntaje", "valor": "5"}}, pendiente="puntaje")
caso("«le doy un 4»", "cierre", "saludo", 0.5, "le doy un 4", {"etapa": "encuesta", "accion": "encuesta", "puntaje": 4}, pendiente="puntaje")
caso("«excelente» vale 5", "cierre", "agradecer", 0.5, "excelente", {"etapa": "encuesta", "accion": "encuesta", "puntaje": 5}, pendiente="puntaje")
caso("en el cierre, otro problema: caso nuevo", "cierre", "reportar_falla", 0.95, "ahora la impresora no imprime", {"etapa": "guia", "guia": True, "accion": "ninguna"},
     pendiente="", articulo=ART)
caso("tras la encuesta, un mensaje nuevo empieza un caso nuevo", "encuesta", "reportar_falla", 0.95, "no me abre el correo", {"etapa": "guia", "guia": True}, articulo=ART)
caso("tras la encuesta, un saludo vuelve a recepción", "encuesta", "saludo", 0.99, "hola", {"etapa": "recepcion"})

# --- Consultar estado ---------------------------------------------------------------------------------------------
caso("consulta con una incidencia abierta", "recepcion", "consultar_estado", 0.95, "¿cómo va mi ticket?", {"etapa": "consulta_estado", "accion": "consultar_estado", "numero": "INC-000142"}, abiertas=[INC])
caso("consulta con el número", "recepcion", "consultar_estado", 0.95, "qué pasó con el INC-000231", {"accion": "consultar_estado", "numero": "INC-000231"},
     abiertas=[INC, {**INC, "numero": "INC-000231"}])
caso("consulta sin incidencias: la acción sigue, sin número", "recepcion", "consultar_estado", 0.95, "cómo va mi incidencia", {"accion": "consultar_estado", "numero": None})
caso("consulta aunque el clasificador diga otra cosa", "recepcion", "solicitar_acceso", 0.5, "cómo va mi ticket", {"intencion": "consultar_estado", "accion": "consultar_estado"}, abiertas=[INC])
caso("consulta en plena guía", "guia", "reportar_falla", 0.6, "¿ya asignaron a alguien a mi caso?", {"intencion": "consultar_estado", "accion": "consultar_estado"}, abiertas=[INC])
caso("tras consultar, un problema nuevo se atiende", "consulta_estado", "reportar_falla", 0.95, "ahora no imprime", {"etapa": "guia", "guia": True}, articulo=ART)

# --- Quejas y cortesías ---------------------------------------------------------------------------------------------
caso("queja con incidencia abierta: seguimiento y constancia", "seguimiento", "queja", 0.95, "es la tercera vez que reporto y nadie hace nada", {"etapa": "seguimiento", "numero": "INC-000142", "accion": "ninguna"}, abiertas=[INC])
caso("queja sin incidencia: se ofrece un técnico", "recepcion", "queja", 0.95, "pésima atención", {"etapa": "recepcion", "accion": "ninguna", "ofrecer_tecnico": True})
caso("queja por palabras aunque el clasificador diga otra cosa", "recepcion", "reportar_falla", 0.6, "inaceptable, nadie me responde", {"intencion": "queja"})
caso("agradecer en la guía no cierra nada", "guia", "agradecer", 0.95, "gracias", {"etapa": "guia", "accion": "ninguna"}, mem=mem(articulos_mostrados=["KB-001"]))
caso("agradecer en recepción", "recepcion", "agradecer", 0.95, "gracias, eso era todo", {"etapa": "recepcion", "accion": "ninguna"})
caso("acuse corto «ok» sin pregunta pendiente", "guia", "saludo", 0.4, "ok", {"intencion": "agradecer", "etapa": "guia"}, mem=mem(articulos_mostrados=["KB-001"]))
caso("fuera de alcance", "recepcion", "fuera_de_alcance", 0.95, "cuéntame un chiste", {"etapa": "recepcion", "accion": "ninguna"})
caso("fuera de alcance en pleno diagnóstico: no se pierde la etapa", "diagnostico", "fuera_de_alcance", 0.95, "qué hora es", {"etapa": "diagnostico"})

# --- Datos en seguimiento -------------------------------------------------------------------------------------------
caso("dato nuevo en seguimiento: se agrega a la incidencia", "seguimiento", "aportar_dato", 0.9, "es la PC-CONT-07",
     {"accion": "agregar_dato", "numero": "INC-000142", "dato": {"clave": "equipo", "valor": "PC-CONT-07"}}, abiertas=[INC], datos_nuevos={"equipo": "PC-CONT-07"})
caso("sin dato nuevo en seguimiento: nada que agregar", "seguimiento", "aportar_dato", 0.9, "sigo aquí", {"accion": "ninguna", "etapa": "seguimiento"}, abiertas=[INC])
caso("dato suelto sin caso: se pregunta qué pasa", "recepcion", "aportar_dato", 0.9, "mi equipo es la PC-CONT-07", {"etapa": "recepcion", "accion": "ninguna"})
caso("un «dato» dudoso sin pregunta ni caso es más bien el problema", "recepcion", "aportar_dato", 0.45, "mi pc tarda quince minutos en prender", {"intencion": "reportar_falla"}, articulo=ART)
caso("un dato seguro sin caso sigue siendo un dato", "recepcion", "aportar_dato", 0.95, "mi equipo es la PC-CONT-07", {"intencion": "aportar_dato"})
caso("un dato dudoso CON pregunta pendiente sigue siendo un dato", "diagnostico", "aportar_dato", 0.45, "quince minutos", {"intencion": "aportar_dato"}, pendiente="desde", respondio_pendiente=True)

# --- Lo que nunca debe pasar ---------------------------------------------------------------------------------------
for etapa in ("recepcion", "diagnostico", "guia", "incidencia", "seguimiento", "cierre", "encuesta", "consulta_estado"):
    for intent in ("reportar_falla", "saludo", "agradecer", "fuera_de_alcance", "aportar_dato", "queja"):
        d = decidir(etapa, intent, 0.9, "mensaje cualquiera", articulo=ART)
        total += 1
        if d["accion"] in ("confirmar_solucion", "encuesta"):
            fallos.append(f"   ✗ {etapa}/{intent}: nunca debe cerrar sin que lo confirme la persona ({d['accion']})")
        total += 1
        if d["etapa"] == "cierre" or d["etapa"] == "encuesta":
            fallos.append(f"   ✗ {etapa}/{intent}: llegó a {d['etapa']} sin confirmación")
for etapa in ("recepcion", "guia", "seguimiento"):
    total += 1
    d = decidir(etapa, "reportar_falla", 0.95, "algo pasa", articulo=ART, mem=mem(impacto="persona"))
    if d["accion"] == "crear_incidencia" and etapa != "seguimiento":
        fallos.append(f"   ✗ {etapa}: con un artículo suficiente y una persona afectada no se abre incidencia")
total += 1
if decidir("diagnostico", "reportar_falla", 0.9, "x", hay_pregunta=True)["accion"] == "crear_incidencia":
    fallos.append("   ✗ con preguntas por hacer no se abre incidencia sin artículo")
total += 1
d = decidir("recepcion", "reportar_falla", 0.95, "se cayó todo", mem=mem(impacto="sede", caida=True), articulo=ART)
if d["guia"]:
    fallos.append("   ✗ en un P1 nunca se entrega guía")
# El agente no decide prioridad, plazos, técnicos ni estados.
total += 1
d = decidir("recepcion", "reportar_falla", 0.95, "se cayó todo", mem=mem(impacto="sede", caida=True))
if any(k in d for k in ("prioridad", "plazo", "tecnico", "sla", "estado")):
    fallos.append(f"   ✗ la decisión no debe traer prioridad, plazo, técnico ni estado: {sorted(d)}")

# --- Reglas que dan robustez al clasificador (lo que la persona dice manda) ---------------------------------------------
caso("«se me bloqueó el usuario» es restablecer la clave aunque el clasificador diga falla", "recepcion", "reportar_falla", 0.45, "se me bloqueó el usuario",
     {"intencion": "restablecer_clave"}, articulo=ART)
caso("«olvidé la contraseña del sistema» es restablecer la clave", "recepcion", "reportar_falla", 0.5, "olvidé la contraseña del sistema de ventas", {"intencion": "restablecer_clave"})
caso("«me bota usuario o clave incorrecta» NO es restablecer: es una falla al entrar", "recepcion", "reportar_falla", 0.8, "me bota usuario o clave incorrecta", {"intencion": "reportar_falla"}, articulo=ART)
caso("si el clasificador está muy seguro, manda él", "recepcion", "reportar_falla", 0.95, "cambiar mi clave del correo no funciona", {"intencion": "reportar_falla"}, articulo=ART)
caso("en plena guía, otra descripción del problema es un dato más", "guia", "reportar_falla", 0.9, "me sale error de autenticación",
     {"intencion": "aportar_dato", "etapa": "guia", "accion": "ninguna", "guia": False}, mem=mem(articulos_mostrados=["KB-007"], intentos_guia=1))
caso("en plena guía, «restablecer_clave» por un error NO es otro problema", "guia", "restablecer_clave", 0.52, "me sale error de autenticación",
     {"intencion": "aportar_dato", "etapa": "guia"}, mem=mem(articulos_mostrados=["KB-007"], intentos_guia=1))
caso("en plena guía, «olvidé mi contraseña» sí es otro problema", "guia", "restablecer_clave", 0.9, "olvidé mi contraseña",
     {"intencion": "restablecer_clave"}, mem=mem(articulos_mostrados=["KB-007"], intentos_guia=1), cambio_tema=True, articulo=ART)
caso("en plena guía, un cambio de tema reconocido empieza un caso nuevo", "guia", "reportar_falla", 0.9, "ahora la impresora no imprime",
     {"intencion": "reportar_falla", "etapa": "guia", "guia": True}, mem=mem(articulos_mostrados=["KB-001"], intentos_guia=1), cambio_tema=True, articulo=ART)
caso("P1 descubierto en plena guía: va a incidencia", "guia", "aportar_dato", 0.9, "a todos en toda la sede, se cayó la red",
     {"etapa": "incidencia", "accion": "crear_incidencia", "motivo_incidencia": "p1", "p1": True, "guia": False},
     mem=mem(sintoma="no tengo internet", impacto="sede", caida=True, articulos_mostrados=["KB-010"], intentos_guia=1, intencion_caso="reportar_falla"), articulo=ART)
caso("P1 descubierto en el diagnóstico", "diagnostico", "aportar_dato", 0.9, "sí, a toda la empresa", {"etapa": "incidencia", "motivo_incidencia": "p1"},
     mem=mem(sintoma="no hay sistema", impacto="organizacion", intencion_caso="reportar_falla"), pendiente="afecta_otros", respondio_pendiente=True)
caso("una solicitud para toda la sede NO es P1 aunque llegue en el diagnóstico", "diagnostico", "aportar_dato", 0.9, "para toda la sede", {"p1": False},
     mem=mem(solicitud="acceso a la carpeta", impacto="sede", intencion_caso="solicitar_acceso"), es_solicitud_concreta=True)

# --- Utilidades de lenguaje ---------------------------------------------------------------------------------------
for msg, esp in (("quiero hablar con un técnico", True), ("pásenme con una persona", True), ("gracias al técnico", False), ("el técnico llegó tarde", False),
                 ("no funciona el correo", False), ("necesito una laptop", False), ("que venga alguien a ver mi pc", True), ("hablar con soporte", False)):
    total += 1
    if pide_tecnico(msg) != esp:
        fallos.append(f"   ✗ pide_tecnico({msg!r}) = {not esp}")
for msg, esp in (("cómo va mi ticket", True), ("INC-000142 qué pasó", True), ("ya asignaron a alguien", True), ("necesito acceso", False), ("el ticket de ayer sigue abierto?", True),
                 ("hola", False)):
    total += 1
    if pregunta_por_estado(msg) != esp:
        fallos.append(f"   ✗ pregunta_por_estado({msg!r}) = {not esp}")
for msg, esp in (("pésima atención", True), ("es la tercera vez que reporto", True), ("gracias por todo", False), ("mi laptop no prende", False), ("estoy harto del sistema", True)):
    total += 1
    if es_queja(msg) != esp:
        fallos.append(f"   ✗ es_queja({msg!r}) = {not esp}")
for msg, esp in (("INC-000142", "INC-000142"), ("qué pasó con inc 231", "INC-000231"), ("el caso 5", None), ("hola", None)):
    total += 1
    if numero_en(msg) != esp:
        fallos.append(f"   ✗ numero_en({msg!r}) = {numero_en(msg)!r}")

# --- Entradas raras: nunca revienta -----------------------------------------------------------------------------------
for etapa in ("", "inventada", None, 5):
    for intent in ("", "inventada", None):
        for conf in (-1, 0, 0.5, 1, 7, "x"):
            total += 1
            try:
                decidir(etapa, intent, conf if isinstance(conf, (int, float)) else 0.5, "x" * 300)
            except Exception as e:  # noqa: BLE001
                fallos.append(f"   ✗ decidir({etapa!r}, {intent!r}, {conf!r}) reventó: {e!r}")
total += 1
try:
    decidir("guia", "reportar_falla", 0.9, "", abiertas=[None, "x", {"numero": None}], mem={"sabemos": {}}, articulo={})
except Exception as e:  # noqa: BLE001
    fallos.append(f"   ✗ contexto raro reventó: {e!r}")

print(f"prueba_etapas: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
