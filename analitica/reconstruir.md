# Reconstruir ClickHouse desde Postgres

ClickHouse **no es fuente de verdad** (`AGENTS.md` §1.4 regla 8): se puede borrar y volver a cargar desde Postgres, y las
cifras tienen que salir idénticas. Este documento es el procedimiento y la forma de comprobarlo. La parte de Go (el
trabajador que lee `outbox_analitica`) la prueba el backend; la parte de ClickHouse, ya probada, es `./probar_reconstruccion.sh`.

## Cuándo se reconstruye

- Cambió el esquema de una tabla (`esquema.sql`) de forma que no se arregla con `ALTER`.
- Se cambió la definición de una vista o el tipo de una columna.
- Se perdió el volumen de ClickHouse o se sospecha que está corrupto.
- Se cambió de servidor. ClickHouse **no se respalda**: se reconstruye (`PLAN_TRABAJO.md` F9).

## Qué hace posible la reconstrucción

| Pieza | Garantía |
|---|---|
| `outbox_analitica` | Una fila por cambio, con `clave` estable (`ev-<id>`, `inc-<id>-<version>`…). Ver `CONTRATOS.md` §4. |
| Tablas con versión | `incidencias_estado`, `incidencias_tiempos`, `casos_estado` son `ReplacingMergeTree(version)`: gana la mayor versión, llegue en el orden que llegue. |
| `eventos_incidencia` | `ReplacingMergeTree(id)`: un evento reenviado se funde con el original. |
| `mensajes`, `feedback`, `encuestas` | Pueden traer duplicados; las vistas `v_mensajes`, `v_feedback` y `v_encuestas` los resuelven por `id`. |
| `kpi_diario` | Solo contadores `uniqExact` sobre el id del hecho: recargar o reenviar no los infla. |
| Golden queries | Leen únicamente las vistas `v_*` (con `FINAL`/`LIMIT 1 BY`): dan lo mismo antes y después de las fusiones. |

## Requisitos del trabajador de la outbox (backend)

Para que la reconstrucción sea correcta, el trabajador tiene que:

1. Mandar con `INSERT INTO jsrbot.<tabla> FORMAT JSONEachRow` y `date_time_input_format=best_effort`, con las claves del
   payload **exactamente** como las columnas (las define `esquema.sql`).
2. Mandar `wait_end_of_query=1` en cada petición. Sin él, un error a media respuesta llega como HTTP 200 con el cuerpo cortado
   y el lote se marcaría como enviado sin estarlo.
3. Marcar `enviado_en` **solo tras un 200** de ClickHouse. Un reintento reenvía el **mismo lote** (mismas filas, mismo orden):
   así `non_replicated_deduplication_window` lo descarta entero. Si no, los duplicados los absorben las vistas.
4. Leer la outbox **por `id` ascendente**, en lotes (5000 filas es razonable), y avanzar solo cuando el lote entró.
5. Conservar la outbox mientras haga falta reconstruir. **Si la outbox se purga, hay que poder re-emitir desde las tablas de
   verdad** (`incidencia_eventos`, `incidencias`, `casos`, `mensajes`, `encuestas`, `feedback`, más el cálculo de
   `incidencias_tiempos`). Sin una de las dos cosas, ClickHouse no se puede reconstruir. Ver «Cambios que pido».

## Procedimiento

Usuario `jsr` (escritura) para todo. Nada de esto imprime claves; van por variable de entorno (`.env.ejemplo`).

1. **Pausar el trabajador** de la outbox (o parar el servicio del backend que lo corre).
2. **Guardar la huella de antes** (solo si ClickHouse está sano): ejecuta
   `SELECT count(), sum(cityHash64(tuple(*))) FROM jsrbot.<vista>` para cada vista de la tabla de abajo y guarda el resultado
   de las 12 golden queries del último mes cerrado (`GET /api/indicadores?desde&hasta` o las golden queries a mano).
   Se hashea la **tupla** y no `cityHash64(*)`: este devuelve `NULL` si una columna es `NULL` y `sum()` se saltaría la fila.
3. **Vaciar.** `DROP DATABASE jsrbot;` — no `TRUNCATE`: así se van también `kpi_diario` y sus vistas materializadas.
4. **Aplicar el esquema.** `esquema.sql` sentencia por sentencia (es idempotente: `IF NOT EXISTS`, nombres completos, sin
   `USE`). Cuesta menos de un segundo.
5. **Marcar la outbox como no enviada**, en Postgres: `UPDATE outbox_analitica SET enviado_en = NULL;`
   (por lotes si es muy grande).
6. **Reanudar el trabajador.** Carga a su ritmo; ClickHouse deduplica y las vistas materializadas se llenan mientras entra.
   Referencia medida con ClickHouse efímero: la semilla (25 000 filas) entra en 0,7 s con lotes de 5000 filas, en 3,5 s con lotes de
   500 y en 40 s con lotes de 40 (625 `INSERT`, el peor caso).
7. **Esperar** a que `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL` llegue a 0 y siga en 0.
8. **Verificar** (abajo). Si todo cuadra, la reconstrucción terminó. Opcional: `OPTIMIZE TABLE jsrbot.<tabla> FINAL` para
   fundir partes y ahorrar disco; no cambia ningún resultado.

## Verificación

**A. Recuento contra Postgres.** Cada vista de ClickHouse tiene un equivalente exacto en Postgres:

| Vista de ClickHouse | Postgres | Comparar |
|---|---|---|
| `v_eventos` | `incidencia_eventos` | `count(*)` y `sum(id)` |
| `v_incidencias` | `incidencias` | `count(*)` y `sum(id)` (contra `incidencia_id`) |
| `v_tiempos` | `incidencias` | `count(*)` (una fila vigente por incidencia) |
| `v_casos` | `casos` | `count(*)` y `sum(id)` (contra `caso_id`) |
| `v_mensajes` | `mensajes` | `count(*)` y `sum(id)` |
| `v_encuestas` | `encuestas` | `count(*)` y `sum(id)` |
| `v_feedback` | `feedback` | `count(*)` y `sum(id)` |

**B. Huella contra la de antes.** Repite la consulta del paso 2: filas y suma de hashes deben ser **idénticas**. Para
`v_kpi_diario` se excluye `latencia_asistente_ms` (percentiles aproximados por naturaleza).

**C. Las golden queries.** Repite las 12 con los mismos parámetros que en el paso 2: cada resultado, **idéntico**
(número a número: ClickHouse da lo mismo cuando los datos vigentes son los mismos).

Criterio: A, B y C iguales. Una diferencia en A o B significa que faltan o sobran filas; una diferencia solo en C con A y B
iguales significa que cambió una definición (nueva versión de una golden query) y no es un fallo de la reconstrucción.

## La prueba automática

```bash
cd analitica && ./probar_reconstruccion.sh            # levanta ClickHouse, carga la semilla, vacía, recarga, compara
cd analitica && ./probar_reconstruccion.sh --actualizar   # solo si la semilla o el esquema cambiaron A PROPOSITO
```

Qué hace, con ClickHouse efímero y la semilla:

1. Carga A: orden original, lotes de 100 filas. Guarda la huella de las 8 vistas vigentes y el SHA-256 de 84 resultados de
   golden query (12 KPI por 7 escenarios).
2. `DROP DATABASE jsrbot` y comprueba que no queda ninguna tabla.
3. Carga B: tablas en **otro orden**, filas **barajadas**, lotes de **97** filas y reenvío del **30 %** de la cola de cada
   lote (la outbox es «al menos una vez»). Recompara las huellas y los resultados: idénticos.
4. `OPTIMIZE ... FINAL` y vuelve a comparar: idénticos.
5. Control negativo: una fila de más y una versión nueva **sí** cambian la huella (si no, comparar huellas no probaría nada).
6. Compara contra `semilla/checksums_clickhouse.txt` (versionado): detecta un cambio no intencionado en la semilla o en el
   esquema.

Última ejecución (ClickHouse 26.9.10.4): 30 comprobaciones, 30 OK. Con 7337 filas reenviadas, las 8 vistas y las 84 golden
queries dieron exactamente lo mismo.

## Lo que esta prueba NO cubre

- La lectura de `outbox_analitica` y la idempotencia del trabajador en Go (`internal/analitica`): la prueba el backend.
- El volumen real: la semilla son 25 000 filas. Con millones, el paso 6 tarda minutos y conviene lotes más grandes.
- La coherencia de `incidencias_tiempos` frente al calendario real de Postgres: ver `semilla/validar_semilla.py`, que es la
  especificación ejecutable de cómo se derivan esos tiempos de los eventos, y `semilla/vectores_calendario.json`, con casos para
  probar la función de minutos laborales en Go.
