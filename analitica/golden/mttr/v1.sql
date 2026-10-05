-- mttr v1 · Tiempo de resolucion (MTTR): mediana y media en minutos del calendario de la prioridad, sin pausas.
-- Base: incidencias CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos), con resolucion vigente
-- (mttr_min no NULL). Una incidencia abierta o reabierta NO entra (mttr_min es NULL hasta su ultima resolucion).
-- mttr_min ya viene sin pausas y mide hasta la ULTIMA resolucion (el tiempo entre una resolucion y su reapertura corre).
-- Sin incidencias evaluadas: mediana y media salen NULL (nunca 0).
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
)
SELECT
    count() AS evaluadas,
    if(evaluadas = 0, NULL, round(quantileExactInclusive(0.5)(t.mttr_min), 2)) AS mediana_min,
    if(evaluadas = 0, NULL, round(avg(t.mttr_min), 2)) AS media_min
FROM jsrbot.v_tiempos AS t
LEFT JOIN origen AS o ON o.incidencia_id = t.incidencia_id
WHERE t.mttr_min IS NOT NULL
  AND toDate(t.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
  AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
