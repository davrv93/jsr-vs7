-- csat v1 · Satisfaccion (CSAT).
-- Base: ENCUESTAS enviadas en el periodo (dia de Lima de su ts), del grupo de origen {grupo} ('' = todos). Las encuestas de un
-- caso resuelto por el asistente no tienen incidencia ni grupo: solo entran cuando {grupo} es ''.
-- Una encuesta sin puntaje esta enviada y sin responder: cuenta en la tasa de respuesta, no en la media.
-- porcentajes: tasa_respuesta_pct = respondidas / enviadas · pct_4_5 = respondidas con 4 o 5 / respondidas.
-- csat_media va de 1 a 5. Sin respuestas: csat_media y pct_4_5 salen NULL (nunca 0).
-- v_encuestas junta las dos filas de una encuesta respondida (envio sin puntaje + respuesta) por id.
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
)
SELECT
    count() AS enviadas,
    countIf(e.puntaje IS NOT NULL) AS respondidas,
    if(enviadas = 0, NULL, round(100 * respondidas / enviadas, 2)) AS tasa_respuesta_pct,
    if(respondidas = 0, NULL, round(avg(e.puntaje), 2)) AS csat_media,
    if(respondidas = 0, NULL, round(100 * countIf(e.puntaje >= 4) / respondidas, 2)) AS pct_4_5
FROM jsrbot.v_encuestas AS e
LEFT JOIN origen AS o ON o.incidencia_id = e.incidencia_id
WHERE toDate(e.ts, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
  AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
