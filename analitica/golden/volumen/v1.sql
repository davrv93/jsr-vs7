-- volumen v1 · Volumen de casos e incidencias por canal, categoria, sede, hora y dia.
-- Incidencias: CREADAS en el periodo (dia de Lima), del grupo de origen {grupo} ('' = todos).
-- Casos: iniciados en el periodo (dia de Lima). Un caso no tiene categoria, sede ni grupo: solo cuenta en canal, hora, dia y
-- total, y con un {grupo} distinto de '' no se cuentan. En las filas donde los casos no aplican (categoria, sede, o cualquier
-- fila con un {grupo} elegido) la columna casos sale NULL, no 0.
-- hora = hora de Lima ('00' a '23'), dia = fecha de Lima (aaaa-mm-dd). Solo aparecen los valores con datos, salvo la fila total.
-- Una categoria o una sede sin dato se muestra como '(sin categoria)' o '(sin sede)'.
WITH
origen AS (
    SELECT incidencia_id, any(grupo) AS grupo_origen
    FROM jsrbot.v_eventos
    WHERE tipo = 'creada'
    GROUP BY incidencia_id
),
inc AS (
    SELECT i.canal AS canal, i.categoria AS categoria, i.sede AS sede, i.creada_en AS creada_en
    FROM jsrbot.v_incidencias AS i
    LEFT JOIN origen AS o ON o.incidencia_id = i.incidencia_id
    WHERE toDate(i.creada_en, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
      AND ({grupo:String} = '' OR o.grupo_origen = {grupo:String})
),
caso AS (
    SELECT canal, inicio
    FROM jsrbot.v_casos
    WHERE toDate(inicio, 'America/Lima') BETWEEN {desde:Date} AND {hasta:Date}
      AND {grupo:String} = ''
)
SELECT dimension, valor, casos, incidencias
FROM
(
    SELECT
        'total' AS dimension,
        '' AS valor,
        if({grupo:String} = '', toNullable((SELECT count() FROM caso)), NULL) AS casos,
        (SELECT count() FROM inc) AS incidencias
    UNION ALL
    SELECT
        dimension,
        valor,
        if({grupo:String} = '' AND dimension IN ('canal', 'hora', 'dia'), toNullable(countIf(fuente = 'caso')), NULL) AS casos,
        countIf(fuente = 'incidencia') AS incidencias
    FROM
    (
        SELECT 'canal' AS dimension, canal AS valor, 'incidencia' AS fuente FROM inc
        UNION ALL SELECT 'canal', canal, 'caso' FROM caso
        UNION ALL SELECT 'categoria', ifNull(categoria, '(sin categoria)'), 'incidencia' FROM inc
        UNION ALL SELECT 'sede', ifNull(sede, '(sin sede)'), 'incidencia' FROM inc
        UNION ALL SELECT 'hora', lpad(toString(toHour(creada_en, 'America/Lima')), 2, '0'), 'incidencia' FROM inc
        UNION ALL SELECT 'hora', lpad(toString(toHour(inicio, 'America/Lima')), 2, '0'), 'caso' FROM caso
        UNION ALL SELECT 'dia', toString(toDate(creada_en, 'America/Lima')), 'incidencia' FROM inc
        UNION ALL SELECT 'dia', toString(toDate(inicio, 'America/Lima')), 'caso' FROM caso
    )
    GROUP BY dimension, valor
)
ORDER BY indexOf(['total', 'canal', 'categoria', 'sede', 'hora', 'dia'], dimension), valor
