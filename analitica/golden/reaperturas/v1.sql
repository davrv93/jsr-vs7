-- reaperturas v1 · Reaperturas dentro de 7 dias.
-- Base: incidencias CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos), que tuvieron al menos una
-- resolucion (evento 'resuelta'). Reabierta en 7 dias = existe una resolucion seguida de una reapertura 'reabierta' dentro de
-- los 7 dias siguientes (604800 s, limite inclusivo). Se lee de los eventos: hacen falta los instantes de ambos.
-- La ventana NO se corta en {hasta}: una reapertura posterior al periodo pero dentro de los 7 dias de su resolucion cuenta.
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
),
tiempos_evento AS (
    SELECT
        incidencia_id,
        groupArrayIf(toUnixTimestamp(ts), tipo = 'resuelta') AS resoluciones,
        groupArrayIf(toUnixTimestamp(ts), tipo = 'reabierta') AS reaperturas
    FROM jsrbot.v_eventos
    WHERE tipo IN ('resuelta', 'reabierta')
    GROUP BY incidencia_id
)
SELECT
    countIf(length(x.resoluciones) > 0) AS resueltas,
    countIf(arrayExists(r -> arrayExists(a -> a > r AND a - r <= 604800, x.reaperturas), x.resoluciones)) AS reabiertas_7d,
    if(resueltas = 0, NULL, round(100 * reabiertas_7d / resueltas, 2)) AS porcentaje
FROM jsrbot.v_incidencias AS i
LEFT JOIN origen AS o ON o.incidencia_id = i.incidencia_id
LEFT JOIN tiempos_evento AS x ON x.incidencia_id = i.incidencia_id
WHERE toDate(i.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
  AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
