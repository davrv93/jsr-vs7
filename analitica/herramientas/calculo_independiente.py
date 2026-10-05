#!/usr/bin/env python3
"""Calculo INDEPENDIENTE de los 12 KPI sobre los .jsonl de la semilla, sin ClickHouse.

Existe para vigilar a las golden queries: los estudios sobre BIRD y Spider hallaron errores en sus propias consultas
«de oro», asi que ningun esperado.csv se acepta solo porque ClickHouse lo devuelva. Aqui cada KPI se recalcula con
bucles y diccionarios de Python, leyendo los mismos archivos, y se compara con esperado.csv.

No comparte codigo con el generador ni con el SQL. Lo unico comun es la DEFINICION escrita en cada meta.yaml.
Reglas de lectura que replica a mano (lo que en ClickHouse hacen FINAL, LIMIT 1 BY y GROUP BY):
  * eventos_incidencia: un evento por id.
  * incidencias_estado, incidencias_tiempos, casos_estado: la fila de mayor version (a igual version, la ultima del archivo).
  * mensajes, feedback: una fila por id.
  * encuestas: se juntan por id: puntaje = el mayor no nulo, ts = el menor.
Hora de Lima = UTC-5 fijo (Lima no tiene horario de verano): no depende de tzdata.

Uso:
  python3 calculo_independiente.py <kpi> <desde> <hasta> [grupo]      # imprime el resultado como CSV
"""
import csv
import io
import math
import os
import sys
from datetime import date, datetime, timedelta

CARPETA_SEMILLA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "semilla")
LIMA = timedelta(hours=-5)


def _t(txt):
    return datetime.strptime(txt, "%Y-%m-%dT%H:%M:%SZ") if txt else None


def _dia_lima(txt):
    return (_t(txt) + LIMA).date()


def _leer(nombre):
    import json
    with open(os.path.join(CARPETA_SEMILLA, nombre + ".jsonl"), encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


class Datos:
    def __init__(self):
        # eventos: uno por id
        self.eventos = {}
        for r in _leer("eventos_incidencia"):
            self.eventos.setdefault(r["id"], r)
        # versionadas: gana la mayor version; a igual version, la ultima leida
        self.inc = self._ultima(_leer("incidencias_estado"), "incidencia_id")
        self.tie = self._ultima(_leer("incidencias_tiempos"), "incidencia_id")
        self.cas = self._ultima(_leer("casos_estado"), "caso_id")
        self.mensajes = {}
        for r in _leer("mensajes"):
            self.mensajes.setdefault(r["id"], r)
        self.feedback = {}
        for r in _leer("feedback"):
            self.feedback.setdefault(r["id"], r)
        enc = {}
        for r in _leer("encuestas"):
            e = enc.setdefault(r["id"], {"id": r["id"], "incidencia_id": r["incidencia_id"], "caso_id": r["caso_id"],
                                         "ts": r["ts"], "puntaje": None})
            if r["ts"] < e["ts"]:
                e["ts"] = r["ts"]
            if r["puntaje"] is not None and (e["puntaje"] is None or r["puntaje"] > e["puntaje"]):
                e["puntaje"] = r["puntaje"]
        self.encuestas = enc
        # grupo de origen = el del evento «creada»
        self.origen = {}
        for e in self.eventos.values():
            if e["tipo"] == "creada":
                self.origen[e["incidencia_id"]] = e["grupo"]
        # eventos por incidencia, en orden (ts, id)
        self.por_inc = {}
        for e in sorted(self.eventos.values(), key=lambda x: (x["ts"], x["id"])):
            self.por_inc.setdefault(e["incidencia_id"], []).append(e)

    @staticmethod
    def _ultima(filas, clave):
        out = {}
        for r in filas:
            k = r[clave]
            if k not in out or r["version"] >= out[k]["version"]:
                out[k] = r
        return out


def cuantil_inclusivo(valores, p):
    """Interpolacion lineal entre los puntos (n-1)*p, como PERCENTILE.INC / numpy.percentile por defecto."""
    x = sorted(valores)
    n = len(x)
    if n == 0:
        return None
    h = (n - 1) * p
    lo = int(math.floor(h))
    hi = min(lo + 1, n - 1)
    return x[lo] + (h - lo) * (x[hi] - x[lo])


def pct(a, b):
    return None if b == 0 else 100.0 * a / b


def en_periodo(txt_utc, desde, hasta):
    return desde <= _dia_lima(txt_utc) <= hasta


def del_grupo_origen(D, inc_id, grupo):
    return grupo == "" or D.origen.get(inc_id) == grupo


# --------------------------------------------------------------------------------------------------------------
# KPI
# --------------------------------------------------------------------------------------------------------------

def sla_cumplimiento(D, desde, hasta, grupo):
    base = [t for t in D.tie.values() if en_periodo(t["creada_en"], desde, hasta) and del_grupo_origen(D, t["incidencia_id"], grupo)]
    filas = []
    for metrica, campo in (("respuesta", "sla_respuesta_ok"), ("resolucion", "sla_resolucion_ok")):
        con_veredicto = [t[campo] for t in base if t[campo] is not None]
        cumplidas = sum(1 for v in con_veredicto if v == 1)
        filas.append((metrica, len(con_veredicto), cumplidas, pct(cumplidas, len(con_veredicto))))
    return ["metrica", "evaluadas", "cumplidas", "porcentaje"], filas


def frt(D, desde, hasta, grupo):
    v = [t["frt_min"] for t in D.tie.values() if t["frt_min"] is not None and en_periodo(t["creada_en"], desde, hasta)
         and del_grupo_origen(D, t["incidencia_id"], grupo)]
    return ["evaluadas", "mediana_min", "p90_min"], [(len(v), cuantil_inclusivo(v, 0.5), cuantil_inclusivo(v, 0.9))]


def mttr(D, desde, hasta, grupo):
    v = [t["mttr_min"] for t in D.tie.values() if t["mttr_min"] is not None and en_periodo(t["creada_en"], desde, hasta)
         and del_grupo_origen(D, t["incidencia_id"], grupo)]
    return ["evaluadas", "mediana_min", "media_min"], [(len(v), cuantil_inclusivo(v, 0.5), (sum(v) / len(v)) if v else None)]


def fcr(D, desde, hasta, grupo):
    v = [t["primer_contacto"] for t in D.tie.values() if t["primer_contacto"] is not None and en_periodo(t["creada_en"], desde, hasta)
         and del_grupo_origen(D, t["incidencia_id"], grupo)]
    uno = sum(1 for x in v if x == 1)
    return ["evaluadas", "al_primer_contacto", "porcentaje"], [(len(v), uno, pct(uno, len(v)))]


def contencion_asistente(D, desde, hasta, grupo):
    casos = [c for c in D.cas.values() if en_periodo(c["inicio"], desde, hasta)]
    concluidos = [c for c in casos if c["estado"] != "abierto"]
    abiertos = len(casos) - len(concluidos)
    contenidos = sum(1 for c in concluidos if c["estado"] == "resuelto_asistente" and c["confirmado_resuelto"] == 1
                     and c["tiene_incidencia"] == 0)
    return (["casos_concluidos", "contenidos", "porcentaje", "casos_abiertos_excluidos"],
            [(len(concluidos), contenidos, pct(contenidos, len(concluidos)), abiertos)])


def tasa_escalamiento(D, desde, hasta, grupo):
    inc = [i for i in D.inc.values() if en_periodo(i["creada_en"], desde, hasta) and del_grupo_origen(D, i["incidencia_id"], grupo)]
    escaladas = sum(1 for i in inc if any(e["tipo"] == "escalada" for e in D.por_inc.get(i["incidencia_id"], [])))
    return ["incidencias", "escaladas", "porcentaje"], [(len(inc), escaladas, pct(escaladas, len(inc)))]


def reaperturas(D, desde, hasta, grupo):
    resueltas = reabiertas = 0
    for i in D.inc.values():
        if not (en_periodo(i["creada_en"], desde, hasta) and del_grupo_origen(D, i["incidencia_id"], grupo)):
            continue
        evs = D.por_inc.get(i["incidencia_id"], [])
        rs = [_t(e["ts"]) for e in evs if e["tipo"] == "resuelta"]
        ras = [_t(e["ts"]) for e in evs if e["tipo"] == "reabierta"]
        if not rs:
            continue
        resueltas += 1
        if any(timedelta(0) < (a - r) <= timedelta(days=7) for r in rs for a in ras):
            reabiertas += 1
    return ["resueltas", "reabiertas_7d", "porcentaje"], [(resueltas, reabiertas, pct(reabiertas, resueltas))]


def pendientes_antiguedad(D, desde, hasta, grupo):
    # corte = 00:00 de Lima del dia siguiente a «hasta»  ->  en UTC, +5 h
    corte = datetime.combine(hasta + timedelta(days=1), datetime.min.time()) - LIMA
    tramos = [0, 0, 0, 0]
    for inc_id, evs in D.por_inc.items():
        antes = [e for e in evs if _t(e["ts"]) < corte]
        if not antes:
            continue
        ciclo = [e for e in antes if e["tipo"] in ("creada", "resuelta", "reabierta", "cerrada")]
        if not ciclo or ciclo[-1]["tipo"] not in ("creada", "reabierta"):
            continue
        grupo_al_corte = antes[-1]["grupo"]
        if grupo != "" and grupo_al_corte != grupo:
            continue
        creada = min(_t(e["ts"]) for e in antes if e["tipo"] == "creada")
        edad = (corte - creada).total_seconds()
        if edad < 86400:
            tramos[0] += 1
        elif edad < 3 * 86400:
            tramos[1] += 1
        elif edad < 7 * 86400:
            tramos[2] += 1
        else:
            tramos[3] += 1
    nombres = ["< 1 d", "1-3 d", "3-7 d", "> 7 d"]
    return ["tramo", "incidencias"], list(zip(nombres, tramos))


def csat(D, desde, hasta, grupo):
    enc = [e for e in D.encuestas.values() if en_periodo(e["ts"], desde, hasta)
           and (grupo == "" or (e["incidencia_id"] is not None and D.origen.get(e["incidencia_id"]) == grupo))]
    resp = [e["puntaje"] for e in enc if e["puntaje"] is not None]
    return (["enviadas", "respondidas", "tasa_respuesta_pct", "csat_media", "pct_4_5"],
            [(len(enc), len(resp), pct(len(resp), len(enc)), (sum(resp) / len(resp)) if resp else None,
              pct(sum(1 for p in resp if p >= 4), len(resp)))])


def volumen(D, desde, hasta, grupo):
    from collections import Counter
    inc = [i for i in D.inc.values() if en_periodo(i["creada_en"], desde, hasta) and del_grupo_origen(D, i["incidencia_id"], grupo)]
    # los casos no tienen grupo: con un grupo elegido no se cuentan (la columna casos sale NULL)
    cas = [c for c in D.cas.values() if en_periodo(c["inicio"], desde, hasta)] if grupo == "" else []
    cuenta = {}
    def sumar(dim, val, fuente):
        cuenta.setdefault((dim, val), Counter())[fuente] += 1
    for i in inc:
        loc = _t(i["creada_en"]) + LIMA
        sumar("canal", i["canal"], "i")
        sumar("categoria", i["categoria"] if i["categoria"] is not None else "(sin categoria)", "i")
        sumar("sede", i["sede"] if i["sede"] is not None else "(sin sede)", "i")
        sumar("hora", "%02d" % loc.hour, "i")
        sumar("dia", loc.date().isoformat(), "i")
    for c in cas:
        loc = _t(c["inicio"]) + LIMA
        sumar("canal", c["canal"], "c")
        sumar("hora", "%02d" % loc.hour, "c")
        sumar("dia", loc.date().isoformat(), "c")
    aplica_casos = grupo == ""
    filas = [("total", "", len(cas) if aplica_casos else None, len(inc))]
    orden = ["canal", "categoria", "sede", "hora", "dia"]
    for (dim, val), c in sorted(cuenta.items(), key=lambda kv: (orden.index(kv[0][0]), kv[0][1])):
        filas.append((dim, val, c["c"] if aplica_casos and dim in ("canal", "hora", "dia") else None, c["i"]))
    return ["dimension", "valor", "casos", "incidencias"], filas


def productividad_tecnico(D, desde, hasta, grupo):
    por_tec = {}
    for t in D.tie.values():
        if t["resuelta_en"] is None or t["tecnico_id"] is None:
            continue
        if not en_periodo(t["resuelta_en"], desde, hasta):
            continue
        if grupo != "" and t["grupo"] != grupo:
            continue
        por_tec.setdefault(t["tecnico_id"], []).append(t)
    filas = []
    for tec in sorted(por_tec):
        ts = por_tec[tec]
        ids = {t["incidencia_id"] for t in ts}
        puntajes = [e["puntaje"] for e in D.encuestas.values() if e["incidencia_id"] in ids and e["puntaje"] is not None]
        filas.append((tec, len(ts),
                      cuantil_inclusivo([t["frt_min"] for t in ts if t["frt_min"] is not None], 0.5),
                      cuantil_inclusivo([t["mttr_min"] for t in ts if t["mttr_min"] is not None], 0.5),
                      len(puntajes), (sum(puntajes) / len(puntajes)) if puntajes else None))
    return (["tecnico_id", "resueltas", "frt_mediana_min", "mttr_mediana_min", "encuestas_respondidas", "csat_media"], filas)


def calidad_asistente(D, desde, hasta, grupo):
    m = [x for x in D.mensajes.values() if en_periodo(x["ts"], desde, hasta)]
    f = [x for x in D.feedback.values() if en_periodo(x["ts"], desde, hasta)]
    clasificados = sum(1 for x in m if x["rol"] == "usuario" and x["intencion"] is not None)
    correcciones = sum(1 for x in f if x["senal"] == "correccion_intencion")
    resp = [x for x in m if x["rol"] == "asistente"]
    con_quitadas = sum(1 for x in resp if x["frases_quitadas"] > 0)
    regen = sum(1 for x in resp if x["regenerada"] == 1)
    casos = len({x["caso_id"] for x in resp})
    costo = sum(x["costo_usd"] for x in resp)
    fila = (clasificados, correcciones,
            None if clasificados == 0 else 100.0 * (1 - correcciones / clasificados),
            len(resp), con_quitadas, pct(con_quitadas, len(resp)), regen, pct(regen, len(resp)),
            casos, costo, None if casos == 0 else 1000.0 * costo / casos)
    cols = ["mensajes_usuario_clasificados", "correcciones_intencion", "exactitud_frente_a_correcciones_pct",
            "respuestas_asistente", "respuestas_con_frases_quitadas", "pct_con_frases_quitadas",
            "respuestas_regeneradas", "pct_regeneradas", "casos_atendidos", "costo_usd_total", "costo_usd_por_1000_casos"]
    return cols, [fila]


KPIS = {f.__name__: f for f in (sla_cumplimiento, frt, mttr, fcr, contencion_asistente, tasa_escalamiento, reaperturas,
                                pendientes_antiguedad, csat, volumen, productividad_tecnico, calidad_asistente)}


def calcular(D, kpi, desde, hasta, grupo=""):
    d = date.fromisoformat(desde) if isinstance(desde, str) else desde
    h = date.fromisoformat(hasta) if isinstance(hasta, str) else hasta
    return KPIS[kpi](D, d, h, grupo)


def a_csv(columnas, filas):
    s = io.StringIO()
    w = csv.writer(s, lineterminator="\n")
    w.writerow(columnas)
    for f in filas:
        w.writerow(["\\N" if v is None else v for v in f])
    return s.getvalue()


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    D = Datos()
    cols, filas = calcular(D, sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    sys.stdout.write(a_csv(cols, filas))
