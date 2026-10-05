-- calidad_asistente v1 · Calidad del asistente. Una sola fila. El parametro {grupo} no aplica (los mensajes no tienen grupo).
-- Base: mensajes con ts en el periodo (dia de Lima) y feedback con ts en el periodo.
--   mensajes_usuario_clasificados: mensajes de la persona con una intencion asignada por el clasificador
--   correcciones_intencion: veces que un tecnico corrigio la intencion (feedback senal = correccion_intencion)
--   exactitud_frente_a_correcciones_pct = 100 x (1 - correcciones / clasificados). Es una ESTIMACION: supone correcto todo lo
--     que ningun tecnico corrigio. Subestima los errores que nadie revisa.
--   respuestas_con_frases_quitadas / respuestas_regeneradas: de las respuestas del asistente, las que el verificador recorto
--     (frases_quitadas > 0) y las que se regeneraron (regenerada = 1)
--   casos_atendidos: casos con al menos una respuesta del asistente en el periodo (un hilo solo de tecnico no es del asistente)
--   costo_usd_por_1000_casos = costo del LLM de redaccion / casos_atendidos x 1000
-- Sin mensajes: los porcentajes y el costo salen NULL (nunca 0).
WITH
m AS (
    SELECT * FROM jsrbot.v_mensajes
    WHERE toDate(ts, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
),
f AS (
    SELECT * FROM jsrbot.v_feedback
    WHERE toDate(ts, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
)
SELECT
    countIf(rol = 'usuario' AND intencion IS NOT NULL) AS mensajes_usuario_clasificados,
    (SELECT countIf(senal = 'correccion_intencion') FROM f) AS correcciones_intencion,
    if(mensajes_usuario_clasificados = 0, NULL,
       round(100 * (1 - correcciones_intencion / mensajes_usuario_clasificados), 2)) AS exactitud_frente_a_correcciones_pct,
    countIf(rol = 'asistente') AS respuestas_asistente,
    countIf(rol = 'asistente' AND frases_quitadas > 0) AS respuestas_con_frases_quitadas,
    if(respuestas_asistente = 0, NULL, round(100 * respuestas_con_frases_quitadas / respuestas_asistente, 2)) AS pct_con_frases_quitadas,
    countIf(rol = 'asistente' AND regenerada = 1) AS respuestas_regeneradas,
    if(respuestas_asistente = 0, NULL, round(100 * respuestas_regeneradas / respuestas_asistente, 2)) AS pct_regeneradas,
    uniqExactIf(caso_id, rol = 'asistente') AS casos_atendidos,
    round(sumIf(costo_usd, rol = 'asistente'), 2) AS costo_usd_total,
    if(casos_atendidos = 0, NULL, round(1000 * sumIf(costo_usd, rol = 'asistente') / casos_atendidos, 2)) AS costo_usd_por_1000_casos
FROM m
