---
name: jsr-golden-query
description: Añadir o cambiar una golden query (la definición oficial de un KPI) de jsrbot - escribir el SQL de ClickHouse, documentar la definición, fijar el resultado esperado sobre la semilla, verificarlo con un cálculo independiente en Python y registrar la versión. Úsala al crear o cambiar un KPI o un reporte, o cuando un tablero, un reporte o el analista necesitan una cifra que aún no tiene golden query.
metadata:
  argument-hint: "[kpi]"
---

Una golden query es la **definición oficial de un KPI**: la pregunta en palabras, el SQL verificado y el resultado esperado
sobre un conjunto de datos fijo. Regla 7 de `AGENTS.md`: un KPI, una golden query. Ningún tablero, reporte ni respuesta del
analista calcula un KPI con SQL propio. Si la definición cambia, cambia la golden query, con **nueva versión**.

Los estudios sobre BIRD y Spider encontraron errores en sus propias consultas «de oro». Por eso aquí un esperado nunca se
acepta solo porque ClickHouse lo devuelva: también tiene que coincidir con un cálculo independiente en Python.

## Cuándo

- Hay que crear un KPI nuevo, o cambiar la definición de uno existente (bordes, base, atribución al grupo, redondeo).
- Un tablero, un reporte programado, una exportación o el analista necesitan una cifra que no está en `analitica/catalogo.json`.
- Una versión vieja de un KPI hay que conservarla para comparar periodos.

No la uses para explorar datos: el SQL exploratorio del analista se marca «Sin verificar» y no pasa por aquí.

## Antes de empezar (qué leer, qué comprobar)

1. `analitica/LEEME.md` (catálogo, reglas de lectura, ejecución desde el backend) y `ARQUITECTURA.md` §8.2 y §8.3.
2. `docs/CONTRATOS.md` §4: las columnas de las tablas. No inventes columnas.
3. Decide **antes de escribir SQL**, y anótalo en `meta.yaml`:
   - **la base**: ¿qué filas entran? (incidencias creadas en el periodo, casos iniciados, encuestas enviadas, foto al cierre…);
   - **el denominador**: ¿qué pasa si es cero? (siempre `NULL`, nunca `0`);
   - **abiertas, reabiertas y cerradas fuera del periodo**: ¿entran, salen, cuentan como incumplidas?;
   - **el grupo**: ¿de origen (con el que nació), vigente al corte o del técnico? Un KPI de escalamiento por grupo vigente
     da siempre 0 en la Mesa N1 porque las escaladas ya cambiaron de grupo;
   - **la hora**: día y hora siempre en `America/Lima`; el UTC de la base nunca se muestra.
4. ¿Se puede calcular con UNA fila? Solo entonces cabe en una vista materializada de `kpi_diario`. Si necesita dos eventos
   (tiempo entre uno y otro) o el estado puede retroceder, sale de `incidencias_tiempos` o de las vistas `v_*` en la consulta.

## Pasos

**Crear un KPI nuevo** (`analitica/golden/<kpi>/`):

1. Crea `meta.yaml` (copia uno existente): `kpi` (igual al nombre de la carpeta), `nombre`, `version: 1`, `unidad`, `dueno`,
   `definicion`, `base`, `parametros` (los que el SQL usa: `desde`, `hasta`, `grupo`), `atribucion_grupo`, `columnas`,
   `bordes`, `objetivo` (opcional, marcado `SUPUESTO:` si no lo dio la organización), **al menos 4**
   `preguntas_equivalentes` en español (cómo lo preguntaría una persona distinta cada vez) y `pruebas` (los escenarios).
2. Escribe `v1.sql` con parámetros nativos `{desde:Date}`, `{hasta:Date}`, `{grupo:String}` (`''` = todos).
   Lee SOLO las vistas `jsrbot.v_*`, nunca las tablas crudas: las vistas ya resuelven duplicados y versiones.
   Cada columna lleva un nombre claro; ordena siempre (`ORDER BY`); redondea a 2 decimales; denominador cero → `NULL`.
3. Añade la función del KPI a `analitica/herramientas/calculo_independiente.py` (`KPIS`), escrita **sin mirar el SQL**: con
   bucles y diccionarios sobre los `.jsonl`, desde la definición de `meta.yaml`. Devuelve las mismas columnas y filas.
4. Escenarios mínimos en `pruebas` (los 7 del resto de KPI): periodo completo (`esperado.csv`), un mes, un grupo con un mes,
   dos días a caballo de un cambio de mes, **un grupo sin datos** (`Seguridad`), un periodo posterior (octubre) y un periodo
   vacío. Cubren borde de zona horaria, denominador cero y filtro de grupo.
5. Genera los esperados **solo si SQL y Python coinciden**:

   ```bash
   cd analitica && ./probar_golden.sh --generar-esperados
   ```

   Si hay una `DISCREPANCIA SQL vs Python`, **investiga quién tiene razón** antes de tocar nada: casi siempre es una
   decisión de definición no escrita (¿entra la abierta?, ¿grupo de origen o vigente?). Corrige la que esté mal y deja la
   definición escrita en `meta.yaml`. Nunca copies el resultado de ClickHouse como verdad.
6. Revisa a mano los `esperado*.csv`: ¿las cifras tienen sentido?, ¿los casos difíciles de la semilla
   (`semilla/casos_dificiles.json`) caen donde dice la definición?
7. Añade **mutantes** a `MUTANTES` en `herramientas/ejecutar_pruebas.py`: dos o tres errores típicos de ese KPI (día en UTC,
   leer la tabla sin FINAL, grupo equivocado, ventana distinta). Si un mutante sobrevive, faltan escenarios.
8. Regenera el catálogo: `python3 analitica/herramientas/generar_catalogo.py` (lo valida: campos, preguntas, parámetros).

**Cambiar una definición existente (versión nueva, nunca editar la vieja)**:

1. Congela lo que existe: `mkdir -p golden/<kpi>/historicas/v1 && cp golden/<kpi>/esperado*.csv golden/<kpi>/historicas/v1/`.
   `v1.sql` se queda donde está; la prueba lo sigue ejecutando contra esos esperados congelados (grupo «historicas»).
2. Copia `v1.sql` a `v2.sql`, cambia el SQL, sube `version: 2` en `meta.yaml` y actualiza `definicion`, `base` y `bordes`.
3. Actualiza el cálculo independiente de Python a la definición nueva, regenera con `--generar-esperados` y revisa el diff de
   los `esperado*.csv`: cada cifra que cambió debe tener explicación.
4. `generar_catalogo.py`. Avisa al backend y a quien use el KPI: el tablero muestra qué versión usa; las comparaciones entre
   periodos con versiones distintas se marcan.

## Cómo verificar

```bash
cd analitica && ./probar_golden.sh      # termina con «GOLDEN QUERIES EN VERDE» y código 0
```

Debe haber en verde: el SQL contra cada esperado; el cálculo independiente en Python contra cada esperado; las pruebas
negativas y los mutantes; el usuario `analista`; y las golden queries otra vez tras `OPTIMIZE FINAL`. Si tocaste el esquema
o la semilla, corre también `./probar_reconstruccion.sh` (y `--actualizar` solo si el cambio fue a propósito).

## Trampas conocidas

- **ClickHouse deduplica dentro de un INSERT** (`optimize_on_insert`): si cargas toda la semilla de una vez, los duplicados
  desaparecen y una consulta sin `FINAL` pasa la prueba. La prueba carga en lotes de 100 filas con las fusiones detenidas.
- **`FINAL` o `argMax` siempre** en tablas con versión (`incidencias_estado`, `incidencias_tiempos`, `casos_estado`). Las
  vistas `v_*` ya lo hacen. Los mensajes y el feedback se dedupican por id (`LIMIT 1 BY id`); las encuestas, por id con `max`.
- **Vista materializada = solo filas nuevas.** Una vista que mide FRT, MTTR o contención se equivoca en silencio.
- **Día y hora de Lima.** Una incidencia creada el 30-jun a las 23:40 de Lima es del 1-jul en UTC y NO es de julio.
- **El corte de «pendientes» se reconstruye con eventos**, no con el estado de hoy: una incidencia resuelta después del corte
  era pendiente en el corte.
- **`cityHash64(*)` devuelve NULL si una columna es NULL** y `sum()` se salta la fila: el checksum de la reconstrucción hashea
  la tupla (`cityHash64(tuple(*))`).
- **`quantile` aproxima**: usa `quantileExactInclusive` (interpolación lineal, igual que `PERCENTILE.INC`).
- **Sin ranking público** de técnicos: `productividad_tecnico` se ordena por id, nunca por desempeño.
- **Un grupo no existe en ClickHouse**: no hay tabla de grupos. Un grupo sin incidencias devuelve ceros o `NULL`, no un error.
- **Tolerancia numérica 0,006** (`comparar_csv.py`): medio centésimo por el redondeo a 2 decimales. Enteros y textos, exactos.
