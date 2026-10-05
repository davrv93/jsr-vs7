#!/usr/bin/env python3
"""Ejecuta las pruebas de analitica contra un ClickHouse YA levantado (probar_golden.sh lo levanta y lo apaga).

Entorno (lo pone probar_golden.sh; nada de esto se imprime):
  JSR_CH_URL, JSR_CH_CLAVE (usuario jsr, escritura), JSR_CH_ANALISTA_CLAVE (usuario analista, solo lectura)

Que comprueba:
  1. esquema.sql se aplica (y se vuelve a aplicar: es idempotente) y la semilla se carga por la misma via que el backend.
  2. Cada golden query, ejecutada con el usuario analista, da su esperado*.csv (tolerancia de comparar_csv.py).
  3. Cada esperado*.csv coincide con el CALCULO INDEPENDIENTE en Python sobre los .jsonl (no se acepta un esperado solo
     porque ClickHouse lo devuelva).
  4. Prueba negativa: si se altera un esperado en memoria, la comparacion FALLA; y 26 «mutantes» (errores tipicos de SQL:
     dia en UTC, sin FINAL, grupo equivocado, ventana de 8 dias...) deben ser detectados por algun escenario.
  5. El usuario analista es de solo lectura y tiene limites; el perfil de poca memoria esta aplicado.
  6. kpi_diario reconcilia con las golden queries; los duplicados de la semilla se resuelven.
Modos:  (sin banderas) probar   |   --generar-esperados  escribe los esperado*.csv (solo si coinciden con el calculo independiente)
"""
import json
import os
import sys
import time

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
import calculo_independiente as ci  # noqa: E402
import ch_http  # noqa: E402
import comparar_csv  # noqa: E402
import miniyaml  # noqa: E402

RAIZ = os.path.abspath(os.path.join(AQUI, ".."))
GOLDEN = os.path.join(RAIZ, "golden")
SEMILLA = os.path.join(RAIZ, "semilla")
TABLAS = ["eventos_incidencia", "incidencias_estado", "incidencias_tiempos", "casos_estado", "mensajes", "encuestas", "feedback"]

OK, FALLA = "OK", "FALLA"
resultados = []   # (grupo, nombre, estado, detalle)


def registrar(grupo, nombre, ok, detalle=""):
    resultados.append((grupo, nombre, OK if ok else FALLA, detalle))
    return ok


def cliente(usuario, clave_env):
    return ch_http.Cliente(os.environ["JSR_CH_URL"], usuario, os.environ[clave_env])


LOTE = 100   # filas por INSERT: simula los lotes de la outbox. Con un solo INSERT ClickHouse deduplica dentro del bloque
            # (optimize_on_insert) y los duplicados y versiones viejas quedarian ocultos a las pruebas.


def preparar(admin, reaplicar=True, lote=LOTE):
    """Esquema + carga de la semilla por lotes, igual que el backend. Detiene las fusiones para que los duplicados y las
    versiones viejas sigan en partes distintas (como pasa en produccion entre fusion y fusion)."""
    sentencias = ch_http.partir_sentencias(open(os.path.join(RAIZ, "esquema.sql"), encoding="utf-8").read())
    for s in sentencias:
        admin.ejecutar(s)
    if reaplicar:   # idempotencia: aplicarlo otra vez no falla ni cambia nada
        for s in sentencias:
            admin.ejecutar(s)
    for t in TABLAS:
        admin.ejecutar("SYSTEM STOP MERGES jsrbot.%s" % t)
    cargadas = {}
    for t in TABLAS:
        lineas = open(os.path.join(SEMILLA, t + ".jsonl"), "rb").read().splitlines(keepends=True)
        for i in range(0, len(lineas), lote):
            admin.insertar_jsonl("jsrbot." + t, b"".join(lineas[i:i + lote]))
        cargadas[t] = len(lineas)
    return len(sentencias), cargadas


def fusionar(admin):
    """Reactiva las fusiones y las fuerza: el resultado de las golden queries no debe cambiar."""
    for t in TABLAS:
        admin.ejecutar("SYSTEM START MERGES jsrbot.%s" % t)
        admin.ejecutar("OPTIMIZE TABLE jsrbot.%s FINAL" % t)


def escenarios(meta):
    return [(p["archivo"], p["desde"], p["hasta"], p["grupo"]) for p in meta["pruebas"]]


def cargar_metas():
    metas = {}
    for k in sorted(os.listdir(GOLDEN)):
        ruta = os.path.join(GOLDEN, k, "meta.yaml")
        if os.path.isfile(ruta):
            metas[k] = miniyaml.cargar_archivo(ruta)
    return metas


def sql_de(kpi, meta):
    return open(os.path.join(GOLDEN, kpi, "v%d.sql" % meta["version"]), encoding="utf-8").read()


def ejecutar_golden(analista, kpi, meta, desde, hasta, grupo, formato="CSVWithNames"):
    return analista.consulta(sql_de(kpi, meta), {"desde": desde, "hasta": hasta, "grupo": grupo}, formato)


def formatear_independiente(D, kpi, desde, hasta, grupo):
    cols, filas = ci.calcular(D, kpi, desde, hasta, grupo)
    return ci.a_csv(cols, filas)


# --------------------------------------------------------------------------------------------------------------

def pruebas_golden(analista, metas, D, etiqueta="golden", con_independiente=True):
    for kpi, meta in metas.items():
        for archivo, desde, hasta, grupo in escenarios(meta):
            ruta = os.path.join(GOLDEN, kpi, archivo)
            nombre = "%s [%s]" % (kpi, archivo)
            if not os.path.isfile(ruta):
                registrar(etiqueta, nombre, False, "falta el esperado")
                if con_independiente:
                    registrar("independiente", nombre, False, "falta el esperado")
                continue
            esperado = open(ruta, encoding="utf-8").read()
            try:
                obtenido = ejecutar_golden(analista, kpi, meta, desde, hasta, grupo)
                dif = comparar_csv.comparar(esperado, obtenido)
                registrar(etiqueta, nombre, not dif, "; ".join(dif[:3]))
            except ch_http.ErrorCH as e:
                registrar(etiqueta, nombre, False, "ClickHouse: " + e.mensaje[:200])
            if con_independiente:
                indep = formatear_independiente(D, kpi, desde, hasta, grupo)
                dif = comparar_csv.comparar(esperado, indep)
                registrar("independiente", nombre, not dif, "; ".join(dif[:3]))


def pruebas_historicas(analista, metas):
    """Las versiones anteriores de una golden query (v1 cuando ya existe v2) NO se borran: sirven para comparar periodos.
    Sus esperados se congelan en golden/<kpi>/historicas/v<N>/ al crear la version nueva y siguen exigiendo lo mismo."""
    for kpi, meta in metas.items():
        for n in range(1, meta["version"]):
            ruta_sql = os.path.join(GOLDEN, kpi, "v%d.sql" % n)
            if not os.path.isfile(ruta_sql):
                continue
            carpeta = os.path.join(GOLDEN, kpi, "historicas", "v%d" % n)
            if not os.path.isdir(carpeta):
                registrar("historicas", "%s v%d" % (kpi, n), False, "falta congelar sus esperados en historicas/v%d/" % n)
                continue
            sql = open(ruta_sql, encoding="utf-8").read()
            for archivo, desde, hasta, grupo in escenarios(meta):
                ruta = os.path.join(carpeta, archivo)
                if not os.path.isfile(ruta):
                    continue
                try:
                    obtenido = analista.consulta(sql, {"desde": desde, "hasta": hasta, "grupo": grupo})
                    dif = comparar_csv.comparar(open(ruta, encoding="utf-8").read(), obtenido)
                    registrar("historicas", "%s v%d [%s]" % (kpi, n, archivo), not dif, "; ".join(dif[:3]))
                except ch_http.ErrorCH as e:
                    registrar("historicas", "%s v%d [%s]" % (kpi, n, archivo), False, "ClickHouse: " + e.mensaje[:200])


def prueba_negativa(metas):
    """Si alteramos un esperado en memoria, comparar() debe decir que difiere. Se prueba con tres alteraciones por KPI."""
    for kpi, meta in metas.items():
        archivo = meta["pruebas"][0]["archivo"]
        esperado = open(os.path.join(GOLDEN, kpi, archivo), encoding="utf-8").read()
        lineas = esperado.splitlines()
        alteraciones = {}
        # 1) sumar una unidad a la primera celda numerica de la primera fila de datos
        for fila_n in range(1, len(lineas)):
            celdas = lineas[fila_n].split(",")
            idx = next((i for i, c in enumerate(celdas) if c.replace(".", "", 1).isdigit() or c == "\\N"), None)
            if idx is not None:
                nueva = list(celdas)
                nueva[idx] = "\\N" if celdas[idx] != "\\N" else "0"
                if celdas[idx] != "\\N":
                    nueva[idx] = repr(float(celdas[idx]) + 1)
                alteraciones["una celda +1"] = "\n".join(lineas[:fila_n] + [",".join(nueva)] + lineas[fila_n + 1:]) + "\n"
                break
        # 2) quitar la ultima fila de datos (si hay)
        if len(lineas) > 2:
            alteraciones["una fila menos"] = "\n".join(lineas[:-1]) + "\n"
        # 3) cambiar el orden de las columnas
        alteraciones["encabezado cambiado"] = lineas[0].replace(lineas[0].split(",")[0], "columna_falsa", 1) + "\n" + "\n".join(lineas[1:]) + "\n"
        detectadas = [n for n, t in alteraciones.items() if comparar_csv.comparar(esperado, t)]
        registrar("negativa", kpi, len(detectadas) == len(alteraciones),
                  "" if len(detectadas) == len(alteraciones) else "no detecto: %s" % sorted(set(alteraciones) - set(detectadas)))
    # una diferencia dentro de la tolerancia NO debe fallar, y fuera de ella SI
    registrar("negativa", "tolerancia", comparar_csv.iguales(10.0, 10.0 + comparar_csv.TOLERANCIA / 2) and
              not comparar_csv.iguales(10.0, 10.0 + comparar_csv.TOLERANCIA * 3),
              "la tolerancia declarada es %.3f" % comparar_csv.TOLERANCIA)



# Errores tipicos de quien escribe un KPI sin cuidado. Cada mutante cambia el SQL como lo haria ese error y las pruebas
# deben DETECTARLO (alguna comparacion con un esperado falla). Un mutante que sobrevive significa que faltan escenarios.
MUTANTES = [
    ("sla_cumplimiento", "dia en UTC en vez de hora de Lima", [("toDate(t.creada_en, 'America/Lima')", "toDate(t.creada_en, 'UTC')")]),
    ("sla_cumplimiento", "leer la tabla sin FINAL (versiones y duplicados)", [("jsrbot.v_tiempos", "jsrbot.incidencias_tiempos")]),
    ("sla_cumplimiento", "contar sin veredicto en el denominador", [("countIf(ok_resolucion IS NOT NULL)", "count()")]),
    ("sla_cumplimiento", "grupo actual en vez de grupo de origen", [("o.grupo_origen = {grupo:String}", "t.grupo = {grupo:String}")]),
    ("frt", "media en vez de mediana", [("quantileExactInclusive(0.5)(t.frt_min)", "avg(t.frt_min)")]),
    ("frt", "percentil 95 en vez de 90", [("quantileExactInclusive(0.9)", "quantileExactInclusive(0.95)")]),
    ("mttr", "mediana sin interpolacion", [("quantileExactInclusive(0.5)", "quantileExact(0.5)")]),
    ("mttr", "contar abiertas con mttr 0", [("WHERE t.mttr_min IS NOT NULL", "WHERE 1")]),
    ("fcr", "contar las cerradas sin confirmacion (primer_contacto NULL)", [("countIf(t.primer_contacto IS NOT NULL)", "count()")]),
    ("contencion_asistente", "casos abiertos dentro del denominador", [("countIf(estado != 'abierto') AS casos_concluidos", "count() AS casos_concluidos")]),
    ("contencion_asistente", "leer casos sin quedarse con la ultima version", [("jsrbot.v_casos", "jsrbot.casos_estado")]),
    ("tasa_escalamiento", "grupo actual en vez de grupo de origen", [("o.grupo_origen = {grupo:String}", "i.grupo = {grupo:String}")]),
    ("tasa_escalamiento", "contar las abiertas fuera", [("WHERE toDate(i.creada_en", "WHERE i.estado = 'cerrada' AND toDate(i.creada_en")]),
    ("reaperturas", "ventana de 8 dias en vez de 7", [("604800", "691200")]),
    ("reaperturas", "sin el limite de 7 dias", [("a - r <= 604800", "a - r <= 99999999")]),
    ("pendientes_antiguedad", "corte en UTC en vez de Lima", [("toDateTime(addDays({hasta:Date}, 1), 'America/Lima')", "toDateTime(addDays({hasta:Date}, 1), 'UTC')")]),
    ("pendientes_antiguedad", "ignorar las reaperturas", [("tipo IN ('creada', 'resuelta', 'reabierta', 'cerrada')) AS ultimo_ciclo", "tipo IN ('creada', 'resuelta', 'cerrada')) AS ultimo_ciclo")]),
    ("pendientes_antiguedad", "antiguedad desde el inicio del dia", [("corte - creada_unix < 86400", "corte - creada_unix < 43200")]),
    ("csat", "no-respuestas como nota 0", [("round(avg(e.puntaje), 2)", "round(avg(ifNull(e.puntaje, 0)), 2)")]),
    ("csat", "encuestas sin juntar por id", [("jsrbot.v_encuestas", "jsrbot.encuestas")]),
    ("volumen", "hora en UTC", [("toHour(creada_en, 'America/Lima')", "toHour(creada_en, 'UTC')")]),
    ("volumen", "dia en UTC", [("toString(toDate(creada_en, 'America/Lima'))", "toString(toDate(creada_en, 'UTC'))")]),
    ("productividad_tecnico", "ordenar por desempeno (ranking)", [("ORDER BY t.tecnico_id", "ORDER BY t.resueltas DESC, t.tecnico_id")]),
    ("productividad_tecnico", "resueltas por fecha de creacion", [("toDate(resuelta_en, 'America/Lima')", "toDate(creada_en, 'America/Lima')")]),
    ("calidad_asistente", "mensajes duplicados sin descartar", [("jsrbot.v_mensajes", "jsrbot.mensajes")]),
    ("calidad_asistente", "costo por caso en vez de por 1000 casos", [("1000 * sumIf", "sumIf")]),
]


def prueba_mutantes(analista, metas):
    for i, (kpi, descripcion, cambios) in enumerate(MUTANTES, start=1):
        meta = metas[kpi]
        sql = sql_de(kpi, meta)
        mutado = sql
        for viejo, nuevo in cambios:
            if viejo not in mutado:
                registrar("mutantes", "%s: %s" % (kpi, descripcion), False, "el cambio no se aplica (¿cambio el SQL?): %r" % viejo)
                break
            mutado = mutado.replace(viejo, nuevo)
        else:
            detectado = None
            for archivo, desde, hasta, grupo in escenarios(meta):
                esperado = open(os.path.join(GOLDEN, kpi, archivo), encoding="utf-8").read()
                try:
                    obtenido = analista.consulta(mutado, {"desde": desde, "hasta": hasta, "grupo": grupo})
                except ch_http.ErrorCH:
                    detectado = archivo + " (error)"
                    break
                if comparar_csv.comparar(esperado, obtenido):
                    detectado = archivo
                    break
            registrar("mutantes", "%s: %s" % (kpi, descripcion), detectado is not None,
                      "SOBREVIVE: ningun escenario lo detecta" if detectado is None else "")


def pruebas_seguridad(admin, analista):
    def debe_fallar(nombre, sql, esperado_en_mensaje, cliente_=None):
        c = cliente_ or analista
        try:
            c.ejecutar(sql)
            registrar("seguridad", nombre, False, "se ejecuto y no debia")
        except ch_http.ErrorCH as e:
            registrar("seguridad", nombre, esperado_en_mensaje in e.mensaje, "" if esperado_en_mensaje in e.mensaje else e.mensaje[:150])

    debe_fallar("analista no inserta", "INSERT INTO jsrbot.feedback VALUES (999999, 1, 1, now(), 'x', 'y')", "ACCESS_DENIED")
    debe_fallar("analista no borra", "TRUNCATE TABLE jsrbot.eventos_incidencia", "ACCESS_DENIED")
    debe_fallar("analista no altera", "ALTER TABLE jsrbot.feedback DELETE WHERE 1", "ACCESS_DENIED")
    debe_fallar("analista no crea", "CREATE TABLE jsrbot.trampa (x UInt8) ENGINE = Memory", "ACCESS_DENIED")
    debe_fallar("analista no lee system.users", "SELECT * FROM system.users", "ACCESS_DENIED")
    debe_fallar("analista no sube sus limites", "SET max_memory_usage = 100000000000", "READONLY")
    debe_fallar("limite de filas leidas", "SELECT count() FROM numbers(1000000000)", "TOO_MANY_ROWS")
    ajustes = analista.consulta("SELECT getSetting('readonly'), getSetting('max_execution_time'), getSetting('timeout_overflow_mode'), "
                                "getSetting('max_memory_usage'), getSetting('max_result_rows'), getSetting('max_rows_to_read'), getSetting('max_threads')", formato="TSV").strip().split("\t")
    registrar("seguridad", "ajustes del analista: solo lectura, 10 s, 400 MB, 10 000 filas, 2 hilos",
              ajustes == ["1", "10", "throw", "400000000", "10000", "100000000", "2"], "valores %s" % ajustes)
    debe_fallar("limite de filas del resultado", "SELECT number FROM numbers(20000)", "TOO_MANY_ROWS")
    debe_fallar("limite de memoria", "SELECT groupArray(toString(number)) FROM numbers(30000000) FORMAT Null", "MEMORY_LIMIT_EXCEEDED")
    # limites de tiempo y memoria dependen de la maquina: se aceptan tambien los mensajes equivalentes
    # el usuario jsr (escritura) si puede lo suyo, y no puede administrar usuarios
    try:
        admin.ejecutar("CREATE TABLE IF NOT EXISTS jsrbot.prueba_escritura (x UInt8) ENGINE = Memory")
        admin.ejecutar("DROP TABLE jsrbot.prueba_escritura")
        registrar("seguridad", "jsr crea y borra en jsrbot", True)
    except ch_http.ErrorCH as e:
        registrar("seguridad", "jsr crea y borra en jsrbot", False, e.mensaje[:150])
    debe_fallar("jsr no crea usuarios", "CREATE USER intruso IDENTIFIED BY 'x'", "ACCESS_DENIED", admin)
    debe_fallar("jsr no toca otras bases", "CREATE DATABASE otra_base", "ACCESS_DENIED", admin)
    # el usuario por defecto no existe
    try:
        ch_http.Cliente(os.environ["JSR_CH_URL"], "default", "").ejecutar("SELECT 1")
        registrar("seguridad", "no existe usuario default sin clave", False, "default entra")
    except ch_http.ErrorCH as e:
        registrar("seguridad", "no existe usuario default sin clave", True)
    # forma de la respuesta que usa el backend: JSON con enteros sin comillas
    meta = miniyaml.cargar_archivo(os.path.join(GOLDEN, "sla_cumplimiento", "meta.yaml"))
    txt = ejecutar_golden(analista, "sla_cumplimiento", meta, "2026-07-01", "2026-09-30", "", "JSON")
    j = json.loads(txt)
    fila = j["data"][0]
    registrar("seguridad", "respuesta JSON con enteros sin comillas", isinstance(fila["evaluadas"], int) and isinstance(fila["porcentaje"], float),
              "tipos: %s" % {k: type(v).__name__ for k, v in fila.items()})


def pruebas_perfil(admin):
    try:
        v = admin.consulta("SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage_to_ram_ratio'", formato="TSV").strip()
        registrar("perfil", "max_server_memory_usage_to_ram_ratio = 0.25", abs(float(v) - 0.25) < 1e-9, "valor %s" % v)
        v = admin.consulta("SELECT value FROM system.server_settings WHERE name = 'mark_cache_size'", formato="TSV").strip()
        registrar("perfil", "mark_cache_size = 536870912 (500 MB)", int(v) == 536870912, "valor %s" % v)
        logs = admin.consulta("SELECT groupArray(name) FROM system.tables WHERE database = 'system' AND name IN "
                              "('query_log','trace_log','text_log','metric_log','asynchronous_metric_log','part_log','query_thread_log')", formato="TSV").strip()
        registrar("perfil", "sin query_log/trace_log/text_log/metric_log", logs in ("[]", ""), "presentes: %s" % logs)
        v = admin.consulta("SELECT getSetting('max_threads')", formato="TSV").strip()
        registrar("perfil", "max_threads = 2 (jsr)", v == "2", "valor %s" % v)
        v = admin.consulta("SELECT getSetting('max_block_size')", formato="TSV").strip()
        registrar("perfil", "max_block_size = 8192 (jsr)", v == "8192", "valor %s" % v)
    except ch_http.ErrorCH as e:
        registrar("perfil", "consultar el perfil", False, e.mensaje[:200])


def pruebas_datos(admin, analista, metas):
    """Duplicados de la semilla, kpi_diario y recuento de la carga."""
    # La semilla trae reenvios: las tablas crudas tienen mas filas que las vistas.
    for tabla, vista in (("eventos_incidencia", "v_eventos"), ("incidencias_estado", "v_incidencias"),
                         ("incidencias_tiempos", "v_tiempos"), ("casos_estado", "v_casos"), ("mensajes", "v_mensajes"),
                         ("feedback", "v_feedback")):
        crudas = int(admin.consulta("SELECT count() FROM jsrbot.%s" % tabla, formato="TSV"))
        limpias = int(admin.consulta("SELECT count() FROM jsrbot.%s" % vista, formato="TSV"))
        registrar("datos", "la semilla trae duplicados en %s" % tabla, crudas > limpias, "%d filas crudas, %d vigentes" % (crudas, limpias))
    # Coinciden con el recuento independiente
    D = ci.Datos()
    comparaciones = [("v_eventos", len(D.eventos)), ("v_incidencias", len(D.inc)), ("v_tiempos", len(D.tie)),
                     ("v_casos", len(D.cas)), ("v_mensajes", len(D.mensajes)), ("v_feedback", len(D.feedback)),
                     ("v_encuestas", len(D.encuestas))]
    for vista, n in comparaciones:
        got = int(admin.consulta("SELECT count() FROM jsrbot.%s" % vista, formato="TSV"))
        registrar("datos", "filas vigentes de %s = recuento en Python" % vista, got == n, "%d vs %d" % (got, n))
    # kpi_diario reconcilia con la golden query de volumen (por dia)
    meta = metas["volumen"]
    csv_v = ejecutar_golden(analista, "volumen", meta, "2026-07-01", "2026-09-30", "")
    cols, filas = comparar_csv.leer_csv(csv_v)
    golden_dia = {f[1]: (f[2], f[3]) for f in filas if f[0] == "dia"}
    kd = admin.consulta("SELECT toString(dia), sum(casos_nuevos), sum(incidencias_creadas) FROM jsrbot.v_kpi_diario "
                        "WHERE dia BETWEEN '2026-07-01' AND '2026-09-30' GROUP BY dia ORDER BY dia", formato="TSV")
    dif = []
    kpi_dia = {}
    for linea in kd.strip().splitlines():
        d, c, i = linea.split("\t")
        kpi_dia[d] = (float(c), float(i))
    for d, (c, i) in golden_dia.items():
        k = kpi_dia.get(d, (0.0, 0.0))
        if (c or 0.0) != k[0] or (i or 0.0) != k[1]:
            dif.append("%s: golden casos=%s inc=%s, kpi_diario casos=%s inc=%s" % (d, c, i, k[0], k[1]))
    for d in kpi_dia:
        if d not in golden_dia and (kpi_dia[d] != (0.0, 0.0)):
            dif.append("%s: solo en kpi_diario" % d)
    registrar("datos", "kpi_diario = golden volumen (casos e incidencias por dia)", not dif, "; ".join(dif[:3]))
    # mensajes por dia
    m_g = admin.consulta("SELECT toString(toDate(ts, 'America/Lima')) AS d, count() FROM jsrbot.v_mensajes WHERE d BETWEEN '2026-07-01' AND '2026-09-30' GROUP BY d ORDER BY d", formato="TSV")
    m_k = admin.consulta("SELECT toString(dia), sum(mensajes) FROM jsrbot.v_kpi_diario WHERE dia BETWEEN '2026-07-01' AND '2026-09-30' GROUP BY dia HAVING sum(mensajes) > 0 ORDER BY dia", formato="TSV")
    registrar("datos", "kpi_diario = mensajes por dia (v_mensajes)", m_g == m_k, "difiere" if m_g != m_k else "")
    # contencion NO esta en kpi_diario (trampa 8.2): la columna no existe
    cols_kd = admin.consulta("SELECT name FROM system.columns WHERE database = 'jsrbot' AND table = 'kpi_diario'", formato="TSV").split()
    registrar("datos", "kpi_diario no guarda FRT, MTTR, SLA ni contencion (trampa 8.2)",
              not any(("frt" in c or "mttr" in c or "sla" in c or "contenc" in c) for c in cols_kd), "")


def generar_esperados(analista, metas, D):
    escritos = 0
    discrepancias = []
    for kpi, meta in metas.items():
        for archivo, desde, hasta, grupo in escenarios(meta):
            obtenido = ejecutar_golden(analista, kpi, meta, desde, hasta, grupo)
            indep = formatear_independiente(D, kpi, desde, hasta, grupo)
            dif = comparar_csv.comparar(indep, obtenido)
            if dif:
                discrepancias.append("%s [%s]: %s" % (kpi, archivo, "; ".join(dif[:3])))
                continue
            with open(os.path.join(GOLDEN, kpi, archivo), "w", encoding="utf-8", newline="\n") as f:
                f.write(obtenido)
            escritos += 1
    for d in discrepancias:
        print("DISCREPANCIA SQL vs Python:", d)
    print("esperados escritos: %d, discrepancias: %d" % (escritos, len(discrepancias)))
    return 1 if discrepancias else 0


ORDEN_GRUPOS = ["golden", "independiente", "historicas", "negativa", "mutantes", "seguridad", "perfil", "datos", "tras_fusion"]
TITULOS = {
    "golden": "SQL de cada golden query contra su esperado (7 escenarios por KPI)",
    "independiente": "Calculo independiente en Python contra cada esperado (7 escenarios por KPI)",
    "historicas": "Versiones anteriores de una golden query (siguen dando su resultado congelado)",
    "negativa": "Prueba negativa: alterar un esperado en memoria debe hacer fallar la comparacion",
    "mutantes": "Mutantes: errores tipicos de SQL que alguna prueba debe detectar",
    "seguridad": "Usuario analista (solo lectura, con limites) y usuario jsr",
    "perfil": "Perfil de poca memoria",
    "datos": "Datos: duplicados, versiones y kpi_diario",
    "tras_fusion": "Tras OPTIMIZE ... FINAL (fusiones): las golden queries dan lo mismo que antes de fusionar",
}


def tabla(res):
    ancho = max(len(r[1]) for r in res) + 2
    for g in ORDEN_GRUPOS:
        grupo = [r for r in res if r[0] == g]
        if not grupo:
            continue
        print("\n  [%s]" % TITULOS[g])
        if g in ("golden", "independiente", "tras_fusion"):
            ok = sum(1 for r in grupo if r[2] == OK)
            print("    %d de %d comprobaciones OK" % (ok, len(grupo)))
            grupo = [r for r in grupo if r[2] == FALLA]
        for _, n, e, d in grupo:
            marca = "OK   " if e == OK else "FALLA"
            print("    %s  %s%s" % (marca, n.ljust(ancho), ("  <- " + d) if d and e == FALLA else ""))


def main():
    t0 = time.time()
    modo_generar = "--generar-esperados" in sys.argv
    admin = cliente("jsr", "JSR_CH_CLAVE")
    analista = cliente("analista", "JSR_CH_ANALISTA_CLAVE")
    # base limpia: simula una reconstruccion desde cero
    admin.ejecutar("DROP DATABASE IF EXISTS jsrbot")
    t_carga = time.time()
    n_sent, cargadas = preparar(admin)
    print("esquema aplicado dos veces (%d sentencias), semilla cargada en %.1f s (lotes de %d filas): %s" % (
        n_sent, time.time() - t_carga, LOTE, ", ".join("%s=%d" % kv for kv in cargadas.items())))
    metas = cargar_metas()
    D = ci.Datos()
    if modo_generar:
        sys.exit(generar_esperados(analista, metas, D))
    pruebas_golden(analista, metas, D)
    pruebas_historicas(analista, metas)
    prueba_negativa(metas)
    prueba_mutantes(analista, metas)
    pruebas_seguridad(admin, analista)
    pruebas_perfil(admin)
    pruebas_datos(admin, analista, metas)
    fusionar(admin)
    pruebas_golden(analista, metas, D, "tras_fusion", con_independiente=False)
    tabla(resultados)
    # resumen por KPI
    print("\n  Resumen por golden query (escenarios con SQL = esperado / esperado = calculo independiente en Python):")
    for kpi, meta in metas.items():
        n = len(meta["pruebas"])
        g = sum(1 for r in resultados if r[0] == "golden" and r[1].startswith(kpi + " [") and r[2] == OK)
        i = sum(1 for r in resultados if r[0] == "independiente" and r[1].startswith(kpi + " [") and r[2] == OK)
        print("    %-24s v%d   SQL %d/%d   Python %d/%d   %s" % (kpi, meta["version"], g, n, i, n, "OK" if g == n and i == n else "FALLA"))
    fallas = [r for r in resultados if r[2] == FALLA]
    total = len(resultados)
    print("\n  %d comprobaciones, %d OK, %d FALLA  (%.1f s)" % (total, total - len(fallas), len(fallas), time.time() - t0))
    sys.exit(1 if fallas else 0)


if __name__ == "__main__":
    main()
