# analitica · ClickHouse, KPI y golden queries

Reportería de jsrbot. ClickHouse **no es fuente de verdad** (`AGENTS.md` §1.4 regla 8): se carga desde Postgres por la
outbox, se puede borrar y reconstruir (`reconstruir.md`), y nunca se escribe en él algo que no exista antes en Postgres.
Cada KPI es **una golden query** (regla 7): tablero, reporte programado, exportación y analista ejecutan la misma consulta.

```
analitica/
  esquema.sql                 tablas, vistas «vigentes» y kpi_diario (idempotente, nombres completos)
  perfil-poca-memoria.xml     config.d de ClickHouse (ARQUITECTURA §9)
  usuarios.xml                users.d: jsr (escritura) y analista (solo lectura, con límites)
  .env.ejemplo                variables (claves y hashes); .env no se sube
  catalogo.json               generado desde los meta.yaml: lo leen el backend y el analista
  golden/<kpi>/               meta.yaml · vN.sql · esperado*.csv (7 escenarios) · historicas/ (versiones congeladas)
  semilla/                    datos sintéticos fijos: generar_semilla.py, validar_semilla.py, *.jsonl, SHA256SUMS
  herramientas/               pruebas, cálculo independiente, comparador, generador de catálogo
  probar_golden.sh            LA prueba (AGENTS.md §1.3)
  probar_reconstruccion.sh    vaciar y recargar da las mismas cifras
  reconstruir.md              procedimiento de reconstrucción
```

## 1. Cómo correr

Requisitos: Docker, Python 3.9+ (solo biblioteca estándar), `openssl` y `curl`.

```bash
cd analitica
./probar_golden.sh                 # LA prueba: sale con código 0 si todo está en verde
./probar_golden.sh --generar-esperados   # reescribe esperado*.csv, SOLO si SQL y Python independiente coinciden
./probar_reconstruccion.sh         # vaciar ClickHouse y recargarlo: mismas huellas y mismas golden queries
python3 herramientas/generar_catalogo.py # regenera catalogo.json desde los meta.yaml
python3 semilla/generar_semilla.py --verificar   # la semilla guardada es la que produce el código
python3 semilla/validar_semilla.py       # la semilla es coherente (recalcula sus tiempos desde los eventos)
```

`probar_golden.sh` levanta un ClickHouse **efímero** con el perfil de poca memoria (contenedor con tope de 3 GB, claves al azar
que no se imprimen), aplica el esquema (dos veces: es idempotente), carga la semilla **por lotes de 100 filas** como el backend,
y lo apaga al terminar, pase lo que pase. Imagen por defecto `clickhouse/clickhouse-server:26.9.10.4-alpine` (la versión probada, fijada
para que la prueba no cambie sola; `latest-alpine` era la misma imagen); se cambia con `JSR_CH_IMAGEN`. Tarda unos 25 s.

Qué comprueba, en orden:

1. **Semilla reproducible y coherente**: el código regenera los mismos bytes (`SHA256SUMS`), la función de minutos laborales
   pasa su autoprueba y `validar_semilla.py` recalcula de los eventos, con otro algoritmo, el estado y los tiempos de las 624
   incidencias.
2. **SQL contra esperado**: cada golden query, con el usuario `analista`, en 7 escenarios (12 × 7 = 84 comparaciones).
3. **Esperado contra cálculo independiente**: `herramientas/calculo_independiente.py` recalcula cada KPI en Python con
   bucles y diccionarios sobre los `.jsonl`, sin compartir código con el SQL. Un esperado solo vale si coinciden.
4. **Prueba negativa**: alterar un esperado en memoria (una celda, una fila, el encabezado) hace fallar la comparación.
5. **26 mutantes**: errores típicos de SQL (día en UTC, sin `FINAL`, grupo actual en vez de grupo de origen, ventana de 8 días,
   media en vez de mediana…) que alguna prueba debe detectar. Un mutante vivo es una falla: faltan escenarios.
6. **Usuario `analista`**: no inserta, no borra, no altera, no crea, no lee `system.users`, no sube sus límites; tiene tope de
   filas leídas, filas de resultado y memoria, y el tiempo de ejecución configurado. El usuario `default` no existe.
7. **Perfil de poca memoria** aplicado y **duplicados y versiones** de la semilla resueltos; `kpi_diario` reconcilia con las
   golden queries.
8. **Tras `OPTIMIZE ... FINAL`**, las 84 comparaciones dan lo mismo: el resultado no depende de las fusiones.

**Tolerancia numérica** (`herramientas/comparar_csv.py`): dos números son iguales si `|a − b| ≤ 0,006` (medio centésimo, porque los
porcentajes y los minutos se redondean a 2 decimales, más holgura de punto flotante). Enteros y textos, exactos; `NULL` solo es
igual a `NULL`; mismas columnas y mismas filas, en el mismo orden.

## 2. Esquema

Las columnas de las siete tablas de carga se llaman **exactamente** como las claves del payload de `docs/CONTRATOS.md` §4:

| Tabla | Motor | Clave de orden | Nota |
|---|---|---|---|
| `eventos_incidencia` | `ReplacingMergeTree(id)`, por mes de `ts` | `(incidencia_id, ts, id)` | un evento reenviado se funde con el original |
| `incidencias_estado` | `ReplacingMergeTree(version)` | `incidencia_id` | gana la mayor `version` (ms epoch de `actualizada_en`) |
| `incidencias_tiempos` | `ReplacingMergeTree(version)` | `incidencia_id` | tiempos que calcula el **backend**; aquí no se recalcula horario laboral |
| `casos_estado` | `ReplacingMergeTree(version)` | `caso_id` | |
| `mensajes` | `MergeTree`, por mes | `(caso_id, ts, id)` | duplicados posibles: léelo por `v_mensajes` |
| `encuestas` | `MergeTree`, por mes | `(ts, id)` | `puntaje` NULL = enviada y sin responder; léelo por `v_encuestas` |
| `feedback` | `MergeTree`, por mes | `(senal, ts, id)` | léelo por `v_feedback` |
| `kpi_diario` | `AggregatingMergeTree` | `(dia, canal, categoria, grupo, prioridad, tecnico_id)` | solo lo que sale de **una fila** |

**Las golden queries leen únicamente las vistas** `v_eventos`, `v_incidencias`, `v_tiempos`, `v_casos`, `v_mensajes`, `v_feedback`
y `v_encuestas`: ya resuelven versiones (`FINAL`) y duplicados (`LIMIT 1 BY id`; las encuestas se juntan por `id` con `max`). Una
consulta sobre la tabla cruda sin `FINAL` cuenta filas viejas y duplicadas.

**La trampa de la sección 8.2.** Una vista materializada solo ve las filas **nuevas** de su tabla. `kpi_diario` se alimenta de tres
vistas materializadas y solo guarda lo que se calcula con una fila (incidencias creadas, resoluciones, reaperturas, escalamientos
y casos nuevos por día; mensajes y latencias). **FRT, MTTR y SLA salen de `incidencias_tiempos`, no de una vista.** Tampoco la
**contención del asistente**, que el plan daba por posible en una vista: `casos_estado` lleva una fila por cambio y el estado puede
retroceder (un caso resuelto por el asistente vuelve y termina con incidencia), así que la vista lo contaría como contenido para
siempre. La contención sale de `v_casos`. Todos los contadores son `uniqExact` sobre el id del hecho: reenviar un lote o cargar una
versión nueva no cuenta dos veces. No hay sumas (el costo del LLM) porque una suma cuenta dos veces un mensaje reenviado.

`kpi_diario` es un acelerador de tendencias, **no una definición de KPI**: la prueba lo reconcilia con la golden query `volumen`
y con el recuento de mensajes.

## 3. Perfil de poca memoria y usuarios

`perfil-poca-memoria.xml` → `/etc/clickhouse-server/config.d/`. `usuarios.xml` → `/etc/clickhouse-server/users.d/`.
Sin `usuarios.xml`, ClickHouse arranca con el usuario `default` sin clave: **no lo montes sin él**.

| Ajuste | Valor | Dónde |
|---|---|---|
| `max_server_memory_usage_to_ram_ratio` | 0,25 de la RAM (1,5–2 GB en un servidor de 8 GB) | perfil |
| `mark_cache_size` | 500 MB | perfil |
| `query_log`, `trace_log`, `text_log`, `metric_log` y los demás registros del sistema | eliminados | perfil |
| `max_threads` | 2 | usuarios.xml (`jsr_base`) |
| `max_block_size` | 8192 | usuarios.xml (`jsr_base`) |

Medido al probar: **no se baja `background_pool_size`**. Con 4 y con 10 ClickHouse se niega a arrancar (código 36): su valor por
`background_merges_mutations_concurrency_ratio` (2) queda por debajo de `number_of_free_entries_in_pool_to_execute_mutation` (20) o
de `..._to_execute_optimize_entire_partition` (25), así que haría falta al menos 13. Se deja el valor por defecto (16): con carga
de miles de filas por día los hilos ociosos casi no pesan.

| Usuario | Para qué | Permisos y límites |
|---|---|---|
| `jsr` | el backend: carga por lotes, aplica `esquema.sql`, reconstruye | `SELECT, INSERT, ALTER, CREATE, DROP, TRUNCATE, OPTIMIZE, SHOW, SYSTEM MERGES` sobre `jsrbot.*`; `SELECT` sobre cinco tablas de `system` para vigilar la propia base; **sin** gestión de usuarios; 800 MB y 120 s por consulta |
| `analista` | golden queries, tableros y SQL del analista | `SELECT` sobre `jsrbot.*`; `readonly=1` (ni siquiera `SET`); 400 MB, 10 s, 100 M filas leídas, 10 000 filas de resultado, 5 M filas en `GROUP BY` y `JOIN`, 4 consultas a la vez |

Las claves **no están en ningún archivo del repositorio**: `usuarios.xml` lee el hash SHA-256 de cada una de una variable de
entorno (`JSR_CH_CLAVE_SHA256`, `JSR_CH_ANALISTA_CLAVE_SHA256`; ver `.env.ejemplo`). Los dos usuarios solo aceptan conexiones
de la red interna (`127.0.0.1`, `10/8`, `172.16/12`, `192.168/16`). No publiques el puerto 8123 hacia fuera.

Ejemplo para el `docker-compose` (lo pone quien mantiene `despliegue/`; aquí solo se deja la forma):

```yaml
  jsrbot_clickhouse:
    image: ${JSR_CH_IMAGEN:-clickhouse/clickhouse-server:26.9.10.4-alpine}
    mem_limit: 2g
    environment:
      CLICKHOUSE_SKIP_USER_SETUP: "1"
      JSR_CH_CLAVE_SHA256: ${JSR_CH_CLAVE_SHA256}
      JSR_CH_ANALISTA_CLAVE_SHA256: ${JSR_CH_ANALISTA_CLAVE_SHA256}
    volumes:
      - ./analitica/perfil-poca-memoria.xml:/etc/clickhouse-server/config.d/perfil-poca-memoria.xml:ro
      - ./analitica/usuarios.xml:/etc/clickhouse-server/users.d/usuarios.xml:ro
      - ./volumenes/clickhouse:/var/lib/clickhouse
```

## 4. La semilla

`semilla/` es el conjunto fijo con el que se prueba todo: **3 meses (1-jul a 30-sep de 2026)**, un archivo JSONEachRow por tabla,
con las columnas del contrato. **624 incidencias, 1203 casos**, 25 000 filas (unos 7 MB). Se genera con
`python3 semilla/generar_semilla.py` (semilla fija `20261005`, azar propio `splitmix64`, solo enteros y aritmética básica: los
mismos bytes en cualquier máquina y versión de Python) y se commitea el resultado. Para cambiarla hay que cambiar el código y volver
a generar; `--verificar` y `SHA256SUMS` lo vigilan.

Trae **duplicados y reenvíos** a propósito (2 % de filas reenviadas pocas filas después, 3 % de versiones viejas que llegan
tarde, después de la versión nueva), porque así llega la outbox («al menos una vez»). La prueba de reconstrucción además las baraja. «Ahora» de la semilla es el 5-oct-2026 a las 00:00 de Lima: nada es posterior.

**Reglas del horario laboral** (`semilla/calendario.json`, `semilla/sla.json`; todo `SUPUESTO:`, ninguna organización los dio):

- Calendario `laboral`: lunes a viernes, **08:30 a 18:00 de Lima** (UTC-5 fijo, sin horario de verano), sin almuerzo, sin
  los feriados de la semilla (28 y 29 de julio, y 6 de agosto). Calendario `p1_24x7`: todo minuto cuenta, y lo usa la prioridad P1.
- Plazos (respuesta / resolución, en minutos del calendario de la prioridad): P1 15 / 240 · P2 60 / 480 · P3 240 / 1440 · P4 480 / 2880.
- `frt_min` = minutos entre `creada_en` y la primera respuesta. `mttr_min` = minutos entre `creada_en` y la **última**
  resolución, menos `pausa_min`; el tiempo entre una resolución y su reapertura **sí** corre. `pausa_min` = pausas
  (`espera_usuario`, `espera_tercero`) hasta el instante de la versión de la fila.
- `resuelta_en` es la última resolución vigente: es `NULL` mientras la incidencia está reabierta.
- `sla_*_ok` vale 1 si cumplió, 0 si no cumplió **o si el plazo ya venció sin cumplirse**, y `NULL` si el plazo aún no vence
  (o está en pausa). `primer_contacto` es `NULL` si nunca se resolvió o si se cerró sin confirmación; 0 si hubo escalamiento,
  reasignación o reapertura; 1 en los demás casos resueltos.
- `semilla/vectores_calendario.json` trae casos de la función de minutos laborales (y de la función inversa) para probar el
  calendario del backend en Go. `semilla/validar_semilla.py` es la especificación ejecutable de cómo se derivan estado y tiempos
  de los eventos.

**Casos difíciles** (28 incidencias, con su explicación en `semilla/casos_dificiles.json`): creada el viernes 17:55; feriados en
medio; pausa larga con fin de semana y feriado dentro; reapertura a los 2 días y a los 7 d 18 h (fuera de ventana); doble
reapertura; reabierta y todavía abierta; escalamiento doble hasta un técnico N3 que **solo tiene esa incidencia**; P1 fuera de
horario cumplida e incumplida; nunca resueltas (sin respuesta, en espera de tercero, en curso); creada el 30-jun 23:40 de Lima
(1-jul en UTC, **fuera** del periodo) y el 30-sep 23:55 (1-oct en UTC, **dentro**); cambio de día en UTC el 31-jul y el 31-ago;
cierre fuera del periodo; resuelta antes del corte y reabierta después, y al revés; pausa vigente con veredicto pendiente; alta
manual sin caso; cierre sin confirmación; escalada por SLA vencido. Además: casos resueltos solo por el asistente (y 12 que volvieron
y terminaron con incidencia), casos abandonados y tomados por un técnico, encuestas sin responder, un grupo (`Seguridad`) **sin
datos** y duplicados en todas las tablas.

## 5. Catálogo de KPI

Todas las cifras de la tabla son de `esperado.csv`: semilla completa, `desde=2026-07-01`, `hasta=2026-09-30`, `grupo=''` (todos).
Cada KPI tiene su `meta.yaml` (definición, base, bordes, preguntas equivalentes) y siete esperados.

| KPI (carpeta) | Definición resumida | Resultado sobre la semilla |
|---|---|---|
| `sla_cumplimiento` | % de incidencias creadas en el periodo que cumplieron su plazo, por separado para respuesta y resolución. Solo entran las que tienen veredicto: una abierta con el plazo vencido cuenta como incumplida | respuesta **76,57 %** (477 de 623) · resolución **83,95 %** (518 de 617) |
| `frt` | Mediana y p90 de creación → primera respuesta humana, en minutos del calendario de la prioridad. Excluye las que aún no tienen respuesta | 612 evaluadas · mediana **62** min · p90 **399,8** min |
| `mttr` | Mediana y media de creación → última resolución, sin pausas. Excluye abiertas y reabiertas | 591 evaluadas · mediana **549** min · media **833,65** min |
| `fcr` | % de resueltas por el primer técnico, sin escalamiento, reasignación ni reapertura. Excluye nunca resueltas y cerradas sin confirmación | 497 evaluadas · **79,48 %** |
| `contencion_asistente` | % de casos concluidos que resolvió el asistente, confirmó la persona y no abrieron incidencia. Los abiertos se informan aparte | 1186 concluidos · 492 contenidos · **41,48 %** · 16 abiertos |
| `tasa_escalamiento` | % de incidencias con al menos un escalamiento funcional, por grupo de origen | 623 incidencias · 69 escaladas · **11,08 %** |
| `reaperturas` | % de incidencias resueltas con una reapertura dentro de los 7 días de una resolución (límite inclusivo) | 592 resueltas · 39 · **6,59 %** |
| `pendientes_antiguedad` | Abiertas al cierre del periodo (reconstruidas desde los eventos) por antigüedad desde la creación | `< 1 d` 9 · `1-3 d` 9 · `3-7 d` 4 · `> 7 d` 24 |
| `csat` | Media (1–5), % de 4–5 y tasa de respuesta de las encuestas enviadas en el periodo | 757 enviadas · 452 respondidas (**59,71 %**) · media **3,88** · 4–5 **70,58 %** |
| `volumen` | Casos e incidencias en total y por canal, categoría, sede, hora y día (de Lima) | 1202 casos · 623 incidencias (390 WhatsApp, 196 web, 37 consola) |
| `productividad_tecnico` | Por técnico: resueltas, mediana de FRT y de MTTR de esas resueltas, CSAT. **Sin ranking**: se ordena por id | 10 técnicos; el 10 tiene **1** resuelta (FRT 25, MTTR 218,6) |
| `calidad_asistente` | Exactitud del clasificador frente a correcciones (estimación), % de respuestas con frases quitadas, % regeneradas y costo del LLM por 1000 casos | **98,85 %** de exactitud · 7,15 % con frases quitadas · 3,38 % regeneradas · 1,19 USD por 1000 casos |

**Atribución al grupo** (parámetro `grupo`, el **nombre** del grupo: `Mesa N1`, `Redes`…; `''` = todos): los KPI de proceso
(SLA, FRT, MTTR, FCR, escalamiento, reaperturas, volumen, CSAT) usan el **grupo de origen**, el de la fila `creada`; si no, la
Mesa N1 nunca tendría escalamientos. `pendientes_antiguedad` usa el grupo que tenía la incidencia **en el corte**.
`productividad_tecnico` usa el grupo actual de la incidencia (el del técnico). `contencion_asistente` y `calidad_asistente`
**no tienen grupo** y lo ignoran. Cada `meta.yaml` lo declara en `atribucion_grupo`.

**Bases distintas, a propósito** (cada `meta.yaml` lo dice en `base`): los KPI de proceso miran la **cohorte de las incidencias
creadas en el periodo**; `contencion_asistente`, los casos iniciados; `csat`, las encuestas enviadas; `productividad_tecnico`, las
resueltas en el periodo; `pendientes_antiguedad`, una foto al fin del último día; `calidad_asistente`, los mensajes y el feedback
con fecha en el periodo.

**Dónde me aparté de `ARQUITECTURA.md` §8.3 y por qué** (el Arquitecto debe confirmarlo): el cumplimiento de SLA mira incidencias
**creadas** en el periodo y no «cerradas en el periodo». Con la base «cerradas», una incidencia abierta y vencida nunca entra
(sesgo de supervivencia: el KPI mejora justo cuando la mesa se atrasa) y el dato llega con dos días de retraso por el cierre de
48 h laborales.

## 6. Cómo ejecuta el backend una golden query

El backend no calcula nada: lee `catalogo.json`, manda el SQL y devuelve las filas.

```
POST {JSR_CH_URL}/?default_format=JSON&wait_end_of_query=1&param_desde=2026-07-01&param_hasta=2026-09-30&param_grupo=
Authorization: Basic base64(analista:<JSR_CH_ANALISTA_CLAVE>)
<cuerpo: el contenido de golden/<kpi>/v<N>.sql, tal cual>
```

| Parámetro | Tipo en el SQL | Valor |
|---|---|---|
| `param_desde` | `{desde:Date}` | `aaaa-mm-dd`, **día de Lima**, inclusivo |
| `param_hasta` | `{hasta:Date}` | `aaaa-mm-dd`, **día de Lima**, inclusivo |
| `param_grupo` | `{grupo:String}` | nombre del grupo; vacío = todos |

- Se pueden mandar los tres siempre: ClickHouse ignora el que la consulta no usa. `catalogo.json` dice cuáles usa cada KPI
  (`parametros`) para que el tablero deshabilite el filtro que no aplica.
- **`wait_end_of_query=1` es obligatorio.** Sin él, un límite excedido a media respuesta llega como HTTP 200 con el cuerpo cortado
  y el error escrito al final (se midió). Con él, ClickHouse devuelve un 500 de verdad. No es un ajuste de perfil, es un parámetro
  de la URL.
- El usuario `analista` está en `readonly=1`: **no se pueden mandar otros ajustes por la URL** (devuelve `READONLY`). Los que hacen
  falta ya están en su perfil, entre ellos `output_format_json_quote_64bit_integers=0` (enteros sin comillas en el JSON).

La respuesta de ClickHouse (`format=JSON`) trae `meta` (columnas y tipos, en orden), `data` (las filas) y estadísticas. El backend
devuelve a la API de indicadores, por cada KPI:

```json
{
  "kpi": "sla_cumplimiento",
  "version": 1,
  "definicion": "Porcentaje de incidencias que cumplieron su plazo de SLA…",
  "unidad": "%",
  "filas": [
    {"metrica": "respuesta",  "evaluadas": 623, "cumplidas": 477, "porcentaje": 76.57},
    {"metrica": "resolucion", "evaluadas": 617, "cumplidas": 518, "porcentaje": 83.95}
  ]
}
```

`version`, `definicion` y `unidad` salen del catálogo, `filas` es el `data` de ClickHouse. **`NULL` llega como `null`** (nunca 0:
un denominador cero es «sin dato»). Un grupo sin datos devuelve `filas` con ceros y `null`, o `[]` en `productividad_tecnico`;
no es un error. Para comparar periodos con versiones distintas se puede pedir una versión vieja: `golden/<kpi>/v<N>.sql`.

Una pregunta del analista como «¿cuál fue el MTTR de impresoras en septiembre?» **no tiene golden query**: las golden queries solo
filtran por grupo, no por categoría. El analista lo dice, propone un SQL marcado «Sin verificar» y deja la petición de una golden
query nueva.

## 7. Crear una golden query nueva o una versión 2

Procedimiento completo, con sus trampas, en [`.agents/skills/jsr-golden-query/SKILL.md`](../.agents/skills/jsr-golden-query/SKILL.md).
En corto:

1. **KPI nuevo**: `golden/<kpi>/meta.yaml` + `v1.sql` (parámetros `{desde:Date}`, `{hasta:Date}`, `{grupo:String}`; lee solo
   las vistas `v_*`; denominador cero → `NULL`; `ORDER BY` siempre) + su función en `herramientas/calculo_independiente.py`,
   escrita sin mirar el SQL. Después `./probar_golden.sh --generar-esperados`, que **se niega a escribir** un esperado donde SQL y
   Python difieren. Revisa los esperados a mano, añade mutantes y corre `generar_catalogo.py`.
2. **Versión 2**: nunca se edita `v1.sql`. Se congelan sus esperados en `golden/<kpi>/historicas/v1/` (la prueba sigue
   ejecutando `v1.sql` contra ellos), se copia a `v2.sql`, se cambia, se sube `version: 2` en `meta.yaml` y se regeneran los
   esperados. El tablero muestra qué versión usa.
3. **Nunca** se copia el resultado de ClickHouse como verdad. Si SQL y Python difieren, se investiga quién tiene razón.

## 8. Reconstrucción

`reconstruir.md` es el procedimiento (vaciar con `DROP DATABASE`, aplicar `esquema.sql`, reenviar la outbox, verificar). La
verificación contra la semilla es `./probar_reconstruccion.sh` y compara con `semilla/checksums_clickhouse.txt`.

## 9. Límites conocidos

- **Todo lo que dice `SUPUESTO:` lo es**: horario, feriados, plazos de SLA, objetivos de los KPI, sedes y áreas de la semilla.
  Cuando la organización los dé, cambian `semilla/` y `meta.yaml`, no el SQL.
- La **exactitud del clasificador** es una estimación (supone correcto lo que nadie corrigió). La medida real es la evaluación de
  `agente/` sobre el conjunto reservado.
- `reaperturas` subestima en los últimos 7 días de datos (todavía no tuvieron tiempo de reabrirse).
- `kpi_diario` no tiene suma de costos ni FRT/MTTR/SLA/contención: es a propósito (sección 2).
- La semilla son 25 000 filas: la prueba no mide rendimiento con millones.
