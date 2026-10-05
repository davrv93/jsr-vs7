-- productividad_tecnico v1 · Productividad por tecnico (SIN ranking: se ordena por id, nunca por desempeno).
-- Base: incidencias RESUELTAS en el periodo (dia de Lima de su ultima resolucion vigente), atribuidas al tecnico con el que
-- quedaron (tecnico_id del ultimo estado). Con {grupo}, solo las incidencias cuyo grupo actual es ese (el grupo del tecnico).
--   resueltas = cuantas · frt_mediana_min y mttr_mediana_min = medianas SOBRE ESAS MISMAS incidencias
--   csat_media = media de las encuestas respondidas de esas incidencias (cuando se enviaron)
-- Un tecnico sin resueltas en el periodo no aparece. Medianas con interpolacion lineal. Un tecnico con una sola resuelta
-- tiene mediana igual a ese unico valor. csat_media es NULL si no hay encuestas respondidas.
WITH
res AS (
    SELECT incidencia_id, tecnico_id, frt_min, mttr_min
    FROM jsrbot.v_tiempos
    WHERE resuelta_en IS NOT NULL
      AND tecnico_id IS NOT NULL
      AND toDate(resuelta_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
      AND ({grupo:String} = '' OR grupo = {grupo:String})
),
tiempos_tec AS (
    SELECT
        tecnico_id,
        count() AS resueltas,
        round(quantileExactInclusive(0.5)(frt_min), 2) AS frt_mediana_min,
        round(quantileExactInclusive(0.5)(mttr_min), 2) AS mttr_mediana_min
    FROM res
    GROUP BY tecnico_id
),
enc_tec AS (
    SELECT
        r.tecnico_id AS tecnico_id,
        countIf(e.puntaje IS NOT NULL) AS encuestas_respondidas,
        if(encuestas_respondidas = 0, NULL, round(avg(e.puntaje), 2)) AS csat_media
    FROM res AS r
    INNER JOIN jsrbot.v_encuestas AS e ON e.incidencia_id = r.incidencia_id
    GROUP BY r.tecnico_id
)
SELECT
    t.tecnico_id AS tecnico_id,
    t.resueltas AS resueltas,
    t.frt_mediana_min AS frt_mediana_min,
    t.mttr_mediana_min AS mttr_mediana_min,
    ifNull(c.encuestas_respondidas, 0) AS encuestas_respondidas,
    c.csat_media AS csat_media
FROM tiempos_tec AS t
LEFT JOIN enc_tec AS c ON c.tecnico_id = t.tecnico_id
ORDER BY t.tecnico_id
