-- tasa_escalamiento v1 · Tasa de escalamiento funcional.
-- Base: incidencias CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos): el grupo con el que se
-- crearon, no al que llegaron al escalar (si no, la Mesa N1 nunca tendria escalamientos).
-- Escalada = al menos un evento 'escalada' (escalamiento funcional: pasa a otro nivel o grupo). Los avisos jerarquicos
-- no cuentan. Las incidencias aun abiertas SI entran en el denominador (todas las creadas en el periodo).
-- El numerador se lee de los eventos, no del contador de incidencias_estado, para que un contador desfasado no mienta.
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
),
escaladas AS (
    SELECT incidencia_id, count() AS veces
    FROM jsrbot.v_eventos
    WHERE tipo = 'escalada'
    GROUP BY incidencia_id
)
SELECT
    count() AS incidencias,
    countIf(e.veces > 0) AS escaladas,
    if(incidencias = 0, NULL, round(100 * escaladas / incidencias, 2)) AS porcentaje
FROM jsrbot.v_incidencias AS i
LEFT JOIN origen AS o ON o.incidencia_id = i.incidencia_id
LEFT JOIN escaladas AS e ON e.incidencia_id = i.incidencia_id
WHERE toDate(i.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
  AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
