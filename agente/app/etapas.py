"""Máquina de etapas de atención: recepción → diagnóstico → guía → incidencia → seguimiento → cierre → encuesta.

El clasificador dice qué quiere la persona (intención y confianza). Este módulo decide, con reglas explícitas y umbrales,
en qué etapa queda el caso y qué acción propone al backend. **El LLM no decide etapas: solo redacta.** Y el agente
tampoco decide prioridad, plazos, técnicos ni estados: propone, y el backend dispone (CONTRATOS §1).

Cada decisión deja su porqué en `bitacora` (una lista de frases en español): es lo que se ve en la consola y lo que se
revisa cuando algo sale raro.

Reglas clave (ARQUITECTURA §2.1):

1. **P1 sin guía.** Una caída que afecta a una sede o a toda la organización va directo a incidencia (urgencia crítica).
2. **«Quiero hablar con un técnico» siempre se respeta**, venga lo que venga del clasificador y en cualquier etapa.
3. **Una sola incidencia abierta por síntoma.** Si ya hay una abierta del mismo síntoma, se agrega el dato a esa.
4. **Guía agotada.** «Sigue igual» tras los pasos, o dos guías sin resolver, abre la incidencia (motivo `guia_agotada`).
5. **Cierre confirmado.** Solo la persona (o el técnico) cierra: «ya funcionó» lleva a cierre y a la encuesta.
6. **Sin artículo, sin inventar.** Si no hay artículo suficiente y no quedan preguntas que hacer, incidencia (`sin_articulo`).
7. **Los pasos solo salen de un artículo.** Esta máquina nunca pone pasos: dice `guia=True` y main.py los toma del artículo.

Sin dependencias pesadas: se prueba con `python -m app.prueba_etapas`.
"""
from __future__ import annotations

import os
import re

from . import memoria
from .datos import INTENCIONES, INTENCIONES_CASO

ETAPAS = ("recepcion", "diagnostico", "guia", "incidencia", "seguimiento", "cierre", "encuesta", "consulta_estado")

UMBRAL_ALTO = float(os.environ.get("ETAPAS_UMBRAL_ALTO", "0.60"))    # se usa la clasificación tal cual
UMBRAL_MEDIO = float(os.environ.get("ETAPAS_UMBRAL_MEDIO", "0.40"))  # entre medio y alto: solo transiciones prudentes; por debajo, ninguna
# Los umbrales salen de la calibración medida en el conjunto reservado (LEEME.md): con la confianza calibrada, entre 0,4 y 0,6 el clasificador acierta
# ~60 % de las veces (15 mensajes), entre 0,6 y 0,9 ~93 % (45) y desde 0,9 el 100 % (90). Por debajo de 0,4 hubo solo 3 mensajes: muestra demasiado chica.
MAX_INTENTOS_GUIA = 2      # guías entregadas sin que se resolviera: la siguiente vez, incidencia
MAX_TURNOS_GUIA = 3        # turnos en la etapa guía sin confirmar ni negar: incidencia
MAX_PREGUNTAS_CON_ARTICULO = 1   # con un artículo a medias se afina con UNA pregunta; sin artículo se pregunta hasta memoria.MAX_PREGUNTAS_DATOS

_p = memoria._plano

# --- reglas de lenguaje (las que mandan sobre el clasificador) ---------------------------------------------------
from .lenguaje import pide_restablecer as memoria_pide_restablecer  # noqa: E402
from .lenguaje import (RE_ESTADO, RE_NIEGA_RESUELTO, RE_PIDE_TECNICO, RE_QUEJA, RE_SOLO_ACUSE, es_queja, numero_en, pide_tecnico, pregunta_por_estado)  # noqa: E402,F401


def _estado_abierto(i: dict) -> bool:
    return isinstance(i, dict) and str(i.get("estado") or "") not in ("cerrada",)


def _etapa_efectiva(etapa_in: str, pendiente: str, abiertas: list, mismo_sintoma, cambio_tema: bool, b: list[str]) -> str:
    """La etapa que persistió el backend, leída con lo que hay ahora."""
    if etapa_in == "incidencia" and (mismo_sintoma or abiertas):
        etapa_ef = "seguimiento"
        b.append("etapa «incidencia» con incidencia abierta: se sigue como seguimiento")
    elif etapa_in == "incidencia":
        etapa_ef = "incidencia"
    elif etapa_in in ("consulta_estado", "encuesta"):
        etapa_ef = "recepcion"
    elif etapa_in == "cierre" and pendiente != "puntaje":
        etapa_ef = "recepcion"
    else:
        etapa_ef = etapa_in
    if cambio_tema and etapa_ef in ("diagnostico", "guia"):
        etapa_ef = "recepcion"
        b.append("cambio de tema: se atiende como un caso nuevo")

    return etapa_ef


def corregir_intencion(etapa_ef: str, intencion: str, confianza: float, mensaje: str, pendiente: str, respondio_pendiente: bool, mem: dict, abiertas: list,
                       b: list[str]) -> tuple[str, float, bool]:
    """Las reglas de lenguaje corrigen la intención ANTES de mirar umbrales (lo que la persona dice manda sobre lo que opine el clasificador).
    Devuelve (intención, confianza, es_aporte). Es pública para que main.py use la misma intención al decidir la categoría y el síntoma."""
    texto = _p(mensaje)
    corto = len(texto) <= 26
    intent, conf = (intencion if intencion in INTENCIONES else "fuera_de_alcance"), float(confianza)
    pide, estado_q, queja_q = pide_tecnico(mensaje), pregunta_por_estado(mensaje), es_queja(mensaje)
    confirma, sigue = memoria.confirma(mensaje), memoria.sigue_igual(mensaje)
    afirma, niega = memoria.afirma(mensaje), memoria.niega(mensaje)
    puntaje = memoria.puntaje_en(mensaje) if pendiente == "puntaje" else None
    es_aporte = False

    if pendiente == "puntaje" and puntaje and (corto or len(texto.split()) <= 8):
        intent, conf = "agradecer", 1.0
        b.append(f"respondió la encuesta con {puntaje}")
    elif pide:
        intent, conf = "pedir_tecnico", max(conf if intent == "pedir_tecnico" else 0.0, 0.95)
        b.append("pidió hablar con una persona: se respeta siempre")
    elif pendiente == "ofrecer_tecnico" and (afirma or re.match(r"^(?:si+|sip|claro|por favor|dale|ya|ok|bueno|listo)\b", texto)):
        intent, conf = "pedir_tecnico", 0.97
        b.append("«sí» a «¿quieres que un técnico te contacte?»")
    elif pendiente == "resolvio" and (memoria.afirma_resuelto(mensaje) or confirma) and not sigue:
        intent, conf = "confirmar_solucion", 0.97
        b.append("«sí» a «¿quedó resuelto?»")
    elif pendiente == "resolvio" and (niega or sigue or RE_NIEGA_RESUELTO.match(texto)):
        intent, conf = "sigue_igual", 0.97
        b.append("«no» a «¿quedó resuelto?»: sigue igual")
    elif sigue and not confirma and (etapa_ef in ("guia", "seguimiento", "incidencia") or abiertas or mem.get("articulos_mostrados") or pendiente == "resolvio"
                                     or (intent == "sigue_igual" and etapa_ef in ("diagnostico", "recepcion"))):
        intent, conf = "sigue_igual", max(conf if intent == "sigue_igual" else 0.0, 0.9)
        b.append("dice que sigue igual")
    elif confirma and (etapa_ef in ("guia", "seguimiento", "diagnostico") or pendiente == "resolvio" or mem.get("articulos_mostrados")) and not estado_q:
        intent, conf = "confirmar_solucion", max(conf if intent == "confirmar_solucion" else 0.0, 0.92)
        b.append("dice que ya quedó resuelto")
    elif estado_q and intent != "consultar_estado" and not queja_q:
        intent, conf = "consultar_estado", max(conf if intent == "consultar_estado" else 0.0, 0.9)
        b.append("pregunta por el estado de un caso")
    elif queja_q and intent not in ("queja", "pedir_tecnico"):
        intent, conf = "queja", max(conf if intent == "queja" else 0.0, 0.9)
        b.append("se queja del servicio")
    elif intent == "aportar_dato" and not pendiente and etapa_ef == "recepcion" and not mem.get("sabemos", {}).get("sintoma") and conf < UMBRAL_ALTO and not respondio_pendiente:
        intent = "reportar_falla"
        b.append("un «dato» dudoso sin ninguna pregunta ni caso abierto: lo más probable es que sea el problema")
    elif pendiente == "que_pasa" and intent in ("aportar_dato",) and not respondio_pendiente and conf < 0.999:
        intent, conf = "reportar_falla", max(conf, 0.8)
        b.append("a «¿qué pasa?» contesta con lo que le pasa: es el problema, no un dato suelto")
    elif memoria_pide_restablecer(mensaje) and intent not in ("restablecer_clave", "pedir_tecnico", "queja", "consultar_estado") and conf < 0.9 and not respondio_pendiente:
        intent, conf = "restablecer_clave", max(conf, 0.85)
        b.append("habla de olvidar, bloquear o vencer su contraseña o usuario: es restablecer la clave")
    elif respondio_pendiente and pendiente in memoria.PEND_DATOS:
        intent, conf = "aportar_dato", max(conf if intent == "aportar_dato" else 0.0, 0.95)
        es_aporte = True
        b.append(f"responde a la pregunta pendiente «{pendiente}»")
    elif corto and RE_SOLO_ACUSE.match(texto) and pendiente in ("", "resolvio"):
        intent, conf = "agradecer", 0.7
        b.append("acuse corto sin pregunta pendiente: no cambia nada")

    return intent, conf, es_aporte


def intencion_efectiva(etapa: str, intencion: str, confianza: float, mensaje: str, *, pendiente: str = "", respondio_pendiente: bool = False,
                       mem: dict | None = None, abiertas: list | None = None, mismo_sintoma: dict | None = None, cambio_tema: bool = False) -> tuple[str, float]:
    """La intención que decidir() usaría para este mensaje, sin decidir nada más."""
    mem = mem or memoria.nueva()
    abiertas = [i for i in (abiertas or []) if _estado_abierto(i)]
    etapa_in = etapa if etapa in ETAPAS else "recepcion"
    scratch: list[str] = []
    etapa_ef = _etapa_efectiva(etapa_in, pendiente, abiertas, mismo_sintoma, cambio_tema, scratch)
    intent, conf, _ = corregir_intencion(etapa_ef, intencion, confianza, mensaje, pendiente, respondio_pendiente, mem, abiertas, scratch)
    return intent, conf


def decidir(etapa: str, intencion: str, confianza: float, mensaje: str, *, pendiente: str = "", respondio_pendiente: bool = False,
            categoria: str = "", mem: dict | None = None, articulo: dict | None = None, hay_pregunta: bool = False,
            abiertas: list | None = None, mismo_sintoma: dict | None = None, primer_mensaje: bool = False,
            cambio_tema: bool = False, datos_nuevos: dict | None = None, es_solicitud_concreta: bool = False) -> dict:
    """Decide la etapa nueva y la acción que se propone, con el motivo de cada decisión.

    - `articulo`: el mejor artículo que aún no se mostró, {"clave", "score", "suficiente"}; None si ninguno pasa el umbral mínimo.
    - `hay_pregunta`: queda una pregunta de datos por hacer (`memoria.siguiente()` no está vacío).
    - `abiertas`: incidencias abiertas de la persona (del contrato); `mismo_sintoma`: la que es del mismo síntoma, si la hay.
    - `cambio_tema`: la persona empezó otro problema distinto del que se venía tratando (lo calcula main.py).
    - `es_solicitud_concreta`: el mensaje de una solicitud ya dice qué se pide (no hace falta preguntar).
    Devuelve {etapa, intencion, accion, motivo_incidencia, incidencia_tipo, numero, guia, preguntar, entendido, p1, ...}.
    """
    mem = mem or memoria.nueva()
    sab = mem.get("sabemos", {})
    abiertas = [i for i in (abiertas or []) if _estado_abierto(i)]
    etapa_in = etapa if etapa in ETAPAS else "recepcion"
    b: list[str] = []

    etapa_ef = _etapa_efectiva(etapa_in, pendiente, abiertas, mismo_sintoma, cambio_tema, b)
    intent, conf, es_aporte = corregir_intencion(etapa_ef, intencion, confianza, mensaje, pendiente, respondio_pendiente, mem, abiertas, b)
    if etapa_ef == "guia" and intent in ("reportar_falla", "restablecer_clave") and not cambio_tema and not (intent == "restablecer_clave" and memoria_pide_restablecer(mensaje)):
        intent = "aportar_dato"
        b.append("en plena guía, otra descripción del mismo problema: se toma como un dato más, no como un problema nuevo")
    pide = pide_tecnico(mensaje)
    puntaje = memoria.puntaje_en(mensaje) if pendiente == "puntaje" else None

    nivel = "alta" if conf >= UMBRAL_ALTO else "media" if conf >= UMBRAL_MEDIO else "baja"
    base = {"etapa_anterior": etapa_in, "intencion": intent, "confianza": round(conf, 3), "nivel": nivel, "accion": "ninguna", "motivo_incidencia": None,
            "incidencia_tipo": None, "numero": None, "guia": False, "preguntar": False, "entendido": True, "p1": False, "urgencia_sugerida": None,
            "pide_tecnico": bool(pide or intent == "pedir_tecnico"), "dato": None}

    def fin(etapa_nueva: str, **kw) -> dict:
        r = dict(base) | kw
        r["etapa"] = etapa_nueva
        r["transicion"] = etapa_nueva != etapa_in
        r["bitacora"] = list(b)
        r["motivo"] = "; ".join(b)
        return r

    numero_mencionado = numero_en(mensaje)
    abierta_ref = next((i for i in abiertas if i.get("numero") == numero_mencionado), None) if numero_mencionado else None
    abierta_ref = abierta_ref or mismo_sintoma or (abiertas[0] if len(abiertas) == 1 else None)
    numero_ref = abierta_ref.get("numero") if abierta_ref else None

    # --- 2. Encuesta pendiente -------------------------------------------------------------------------------------
    if pendiente == "puntaje" and puntaje:
        b.append("la encuesta se registra; el caso termina")
        return fin("encuesta", accion="encuesta", intencion="agradecer", dato={"clave": "puntaje", "valor": str(puntaje)}, puntaje=puntaje)

    # --- 3. Pedir un técnico: siempre ------------------------------------------------------------------------------
    if intent == "pedir_tecnico":
        if abierta_ref:
            b.append(f"ya hay una incidencia abierta ({numero_ref}): la petición se suma a esa")
            return fin("seguimiento", accion="pedir_tecnico", numero=numero_ref)
        b.append("no hay incidencia abierta: se propone una con motivo «pidió un técnico»")
        return fin("incidencia", accion="pedir_tecnico", motivo_incidencia="pidio_tecnico", incidencia_tipo="incidente" if sab.get("sintoma") or categoria else "consulta")

    # --- 4. Nada que entender --------------------------------------------------------------------------------------
    if nivel == "baja" and intent not in ("agradecer", "saludo"):
        b.append(f"confianza baja ({conf:.2f}): la etapa no cambia y se le pide que lo cuente de otro modo")
        return fin(etapa_in if etapa_in not in ("encuesta",) else "recepcion", entendido=False, preguntar=False)

    # --- 5. Consultar el estado ------------------------------------------------------------------------------------
    if intent == "consultar_estado":
        if abierta_ref or abiertas:
            ref = abierta_ref or abiertas[0]
            b.append(f"consulta el estado de {ref.get('numero')}: lo informa el sistema")
            return fin("consulta_estado", accion="consultar_estado", numero=ref.get("numero"))
        b.append("pregunta por el estado pero no tiene incidencias abiertas")
        return fin("consulta_estado", accion="consultar_estado", numero=None)

    # --- 6. Confirmar que ya funciona ------------------------------------------------------------------------------
    if intent == "confirmar_solucion":
        if etapa_ef in ("guia", "diagnostico") or mem.get("articulos_mostrados") or pendiente == "resolvio":
            b.append("confirmó la solución de la guía: cierre confirmado y encuesta")
            return fin("cierre", accion="confirmar_solucion", numero=numero_ref)
        if abierta_ref:
            b.append(f"confirma que quedó resuelto lo de {numero_ref}: cierre confirmado y encuesta")
            return fin("cierre", accion="confirmar_solucion", numero=numero_ref)
        b.append("dice que ya funciona pero no hay nada abierto: se agradece y no se cambia nada")
        return fin(etapa_ef if etapa_ef != "cierre" else "recepcion")

    # --- 7. «Sigue igual» --------------------------------------------------------------------------------------------
    if intent == "sigue_igual":
        if etapa_ef == "guia" or (mem.get("articulos_mostrados") and not abierta_ref):
            if mismo_sintoma:
                b.append(f"sigue igual tras la guía y ya hay {numero_ref} del mismo síntoma: se agrega a esa")
                return fin("seguimiento", accion="sigue_igual", numero=numero_ref)
            b.append("sigue igual tras los pasos de la guía: guía agotada, incidencia")
            return fin("incidencia", accion="crear_incidencia", motivo_incidencia="guia_agotada", incidencia_tipo="incidente")
        if abierta_ref:
            b.append(f"sigue igual con {numero_ref} abierta: se avisa a esa incidencia (el backend la reabre si estaba resuelta)")
            return fin("seguimiento", accion="sigue_igual", numero=numero_ref)
        if etapa_ef == "diagnostico" and (sab.get("sintoma") or categoria):
            b.append("«sigue igual» sin guía previa pero con un problema en curso: se sigue diagnosticando")
            return fin("diagnostico", preguntar=hay_pregunta)
        b.append("«sigue igual» sin ningún caso al que referirse: se le pregunta qué problema es")
        return fin("recepcion", preguntar=False)

    # --- 8. Queja ----------------------------------------------------------------------------------------------------
    if intent == "queja":
        if nivel == "media":
            b.append("queja con confianza media: se trata con empatía y no se cambia la etapa")
        if abierta_ref:
            b.append(f"queja con {numero_ref} abierta: se deja constancia (señal para el supervisor) y se sigue como seguimiento")
            return fin("seguimiento", numero=numero_ref)
        b.append("queja sin incidencia abierta: se deja constancia y se ofrece un técnico")
        return fin(etapa_ef if etapa_ef not in ("recepcion",) else "recepcion", preguntar=False, ofrecer_tecnico=True)

    # --- 9. Cortesías y lo que no es soporte ------------------------------------------------------------------------
    if intent == "agradecer":
        b.append("agradece: no cambia la etapa")
        return fin(etapa_ef if etapa_ef in ("diagnostico", "guia", "seguimiento") else "recepcion")
    if intent == "saludo":
        b.append("saluda: no cambia la etapa")
        return fin(etapa_ef if etapa_ef in ("diagnostico", "guia", "seguimiento") else "recepcion")
    if intent == "fuera_de_alcance":
        b.append("no es un tema de soporte: se le dice qué sí puede hacer el asistente")
        return fin(etapa_ef if etapa_ef in ("diagnostico", "guia", "seguimiento") else "recepcion")

    # --- 9b. P1 descubierto en el camino: dice que afecta a toda la sede o a toda la organización mientras se diagnostica o se guía --------
    if sab.get("impacto") in ("sede", "organizacion") and intent in ("reportar_falla", "aportar_dato") and etapa_ef in ("recepcion", "diagnostico", "guia") \
            and mem.get("intencion_caso") not in ("solicitar_acceso", "solicitar_equipo") and (sab.get("sintoma") or intent == "reportar_falla"):
        return _problema(b, fin, mem, sab, categoria, "reportar_falla", articulo, hay_pregunta, abiertas, mismo_sintoma, numero_ref, es_solicitud_concreta, base, etapa_in, etapa_ef, nivel)

    # --- 10. Datos para un caso que ya está en marcha --------------------------------------------------------------
    if intent == "aportar_dato":
        if etapa_ef == "seguimiento":
            num = numero_ref
            if datos_nuevos:
                k, v = next(iter(datos_nuevos.items()))
                b.append(f"aporta datos nuevos a {num or 'su incidencia'}: se agregan (sin crear otra)")
                return fin("seguimiento", accion="agregar_dato", numero=num, dato={"clave": k, "valor": v})
            b.append("sigue el caso en seguimiento sin datos nuevos")
            return fin("seguimiento", numero=num)
        if etapa_ef == "guia":
            return _en_guia_con_dato(b, fin, mem, articulo, hay_pregunta, base)
        if etapa_ef in ("recepcion",) and not sab.get("sintoma") and not categoria:
            b.append("dato suelto sin problema descrito: se le pregunta qué pasa")
            return fin("recepcion", preguntar=False)
        # diagnóstico (o dato que completa lo que ya había): se reevalúa como el problema
        intent_problema = mem.get("intencion_caso") or "reportar_falla"
        return _problema(b, fin, mem, sab, categoria, intent_problema, articulo, hay_pregunta, abiertas, mismo_sintoma, numero_ref, es_solicitud_concreta, base, etapa_in, etapa_ef, nivel)

    # --- 11. Un problema o una solicitud ----------------------------------------------------------------------------
    if intent in INTENCIONES_CASO:
        if intent == "reportar_falla" and nivel == "baja":
            b.append("falla con confianza baja: no se mueve")
            return fin(etapa_ef)
        return _problema(b, fin, mem, sab, categoria, intent, articulo, hay_pregunta, abiertas, mismo_sintoma, numero_ref, es_solicitud_concreta, base, etapa_in, etapa_ef, nivel)

    b.append("sin regla para esta combinación: no se cambia la etapa")
    return fin(etapa_ef)


def _en_guia_con_dato(b, fin, mem, articulo, hay_pregunta, base):
    """Aporta datos estando en la guía: si hay otro artículo que encaje y quedan intentos, una guía nueva; si no, se le
    recuerda probar los pasos; y si ya se dieron dos guías o van demasiados turnos, incidencia."""
    intentos, turnos = mem.get("intentos_guia", 0), mem.get("turnos_guia", 0)
    if articulo and articulo.get("suficiente") and intentos < MAX_INTENTOS_GUIA:
        b.append(f"aporta un dato y hay otro artículo que encaja ({articulo.get('clave')}): segundo intento de guía")
        return fin("guia", guia=True)
    if intentos >= MAX_INTENTOS_GUIA or turnos + 1 >= MAX_TURNOS_GUIA:
        b.append(f"van {intentos} guías y {turnos + 1} turnos sin resolver: guía agotada, incidencia")
        return fin("incidencia", accion="crear_incidencia", motivo_incidencia="guia_agotada", incidencia_tipo="incidente")
    b.append("aporta un dato en la guía sin artículo nuevo: se le recuerda probar los pasos")
    return fin("guia", preguntar=False, recordar_pasos=True)


def _problema(b, fin, mem, sab, categoria, intent, articulo, hay_pregunta, abiertas, mismo_sintoma, numero_ref, es_solicitud_concreta, base, etapa_in, etapa_ef, nivel):
    """Reportar una falla o hacer una solicitud: diagnosticar, guiar, abrir incidencia o sumar a la que ya existe."""
    impacto, caida = sab.get("impacto"), bool(sab.get("caida"))
    amplio = impacto in ("sede", "organizacion")
    tipo = "solicitud" if intent in ("solicitar_acceso", "solicitar_equipo") else "incidente"

    # (a) Ya hay una incidencia abierta del mismo síntoma: no se crea otra.
    if mismo_sintoma and etapa_ef in ("recepcion", "seguimiento", "diagnostico", "guia"):
        b.append(f"ya hay {numero_ref} abierta del mismo síntoma: se agrega a esa, no se crea otra")
        r = fin("seguimiento", accion="agregar_dato", numero=numero_ref, dato={"clave": "comentario", "valor": "reporta el mismo síntoma de nuevo"})
        if amplio:
            r["dato"] = {"clave": "impacto", "valor": impacto}
            r["bitacora"].append(f"y ahora dice que afecta a {impacto}: el backend recalcula la prioridad")
            r["motivo"] = "; ".join(r["bitacora"])
        return r
    # (b) P1: una caída que afecta a una sede o a toda la organización va directo a incidencia, sin guía.
    if amplio and tipo == "incidente":
        urg = "critica" if (caida or sab.get("urgencia") == "critica") else "alta"
        b.append(f"afecta a {impacto}{' y es una caída' if caida else ''}: P1 sin guía, directo a incidencia (urgencia {urg})")
        return fin("incidencia", accion="crear_incidencia", motivo_incidencia="p1", incidencia_tipo="incidente", p1=True, urgencia_sugerida=urg)
    # (c) Solicitudes (acceso, equipo): no hay guía que dar; si ya dice qué pide, incidencia; si no, se pregunta.
    if tipo == "solicitud":
        if es_solicitud_concreta or sab.get("solicitud"):
            b.append("solicitud con lo que se pide ya dicho: se propone la incidencia (tipo solicitud)")
            return fin("incidencia", accion="crear_incidencia", motivo_incidencia="sin_articulo", incidencia_tipo="solicitud")
        if hay_pregunta:
            b.append("solicitud sin decir qué se pide: se pregunta")
            return fin("diagnostico", preguntar=True)
        b.append("solicitud y ya no quedan preguntas: se propone la incidencia (tipo solicitud)")
        return fin("incidencia", accion="crear_incidencia", motivo_incidencia="sin_articulo", incidencia_tipo="solicitud")
    # (d) Hay un artículo que alcanza: guía.
    if articulo and articulo.get("suficiente"):
        b.append(f"artículo suficiente ({articulo.get('clave')}, {articulo.get('score')}): se guía con sus pasos")
        return fin("guia", guia=True)
    # (e) Artículo a medias: se afina con preguntas; sin preguntas, se guía con él.
    if articulo:
        if hay_pregunta and memoria.preguntas_hechas(mem) < MAX_PREGUNTAS_CON_ARTICULO:
            b.append(f"artículo a medias ({articulo.get('clave')}, {articulo.get('score')}): primero se afina con una pregunta")
            return fin("diagnostico", preguntar=True)
        b.append(f"artículo a medias ({articulo.get('clave')}, {articulo.get('score')}) y sin más preguntas: se guía con el mejor")
        return fin("guia", guia=True)
    # (f) Sin artículo: se pregunta lo que falta y, sin preguntas, incidencia.
    if hay_pregunta:
        b.append("no hay artículo que alcance: se pregunta lo que falta para diagnosticar")
        return fin("diagnostico", preguntar=True)
    b.append("no hay artículo que alcance y no quedan preguntas: se propone la incidencia")
    return fin("incidencia", accion="crear_incidencia", motivo_incidencia="sin_articulo", incidencia_tipo="incidente")
