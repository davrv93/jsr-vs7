-- contencion_asistente v1 · Contencion del asistente.
-- Base: CASOS (conversaciones) iniciados en el periodo (dia de Lima) y ya concluidos (estado distinto de 'abierto').
-- Contenido = el asistente lo resolvio, la persona lo confirmo y no hubo incidencia.
-- Los casos aun abiertos NO entran en el denominador: se informan aparte (casos_abiertos_excluidos).
-- Los casos no tienen grupo, asi que el parametro {grupo} no aplica: con un grupo la cifra es la misma.
-- Lee v_casos (la ultima version de cada caso). NO se calcula con una vista materializada: el estado de un caso
-- puede retroceder (resuelto por el asistente y luego con incidencia) y la vista lo contaria como contenido para siempre.
SELECT
    countIf(estado != 'abierto') AS casos_concluidos,
    countIf(estado = 'resuelto_asistente' AND confirmado_resuelto = 1 AND tiene_incidencia = 0) AS contenidos,
    if(casos_concluidos = 0, NULL, round(100 * contenidos / casos_concluidos, 2)) AS porcentaje,
    countIf(estado = 'abierto') AS casos_abiertos_excluidos
FROM jsrbot.v_casos
WHERE toDate(inicio, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
