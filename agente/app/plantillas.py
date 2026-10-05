"""Textos por código (sin LLM): lo que se dice en cada situación. Es el respaldo que SIEMPRE está disponible y el que usa
la regresión (determinista, sin red). Con un LLM disponible, solo la pieza «responde» de la conversación (diagnóstico y guía)
la puede redactar él; todo lo demás sigue saliendo de aquí: número, plazo, técnico, estado y encuesta los escribe código.

Reglas de redacción: español de Perú, trato de «tú», breve, sin tecnicismos, sin emojis, sin prometer plazos (los plazos
salen del SLA y los informa el sistema) y sin inventar nada de la organización.
"""
from __future__ import annotations

import re

from . import memoria
from .seguridad import AVISO_CONTRASENA

ACK_CATEGORIA = {
    "correo": "Entiendo, vamos a revisar tu correo.", "cuentas_accesos": "Entiendo, vamos a revisar tu acceso.",
    "red_wifi": "Entiendo, vamos a revisar tu conexión.", "vpn": "Entiendo, vamos a revisar la VPN.",
    "impresoras": "Entiendo, vamos a revisar la impresora.", "equipo": "Entiendo, vamos a revisar tu equipo.",
    "software_oficina": "Entiendo, vamos a revisar ese programa.", "sistema_interno": "Entiendo, vamos a revisar ese sistema.",
    "telefonia": "Entiendo, vamos a revisar tu teléfono.", "otro": "Entiendo, déjame ayudarte con eso.",
}
ACK_DATO = ("Gracias, ya lo anoté.", "Perfecto, gracias.", "Entendido, lo anoto.")
PIDE_TECNICO = {"consulta": "Claro, registro tu pedido para que un técnico te contacte.", "incidente": "Claro, registro tu pedido para que un técnico te contacte."}
FUERA = "Solo puedo ayudarte con temas de soporte técnico: fallas, accesos, equipos y el estado de tus incidencias. ¿Tienes algo de eso?"
NO_ENTENDI = "No te entendí bien."


def nombre_pila(perfil: dict | None) -> str:
    n = (perfil or {}).get("nombre")
    if not isinstance(n, str) or not n.strip():
        return ""
    return re.split(r"\s+", n.strip())[0][:20]


def _v(opciones, mem) -> str:
    """Una variante estable según el turno: no suena a formulario y es determinista."""
    return opciones[(mem.get("turnos", 0) if isinstance(mem, dict) else 0) % len(opciones)]


def saludo(perfil, mem) -> str:
    n = nombre_pila(perfil)
    return f"¡Hola{', ' + n if n else ''}! Soy el asistente de soporte técnico. Cuéntame qué problema tienes o qué necesitas."


def componer(d: dict, ctx: dict) -> dict:
    """La respuesta por código para la decisión `d` (etapas.decidir). Devuelve
    {"responde", "pasos", "pregunta", "pendiente", "texto_null"}: `pendiente` es la pregunta que queda abierta (si la hay);
    `texto_null` es True cuando el backend arma el texto y esto es solo la frase previa."""
    mem, perfil, cat = ctx["mem"], ctx.get("perfil") or {}, ctx.get("categoria") or "otro"
    accion, etapa, intent = d["accion"], d["etapa"], d["intencion"]
    out = {"responde": "", "pasos": [], "pregunta": "", "pendiente": "", "texto_null": False}
    antes = AVISO_CONTRASENA + " " if ctx.get("secreto") else ""

    def r(responde="", pasos=(), pregunta="", pendiente="", null=False):
        out.update(responde=(antes + responde).strip(), pasos=list(pasos), pregunta=pregunta, pendiente=pendiente, texto_null=null)
        return out

    # --- no se entendió ----------------------------------------------------------------------------------------
    if not d.get("entendido", True):
        if mem.get("sin_entender", 0) >= 2:
            return r(NO_ENTENDI + " Prefiero no hacerte perder tiempo.", pregunta=memoria.PREGUNTAS["ofrecer_tecnico"], pendiente="ofrecer_tecnico")
        if etapa == "guia" and mem.get("articulos_mostrados"):          # hay una guía en marcha: no se pierde el hilo
            return r(NO_ENTENDI + " Sigamos con la guía que te envié.", pregunta=memoria.PREGUNTAS["resolvio"], pendiente="resolvio")
        if mem.get("pendiente") in memoria.PEND_DATOS and mem.get("pendiente") != "que_pasa":
            return r(NO_ENTENDI, pregunta=memoria.texto_pregunta(mem["pendiente"], mem, cat, perfil), pendiente=mem["pendiente"])
        return r(NO_ENTENDI, pregunta="¿Me cuentas con otras palabras qué está pasando?", pendiente="que_pasa")

    # --- acciones fijas: el backend arma el texto con los datos; aquí va la frase previa --------------------------
    if accion == "encuesta":
        n = d.get("puntaje") or 0
        return r("¡Gracias por tu calificación! Si necesitas algo más, escríbeme." if n >= 3 else
                 "Gracias por decírmelo; lamento que la atención no haya estado a la altura. Tomo nota para mejorarla.", null=True)
    if accion == "confirmar_solucion":
        return r("¡Qué bueno que quedó resuelto!", pregunta=memoria.PREGUNTAS["puntaje"], pendiente="puntaje")
    if accion == "consultar_estado":
        if d.get("numero"):
            return r("Te cuento cómo va tu incidencia.", null=True)
        return r("No veo incidencias abiertas a tu nombre. Si tienes un problema, cuéntamelo y lo revisamos.", pregunta="", pendiente="que_pasa")
    if accion == "sigue_igual":
        return r("Gracias por avisarme. Lo anoto en tu incidencia para que el técnico lo tenga presente.", null=True)
    if accion == "agregar_dato":
        dato = d.get("dato") or {}
        k, v = dato.get("clave"), dato.get("valor")
        if k and k not in ("comentario",) and v:
            et = memoria.NOMBRES.get(k, k)
            return r(f"Anotado: {et}: {v}. Lo agrego a tu incidencia.", null=True)
        return r("Anotado. Lo agrego a tu incidencia.", null=True)
    if accion == "pedir_tecnico":
        if d.get("numero"):
            return r(f"Claro, aviso al técnico que lleva tu incidencia {d['numero']} para que te contacte.", null=True)
        return r(PIDE_TECNICO["incidente"], null=True)
    if accion == "crear_incidencia":
        mot, tipo = d.get("motivo_incidencia"), d.get("incidencia_tipo")
        if mot == "guia_agotada":
            t = "Lamento que no se haya resuelto. Registro una incidencia con todo lo que ya probamos para que la atienda un técnico."
        elif mot == "p1":
            t = "Esto afecta a varias personas, así que no te pido más pasos: lo registro ahora mismo para que lo atienda un técnico."
        elif tipo == "solicitud":
            t = "Registro tu solicitud para que la atienda el área correspondiente."
        else:
            t = "No tengo una guía para esto, así que lo registro para que lo atienda un técnico."
        return r(t, null=True)

    # --- conversación ------------------------------------------------------------------------------------------
    if intent == "queja":
        base = ("Lamento la demora y la molestia. Dejo constancia de tu queja para que la revise un supervisor." if d.get("numero") else
                "Lamento lo que me cuentas, tienes razón en estar molesto. Dejo constancia de tu queja para que la revise un supervisor.")
        if d.get("ofrecer_tecnico"):
            return r(base, pregunta=memoria.PREGUNTAS["ofrecer_tecnico"], pendiente="ofrecer_tecnico")
        return r(base)
    if intent == "fuera_de_alcance":
        return r(FUERA)
    if intent == "saludo":
        if etapa in ("diagnostico", "guia", "seguimiento"):
            return r("¡Hola! Seguimos con lo tuyo. ¿Cómo vas?")
        return r(saludo(perfil, mem), pendiente="que_pasa")
    if intent == "agradecer":
        if etapa == "guia":
            return r("¡Con gusto! Cuando pruebes los pasos, cuéntame si quedó resuelto.", pendiente="resolvio")
        return r("¡De nada! Si necesitas algo más, aquí estoy.")
    if intent == "sigue_igual" and etapa == "recepcion":
        return r("¿Qué es lo que sigue igual? Cuéntame el problema y lo revisamos.", pendiente="que_pasa")
    if intent == "confirmar_solucion":
        return r("¡Me alegra! Si necesitas algo más, aquí estoy.")

    if d.get("guia") and ctx.get("articulo"):
        art = ctx["articulo"]
        pasos, saltados = ctx["pasos"], ctx.get("saltados", [])
        segunda = mem.get("intentos_guia", 0) >= 2      # main ya contó esta guía: la segunda es la que lleva intentos_guia == 2
        intro = (f"Probemos con otra guía: «{art['titulo']}»." if segunda else f"Encontré esta guía: «{art['titulo']}». Pruébala en orden.")
        if saltados:
            intro += " Salté lo que ya hiciste (" + ", ".join(saltados) + ")."
        return r(intro, pasos=pasos, pregunta=memoria.PREGUNTAS["resolvio"], pendiente="resolvio")
    if d.get("recordar_pasos"):
        return r("Gracias por el dato, lo anoto. Mientras tanto, prueba los pasos que te envié.", pregunta=memoria.PREGUNTAS["resolvio"], pendiente="resolvio")

    if etapa in ("diagnostico", "recepcion", "guia") and d.get("preguntar"):
        k = ctx.get("pregunta_clave") or "que_pasa"
        ack = ACK_CATEGORIA.get(cat, ACK_CATEGORIA["otro"]) if intent in ("reportar_falla", "restablecer_clave", "solicitar_acceso", "solicitar_equipo") and mem.get("turnos", 0) <= 1 \
            else _v(ACK_DATO, mem)
        if intent in ("solicitar_acceso", "solicitar_equipo") and mem.get("turnos", 0) <= 1:
            ack = "Claro, te ayudo con esa solicitud."
        return r(ack, pregunta=memoria.texto_pregunta(k, mem, cat, perfil), pendiente=k)

    if etapa == "seguimiento":
        return r("Aquí sigo. Tu incidencia sigue su curso; si quieres saber cómo va, pregúntame por el estado.")
    if etapa == "recepcion" and intent == "aportar_dato":
        return r("Gracias, lo anoto. ¿Qué problema o qué necesitas?", pendiente="que_pasa")
    return r("Cuéntame con tus palabras qué problema tienes o qué necesitas.", pendiente="que_pasa")
