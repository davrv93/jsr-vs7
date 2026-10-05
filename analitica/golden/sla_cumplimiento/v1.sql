-- sla_cumplimiento v1 · Cumplimiento de SLA (respuesta y resolucion).
-- Base: incidencias CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos).
-- Cada metrica tiene su propio denominador: solo entran las incidencias con veredicto (sla_*_ok no NULL).
--   * Una incidencia abierta con el plazo ya vencido cuenta como incumplida (el backend escribe 0).
--   * Una incidencia abierta cuyo plazo aun no vence no tiene veredicto y NO entra.
-- Los tiempos laborales y los veredictos los calcula el backend (incidencias_tiempos): aqui no se recalcula nada.
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
),
base AS (
    SELECT t.sla_respuesta_ok AS ok_respuesta, t.sla_resolucion_ok AS ok_resolucion
    FROM jsrbot.v_tiempos AS t
    LEFT JOIN origen AS o ON o.incidencia_id = t.incidencia_id
    WHERE toDate(t.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
      AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
)
SELECT metrica, evaluadas, cumplidas, porcentaje
FROM
(
    SELECT
        'respuesta' AS metrica,
        countIf(ok_respuesta IS NOT NULL) AS evaluadas,
        countIf(ok_respuesta = 1) AS cumplidas,
        if(evaluadas = 0, NULL, round(100 * cumplidas / evaluadas, 2)) AS porcentaje
    FROM base
    UNION ALL
    SELECT
        'resolucion' AS metrica,
        countIf(ok_resolucion IS NOT NULL) AS evaluadas,
        countIf(ok_resolucion = 1) AS cumplidas,
        if(evaluadas = 0, NULL, round(100 * cumplidas / evaluadas, 2)) AS porcentaje
    FROM base
)
ORDER BY indexOf(['respuesta', 'resolucion'], metrica)
