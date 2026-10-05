# Contratos entre servicios — jsrbot

Dueño: Arquitecto. Quien necesite cambiar algo aquí lo anota en la sección «Cambios» al final, con motivo.
Esquema de Postgres: [`backend/migrations/001_esquema.sql`](../backend/migrations/001_esquema.sql).
Convenciones: JSON en `snake_case` sin tildes en las claves; fechas ISO 8601 en UTC (`2026-10-05T14:30:00Z`); la
interfaz las muestra en hora de Lima.

## 1. Agente: `POST /chat`

El backend manda el turno; el agente **no guarda estado** (el backend persiste `etapa` y `memoria`).

Petición:

```json
{
  "caso_id": 12, "canal": "whatsapp|web", "mensaje": "no me abre el correo",
  "historial": [{"rol": "usuario|asistente|tecnico", "texto": "…"}],
  "etapa": "recepcion", "memoria": {},
  "perfil": {"nombre": "Ana Ríos", "sede": "Centro", "area": "Contabilidad", "vip": false, "equipos": ["PC-CONT-07"]},
  "incidencias_abiertas": [{"numero": "INC-000142", "estado": "en_curso", "titulo": "…", "categoria": "correo",
                            "tecnico": "Luis Paz", "vence_resolucion_en": "2026-10-05T16:40:00Z"}],
  "ahora": "2026-10-05T14:30:00Z"
}
```

Respuesta:

```json
{
  "respuesta": "texto para la persona, o null si el backend arma el texto (flujo fijo)",
  "etapa": "diagnostico",
  "memoria": {"…": "ficha del caso, ARQUITECTURA §2.2"},
  "intencion": "reportar_falla", "confianza": 0.93, "categoria": "correo", "categoria_confianza": 0.88,
  "accion": {
    "tipo": "ninguna|crear_incidencia|agregar_dato|consultar_estado|pedir_tecnico|confirmar_solucion|sigue_igual|encuesta",
    "incidencia": {"tipo": "incidente", "categoria": "correo", "impacto": "persona", "urgencia": "media",
                   "titulo": "Outlook no recibe correos", "resumen": "…", "motivo": "guia_agotada|p1|pidio_tecnico|sin_articulo"},
    "numero": "INC-000142",
    "dato": {"clave": "equipo", "valor": "PC-CONT-07"},
    "puntaje": 4
  },
  "articulos_usados": ["KB-031"],
  "senales": {"animo": "neutro|molesto|muy_negativo", "queja": false, "pide_tecnico": false, "contrasena_oculta": false},
  "texto_usuario_guardar": "mensaje con contraseñas/tokens reemplazados por [oculto]",
  "juez": {"modo": "apagado|sombra|activo", "veredictos": {}},
  "latencia_ms": 420
}
```

Reglas:

- **El agente propone; el backend decide.** `prioridad`, plazos, técnico y estado nunca salen del agente.
- **Flujos fijos:** con `crear_incidencia`, `consultar_estado`, `pedir_tecnico` y `encuesta`, el agente puede devolver
  `respuesta: null` y el backend arma el texto (número, plazo, técnico y estado los escribe código, nunca un LLM).
  Si el agente trae una frase previa útil, la manda en `respuesta` y el backend le añade el dato fijo.
- El mensaje que se guarda en `mensajes` es `texto_usuario_guardar`, no el original.
- `GET /salud` → `{"ok": true, "modelo": "v1", "juez": "apagado"}`. `POST /reentrenar`, `POST /conocimiento/recargar`
  (el backend manda los artículos en el cuerpo: `{"articulos": [{"clave","titulo","categoria","sintomas","pasos","cuerpo"}]}`).

## 2. Pasarela (OCaml): API de la consola

Prefijo `/api`. Autenticación: `Authorization: Bearer <token>` (JWT HS256 firmado con `JWT_SECRET`, 12 h).
Roles: `tecnico < supervisor < gerencia`, aparte `entrenador` y `admin` (admin puede todo). Errores:
`{"error": "texto en español para la persona", "codigo": "no_autorizado|no_encontrado|invalido|conflicto"}`.
Listas paginadas: `?pagina=1&por_pagina=50` → `{"items": [...], "total": 123}`.

| Método y ruta | Rol mínimo | Qué hace |
|---|---|---|
| `POST /api/auth/login` `{email, clave}` | — | `{token, usuario: {id, nombre, rol, tecnico_id}}` |
| `GET /api/yo` | tecnico | Usuario actual |
| `GET /api/bandeja` | tecnico | `{vencen_pronto: [], mias: [], sin_asignar: [], contador: n}` (DISENO §02) |
| `GET /api/incidencias` | tecnico | Filtros: `estado, prioridad, tecnico_id, grupo_id, categoria, q, abiertas=1` |
| `POST /api/incidencias` | tecnico | Alta manual |
| `GET /api/incidencias/{id}` | tecnico | Incidencia + `sla` (porcentaje, restante_min, vencida) + `eventos` + `mensajes` del caso + `memoria` + `persona` |
| `POST /api/incidencias/{id}/acciones` | tecnico | `{accion: asignar\|responder\|comentar_interno\|pausar\|reanudar\|resolver\|reabrir\|cerrar\|escalar\|cambiar_prioridad, …}`; `responder` manda el texto a la persona por su canal |
| `GET /api/casos`, `GET /api/casos/{id}/mensajes`, `POST /api/casos/{id}/tomar` | tecnico | Conversaciones; tomar pausa al asistente |
| `GET/POST/PUT /api/tecnicos`, `GET/POST/PUT /api/grupos` | supervisor | Equipo. `GET /api/tecnicos` incluye carga actual |
| `GET/PUT /api/categorias`, `/api/calendarios`, `/api/sla`, `/api/matriz`, `/api/escalamiento/reglas` | admin | Configuración |
| `GET/POST/PUT /api/articulos` | entrenador | Conocimiento |
| `GET /api/entrenamiento/cola`, `POST /api/entrenamiento/{id}/revisar` | entrenador | Cola de revisión |
| `GET /api/indicadores?desde&hasta` | gerencia | Resultado de las golden queries (ver §4) |
| `POST /api/reportes/preguntar` `{pregunta}` | gerencia | Analista |
| `POST /api/chat-web` `{sesion, mensaje}` | público (limitado) | Turno del chat web de prueba; devuelve respuesta + análisis |
| `GET /api/estado/{token}` · `POST /api/estado/{token}/responder` | público | Estado de la incidencia (pantalla 16) |
| `GET /api/eventos` (SSE) | tecnico | Eventos en vivo: `incidencia_creada`, `incidencia_actualizada`, `mensaje` |
| `GET /api/salud` | público | `{ok, db, agente, version}` |
| `POST /webhook/evolution` | secreto | Entrada de WhatsApp (evolution-go) |

## 3. Etapas, estados y vocabulario (cerrado)

- **Intenciones:** `reportar_falla, solicitar_acceso, solicitar_equipo, restablecer_clave, consultar_estado,
  aportar_dato, confirmar_solucion, sigue_igual, pedir_tecnico, queja, agradecer, saludo, fuera_de_alcance`.
- **Categorías:** `correo, cuentas_accesos, red_wifi, vpn, impresoras, equipo, software_oficina, sistema_interno,
  telefonia, otro`.
- **Etapas:** `recepcion, diagnostico, guia, incidencia, seguimiento, cierre, encuesta, consulta_estado`.
- **Estados de incidencia:** `nueva, asignada, en_curso, espera_usuario, espera_tercero, resuelta, cerrada, reabierta`.
- **Pausan el reloj de SLA:** `espera_usuario`, `espera_tercero`.

## 4. Analítica

Outbox: `outbox_analitica(tabla, clave, payload)`; un trabajador del backend manda lotes por el HTTP de ClickHouse
(`INSERT … FORMAT JSONEachRow`, `date_time_input_format=best_effort`) cada 10 s y marca `enviado_en`. **Las claves
del `payload` son exactamente las columnas de la tabla destino** (`analitica/esquema.sql` las define con estos
nombres). Marcas de tiempo en ISO UTC. `version` = milisegundos epoch de `actualizada_en` (para `ReplacingMergeTree`).

| Tabla destino | `clave` | Columnas del payload |
|---|---|---|
| `eventos_incidencia` | `ev-<id del evento>` | `id, incidencia_id, numero, ts, tipo, actor_tipo, actor_id, prioridad, categoria, grupo, tecnico_id, datos` (`datos` = JSON como texto) |
| `incidencias_estado` | `inc-<id>-<version>` | `incidencia_id, version, numero, persona_id, tipo, categoria, impacto, urgencia, prioridad, estado, grupo, nivel, tecnico_id, canal, sede, area, creada_en, primera_respuesta_en, resuelta_en, cerrada_en, reaperturas, escalamientos` |
| `incidencias_tiempos` | `tie-<id>-<version>` | `incidencia_id, version, prioridad, categoria, grupo, tecnico_id, creada_en, resuelta_en, cerrada_en, frt_min, mttr_min, pausa_min, sla_respuesta_ok, sla_resolucion_ok, primer_contacto` (minutos **laborales**, `NULL` si aún no aplica; `*_ok` 0/1; `primer_contacto` 1 si resuelta por el primer técnico, sin escalamiento ni reapertura) |
| `casos_estado` | `caso-<id>-<version>` | `caso_id, version, canal, persona_id, estado, inicio, ultimo_mensaje, tiene_incidencia, confirmado_resuelto` |
| `mensajes` | `msg-<id>` | `id, caso_id, ts, rol, canal, intencion, confianza, categoria, juez_modo, juez_veredicto, latencia_ms, regenerada, frases_quitadas, costo_usd, texto` (`texto` vacío salvo `ANALITICA_TEXTO=1`) |
| `encuestas` | `enc-<id>` | `id, incidencia_id, caso_id, ts, puntaje` |
| `feedback` | `fb-<id>` | `id, caso_id, incidencia_id, ts, senal, valor` |

Golden queries: `analitica/golden/<kpi>/{meta.yaml, vN.sql, esperado.csv}`. El backend las ejecuta con parámetros
`{desde:Date}`, `{hasta:Date}`, `{grupo:String}` y devuelve `{kpi, version, definicion, unidad, filas}`.
`analitica/semilla/` es el conjunto fijo (JSONEachRow por tabla, mismas columnas) con el que se prueban.

## 5. Reparto de servicios: Go (motor) + OCaml (pasarela)

Decisión del usuario (05-10-2026): lo que falta se escribe en **OCaml**; el Go ya hecho se queda.

| Servicio | Lenguaje | Carpeta | Dueño de |
|---|---|---|---|
| **motor** | Go | `backend/` (`cmd/motor`) | Incidencias, eventos, SLA, despacho, escalamiento, vigía, outbox → ClickHouse, golden queries, semilla. Es el **único que escribe** `incidencias`, `incidencia_eventos`, `escalamientos`, `avisos` (creación) y `outbox_analitica` de esas tablas |
| **pasarela** | OCaml | `pasarela/` | API de la consola (§2), autenticación y roles, webhook de WhatsApp, flujo del caso (sesión 6 h, pausa por técnico, flujos fijos), cliente del agente, envío de avisos, chat web, estado público, SSE. Escribe `casos`, `mensajes`, `decisiones`, `personas`, `feedback`, `encuestas`, `pares_preferencia`, `etiquetas_revision`, `modelos`, `usuarios_consola`, `auditoria`, `configuracion` y los CRUD de `tecnicos`, `grupos`, `categorias`, `articulos`, `calendarios`, `sla_politicas`, `matriz_prioridad`, `escalamiento_reglas` |
| **agente** | Python | `agente/` | Contrato §1 |

La pasarela **lee** Postgres directo (listas, bandeja, detalle) y **muta incidencias solo llamando al motor**. Cuando
la pasarela inserta en `mensajes`, `casos`, `encuestas` o `feedback`, encola en `outbox_analitica` en la misma
transacción, con el formato de §4. El motor es el único que vacía el outbox hacia ClickHouse.

### Motor: API interna (HTTP, solo red del compose)

Cabecera `X-Interno-Clave: <MOTOR_CLAVE>` (variable de entorno). JSON. Errores `{"error","codigo"}` con 400/404/409/422.
Actor: `{"tipo":"usuario|tecnico|asistente|sistema","id":"…"}`.

| Ruta | Cuerpo / parámetros | Respuesta |
|---|---|---|
| `GET /interno/salud` | — | `{ok, db, clickhouse, version}` |
| `POST /interno/incidencias` | `{persona_id, caso_id, tipo, categoria, impacto, urgencia, titulo, resumen, canal, motivo, actor}` | `{incidencia, asignacion: {tecnico_id, grupo_id, motivo, en_cola}, avisos: [...]}` |
| `GET /interno/incidencias/duplicada?persona_id=&categoria=` | — | `{incidencia: {...}\|null}` |
| `POST /interno/incidencias/{id}/acciones` | `{accion: asignar\|responder\|comentar\|comentar_interno\|pausar\|reanudar\|resolver\|reabrir\|cerrar\|escalar\|cambiar_prioridad\|agregar_dato, actor, …}` | `{incidencia, avisos: [...]}` |
| `POST /interno/sla/calcular` | `{ids: [1,2,3]}` | `{"1": {porcentaje_respuesta, porcentaje_resolucion, restante_min, vencida, pausada}, …}` |
| `POST /interno/vigia/ejecutar` | `{ahora?: ISO}` | `{revisadas, acciones: [...]}` (el motor también lo corre solo cada minuto) |
| `POST /interno/despacho/simular` | `{categoria, prioridad}` | decisión sin persistir |
| `GET /interno/avisos/pendientes?limite=50` | — | `[{id, incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos}]` |
| `POST /interno/avisos/{id}/marcar` | `{enviado: bool, error?: string}` | `{ok}` |
| `GET /interno/golden` | — | catálogo (`analitica/catalogo.json`) |
| `GET /interno/golden/{kpi}?desde=&hasta=&grupo=` | — | `{kpi, version, definicion, unidad, filas}` |
| `POST /interno/analitica/vaciar` · `POST /interno/analitica/reconstruir` | — | `{enviadas}` |

`incidencia` en las respuestas = fila de `incidencias` + `persona`, `categoria` (clave), `grupo`, `tecnico` (nombre) ya resueltos.
`avisos` = filas encoladas en la tabla `avisos` (la pasarela las envía y las marca).

## Cambios

**05-10-2026 · Datos (analitica/), aceptados por el Arquitecto.** `analitica/esquema.sql` es la definición vigente de
las tablas de ClickHouse; si algo contradice a §4, manda el esquema.

1. **SLA mira incidencias creadas en el periodo**, no «cerradas en el periodo» (ARQUITECTURA §8.3 queda corregida):
   con «cerradas», las abiertas vencidas nunca entran y el KPI mejora cuando la mesa se atrasa.
2. **La fila `creada` de `eventos_incidencia` lleva el grupo de origen** (`grupo` = nombre del grupo, no el id); 8 KPI
   dependen de ello.
3. **`incidencias_tiempos`** (lo escribe el motor):
   - los minutos son del calendario de la política de la prioridad (P1 en 24×7 si la política lo dice);
   - `mttr_min` descuenta pausas y llega hasta la última resolución;
   - `resuelta_en` es NULL mientras la incidencia está reabierta;
   - `sla_*_ok` es 0 cuando el plazo vence sin cumplirse → **el vigía escribe una versión nueva en ese instante**;
   - `primer_contacto` es NULL si el cierre fue «sin confirmación».
4. **`encuestas.puntaje` NULL = enviada y sin responder** (tasa de respuesta). La misma `enc-<id>` se reenvía al
   responder; `ts` es el momento del envío. (La pasarela escribe la fila al enviar la encuesta y la actualiza al
   responder; `encuestas.puntaje` en Postgres pasa a admitir NULL → migración 003.)
5. **`feedback` lleva `mensaje_id`** en el payload (sin él la exactitud del clasificador es una estimación).
   `incidencias_estado` puede llevar `caso_id` (opcional).
6. `ORDER BY` de `eventos_incidencia` = `(incidencia_id, ts, id)` (no hay `org`).
7. Motor: las golden queries se ejecutan con el usuario `analista` de ClickHouse, siempre con `wait_end_of_query=1`
   (si no, un límite excedido llega como HTTP 200 con el cuerpo cortado); reintentar con el mismo lote; no purgar el
   outbox (o poder re-emitir desde las tablas de verdad). Ver `analitica/reconstruir.md`.


**05-10-2026 · Backend-dominio (motor Go).** Detalle de cada pieza en `backend/internal/LEEME.md`.

1. **Migraciones** (todas idempotentes, `backend/migrations/`): `002_avisos.sql` crea `avisos(id, incidencia_id,
   destinatario_tipo, destinatario_id, canal, plantilla, datos, creado_en, enviado_en, error)` **más** `clave` UNIQUE
   (idempotencia: un aviso se encola una sola vez) e `intentos`; `003_encuestas_puntaje_null.sql` (001 ya permitía NULL; queda
   explícito); `004_eventos_inmutables.sql` (disparador que prohíbe UPDATE/DELETE en `incidencia_eventos`; se llamó
   `003_eventos_inmutables.sql` unos minutos: idempotente, no falla en una base que ya la aplicó con ese nombre).
2. **Reglas de escalamiento**: el SLA se parte por métrica porque `escalamientos` es UNIQUE por (incidencia, regla,
   versión): claves `sla_75_respuesta`, `sla_75_resolucion`, `sla_100_respuesta`, `sla_100_resolucion` (en vez de
   `sla_75` y `sla_100`); resto igual (`p1_creada`, `reapertura_2`, `queja`, `vip`, `guia_agotada`). Acción añadida
   `nota` (comentario interno, la usa `guia_agotada`). Nacen en `sombra`. Plantillas de aviso del vigía: `sla_75`,
   `sla_100`, `p1_creada`, `reapertura_2`, `queja`, `vip`; del dominio: `incidencia_asignada`, `incidencia_sin_asignar`.
3. **Eventos de incidencia añadidos** (la columna `tipo` es libre): `en_cola`, `queja`, `sla_vencido` (una vez por plazo
   y métrica; fuerza una versión nueva de `incidencias_estado` e `incidencias_tiempos` con el veredicto 0). Todo evento
   lleva en `datos.contexto` la foto `{prioridad, categoria, grupo (nombre), tecnico_id}` de ese momento, de donde salen
   las columnas `prioridad/categoria/grupo/tecnico_id` de `eventos_incidencia` (por eso `Reconstruir` reproduce lo emitido).
   El texto libre de `datos` (`texto, valor, nota, solucion, comentario, detalle`) **no sale a ClickHouse** salvo `ANALITICA_TEXTO=1`.
4. **Payloads de §4**: `actor_id` sale `""` y no `null` (la columna es `String`); los minutos de `incidencias_tiempos` salen
   **enteros** (valen para columnas enteras y de coma flotante); `costo_usd` sale `0` y no `null`; `incidencias_estado`
   lleva `caso_id` y `feedback` lleva `mensaje_id` (Cambios de Datos 5) aunque `esquema.sql` aún no tenga esas columnas:
   el trabajador manda `input_format_skip_unknown_fields=1` (y `wait_end_of_query=1`, `date_time_input_format=best_effort`).
   Variables de ClickHouse: las de `analitica/.env.ejemplo` (`JSR_CH_URL`, `JSR_CH_USUARIO`, `JSR_CH_CLAVE`, `JSR_CH_BASE`,
   `JSR_CH_ANALISTA_USUARIO`, `JSR_CH_ANALISTA_CLAVE`); `CLICKHOUSE_*` como alternativa.
5. **`casos_estado.version`** = lo último que movió al caso (`GREATEST(ultimo_mensaje, última actualización de una incidencia
   suya)`), no solo el último mensaje: si la pasarela cambia el estado de un caso sin mensaje nuevo, **debe actualizar
   `casos.ultimo_mensaje`** para que la versión crezca (si no, ClickHouse conserva una de dos filas con la misma versión).
6. **§5 (API interna), lo que se concretó o añadió**: `MOTOR_CLAVE` obligatoria (≥ 16 caracteres); **todas** las rutas,
   incluida `/interno/salud`, exigen `X-Interno-Clave` (401 `no_autorizado`); `POST /interno/incidencias` responde 200 y
   acepta `queja: true`; `asignacion` lleva además `por_guardia` y `explicacion`; acción nueva `queja` en
   `/incidencias/{id}/acciones`; ruta nueva `GET /interno/incidencias/resuelta?persona_id=&categoria=[&desde=]` (para el
   «sigue igual»); `sla/calcular` devuelve además `proximo`, `restante_respuesta_min`, `restante_resolucion_min` y
   los vencimientos (`restante_min` es el del plazo que toca: respuesta si aún no hubo primera respuesta, si no resolución);
   `avisos/pendientes` devuelve también `intentos`, `error` y `creado_en` (un solo emisor debe sondearlos);
   `analitica/reconstruir` re-encola desde Postgres **y** envía (`{encoladas, enviadas}`), y con
   `?reiniciar_destino=1` antes hace `DROP DATABASE` de ClickHouse y reaplica `esquema.sql`; ClickHouse caído → 502
   `no_disponible` sin perder nada. El motor aplica `analitica/esquema.sql` a ClickHouse al arrancar.
7. **Vocabulario**: `incidencias.canal` admite `consola` (altas manuales) además de `whatsapp|web`. El vigía corre por
   minuto y también hace la asignación de la cola y el cierre a las 48 h laborales (`sin_confirmacion`).
8. **Encuestas**: el dominio solo ofrece `RegistrarEncuesta` (atajo ya respondida); el envío y la respuesta de la
   encuesta (`puntaje` NULL → valor, misma `enc-<id>`) son de la pasarela, que encola la fila con el formato de §4
   (el motor tiene `analitica.EncolarEncuesta` y lo usa `Reconstruir`: la fila sale de `encuestas`, con `ts` = envío).

**05-10-2026 · Diseño UI (web/).** La consola ya consume lo de abajo; las formas están en `web/src/lib/tipos.ts` y el ejemplo
vivo es `web/mock/servidor.mjs` (`npm run mock`, puerto 5599, `admin@jsr.test` / `jsr123`). Lo que sigue **concreta** §2
(que no fijaba las formas) y **pide** lo que la interfaz necesita y §2 no trae. Si el backend se aparta, cambia la
interfaz, no al revés; avisen en esta sección.

1. **Formas de §2 que la UI da por hechas**
   - Fila de lista (`/api/bandeja`, `/api/incidencias`): `{id, numero, titulo, prioridad, estado, categoria, canal,
     persona{id,nombre,area,sede}|null, tecnico{id,nombre}|null, grupo, creada_en, actualizada_en, vence_resolucion_en,
     sla{porcentaje, restante_min, vencida, pausado}|null}`. **El `sla` va también en las listas** (no solo en el detalle):
     el color de la fila sale de ahí. `restante_min` negativo = vencida; `sla` es `null` en resueltas y cerradas.
   - `/api/bandeja`: además de §2, `espera_usuario: {cantidad, desde}` (para «2 esperan respuesta de la persona desde ayer»
     cuando nada vence). `contador` = lo que pide acción ahora = `vencen_pronto.length`.
   - `/api/incidencias`: `estado`, `tecnico_id` (`sin` = sin asignar), `por_pagina` hasta 200; `q` busca en número, asunto y persona.
   - Detalle `/api/incidencias/{id}`: la fila de lista más `resumen, tipo, impacto, urgencia, nivel, reaperturas, escalamientos,
     token_publico, persona_detalle{…, correo, whatsapp, vip, equipos[]}, eventos[{id,ts,tipo,actor_tipo,actor_nombre,datos}],
     mensajes{items[{id,ts,rol,autor,texto,interno?,meta{}}],total}` (las notas internas viajan en el hilo con `interno: true`),
     `memoria{}`, `clasificacion{intencion,confianza,categoria,categoria_confianza}|null`, `veredictos[{ts,modo,tipo,veredicto,
     confianza,detalle}]`, `articulos[{clave,titulo,resultado}]`, `sugerencia{texto,confianza,articulo}|null`.
     Cualquier número puede venir `null`: la UI lo muestra como «—».
   - `POST /api/incidencias/{id}/acciones` devuelve **el detalle actualizado**. Cuerpos que la UI manda: `asignar{tecnico_id}`,
     `responder{texto}`, `comentario_interno{texto}`, `pausar{motivo: espera_usuario|espera_tercero}`, `reanudar`,
     `resolver{nota}`, `reabrir`, `cerrar`, `escalar{motivo, grupo_id?}`, `cambiar_prioridad{prioridad}`.
   - `POST /api/incidencias` (alta manual): `{titulo, resumen?, persona_texto?, categoria, prioridad}`. `persona_texto` es lo que
     escribió quien da el alta (nombre, correo o WhatsApp): el backend la resuelve contra `personas`.
   - `POST /api/chat-web` → `{respuesta, mensajes[], botones[], incidencia{numero}|null, analisis{…}}`; `analisis` es la respuesta
     de §1 sin el texto (`etapa, memoria, intencion, confianza, categoria, categoria_confianza, accion, articulos_usados[{clave,
     titulo,fuente}], senales, juez, latencia_ms`). `mensajes` ya trae el texto partido por párrafos (un globo por párrafo);
     `botones` ya son los textos que la UI envía tal cual como mensaje de la persona.
   - `GET /api/indicadores?desde&hasta` → `{desde, hasta, kpis[{kpi, version, titulo, definicion, sql, unidad, valor, meta,
     sentido: mayor_mejor|menor_mejor, filas[{periodo,valor}] (12 semanas), pide_accion?, detalle?}]}`. **La UI no calcula nada**:
     `valor` del periodo, `meta` y `pide_accion` los decide el backend (la UI solo sube los bloques con `pide_accion`).
   - `POST /api/reportes/preguntar` → `{pregunta, golden{kpi,nombre,version}|null, verificado, sql, resumen, unidad, columnas[],
     filas[][], nota?}`. `golden: null` ⇒ la UI rotula «Sin verificar» y muestra el SQL.
   - `GET /api/estado/{token}` → `{numero, titulo, estado, estado_texto, tecnico (nombre)|null, prioridad, vence_resolucion_en,
     creada_en, ultimo_mensaje_tecnico{ts,texto,autor}|null, puede_responder}`; `POST …/responder {texto}` (≤ 1000 caracteres).
   - `GET /api/tecnicos` y `/api/tecnicos/{id}`: `{id,nombre,nivel,estado,capacidad,carga,correo,whatsapp,foto,grupos[{id,nombre}],
     habilidades[{categoria,nivel}],turnos[{dia_semana,desde,hasta}],ausencia,rendimiento{resueltas_30d,sla_cumplido_pct,
     primera_respuesta_mediana_min}}`. `PUT` acepta además `habilidades[]`, `turnos[]` y `grupo_ids[]` (reemplazan).
2. **Rutas que la UI usa y §2 no lista** (se añaden a §2)
   | Ruta | Rol | Para qué |
   |---|---|---|
   | `GET /api/tecnicos/{id}` | supervisor | Ficha (07) |
   | `GET /api/grupos` | supervisor | `{items[{id,nombre,nivel,escala_a_grupo_id,responsable_tecnico_id,miembros[]}]}` |
   | `GET /api/casos?estado=` · `POST /api/casos/{id}/mensajes {texto}` | tecnico | Lista de conversaciones; escribir **después de tomar** (409 si no se tomó) |
   | `PUT /api/escalamiento/reglas/{id}` | admin | `{activa, modo, condicion, acciones}`; `GET` lo ven supervisor y superiores; cada regla lleva `descripcion` y `disparos_7d` |
   | `GET/PUT /api/usuarios[/{id}]` | admin | Roles y acceso (`{id,email,nombre,rol,activo}`) |
   | `GET/PUT /api/asistente/config` | entrenador | `{nombre, trato: tu\|usted, saludo, umbral_confianza, maximo_pasos_guia, juez_modo, puede{crear_incidencias, consultar_estado, pedir_encuesta, resolver_clave}}` |
   | `GET /api/entrenamiento/cola?estado=` | entrenador | Items `{id,mensaje_id,texto,intencion_modelo,confianza,motivo,estado,ts,caso_id,intencion_correcta}`; `motivo`: `baja_confianza\|pulgar_abajo\|correccion_tecnico\|reapertura` |
   | `POST /api/entrenamiento/{id}/revisar` | entrenador | `{decision: confirmar\|corregir\|descartar, intencion?}` |
   | `GET /api/entrenamiento/estado` · `POST …/reentrenar` · `…/publicar` · `…/descartar` | entrenador | `{publicado, candidato, fase: ninguno\|entrenando\|listo, cambios_pendientes, progreso}`; **publicar rechaza (409) un candidato que empeora** |
   | `GET /api/calidad` | entrenador | `{semanas[], confianza_media[], pulgar_abajo_pct[], contencion_pct[], modelos[]}` (12 semanas) |
   | `GET /api/reportes` | gerencia | Biblioteca `{items[{id,nombre,descripcion,golden,programado}]}` |
   | `GET /api/buscar?q=` (opcional) | tecnico | Hoy el ⌘K combina listados existentes en el cliente; un endpoint único ahorra 4 llamadas |
3. **`/api/eventos` (SSE)**: la UI lo abre con `fetch` y `Authorization: Bearer` (un `EventSource` no puede mandar la cabecera),
   así que no hace falta `?token=`. Entiende bloques con `event:` o `data:`; ignora los comentarios `: ping`. Detrás de nginx:
   sin búfer (`proxy_buffering off`, `X-Accel-Buffering: no`) y `proxy_read_timeout` largo.
4. **Texto y formato**: los mensajes de `error` van en español de Perú para la persona (la UI los muestra tal cual y nunca un
   código HTTP). Fechas ISO UTC; la UI las pinta en hora de Lima. Los decimales salen con punto (`92.4`), como `es-PE`.
5. **Origen cruzado**: con `VITE_API_BASE` apuntando a otro origen, el backend debe responder CORS a `Authorization` y
   `Content-Type` (el mock lo hace). Con el nginx de `web/` (`/api` → backend) no hace falta.

**05-10-2026 · Agente IA (`agente/`).** Propuestas sobre §1; todas son **aditivas**: un backend que las ignore sigue funcionando. Detalle y cifras en `agente/LEEME.md`.

1. **`categoria` y `categoria_confianza` pueden ser `null`** cuando el mensaje no describe un caso (saludo, agradecimiento, consulta de estado sin categoría conocida). Motivo: no inventar una categoría para «hola».
   En Go, `null` se decodifica a la cadena vacía.
2. **`respuesta` nunca es `null` en esta versión.** Con `crear_incidencia`, `consultar_estado`, `pedir_tecnico`, `sigue_igual`, `agregar_dato` y `encuesta`, el agente manda una **frase previa** y el backend le añade el dato fijo
   (número, plazo, técnico, estado). Es el caso «el agente trae una frase previa útil» de §1. Si el backend prefiere armar el texto entero, descarta `respuesta` en esos flujos.
3. **`accion.tipo = "pedir_tecnico"` lleva `accion.incidencia`** (propuesta con `motivo: "pidio_tecnico"`) cuando la persona no tiene una incidencia abierta; el backend la crea y avisa. Si ya hay una abierta, trae
   `accion.numero` y no trae `incidencia`: la petición se suma a esa.
4. **Las solicitudes (acceso, equipo, software) usan `accion.incidencia.tipo = "solicitud"` y `motivo: "sin_articulo"`** (no hay guía que dar). El vocabulario cerrado de `motivo` no tiene un valor aparte.
5. **`accion.datos`** (lista de `{clave, valor}`) acompaña a `accion.dato` en `agregar_dato`: `dato` es el primero; `datos` trae todos los nuevos del mensaje. `valor` es **siempre texto** (las listas se unen con comas). Claves: `aplicacion, mensaje_error, desde,
   equipo, sede, piso, area, impacto, urgencia, impresora, tipo_red, anexo, solicitud, pasos_probados, comentario`.
6. **Encuesta:** se pide con `confirmar_solucion` (el agente devuelve etapa `cierre` y deja `memoria.pendiente = "puntaje"`); el siguiente mensaje con la nota devuelve `accion.tipo = "encuesta"`, etapa `encuesta`, `accion.puntaje` (1–5) y
   `accion.dato = {clave: "puntaje", valor: "5"}`.
7. **Etapa `incidencia`:** el agente la devuelve en el turno en que propone crear la incidencia. Si el turno siguiente llega con `etapa = "incidencia"` y hay una incidencia abierta, el agente lo trata como `seguimiento`.
8. **Campos extra de la respuesta** (el backend puede ignorarlos): `costo_usd` (gasto del LLM de ese turno: es un KPI), `regenerada`, `frases_quitadas` (calidad del asistente), y `analisis`
   (`bitacora`, `top_intenciones`, `nivel`, `p1`, `lo_que_sabemos`, `articulo`, `llm`, `secretos`, `pregunta_siguiente`), que es lo que pinta `POST /api/chat-web` en la consola. `juez.veredictos` puede traer `clasificacion` (veredicto del juez
   local), `rag` (orden por parecido y orden del bandido en sombra), `verificacion` (frases quitadas por el verificador) y `datos_propuestos`.
9. **Campo extra de la petición:** `usar_llm` (bool, por defecto `true`). Solo para pruebas: `false` fuerza el respaldo por código aunque haya clave de LLM. La regresión lo usa.
10. **`POST /conocimiento/recargar` acepta `usos` opcional por artículo** (`{"correo": {"exitos": 12, "fracasos": 3}}`) para el bandido de Thompson. El agente no guarda estado: la fuente de verdad de los éxitos y fracasos es
    `articulo_usos` del backend.
11. **`POST /reentrenar`** (revisado el 05-10-2026, atiende la petición 10 de la pasarela): cuerpo opcional `{"ejemplos": [{"mensaje", "intencion", "categoria"}], "publicar": false, "forzar": false}`. Entrena una versión nueva (`v2`, `v3`…) y la mide
    sobre el conjunto reservado. **Por defecto NO la publica: queda como candidata** con sus cifras (la aprobación humana va por la consola). Con `publicar: true` la publica **solo si no empeora** la actual (ni la exactitud de intención ni la de categoría);
    con `forzar: true` (decisión explícita de una persona) publica aunque empeore. Devuelve `{ok, modelo, publicado, candidato, no_empeora, actual, intencion: {exactitud, f1_macro, antes}, categoria: {...}, ejemplos_extra, motivo}`.
    Los ejemplos que coincidan con el reservado se descartan.
12. **`GET /salud`** devuelve exactamente `{"ok", "modelo", "juez"}`; el detalle (métricas, umbrales, modo del verificador, LLM configurado) está en `GET /metricas`.
13. **Memoria:** además de los campos de ARQUITECTURA §2.2, la ficha lleva `categoria`, `turnos`, `turnos_guia`, `sin_entender` e `intencion_caso`. El backend la guarda tal cual y la devuelve; no debe interpretarla.
14. **`GET /modelos`:** `{publicada, cifras_publicada, candidatos: ["v2"], modelos: [{version, estado: publicada|candidata|anterior, intencion: {exactitud, f1_macro}, categoria: {...}, n_ejemplos_intencion, n_ejemplos_categoria, no_empeora}]}`.
    `no_empeora` compara con la publicada. **`POST /modelos/{version}/publicar`** publica un candidato si no empeora el reservado: 200 `{ok, modelo, publicado, actual, no_empeora, intencion, categoria}`; **409** `{codigo: "empeora", ...cifras}` si empeora
    (cuerpo `{"forzar": true}` = decisión de una persona); 404 `no_existe`; 409 `conflicto` si hay un reentrenamiento en curso. La versión ya publicada responde 200 sin cambiar nada.
15. **`sugerencia_tecnico` en la respuesta de `POST /chat`** (atiende la petición 11 de la pasarela): `{"texto", "articulo"?}` o `null`, **con la forma que ya lee la pasarela** (objeto, no cadena; un texto suelto se perdería en silencio). `texto` es un borrador breve que el
    técnico podría enviar a la persona, armado por código desde el artículo o la ficha (nunca por el LLM): hasta 3 pasos del artículo que mejor encaja con el síntoma y que la persona aún no vio (`articulo` = su clave; solo pasos del artículo y nunca en un P1), o el dato que
    falta, o un acuse neutro; sin plazos ni promesas. Solo con el caso en manos de la mesa (etapa `incidencia` o `seguimiento`) y síntoma en la ficha; si no, `null`. No lleva `confianza` (no hay una medida honesta de ella).
16. **`GET /conocimiento/articulos`:** `{"articulos": [{clave, titulo, categoria, sintomas, pasos, cuerpo, supuesto: true}]}` con los 20 artículos del seed (`agente/seed/articulos.json`, todos SUPUESTO), siempre los del seed aunque después se hayan recargado otros. La pasarela los carga en
    su tabla cuando está vacía y los devuelve por `POST /conocimiento/recargar`.
17. **`costo_usd`, `regenerada` y `frases_quitadas` van en la raíz de la respuesta** (ya iban; el punto 8 los daba como extras). `frases_quitadas` cuenta lo que se quitó **de verdad**: con el verificador en `sombra` (el defecto, ver 18) es 0 y lo que habría quitado queda en `juez.veredictos.verificacion`.
18. **`VERIFICAR_MODO` por defecto = `sombra`** (AGENTS §1.4 regla 6: nada nuevo decide sin pasar por sombra). Corrige lo que el agente declaró el 05-10-2026 (`activo`). `activo` se pide por entorno cuando una cifra con tráfico real lo justifique; lo muestra `GET /metricas` (`verificar.modo`).

**05-10-2026 · Pasarela (pasarela/, OCaml).** Detalle en `pasarela/LEEME.md`. Probado contra el motor y el agente reales (`pasarela/scripts/e2e-docker.sh`).

1. **Webhook:** `POST /webhook/evolution` **y** `POST /webhook/evolution/{secreto}` (como en kddesign). El secreto va en la ruta, en `?secreto=` o en la
   cabecera `X-Webhook-Secret`; se compara en tiempo constante. Responde 200 de inmediato (`{recibido, ignorado?}`) y procesa en segundo plano; un payload raro
   también da 200 para que evolution-go no reintente. Entiende evolution-go (`event: Message`) y Evolution API v2 (`messages.upsert`).
2. **Índices que crea la pasarela** (solo índices, idempotentes, al arrancar; no tocan el esquema del Arquitecto): `mensajes_wa_id_uq` (único sobre
   `meta->>'wa_id'`: deduplica el webhook), `mensajes_recordatorio_uq` (único sobre `meta->>'recordatorio_clave'`), `decisiones_aviso_idx`,
   `decisiones_caso_idx`, `casos_persona_idx`, `incidencias_caso_idx`, `auditoria_objeto_idx`, `articulo_usos_caso_idx`.
3. **Rutas que se añaden a §2** (la UI las usa o el flujo las necesita): `POST /api/casos/{id}/devolver` (el asistente vuelve a atender), `POST /api/casos/{id}/mensajes`,
   `GET /api/buscar?q=` (⌘K), `GET/POST/PUT /api/usuarios[/{id}]`, `GET/PUT /api/avisos/plantillas` (plantillas configurables de los avisos), `GET/PUT /api/asistente/config`,
   `GET /api/entrenamiento/estado`, `POST …/reentrenar|publicar|descartar`, `GET /api/calidad`, `GET /api/reportes`, `GET /api/tecnicos/{id}`, `PUT /api/grupos/{id}`.
   `GET /api/escalamiento/reglas` lo ve el **supervisor** (como pide la UI); `PUT`, solo admin. Cambiar la condición o las acciones de una regla crea una **versión nueva**
   (la anterior queda inactiva: `escalamientos` es único por incidencia+regla+versión); `activa` y `modo` se cambian en el sitio.
4. **Errores:** además de `no_autorizado|no_encontrado|invalido|conflicto`: `limite` (429), `no_disponible` (503, el motor no responde) e `interno` (500). 413 lleva `invalido`.
   El rol manda por la **base** (un usuario desactivado o con otro rol surte efecto al instante); el del token no se usa.
5. **Respuesta del agente (§1), lo que la pasarela lee además de lo escrito:** `regenerada` (bool), `frases_quitadas` (int) y `costo_usd` en la raíz (o dentro de `juez`): alimentan la
   golden `calidad_asistente`; `botones` (opcional) para el chat web; `juez.veredictos` como `{tipo: {veredicto, confianza, detalle?}}` — lo que no trae `veredicto` (el orden del bandido,
   p. ej.) se guarda en `decisiones` con su propio `componente`, no como veredicto del juez. Una `accion.tipo` desconocida se trata como `ninguna` y se anota.
6. **Escrituras que la pasarela hace y §5 no listaba:** `articulo_usos` (`resolvio` / `sigue_igual`, desde las claves de `articulos_usados`), `etiquetas_revision` (cola de revisión: baja confianza,
   👎 y correcciones), `modelos` (candidato del reentrenamiento) y `pares_preferencia` (cuando el técnico edita la sugerencia). `decisiones.componente`: `asistente`, `juez`, `agente` (caída),
   `entrega` (mensaje perdido), `aviso_enviado` (idempotencia de avisos), `rag`. `feedback.senal` añade `encuesta` (valor = puntaje). `mensajes.rol = 'sistema'` para los avisos y recordatorios que arma el código.
7. **Encuesta (Cambios de Datos 4 y 8):** al enviarla (etapa `encuesta` del agente) se inserta la fila con `puntaje` NULL y se encola `enc-<id>`; la respuesta actualiza la fila y reencola la misma clave con `ts` = envío.
   `casos_estado.version` = `GREATEST(ultimo_mensaje, último cambio de una incidencia suya)` y la pasarela sube `casos.ultimo_mensaje` al cambiar el estado de un caso sin mensaje nuevo. Tras la encuesta, un caso
   `resuelto_asistente` **se queda** así (si no, la contención del asistente dejaría de contarlo); el resto pasa a `cerrado`. `confirmado_resuelto` = existe un `feedback se_resolvio` del caso.
8. **Interpretaciones (SUPUESTO, ajustables):** `pedir_tecnico` abre una incidencia con `motivo=pidio_tecnico` o, si ya hay una abierta, le agrega `dato_agregado(pide_tecnico)`; no escala por nivel. `confirmar_solucion`
   solo cierra (con el motor) una incidencia `resuelta`. Un usuario de consola sin técnico vinculado actúa como `{tipo: sistema, id: consola:<id>}` y **no puede `responder`**. Los avisos `canal=correo` salen por
   WhatsApp si hay número (no hay envío de correo). Los avisos de la semilla (`error` = `semilla_sintetica…`) no se envían ni se marcan.
9. **Pasarela → motor:** usa `GET /interno/incidencias/duplicada`, `POST /interno/incidencias`, `…/acciones` (incluida `queja`), `POST /interno/sla/calcular` (un lote por lista), `GET /interno/avisos/pendientes`,
   `POST /interno/avisos/{id}/marcar`, `GET /interno/golden[/{kpi}]` y `GET /interno/salud`. No usa `…/resuelta` (la incidencia resuelta se encuentra por Postgres). Indicadores: `valor` y las 12 semanas
   salen de la golden de cada KPI (caché de 5 min); `meta` es el primer número de `objetivo`; `sql` va vacío (el motor no expone el SQL).
10. **Entrenamiento y modelos (agente):** `POST /reentrenar` se llama con `{ejemplos (revisados), publicar: false}`: el agente mide sin publicar y la pasarela guarda el candidato en `modelos` (cifras de `intencion.exactitud` / `intencion.f1_macro`);
    `GET /modelos` (`{actual, modelos: [{version, publicado?, intencion: {exactitud, f1_macro}}]}`, o la lista sola) se sincroniza con `modelos` (mejor esfuerzo, cada 30 s como máximo). «Publicar» de la consola: la pasarela rechaza (409) un candidato que empeora y luego
    pregunta al agente (`POST /modelos/{version}/publicar`): un 409/422 (o un 200 con `publicado: false`) se devuelve a la consola con el motivo del agente; si no responde, 503; solo si lo acepta se refleja en `modelos`. `POST /conocimiento/recargar` lleva `usos`
    por categoría desde `articulo_usos` (la categoría del **caso**). `GET /conocimiento/articulos` (`{articulos: [...]}` o lista; 404 = agente viejo, se ignora) siembra `articulos` cuando está vacía, con `supuesto = true`.
11. **`sugerencia_tecnico: {texto, confianza?, articulo?}`** en la raíz de `/chat` (opcional): se guarda en `mensajes.meta` del mensaje del asistente y el detalle de la incidencia devuelve la del último mensaje del caso que la traiga, mientras ningún técnico haya contestado después. La persona no la ve.
    `GET /api/calidad` suma `frases_quitadas_pct`, `regeneradas_pct`, `costo_usd_por_caso`, `exactitud_por_version` y `fuente`: golden `calidad_asistente`/`contencion_asistente` si el motor responde; si no, cifras operativas de Postgres (`fuente.oficial = false`).
12. **Encuesta con el agente real:** el agente pide la nota con etapa `cierre` y `memoria.pendiente = "puntaje"`; la pasarela envía la encuesta (fila con `puntaje` NULL) cuando ve esa pendiente o la etapa `encuesta`,
    y el `analisis` extra del agente viaja en `analisis.agente` del chat web.
13. **Pasada de la consola web contra la pasarela real** (motor y agente reales, semilla de 120 incidencias; Bandeja, Detalle, Chat, Incidencias, Conversaciones, Equipo, Escalamiento, Indicadores, Reportes, Asistente, Ajustes y Estado público en 1280 px y 393 px, sin un solo
    HTTP ≥ 400 ni error de consola). Lo que **difiere del mock** y la UI debe saber: (a) `memoria` es la ficha del agente tal cual: `{etapa, pendiente, sabemos: {sintoma, aplicacion, equipo, …, pasos_probados}, articulos_mostrados, intentos_guia, …}`,
    no un mapa plano; la UI imprime hoy `sabemos` como un objeto en una línea (conviene aplanar `memoria.sabemos` en «Memoria» y en el cajón del chat). (b) `juez.veredictos` trae lo que mande el agente (p. ej. `rag` con `orden_puro`/`orden_bandido`, sin `veredicto`).
    (c) `condicion` de una regla trae `tipo`, `metrica`, `umbral_pct`; la pasarela la **muestra también como `porcentaje`** y acepta `porcentaje` al guardar (lo guarda como `umbral_pct`); si el guardado no cambia nada no crea versión. (d) La tabla `articulos` nace vacía: los 20 artículos de ejemplo
    viven en el seed del agente, no en Postgres (Conocimiento sale con «0 artículos»). (e) Con ClickHouse sin configurar, Indicadores muestra por KPI «ClickHouse no está configurado» (el mensaje del motor). (f) `/api/yo` y el login traen también `email`.
6. **Ajuste tras ver la consola contra la pasarela (Diseño UI).** La consola ya tolera la forma real: `memoria` = `{sabemos:{…}, pendiente,
   articulos_mostrados, intentos_guia, …}` se aplana con etiquetas legibles (también acepta una ficha plana); en `juez.veredictos` solo
   son veredictos las claves con `veredicto` o `confianza`, el resto (`rag`, `datos_propuestos`…) va bajo «Otros datos»; reglas de
   escalamiento: el porcentaje se lee de `umbral_pct` (o `condicion.umbral_pct` / `condicion.porcentaje`) y se **guarda con los dos
   nombres**; las acciones que ofrece son las del motor (`avisar_tecnico, escalar_nivel, avisar_responsable, avisar_supervisor,
   avisar_guardia, nota`); un KPI con `valor: null` y `detalle` se pinta como «Sin cifra» con esa línea, sin gráfica vacía.
