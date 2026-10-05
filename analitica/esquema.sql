-- jsrbot · esquema de ClickHouse (reporteria). Dueno: Datos.
--
-- ClickHouse NO es fuente de verdad (AGENTS.md 1.4 regla 8): se puede borrar y reconstruir desde Postgres
-- (tabla outbox_analitica). Nunca se escribe aqui algo que no exista antes en Postgres.
--
-- Las columnas de las siete tablas de carga se llaman EXACTAMENTE como las claves del payload de
-- docs/CONTRATOS.md seccion 4, porque el backend inserta con INSERT ... FORMAT JSONEachRow
-- y date_time_input_format=best_effort.
--
-- Este archivo es idempotente (IF NOT EXISTS) y usa nombres completos (jsrbot.tabla), sin USE.
-- Una sentencia por cada punto y coma al final de linea. Los comentarios no llevan punto y coma
-- para que un ejecutor sencillo pueda partir el archivo por sentencias.
--
-- Hora: todo se guarda en UTC. Los dias y horas de los KPI se calculan en America/Lima (UTC-5, sin horario de verano).
-- Los tiempos laborales (frt_min, mttr_min, pausa_min) los calcula el BACKEND en Go y llegan hechos
-- en incidencias_tiempos: aqui no se recalcula ningun horario laboral.

CREATE DATABASE IF NOT EXISTS jsrbot;

-- =====================================================================================================
-- 1. Tablas de carga (contrato seccion 4)
-- =====================================================================================================

-- Cada cambio de estado, asignacion, escalamiento, pausa... Los eventos no se editan: una correccion es otro evento.
-- ReplacingMergeTree(id): un reenvio del mismo evento (misma incidencia, mismo ts, mismo id) se funde en uno.
-- Particion por mes del evento. Un reenvio con un ts distinto caeria en otra particion y NO se deduplicaria:
-- el ts de un evento es inmutable.
-- Hasta que el merge de fondo corra, pueden verse duplicados: consulta siempre v_eventos (con FINAL).
CREATE TABLE IF NOT EXISTS jsrbot.eventos_incidencia
(
    id             UInt64,
    incidencia_id  UInt64,
    numero         String,
    ts             DateTime64(3, 'UTC'),
    tipo           LowCardinality(String),
    actor_tipo     LowCardinality(String),
    actor_id       String,
    prioridad      LowCardinality(String),
    categoria      LowCardinality(Nullable(String)),
    grupo          LowCardinality(Nullable(String)),
    tecnico_id     Nullable(UInt32),
    datos          String
)
ENGINE = ReplacingMergeTree(id)
PARTITION BY toYYYYMM(ts)
ORDER BY (incidencia_id, ts, id);

-- Ultimo estado de cada incidencia. El backend escribe una fila nueva (version = milisegundos epoch de
-- actualizada_en) cada vez que algo cambia. Se consulta con FINAL (via v_incidencias) o con argMax.
CREATE TABLE IF NOT EXISTS jsrbot.incidencias_estado
(
    incidencia_id         UInt64,
    version               UInt64,
    numero                String,
    caso_id               Nullable(UInt64),
    persona_id            Nullable(UInt32),
    tipo                  LowCardinality(String),
    categoria             LowCardinality(Nullable(String)),
    impacto               LowCardinality(String),
    urgencia              LowCardinality(String),
    prioridad             LowCardinality(String),
    estado                LowCardinality(String),
    grupo                 LowCardinality(Nullable(String)),
    nivel                 LowCardinality(String),
    tecnico_id            Nullable(UInt32),
    canal                 LowCardinality(String),
    sede                  LowCardinality(Nullable(String)),
    area                  LowCardinality(Nullable(String)),
    creada_en             DateTime64(3, 'UTC'),
    primera_respuesta_en  Nullable(DateTime64(3, 'UTC')),
    resuelta_en           Nullable(DateTime64(3, 'UTC')),
    cerrada_en            Nullable(DateTime64(3, 'UTC')),
    reaperturas           UInt16,
    escalamientos         UInt16
)
ENGINE = ReplacingMergeTree(version)
ORDER BY incidencia_id;

-- Tiempos en minutos del calendario de la politica de SLA (laborales, salvo P1 si usa 24x7), calculados por el backend.
-- NULL significa que aun no aplica. sla_*_ok es 0 o 1, y vale 0 tambien cuando el plazo ya vencio sin cumplirse.
-- El backend reescribe la fila con una version nueva cada vez que cambia algo.
-- Los KPI que necesitan DOS eventos (FRT, MTTR) salen de aqui y nunca de una vista materializada.
CREATE TABLE IF NOT EXISTS jsrbot.incidencias_tiempos
(
    incidencia_id      UInt64,
    version            UInt64,
    prioridad          LowCardinality(String),
    categoria          LowCardinality(Nullable(String)),
    grupo              LowCardinality(Nullable(String)),
    tecnico_id         Nullable(UInt32),
    creada_en          DateTime64(3, 'UTC'),
    resuelta_en        Nullable(DateTime64(3, 'UTC')),
    cerrada_en         Nullable(DateTime64(3, 'UTC')),
    frt_min            Nullable(Float64),
    mttr_min           Nullable(Float64),
    pausa_min          Float64,
    sla_respuesta_ok   Nullable(UInt8),
    sla_resolucion_ok  Nullable(UInt8),
    primer_contacto    Nullable(UInt8)
)
ENGINE = ReplacingMergeTree(version)
ORDER BY incidencia_id;

-- Estado de cada caso (conversacion). Una fila por cambio, con version.
CREATE TABLE IF NOT EXISTS jsrbot.casos_estado
(
    caso_id              UInt64,
    version              UInt64,
    canal                LowCardinality(String),
    persona_id           Nullable(UInt32),
    estado               LowCardinality(String),
    inicio               DateTime64(3, 'UTC'),
    ultimo_mensaje       DateTime64(3, 'UTC'),
    tiene_incidencia     UInt8,
    confirmado_resuelto  UInt8
)
ENGINE = ReplacingMergeTree(version)
ORDER BY caso_id;

-- Mensajes del caso. Solo inserciones. El texto va vacio salvo ANALITICA_TEXTO=1.
-- MergeTree sin deduplicar: un lote reenviado puede duplicar filas. Por eso se consulta v_mensajes (LIMIT 1 BY id).
-- non_replicated_deduplication_window descarta ademas los lotes reenviados identicos (mismas filas, mismo orden).
CREATE TABLE IF NOT EXISTS jsrbot.mensajes
(
    id               UInt64,
    caso_id          UInt64,
    ts               DateTime64(3, 'UTC'),
    rol              LowCardinality(String),
    canal            LowCardinality(String),
    intencion        LowCardinality(Nullable(String)),
    confianza        Nullable(Float32),
    categoria        LowCardinality(Nullable(String)),
    juez_modo        LowCardinality(String),
    juez_veredicto   String,
    latencia_ms      Nullable(UInt32),
    regenerada       UInt8,
    frases_quitadas  UInt16,
    costo_usd        Float64,
    texto            String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (caso_id, ts, id)
SETTINGS non_replicated_deduplication_window = 1000;

-- Encuesta de satisfaccion. puntaje NULL = enviada y sin responder (la tasa de respuesta lo necesita).
-- La misma encuesta (id) llega dos veces si se responde: primero con puntaje NULL y luego con el puntaje.
-- v_encuestas las junta por id (max ignora los NULL), asi que el orden de llegada no importa.
CREATE TABLE IF NOT EXISTS jsrbot.encuestas
(
    id             UInt64,
    incidencia_id  Nullable(UInt64),
    caso_id        Nullable(UInt64),
    ts             DateTime64(3, 'UTC'),
    puntaje        Nullable(UInt8)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (ts, id)
SETTINGS non_replicated_deduplication_window = 1000;

-- Senales de calidad: pulgar_arriba, pulgar_abajo, se_resolvio, sigue_igual, correccion_intencion,
-- correccion_categoria, reapertura. Solo inserciones.
CREATE TABLE IF NOT EXISTS jsrbot.feedback
(
    id             UInt64,
    caso_id        Nullable(UInt64),
    incidencia_id  Nullable(UInt64),
    mensaje_id     Nullable(UInt64),
    ts             DateTime64(3, 'UTC'),
    senal          LowCardinality(String),
    valor          Nullable(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (senal, ts, id)
SETTINGS non_replicated_deduplication_window = 1000;

-- =====================================================================================================
-- 2. Vistas "vigentes": resuelven duplicados y versiones. Las golden queries leen SOLO estas vistas.
-- =====================================================================================================

CREATE VIEW IF NOT EXISTS jsrbot.v_eventos AS
SELECT * FROM jsrbot.eventos_incidencia FINAL;

CREATE VIEW IF NOT EXISTS jsrbot.v_incidencias AS
SELECT * FROM jsrbot.incidencias_estado FINAL;

CREATE VIEW IF NOT EXISTS jsrbot.v_tiempos AS
SELECT * FROM jsrbot.incidencias_tiempos FINAL;

CREATE VIEW IF NOT EXISTS jsrbot.v_casos AS
SELECT * FROM jsrbot.casos_estado FINAL;

CREATE VIEW IF NOT EXISTS jsrbot.v_mensajes AS
SELECT * FROM jsrbot.mensajes LIMIT 1 BY id;

CREATE VIEW IF NOT EXISTS jsrbot.v_feedback AS
SELECT * FROM jsrbot.feedback LIMIT 1 BY id;

CREATE VIEW IF NOT EXISTS jsrbot.v_encuestas AS
SELECT
    id,
    any(incidencia_id) AS incidencia_id,
    any(caso_id)       AS caso_id,
    min(ts)            AS ts,
    max(puntaje)       AS puntaje
FROM jsrbot.encuestas
GROUP BY id;

-- =====================================================================================================
-- 3. kpi_diario: agregados por dia, SOLO de lo que se calcula con UNA fila.
-- =====================================================================================================
-- TRAMPA (ARQUITECTURA.md 8.2): una vista materializada solo ve las filas NUEVAS de su tabla de origen.
--  * Sirve para contar eventos o mensajes (cada uno llega una vez y no cambia) y para casos nuevos.
--  * NO sirve para FRT, MTTR ni SLA, que necesitan dos eventos: salen de incidencias_tiempos.
--  * NO sirve para la contencion del asistente. casos_estado lleva una fila por cambio y el estado puede
--    retroceder (un caso resuelto por el asistente vuelve a abrirse y termina con incidencia). La vista
--    contaria el caso como contenido para siempre. La contencion sale de v_casos.
--  * Todos los contadores son uniqExact sobre el id del hecho: un reenvio o una version nueva no cuentan dos veces.
--  * NO hay sumas (costo del LLM): una suma cuenta dos veces un mensaje reenviado. El costo exacto sale de v_mensajes
--    (golden calidad_asistente). La unica excepcion es la latencia (percentiles aproximados por naturaleza).
-- kpi_diario es un acelerador de tendencias. NO es una definicion de KPI: la fuente exacta son las golden queries,
-- y la prueba compara ambos.
CREATE TABLE IF NOT EXISTS jsrbot.kpi_diario
(
    dia                      Date,
    canal                    LowCardinality(String),
    categoria                LowCardinality(String),
    grupo                    LowCardinality(String),
    prioridad                LowCardinality(String),
    tecnico_id               UInt32,
    incidencias_creadas      AggregateFunction(uniqExactIf, UInt64, UInt8),
    resoluciones             AggregateFunction(uniqExactIf, UInt64, UInt8),
    reaperturas              AggregateFunction(uniqExactIf, UInt64, UInt8),
    escalamientos            AggregateFunction(uniqExactIf, UInt64, UInt8),
    casos_nuevos             AggregateFunction(uniqExact, UInt64),
    casos_con_incidencia     AggregateFunction(uniqExactIf, UInt64, UInt8),
    mensajes                 AggregateFunction(uniqExact, UInt64),
    mensajes_usuario         AggregateFunction(uniqExactIf, UInt64, UInt8),
    respuestas_asistente     AggregateFunction(uniqExactIf, UInt64, UInt8),
    respuestas_regeneradas   AggregateFunction(uniqExactIf, UInt64, UInt8),
    respuestas_con_quitadas  AggregateFunction(uniqExactIf, UInt64, UInt8),
    latencia_asistente_ms    AggregateFunction(quantilesIf(0.5, 0.9), UInt32, UInt8)
)
ENGINE = AggregatingMergeTree
ORDER BY (dia, canal, categoria, grupo, prioridad, tecnico_id);

-- Eventos: una fila por evento. Cada evento se cuenta una vez por su id.
CREATE MATERIALIZED VIEW IF NOT EXISTS jsrbot.mv_kpi_eventos TO jsrbot.kpi_diario AS
SELECT
    toDate(ts, 'America/Lima')                       AS dia,
    ifNull(categoria, '')                            AS categoria,
    ifNull(grupo, '')                                AS grupo,
    prioridad,
    ifNull(tecnico_id, 0)                            AS tecnico_id,
    uniqExactIfState(id, tipo = 'creada')            AS incidencias_creadas,
    uniqExactIfState(id, tipo = 'resuelta')          AS resoluciones,
    uniqExactIfState(id, tipo = 'reabierta')         AS reaperturas,
    uniqExactIfState(id, tipo = 'escalada')          AS escalamientos
FROM jsrbot.eventos_incidencia
WHERE tipo IN ('creada', 'resuelta', 'reabierta', 'escalada')
GROUP BY dia, categoria, grupo, prioridad, tecnico_id;

-- Casos: el dia de inicio y el canal no cambian entre versiones, y tiene_incidencia solo pasa de 0 a 1.
CREATE MATERIALIZED VIEW IF NOT EXISTS jsrbot.mv_kpi_casos TO jsrbot.kpi_diario AS
SELECT
    toDate(inicio, 'America/Lima')                   AS dia,
    canal,
    uniqExactState(caso_id)                          AS casos_nuevos,
    uniqExactIfState(caso_id, tiene_incidencia = 1)  AS casos_con_incidencia
FROM jsrbot.casos_estado
GROUP BY dia, canal;

-- Mensajes: una fila por mensaje, inmutable.
CREATE MATERIALIZED VIEW IF NOT EXISTS jsrbot.mv_kpi_mensajes TO jsrbot.kpi_diario AS
SELECT
    toDate(ts, 'America/Lima')                                  AS dia,
    canal,
    uniqExactState(id)                                          AS mensajes,
    uniqExactIfState(id, rol = 'usuario')                       AS mensajes_usuario,
    uniqExactIfState(id, rol = 'asistente')                     AS respuestas_asistente,
    uniqExactIfState(id, rol = 'asistente' AND regenerada = 1)  AS respuestas_regeneradas,
    uniqExactIfState(id, rol = 'asistente' AND frases_quitadas > 0) AS respuestas_con_quitadas,
    quantilesIfState(0.5, 0.9)(ifNull(latencia_ms, 0), rol = 'asistente' AND latencia_ms IS NOT NULL) AS latencia_asistente_ms
FROM jsrbot.mensajes
GROUP BY dia, canal;

-- Lectura de kpi_diario con los estados ya combinados.
CREATE VIEW IF NOT EXISTS jsrbot.v_kpi_diario AS
SELECT
    dia, canal, categoria, grupo, prioridad, tecnico_id,
    uniqExactIfMerge(incidencias_creadas)     AS incidencias_creadas,
    uniqExactIfMerge(resoluciones)            AS resoluciones,
    uniqExactIfMerge(reaperturas)             AS reaperturas,
    uniqExactIfMerge(escalamientos)           AS escalamientos,
    uniqExactMerge(casos_nuevos)              AS casos_nuevos,
    uniqExactIfMerge(casos_con_incidencia)    AS casos_con_incidencia,
    uniqExactMerge(mensajes)                  AS mensajes,
    uniqExactIfMerge(mensajes_usuario)        AS mensajes_usuario,
    uniqExactIfMerge(respuestas_asistente)    AS respuestas_asistente,
    uniqExactIfMerge(respuestas_regeneradas)  AS respuestas_regeneradas,
    uniqExactIfMerge(respuestas_con_quitadas) AS respuestas_con_quitadas,
    quantilesIfMerge(0.5, 0.9)(latencia_asistente_ms) AS latencia_asistente_ms_p50_p90
FROM jsrbot.kpi_diario
GROUP BY dia, canal, categoria, grupo, prioridad, tecnico_id;
