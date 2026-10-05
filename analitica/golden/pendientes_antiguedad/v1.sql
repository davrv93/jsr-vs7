-- pendientes_antiguedad v1 · Incidencias pendientes al CIERRE del periodo, por antiguedad.
-- Corte = las 00:00 de Lima del dia siguiente a {hasta} (fin del ultimo dia del periodo). {desde} no se usa:
-- una incidencia de junio que sigue abierta el 30-sep es pendiente de septiembre.
-- Pendiente al corte = su ultimo evento de ciclo de vida (creada, resuelta, reabierta, cerrada) con ts < corte es
-- 'creada' o 'reabierta'. Se reconstruye desde los EVENTOS, no desde el estado de hoy: una incidencia resuelta despues del
-- corte era pendiente en el corte, y una reabierta despues del corte estaba resuelta en el corte.
-- Antiguedad = tiempo de pared desde la creacion hasta el corte (dias de 24 h): tramos [0,1), [1,3), [3,7), [7, ...).
-- Grupo = el que tenia la incidencia en el corte (grupo del ultimo evento anterior al corte), no el de hoy.
-- Siempre devuelve los cuatro tramos, con 0 si no hay incidencias.
WITH
toUnixTimestamp(toDateTime(addDays({hasta:Date}, 1), 'America/Lima')) AS corte,
pend AS (
    SELECT
        incidencia_id,
        argMaxIf(tipo, (ts, id), tipo IN ('creada', 'resuelta', 'reabierta', 'cerrada')) AS ultimo_ciclo,
        argMax(grupo, (ts, id)) AS grupo_al_corte,
        minIf(toUnixTimestamp(ts), tipo = 'creada') AS creada_unix
    FROM jsrbot.v_eventos
    WHERE toUnixTimestamp(ts) < corte
    GROUP BY incidencia_id
    HAVING ultimo_ciclo IN ('creada', 'reabierta')
       AND ({grupo:String} = '' OR grupo_al_corte = {grupo:String})
),
conteo AS (
    SELECT
        countIf(corte - creada_unix < 86400) AS menos_1_dia,
        countIf(corte - creada_unix >= 86400 AND corte - creada_unix < 3 * 86400) AS de_1_a_3_dias,
        countIf(corte - creada_unix >= 3 * 86400 AND corte - creada_unix < 7 * 86400) AS de_3_a_7_dias,
        countIf(corte - creada_unix >= 7 * 86400) AS mas_de_7_dias
    FROM pend
)
SELECT tupleElement(x, 2) AS tramo, tupleElement(x, 3) AS incidencias
FROM conteo
ARRAY JOIN [(1, '< 1 d', menos_1_dia), (2, '1-3 d', de_1_a_3_dias), (3, '3-7 d', de_3_a_7_dias), (4, '> 7 d', mas_de_7_dias)] AS x
ORDER BY tupleElement(x, 1) ASC
