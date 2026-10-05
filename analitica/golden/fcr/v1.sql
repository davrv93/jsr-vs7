-- fcr v1 · Resolucion al primer contacto (FCR).
-- Base: incidencias CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos), ya resueltas y con
-- veredicto de primer contacto (primer_contacto no NULL). El backend deja primer_contacto en NULL si nunca se resolvio o si
-- se cerro SIN confirmacion del usuario: esas no cuentan. Vale 1 si la resolvio el primer tecnico, sin escalamiento,
-- reasignacion ni reapertura, y 0 en los demas casos resueltos.
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
)
SELECT
    countIf(t.primer_contacto IS NOT NULL) AS evaluadas,
    countIf(t.primer_contacto = 1) AS al_primer_contacto,
    if(evaluadas = 0, NULL, round(100 * al_primer_contacto / evaluadas, 2)) AS porcentaje
FROM jsrbot.v_tiempos AS t
LEFT JOIN origen AS o ON o.incidencia_id = t.incidencia_id
WHERE toDate(t.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
  AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
