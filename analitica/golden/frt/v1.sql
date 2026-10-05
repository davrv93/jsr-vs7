-- frt v1 · Tiempo de primera respuesta (FRT): mediana y p90 en minutos del calendario de la prioridad.
-- Base: incidencias CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos), con primera respuesta
-- (frt_min no NULL). Las que aun no tienen respuesta NO entran: no hay tiempo que medir (ellas pesan en sla_cumplimiento).
-- Percentil con interpolacion lineal (quantileExactInclusive, igual que PERCENTILE.INC de una hoja de calculo).
-- Sin incidencias evaluadas: mediana y p90 salen NULL (nunca 0).
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
)
SELECT
    count() AS evaluadas,
    if(evaluadas = 0, NULL, round(quantileExactInclusive(0.5)(t.frt_min), 2)) AS mediana_min,
    if(evaluadas = 0, NULL, round(quantileExactInclusive(0.9)(t.frt_min), 2)) AS p90_min
FROM jsrbot.v_tiempos AS t
LEFT JOIN origen AS o ON o.incidencia_id = t.incidencia_id
WHERE t.frt_min IS NOT NULL
  AND toDate(t.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
  AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
