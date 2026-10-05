# jsrbot

Mesa de ayuda con asistente conversacional por WhatsApp y web: gestor de incidencias, personal técnico,
escalamiento, KPI, entrenamiento y reportería en ClickHouse con *golden queries*. Se construyó a partir de
[ddesign-k](https://github.com/davrv93/ddesign-k) (el asistente de ventas de Baruka), adaptado a soporte técnico.

> **Estado (05-10-2026): construido y probado en local; no desplegado.** Faltan el despliegue, los respaldos y la
> revisión de seguridad (F9) y el piloto (F10). Todos los datos de entrenamiento, la semilla y los artículos de
> ejemplo son **sintéticos** y están marcados `SUPUESTO:`: las cifras de exactitud no prometen rendimiento con
> personas reales. WhatsApp arranca en **modo simulado** (no envía nada a nadie).

## Cómo está hecho

```
 Persona ── WhatsApp ──► evolution-go ──webhook──┐
 Persona ── chat web ────────────────────────────┤
                                                 ▼
 Consola (Qwik, nginx) ──/api──► pasarela (OCaml) ──/chat──► agente (Python)
                                    │   ▲                      clasificador e5 · memoria · etapas
                                    │   └─ avisos, SSE         RAG · verificador · Jev local (opcional)
                                    ▼
                          motor (Go) ──────────► Postgres (fuente de verdad)
                  incidencias · SLA · despacho        │ outbox
                  vigía · escalamiento · golden       ▼
                                                 ClickHouse (solo reportes; se puede reconstruir)
```

| Carpeta | Servicio | Lenguaje | Qué hace |
|---|---|---|---|
| `backend/` | motor | Go | Incidencias, reloj de SLA en horario laboral, despachador, vigía, reglas de escalamiento, outbox hacia ClickHouse, golden queries. API interna `/interno/*`. |
| `pasarela/` | pasarela | OCaml (Dream) | API de la consola, login y roles, webhook de WhatsApp, flujo del caso, avisos, chat web, estado público. |
| `agente/` | agente | Python (FastAPI) | Clasificador local, ficha del caso, etapas, RAG sobre artículos, verificación de respuestas, Jev local. |
| `web/` | web | Qwik + nginx | Consola estilo Apple (17 pantallas), chat web de prueba con piel de WhatsApp, página pública de estado. |
| `analitica/` | clickhouse | SQL | Esquema, 12 golden queries (un KPI, una definición) con esperados verificados y su prueba. |
| `juez/` | juez (opcional) | llama.cpp | `llama-server` para Jev local. |

Principio de diseño: **los modelos proponen; el código decide.** Prioridad, plazos, asignación, escalamiento y
cierre salen de reglas. El número de incidencia, el plazo y el técnico los escribe código, nunca un LLM.

## Levantar todo

### Requisitos

- Docker con Compose v2 y **al menos 6 GB de RAM libres** para Docker (el stack declara ~3 GB de topes; el build
  del agente y el de OCaml son lo más pesado). Git, `openssl` y `curl`.
- Conexión a internet en el primer build (imágenes base, modelo de embeddings `multilingual-e5-small`, dependencias
  de OCaml, npm).
- Un procesador de 2 núcleos o más. No hace falta GPU.

### Pasos

```bash
git clone https://github.com/davrv93/jsr-vs7.git && cd jsr-vs7

# 1. Secretos al azar en .env (no pisa uno existente y no imprime nada). El .env nunca se sube a git.
./despliegue/generar-env.sh

# 2. Construye las imágenes de UNA en UNA (dos builds a la vez saturan una máquina pequeña).
#    La primera vez tarda: la pasarela compila las dependencias de OCaml (10–25 min) y el agente descarga y
#    entrena el clasificador. Las veces siguientes Docker usa caché.
COMPOSE_PARALLEL_LIMIT=1 docker compose build

# 3. Arranca los seis servicios: postgres, clickhouse, motor, agente, pasarela y web.
docker compose up -d
docker compose ps            # todos deben decir (healthy)

# 4. Crea tu administrador (te pide la clave sin mostrarla; mínimo 12 caracteres).
./despliegue/crear-admin.sh tu@correo.com "Tu Nombre"

# 5. Abre la consola.
open http://127.0.0.1:18580     # en Linux: xdg-open
```

Entra con ese correo y esa clave. El chat de prueba está en el menú de la consola (pantalla 17): escribe «no me
abre el correo», sigue la guía, di «sigue igual, quiero un técnico» y verás cómo se crea la incidencia y aparece
en la Bandeja.

**Datos de ejemplo (opcional).** Carga 3 meses de incidencias sintéticas (600 incidencias, 840 casos) para ver la
consola con datos y los KPI con cifras. Solo funciona sobre una base **vacía**, sin datos reales:

```bash
set -a; . ./.env; set +a
docker run --rm --network jsrbot_net --entrypoint /semilla jsrbot/motor:local \
  -dsn "postgres://jsrbot:${JSR_PG_CLAVE}@postgres:5432/jsrbot?sslmode=disable" -limpiar
```

La semilla es de julio a septiembre de 2026, así que en Indicadores elige «A medida» con ese rango. Sus números
de teléfono y correos son ficticios.

**Apagar.** `docker compose down` conserva los datos; `docker compose down -v` los borra (solo los volúmenes de
jsrbot).

### Si algo no arranca

| Síntoma | Causa y arreglo |
|---|---|
| `all predefined address pools have been fully subnetted` | Docker se quedó sin rangos de red. Añade a `.env`: `COMPOSE_FILE=docker-compose.yml:despliegue/subred.yml` (fija 192.168.64.0/24; cámbiala si ya la usas). |
| `required variable … is missing a value` | Falta una variable en `.env`: bórralo y vuelve a correr `./despliegue/generar-env.sh`, o complétala. |
| La consola carga pero las cifras de Indicadores salen «Sin cifra» | ClickHouse aún arranca o no hay datos en el periodo. `docker compose logs motor` lo explica. |
| El puerto 18580 está ocupado | Cambia `JSR_HTTP_PORT` en `.env` y `JSR_URL_PUBLICA` con el mismo puerto. |
| El build de la pasarela parece colgado | Está compilando OCaml; es lento la primera vez. `docker compose build pasarela --progress=plain` muestra el avance. |

Nunca corras `docker compose config` sin `-q`: imprime los secretos del `.env`.

### WhatsApp, LLM y juez (todo opcional)

- **WhatsApp real.** Por defecto `EVOLUTION_MODO=simulado`: el sistema registra a dónde habría enviado y no envía
  nada. Para usarlo de verdad levanta el perfil `whatsapp` (evolution-go y su Postgres),
  `docker compose --profile whatsapp up -d`, vincula el número en su manager y pon en `.env`
  `EVOLUTION_MODO=real`, `EVOLUTION_API_KEY` (la genera `generar-env.sh`) y `EVOLUTION_INSTANCIA`. Configura el
  webhook de la instancia hacia `http://pasarela:8080/webhook/evolution/<WEBHOOK_SECRET>`. **Pruébalo primero con un
  número tuyo.**
- **Redacción con LLM.** Sin clave, el asistente responde por plantillas y código (determinista y suficiente para
  la regresión). Con `OPENROUTER_API_KEY` en `.env` redacta con un LLM, siempre sobre el caso **enmascarado**
  (sin nombres, correos, teléfonos ni contraseñas).
- **Jev local (juez).** Perfil `juez`: `docker compose --profile juez up -d`, con `JUEZ_URL=http://juez:8080` y
  `JUEZ_MODO=sombra` para el agente. Mira `juez/README.md` antes: el modelo se descarga en el build, y ese Dockerfile **no se ha probado todavía**.
- **Chat web público.** `POST /api/chat-web` es público y crea personas e incidencias. En producción pon
  `CHAT_WEB=0` o déjalo detrás de un proxy con límites.

### Puertos y seguridad

Solo la consola publica un puerto y solo en `127.0.0.1:18580`. Para exponerla usa un nginx con HTTPS delante. El
motor, el agente y las bases no se publican. El motor exige la cabecera `X-Interno-Clave`.

## Pruebas

| Qué | Comando |
|---|---|
| Golden queries contra la semilla (levanta un ClickHouse efímero) | `cd analitica && ./probar_golden.sh` |
| Reconstrucción de ClickHouse desde cero | `cd analitica && ./probar_reconstruccion.sh` |
| Motor Go (levanta un Postgres efímero) | `cd backend && ./scripts/test-db.sh` |
| Pasarela OCaml (en Docker; una sola vez `make cimientos`) | `cd pasarela && make cimientos && make probar` |
| Agente (entrena y corre todo en el build) | `cd agente && docker build -t jsrbot_agente .` |
| Consola (con el mock de la API) | `cd web && npm ci && npm run build && npm test` |

No corras `make probar` y `pasarela/scripts/ui-docker.sh` a la vez: comparten un contenedor de Postgres.

## Documentación

| Documento | Para qué |
|---|---|
| [CONTEXT.md](CONTEXT.md) | Qué es, para quién, glosario, decisiones y preguntas abiertas |
| [AGENTS.md](AGENTS.md) | Reglas de trabajo, equipo de agentes de desarrollo, agentes del producto |
| [CLAUDE.md](CLAUDE.md) | Entrada para Claude Code (remite a los dos de arriba) |
| [SKILLS.md](SKILLS.md) | Skills de diseño (EDISYS) y del proyecto |
| [PLAN_TRABAJO.md](PLAN_TRABAJO.md) | Fases F0–F10 y estado |
| [ARQUITECTURA.md](ARQUITECTURA.md) | Servicios, caso, incidencias, Jev local, datos, ClickHouse |
| [docs/CONTRATOS.md](docs/CONTRATOS.md) | Contratos entre servicios y cambios acordados |
| [DISENO.md](DISENO.md) · [.better-web-ui.md](.better-web-ui.md) | Consola al estilo Apple |
| [docs/INVESTIGACION_JEV_LOCAL.md](docs/INVESTIGACION_JEV_LOCAL.md) | Modelos de juicio open source, con fuentes |
| `LEEME.md` de cada carpeta | Comandos, variables y cifras medidas de esa pieza |

## Pendiente

- F9: servidor, respaldos de Postgres, carga, revisión de seguridad. F10: piloto.
- Sin canal de correo: los avisos por correo salen por WhatsApp si la persona tiene número.
- Jev local solo se midió con modelos sustitutos, no con Qwen3-1.7B; corre en modo `sombra`.
- Preguntas abiertas para la organización (alcance, SLA reales, número de WhatsApp): `CONTEXT.md` §7.

## Licencia

Sin definir. Las skills de diseño de `.agents/skills/` vienen de EDISYS bajo Apache 2.0 (ver `SKILLS.md`).
