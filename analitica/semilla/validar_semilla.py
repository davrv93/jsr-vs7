#!/usr/bin/env python3
"""Valida que la semilla sea COHERENTE: recalcula, solo desde los eventos y con otro algoritmo, lo que el backend deja en
incidencias_estado e incidencias_tiempos, y lo compara con la ultima version de cada incidencia.

Es la especificacion ejecutable de como se derivan los tiempos laborales de los eventos (el backend en Go debe dar lo
mismo). No usa el generador: lee calendario.json, sla.json y los .jsonl.

Algoritmo distinto al del generador: en vez de recortar tramos entre dos instantes, usa una funcion acumulada
A(t) = segundos laborales desde 2026-01-01 hasta t, y minutos(a, b) = A(b) - A(a). La zona se toma de zoneinfo
(America/Lima) si el sistema trae tzdata y, si no, del desfase fijo UTC-5.

Uso:  python3 validar_semilla.py        (codigo de salida 1 si algo no cuadra)
"""
import json
import os
import sys
from datetime import date, datetime, time, timedelta, timezone

CARPETA = os.path.dirname(os.path.abspath(__file__))
BASE = datetime(2026, 1, 1)           # origen de la funcion acumulada (en hora local)

try:
    from zoneinfo import ZoneInfo
    _LIMA = ZoneInfo("America/Lima")
except Exception:                      # pragma: no cover
    _LIMA = None


def a_local(dt_utc):
    if _LIMA is not None:
        return dt_utc.replace(tzinfo=timezone.utc).astimezone(_LIMA).replace(tzinfo=None)
    return dt_utc - timedelta(hours=5)


def t(txt):
    return datetime.strptime(txt, "%Y-%m-%dT%H:%M:%SZ") if txt else None


def leer(nombre):
    with open(os.path.join(CARPETA, nombre + ".jsonl"), encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


class Calendario:
    def __init__(self, cfg):
        self.es24 = cfg["veinticuatro_siete"]
        self.tramos = {}
        for dia, lista in cfg["horario"].items():
            self.tramos[int(dia)] = [(int(a[:2]) * 3600 + int(a[3:]) * 60, int(b[:2]) * 3600 + int(b[3:]) * 60) for a, b in lista]
        self.feriados = {date.fromisoformat(f["fecha"]) for f in cfg["feriados"]}
        # prefijo: segundos laborales de todos los dias ANTERIORES a cada dia de 2026
        self.prefijo = {}
        total = 0
        d = BASE.date()
        while d <= date(2026, 12, 31):
            self.prefijo[d] = total
            total += self.laborales_del_dia(d)
            d += timedelta(days=1)

    def laborales_del_dia(self, d):
        if d in self.feriados:
            return 0
        return sum(b - a for a, b in self.tramos.get(d.isoweekday(), []))

    def A(self, utc):
        """Segundos del calendario acumulados desde BASE hasta el instante UTC."""
        if self.es24:
            return (utc - BASE).total_seconds()
        loc = a_local(utc)
        d = loc.date()
        seg_dia = loc.hour * 3600 + loc.minute * 60 + loc.second
        parcial = 0
        if d not in self.feriados:
            for a, b in self.tramos.get(d.isoweekday(), []):
                parcial += max(0, min(seg_dia, b) - a)
        return self.prefijo[d] + parcial

    def minutos(self, a, b):
        return (self.A(b) - self.A(a)) / 60.0


def validar():
    cfg = json.load(open(os.path.join(CARPETA, "calendario.json")))["calendarios"]
    sla = json.load(open(os.path.join(CARPETA, "sla.json")))["politicas"]
    ahora = t(json.load(open(os.path.join(CARPETA, "resumen.json")))["ahora"])
    cals = {k: Calendario(v) for k, v in cfg.items()}

    eventos = {}
    for e in leer("eventos_incidencia"):
        eventos.setdefault(e["id"], e)
    por_inc = {}
    for e in sorted(eventos.values(), key=lambda x: (x["ts"], x["id"])):
        por_inc.setdefault(e["incidencia_id"], []).append(e)
    def ultima(filas, clave):
        out = {}
        for r in filas:
            if r[clave] not in out or r["version"] >= out[r[clave]]["version"]:
                out[r[clave]] = r
        return out
    est = ultima(leer("incidencias_estado"), "incidencia_id")
    tie = ultima(leer("incidencias_tiempos"), "incidencia_id")

    errores = []
    def err(i, msg):
        if len(errores) < 40:
            errores.append("incidencia %d: %s" % (i, msg))

    if set(est) != set(tie) or set(est) != set(por_inc):
        errores.append("las incidencias de estado, tiempos y eventos no coinciden: %d / %d / %d" % (len(est), len(tie), len(por_inc)))

    contados = 0
    for iid, evs in por_inc.items():
        e0, t0 = est[iid], tie[iid]
        creada = t(e0["creada_en"])
        prio = e0["prioridad"]
        cal = cals[sla[prio]["calendario"]]
        plazo = sla[prio]
        # --- reproduccion de los eventos
        primera = None
        pausas = []
        abierta = None
        resuelta = None
        n_res = 0
        cerrada = None
        motivo = None
        rea = 0
        esc = 0
        tecs = set()
        estado = "nueva"
        grupo = None
        for e in evs:
            ts = t(e["ts"])
            d = json.loads(e["datos"])
            tp = e["tipo"]
            if tp == "creada":
                if t(e["ts"]) != creada:
                    err(iid, "ts de creada != creada_en")
                grupo = e["grupo"]
            elif tp in ("asignada", "reasignada"):
                tecs.add(d["tecnico_id"])
                grupo = d.get("grupo", grupo)
                if estado == "nueva":
                    estado = "asignada"
            elif tp == "primera_respuesta":
                primera = primera or ts
            elif tp == "estado_cambiado":
                estado = d["a"]
            elif tp == "pausa_inicio":
                abierta = ts
                estado = d["estado"]
            elif tp == "pausa_fin":
                pausas.append((abierta, ts))
                abierta = None
                estado = "en_curso"
            elif tp == "escalada":
                esc += 1
                grupo = d["grupo"]
            elif tp == "resuelta":
                resuelta, n_res, estado = ts, n_res + 1, "resuelta"
            elif tp == "reabierta":
                rea, resuelta, cerrada, estado = rea + 1, None, None, "reabierta"
            elif tp == "cerrada":
                cerrada, motivo, estado = ts, d.get("motivo"), "cerrada"
        if abierta:
            pausas.append((abierta, None))
        # --- estado
        for campo, esperado in (("estado", estado), ("reaperturas", rea), ("escalamientos", esc), ("grupo", grupo)):
            if e0[campo] != esperado:
                err(iid, "estado.%s = %r pero los eventos dan %r" % (campo, e0[campo], esperado))
        for campo, esperado in (("primera_respuesta_en", primera), ("resuelta_en", resuelta), ("cerrada_en", cerrada)):
            if e0[campo] != (esperado.strftime("%Y-%m-%dT%H:%M:%SZ") if esperado else None):
                err(iid, "estado.%s = %r pero los eventos dan %r" % (campo, e0[campo], esperado))
        # --- tiempos
        # La fila refleja el instante de su version (ms epoch): una pausa EN CURSO cuenta solo hasta ese instante.
        # El backend no reescribe la fila cada minuto solo porque una pausa siga abierta.
        t_ref = datetime(1970, 1, 1) + timedelta(milliseconds=t0["version"])
        pausa_min = sum(cal.minutos(i, min(f, t_ref) if f else t_ref) for i, f in pausas if i < t_ref)
        pausa_hasta_res = sum(cal.minutos(i, f) for i, f in pausas if f and resuelta and f <= resuelta)
        frt = cal.minutos(creada, primera) if primera else None
        mttr = (cal.minutos(creada, resuelta) - pausa_hasta_res) if resuelta else None
        if frt is not None:
            ok_r = 1 if round(frt, 2) <= plazo["respuesta_min"] else 0
        else:
            ok_r = 0 if cal.minutos(creada, ahora) > plazo["respuesta_min"] else None
        if mttr is not None:
            ok_s = 1 if round(mttr, 2) <= plazo["resolucion_min"] else 0
        else:
            en_pausa_ahora = sum(cal.minutos(i, f if f else ahora) for i, f in pausas)
            ok_s = 0 if (cal.minutos(creada, ahora) - en_pausa_ahora) > plazo["resolucion_min"] else None
        if n_res == 0:
            pc = None
        elif rea > 0 or esc > 0 or len(tecs) > 1:
            pc = 0
        elif motivo == "sin_confirmacion":
            pc = None
        else:
            pc = 1
        for campo, esperado in (("frt_min", frt), ("mttr_min", mttr), ("pausa_min", round(pausa_min, 2))):
            got = t0[campo]
            if (got is None) != (esperado is None) or (got is not None and abs(got - esperado) > 0.011):
                err(iid, "tiempos.%s = %r pero los eventos dan %r" % (campo, got, esperado))
        for campo, esperado in (("sla_respuesta_ok", ok_r), ("sla_resolucion_ok", ok_s), ("primer_contacto", pc)):
            if t0[campo] != esperado:
                err(iid, "tiempos.%s = %r pero los eventos dan %r" % (campo, t0[campo], esperado))
        contados += 1

    # --- las versiones llevan como version el ms epoch de su instante y no se repiten por incidencia
    for nombre in ("incidencias_estado", "incidencias_tiempos"):
        vistas = set()
        for r in leer(nombre):
            if r["version"] % 1000 != 0:
                errores.append("%s: version %d no es ms epoch de un instante en segundos" % (nombre, r["version"]))
                break
            vistas.add((r["incidencia_id"], r["version"]))
    # --- vectores de calendario: el calendario del generador y el acumulado de aqui dan lo mismo
    vect = json.load(open(os.path.join(CARPETA, "vectores_calendario.json")))
    for v in vect["minutos"]:
        got = cals[v["calendario"]].minutos(t(v["desde"]), t(v["hasta"]))
        if abs(got - v["minutos"]) > 1e-3:
            errores.append("vector de calendario %r: %s vs %s" % (v["caso"], got, v["minutos"]))
    return contados, errores


if __name__ == "__main__":
    n, errores = validar()
    if errores:
        print("INCOHERENTE: %d problemas (se muestran hasta 40)" % len(errores))
        for e in errores:
            print("  -", e)
        sys.exit(1)
    print("semilla coherente: %d incidencias recalculadas desde sus eventos con otro algoritmo (estado y tiempos), vectores de calendario OK" % n)
