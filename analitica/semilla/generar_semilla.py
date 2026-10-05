#!/usr/bin/env python3
"""Generador determinista de la semilla de jsrbot (3 meses sinteticos: julio a septiembre de 2026).

Produce un archivo JSONEachRow por tabla de carga de ClickHouse, con las MISMAS columnas que
docs/CONTRATOS.md seccion 4. Solo usa la biblioteca estandar. Mismo codigo + misma SEMILLA = mismos bytes,
en cualquier maquina y version de Python: el azar es un generador propio (splitmix64) y solo usa
aritmetica de enteros y de punto flotante basica (sin libm), y se compara con SHA256SUMS.

Uso:
  python3 generar_semilla.py              # escribe los archivos en esta carpeta
  python3 generar_semilla.py --verificar  # regenera en memoria y compara con lo que hay en disco (codigo de salida 1 si difiere)
  python3 generar_semilla.py --autoprueba # pruebas internas de la funcion de minutos laborales

REGLA DE LOS TIEMPOS LABORALES (documentada tambien en analitica/LEEME.md)
  * Calendario "laboral": lunes a viernes, 08:30 a 18:00, hora de Lima (UTC-5 fijo), sin los feriados de calendario.json.
    SUPUESTO: no hay hora de almuerzo. La zona America/Lima no tiene horario de verano, asi que el desfase es fijo.
  * Calendario "p1_24x7": todo minuto cuenta. SUPUESTO (ARQUITECTURA.md 3.1: «P1 puede ser 24x7»): la prioridad P1 lo usa.
  * Una incidencia usa el calendario de su prioridad (sla.json). Los minutos son los de ese calendario.
  * frt_min   = minutos(creada_en, primera_respuesta_en)
  * pausa_min = minutos de las pausas (espera_usuario y espera_tercero) hasta el instante de la VERSION de la fila (una pausa
                en curso cuenta hasta ahi: el backend no reescribe la fila cada minuto por una pausa abierta)
  * mttr_min  = minutos(creada_en, resuelta_en) - pausa_min, hasta la ULTIMA resolucion. El tiempo entre una
                resolucion y su reapertura SI corre (la pausa solo la pide un estado espera_*).
  * resuelta_en es la ultima resolucion vigente: vale NULL mientras la incidencia esta reabierta.
  * sla_respuesta_ok  = 1 si frt_min <= plazo, 0 si lo pasa o si el plazo ya vencio sin respuesta, NULL si aun no vence.
  * sla_resolucion_ok = 1 si mttr_min <= plazo, 0 si lo pasa o si el plazo ya vencio sin resolver, NULL si aun no vence.
  * primer_contacto   = NULL si nunca se resolvio, o si cerro sin confirmacion del usuario (no cuenta para el FCR);
                        0 si hubo escalamiento, reasignacion o reapertura; 1 en los demas casos resueltos.
  * "Ahora" de la semilla es AHORA (2026-10-05 00:00 de Lima): ningun hecho es posterior.
"""
import argparse
import hashlib
import json
import os
import sys
from datetime import date, datetime, time, timedelta

SEMILLA = 20261005
AHORA = datetime(2026, 10, 5, 5, 0, 0)          # UTC (= 2026-10-05 00:00 en Lima)
DESFASE_LIMA = timedelta(hours=-5)              # Lima = UTC-5 todo el ano
CARPETA = os.path.dirname(os.path.abspath(__file__))
MASCARA = (1 << 64) - 1

# --------------------------------------------------------------------------------------------------
# Azar propio (splitmix64). Solo enteros y multiplicaciones de punto flotante: identico en todo el mundo.
# --------------------------------------------------------------------------------------------------


class Azar:
    def __init__(self, *claves):
        h = SEMILLA
        for c in claves:
            if isinstance(c, str):
                c = int.from_bytes(hashlib.sha256(c.encode()).digest()[:8], "big")
            h = (h * 0x9E3779B97F4A7C15 + int(c) + 0x1234567) & MASCARA
            h ^= h >> 29
        self.estado = h & MASCARA

    def _sig(self):
        self.estado = (self.estado + 0x9E3779B97F4A7C15) & MASCARA
        z = self.estado
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASCARA
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASCARA
        return z ^ (z >> 31)

    def u(self):
        return (self._sig() >> 11) / 9007199254740992.0     # [0, 1)

    def entero(self, a, b):                                  # inclusivo
        return a + int(self._sig() % (b - a + 1))

    def prob(self, p):
        return self.u() < p

    def elegir(self, seq):
        return seq[int(self._sig() % len(seq))]

    def ponderado(self, pares):
        total = sum(p for _, p in pares)
        x = self.u() * total
        acum = 0.0
        for v, p in pares:
            acum += p
            if x < acum:
                return v
        return pares[-1][0]

    def barajar(self, lista):
        lista = list(lista)
        for i in range(len(lista) - 1, 0, -1):
            j = int(self._sig() % (i + 1))
            lista[i], lista[j] = lista[j], lista[i]
        return lista

    def sesgado(self, lo, hi, potencia=3):                  # lo + (hi-lo)*u^potencia: cola larga a la derecha
        x = self.u()
        r = 1.0
        for _ in range(potencia):
            r *= x
        return lo + int((hi - lo) * r)


# --------------------------------------------------------------------------------------------------
# Calendarios y minutos laborales (funcion independiente: no la usa ningun KPI)
# --------------------------------------------------------------------------------------------------

DIAS_HABILES = ["1", "2", "3", "4", "5"]
CALENDARIOS_CFG = {
    "laboral": {
        "zona": "America/Lima",
        "veinticuatro_siete": False,
        "horario": {**{d: [["08:30", "18:00"]] for d in DIAS_HABILES}, "6": [], "7": []},
        "feriados": [
            {"fecha": "2026-07-28", "nombre": "Fiestas Patrias (sintetico)"},
            {"fecha": "2026-07-29", "nombre": "Fiestas Patrias (sintetico)"},
            {"fecha": "2026-08-06", "nombre": "Feriado sintetico de la semilla"},
        ],
    },
    "p1_24x7": {"zona": "America/Lima", "veinticuatro_siete": True, "horario": {}, "feriados": []},
}
# SUPUESTO: plazos en minutos del calendario de la prioridad (no los dio la organizacion).
SLA_CFG = {
    "P1": {"calendario": "p1_24x7", "respuesta_min": 15, "resolucion_min": 240},
    "P2": {"calendario": "laboral", "respuesta_min": 60, "resolucion_min": 480},
    "P3": {"calendario": "laboral", "respuesta_min": 240, "resolucion_min": 1440},
    "P4": {"calendario": "laboral", "respuesta_min": 480, "resolucion_min": 2880},
}


def _hm(txt):
    h, m = txt.split(":")
    return time(int(h), int(m))


class Calendario:
    def __init__(self, cfg):
        self.es24 = cfg["veinticuatro_siete"]
        self.horario = {int(k): [(_hm(a), _hm(b)) for a, b in v] for k, v in cfg["horario"].items()}
        self.feriados = {date.fromisoformat(f["fecha"]) for f in cfg["feriados"]}

    def _intervalos(self, dia):
        """Tramos laborales (hora local, datetimes ingenuos) de un dia local."""
        if dia in self.feriados:
            return []
        return [(datetime.combine(dia, a), datetime.combine(dia, b)) for a, b in self.horario.get(dia.isoweekday(), [])]

    def segundos(self, a, b):
        """Segundos del calendario entre dos instantes UTC (a <= b)."""
        if b <= a:
            return 0
        if self.es24:
            return int((b - a).total_seconds())
        la, lb = a + DESFASE_LIMA, b + DESFASE_LIMA
        total = 0
        dia = la.date()
        while dia <= lb.date():
            for ini, fin in self._intervalos(dia):
                s, e = max(ini, la), min(fin, lb)
                if e > s:
                    total += int((e - s).total_seconds())
            dia += timedelta(days=1)
        return total

    def minutos(self, a, b):
        return self.segundos(a, b) / 60.0

    def avanzar_s(self, a, segs):
        """Primer instante UTC en que han corrido `segs` segundos del calendario desde a."""
        if segs <= 0:
            return a
        if self.es24:
            return a + timedelta(seconds=segs)
        t = a + DESFASE_LIMA
        restante = segs
        dia = t.date()
        for _ in range(800):
            for ini, fin in self._intervalos(dia):
                if fin <= t:
                    continue
                desde = max(ini, t)
                disp = int((fin - desde).total_seconds())
                if disp >= restante:
                    return desde + timedelta(seconds=restante) - DESFASE_LIMA
                restante -= disp
            dia += timedelta(days=1)
            t = datetime.combine(dia, time(0, 0))
        raise RuntimeError("calendario sin tiempo laboral en 800 dias")

    def avanzar(self, a, minutos):
        return self.avanzar_s(a, int(round(minutos * 60)))


CALS = {k: Calendario(v) for k, v in CALENDARIOS_CFG.items()}


def cal_de(prioridad):
    return CALS[SLA_CFG[prioridad]["calendario"]]


def instante_corrida(cal, inicio, segs, pausas):
    """Instante en que han corrido `segs` segundos del calendario, SIN contar las pausas.
    pausas: lista ordenada de (ini, fin); fin None = pausa aun abierta (el reloj no vuelve a correr)."""
    t = inicio
    restante = segs
    for pi, pf in pausas:
        if pf is not None and pf <= t:
            continue
        if pi > t:
            corr = cal.segundos(t, pi)
            if corr >= restante:
                return cal.avanzar_s(t, restante)
            restante -= corr
        if pf is None:
            return None
        t = max(t, pf)
    return cal.avanzar_s(t, restante)


def local(dt):
    return dt + DESFASE_LIMA


def L(y, m, d, h=0, mi=0, s=0):
    """Hora de Lima -> datetime UTC ingenuo."""
    return datetime(y, m, d, h, mi, s) - DESFASE_LIMA


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def ms(dt):
    return int((dt - datetime(1970, 1, 1)).total_seconds()) * 1000


# --------------------------------------------------------------------------------------------------
# Organizacion sintetica (SUPUESTO: nada de esto lo dio una organizacion real)
# --------------------------------------------------------------------------------------------------

PERIODO_INI = date(2026, 7, 1)
PERIODO_FIN = date(2026, 9, 30)

CAT_GRUPO = {
    "correo": "Mesa N1", "cuentas_accesos": "Mesa N1", "impresoras": "Mesa N1", "software_oficina": "Mesa N1",
    "otro": "Mesa N1", "equipo": "Infraestructura", "red_wifi": "Redes", "vpn": "Redes", "telefonia": "Redes",
    "sistema_interno": "Aplicaciones",
}
CAT_PESO = [("correo", 18), ("cuentas_accesos", 16), ("red_wifi", 14), ("vpn", 8), ("impresoras", 14), ("equipo", 12),
            ("software_oficina", 8), ("sistema_interno", 6), ("telefonia", 3), ("otro", 1)]
ESCALA_A = {  # grupo actual -> grupo de escalamiento funcional (segun categoria para Mesa N1)
    ("Mesa N1", "correo"): "Aplicaciones", ("Mesa N1", "cuentas_accesos"): "Aplicaciones",
    ("Mesa N1", "software_oficina"): "Aplicaciones", ("Mesa N1", "impresoras"): "Infraestructura",
    ("Mesa N1", "otro"): "Infraestructura", ("Redes", None): "Infraestructura", ("Aplicaciones", None): "Infraestructura",
    ("Infraestructura", None): "Infraestructura",
}
NIVEL_GRUPO = {"Mesa N1": "N1", "Redes": "N2", "Aplicaciones": "N2", "Infraestructura": "N2", "Seguridad": "N2"}
# 'Seguridad' es un grupo que existe pero NO recibe incidencias: sirve para probar los KPI sin datos.
TECNICOS = {  # id: grupo
    1: "Mesa N1", 2: "Mesa N1", 3: "Mesa N1", 4: "Mesa N1",
    5: "Redes", 6: "Redes", 7: "Aplicaciones", 8: "Aplicaciones", 9: "Infraestructura", 10: "Infraestructura",
}
PESO_TEC = {"Mesa N1": [(1, 4), (2, 3), (3, 3), (4, 1)], "Redes": [(5, 3), (6, 2)], "Aplicaciones": [(7, 3), (8, 2)],
            "Infraestructura": [(9, 1)]}   # el tecnico 10 (N3) solo se asigna a mano: UNA sola incidencia
SEDES = [("Centro", 50), ("Norte", 25), ("Sur", 25)]
AREAS = ["Contabilidad", "Ventas", "Recursos Humanos", "Logistica", "Direccion"]
MATRIZ = {
    "organizacion": {"critica": "P1", "alta": "P1", "media": "P2", "baja": "P3"},
    "sede": {"critica": "P1", "alta": "P2", "media": "P2", "baja": "P3"},
    "area": {"critica": "P2", "alta": "P2", "media": "P3", "baja": "P4"},
    "persona": {"critica": "P2", "alta": "P3", "media": "P3", "baja": "P4"},
}
IMPACTO_PESO = [("persona", 62), ("area", 25), ("sede", 11), ("organizacion", 2)]
URGENCIA_PESO = [("baja", 25), ("media", 45), ("alta", 25), ("critica", 5)]
INTENCIONES = ["reportar_falla", "solicitar_acceso", "solicitar_equipo", "restablecer_clave", "consultar_estado",
               "aportar_dato", "confirmar_solucion", "sigue_igual", "pedir_tecnico", "queja", "agradecer", "saludo",
               "fuera_de_alcance"]
CATEGORIAS = [c for c, _ in CAT_PESO]


def prioridad_de(impacto, urgencia):
    return MATRIZ[impacto][urgencia]


# --------------------------------------------------------------------------------------------------
# Linea de tiempo de una incidencia
# --------------------------------------------------------------------------------------------------


class Estado:
    """Reproduce los eventos y deja el estado de la incidencia en un instante."""

    def __init__(self, creada, categoria, prioridad, grupo):
        self.creada = creada
        self.categoria = categoria
        self.prioridad = prioridad
        self.estado = "nueva"
        self.grupo = grupo
        self.nivel = NIVEL_GRUPO[grupo]
        self.tecnico_id = None
        self.tecnicos = set()
        self.primera_respuesta_en = None
        self.resuelta_en = None
        self.cerrada_en = None
        self.reaperturas = 0
        self.escalamientos = 0
        self.resoluciones = 0
        self.pausas = []                 # [ini, fin|None]
        self.motivo_cierre = None

    def aplicar(self, ev):
        t, d = ev["tipo"], ev["datos"]
        ts = ev["ts"]
        if t == "asignada" or t == "reasignada":
            self.tecnico_id = d["tecnico_id"]
            self.tecnicos.add(d["tecnico_id"])
            if "grupo" in d:
                self.grupo, self.nivel = d["grupo"], d["nivel"]
            if self.estado == "nueva":
                self.estado = "asignada"
        elif t == "primera_respuesta":
            if self.primera_respuesta_en is None:
                self.primera_respuesta_en = ts
        elif t == "estado_cambiado":
            self.estado = d["a"]
        elif t == "pausa_inicio":
            self.estado = d["estado"]
            self.pausas.append([ts, None])
        elif t == "pausa_fin":
            self.estado = "en_curso"
            if self.pausas and self.pausas[-1][1] is None:
                self.pausas[-1][1] = ts
        elif t == "escalada":
            self.escalamientos += 1
            self.grupo, self.nivel = d["grupo"], d["nivel"]
            self.tecnico_id = None
        elif t == "resuelta":
            self.estado = "resuelta"
            self.resuelta_en = ts
            self.resoluciones += 1
        elif t == "cerrada":
            self.estado = "cerrada"
            self.cerrada_en = ts
            self.motivo_cierre = d.get("motivo")
        elif t == "reabierta":
            self.estado = "reabierta"
            self.reaperturas += 1
            self.resuelta_en = None
            self.cerrada_en = None


def tiempos(est, t):
    """Fila de incidencias_tiempos (sin ids) del estado `est` visto en el instante t."""
    cal = cal_de(est.prioridad)
    plazo = SLA_CFG[est.prioridad]
    # minutos de pausa dentro de la vida de la incidencia hasta t
    pausa_s = 0
    for ini, fin in est.pausas:
        if ini >= t:
            continue
        pausa_s += cal.segundos(ini, min(fin, t) if fin else t)
    frt = None
    if est.primera_respuesta_en:
        frt = round(cal.minutos(est.creada, est.primera_respuesta_en), 2)
    mttr = None
    if est.resuelta_en:
        pausa_hasta_res = sum(cal.segundos(i, f if f else est.resuelta_en) for i, f in est.pausas if i < est.resuelta_en)
        mttr = round((cal.segundos(est.creada, est.resuelta_en) - pausa_hasta_res) / 60.0, 2)
    # veredictos
    if frt is not None:
        ok_r = 1 if frt <= plazo["respuesta_min"] else 0
    else:
        ok_r = 0 if cal.minutos(est.creada, t) > plazo["respuesta_min"] else None
    if mttr is not None:
        ok_s = 1 if mttr <= plazo["resolucion_min"] else 0
    else:
        corrido = (cal.segundos(est.creada, t) - pausa_s) / 60.0
        ok_s = 0 if corrido > plazo["resolucion_min"] else None
    if est.resoluciones == 0:
        pc = None
    elif est.reaperturas > 0 or est.escalamientos > 0 or len(est.tecnicos) > 1:
        pc = 0
    elif est.motivo_cierre == "sin_confirmacion":
        pc = None
    else:
        pc = 1
    return {
        "frt_min": frt, "mttr_min": mttr, "pausa_min": round(pausa_s / 60.0, 2),
        "sla_respuesta_ok": ok_r, "sla_resolucion_ok": ok_s, "primer_contacto": pc,
    }


class Incidencia:
    def __init__(self, spec):
        self.spec = spec
        self.etiqueta = spec.get("etiqueta")
        self.creada = spec["creada"]
        self.categoria = spec["categoria"]
        self.prioridad = prioridad_de(spec["impacto"], spec["urgencia"])
        self.grupo0 = CAT_GRUPO[self.categoria]
        self.eventos = []                # dicts: ts, tipo, actor_tipo, actor_id, datos
        self.id = None
        self.numero = None
        self.caso_id = None

    def ev(self, ts, tipo, actor_tipo, actor_id, datos=None):
        self.eventos.append({"ts": ts, "tipo": tipo, "actor_tipo": actor_tipo, "actor_id": actor_id,
                             "datos": datos or {}, "orden": len(self.eventos)})


def elegir_tecnico(rng, grupo):
    return rng.ponderado(PESO_TEC[grupo])


def construir(spec, rng):
    """Ejecuta el plan (lista de pasos) y devuelve la Incidencia con sus eventos, ya recortados a AHORA."""
    inc = Incidencia(spec)
    cal = cal_de(inc.prioridad)
    t0 = spec["creada"]
    actor_creador = ("tecnico", str(spec.get("tecnico_alta", 1))) if spec.get("manual") else ("asistente", "jsrbot")
    inc.ev(t0, "creada", actor_creador[0], actor_creador[1], {"canal": spec["canal"], "tipo": "incidente"})
    tec = None
    t = t0
    # asignacion inicial
    if spec.get("asignar", True):
        tec = spec.get("tecnico") or elegir_tecnico(rng, inc.grupo0)
        espera_resp = spec.get("espera_resp_seg", 600)
        t_asig = t0 + timedelta(seconds=min(rng.entero(20, 150), max(1, espera_resp - 1)))
        inc.ev(t_asig, "asignada", "sistema", "despachador",
               {"tecnico_id": tec, "grupo": inc.grupo0, "nivel": NIVEL_GRUPO[inc.grupo0]})
    grupo_actual = inc.grupo0
    resp_hecha = False
    for paso in spec["pasos"]:
        k = paso[0]
        if k == "responder":                      # primera respuesta humana tras N minutos del calendario
            t = cal.avanzar(t0, paso[1])
            inc.ev(t, "primera_respuesta", "tecnico", str(tec))
            inc.ev(t, "estado_cambiado", "tecnico", str(tec), {"a": "en_curso"})
            resp_hecha = True
        elif k == "trabajo":                      # corre el reloj del calendario N minutos
            t = cal.avanzar(t, paso[1])
        elif k == "espera":                       # t avanza en tiempo de pared (no cuenta para nadie)
            t = t + timedelta(seconds=int(paso[1] * 3600))
        elif k == "comentario":
            inc.ev(t + timedelta(seconds=paso[1] if len(paso) > 1 else 90), rng.elegir(
                ["comentario", "comentario_interno", "dato_agregado"]),
                rng.elegir(["usuario", "tecnico", "asistente"]), None, {})
        elif k == "pausa":                        # ('pausa', horas_de_pared, tipo)
            tipo = paso[2] if len(paso) > 2 else "espera_usuario"
            inc.ev(t, "pausa_inicio", "tecnico", str(tec), {"estado": tipo})
            t = t + timedelta(seconds=int(paso[1] * 3600))
            inc.ev(t, "pausa_fin", "usuario" if tipo == "espera_usuario" else "tecnico",
                   None if tipo == "espera_usuario" else str(tec), {})
        elif k == "escalar":                      # ('escalar', {'tec': id opcional, 'grupo': opcional})
            opc = paso[1] if len(paso) > 1 else {}
            dest = opc.get("grupo") or ESCALA_A.get((grupo_actual, inc.categoria)) or ESCALA_A.get((grupo_actual, None))
            nivel = opc.get("nivel") or NIVEL_GRUPO[dest]
            inc.ev(t, "escalada", "sistema" if opc.get("sistema") else "tecnico", "vigia" if opc.get("sistema") else str(tec),
                   {"grupo": dest, "nivel": nivel, "motivo": opc.get("motivo", "funcional")})
            tec = opc.get("tec") or elegir_tecnico(rng, dest)
            t = t + timedelta(seconds=rng.entero(60, 600))
            inc.ev(t, "reasignada", "sistema", "despachador", {"tecnico_id": tec, "grupo": dest, "nivel": nivel})
            grupo_actual = dest
        elif k == "resolver":
            inc.ev(t, "resuelta", "tecnico", str(tec))
        elif k == "cerrar":                       # ('cerrar', 'confirmado', horas) | ('cerrar', 'sin_confirmacion')
            if paso[1] == "sin_confirmacion":
                t = CALS["laboral"].avanzar(t, 48 * 60)
                inc.ev(t, "cerrada", "sistema", "auto", {"motivo": "sin_confirmacion"})
            else:
                t = t + timedelta(seconds=int(paso[2] * 3600))
                inc.ev(t, "cerrada", "usuario", None, {"motivo": "confirmado"})
        elif k == "reabrir":                      # ('reabrir', horas_de_pared_desde_la_resolucion[, 'sin_tomar'])
            t = t + timedelta(seconds=int(paso[1] * 3600))
            inc.ev(t, "reabierta", "usuario", None, {})
            if not (len(paso) > 2 and paso[2] == "sin_tomar"):     # 'sin_tomar': nadie la ha retomado, sigue en estado reabierta
                t2 = t + timedelta(seconds=rng.entero(300, 3000))
                inc.ev(t2, "estado_cambiado", "tecnico", str(tec), {"a": "en_curso"})
                t = t2
        else:
            raise ValueError(paso)
    # avisos del vigia (ruido realista: al 75 % del plazo si aun no hay respuesta o resolucion)
    plazo = SLA_CFG[inc.prioridad]
    ev_resp = [e["ts"] for e in inc.eventos if e["tipo"] == "primera_respuesta"]
    t_resp = min(ev_resp) if ev_resp else None
    t75 = cal.avanzar_s(t0, int(plazo["respuesta_min"] * 60 * 0.75))
    if (t_resp is None or t75 < t_resp):
        inc.ev(t75, "aviso_sla", "sistema", "vigia", {"plazo": "respuesta", "umbral": 75})
    pausas = []
    abierta = None
    for e in sorted(inc.eventos, key=lambda x: (x["ts"], x["orden"])):
        if e["tipo"] == "pausa_inicio":
            abierta = e["ts"]
        elif e["tipo"] == "pausa_fin" and abierta:
            pausas.append((abierta, e["ts"]))
            abierta = None
    if abierta:
        pausas.append((abierta, None))
    t75r = instante_corrida(cal, t0, int(plazo["resolucion_min"] * 60 * 0.75), pausas)
    t_res = [e["ts"] for e in inc.eventos if e["tipo"] == "resuelta"]
    if t75r and (not t_res or t75r < min(t_res)):
        inc.ev(t75r, "aviso_sla", "sistema", "vigia", {"plazo": "resolucion", "umbral": 75})
    # nada es posterior a AHORA
    inc.eventos = [e for e in inc.eventos if e["ts"] <= AHORA]
    inc.eventos.sort(key=lambda x: (x["ts"], x["orden"]))
    return inc


# --------------------------------------------------------------------------------------------------
# Incidencias: casos dificiles explicitos + incidencias aleatorias
# --------------------------------------------------------------------------------------------------


def base_spec(**kw):
    d = dict(impacto="persona", urgencia="media", canal="whatsapp", sede="Centro", area="Contabilidad", persona_id=1,
             categoria="correo", asignar=True, manual=False)
    d.update(kw)
    return d


def casos_dificiles():
    """Cada entrada: (etiqueta, descripcion, spec). Los pasos son explicitos: lo que se espera se puede razonar a mano."""
    C = []

    def add(etq, desc, **kw):
        kw["etiqueta"] = etq
        C.append((etq, desc, base_spec(**kw)))

    add("viernes_1755", "Creada el viernes 10-jul 17:55 (Lima). 5 min cuentan ese dia y el resto el lunes: frt=30 laborales.",
        creada=L(2026, 7, 10, 17, 55), impacto="persona", urgencia="media", categoria="correo", persona_id=11,
        pasos=[("responder", 30), ("trabajo", 100), ("resolver",), ("cerrar", "confirmado", 3)])
    add("feriado_en_medio", "Creada el lunes 27-jul 17:00, P2, resuelta el jueves 30-jul: el 28 y el 29 son feriado y no cuentan.",
        creada=L(2026, 7, 27, 17, 0), impacto="area", urgencia="alta", categoria="red_wifi", persona_id=12, sede="Norte",
        pasos=[("responder", 40), ("trabajo", 400), ("resolver",), ("cerrar", "confirmado", 5)])
    add("pausa_larga_fin_de_semana", "Pausa por espera del usuario del martes 4-ago 11:00 al lunes 10-ago 09:30, con el feriado del 6-ago y un fin de semana dentro.",
        creada=L(2026, 8, 4, 10, 0), categoria="cuentas_accesos", persona_id=13,
        pasos=[("responder", 20), ("trabajo", 40), ("pausa", 142.5, "espera_usuario"), ("trabajo", 45), ("resolver",),
               ("cerrar", "confirmado", 4)])
    add("reapertura_en_2_dias", "Resuelta el lunes y reabierta 2 dias despues: dentro de los 7 dias.",
        creada=L(2026, 8, 10, 9, 0), categoria="impresoras", persona_id=14,
        pasos=[("responder", 15), ("trabajo", 120), ("resolver",), ("reabrir", 50), ("trabajo", 90), ("resolver",),
               ("cerrar", "confirmado", 6)])
    add("reapertura_fuera_de_7_dias", "Resuelta el miercoles 22-jul 16:00 y reabierta el jueves 30-jul 10:00 (7 d 18 h): los feriados alargan la ventana de cierre, pero la reapertura queda FUERA de los 7 dias.",
        creada=L(2026, 7, 22, 14, 30), categoria="equipo", persona_id=15, impacto="area", urgencia="media",
        pasos=[("responder", 30), ("trabajo", 60), ("resolver",), ("reabrir", 7 * 24 + 18), ("trabajo", 120), ("resolver",),
               ("cerrar", "confirmado", 4)])
    add("doble_reapertura", "Dos reaperturas y un escalamiento tras la segunda (reaperturas=2).",
        creada=L(2026, 8, 17, 9, 30), categoria="vpn", persona_id=16,
        pasos=[("responder", 20), ("trabajo", 90), ("resolver",), ("reabrir", 20), ("trabajo", 60), ("resolver",),
               ("reabrir", 30), ("escalar", {}), ("trabajo", 120), ("resolver",), ("cerrar", "confirmado", 8)])
    add("reabierta_vigente", "Resuelta el jueves 24-sep, reabierta el lunes 28-sep y todavia reabierta (resuelta_en NULL).",
        creada=L(2026, 9, 24, 9, 0), categoria="correo", persona_id=17,
        pasos=[("responder", 25), ("trabajo", 60), ("resolver",), ("reabrir", 96, "sin_tomar")])
    add("escalamiento_doble_tecnico_unico", "N1 -> N2 -> N3: el tecnico 10 (Infraestructura N3) solo tiene esta incidencia.",
        creada=L(2026, 9, 1, 10, 0), categoria="impresoras", persona_id=18, impacto="sede", urgencia="alta", canal="web",
        pasos=[("responder", 25), ("trabajo", 40), ("escalar", {"motivo": "funcional"}), ("trabajo", 90),
               ("escalar", {"grupo": "Infraestructura", "nivel": "N3", "tec": 10, "motivo": "funcional"}), ("trabajo", 60),
               ("resolver",), ("cerrar", "confirmado", 5)])
    add("p1_fuera_de_horario_cumplida", "P1 el sabado 8-ago 03:10: la guardia responde en 12 min y resuelve en 150 (24x7): cumple ambos plazos.",
        creada=L(2026, 8, 8, 3, 10), categoria="red_wifi", persona_id=19, impacto="organizacion", urgencia="critica",
        sede="Centro", espera_resp_seg=700, pasos=[("responder", 12), ("trabajo", 150), ("resolver",), ("cerrar", "confirmado", 10)])
    add("p1_fuera_de_horario_incumplida", "P1 el domingo 23-ago 22:00: responde a los 45 min y resuelve a los 300 (24x7): incumple ambos.",
        creada=L(2026, 8, 23, 22, 0), categoria="sistema_interno", persona_id=20, impacto="organizacion", urgencia="alta",
        espera_resp_seg=2500, pasos=[("responder", 45), ("trabajo", 255), ("resolver",), ("cerrar", "confirmado", 20)])
    add("nunca_resuelta_sin_respuesta", "Viernes 3-jul 12:00, P3, sin tecnico ni respuesta jamas: abierta de >7 dias, incumple SLA de respuesta.",
        creada=L(2026, 7, 3, 12, 0), categoria="telefonia", persona_id=21, asignar=False, pasos=[])
    add("nunca_resuelta_en_espera_tercero", "Atendida pero detenida en espera_tercero desde el 15-jul: nunca se resuelve.",
        creada=L(2026, 7, 14, 10, 0), categoria="equipo", persona_id=22, impacto="area", urgencia="media",
        pasos=[("responder", 35), ("trabajo", 120), ("pausa", 24 * 90, "espera_tercero")])
    add("nunca_resuelta_en_curso", "Atendida el 18-ago, trabajada y nunca resuelta (en_curso).",
        creada=L(2026, 8, 18, 9, 15), categoria="sistema_interno", persona_id=23,
        pasos=[("responder", 50), ("trabajo", 300)])
    add("sin_respuesta_asignada", "Asignada pero sin primera respuesta jamas (22-sep).",
        creada=L(2026, 9, 22, 11, 0), categoria="vpn", persona_id=24, pasos=[])
    add("sin_respuesta_cola_de_madrugada", "Creada el 30-sep 22:00 (fuera de horario), sin asignar. Al cierre del periodo lleva menos de 1 dia.",
        creada=L(2026, 9, 30, 22, 0), categoria="correo", persona_id=25, asignar=False, impacto="persona", urgencia="baja",
        pasos=[])
    add("fuera_del_periodo_junio_utc_julio", "Creada el 30-jun 23:40 de Lima (= 1-jul 04:40 UTC): NO es de julio. Un calculo en UTC la metera en el periodo.",
        creada=L(2026, 6, 30, 23, 40), categoria="correo", persona_id=26, asignar=True,
        pasos=[("responder", 20), ("trabajo", 60), ("resolver",), ("cerrar", "confirmado", 3)])
    add("borde_superior_30_sep_2355", "Creada el 30-sep 23:55 de Lima (= 1-oct 04:55 UTC): SI es de septiembre. Se resuelve el 1-oct.",
        creada=L(2026, 9, 30, 23, 55), categoria="red_wifi", persona_id=27, impacto="sede", urgencia="media",
        pasos=[("responder", 30), ("trabajo", 100), ("resolver",), ("cerrar", "confirmado", 30)])
    add("cierra_fuera_del_periodo", "Creada y resuelta el 30-sep (16:00), cerrada el 1-oct: la cierra fuera del periodo.",
        creada=L(2026, 9, 30, 14, 0), categoria="impresoras", persona_id=28,
        pasos=[("responder", 20), ("trabajo", 100), ("resolver",), ("cerrar", "confirmado", 20)])
    add("ultimo_dia_utc_cambia_de_dia_31_jul", "Creada el 31-jul 22:30 de Lima (= 1-ago 03:30 UTC): el dia es 31-jul.",
        creada=L(2026, 7, 31, 22, 30), categoria="cuentas_accesos", persona_id=29, impacto="persona", urgencia="alta",
        pasos=[("responder", 70), ("trabajo", 100), ("resolver",), ("cerrar", "confirmado", 8)])
    add("ultimo_dia_utc_cambia_de_dia_31_ago", "Creada el 31-ago 23:10 de Lima (= 1-sep 04:10 UTC): el dia es 31-ago.",
        creada=L(2026, 8, 31, 23, 10), categoria="software_oficina", persona_id=30, impacto="persona", urgencia="baja",
        pasos=[("responder", 120), ("trabajo", 200), ("resolver",), ("cerrar", "confirmado", 8)])
    add("resuelta_y_reabierta_antes_del_corte", "Resuelta el 29-sep 10:15 y reabierta el 30-sep 10:15, resuelta de nuevo el 1-oct: al cierre del 30-sep esta ABIERTA (pendiente).",
        creada=L(2026, 9, 29, 9, 0), categoria="correo", persona_id=31,
        pasos=[("responder", 15), ("trabajo", 60), ("resolver",), ("reabrir", 24), ("trabajo", 700), ("resolver",), ("cerrar", "confirmado", 20)])
    add("resuelta_antes_del_corte_reabierta_despues", "Resuelta el 30-sep 16:20 y reabierta el 1-oct: al cierre del 30-sep esta RESUELTA (no pendiente).",
        creada=L(2026, 9, 30, 15, 0), categoria="impresoras", persona_id=32,
        pasos=[("responder", 10), ("trabajo", 70), ("resolver",), ("reabrir", 16), ("trabajo", 50), ("resolver",), ("cerrar", "confirmado", 12)])
    add("abierta_al_corte_resuelta_despues", "Creada el 28-sep (1-3 dias al cierre), resuelta el 1-oct: pendiente en el corte, resuelta hoy.",
        creada=L(2026, 9, 28, 16, 0), categoria="vpn", persona_id=33,
        pasos=[("responder", 90), ("pausa", 40, "espera_usuario"), ("trabajo", 700), ("resolver",), ("cerrar", "confirmado", 20)])
    add("abierta_3_a_7_dias_al_corte", "Creada el 25-sep, detenida 5 dias en espera_tercero: al cierre del 30-sep lleva entre 3 y 7 dias abierta. Se resuelve el 2-oct.",
        creada=L(2026, 9, 25, 11, 0), categoria="equipo", persona_id=34, impacto="area", urgencia="alta",
        pasos=[("responder", 25), ("trabajo", 200), ("pausa", 120, "espera_tercero"), ("trabajo", 900), ("resolver",),
               ("cerrar", "confirmado", 10)])
    add("pausa_vigente_veredicto_pendiente", "En espera_usuario desde el 30-sep: lleva menos del plazo corrido, asi que sla_resolucion_ok sigue NULL.",
        creada=L(2026, 9, 30, 9, 0), categoria="cuentas_accesos", persona_id=35, impacto="persona", urgencia="baja",
        pasos=[("responder", 30), ("trabajo", 60), ("pausa", 24 * 30, "espera_usuario")])
    add("alta_manual_sin_caso", "Alta manual desde la consola (canal consola): no tiene caso de conversacion.",
        creada=L(2026, 8, 12, 10, 30), categoria="equipo", persona_id=36, canal="consola", manual=True, tecnico_alta=2,
        pasos=[("responder", 20), ("trabajo", 180), ("resolver",), ("cerrar", "confirmado", 4)])
    add("cierre_sin_confirmacion", "Resuelta y cerrada por el sistema a las 48 h laborales, sin confirmacion: no cuenta para el FCR (primer_contacto NULL).",
        creada=L(2026, 8, 24, 9, 0), categoria="software_oficina", persona_id=37,
        pasos=[("responder", 30), ("trabajo", 60), ("resolver",), ("cerrar", "sin_confirmacion")])
    add("escalada_por_sla_vencido", "Plazo de resolucion vencido y escalada por el vigia (escalamiento funcional).",
        creada=L(2026, 9, 8, 9, 0), categoria="correo", persona_id=38, impacto="area", urgencia="alta",
        pasos=[("responder", 40), ("trabajo", 440), ("escalar", {"sistema": True, "motivo": "sla_100"}), ("trabajo", 120),
               ("resolver",), ("cerrar", "confirmado", 6)])
    return C


def hora_aleatoria(rng, dia_local):
    """Instante UTC dentro del dia local; 86 % en horario laboral entre semana."""
    habil = dia_local.isoweekday() <= 5 and dia_local.isoformat() not in {f["fecha"] for f in CALENDARIOS_CFG["laboral"]["feriados"]}
    if habil and rng.prob(0.86):
        h = rng.ponderado([(8, 6), (9, 12), (10, 14), (11, 12), (12, 8), (13, 6), (14, 10), (15, 12), (16, 10), (17, 6)])
        mi = rng.entero(0, 59)
        if h == 8 and mi < 30:
            mi = rng.entero(30, 59)
    else:
        h = rng.ponderado([(0, 1), (1, 1), (6, 1), (7, 3), (18, 8), (19, 8), (20, 7), (21, 6), (22, 5), (23, 3)])
        mi = rng.entero(0, 59)
    dt = datetime.combine(dia_local, time(h, mi, rng.entero(0, 59)))
    return dt - DESFASE_LIMA


def spec_aleatoria(rng, creada, serie):
    cat = rng.ponderado(CAT_PESO)
    impacto = rng.ponderado(IMPACTO_PESO)
    urgencia = rng.ponderado(URGENCIA_PESO)
    prio = prioridad_de(impacto, urgencia)
    grupo = CAT_GRUPO[cat]
    canal = rng.ponderado([("whatsapp", 62), ("web", 30), ("consola", 8)])
    spec = base_spec(creada=creada, categoria=cat, impacto=impacto, urgencia=urgencia, canal=canal,
                     manual=(canal == "consola"), tecnico_alta=rng.entero(1, 4),
                     sede=rng.ponderado(SEDES), area=rng.elegir(AREAS), persona_id=rng.entero(40, 180))
    pasos = []
    # primera respuesta
    rangos_resp = {"P1": (2, 40), "P2": (5, 120), "P3": (10, 500), "P4": (20, 900)}
    sin_respuesta = rng.prob(0.012)
    if sin_respuesta:
        spec["asignar"] = rng.prob(0.5)
        spec["pasos"] = []
        return spec
    lo, hi = rangos_resp[prio]
    delay = rng.sesgado(lo, hi, 3)
    spec["espera_resp_seg"] = delay * 60 if prio == "P1" else 600
    pasos.append(("responder", delay))
    # trabajo
    rangos_w = {"P1": (20, 300), "P2": (30, 420), "P3": (60, 1200), "P4": (120, 2400)}
    wlo, whi = rangos_w[prio]
    w_total = rng.sesgado(wlo, whi, 2)
    if rng.prob(0.14):                          # incidencia "lenta"
        w_total *= 3
    # pausas
    pausa = None
    if prio != "P1" and rng.prob(0.20):
        pausa = ("espera_tercero", rng.entero(24, 200)) if rng.prob(0.25) else ("espera_usuario", rng.entero(2, 60))
    escalar = rng.prob(0.20 if grupo == "Mesa N1" else 0.07) and grupo != "Infraestructura"
    # reparto del trabajo en tramos
    tramos = [w_total]
    if pausa:
        a = rng.entero(1, max(1, w_total - 1))
        tramos = [a, max(1, w_total - a)]
    if escalar:
        a0 = max(1, tramos[0] // 2)
        tramos = [a0, max(1, tramos[0] - a0)] + tramos[1:]
    # arma los pasos: trabajo, [escalar], [pausa], trabajo...
    idx = 0
    pasos.append(("trabajo", tramos[idx])); idx += 1
    if escalar:
        pasos.append(("escalar", {}))
        pasos.append(("trabajo", tramos[idx])); idx += 1
    if pausa:
        pasos.append(("pausa", pausa[1], pausa[0]))
        pasos.append(("trabajo", tramos[idx])); idx += 1
    nunca = rng.prob(0.025)
    if not nunca:
        pasos.append(("resolver",))
        r = rng.u()
        if r < 0.07:
            pasos.append(("reabrir", rng.entero(6, 100)))
            pasos.append(("trabajo", rng.sesgado(30, 400, 2)))
            pasos.append(("resolver",))
            if rng.prob(0.12):
                pasos.append(("reabrir", rng.entero(6, 80)))
                pasos.append(("trabajo", rng.sesgado(30, 300, 2)))
                pasos.append(("resolver",))
        if rng.prob(0.80):
            pasos.append(("cerrar", "confirmado", rng.sesgado(1, 40, 2)))
        else:
            pasos.append(("cerrar", "sin_confirmacion"))
    spec["pasos"] = pasos
    return spec


def dias_del_periodo():
    d = PERIODO_INI
    while d <= PERIODO_FIN:
        yield d
        d += timedelta(days=1)


def generar_incidencias():
    feriados = {f["fecha"] for f in CALENDARIOS_CFG["laboral"]["feriados"]}
    specs = []
    for dia in dias_del_periodo():
        rng = Azar("dia", dia.toordinal())
        if dia.isoformat() in feriados:
            n = rng.entero(0, 2)
        elif dia.isoweekday() <= 5:
            n = rng.entero(6, 12)
        elif dia.isoweekday() == 6:
            n = rng.entero(0, 2)
        else:
            n = rng.entero(0, 1)
        for k in range(n):
            r2 = Azar("inc", dia.toordinal(), k)
            specs.append(spec_aleatoria(r2, hora_aleatoria(r2, dia), (dia, k)))
    incs = []
    for etq, desc, spec in casos_dificiles():
        incs.append((spec, desc))
    todos = [(s, None) for s in specs] + incs
    todos.sort(key=lambda p: (p[0]["creada"], p[0].get("etiqueta") or ""))
    out = []
    for i, (spec, desc) in enumerate(todos, start=1):
        rng = Azar("plan", i)
        inc = construir(spec, rng)
        inc.id = i
        inc.numero = "INC-%06d" % i
        inc.descripcion_caso = desc
        out.append(inc)
    return out


# --------------------------------------------------------------------------------------------------
# Filas por tabla
# --------------------------------------------------------------------------------------------------


def evento_fila(inc, e, est_tras):
    return {
        "id": None, "incidencia_id": inc.id, "numero": inc.numero, "ts": iso(e["ts"]), "tipo": e["tipo"],
        "actor_tipo": e["actor_tipo"], "actor_id": e["actor_id"], "prioridad": est_tras.prioridad,
        "categoria": inc.categoria, "grupo": est_tras.grupo, "tecnico_id": est_tras.tecnico_id,
        "datos": json.dumps(e["datos"], separators=(",", ":"), ensure_ascii=False, sort_keys=True),
    }


TIPOS_QUE_CAMBIAN_LA_FICHA = {"creada", "asignada", "reasignada", "primera_respuesta", "estado_cambiado", "pausa_inicio",
                              "pausa_fin", "escalada", "resuelta", "cerrada", "reabierta"}


def filas_incidencia(inc):
    """Devuelve (eventos, versiones_estado, versiones_tiempos) de una incidencia."""
    spec = inc.spec
    est = Estado(inc.creada, inc.categoria, inc.prioridad, inc.grupo0)
    eventos, v_estado, v_tiempos = [], [], []
    plazo = SLA_CFG[inc.prioridad]
    cal = cal_de(inc.prioridad)
    # instantes de vigia (el primer minuto en que el plazo queda superado)
    ticks = []
    t_resp = None
    for e in inc.eventos:
        if e["tipo"] == "primera_respuesta":
            t_resp = e["ts"]
            break
    tb = cal.avanzar_s(inc.creada, plazo["respuesta_min"] * 60 + 60)
    if (t_resp is None or tb < t_resp) and tb <= AHORA:
        ticks.append(tb)
    pausas = []
    abierta = None
    t_res_final = None
    for e in inc.eventos:
        if e["tipo"] == "pausa_inicio":
            abierta = e["ts"]
        elif e["tipo"] == "pausa_fin" and abierta:
            pausas.append((abierta, e["ts"])); abierta = None
        elif e["tipo"] == "resuelta":
            t_res_final = e["ts"]
        elif e["tipo"] == "reabierta":
            t_res_final = None
    if abierta:
        pausas.append((abierta, None))
    tr = instante_corrida(cal, inc.creada, plazo["resolucion_min"] * 60 + 60, pausas)
    ya_resuelta_en_tr = any(e["tipo"] == "resuelta" and e["ts"] <= tr for e in inc.eventos) if tr else False
    reabierta_luego = any(e["tipo"] == "reabierta" for e in inc.eventos)
    if tr and tr <= AHORA and (not ya_resuelta_en_tr or reabierta_luego):
        ticks.append(tr)
    marcas = [(e["ts"], 0, e) for e in inc.eventos] + [(t, 1, None) for t in sorted(set(ticks))]
    marcas.sort(key=lambda x: (x[0], x[1]))
    i = 0
    while i < len(marcas):
        ts = marcas[i][0]
        cambio = False
        while i < len(marcas) and marcas[i][0] == ts:
            _, tipo_marca, e = marcas[i]
            if e is not None:
                est.aplicar(e)
                eventos.append(evento_fila(inc, e, est))
                if e["tipo"] in TIPOS_QUE_CAMBIAN_LA_FICHA:
                    cambio = True
            else:
                cambio = True
            i += 1
        if cambio:
            v_estado.append(fila_estado(inc, est, ts))
            v_tiempos.append(fila_tiempos(inc, est, ts))
    return eventos, v_estado, v_tiempos


def fila_estado(inc, est, ts):
    spec = inc.spec
    return {
        "incidencia_id": inc.id, "version": ms(ts), "numero": inc.numero, "persona_id": spec["persona_id"],
        "tipo": "incidente", "categoria": inc.categoria, "impacto": spec["impacto"], "urgencia": spec["urgencia"],
        "prioridad": est.prioridad, "estado": est.estado, "grupo": est.grupo, "nivel": est.nivel,
        "tecnico_id": est.tecnico_id, "canal": spec["canal"], "sede": spec["sede"], "area": spec["area"],
        "creada_en": iso(inc.creada), "primera_respuesta_en": iso(est.primera_respuesta_en),
        "resuelta_en": iso(est.resuelta_en), "cerrada_en": iso(est.cerrada_en),
        "reaperturas": est.reaperturas, "escalamientos": est.escalamientos,
    }


def fila_tiempos(inc, est, ts):
    t = tiempos(est, ts)
    return {
        "incidencia_id": inc.id, "version": ms(ts), "prioridad": est.prioridad, "categoria": inc.categoria,
        "grupo": est.grupo, "tecnico_id": est.tecnico_id, "creada_en": iso(inc.creada),
        "resuelta_en": iso(est.resuelta_en), "cerrada_en": iso(est.cerrada_en), **t,
    }


# --------------------------------------------------------------------------------------------------
# Casos, mensajes, encuestas y feedback
# --------------------------------------------------------------------------------------------------


def intencion_con_error(rng, correcta):
    if rng.prob(0.055):
        otra = rng.elegir([i for i in INTENCIONES if i != correcta])
        return otra, round(0.45 + rng.u() * 0.35, 2), False
    return correcta, round(0.72 + rng.u() * 0.27, 2), True


def categoria_con_error(rng, correcta):
    if rng.prob(0.07):
        return rng.elegir([c for c in CATEGORIAS if c != correcta]), False
    return correcta, True


class Casos:
    def __init__(self):
        self.casos = []        # dicts
        self.mensajes = []
        self.feedback = []
        self.encuestas = []
        self.estado_filas = []

    def nuevo_caso(self, **kw):
        c = dict(kw)
        c["id"] = None
        self.casos.append(c)
        return c


def msg(c, ts, rol, intencion=None, conf=None, cat=None, rng=None, fijo=False):
    m = {"id": None, "caso_id": None, "ts": ts, "rol": rol, "canal": c["canal"], "intencion": intencion,
         "confianza": conf, "categoria": cat, "juez_modo": "apagado", "juez_veredicto": "", "latencia_ms": None,
         "regenerada": 0, "frases_quitadas": 0, "costo_usd": 0.0, "texto": "", "_caso": c}
    if rol == "asistente":
        m["juez_modo"] = "apagado" if ts < L(2026, 7, 15) else "sombra"
        m["latencia_ms"] = rng.entero(180, 1700)
        if not fijo:
            m["costo_usd"] = round(rng.entero(200, 1300) / 1000000.0, 6)
            m["regenerada"] = 1 if rng.prob(0.06) else 0
            m["frases_quitadas"] = rng.sesgado(1, 3, 1) if rng.prob(0.12) else 0
        if m["juez_modo"] != "apagado":
            m["juez_veredicto"] = "sin_respaldo" if m["frases_quitadas"] else "respalda"
    return m


def generar_conversaciones(incs):
    K = Casos()
    # 1) un caso por cada incidencia que no sea alta manual
    for inc in incs:
        if inc.spec["manual"]:
            continue
        rng = Azar("caso-inc", inc.id)
        antes = rng.entero(10, 40)
        inicio = inc.creada - timedelta(minutes=antes, seconds=rng.entero(0, 59))
        c = K.nuevo_caso(canal=inc.spec["canal"], persona_id=inc.spec["persona_id"], inicio=inicio, tipo="incidencia",
                         inc=inc, cat=inc.categoria)
        inc.caso_ref = c
    # 2) casos que no producen incidencia
    for dia in dias_del_periodo():
        rng = Azar("caso-libre", dia.toordinal())
        if dia.isoweekday() <= 5:
            n = rng.entero(7, 12)
        else:
            n = rng.entero(0, 2)
        for k in range(n):
            r = Azar("caso-libre-k", dia.toordinal(), k)
            canal = r.ponderado([("whatsapp", 65), ("web", 35)])
            tipo = r.ponderado([("contenido", 80), ("abandonado", 18), ("tomado", 2)])
            K.nuevo_caso(canal=canal, persona_id=r.entero(40, 180), inicio=hora_aleatoria(r, dia), tipo=tipo, inc=None,
                         cat=r.ponderado(CAT_PESO))
    # 3) los 12 casos «resueltos por el asistente que luego terminaron en incidencia»: las primeras incidencias de la lista
    #    con caso y sin escalamiento se marcan como retorno (el asistente creyo resolver, la persona volvio)
    candidatos = [i for i in incs if not i.spec["manual"] and not i.etiqueta and i.creada >= L(2026, 7, 5)]
    ra = Azar("retornos")
    for inc in ra.barajar(candidatos)[:12]:
        inc.caso_ref["retorno"] = True
        inc.caso_ref["inicio"] = inc.caso_ref["inicio"] - timedelta(hours=ra.entero(20, 96))
    # ids de caso por inicio
    K.casos.sort(key=lambda c: (c["inicio"], c["tipo"], c["inc"].id if c["inc"] else 0, c["persona_id"]))
    for i, c in enumerate(K.casos, start=1):
        c["id"] = i
        if c["inc"]:
            c["inc"].caso_id = i
    # mensajes y estado de cada caso
    for c in K.casos:
        rng = Azar("conv", c["id"])
        gen_conversacion(K, c, rng)
    # ids de mensaje por orden de tiempo
    K.mensajes.sort(key=lambda m: (m["ts"], m["_caso"]["id"], 0 if m["rol"] == "usuario" else 1))
    for i, m in enumerate(K.mensajes, start=1):
        m["id"] = i
        m["caso_id"] = m["_caso"]["id"]
    return K


def gen_conversacion(K, c, rng):
    t = c["inicio"]
    cat = c["cat"]
    tipo = c["tipo"]

    def paso(lo=15, hi=150):
        nonlocal t
        t = t + timedelta(seconds=rng.entero(lo, hi))
        return t

    def u(intent):
        i, conf, ok = intencion_con_error(rng, intent)
        cc, okc = categoria_con_error(rng, cat)
        m = msg(c, paso(), "usuario", i, conf, cc, rng)
        m["_ok"] = ok
        m["_correcta"] = intent
        K.mensajes.append(m)
        return ok

    def a(fijo=False):
        m = msg(c, paso(2, 12), "asistente", None, None, cat, rng, fijo)
        K.mensajes.append(m)

    estados = [(c["inicio"], "abierto", 0, 0)]   # (ts, estado, tiene_incidencia, confirmado)
    if tipo == "contenido":
        u(rng.ponderado([("reportar_falla", 6), ("restablecer_clave", 2), ("solicitar_acceso", 1), ("fuera_de_alcance", 0.3)]))
        a()
        if rng.prob(0.25):
            u("aportar_dato")
            a()
        ok = u("confirmar_solucion")
        a(fijo=True)
        estados.append((t, "resuelto_asistente", 0, 1))
        c["resuelto_en"] = t
        if rng.prob(0.6):
            K.feedback.append({"caso": c, "inc": None, "ts": t + timedelta(seconds=5), "senal": "se_resolvio", "valor": None})
        if c["canal"] == "web" and rng.prob(0.25):
            K.feedback.append({"caso": c, "inc": None, "ts": t + timedelta(seconds=9),
                               "senal": rng.ponderado([("pulgar_arriba", 8), ("pulgar_abajo", 1)]), "valor": None})
        # encuesta del caso resuelto por el asistente
        if rng.prob(0.5):
            enc = {"caso": c, "inc": None, "ts": t + timedelta(seconds=30), "puntaje": None}
            if rng.prob(0.55):
                enc["puntaje"] = rng.ponderado([(5, 38), (4, 30), (3, 17), (2, 8), (1, 7)])
            K.encuestas.append(enc)
    elif tipo == "abandonado":
        u("reportar_falla")
        a()
        if rng.prob(0.4):
            u("aportar_dato")
        t_final = t
        cierre = t_final + timedelta(hours=rng.entero(7, 30))
        if cierre <= AHORA:
            estados.append((cierre, "cerrado", 0, 0))
    elif tipo == "tomado":
        u("pedir_tecnico")
        a(fijo=True)
        # el tecnico lo tomo y no lo cerro: sigue abierto
    else:   # incidencia
        inc = c["inc"]
        u("reportar_falla")
        a()
        u("aportar_dato")
        a()
        retorno = c.get("retorno")
        if retorno:
            # el asistente cree haberlo resuelto y la persona confirma; vuelve mas tarde
            u("confirmar_solucion")
            a(fijo=True)
            estados.append((t, "resuelto_asistente", 0, 1))
            K.feedback.append({"caso": c, "inc": None, "ts": t + timedelta(seconds=5), "senal": "se_resolvio", "valor": None})
            t = inc.creada - timedelta(seconds=rng.entero(60, 240))
        u(rng.ponderado([("sigue_igual", 7), ("pedir_tecnico", 2), ("queja", 1)]))
        K.feedback.append({"caso": c, "inc": None, "ts": t + timedelta(seconds=4), "senal": "sigue_igual", "valor": None})
        # el backend crea la incidencia: su mensaje fijo sale justo antes de la creacion
        m = msg(c, inc.creada, "asistente", None, None, cat, rng, True)
        K.mensajes.append(m)
        estados.append((inc.creada, "con_incidencia", 1, 0))
        # respuestas del tecnico en el hilo
        for e in inc.eventos:
            if e["tipo"] == "primera_respuesta":
                mt = msg(c, e["ts"] + timedelta(seconds=40), "tecnico", None, None, None, rng)
                if mt["ts"] <= AHORA:
                    K.mensajes.append(mt)
            if e["tipo"] in ("resuelta",) and rng.prob(0.5):
                mt = msg(c, e["ts"] + timedelta(seconds=20), "tecnico", None, None, None, rng)
                if mt["ts"] <= AHORA:
                    K.mensajes.append(mt)
        cerr = [e for e in inc.eventos if e["tipo"] == "cerrada"]
        if cerr:
            conf = 1 if cerr[-1]["datos"].get("motivo") == "confirmado" else 0
            estados.append((cerr[-1]["ts"], "cerrado", 1, conf))
    c["estados"] = estados
    ultimo = max([m["ts"] for m in K.mensajes if m["_caso"] is c] or [c["inicio"]])
    c["ultimo_mensaje"] = ultimo


def correcciones_y_encuestas_de_incidencias(K, incs):
    """Feedback de tecnicos (correcciones, reaperturas) y encuestas de las incidencias cerradas."""
    for c in K.casos:
        if not c["inc"]:
            continue
        inc = c["inc"]
        rng = Azar("fb-inc", inc.id)
        # correcciones: el tecnico corrige alguna de las clasificaciones erradas del caso
        for m in [m for m in K.mensajes if m["_caso"] is c and m["rol"] == "usuario"]:
            if m.get("_ok") is False and rng.prob(0.4):
                K.feedback.append({"caso": c, "inc": inc, "ts": inc.creada + timedelta(minutes=rng.entero(5, 600)),
                                   "senal": "correccion_intencion", "valor": m["_correcta"]})
        if rng.prob(0.012):
            K.feedback.append({"caso": c, "inc": inc, "ts": inc.creada + timedelta(minutes=rng.entero(5, 600)),
                               "senal": "correccion_categoria", "valor": inc.categoria})
        for e in inc.eventos:
            if e["tipo"] == "reabierta":
                K.feedback.append({"caso": c, "inc": inc, "ts": e["ts"], "senal": "reapertura", "valor": None})
    # encuestas al cerrar
    for inc in incs:
        rng = Azar("enc-inc", inc.id)
        cerr = [e for e in inc.eventos if e["tipo"] == "cerrada"]
        if not cerr:
            continue
        e = cerr[-1]
        c = getattr(inc, "caso_ref", None)
        con = e["datos"].get("motivo") == "confirmado"
        if not con and rng.prob(0.5):
            continue
        enc = {"caso": c, "inc": inc, "ts": e["ts"] + timedelta(seconds=rng.entero(30, 400)), "puntaje": None}
        if enc["ts"] > AHORA:
            continue
        if con and rng.prob(0.72):
            incumple = tiempos(_estado_final(inc), AHORA)["sla_resolucion_ok"] == 0
            base = [(5, 22), (4, 28), (3, 22), (2, 14), (1, 14)] if incumple else [(5, 42), (4, 32), (3, 14), (2, 7), (1, 5)]
            enc["puntaje"] = rng.ponderado(base)
        K.encuestas.append(enc)


def _estado_final(inc):
    est = Estado(inc.creada, inc.categoria, inc.prioridad, inc.grupo0)
    for e in inc.eventos:
        est.aplicar(e)
    return est


# --------------------------------------------------------------------------------------------------
# Ensamblado final
# --------------------------------------------------------------------------------------------------

COLUMNAS = {
    "eventos_incidencia": ["id", "incidencia_id", "numero", "ts", "tipo", "actor_tipo", "actor_id", "prioridad", "categoria",
                           "grupo", "tecnico_id", "datos"],
    "incidencias_estado": ["incidencia_id", "version", "numero", "persona_id", "tipo", "categoria", "impacto", "urgencia",
                           "prioridad", "estado", "grupo", "nivel", "tecnico_id", "canal", "sede", "area", "creada_en",
                           "primera_respuesta_en", "resuelta_en", "cerrada_en", "reaperturas", "escalamientos"],
    "incidencias_tiempos": ["incidencia_id", "version", "prioridad", "categoria", "grupo", "tecnico_id", "creada_en",
                            "resuelta_en", "cerrada_en", "frt_min", "mttr_min", "pausa_min", "sla_respuesta_ok",
                            "sla_resolucion_ok", "primer_contacto"],
    "casos_estado": ["caso_id", "version", "canal", "persona_id", "estado", "inicio", "ultimo_mensaje", "tiene_incidencia",
                     "confirmado_resuelto"],
    "mensajes": ["id", "caso_id", "ts", "rol", "canal", "intencion", "confianza", "categoria", "juez_modo", "juez_veredicto",
                 "latencia_ms", "regenerada", "frases_quitadas", "costo_usd", "texto"],
    "encuestas": ["id", "incidencia_id", "caso_id", "ts", "puntaje"],
    "feedback": ["id", "caso_id", "incidencia_id", "ts", "senal", "valor"],
}


def duplicar_y_desordenar(filas, rng, p_dup, p_viejo=0.0, clave_version=None):
    """Simula la outbox real: reenvios exactos de un lote y, para las tablas con version, reenvios TARDIOS de una version vieja
    (que llegan despues de la nueva y no deben ganar)."""
    out = list(filas)
    n = len(filas)
    extras = []
    for i, f in enumerate(filas):
        if rng.prob(p_dup):
            extras.append((min(n, i + rng.entero(1, 40)), dict(f)))
        if p_viejo and clave_version and rng.prob(p_viejo):
            extras.append((min(n, i + rng.entero(20, 400)), dict(f)))
    extras.sort(key=lambda p: p[0])
    for off, (pos, f) in enumerate(extras):
        out.insert(min(len(out), pos + off), f)
    return out


def construir_todo():
    incs = generar_incidencias()
    K = generar_conversaciones(incs)
    correcciones_y_encuestas_de_incidencias(K, incs)

    # eventos y versiones de incidencias
    ev_rows, est_rows, tie_rows = [], [], []
    for inc in incs:
        e, s, t = filas_incidencia(inc)
        ev_rows += e
        est_rows += s
        tie_rows += t
    ev_rows.sort(key=lambda r: (r["ts"], r["incidencia_id"], r["tipo"]))
    for i, r in enumerate(ev_rows, start=1):
        r["id"] = i
    est_rows.sort(key=lambda r: (r["version"], r["incidencia_id"]))
    tie_rows.sort(key=lambda r: (r["version"], r["incidencia_id"]))

    # casos_estado (versiones)
    cas_rows = []
    por_caso = {}
    for m in K.mensajes:
        por_caso.setdefault(m["_caso"]["id"], []).append(m["ts"])
    for c in K.casos:
        horas = sorted(por_caso.get(c["id"], []))
        for (ts, estado, tiene, conf) in c["estados"]:
            previos = [h for h in horas if h <= ts]
            ultimo = previos[-1] if previos else c["inicio"]
            cas_rows.append({"caso_id": c["id"], "version": ms(ts), "canal": c["canal"], "persona_id": c["persona_id"],
                             "estado": estado, "inicio": iso(c["inicio"]), "ultimo_mensaje": iso(ultimo),
                             "tiene_incidencia": tiene, "confirmado_resuelto": conf})
    cas_rows.sort(key=lambda r: (r["version"], r["caso_id"]))

    # mensajes
    men_rows = []
    for m in K.mensajes:
        men_rows.append({k: (iso(m[k]) if k == "ts" else m[k]) for k in COLUMNAS["mensajes"]})

    # feedback
    fb = []
    for f in K.feedback:
        if f["ts"] > AHORA:
            continue
        fb.append({"id": None, "caso_id": f["caso"]["id"] if f["caso"] else None,
                   "incidencia_id": f["inc"].id if f["inc"] else (None), "ts": iso(f["ts"]), "senal": f["senal"], "valor": f["valor"]})
    fb.sort(key=lambda r: (r["ts"], r["caso_id"] or 0, r["senal"]))
    for i, r in enumerate(fb, start=1):
        r["id"] = i

    # encuestas: la fila de envio (puntaje NULL) y, si responde, una segunda fila con el puntaje (misma id)
    en = []
    pend = sorted(K.encuestas, key=lambda e: (e["ts"], e["inc"].id if e["inc"] else 0, e["caso"]["id"] if e["caso"] else 0))
    for i, e in enumerate(pend, start=1):
        base = {"id": i, "incidencia_id": e["inc"].id if e["inc"] else None, "caso_id": e["caso"]["id"] if e["caso"] else None,
                "ts": iso(e["ts"]), "puntaje": None}
        en.append((e["ts"], 0, base))
        if e["puntaje"] is not None:
            rng = Azar("enc-resp", i)
            resp_ts = e["ts"] + timedelta(minutes=rng.entero(2, 1500))
            if resp_ts <= AHORA:
                en.append((resp_ts, 1, dict(base, puntaje=e["puntaje"])))
    en.sort(key=lambda p: (p[0], p[1], p[2]["id"]))
    en_rows = [p[2] for p in en]

    tablas = {
        "eventos_incidencia": duplicar_y_desordenar(ev_rows, Azar("dup-ev"), 0.02),
        "incidencias_estado": duplicar_y_desordenar(est_rows, Azar("dup-est"), 0.02, 0.03, True),
        "incidencias_tiempos": duplicar_y_desordenar(tie_rows, Azar("dup-tie"), 0.02, 0.03, True),
        "casos_estado": duplicar_y_desordenar(cas_rows, Azar("dup-cas"), 0.02, 0.03, True),
        "mensajes": duplicar_y_desordenar(men_rows, Azar("dup-men"), 0.01),
        "encuestas": duplicar_y_desordenar(en_rows, Azar("dup-enc"), 0.01),
        "feedback": duplicar_y_desordenar(fb, Azar("dup-fb"), 0.01),
    }
    return incs, K, tablas


def jsonl(filas, columnas):
    lineas = []
    for f in filas:
        lineas.append(json.dumps({c: f[c] for c in columnas}, separators=(",", ":"), ensure_ascii=False))
    return ("\n".join(lineas) + "\n").encode("utf-8")


def vectores_calendario():
    """Casos de prueba para el calendario del backend (Go): mismos datos y resultado esperado."""
    lab, p1 = CALS["laboral"], CALS["p1_24x7"]
    pares = [
        ("laboral", L(2026, 7, 10, 17, 55), L(2026, 7, 13, 8, 55), "viernes 17:55 a lunes 08:55"),
        ("laboral", L(2026, 7, 27, 17, 0), L(2026, 7, 30, 10, 0), "lunes 17:00 a jueves 10:00 con dos feriados en medio"),
        ("laboral", L(2026, 8, 4, 11, 0), L(2026, 8, 10, 9, 30), "pausa del martes al lunes con un feriado y un fin de semana"),
        ("laboral", L(2026, 8, 8, 3, 10), L(2026, 8, 8, 3, 22), "sabado de madrugada: no cuenta nada"),
        ("laboral", L(2026, 9, 14, 8, 0), L(2026, 9, 14, 9, 0), "antes de la apertura: solo cuenta desde las 08:30"),
        ("laboral", L(2026, 9, 14, 17, 30), L(2026, 9, 14, 19, 0), "cruza el cierre de las 18:00"),
        ("laboral", L(2026, 9, 14, 8, 30), L(2026, 9, 14, 18, 0), "jornada completa"),
        ("laboral", L(2026, 9, 14, 12, 0), L(2026, 9, 14, 12, 0), "intervalo vacio"),
        ("laboral", L(2026, 6, 30, 23, 40), L(2026, 7, 1, 9, 0), "creada el 30-jun 23:40 de Lima (1-jul UTC)"),
        ("p1_24x7", L(2026, 8, 23, 22, 0), L(2026, 8, 24, 9, 0), "domingo 22:00 a lunes 09:00 en 24x7"),
        ("p1_24x7", L(2026, 8, 8, 3, 10), L(2026, 8, 8, 3, 22), "P1 de madrugada: 12 minutos"),
    ]
    rng = Azar("vectores")
    for k in range(25):
        a = L(2026, 7, 1) + timedelta(seconds=rng.entero(0, 90 * 86400))
        b = a + timedelta(seconds=rng.entero(60, 10 * 86400))
        pares.append((rng.elegir(["laboral", "laboral", "p1_24x7"]), a, b, "aleatorio %d" % k))
    out = {"nota": "minutos del calendario entre dos instantes UTC (laboral = lun-vie 08:30-18:00 Lima sin feriados; p1_24x7 = todo)",
           "minutos": [], "avanzar": []}
    for cal, a, b, d in pares:
        c = CALS[cal]
        out["minutos"].append({"calendario": cal, "desde": iso(a), "hasta": iso(b), "minutos": round(c.minutos(a, b), 4), "caso": d})
    for k in range(15):
        cal = rng.elegir(["laboral", "p1_24x7"])
        a = L(2026, 7, 1) + timedelta(seconds=rng.entero(0, 90 * 86400))
        m = rng.entero(1, 3000)
        out["avanzar"].append({"calendario": cal, "desde": iso(a), "minutos": m, "hasta": iso(CALS[cal].avanzar(a, m))})
    return out


def descripcion_casos_dificiles(incs):
    out = []
    for inc in incs:
        if inc.etiqueta:
            out.append({"incidencia_id": inc.id, "numero": inc.numero, "etiqueta": inc.etiqueta, "descripcion": inc.descripcion_caso})
    return out


def todos_los_archivos():
    incs, K, tablas = construir_todo()
    archivos = {}
    for nombre, filas in tablas.items():
        archivos[nombre + ".jsonl"] = jsonl(filas, COLUMNAS[nombre])
    def js(o):
        return (json.dumps(o, indent=2, ensure_ascii=False, sort_keys=False) + "\n").encode("utf-8")
    archivos["calendario.json"] = js({"calendarios": CALENDARIOS_CFG, "nota": "SUPUESTO: horario y feriados sinteticos de la semilla, formato igual al de calendarios.horario del esquema de Postgres"})
    archivos["sla.json"] = js({"politicas": SLA_CFG, "nota": "SUPUESTO: plazos en minutos del calendario de cada prioridad. P1 usa 24x7"})
    archivos["vectores_calendario.json"] = js(vectores_calendario())
    archivos["casos_dificiles.json"] = js(descripcion_casos_dificiles(incs))
    resumen = {"semilla": SEMILLA, "ahora": iso(AHORA), "periodo": [PERIODO_INI.isoformat(), PERIODO_FIN.isoformat()],
               "incidencias": len(incs), "casos": len(K.casos), "filas": {k: len(v) for k, v in tablas.items()}}
    archivos["resumen.json"] = js(resumen)
    sumas = "".join("%s  %s\n" % (hashlib.sha256(archivos[n]).hexdigest(), n) for n in sorted(archivos) if n != "SHA256SUMS")
    archivos["SHA256SUMS"] = sumas.encode()
    return archivos, resumen


def autoprueba():
    lab = CALS["laboral"]
    ok = True

    def eq(nombre, got, esperado):
        nonlocal ok
        bueno = abs(got - esperado) < 1e-9
        ok &= bueno
        print(("OK    " if bueno else "FALLA ") + nombre, got, esperado)

    eq("viernes 17:55 a lunes 08:55", lab.minutos(L(2026, 7, 10, 17, 55), L(2026, 7, 13, 8, 55)), 30)
    eq("feriados 28-29 jul", lab.minutos(L(2026, 7, 27, 17, 0), L(2026, 7, 30, 10, 0)), 60 + 90)
    eq("pausa con feriado", lab.minutos(L(2026, 8, 4, 11, 0), L(2026, 8, 10, 9, 30)), 420 + 570 + 0 + 570 + 60)
    eq("fin de semana", lab.minutos(L(2026, 8, 8, 3, 10), L(2026, 8, 9, 23, 0)), 0)
    eq("antes de abrir", lab.minutos(L(2026, 9, 14, 8, 0), L(2026, 9, 14, 9, 0)), 30)
    eq("30-jun 23:40 a 1-jul 09:00", lab.minutos(L(2026, 6, 30, 23, 40), L(2026, 7, 1, 9, 0)), 30)
    eq("24x7 domingo a lunes", CALS["p1_24x7"].minutos(L(2026, 8, 23, 22, 0), L(2026, 8, 24, 9, 0)), 660)
    # ida y vuelta: avanzar y minutos son inversas
    rng = Azar("autoprueba")
    for k in range(300):
        cal = CALS[rng.elegir(["laboral", "p1_24x7"])]
        a = L(2026, 7, 1) + timedelta(seconds=rng.entero(0, 100 * 86400))
        m = rng.entero(1, 4000)
        b = cal.avanzar(a, m)
        got = cal.minutos(a, b)
        if abs(got - m) > 1e-9:
            ok = False
            print("FALLA ida y vuelta", a, m, b, got)
            break
    else:
        print("OK    300 ida y vuelta avanzar/minutos")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verificar", action="store_true")
    ap.add_argument("--autoprueba", action="store_true")
    args = ap.parse_args()
    if args.autoprueba:
        sys.exit(autoprueba())
    archivos, resumen = todos_los_archivos()
    if args.verificar:
        malos = []
        for nombre, datos in sorted(archivos.items()):
            ruta = os.path.join(CARPETA, nombre)
            if not os.path.exists(ruta) or open(ruta, "rb").read() != datos:
                malos.append(nombre)
        if malos:
            print("DIFIERE de lo guardado:", ", ".join(malos))
            sys.exit(1)
        print("semilla reproducible: %d archivos identicos byte a byte" % len(archivos))
        return
    for nombre, datos in archivos.items():
        with open(os.path.join(CARPETA, nombre), "wb") as f:
            f.write(datos)
    print(json.dumps(resumen, ensure_ascii=False))


if __name__ == "__main__":
    main()
