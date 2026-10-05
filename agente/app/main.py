"""jsrbot · agente de la mesa de ayuda (FastAPI).

Cumple el contrato de `docs/CONTRATOS.md` §1:

    POST /chat                    el turno: mensaje + historial + etapa + memoria + perfil + incidencias abiertas → respuesta, etapa, memoria, acción
    GET  /salud                   {"ok": true, "modelo": "v1", "juez": "apagado"}
    POST /reentrenar              entrena una versión nueva y la deja como candidata; con `publicar: true` la publica solo si no empeora el reservado
    GET  /modelos                 versión publicada, candidatas y sus cifras sobre el reservado
    POST /modelos/{version}/publicar   publica una candidata si no empeora el reservado (409 si empeora)
    POST /conocimiento/recargar   {"articulos": [{clave, titulo, categoria, sintomas, pasos, cuerpo}]}
    GET  /conocimiento/articulos  los artículos del seed (SUPUESTO) para que el backend los cargue si su tabla está vacía
    GET  /                        chat de depuración (ui.html)

El agente NO guarda estado: la etapa y la memoria llegan y vuelven en cada turno (las persiste el backend). Propone; el backend
decide: prioridad, plazos, técnico y estado nunca salen de aquí. Orden de un turno (ARQUITECTURA §4):

    limpiar → ocultar secretos → clasificar (e5) → [juez local si el clasificador duda] → memoria.leer → ánimo → RAG → etapas.decidir
    → acción (propuesta de incidencia, dato, número) → respuesta (código o LLM, revisada) → memoria.registrar_respuesta
"""
from __future__ import annotations

import logging
import os
import re
import threading
import time
from contextlib import asynccontextmanager
from typing import Any

import numpy as np
from fastapi import Body, FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, ConfigDict

from . import animo, datos, entrenar as entrenamiento, estructurado, etapas, gasto, juez, lenguaje, memoria, modelo, plantillas, redactor, seguridad
from .conocimiento import Conocimiento, UMBRAL_MINIMO, UMBRAL_SUFICIENTE, BANDIDO_MODO
from .verificar import MODO as VERIFICAR_MODO, TAU_CONTESTA, Verificador

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("agente")

AQUI = os.path.dirname(os.path.abspath(__file__))
UMBRAL_INTENCION = float(os.environ.get("UMBRAL_INTENCION", "0.45"))
UMBRAL_CATEGORIA = float(os.environ.get("UMBRAL_CATEGORIA", "0.45"))
SIM_MISMO_SINTOMA = float(os.environ.get("SIM_MISMO_SINTOMA", "0.83"))          # misma categoría y parecido ≥ esto: mismo síntoma
SIM_MISMO_SINTOMA_ESTRICTO = float(os.environ.get("SIM_MISMO_SINTOMA_ESTRICTO", "0.90"))   # distinta o desconocida: hace falta más
SIM_MISMA_SOLICITUD = float(os.environ.get("SIM_MISMA_SOLICITUD", "0.93"))       # dos solicitudes solo se funden si son casi iguales
MAX_MENSAJE = 2000          # caracteres que se analizan de un mensaje (el resto se ignora, pero se guarda)
MAX_GUARDAR = 4000
PROBLEMA = ("reportar_falla", "solicitar_acceso", "solicitar_equipo", "restablecer_clave")
ESTADOS = ("nueva", "asignada", "en_curso", "espera_usuario", "espera_tercero", "resuelta", "cerrada", "reabierta")
CATEGORIA_LEGIBLE = {"correo": "correo", "cuentas_accesos": "cuentas y accesos", "red_wifi": "red y WiFi", "vpn": "VPN", "impresoras": "impresoras",
                     "equipo": "equipo", "software_oficina": "software de oficina", "sistema_interno": "sistema interno", "telefonia": "telefonía", "otro": "otro"}
MOTIVO_TEXTO = {"guia_agotada": "La guía no resolvió el problema.", "p1": "Afecta a una sede o a toda la organización: se registra sin guía.",
                "pidio_tecnico": "La persona pidió hablar con un técnico.", "sin_articulo": "No hay un artículo de la base de conocimiento que sirva para este caso."}
RE_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\ud800-\udfff]")


# ---------------------------------------------------------------------------
# Estado cargado al arrancar

class Estado:
    def __init__(self):
        t = time.time()
        self.emb = modelo.Embedder()
        self.lock = threading.Lock()
        self.reentrenando = threading.Lock()
        self._cargar_modelos()
        self.conocimiento = Conocimiento(self.emb)
        n = self.conocimiento.cargar_seed()
        self.verificador = Verificador(self.emb)
        self.emb(["hola"])      # la primera inferencia de ONNX es la lenta: que la pague el arranque
        log.info("agente listo en %.1fs (modelo %s, versión %s, %d artículos)", time.time() - t, self.emb.model_name, self.version, n)

    def _cargar_modelos(self, version: str | None = None):
        version = version or modelo.version_actual()
        if not os.path.exists(os.path.join(modelo.carpeta(version), "intencion.pkl")):
            if os.environ.get("AUTO_ENTRENAR", "1") != "1":
                raise RuntimeError(f"no hay modelo entrenado en {modelo.carpeta(version)}: corre `python -m app.entrenar`")
            log.warning("no hay modelo entrenado: se entrena ahora (python -m app.entrenar lo hace en el build)")
            entrenamiento.entrenar("v1", emb=self.emb, imprimir=False)
            modelo.publicar("v1")
            version = "v1"
        cab_i, cab_c, met = modelo.cargar("intencion.pkl", version), modelo.cargar("categoria.pkl", version), modelo.leer_metricas(version)
        with self.lock:
            self.cab_i, self.cab_c, self.metricas, self.version = cab_i, cab_c, met, version


E: Estado | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global E
    E = Estado()
    yield


app = FastAPI(title="jsrbot agente", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Modelos de la API (permisivos: lo raro se sanea, no se rechaza)

class ChatIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    caso_id: Any = None
    canal: Any = "web"
    mensaje: Any = ""
    historial: Any = None
    etapa: Any = "recepcion"
    memoria: Any = None
    perfil: Any = None
    incidencias_abiertas: Any = None
    ahora: Any = None
    usar_llm: bool = True       # solo para pruebas: False fuerza el respaldo por código aunque haya clave


def _limpio(t: Any) -> str:
    """Sin caracteres de control ni medios emojis (sustitutos sueltos): el tokenizador revienta con ellos."""
    if t is None:
        return ""
    return RE_CONTROL.sub("", t if isinstance(t, str) else str(t))


def _perfil(p: Any) -> dict:
    p = p if isinstance(p, dict) else {}
    out = {k: _limpio(p.get(k))[:80] for k in ("nombre", "sede", "area") if isinstance(p.get(k), str) and p.get(k).strip()}
    out["vip"] = p.get("vip") is True
    eq = p.get("equipos")
    out["equipos"] = [_limpio(e)[:40] for e in eq if isinstance(e, str) and e.strip()][:20] if isinstance(eq, list) else []
    return out


def _abiertas(lista: Any) -> list[dict]:
    out = []
    for i in (lista if isinstance(lista, list) else [])[:20]:
        if not isinstance(i, dict):
            continue
        num = i.get("numero")
        if not isinstance(num, str) or not re.fullmatch(r"INC-\d{1,10}", num):
            continue
        out.append({"numero": num, "estado": i.get("estado") if i.get("estado") in ESTADOS else "", "titulo": _limpio(i.get("titulo"))[:200],
                    "categoria": i.get("categoria") if i.get("categoria") in datos.CATEGORIAS else "",
                    "tecnico": _limpio(i.get("tecnico"))[:80] or None, "vence_resolucion_en": _limpio(i.get("vence_resolucion_en"))[:40] or None})
    return out


def _historial(h: Any) -> list[dict]:
    out = []
    for t in (h if isinstance(h, list) else [])[-30:]:
        if isinstance(t, dict) and isinstance(t.get("texto"), str):
            rol = t.get("rol") if t.get("rol") in ("usuario", "asistente", "tecnico") else "usuario"
            out.append({"rol": rol, "texto": seguridad.ocultar_secretos(_limpio(t["texto"])[:600])[0]})      # por si el backend guardó algo sin ocultar
    return out


# ---------------------------------------------------------------------------
# Clasificación

def clasificar(texto: str) -> dict:
    """Intención y categoría con su confianza calibrada. Vacío o ilegible: confianza 0 (se le pide que lo repita)."""
    if not re.search(r"\w", texto) or memoria.ilegible(texto):
        return {"intencion": "fuera_de_alcance", "confianza": 0.0, "top": [], "categoria": "otro", "categoria_confianza": 0.0, "vector": None}
    v = E.emb([texto[:MAX_MENSAJE]])
    with E.lock:
        ci, cc = E.cab_i, E.cab_c
    pi, pc = ci.predict_proba(v)[0], cc.predict_proba(v)[0]
    orden = np.argsort(-pi)
    top = [(str(ci.classes_[k]), round(float(pi[k]), 3)) for k in orden[:3]]
    cat, cat_conf, por_palabras = lenguaje.categoria_final(texto, str(cc.classes_[int(np.argmax(pc))]), float(pc.max()))
    return {"intencion": top[0][0], "confianza": float(pi[orden[0]]), "top": top, "categoria": cat, "categoria_confianza": cat_conf, "categoria_por_palabras": por_palabras, "vector": v}


# ---------------------------------------------------------------------------
# Piezas del turno

def _ficha_texto(mem: dict, perfil: dict) -> str:
    return memoria.lo_que_sabemos(mem, perfil)


def _mismo_sintoma(mem: dict, categoria: str, consulta: str, abiertas: list[dict], intent: str, etapa: str) -> dict | None:
    """La incidencia abierta que es del mismo síntoma que este caso, si la hay (una sola incidencia abierta por síntoma)."""
    cands = [i for i in abiertas if i["estado"] != "cerrada"]
    if not cands:
        return None
    if mem.get("incidencia"):
        hit = next((i for i in cands if i["numero"] == mem["incidencia"]), None)
        if hit:
            return hit
    if intent not in PROBLEMA or not consulta.strip():
        return None
    textos = [consulta[:300]] + [(i["titulo"] or "")[:300] for i in cands]
    v = E.emb(textos)
    sims = v[1:] @ v[0]
    mejor, mejor_sim = None, 0.0
    for i, s in zip(cands, sims):
        s = float(s)
        if not i["titulo"]:
            continue
        misma_cat = bool(categoria) and i["categoria"] == categoria
        if intent in ("solicitar_acceso", "solicitar_equipo"):
            ok = s >= SIM_MISMA_SOLICITUD and misma_cat
        else:
            ok = (misma_cat and s >= SIM_MISMO_SINTOMA) or s >= SIM_MISMO_SINTOMA_ESTRICTO
        if ok and s > mejor_sim:
            mejor, mejor_sim = i, s
    return mejor


def _consulta_rag(mem: dict, texto: str) -> str:
    """Lo que se busca en la base de conocimiento: el síntoma y lo que ya se sabe (programa y mensaje de error), sin repetir nada. El mensaje de
    este turno no se agrega aparte: lo que trae de útil (el programa, el error) ya está en la ficha, y repetirlo ensucia el parecido."""
    sab = mem["sabemos"]
    partes = [sab.get("sintoma") or texto or ""]
    for k in ("aplicacion", "mensaje_error"):
        v = sab.get(k)
        if v and v not in (memoria.DESCONOCIDO, memoria.SIN_MENSAJE) and str(v).lower() not in partes[0].lower():
            partes.append(str(v))
    return " ".join(p for p in partes if p)[:300]


def _titulo(mem: dict, categoria: str, tipo: str) -> str:
    sab = mem["sabemos"]
    base = (sab.get("solicitud") if tipo == "solicitud" else sab.get("sintoma")) or sab.get("sintoma") or ""
    base = base.strip()
    for _ in range(3):
        base = re.sub(r"^(?:hola|holaa+|buen[oa]s?(?: (?:dias|tardes|noches))?|buen dia|oye|disculpa|disculpen|por favor|ayuda|una consulta)\b[,.!\s]*", "", base, flags=re.I).strip()
    m = re.search(r"[.?!]\s", base)
    if m and m.start() >= 25:
        base = base[:m.start()]
    base = base.strip(" ,.;:!¡¿?")
    if len(base) > 90:
        base = base[:90].rsplit(" ", 1)[0]
    if not base:
        base = {"solicitud": "Solicitud de soporte", "consulta": "Solicitud de contacto con un técnico"}.get(tipo, "Incidencia de soporte")
    base = base[0].upper() + base[1:]
    app_ = sab.get("aplicacion")
    if app_ and app_.lower() not in base.lower() and app_ != memoria.DESCONOCIDO:
        base += f" ({app_})"
    return base[:120]


def _resumen(mem: dict, perfil: dict, categoria: str, motivo: str | None) -> str:
    sab = mem["sabemos"]
    lineas = []
    if sab.get("sintoma"):
        lineas.append(f"Problema: {sab['sintoma']}")
    if sab.get("solicitud") and sab.get("solicitud") != sab.get("sintoma"):
        lineas.append(f"Solicitud: {sab['solicitud']}")
    lineas.append(f"Categoría: {CATEGORIA_LEGIBLE.get(categoria, categoria)}")
    for k, nombre in (("aplicacion", "Programa o sistema"), ("mensaje_error", "Mensaje de error"), ("desde", "Desde"), ("impresora", "Impresora"), ("anexo", "Anexo"),
                      ("tipo_red", "Conexión"), ("equipo", "Equipo")):
        v = sab.get(k)
        if v and v not in (memoria.DESCONOCIDO,):
            lineas.append(f"{nombre}: {v if v != memoria.SIN_MENSAJE else 'no le aparece ningún mensaje'}")
    ubic = [x for x in (sab.get("sede"), sab.get("piso")) if x]
    if ubic:
        lineas.append("Ubicación: " + ", ".join(ubic))
    if sab.get("area"):
        lineas.append(f"Área: {sab['area']}")
    lineas.append(f"A cuántos afecta: {sab.get('impacto') or 'persona (no lo dijo)'}")
    if sab.get("pasos_probados"):
        lineas.append("Ya probó: " + ", ".join(sab["pasos_probados"]))
    if mem.get("articulos_mostrados"):
        lineas.append("Guía mostrada: " + ", ".join(mem["articulos_mostrados"]) + (" (no resolvió)" if motivo == "guia_agotada" else ""))
    if motivo:
        lineas.append(f"Motivo: {MOTIVO_TEXTO.get(motivo, motivo)}")
    return "\n".join(lineas)[:1500]


def _urgencia(d: dict, mem: dict) -> str:
    if d.get("urgencia_sugerida"):
        return d["urgencia_sugerida"]
    return mem["sabemos"].get("urgencia") or "media"


def _propuesta(d: dict, mem: dict, perfil: dict, categoria: str) -> dict:
    memoria.completar_con_perfil(mem, perfil)
    tipo = d.get("incidencia_tipo") or "incidente"
    return {"tipo": tipo, "categoria": categoria or "otro", "impacto": mem["sabemos"].get("impacto") or "persona", "urgencia": _urgencia(d, mem),
            "titulo": _titulo(mem, categoria, tipo), "resumen": _resumen(mem, perfil, categoria, d.get("motivo_incidencia")), "motivo": d.get("motivo_incidencia")}


def _sugerencia_tecnico(mem: dict, perfil: dict, categoria: str, d: dict, articulo_nuevo: dict | None) -> dict | None:
    """`{"texto", "articulo"?}` (la forma que lee la pasarela, CONTRATOS «Cambios»): un texto breve que el técnico podría enviar a la persona, armado por código (nunca por el LLM) desde el artículo o la ficha. None si no hay de qué.
    Solo cuando el caso está en manos de la mesa (etapa `incidencia` o `seguimiento`) y la ficha tiene síntoma; mientras el asistente guía o el caso se cierra, no.
    Con un artículo que la persona todavía no vio (el del turno o el que mejor encaja con el síntoma): hasta 3 de SUS pasos (solo del artículo; en un P1 no, que es una caída grande y no un asunto de la persona).
    Si no: el dato que falta o un acuse neutro (sin plazos ni promesas: lo que no sale del SLA no se dice)."""
    sintoma = (mem["sabemos"].get("sintoma") or "").strip()
    if not sintoma or d["etapa"] not in ("incidencia", "seguimiento") or d["accion"] in ("consultar_estado", "encuesta", "confirmar_solucion") or d.get("guia"):
        return None
    sintoma_completo, sintoma = sintoma, (sintoma if len(sintoma) <= 100 else sintoma[:99].rstrip() + "…")
    n = plantillas.nombre_pila(perfil)
    hola = f"Hola{', ' + n if n else ''}."
    art = articulo_nuevo
    if art is None and not d.get("p1"):         # el mejor artículo para el síntoma que la persona aún no vio
        rag = E.conocimiento.buscar(sintoma_completo, k=1, categoria=categoria or None, excluir=mem["articulos_mostrados"])
        art = E.conocimiento.articulo(rag["resultados"][0]["clave"]) if rag["resultados"] else None
    if art and art.get("pasos") and not d.get("p1"):
        pasos, _ = estructurado.pasos_para(art, mem["sabemos"].get("pasos_probados", []))
        pasos = pasos[:3]
        if pasos:
            return {"texto": f"{hola} Sobre tu caso ({sintoma}), si aún no lo hiciste, prueba esto:\n{estructurado.numerar(pasos)}\nCuéntanos cómo te fue y seguimos desde ahí.", "articulo": art["clave"]}
    k = memoria.siguiente(mem, categoria, mem.get("intencion_caso") or d["intencion"], perfil)
    if k:
        return {"texto": f"{hola} Para avanzar con tu caso ({sintoma}) necesitamos un dato más. {memoria.texto_pregunta(k, mem, categoria, perfil)}"}
    return {"texto": f"{hola} Tenemos registrado tu caso ({sintoma}). Si cambia algo o recuerdas otro dato, escríbenos por aquí."}


def _redactar_con_llm(req: ChatIn, d: dict, ctx: dict, base: dict, texto_ok: str, historial: list[dict], perfil: dict, nombres: list[str]) -> dict:
    """Con un LLM disponible, redacta la pieza «responde» con el caso ENMASCARADO; la revisa frase por frase (verificar.py), regenera una vez
    si hace falta y cae a la plantilla si no queda nada. Los pasos y la pregunta siguen siendo del código. Devuelve
    {"responde", "usado", "modelo", "quitadas", "regenerada", "veredicto"}."""
    out = {"responde": base["responde"], "usado": False, "modelo": None, "quitadas": 0, "regenerada": False, "veredicto": None}
    mem, art = ctx["mem"], ctx.get("articulo")
    prep = lambda t: seguridad.preparar_para_llm(t, nombres)
    caso = {"etapa": d["etapa"], "intencion": d["intencion"], "categoria": ctx.get("categoria"), "ficha": prep(_ficha_texto(mem, perfil)),
            "mensaje": prep(texto_ok), "articulo": art["titulo"] if art and d.get("guia") else "",
            "turnos": [prep(f"{t['rol']}: {t['texto']}")[:200] for t in historial[-4:]]}
    fmt = estructurado.formato(base["pregunta"], permitir_pregunta=False)
    fuentes = [art["cuerpo"] or " ".join(art["pasos"])] if art else []
    contexto = [texto_ok, _ficha_texto(mem, perfil)]
    intentos = 0
    sufijo = ""
    while intentos < 2:
        intentos += 1
        try:
            crudo, modelo_llm = redactor.llamar(redactor.mensajes(caso, fmt + sufijo))
        except Exception as e:  # noqa: BLE001
            log.warning("sin LLM este turno: %s", e)
            return out
        out["usado"], out["modelo"] = True, modelo_llm
        responde = estructurado.responde_de_llm(crudo)
        if not responde:
            return out
        responde = seguridad.quitar_marcadores(responde, plantillas.nombre_pila(perfil))
        rev = E.verificador.revisar(responde, fuentes, contexto, pregunta=texto_ok)
        out["veredicto"] = {"modo": rev["modo"], "quitadas": rev["quitadas"], "contesta": rev["contesta"], "ms": rev["ms"]}
        activo = rev["modo"] == "activo"
        if activo:      # en sombra se registra lo que se habría quitado (en el veredicto), pero no se quita nada ni se regenera
            out["quitadas"] += len(rev["quitadas"])
        mal_contesta = activo and rev["contesta"] is not None and rev["contesta"] < TAU_CONTESTA and bool(texto_ok.strip())
        if (rev["regenerar"] or mal_contesta) and intentos == 1:
            out["regenerada"] = True
            sufijo = "\nOJO: tu respuesta anterior " + ("incluía algo que no está en la guía ni en lo que dijo la persona; " if rev["regenerar"] else "no atendía lo que la persona pidió; ") + \
                     "usa solo lo que está en el contexto y contesta lo que preguntó."
            continue
        final = rev["texto"].strip() if activo else responde
        if final and not (rev["regenerar"] and not final):
            out["responde"] = final
        return out
    return out


# ---------------------------------------------------------------------------
# El turno

def conversar(req: ChatIn) -> dict:
    t0 = time.perf_counter()
    gasto.iniciar()
    entrada = _limpio(req.mensaje)
    texto_guardar, tipos_secreto = seguridad.ocultar_secretos(entrada[:MAX_GUARDAR])
    texto_ok = texto_guardar[:MAX_MENSAJE].strip()           # lo que se analiza: ya sin contraseñas ni tokens
    perfil, abiertas, historial = _perfil(req.perfil), _abiertas(req.incidencias_abiertas), _historial(req.historial)
    etapa_in = req.etapa if req.etapa in datos.ETAPAS else "recepcion"
    mem = memoria.normalizar(req.memoria) if isinstance(req.memoria, dict) and req.memoria else memoria.reconstruir(historial, etapa_in, perfil)
    pendiente_previo = mem["pendiente"]
    bit: list[str] = []

    # 1. Clasificar
    cl = clasificar(texto_ok)
    intent, conf = cl["intencion"], cl["confianza"]
    cat_pred, cat_conf = cl["categoria"], cl["categoria_confianza"]
    if cl.get("categoria_por_palabras"):
        bit.append(f"las palabras del mensaje fijan la categoría «{cat_pred}» (el clasificador dudaba)")
    veredictos: dict = {}

    # 2. Juez local (solo si el clasificador duda; nunca bloquea)
    if conf < juez.UMBRAL and juez.activo() and texto_ok:
        est = juez.estado(texto_ok, historial, etapa_in, pendiente_previo, _ficha_texto(mem, perfil), mem.get("categoria", ""))
        j = juez.clasificar(est)
        if j:
            veredictos["clasificacion"] = {"intent": j["intent"], "confianza": j["confianza"], "ms": j["ms"], "fuente": j["fuente"], "local": {"intent": intent, "confianza": round(conf, 3)}}
            if juez.modo() == "activo" and j["confianza"] >= conf and j["intent"] != intent:
                bit.append(f"el juez local ({j['confianza']:.2f}) corrige la intención «{intent}» ({conf:.2f}) → «{j['intent']}»")
                intent, conf = j["intent"], j["confianza"]
            veredictos["clasificacion"]["usado"] = juez.modo() == "activo" and j["intent"] == intent and j["intent"] != cl["intencion"]
            veredictos["datos_propuestos"] = {k: v for k, v in j["datos"].items() if v and v.lower() in texto_ok.lower()}

    # 3. ¿Cambia de tema? (se calcula con una copia: lo que diga de la pregunta pendiente no es otro tema)
    tmp = memoria.copia(mem)
    respondio_hipotetico = memoria.leer(tmp, texto_ok, perfil)["respondio"]
    # Lo que la persona dice manda sobre lo que opine el clasificador («sigue igual», «quiero un técnico», la respuesta a la pregunta pendiente…):
    # la misma intención que usará etapas.decidir, para decidir también la categoría y el síntoma con ella.
    intent_ef, conf_ef = etapas.intencion_efectiva(etapa_in, intent, conf, texto_ok, pendiente=pendiente_previo, respondio_pendiente=respondio_hipotetico, mem=mem, abiertas=abiertas)
    if intent_ef != intent:
        bit.append(f"las reglas de lenguaje corrigen la intención «{intent}» ({conf:.2f}) → «{intent_ef}»")
        intent, conf = intent_ef, conf_ef
    cat_actual = mem["categoria"]
    kw_cat, marca_tema = lenguaje.categoria_por_palabras(texto_ok), lenguaje.marca_otro_tema(texto_ok)
    es_problema = intent in PROBLEMA and conf >= etapas.UMBRAL_MEDIO
    cat_nueva = cat_pred if cat_conf >= UMBRAL_CATEGORIA else ""
    # ¿Empieza OTRO problema? Hace falta evidencia fuerte: nombra un objeto concreto de otra categoría (la impresora, la VPN, el correo…), o avisa que cambia
    # de tema, o el clasificador está muy seguro. Una descripción más del mismo problema («me sale error de autenticación») no lo es.
    via_palabras = bool(kw_cat and kw_cat != cat_actual and kw_cat in lenguaje.CATEGORIAS_ESPECIFICAS and (es_problema or marca_tema))
    via_clasificador = bool(es_problema and cat_nueva and cat_nueva != cat_actual and cat_nueva in lenguaje.CATEGORIAS_ESPECIFICAS and conf >= 0.9 and cat_conf >= 0.9)
    via_restablecer = bool(intent == "restablecer_clave" and lenguaje.pide_restablecer(texto_ok) and cat_actual and cat_actual != "cuentas_accesos")
    cambia_categoria = bool(cat_actual and not respondio_hipotetico and (via_palabras or via_clasificador or via_restablecer))
    if via_palabras and marca_tema and not es_problema:
        intent, conf, es_problema = "reportar_falla", max(conf, 0.6), True
        bit.append("avisa que cambia de tema y nombra otro objeto: se toma como un problema nuevo")
    mismo_pre = _mismo_sintoma(mem, cat_nueva or cat_actual, texto_ok, abiertas, intent, etapa_in) if es_problema and not respondio_hipotetico else None
    nuevo_caso = bool(es_problema and not respondio_hipotetico and not mismo_pre and (
        etapa_in in ("encuesta", "cierre", "consulta_estado", "seguimiento", "incidencia") or (cambia_categoria and etapa_in in ("diagnostico", "guia"))))
    if nuevo_caso:
        memoria.nuevo_tema(mem, ("cuentas_accesos" if via_restablecer else (kw_cat if via_palabras else cat_nueva)) or "")
        bit.append("otro problema distinto del anterior: ficha en blanco")
    cambio_tema = nuevo_caso or cambia_categoria

    # 4. Memoria: leer el mensaje contra la pregunta pendiente
    lectura = memoria.leer(mem, texto_ok, perfil)
    if es_problema:
        if not mem["sabemos"].get("sintoma"):
            mem["sabemos"]["sintoma"] = seguridad.sin_datos_personales(texto_ok, seguridad.nombres_del_caso(perfil, abiertas))[:140]
        mem["intencion_caso"] = mem["intencion_caso"] if (mem["intencion_caso"] and not nuevo_caso and etapa_in in ("diagnostico", "guia")) else intent
        if intent in ("solicitar_acceso", "solicitar_equipo") and not mem["sabemos"].get("solicitud") and lectura["datos"].get("solicitud"):
            mem["sabemos"]["solicitud"] = lectura["datos"]["solicitud"]
    # La categoría: la del clasificador si está segura y el mensaje describe un caso; si no, la que ya tenía el caso.
    if cat_nueva and (intent in datos.INTENCIONES_CASO or (intent == "aportar_dato" and mem["sabemos"].get("sintoma"))) and (es_problema or not mem["categoria"]):
        if intent in datos.INTENCIONES_CASO or not mem["categoria"]:
            mem["categoria"] = cat_nueva
    if nuevo_caso and (via_palabras or via_restablecer):
        mem["categoria"] = "cuentas_accesos" if via_restablecer else kw_cat
    categoria = mem["categoria"] or (cat_nueva if intent in datos.INTENCIONES_CASO else "")
    if intent == "restablecer_clave" and not mem["categoria"]:
        mem["categoria"] = categoria = "cuentas_accesos"
    # Datos que propone el juez y las reglas no vieron: solo los que están, tal cual, en el mensaje (el juez propone; el código decide).
    for k, v in (veredictos.get("datos_propuestos") or {}).items():
        if k in ("equipo", "aplicacion", "desde", "mensaje_error") and not mem["sabemos"].get(k) and juez.modo() == "activo":
            mem["sabemos"][k] = v
            lectura["nuevos"].setdefault(k, v)

    # 5. Ánimo y señales
    an = animo.evaluar(texto_ok, mem)

    # 6. RAG: solo cuando hay un problema que guiar
    articulo_dec, rag, mostrados = None, None, mem["articulos_mostrados"]
    if intent in ("reportar_falla", "restablecer_clave") or (intent == "aportar_dato" and etapa_in in ("diagnostico", "guia", "recepcion")) or lectura["respondio"]:
        if mem["sabemos"].get("sintoma"):
            consulta = _consulta_rag(mem, texto_ok)
            # «Olvidé la contraseña del sistema de ventas» es un tema de cuentas, no del sistema de ventas.
            cat_rag = "cuentas_accesos" if (intent == "restablecer_clave" or mem.get("intencion_caso") == "restablecer_clave") else (categoria or None)
            rag = E.conocimiento.buscar(consulta, k=3, categoria=cat_rag)
            if rag["resultados"]:
                top = rag["resultados"][0]
                # Lo que más se parece ya se mostró: no se cambia de guía por un dato suelto (se le recuerda probar los pasos).
                if top["clave"] not in mostrados:
                    articulo_dec = {"clave": top["clave"], "score": top["score"], "suficiente": rag["suficiente"]}

    # 7. ¿Mismo síntoma que una incidencia abierta?
    mismo = _mismo_sintoma(mem, categoria, mem["sabemos"].get("sintoma") or texto_ok, abiertas, intent, etapa_in)
    if mismo is None and (etapa_in in ("seguimiento", "incidencia") or mem.get("incidencia")) and abiertas and not nuevo_caso:
        mismo = next((i for i in abiertas if i["numero"] == mem.get("incidencia")), None) or (
            next((i for i in abiertas if categoria and i["categoria"] == categoria), None) or (abiertas[0] if len(abiertas) == 1 else None)) if intent not in PROBLEMA else None

    # 8. Decidir la etapa y la acción
    k_sig = memoria.siguiente(mem, categoria, mem.get("intencion_caso") or intent, perfil)
    d = etapas.decidir(
        etapa_in, intent, conf, texto_ok, pendiente=pendiente_previo, respondio_pendiente=lectura["respondio"], categoria=categoria, mem=mem,
        articulo=articulo_dec, hay_pregunta=bool(k_sig), abiertas=abiertas, mismo_sintoma=mismo, primer_mensaje=not historial and etapa_in == "recepcion",
        cambio_tema=cambio_tema and not nuevo_caso, datos_nuevos={k: v for k, v in lectura["nuevos"].items() if k not in ("caida", "pasos_probados")} or None,
        es_solicitud_concreta=bool(lectura["datos"].get("solicitud") or mem["sabemos"].get("solicitud")))
    bit += d["bitacora"]

    # 9. Aplicar la decisión a la memoria
    articulo_full = None
    if d["guia"] and rag and rag["resultados"]:
        articulo_full = E.conocimiento.articulo(rag["resultados"][0]["clave"])
        mem["intentos_guia"] += 1
        if articulo_full["clave"] not in mostrados:
            mostrados.append(articulo_full["clave"])
        mem["turnos_guia"] = 0
    elif d["etapa"] == "guia":
        mem["turnos_guia"] += 1
    else:
        mem["turnos_guia"] = 0
    if d["accion"] in ("confirmar_solucion", "sigue_igual") and mostrados:
        E.conocimiento.registrar_uso(mostrados[-1], categoria or "otro", d["accion"] == "confirmar_solucion")
    mem["sin_entender"] = 0 if d["entendido"] else mem["sin_entender"] + 1
    if d.get("numero"):
        mem["incidencia"] = d["numero"]
    d_resp = dict(d)
    if d["preguntar"]:
        k_sig = memoria.siguiente(mem, categoria, mem.get("intencion_caso") or intent, perfil) or "que_pasa"
    # sede_piso con la sede ya sabida: se pregunta solo el piso (texto_pregunta lo resuelve)

    # 10. Componer la respuesta (código) y, si hay LLM, mejorar la pieza «responde»
    pasos, saltados = estructurado.pasos_para(articulo_full, mem["sabemos"].get("pasos_probados", [])) if articulo_full else ([], [])
    if articulo_full and not estructurado.solo_del_articulo(pasos, articulo_full):      # no debería pasar nunca; si pasa, no se muestra
        pasos, d_resp["guia"] = [], False
        log.error("los pasos a mostrar no coinciden con el artículo %s", articulo_full["clave"])
    ctx = {"mem": mem, "perfil": perfil, "categoria": categoria, "articulo": articulo_full, "pasos": pasos, "saltados": saltados, "pregunta_clave": k_sig, "secreto": bool(tipos_secreto)}
    comp = plantillas.componer(d_resp, ctx)
    nombres = seguridad.nombres_del_caso(perfil, abiertas)
    llm = {"usado": False, "modelo": None, "quitadas": 0, "regenerada": False, "veredicto": None}
    if req.usar_llm and redactor.disponible() and not comp["texto_null"] and (d_resp.get("guia") or d_resp.get("preguntar") or d_resp.get("recordar_pasos")) and d["entendido"]:
        llm = _redactar_con_llm(req, d_resp, ctx, comp, texto_ok, historial, perfil, nombres)
        if llm["usado"] and llm["responde"] != comp["responde"]:
            comp["responde"] = (seguridad.AVISO_CONTRASENA + " " if tipos_secreto else "") + llm["responde"]
    respuesta = estructurado.armar(comp["responde"], comp["pasos"], comp["pregunta"]) or None
    if comp["texto_null"] and not comp["responde"]:
        respuesta = None
    if comp["pendiente"]:
        memoria.registrar_respuesta(mem, forzar=comp["pendiente"])
    else:
        memoria.registrar_respuesta(mem, "")
    memoria.anotar_turno(mem, d["etapa"], categoria, [articulo_full["clave"]] if articulo_full else [])
    if mem["sabemos"].get("sintoma") is None and intent in PROBLEMA:
        mem["sabemos"]["sintoma"] = seguridad.sin_datos_personales(texto_ok, seguridad.nombres_del_caso(perfil, abiertas))[:140]

    # 11. La acción del contrato
    accion: dict = {"tipo": d["accion"]}
    if d["accion"] in ("crear_incidencia",) or (d["accion"] == "pedir_tecnico" and not d.get("numero")):
        accion["incidencia"] = _propuesta(d, mem, perfil, categoria)
    if d.get("numero"):
        accion["numero"] = d["numero"]
    if d["accion"] == "agregar_dato":
        nuevos = [{"clave": k, "valor": v} for k, v in lectura["nuevos"].items() if k not in ("caida",) and v]
        accion["dato"] = d.get("dato") or (nuevos[0] if nuevos else {"clave": "comentario", "valor": texto_ok[:200]})
        accion["datos"] = nuevos or [accion["dato"]]
    if d["accion"] == "encuesta":
        accion["puntaje"] = d.get("puntaje")
        accion["dato"] = d.get("dato")
    # El contrato manda `valor` como texto (un backend en Go lo decodifica a string): las listas se unen con comas y los números se vuelven texto.
    for dato in ([accion["dato"]] if accion.get("dato") else []) + list(accion.get("datos") or []):
        v = dato.get("valor")
        dato["valor"] = ", ".join(str(x) for x in v) if isinstance(v, (list, tuple)) else str(v)
    usados = [articulo_full["clave"]] if articulo_full else ([mostrados[-1]] if d["etapa"] == "guia" and mostrados else [])

    if accion.get("incidencia"):
        categoria = categoria or accion["incidencia"]["categoria"]      # la respuesta dice la misma categoría que la propuesta
    es_caso = intent in datos.INTENCIONES_CASO or d["accion"] in ("crear_incidencia", "pedir_tecnico") or bool(categoria)
    senales = {"animo": an["animo"], "queja": bool(an["queja"] or d["intencion"] == "queja"), "pide_tecnico": bool(d["pide_tecnico"]), "contrasena_oculta": bool(tipos_secreto)}
    if rag is not None:
        veredictos["rag"] = {"modo_bandido": rag["modo_bandido"], "orden_puro": rag["orden_puro"], "orden_bandido": rag["orden_bandido"]}
    if llm["veredicto"]:
        veredictos["verificacion"] = llm["veredicto"] | {"regenerada": llm["regenerada"]}
    art_nuevo = E.conocimiento.articulo(articulo_dec["clave"]) if articulo_dec and not d["guia"] else None     # un artículo que la persona aún no vio
    sugerencia = _sugerencia_tecnico(mem, perfil, categoria, d, art_nuevo)
    ms = int((time.perf_counter() - t0) * 1000)
    out = {
        "respuesta": respuesta, "etapa": d["etapa"], "memoria": mem, "intencion": d["intencion"], "confianza": round(d["confianza"], 3),
        "categoria": categoria or None if es_caso or categoria else None, "categoria_confianza": round(cat_conf, 3) if (categoria or es_caso) else None,
        "accion": accion, "articulos_usados": usados, "senales": senales, "texto_usuario_guardar": texto_guardar, "sugerencia_tecnico": sugerencia,
        "juez": {"modo": juez.modo(), "veredictos": veredictos}, "latencia_ms": ms,
        # Extras que el contrato no pide y el backend puede ignorar (CONTRATOS «Cambios»): costo y calidad por turno, y el análisis para la consola.
        "costo_usd": gasto.total(), "regenerada": llm["regenerada"], "frases_quitadas": llm["quitadas"],
        "analisis": {"bitacora": bit, "top_intenciones": cl["top"], "nivel": d["nivel"], "entendido": d["entendido"], "p1": d["p1"], "lo_que_sabemos": _ficha_texto(mem, perfil),
                     "articulo": articulo_dec, "llm": {"usado": llm["usado"], "modelo": llm["modelo"]}, "secretos": tipos_secreto,
                     "pregunta_siguiente": k_sig if d["preguntar"] else ""},
    }
    log.info("turno caso=%s etapa=%s→%s intención=%s(%.2f) acción=%s %dms", req.caso_id, etapa_in, d["etapa"], d["intencion"], d["confianza"], d["accion"], ms)
    return out


# ---------------------------------------------------------------------------
# Rutas

@app.get("/salud")
def salud():
    return {"ok": E is not None, "modelo": E.version if E else None, "juez": juez.modo()}


@app.get("/metricas")
def metricas():
    return {"modelo": E.version, "entrenamiento": E.metricas, "juez": {"modo": juez.modo(), "url_configurada": bool(juez.URL), "umbral": juez.UMBRAL},
            "llm": redactor.estado(), "verificar": {"modo": VERIFICAR_MODO, "nli": bool(E.verificador.nli), "lettuce": bool(E.verificador.lettuce)},
            "rag": {"articulos": len(E.conocimiento.articulos), "umbral_minimo": UMBRAL_MINIMO, "umbral_suficiente": UMBRAL_SUFICIENTE, "bandido": BANDIDO_MODO},
            "umbrales": {"intencion": UMBRAL_INTENCION, "categoria": UMBRAL_CATEGORIA, "etapas_alto": etapas.UMBRAL_ALTO, "etapas_medio": etapas.UMBRAL_MEDIO}}


class TextoIn(BaseModel):
    texto: Any = ""


@app.post("/clasificar")
def ruta_clasificar(req: TextoIn):
    """Depuración: cómo clasifica el modelo un mensaje suelto."""
    cl = clasificar(_limpio(req.texto))
    cl.pop("vector", None)
    return cl


@app.post("/chat")
def ruta_chat(req: ChatIn):
    return conversar(req)


@app.post("/conocimiento/recargar")
def ruta_recargar(cuerpo: Any = Body(default=None)):
    arts = cuerpo.get("articulos") if isinstance(cuerpo, dict) else (cuerpo if isinstance(cuerpo, list) else None)
    if not isinstance(arts, list):
        return JSONResponse({"error": "El cuerpo debe traer {\"articulos\": [...]}.", "codigo": "invalido"}, status_code=400)
    n = E.conocimiento.cargar(arts)
    return {"ok": True, "articulos": n, "descartados": len(arts) - n}


@app.get("/conocimiento")
def ruta_conocimiento():
    return {"articulos": [{"clave": a["clave"], "titulo": a["titulo"], "categoria": a["categoria"], "pasos": len(a["pasos"])} for a in E.conocimiento.articulos]}


RE_VERSION = re.compile(r"^v[0-9]{1,6}$")


def _reservado(met: dict) -> dict:
    """Las cifras del conjunto reservado de un modelo: {intencion: {exactitud, f1_macro}, categoria: {...}}."""
    f = lambda k: {"exactitud": (met.get(k, {}).get("reservado", {}) or {}).get("exactitud"), "f1_macro": (met.get(k, {}).get("reservado", {}) or {}).get("f1_macro")}
    return {"intencion": f("intencion"), "categoria": f("categoria")}


def _no_empeora(nuevo: dict, actual: dict) -> bool:
    """La regla de publicación: ni la intención ni la categoría bajan de exactitud en el conjunto reservado respecto a la publicada."""
    n, a = _reservado(nuevo), _reservado(actual)
    return all((n[k]["exactitud"] or 0) >= (a[k]["exactitud"] or 0) for k in ("intencion", "categoria"))


def _numero(version: str) -> int:
    return int(version[1:]) if RE_VERSION.match(version or "") else 0


def _publicar_modelo(version: str, forzar: bool = False) -> tuple[bool, bool]:
    """Publica `version` si no empeora el reservado (o si una persona lo fuerza) y la carga en caliente. Devuelve (publicado, no_empeora).
    Quien llama ya tiene `E.reentrenando`."""
    ok = _no_empeora(modelo.leer_metricas(version), E.metricas)
    if ok or forzar:
        modelo.publicar(version)
        E._cargar_modelos(version)
        return True, ok
    return False, ok


@app.get("/conocimiento/articulos")
def ruta_articulos_seed():
    """Los artículos del seed (`seed/articulos.json`, todos SUPUESTO) con la forma de `POST /conocimiento/recargar`, para que el backend los cargue
    en su tabla cuando esté vacía. Siempre los del seed, aunque después se hayan recargado otros."""
    return {"articulos": [{"clave": a["clave"], "titulo": a["titulo"], "categoria": a["categoria"], "sintomas": a["sintomas"], "pasos": a["pasos"], "cuerpo": a["cuerpo"], "supuesto": True}
                          for a in E.conocimiento.seed_articulos()]}


@app.post("/reentrenar")
def ruta_reentrenar(cuerpo: Any = Body(default=None)):
    """Entrena una versión nueva (con los ejemplos revisados que mande el backend) y la deja como CANDIDATA con sus cifras.
    Con `publicar: true` la publica solo si no empeora el reservado; la aprobación de una persona va por `POST /modelos/{version}/publicar`.
    `forzar: true` (decisión de una persona) publica aunque empeore."""
    cuerpo = cuerpo if isinstance(cuerpo, dict) else {}
    extra = [r for r in (cuerpo.get("ejemplos") or []) if isinstance(r, dict)]
    reservados = {re.sub(r"[^\w ]", "", datos.plano(p["mensaje"])) for p in datos.prueba()}
    extra = [r for r in extra if str(r.get("mensaje") or "").strip() and (r.get("intencion") in datos.INTENCIONES or r.get("categoria") in datos.CATEGORIAS)]
    extra = [r for r in extra if re.sub(r"[^\w ]", "", datos.plano(str(r.get("mensaje", "")))) not in reservados]   # el reservado no se contamina
    forzar = cuerpo.get("forzar") is True
    pide_publicar = cuerpo.get("publicar") is True or forzar
    if not E.reentrenando.acquire(blocking=False):
        return JSONResponse({"error": "Ya hay un reentrenamiento en curso.", "codigo": "conflicto"}, status_code=409)
    try:
        actual = E.metricas
        version = modelo.siguiente_version()
        nuevo = entrenamiento.entrenar(version, extra=extra, emb=E.emb, imprimir=False)
        ri, rc = nuevo["intencion"]["reservado"], nuevo["categoria"]["reservado"]
        ai, ac = (actual.get("intencion", {}).get("reservado", {}), actual.get("categoria", {}).get("reservado", {}))
        publicado, mejora = _publicar_modelo(version, forzar) if pide_publicar else (False, _no_empeora(nuevo, actual))
        motivo = "" if publicado else ("no mejora el conjunto reservado: no se publica" if pide_publicar
                                       else f"queda como candidato{'' if mejora else ' (empeora el conjunto reservado)'}: se publica con POST /modelos/{version}/publicar")
        return {"ok": True, "modelo": version, "publicado": publicado, "candidato": not publicado, "no_empeora": mejora, "actual": E.version,
                "intencion": {"exactitud": ri["exactitud"], "f1_macro": ri["f1_macro"], "antes": ai.get("exactitud")},
                "categoria": {"exactitud": rc["exactitud"], "f1_macro": rc["f1_macro"], "antes": ac.get("exactitud")},
                "ejemplos_extra": len(extra), "motivo": motivo}
    finally:
        E.reentrenando.release()


@app.get("/modelos")
def ruta_modelos():
    """La versión publicada y los candidatos (entrenados y sin publicar) con sus cifras sobre el reservado. La aprobación humana la hace la consola."""
    publicada = E.version
    modelos = []
    for v in modelo.versiones():
        met = modelo.leer_metricas(v)
        if not met:
            continue
        estado = "publicada" if v == publicada else ("candidata" if _numero(v) > _numero(publicada) else "anterior")
        modelos.append({"version": v, "estado": estado, **_reservado(met), "n_ejemplos_intencion": met.get("n_ejemplos_intencion"), "n_ejemplos_categoria": met.get("n_ejemplos_categoria"),
                        "no_empeora": True if v == publicada else _no_empeora(met, E.metricas)})
    return {"publicada": publicada, "cifras_publicada": _reservado(E.metricas), "candidatos": [m["version"] for m in modelos if m["estado"] == "candidata"], "modelos": modelos}


@app.post("/modelos/{version}/publicar")
def ruta_publicar_modelo(version: str, cuerpo: Any = Body(default=None)):
    """Publica un candidato si no empeora el reservado (409 si empeora; `forzar: true` es la decisión explícita de una persona)."""
    cuerpo = cuerpo if isinstance(cuerpo, dict) else {}
    if not RE_VERSION.match(version) or not os.path.exists(os.path.join(modelo.carpeta(version), "intencion.pkl")) or not modelo.leer_metricas(version):
        return JSONResponse({"error": "Esa versión no existe.", "codigo": "no_existe"}, status_code=404)
    if not E.reentrenando.acquire(blocking=False):
        return JSONResponse({"error": "Hay un reentrenamiento en curso.", "codigo": "conflicto"}, status_code=409)
    try:
        if version == E.version:
            return {"ok": True, "modelo": version, "publicado": True, "actual": E.version, "motivo": "ya es la versión publicada"}
        antes = _reservado(E.metricas)
        publicado, mejora = _publicar_modelo(version, cuerpo.get("forzar") is True)
        cifras = {"intencion": _reservado(modelo.leer_metricas(version))["intencion"] | {"antes": antes["intencion"]["exactitud"]},
                  "categoria": _reservado(modelo.leer_metricas(version))["categoria"] | {"antes": antes["categoria"]["exactitud"]}}
        if not publicado:
            return JSONResponse({"error": "Empeora el conjunto reservado: no se publica.", "codigo": "empeora", "modelo": version, "actual": E.version, "no_empeora": False, **cifras}, status_code=409)
        return {"ok": True, "modelo": version, "publicado": True, "actual": E.version, "no_empeora": mejora, **cifras}
    finally:
        E.reentrenando.release()


@app.get("/", response_class=HTMLResponse)
def ui():
    with open(os.path.join(AQUI, "ui.html"), encoding="utf-8") as f:
        return HTMLResponse(f.read(), headers={"Cache-Control": "no-store"})
