#!/usr/bin/env python3
"""Prueba de RECONSTRUCCION: vaciar ClickHouse y recargarlo desde la outbox da las mismas cifras (PLAN_TRABAJO F7).

ClickHouse no es fuente de verdad (AGENTS.md 1.4 regla 8): se borra y se reconstruye desde Postgres (outbox_analitica).
La parte de Go (leer la outbox y mandar lotes) la prueba el backend. Aqui se prueba lo que le toca a ClickHouse: que cargar
las mismas filas en OTRO orden, en lotes de OTRO tamano y con reenvios (la outbox es «al menos una vez») deja las mismas
tablas vigentes y los mismos resultados de las 12 golden queries.

Pasos:  carga A (orden original, lotes de 100)  ->  huella
        DROP DATABASE + esquema + carga B (otro orden, otros lotes, con reenvios)  ->  huella igual a la de A y a la guardada
        OPTIMIZE FINAL  ->  huella igual otra vez
La huella de una tabla es (filas vigentes, suma de cityHash64 de la tupla de todas sus columnas): no depende del orden ni de las
partes. Se hashea la TUPLA porque cityHash64 de varios argumentos devuelve NULL si uno es NULL y sum() se saltaria esa fila
sin avisar (el checksum dejaria de cubrir las filas con algun campo vacio).
La huella de una golden query es el SHA-256 de su resultado CSV.

Uso:  probar_reconstruccion.py [--actualizar]   (--actualizar reescribe semilla/checksums_clickhouse.txt)
Entorno: JSR_CH_URL, JSR_CH_CLAVE, JSR_CH_ANALISTA_CLAVE (los pone probar_reconstruccion.sh)
"""
import hashlib
import os
import random
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
import ch_http  # noqa: E402
import ejecutar_pruebas as ep  # noqa: E402

RAIZ = ep.RAIZ
ARCHIVO_HUELLAS = os.path.join(ep.SEMILLA, "checksums_clickhouse.txt")
COLS_KPI_DIARIO = ("dia, canal, categoria, grupo, prioridad, tecnico_id, incidencias_creadas, resoluciones, reaperturas, "
                   "escalamientos, casos_nuevos, casos_con_incidencia, mensajes, mensajes_usuario, respuestas_asistente, "
                   "respuestas_regeneradas, respuestas_con_quitadas")
VISTAS = [("v_eventos", "*"), ("v_incidencias", "*"), ("v_tiempos", "*"), ("v_casos", "*"), ("v_mensajes", "*"),
          ("v_feedback", "*"), ("v_encuestas", "*"), ("v_kpi_diario", COLS_KPI_DIARIO)]


def huellas_tablas(admin):
    out = {}
    for vista, cols in VISTAS:
        fila = admin.consulta("SELECT count(), sum(cityHash64(tuple(%s))) FROM jsrbot.%s" % (cols, vista), formato="TSV").strip().split("\t")
        out[vista] = (int(fila[0]), int(fila[1]))
    return out


def huellas_golden(analista, metas):
    out = {}
    for kpi, meta in metas.items():
        for archivo, desde, hasta, grupo in ep.escenarios(meta):
            out["%s [%s]" % (kpi, archivo)] = hashlib.sha256(ep.ejecutar_golden(analista, kpi, meta, desde, hasta, grupo).encode()).hexdigest()
    return out


def cargar_desordenado(admin, semilla=7, lote=97, reenvio=0.3):
    """Recarga con otro orden de tablas, filas barajadas, lotes de otro tamano y reenvio de la cola de cada lote."""
    azar = random.Random(semilla)
    sentencias = ch_http.partir_sentencias(open(os.path.join(RAIZ, "esquema.sql"), encoding="utf-8").read())
    for s in sentencias:
        admin.ejecutar(s)
    for t in ep.TABLAS:
        admin.ejecutar("SYSTEM STOP MERGES jsrbot.%s" % t)
    reenviadas = 0
    for t in reversed(ep.TABLAS):
        lineas = open(os.path.join(ep.SEMILLA, t + ".jsonl"), "rb").read().splitlines(keepends=True)
        azar.shuffle(lineas)
        previo = []
        for i in range(0, len(lineas), lote):
            actual = lineas[i:i + lote]
            cola = previo[-int(len(previo) * reenvio):] if previo else []
            admin.insertar_jsonl("jsrbot." + t, b"".join(actual + cola))
            reenviadas += len(cola)
            previo = actual
    return reenviadas


def leer_guardadas():
    if not os.path.exists(ARCHIVO_HUELLAS):
        return None
    out = {}
    for linea in open(ARCHIVO_HUELLAS, encoding="utf-8"):
        if linea.startswith("#") or not linea.strip():
            continue
        v, n, h = linea.split()
        out[v] = (int(n), int(h))
    return out


def main():
    actualizar = "--actualizar" in sys.argv
    admin = ch_http.Cliente(os.environ["JSR_CH_URL"], "jsr", os.environ["JSR_CH_CLAVE"])
    analista = ch_http.Cliente(os.environ["JSR_CH_URL"], "analista", os.environ["JSR_CH_ANALISTA_CLAVE"])
    metas = ep.cargar_metas()
    res = []

    def comparar(nombre, a, b):
        res.append((nombre, a == b, "" if a == b else "difiere"))

    admin.ejecutar("DROP DATABASE IF EXISTS jsrbot")
    ep.preparar(admin)
    h_a = huellas_tablas(admin)
    g_a = huellas_golden(analista, metas)
    print("A) carga original: %s" % ", ".join("%s=%d" % (v, n) for v, (n, _) in h_a.items()))

    # --- vaciar y reconstruir
    admin.ejecutar("DROP DATABASE jsrbot")
    vacia = admin.consulta("SELECT count() FROM system.tables WHERE database = 'jsrbot'", formato="TSV").strip()
    res.append(("la base queda vacia tras DROP DATABASE", vacia == "0", "tablas: %s" % vacia))
    reenv = cargar_desordenado(admin)
    print("B) reconstruida en otro orden, lotes de 97 filas y %d filas reenviadas (al menos una vez)" % reenv)
    h_b = huellas_tablas(admin)
    g_b = huellas_golden(analista, metas)
    for v in h_a:
        comparar("tabla vigente %s: filas y suma de hashes" % v, h_a[v], h_b[v])
    comparar("%d resultados de golden query (SHA-256 del CSV)" % len(g_a), g_a, g_b)

    # --- fusionar las partes
    ep.fusionar(admin)
    h_c = huellas_tablas(admin)
    g_c = huellas_golden(analista, metas)
    for v in h_a:
        comparar("tras OPTIMIZE FINAL, %s" % v, h_a[v], h_c[v])
    comparar("tras OPTIMIZE FINAL, las golden queries", g_a, g_c)

    # --- control negativo: la huella DETECTA una fila de mas y un valor cambiado (si no, comparar huellas no probaria nada)
    admin.insertar_jsonl("jsrbot.eventos_incidencia", b'{"id":999999,"incidencia_id":1,"numero":"INC-000001","ts":"2026-07-02T10:00:00Z","tipo":"comentario","actor_tipo":"usuario","actor_id":null,"prioridad":"P3","categoria":"correo","grupo":"Mesa N1","tecnico_id":null,"datos":"{}"}\n')
    admin.insertar_jsonl("jsrbot.incidencias_estado", b'{"incidencia_id":1,"version":9999999999999,"numero":"INC-000001","persona_id":26,"tipo":"incidente","categoria":"correo","impacto":"persona","urgencia":"media","prioridad":"P3","estado":"en_curso","grupo":"Mesa N1","nivel":"N1","tecnico_id":2,"canal":"whatsapp","sede":"Centro","area":"Contabilidad","creada_en":"2026-07-01T04:40:00Z","primera_respuesta_en":null,"resuelta_en":null,"cerrada_en":null,"reaperturas":0,"escalamientos":0}\n')
    h_d = huellas_tablas(admin)
    res.append(("control negativo: una fila de mas cambia la huella de v_eventos", h_d["v_eventos"] != h_a["v_eventos"], "no la detecta"))
    res.append(("control negativo: una version nueva cambia la huella de v_incidencias", h_d["v_incidencias"] != h_a["v_incidencias"], "no la detecta"))
    res.append(("control negativo: lo que no se toco sigue igual (v_tiempos)", h_d["v_tiempos"] == h_a["v_tiempos"], "cambio sin tocarla"))

    # --- contra las huellas guardadas en el repositorio
    if actualizar:
        with open(ARCHIVO_HUELLAS, "w", encoding="utf-8", newline="\n") as f:
            f.write("# Huella de las tablas VIGENTES de ClickHouse tras cargar la semilla: vista, filas, suma de cityHash64 de las columnas.\n")
            f.write("# Genera: analitica/probar_reconstruccion.sh --actualizar. Cambia si cambia la semilla o el esquema: es la idea.\n")
            for v, (n, h) in h_a.items():
                f.write("%s %d %d\n" % (v, n, h))
        print("huellas guardadas en %s" % os.path.relpath(ARCHIVO_HUELLAS))
    else:
        guardadas = leer_guardadas()
        if guardadas is None:
            res.append(("hay huellas guardadas (checksums_clickhouse.txt)", False, "falta el archivo: corre --actualizar"))
        else:
            for v in h_a:
                comparar("huella guardada de %s" % v, guardadas.get(v), h_a[v])

    ancho = max(len(r[0]) for r in res) + 2
    print()
    for nombre, ok, det in res:
        print("  %s  %s%s" % ("OK   " if ok else "FALLA", nombre.ljust(ancho), ("  <- " + det) if not ok and det else ""))
    fallas = [r for r in res if not r[1]]
    print("\n  %d comprobaciones, %d OK, %d FALLA" % (len(res), len(res) - len(fallas), len(fallas)))
    sys.exit(1 if fallas else 0)


if __name__ == "__main__":
    main()
