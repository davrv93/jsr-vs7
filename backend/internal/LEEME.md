# backend/internal · motor de jsrbot (Go)

Dominio del gestor de incidencias: ciclo de vida, SLA en horario laboral, despachador, vigía de escalamiento,
outbox hacia ClickHouse, golden queries, semilla sintética y la API HTTP **interna** que consume la pasarela OCaml
(`docs/CONTRATOS.md` §5). Fuente de verdad: Postgres. Todo en español; los supuestos llevan `SUPUESTO:`.

```
internal/
  sla/         PURO. Prioridad (matriz), calendario (zona, tramos, feriados, 24x7), reloj de SLA con pausas
  store/       pool pgx, migraciones embebidas, EnTx, configuración por defecto, lectores de SLA, avisos
  despacho/    despachador: núcleo puro (Decidir) + capa de base (Elegir)
  incidencia/  máquina de estados, Servicio (Crear y las acciones), consultas, cierre automático, cola
  escala/      reglas versionadas + vigía (Vigilar/Ciclo/Correr) + Reproducir (histórico, sombra)
  analitica/   outbox: Encolar, payloads del contrato §4, Trabajador → ClickHouse, Reconstruir
  golden/      ejecuta las golden queries de analitica/ con el usuario de solo lectura
  motor/       servidor HTTP /interno/* + trabajos de fondo
  semilla/     datos sintéticos deterministas (la usa cmd/semilla)
cmd/motor      el servidor (imagen Docker)        cmd/semilla  carga de datos sintéticos
migrations/    001 esquema · 002 avisos · 003 encuestas.puntaje NULL · 004 eventos inmutables (embebidas)
```

## 1. Pruebas

```bash
cd backend && go vet ./... && ./scripts/test-db.sh            # todo: ~2 min
./scripts/test-db.sh -count=1 -run Vigia ./internal/escala/... # un subconjunto (acepta argumentos de go test)
```

`scripts/test-db.sh` levanta un `postgres:16-alpine` efímero en un puerto libre, exporta `JSR_TEST_DB`, corre
`go test` y lo apaga al terminar. Si la imagen de ClickHouse está en local y existe `analitica/usuarios.xml`, levanta
también un ClickHouse efímero (perfil de poca memoria, usuarios `jsr` y `analista` de `analitica/`) y exporta
`JSR_TEST_CH_*`; `JSR_TEST_CH=0` lo desactiva. **Las pruebas con base se saltan (`t.Skip`) si `JSR_TEST_DB` no está
definida; la de ClickHouse, si falta `JSR_TEST_CH_URL`.** Cada prueba con base crea su propia base (`storetest`), así
que no se pisan.

Qué cubre: reloj de SLA (viernes 17:55, feriados, fin de semana, dos pausas, P1 24×7, cambio de horario, cruce de
medianoche UTC/Lima, propiedad inversa con 600 casos al azar), despachador (empate, fuera de turno, ausente, sin
candidatos, capacidad llena, guardia P1, concurrencia), matriz estado×acción completa (válidas e inválidas, sin
dejar rastro), ciclo de vida, vigía (idempotencia, dos vigías a la vez, sombra vs activo, versiones, reproducción =
vigía en vivo), outbox con `httptest` (fallos, reintento sin perder ni duplicar, trabajadores en paralelo),
reconstrucción, las rutas `/interno` (clave incorrecta → 401), la semilla (carga, dos corridas con la misma huella,
casos difíciles) y **el outbox de la semilla cargado en un ClickHouse real**: volumen, SLA y MTTR salen iguales que
una cuenta independiente sobre Postgres y las 12 golden queries dan lo mismo tras borrar ClickHouse y reconstruir.

## 2. `sla` (puro, sin base ni reloj del sistema)

| Función / tipo | Qué hace |
|---|---|
| `NuevoCalendario(nombre, zona, v247, horarioJSON) (*Calendario, error)`, `(*Calendario).AgregarFeriado("AAAA-MM-DD", nombre)` | calendario de la tabla `calendarios`; zona IANA (`America/Lima`); `Horario` `{"1":[["08:30","13:00"],…]}` |
| `(*Calendario).EsLaboral(t)`, `EsFeriado(t)`, `Laboral(desde,hasta) time.Duration`, `ProximoLaboral(t)` | consultas de calendario |
| `MinutosLaborales(cal, desde, hasta) float64` | minutos laborales entre dos instantes (cero si hasta ≤ desde) |
| `MinutosNetos(cal, desde, hasta, pausas)` / `DuracionNeta` | idem descontando pausas |
| `FechaVencimiento(cal, desde, minutos, pausas) (time.Time, error)` / `FechaVencimientoDur` | instante en que se cumplen N minutos laborales netos; si termina justo al cierre de un tramo devuelve ese cierre; `ErrSinHorario` si el calendario no alcanza o la pausa nunca termina |
| `EstadoSLA(cal, desde, corte, limiteMin, pausas) Estado` | `{LimiteMin, TranscurridoMin, RestanteMin, Porcentaje, Vencida}` (vencida = se pasó; cumplir justo en el límite no vence) |
| `PausasDeEventos([]MarcaReloj) []Intervalo` | pausas desde los eventos: `pausa_inicio…pausa_fin` y también `resuelta…reabierta` (mientras está resuelta no corre el reloj); las no cerradas quedan abiertas (`Hasta` en cero) |
| `Evaluar(Entrada) Resultado` | todo junto: estados de respuesta y resolución, vencimientos, `FRTMin`, `MTTRMin`, `PausaMin`, `RespuestaOK`, `ResolucionOK` (`nil` = aún no aplica) |
| `Matriz`, `MatrizPorDefecto()`, `(Matriz).Prioridad(impacto, urgencia)`, `AplicarMinimo(p, "P2")` | prioridad por matriz y mínimo VIP (nunca baja una prioridad) |

Todo se calcula desde los eventos (nunca un contador). La base de zonas horarias va dentro del binario (`time/tzdata`).

## 3. `store`

`Abrir(ctx, dsn) (*DB, error)` · `(*DB).Migrar(ctx)` (aplica `migrations/*.sql` en orden, `schema_migrations`, advisory
lock) · `(*DB).EnTx(ctx, func(pgx.Tx) error)` (reintenta deadlock y fallo de serialización hasta 3 veces) · `Q` (lo que
comparten pool y transacción) · `SembrarConfiguracion(ctx, db)` (idempotente, **no pisa lo que un administrador editó**:
claves de configuración, calendarios `laboral_lima` y `24x7`, 16 feriados de Perú 2026, matriz, 4 grupos, 10
categorías, políticas P1–P4 y 9 reglas de escalamiento en **sombra**) · `CacheSLA` (calendarios, políticas, matriz;
TTL 30 s) · `EncolarAviso`, `AvisosPendientes`, `MarcarAvisoEnviado/Error` · `LeerConfig/GuardarConfig/ConfigTexto/
ConfigEntero/ConfigBool` · `MarcasReloj`. Claves de configuración: `calendario_base`, `vip_prioridad_minima`,
`pausa_espera_tercero`, `cierre_automatico_horas`, `peso_carga`, `supervisor_tecnico_id`, `semilla_sintetica`.

SUPUESTO (todo configurable desde Ajustes, ver `CONTEXT.md` §7): horario lun–vie 08:30–13:00/14:00–18:00 Lima; plazos
P1 15/240 min (24×7), P2 30/480, P3 120/1440, P4 240/2880 (laborales); grupos Mesa N1 → Infraestructura,
Redes → Infraestructura, Aplicaciones → Infraestructura; feriados nacionales sin los «días no laborables» decretados.

## 4. `despacho`

Núcleo puro: `Decidir(Peticion{Prioridad, FueraDeHorario}, miembros, guardias []Candidato) Decision`. Elegibles = grupo
de la categoría, activo, sin ausencia, con la habilidad, **en turno**, con capacidad (`Abiertas < Capacidad`); gana la
menor carga ponderada (P1=4, P2=2, P3/P4=1), empate → quien lleva más tiempo sin recibir (`ultima_asignacion`; nunca
= el más antiguo), empate → menor id. **P1 fuera de horario → la guardia vigente** (aunque esté fuera de turno o sin
capacidad); P1 en horario sin elegibles también cae en la guardia. Nadie → **cola del grupo**
(`TecnicoID nil`, `Cola`, `AvisarResponsable`). `Decision` lleva `Motivo` (código estable), `Explicacion` y
`Evaluados` (por qué se descartó cada técnico).

Capa de base: `Elegir(ctx, q, Entrada{GrupoID, CategoriaID, Prioridad, Ahora, Zona, FueraDeHorario}) (Decision, error)`
**bloquea con `FOR UPDATE` (en orden de id) a los candidatos**: llamarla dentro de la transacción que registra la
asignación. No escribe. `RegistrarAsignacion` actualiza `tecnicos.ultima_asignacion`. `EnTurno(turnos, zona, t)`
contempla turnos que cruzan la medianoche.

## 5. `incidencia`: API exportada y lo que deja cada operación

Estados `nueva asignada en_curso espera_usuario espera_tercero resuelta cerrada reabierta`. `Transicion(desde, acción)
(Estado, error)` es pura; las inválidas devuelven `*ErrTransicion` (`errors.Is(err, ErrTransicionInvalida)`), no tocan
nada y **no dejan eventos ni filas de outbox**. `Permitidas(estado)` lista las acciones válidas.

`Nuevo(db, ConReloj(f), ConCache(c)) *Servicio`. Dos formas de uso:

* `svc.Crear(ctx, entrada)` … **abre una transacción por llamada**.
* `svc.EnTx(ctx, func(o *Operaciones) error)` o `svc.Sobre(tx)` / `svc.SobreEn(tx, ahora)` → mismas operaciones
  (`o.Crear`, `o.Asignar`, …) **dentro de tu transacción** (p. ej. la del caso: la incidencia, el caso y su outbox
  en un solo COMMIT). Todas las operaciones de una `Operaciones` comparten instante (µs) y transacción.

Cada acción: bloquea la fila (`FOR UPDATE`), valida la transición, inserta eventos, actualiza la proyección
(`incidencias`), recalcula `vence_*_en` desde los eventos y deja en `outbox_analitica`: una fila `eventos_incidencia`
por evento, una `incidencias_estado` y una `incidencias_tiempos`, **en la misma transacción**.

| Operación (`Servicio` y `Operaciones`) | Entrada → resultado | Eventos que deja (además de `estado_cambiado` si cambia el estado) |
|---|---|---|
| `Crear` | `EntradaCrear{PersonaID, CasoID, Tipo, Categoria (clave), Impacto, Urgencia, Titulo, Resumen, Canal, Actor, Motivo, Queja}` → `*Resultado{Incidencia, Despacho}` | `creada` (con `prioridad_base`, `vip`, `vip_minimo_aplicado`, `motivo`); `queja` si `Queja`; `asignada` o `en_cola`. Prioridad por matriz; VIP mínimo P2. Aviso `incidencia_asignada` al técnico, o `incidencia_sin_asignar` al responsable del grupo. Fila en `decisiones` (despacho) |
| `Asignar` | `{TecnicoID, Motivo, Actor}` → `*Incidencia` | `asignada` / `reasignada`; aviso `incidencia_asignada`. nueva→asignada; en los demás estados abiertos el estado no cambia. No exige turno ni capacidad (decisión humana) |
| `Responder` | `{Texto, Actor (técnico), EsperaUsuario}` | primera vez `primera_respuesta` (fija `primera_respuesta_en`), luego `comentario`; asignada/reabierta → en_curso; con `EsperaUsuario` además `pausa_inicio` |
| `Pausar` | `{Motivo: espera_usuario\|espera_tercero, Nota, Actor}` | `pausa_inicio` (espera_tercero solo si `pausa_espera_tercero`, por defecto sí) |
| `Reanudar` | `{Actor}` | `pausa_fin` (si había pausa abierta) |
| `Resolver` | `{Solucion, Actor}` en_curso→resuelta | `resuelta` (fija `resuelta_en`) |
| `Reabrir` | `{Motivo, Actor}` resuelta→reabierta | `reabierta` (`reaperturas++`, borra `resuelta_en`) |
| `Cerrar` | `{Motivo: confirmado\|sin_confirmacion, Actor}` resuelta→cerrada | `cerrada`. `sin_confirmacion` solo lo hace el sistema |
| `Escalar` | `{GrupoDestinoID?, Motivo, Actor}` → `*Resultado` | `escalada`, `pausa_fin` si estaba en espera, `asignada`/`reasignada`/`en_cola`; `escalamientos++`; queda `asignada` (o `nueva` si el grupo nuevo no tiene a quién). `ErrSinNivelSuperior` si no hay a dónde |
| `CambiarPrioridad` | `{Prioridad, Motivo, Actor}` | `prioridad_cambiada` y recalcula plazos |
| `Comentar` | `{Texto, Interno, Actor}` | `comentario` / `comentario_interno` (no es primera respuesta) |
| `AgregarDato` | `{Clave, Valor, Actor}` | `dato_agregado` (el caso agrega dato en vez de abrir otra incidencia) |
| `RegistrarQueja` | `{Texto, Actor}` | `queja` |
| `AsignarDesdeCola` / `Servicio.DespacharCola(ctx)` | reintenta las que están en `nueva` sin técnico | `asignada`; sin candidato no escribe nada |
| `RegistrarSLAVencido(ctx, id, "respuesta"\|"resolucion")` | lo llama el vigía | `sla_vencido` una vez por plazo, y **reescribe estado y tiempos** (veredicto «incumplida» aunque nadie toque la incidencia) |
| `RegistrarEvento(ctx, id, actor, tipo, datos)` | solo `aviso_sla`, `comentario_interno` | solo el evento y su fila `eventos_incidencia` (no toca la proyección) |
| `Servicio.CerrarResueltasSinConfirmar(ctx, ahora) ([]string, error)` | cierra las `resuelta` con ≥ 48 h **laborales** (`cierre_automatico_horas`) | `cerrada` con motivo `sin_confirmacion`, actor sistema; idempotente |
| `Servicio.BuscarAbiertaDuplicada(ctx, personaID, categoria)` | `*Incidencia` o `nil` | — (el caso debe `AgregarDato` en vez de `Crear`) |
| `Servicio.BuscarResueltaReciente(ctx, personaID, categoria, desde)` | para el «sigue igual» → `Reabrir` | — |
| `Servicio.RegistrarEncuesta(ctx, incID, puntaje, comentario)` | encuesta ya respondida (atajo) | fila `encuestas` + outbox `enc-<id>` |
| Consultas | `Obtener`, `ObtenerPorNumero`, `ObtenerPorToken`, `Eventos`, `SLA`, `SLALote(ids)`, `Detalle` (incidencia + SLA + eventos + acciones válidas), `Listar(Filtro)`, `SimularDespacho(categoria, prioridad)` (no persiste) | — |

Tipos de evento (`incidencia_eventos.tipo`): `creada asignada reasignada en_cola primera_respuesta estado_cambiado
pausa_inicio pausa_fin comentario comentario_interno escalada aviso_sla prioridad_cambiada resuelta reabierta cerrada
dato_agregado queja sla_vencido`. **Solo se inserta** (disparador en la base). `datos` lleva códigos y, solo en las claves
`texto valor nota solucion comentario detalle`, texto libre (que **no sale a ClickHouse** salvo `ANALITICA_TEXTO=1`), más
`contexto` = foto `{prioridad, categoria, grupo (nombre), tecnico_id}` del momento del evento (así el outbox se puede
reconstruir tal cual se emitió).

Errores: `ErrNoEncontrado`, `ErrInvalido` (vocabulario, campos), `ErrTransicionInvalida`, `ErrSinNivelSuperior`.

Avisos que encola el dominio (tabla `avisos`, **nunca se envían aquí**): plantillas `incidencia_asignada`,
`incidencia_sin_asignar` (y, por el vigía, `sla_75`, `sla_100`, `p1_creada`, `reapertura_2`, `queja`, `vip`).
`datos` = `{numero, prioridad, categoria, estado, grupo, titulo, vence_*_en…}`; nunca notas internas. Cada aviso lleva
`clave` UNIQUE: se encola una sola vez aunque el vigía corra dos veces.

## 6. `escala`: reglas y vigía

Reglas = datos (`escalamiento_reglas`), versionadas, `modo` `sombra|activo`. Claves sembradas: `sla_75_respuesta`,
`sla_75_resolucion`, `sla_100_respuesta`, `sla_100_resolucion` (el SLA se parte por métrica porque `escalamientos` es
UNIQUE por incidencia+regla+versión), `p1_creada`, `reapertura_2`, `queja`, `vip`, `guia_agotada`.
Condición `{"tipo":"sla","metrica":"respuesta","umbral_pct":75}` | `prioridad` | `reaperturas` | `queja` | `vip` |
`guia_agotada`. Acciones `avisar_tecnico`, `escalar_nivel`, `avisar_responsable`, `avisar_guardia`, `avisar_supervisor`
y `nota` (comentario interno).

* `ReglasVigentes`, `PublicarVersion(ctx, q, Regla) (version, error)`, `CambiarModo`, `Evaluar(Condicion, Foto)` (pura).
* `Nuevo(svc) *Vigia`; **`Vigilar(ctx, ahora) (*Informe, error)`**: evalúa las reglas vigentes sobre las abiertas.
  Idempotente (UNIQUE en `escalamientos` + clave de cada aviso): no repite aunque corra dos veces o se reinicie.
  **Activo** → ejecuta (aviso en `avisos`, `aviso_sla`, `escalada`, nota) y registra en `escalamientos`/`decisiones`;
  **sombra** → solo registra qué habría hecho. Pasar una regla de sombra a activo ejecuta lo pendiente en la pasada
  siguiente (para una activación controlada, `PublicarVersion`). Aparte de las reglas, marca `sla_vencido` (§5).
  `avisar_responsable` va al responsable del grupo **en que estaba** la incidencia; `avisar_guardia` sin guardia vigente
  cae en el supervisor; el supervisor sale de `configuracion.supervisor_tecnico_id` o de un usuario de consola
  `supervisor` con `tecnico_id`.
* **`Ciclo(ctx, ahora)`** = `DespacharColaEn` + `Vigilar` + `CerrarResueltasSinConfirmar`; `Correr(ctx, cada)` lo repite
  cada minuto (no se baja a intervalos mayores).
* **`Reproducir(ctx, desde, hasta) ([]Disparo, error)`** / `ReproducirConReglas`: repite las reglas sobre el historial y
  lista, en orden cronológico y sin escribir, qué habrían hecho. Límite: usa la prioridad vigente, no la de cada momento.

## 7. `analitica`: outbox

* `Encolar(ctx, q, tabla, clave, payload)`: fila en `outbox_analitica` **con la transacción del cambio**. Tablas:
  `eventos_incidencia incidencias_estado incidencias_tiempos casos_estado mensajes encuestas feedback`.
* Constructores (contrato §4, claves = columnas de `analitica/esquema.sql`): `EncolarEvento`, `EncolarIncidencia(ctx, q,
  cache, id, ahora)` (estado + tiempos), `EncolarCaso`, `EncolarMensaje`, `EncolarEncuesta`, `EncolarFeedback`
  (todos leen la fila de Postgres por id; la pasarela los usa al escribir `casos/mensajes/encuestas/feedback`).
  Claves `ev-<id>`, `inc-<id>-<version>`, `tie-<id>-<version>`, `caso-<id>-<version>`, `msg-<id>`, `enc-<id>`, `fb-<id>`;
  `version` = ms epoch de `actualizada_en` (siempre estrictamente creciente por incidencia).
* Tiempos: minutos **enteros** del calendario de la política de la prioridad; `mttr_min` neto de pausas hasta la última
  resolución; `resuelta_en` NULL mientras está reabierta; `sla_*_ok` 0/1/NULL (0 también cuando el plazo venció);
  `primer_contacto` NULL si no está resuelta o si se cerró «sin confirmación». `casos_estado.version` = lo último que movió
  al caso (su último mensaje o el último cambio de una incidencia suya): **quien cambie el estado de un caso sin mensaje
  nuevo debe actualizar `casos.ultimo_mensaje`**. Una encuesta enviada sin responder lleva `puntaje` NULL y se reenvía
  con la misma clave `enc-<id>` al responder.
* `NuevoTrabajador(db, Config)`, `ConfigDesdeEntorno()` (`JSR_CH_URL`, `JSR_CH_USUARIO`, `JSR_CH_CLAVE`, `JSR_CH_BASE`,
  `ANALITICA_LOTE`; alternativas `CLICKHOUSE_*`). **`Vaciar(ctx)`**: lotes de `FOR UPDATE SKIP LOCKED` por `id`
  ascendente → `INSERT INTO <tabla> FORMAT JSONEachRow` con `date_time_input_format=best_effort`,
  `wait_end_of_query=1` e `input_format_skip_unknown_fields=1`, cabeceras `X-ClickHouse-User/Key`; marca `enviado_en`
  solo tras un 200; si falla, lo ya confirmado queda marcado, el resto pendiente y se reintenta el mismo lote (nada se
  pierde ni se duplica; al-menos-una-vez). `Correr(ctx, cada)` cada 10 s con espera creciente. `Ping`, `AplicarEsquema`,
  `ReiniciarDestino` (`DROP DATABASE` + esquema; solo a petición).
* **`Reconstruir(ctx, db)`**: borra el outbox y lo regenera desde las tablas de verdad (todos los eventos, la última
  versión de cada incidencia y caso, mensajes, encuestas, feedback), todo pendiente. Tras `ReiniciarDestino` + `Vaciar`
  ClickHouse da las mismas cifras (probado con las 12 golden queries). La alternativa de `analitica/reconstruir.md`
  (marcar `enviado_en = NULL`) también vale; el outbox nunca se purga solo.

## 8. `golden`

`Nuevo(dirAnalitica, lector).Catalogo(ctx)` (devuelve `analitica/catalogo.json` tal cual), `CatalogoConSQL(ctx)` (el
catálogo con la clave `sql` en cada KPI: el texto de su última `vN.sql`) y `Ejecutar(ctx, kpi, Params{Desde, Hasta,
Grupo}) (*Resultado{KPI, Version, Definicion, Unidad, Parametros, SQL, Filas})` (`SQL` = texto de la versión ejecutada): usa **siempre la última
`vN.sql`** de `analitica/golden/<kpi>/`, valida fechas, pasa solo los parámetros que el SQL declara. `CH` es el lector
HTTP (usuario `analista` de solo lectura, `wait_end_of_query=1`); `LectorDesdeEntorno()` lee `JSR_CH_URL`,
`JSR_CH_ANALISTA_USUARIO`, `JSR_CH_ANALISTA_CLAVE`, `JSR_CH_BASE`. Ningún otro código calcula un KPI.

## 9. Motor: variables, rutas y ejemplos

Variables (nunca se imprimen): `DATABASE_URL`, **`MOTOR_CLAVE`** (≥ 16 caracteres; sin ella no arranca), `MOTOR_ADDR`
(`:8090`), `ANALITICA_DIR` (`/analitica`), `JSR_CH_*` (§7 y §8), `MOTOR_VIGIA=0` / `MOTOR_OUTBOX=0` (apagan los
trabajos de fondo), `MOTOR_MIGRAR=0`. Al arrancar migra, siembra la configuración por defecto y aplica
`analitica/esquema.sql` a ClickHouse (si está configurado). En segundo plano: **vigía cada minuto**
(`Ciclo`: cola + reglas + cierre a las 48 h laborales), **outbox → ClickHouse cada 10 s**. Solo red del compose.

Todas las rutas exigen `X-Interno-Clave` (incluida `/interno/salud`; sin clave o con otra → **401**
`{"error","codigo":"no_autorizado"}`). Errores `{"error": "texto en español", "codigo"}`: 400 JSON roto, 404
`no_encontrado`, 409 `conflicto` (transición inválida, sin nivel superior, ClickHouse no configurado), 422 `invalido`,
502 `no_disponible` (ClickHouse no respondió), 500 `interno`.

```bash
export M=http://motor:8090 K="X-Interno-Clave: $MOTOR_CLAVE"

# Salud
curl -s -H "$K" $M/interno/salud
#  {"ok":true,"db":"ok","clickhouse":"ok|error|sin_configurar","version":"1.2.3","outbox_pendiente":0}

# Crear (devuelve incidencia + asignacion + avisos encolados por esta llamada)
curl -s -H "$K" -X POST $M/interno/incidencias -d '{
  "persona_id": 12, "caso_id": 340, "tipo": "incidente", "categoria": "correo", "impacto": "persona", "urgencia": "media",
  "titulo": "Outlook no recibe correos", "resumen": "Desde la mañana", "canal": "whatsapp", "motivo": "guia_agotada",
  "queja": false, "actor": {"tipo":"asistente"}}'
#  {"incidencia":{"id":142,"numero":"INC-000142","estado":"asignada","prioridad":"P3","categoria":"correo","grupo":"Mesa N1",
#     "tecnico":"Luis Paz","tecnico_id":3,"persona":{"id":12,"nombre":"…","vip":false,"sede":"…","area":"…"},
#     "vence_respuesta_en":"2026-10-05T16:00:00Z","vence_resolucion_en":"…","token_publico":"…", …},
#   "asignacion":{"tecnico_id":3,"grupo_id":1,"motivo":"desempate_ultima_asignacion","en_cola":false,"por_guardia":false,"explicacion":"…"},
#   "avisos":[{"id":9,"plantilla":"incidencia_asignada","destinatario_tipo":"tecnico","destinatario_id":3,"canal":"whatsapp","datos":{…}}]}

# Una incidencia abierta por síntoma / la resuelta reciente (para «sigue igual»)
curl -s -H "$K" "$M/interno/incidencias/duplicada?persona_id=12&categoria=correo"      # {"incidencia": {...} | null}
curl -s -H "$K" "$M/interno/incidencias/resuelta?persona_id=12&categoria=correo&desde=2026-10-01T00:00:00Z"

# Acciones: asignar responder comentar comentar_interno pausar reanudar resolver reabrir cerrar escalar
#           cambiar_prioridad agregar_dato queja            (todas devuelven {incidencia, avisos[, asignacion]})
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"responder","texto":"Lo reviso","actor":{"tipo":"tecnico","id":"3"}}'
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"pausar","motivo":"espera_usuario","nota":"¿qué error ves?","actor":{"tipo":"tecnico","id":"3"}}'
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"reanudar","actor":{"tipo":"usuario","id":"12"}}'
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"resolver","solucion":"Se reconfiguró el perfil","actor":{"tipo":"tecnico","id":"3"}}'
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"cerrar","motivo":"confirmado","actor":{"tipo":"usuario","id":"12"}}'
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"agregar_dato","clave":"equipo","valor":"PC-CONT-07","actor":{"tipo":"asistente"}}'
curl -s -H "$K" -X POST $M/interno/incidencias/142/acciones -d '{"accion":"asignar","tecnico_id":5,"motivo":"balanceo","actor":{"tipo":"tecnico","id":"1"}}'
#  campos por acción: asignar{tecnico_id,motivo} responder{texto,espera_usuario} comentar{texto} pausar{motivo,nota}
#  resolver{solucion} reabrir{motivo} cerrar{motivo: confirmado|sin_confirmacion} escalar{grupo_destino_id?,motivo}
#  cambiar_prioridad{prioridad,motivo} agregar_dato{clave,valor} queja{texto}.  Transición inválida → 409.

# SLA por lote (hasta 1000 ids): proximo = respuesta si aún no hubo primera respuesta; si no, resolucion
curl -s -H "$K" -X POST $M/interno/sla/calcular -d '{"ids":[142,143]}'
#  {"142":{"porcentaje_respuesta":75,"porcentaje_resolucion":6.25,"restante_min":30,"vencida":false,"pausada":false,
#          "proximo":"respuesta","restante_respuesta_min":30,"restante_resolucion_min":1350,"vence_respuesta_en":"…","vence_resolucion_en":"…"}}

# Vigía a demanda (el motor ya lo corre cada minuto); cuerpo opcional
curl -s -H "$K" -X POST $M/interno/vigia/ejecutar -d '{"ahora":"2026-10-05T15:30:00Z"}'
#  {"ahora":"…","revisadas":62,"reglas":9,"acciones":[{"incidencia_id":142,"numero":"INC-000142","regla_clave":"sla_75_respuesta",
#    "regla_version":1,"modo":"activo","ejecutada":true,"acciones":[{"tipo":"avisar_tecnico","resultado":"aviso_encolado",…}]}],
#   …}   (vencidos, asignadas, cerradas y errores aparecen solo si hay)

# Qué haría el despachador ahora, sin persistir nada
curl -s -H "$K" -X POST $M/interno/despacho/simular -d '{"categoria":"correo","prioridad":"P2"}'

# Avisos: la pasarela los envía y los marca (el motor nunca envía)
curl -s -H "$K" "$M/interno/avisos/pendientes?limite=50"      # [{id, incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, intentos, error, creado_en}]
curl -s -H "$K" -X POST $M/interno/avisos/9/marcar -d '{"enviado":true}'
curl -s -H "$K" -X POST $M/interno/avisos/9/marcar -d '{"enviado":false,"error":"Evolution respondió 503"}'   # sigue pendiente

# Golden queries (siempre la última versión, con el usuario analista de ClickHouse)
curl -s -H "$K" $M/interno/golden                              # analitica/catalogo.json + "sql" (última versión) en cada KPI
curl -s -H "$K" "$M/interno/golden/mttr?desde=2026-07-01&hasta=2026-09-30&grupo=Redes"
#  {"kpi":"mttr","nombre":"…","version":1,"definicion":"…","unidad":"minutos laborales","parametros":{…},"sql":"-- mttr v1 …","filas":[{"evaluadas":…,"mediana_min":…}]}

# Analítica
curl -s -H "$K" -X POST $M/interno/analitica/vaciar                                     # {"enviadas":123,"por_tabla":{…}}
curl -s -H "$K" -X POST "$M/interno/analitica/reconstruir"                              # re-encola desde Postgres y envía: {"encoladas":{…},"enviadas":n}
curl -s -H "$K" -X POST "$M/interno/analitica/reconstruir?reiniciar_destino=1"          # antes: DROP DATABASE de ClickHouse + esquema
```

## 10. Semilla sintética (`cmd/semilla`)

```bash
go run ./cmd/semilla -dsn "$DATABASE_URL" [-limpiar] [-incidencias 600] [-semilla 20261005] [-exportar dir] [-json]
```

3 meses (01-jul a 30-sep-2026), 4 sedes, 8 áreas, 40 personas (3 VIP), 11 técnicos en 4 grupos con turnos, habilidades,
2 ausencias y guardias semanales, ~600 incidencias y ~240 casos que resolvió solo el asistente. Los estados, eventos y
outbox **los producen `incidencia`, `escala` y `analitica`** moviendo un reloj inyectable (el vigía corre con las reglas
en modo activo durante la carga y se restauran a sombra al terminar). Casos difíciles: creadas el viernes 17:55,
feriados, pausas, reaperturas (1 y 2), escalamientos por SLA, P1 fuera de horario a la guardia, nunca resueltas, sin
primera respuesta, cierres sin confirmación, quejas, VIP, guía agotada, encuestas respondidas y sin responder,
feedback. **Determinista**: la misma semilla y fechas dan los mismos datos (`Resumen.Huella`, SHA-256 del outbox) y los
mismos ids/números `INC-000001…`. Sin `-limpiar`, si ya hay semilla no hace nada; con `-limpiar` borra solo lo
sintético y recarga; **se niega a trabajar sobre una base con datos que no son de la semilla** (`ErrDatosReales`).
Todo marcado como sintético: `configuracion.semilla_sintetica`, WhatsApp `5100000xxxx` (inválidos), correos
`@empresa.example`, y todos los avisos quedan marcados como no enviables (`error = 'semilla_sintetica…'`).
`-exportar dir` escribe un `.jsonl` por tabla de ClickHouse (JSONEachRow, una fila por evento y la última versión de
cada incidencia/caso) para generar `analitica/semilla/` desde esta misma semilla.

## 11. Imagen Docker

`backend/Dockerfile` (multi-stage `golang:1.27-bookworm` → `gcr.io/distroless/static-debian12:nonroot`, 36 MB, solo
`/motor` y `/semilla`, `HEALTHCHECK` con `/motor -salud`, sin shell ni root):

```bash
docker build -t jsrbot/motor --build-arg VERSION=$(git rev-parse --short HEAD) backend
docker run -d -e DATABASE_URL=… -e MOTOR_CLAVE=… -v ./analitica:/analitica:ro jsrbot/motor
docker run --rm --entrypoint /semilla -e DATABASE_URL=… jsrbot/motor -limpiar
```

## 12. Decisiones y supuestos para quien siga

* **`SUPUESTO:`** horario, feriados, plazos de SLA, cadena de grupos, categorías por grupo, capacidades, matriz, umbrales
  y acciones de las reglas: valores de ejemplo (`CONTEXT.md` §7), todos configurables.
* Las reglas nacen en **sombra** (AGENTS §1.4 regla 6). Para encenderlas: `PublicarVersion` con `modo: activo` (o
  `CambiarModo`) con la cifra de `Reproducir` que lo justifique.
* La prioridad nunca viene de fuera: la calcula la matriz (y el mínimo VIP). El asistente propone impacto y urgencia.
* El motor es el único que escribe `incidencias`, `incidencia_eventos`, `escalamientos`, `avisos` (creación) y las filas
  de outbox de esas tablas. La pasarela lee Postgres y muta incidencias solo por la API interna.
* Un plazo vencido se escribe como `sla_vencido` + versión nueva de `incidencias_tiempos` en el minuto en que vence
  (hace falta que el vigía corra cada minuto; el motor lo hace solo).
* `feedback.mensaje_id` e `incidencias_estado.caso_id` viajan en el payload (contrato) aunque `analitica/esquema.sql`
  todavía no tenga esas columnas: por eso el trabajador manda `input_format_skip_unknown_fields=1`.
* Las acciones de un guion de la semilla que el estado ya no permite (la incidencia se escaló, se cerró sola…) se saltan
  y se cuentan en `Resumen.Saltadas`: la intención la define el guion; la realidad, las reglas.
