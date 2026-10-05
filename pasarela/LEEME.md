# pasarela · API de la consola, WhatsApp y flujo del caso (OCaml)

Servicio en **OCaml** (Dream + Lwt + Caqti) que está entre las personas y el resto de jsrbot. Contrato: [`docs/CONTRATOS.md`](../docs/CONTRATOS.md)
§1 (agente), §2 (la API que sirve), §4 (analítica) y §5 (el motor). Su entrada en «Cambios» dice dónde se aparta o completa el contrato.

| Hace | Cómo |
|---|---|
| API de la consola (`/api/*`) | Lee Postgres directo; **toda mutación de una incidencia pasa por el motor** (`/interno/*`). El SLA de cada fila sale del motor en un solo lote |
| Webhook de WhatsApp | `POST /webhook/evolution`: secreto, deduplica por id, ignora grupos y mensajes propios; audio e imagen reciben un aviso amable |
| Flujo del caso | persona → caso (sesión nueva tras 6 h) → [pausa por técnico] → agente (`POST /chat`, un reintento) → guardar → ejecutar la acción → responder |
| Texto fijo | El número, el técnico, el plazo y el estado los escribe **el código** (`src/textos.ml`), nunca el LLM |
| Avisos | Sondea `GET /interno/avisos/pendientes`, rinde la plantilla (sin notas internas), envía por evolution-go y marca. La pasarela es el **único emisor** |
| Analítica | Cada INSERT en `mensajes`, `casos`, `encuestas` o `feedback` encola en `outbox_analitica` **en la misma transacción**, con el formato de §4 |
| Seguridad | JWT HS256 (12 h), PBKDF2-HMAC-SHA256 (600 000 iteraciones, con sal), roles, límites de intentos, CORS cerrado, cabeceras, cuerpos acotados, secretos en tiempo constante, teléfonos enmascarados en el registro |

## Comandos (todo en Docker; en el Mac no hay OCaml)

```bash
cd pasarela
make cimientos   # una vez (≈ 5 min): imagen jsr/pasarela-cimientos con OCaml 5.1 y las dependencias compiladas
make construir   # compila en modo release -> dist/pasarela (ELF de Linux musl)
make probar      # 91 pruebas: unitarias + de flujo + de la API, contra un Postgres efímero (postgres:16-alpine) con backend/migrations
make imagen      # imagen final jsr/pasarela:local (Alpine, usuario 10001, 43 MB, HEALTHCHECK con el propio binario)
make humo        # arranca la pasarela con el motor y el agente FALSOS y recorre login -> bandeja -> detalle -> acción -> chat web -> ...
make e2e         # punta a punta con el motor Go y el agente Python REALES (imágenes jsrbot/motor y jsrbot_agente)
make carga N=50  # N conversaciones del chat web en paralelo (3 turnos) con agente y motor falsos
scripts/ui-docker.sh arrancar   # todo real (motor, agente, semilla, pasarela en http://127.0.0.1:18480) para usar la consola: cd web && BACKEND_URL=http://127.0.0.1:18480 npm run dev
```

`make probar` y `make humo` levantan y apagan solos un Postgres sin puertos publicados. Para iterar rápido: `scripts/en-cimientos.sh dune build` (el
código va montado y la compilación queda en el volumen `jsr-pasarela-build`).

## Variables de entorno (sin valores)

La lista completa, comentada y sin valores, está en [`.env.ejemplo`](.env.ejemplo).

**Obligatorias** (el arranque lista TODAS las que falten y sale con código 2):
`DATABASE_URL` · `JWT_SECRET` (≥ 16 caracteres) · `MOTOR_URL` · `MOTOR_CLAVE` (≥ 16, la misma del motor) · `AGENTE_URL` · `WEBHOOK_SECRET`.

| Variable | Por defecto | Para qué |
|---|---|---|
| `PORT` | 8080 | Puerto HTTP |
| `EVOLUTION_MODO` | `simulado` | `simulado`: **no envía nada**, solo registra el destino enmascarado. `real`: envía de verdad y **exige** `EVOLUTION_URL`, `EVOLUTION_API_KEY` y `EVOLUTION_INSTANCIA` (AGENTS §1.4 regla 3) |
| `ANALITICA_TEXTO` | 0 | `1`: el texto de los mensajes viaja a ClickHouse. Con 0 sale `texto = ""` |
| `BASE_URL_PUBLICA` | vacía | Prefijo público de la consola, p. ej. `https://…/jsr`: arma el enlace `…/estado/<token>` que se manda a la persona |
| `CORS` | vacía | Orígenes permitidos, separados por comas. Vacía = ningún origen cruzado. `*` solo para desarrollo |
| `CHAT_WEB` | 1 | `0` apaga `POST /api/chat-web` (es público por contrato y crea personas e incidencias: en producción, apágalo o ponlo detrás de nginx) |
| `CONFIAR_PROXY` | 0 | `1` detrás de nginx: la IP del cliente sale de `X-Real-IP` o de la **última** `X-Forwarded-For` |
| `JWT_HORAS` · `PBKDF2_ITER` | 12 · 600000 | Vida del token; costo del hash (va dentro de cada hash: subirlo no invalida claves viejas) |
| `SESION_HORAS` | 6 | Silencio tras el cual el siguiente mensaje abre un caso nuevo |
| `AGENTE_TIMEOUT_S` · `MOTOR_TIMEOUT_S` · `EVOLUTION_TIMEOUT_S` | 30 · 15 · 30 | Plazos duros de cada cliente |
| `SALIDA_ESPACIADO_MS` | 900 | Pausa entre mensajes a un mismo chat |
| `HISTORIAL_TURNOS` | 10 | Mensajes previos que se mandan al agente |
| `RECORDATORIO_CIERRE_HORAS` · `RECORDATORIO_ENCUESTA_HORAS` | 24 · 12 | Cuándo recordar la confirmación de cierre y la encuesta |
| `ESTADO_CADUCA_DIAS` | 30 | Un enlace de estado público de una incidencia cerrada caduca |
| `POOL_CONEXIONES` · `MIGRAR` · `TRABAJADORES` | 8 · 1 · 1 | Conexiones a Postgres; aplicar los índices propios al arrancar; avisos/recordatorios/sondeo |
| `PASARELA_ADMIN_CLAVE` | — | Solo para `crear-admin` (la clave **no** va por argumento: se vería en `ps`) |

El registro de arranque dice «definida / VACIA» por cada secreto; nunca el valor.

## Primer usuario

```bash
PASARELA_ADMIN_CLAVE=… DATABASE_URL=… pasarela crear-admin --email admin@organizacion.pe --nombre "Administrador" --rol admin
# o la clave por stdin (primera línea). Roles: tecnico, supervisor, gerencia, entrenador, admin.
# Para que un usuario pueda RESPONDER como técnico hay que vincularlo: PUT /api/usuarios/{id} {"tecnico_id": …}
```

## Apuntar la consola web (`web/`) a esta API

```bash
# desarrollo: la consola en :5173 y la pasarela en :8080
CORS=http://localhost:5173 …            # en la pasarela
VITE_API_BASE=http://localhost:8080 npm run dev   # en web/ (o al compilar)
```

En producción, con nginx delante, no hace falta CORS: `location /api/ { proxy_pass http://pasarela:8080; }`, y para los eventos en vivo:
`proxy_buffering off; proxy_read_timeout 1h;` (la pasarela ya manda `X-Accel-Buffering: no` y un latido cada 20 s). Con `CONFIAR_PROXY=1` y
`proxy_set_header X-Real-IP $remote_addr;`. El webhook de evolution-go apunta a `http://pasarela:8080/webhook/evolution/<WEBHOOK_SECRET>`
(o a `/webhook/evolution` con la cabecera `X-Webhook-Secret`).

## Rutas

Públicas: `POST /api/auth/login` · `GET /api/salud` · `POST /api/chat-web` · `GET /api/estado/{token}` · `POST /api/estado/{token}/responder` ·
`POST /webhook/evolution[/{secreto}]`.
Con sesión (rol mínimo): `GET /api/yo`, `/api/bandeja`, `/api/incidencias[/{id}]`, `POST /api/incidencias`, `POST /api/incidencias/{id}/acciones`,
`GET /api/buscar` (tecnico) · `GET /api/casos`, `/api/casos/{id}/mensajes`, `/api/eventos` (tecnico o entrenador) · `POST /api/casos/{id}/tomar|devolver|mensajes`
(tecnico) · `/api/tecnicos`, `/api/grupos`, `GET /api/escalamiento/reglas` (supervisor) · `/api/categorias`, `/api/calendarios`, `/api/sla`, `/api/matriz`,
`PUT /api/escalamiento/reglas/{id}`, `/api/usuarios`, `/api/avisos/plantillas` (admin) · `/api/articulos`, `/api/asistente/config`, `/api/entrenamiento/*`,
`/api/calidad` (entrenador) · `/api/indicadores`, `/api/reportes`, `POST /api/reportes/preguntar` (gerencia). El administrador puede todo.
Errores: `{"error": "texto en español", "codigo": "no_autorizado|no_encontrado|invalido|conflicto|limite|no_disponible|interno"}`; listas: `{items, total}` con
`?pagina=&por_pagina=` (hasta 200).

## Decisiones de diseño que conviene saber

- **SQL siempre parametrizado.** Ningún valor de usuario toca el texto SQL: los valores viajan en un único parámetro JSON y el SQL los lee con
  marcadores `$nombre`, `$i:id`, `$b:flag`… (`src/db.ml`). Las consultas devuelven JSON hecho por Postgres, así que no hay un tipo OCaml por consulta.
- **El agente propone, el código decide** (`src/acciones.ml`): crear incidencia (primero `duplicada`; si hay, `agregar_dato`), consultar estado, pedir técnico,
  confirmar solución (cierra solo si la incidencia está «resuelta»; si no, anota el dato y un técnico decide), «sigue igual» (reabre una resuelta), encuesta.
  Si el motor no responde **no se finge**: se le dice a la persona que no se pudo registrar.
- **Agente caído** (dos intentos): mensaje de cortesía honesto y derivación: se abre una incidencia (o se agrega el mensaje a la abierta). El mensaje se guarda con
  las credenciales ocultas por la propia pasarela.
- **Pausa por técnico:** el asistente no responde; el mensaje llega a la incidencia como comentario de la persona. Un caso pausado **con una incidencia abierta** no
  caduca a las 6 h. `responder` desde la consola pausa el caso; `resolver` lo devuelve al asistente con la pregunta de cierre abierta.
- **Capa de juicio** (`src/juicio.ml`): revisa lo que propone el agente y lo anota en `decisiones`; en `sombra` (por defecto, `configuracion.juicio_modo`) no cambia nada.
- **Ninguna cifra de KPI se calcula aquí** (AGENTS §1.4 regla 7): indicadores, series, rendimiento por técnico y analista salen de `/interno/golden`.
- **Una instancia.** Los límites de frecuencia, el hub de eventos y los candados por chat viven en memoria. Para varias réplicas habría que moverlos a Postgres.

## Conocimiento, sugerencia y calidad

- **Conocimiento inicial:** si `articulos` está vacía, la pasarela pide `GET /conocimiento/articulos` al agente (una vez al arrancar y cada minuto mientras siga vacía; si el agente está caído o responde 404, solo lo registra una vez y
  sigue), inserta los válidos con `supuesto = true` y `estado = publicado`, y le recarga el conocimiento (`POST /conocimiento/recargar`, con `usos`). No toca una tabla que ya tiene artículos.
- **`sugerencia`** del detalle de incidencia: el agente la manda en `sugerencia_tecnico` (`{texto, confianza?, articulo?}`) en la raíz de `/chat`; la pasarela la guarda en `mensajes.meta` del mensaje del asistente (la persona **no** la ve) y el detalle devuelve
  la del último mensaje del caso que la traiga, mientras ningún técnico haya contestado después. Si el técnico la edita al responder (`sugerencia` en el cuerpo de `responder`), la diferencia queda en `pares_preferencia`.
- **`GET /api/calidad`:** `semanas` (12 lunes de Lima), `confianza_media`, `pulgar_abajo_pct`, `contencion_pct`, `frases_quitadas_pct`, `regeneradas_pct`, `costo_usd_por_caso`, `modelos` y `exactitud_por_version` (desde `modelos`). Son **cifras operativas de Postgres**
  (`mensajes.meta`, `feedback`, `casos`); cuando el motor/ClickHouse responden, las de frases quitadas, regeneradas, costo y contención salen de las golden queries `calidad_asistente` y `contencion_asistente` (la cifra oficial, AGENTS §1.4 regla 7) y `fuente.oficial` lo dice.
  Sin datos, `null` (nunca un cero inventado).

## Qué está probado y qué no

Probado (91 pruebas en verde, más `make humo` y `scripts/e2e-docker.sh`): JWT, roles, PBKDF2 (vectores conocidos), configuración, enmascarado, parseo del webhook (evolution-go
y Evolution API v2), textos y plazos en hora de Lima, el flujo completo del caso con agente y motor falsos (incidencia con texto fijo, duplicada, sesión de 6 h, pausa, agente
caído, motor caído, webhook duplicado y simultáneo, encuesta con `puntaje` NULL → valor, contención), el formato exacto del outbox, cada endpoint con sus validaciones,
los avisos (plantilla editada, tope de intentos, semilla, sin notas internas), los recordatorios idempotentes y el SSE.

**Punta a punta real** (motor Go + agente Python reales, Evolution simulado): chat web con el agente real hasta que el **motor crea** la incidencia (en cola fuera de horario),
asignarse, responder con espera del usuario (reloj pausado), la persona responde desde la página de estado (el motor reanuda), resolver, «sí, ya funciona» por el agente (la pasarela
cierra con el motor) y encuesta; webhook de WhatsApp; avisos enviados y marcados; configuración sobre el esquema que aplica el motor.

No probado o pendiente (honesto):
- **evolution-go real:** el modo `real` se probó contra un servidor de la misma forma (cabecera `apikey`, `POST /send/text`), no contra evolution-go. No se mandó nada a un número real.
- **ClickHouse:** no se levantó en la prueba de punta a punta; los indicadores salen con «ClickHouse no está configurado». La forma de los payloads sí está probada contra el esquema.
- **Canal correo:** los avisos con `canal=correo` salen por WhatsApp si la persona o el técnico tienen número; no hay envío de correo.
- **Modelos:** el agente entrena y mide sin publicar (`POST /reentrenar` con `publicar: false`); la pasarela registra el candidato en `modelos` y sincroniza las versiones con `GET /modelos`. «Publicar» tiene dos llaves:
  la pasarela rechaza (409) un candidato que empeora al publicado y el **agente** decide (`POST /modelos/{version}/publicar`; si lo rechaza, 409 con su motivo; si no responde, 503); solo entonces se refleja en `modelos`.
  Si el agente no tiene esas rutas todavía, «Publicar» no publica nada.
- **`sql` de Indicadores y del analista va VACÍO:** el motor devuelve la definición, no el SQL de la golden query (`GET /interno/golden/{kpi}` y `catalogo.json` solo traen `archivo_sql` y `sha256_sql`). La pasarela ya lo muestra
  en cuanto el motor lo exponga (campo `sql` en el resultado o en el catálogo); no se lee `analitica/golden/*/vN.sql` desde aquí porque la pasarela no tiene esa carpeta.
- **Carga:** `make carga N=50` (50 conversaciones × 3 turnos, agente y motor falsos, 8 conexiones a Postgres): 150/150 con HTTP 200, p50 ≈ 80 ms, p95 ≈ 490 ms por turno (no incluye el agente real, ~70 ms por turno
  sin LLM, ni un LLM de redacción). El apagado con mensajes en vuelo bajo carga no se midió.
