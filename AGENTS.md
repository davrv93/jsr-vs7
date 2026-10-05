# AGENTS.md — jsrbot (`jsr-vs7`)

Instrucciones para cualquier agente (Claude Code, Codex, Cline…) y persona que trabaje en jsrbot. Este archivo
tiene tres partes:

1. **Reglas de trabajo** en el repo.
2. **Equipo de agentes de desarrollo**: qué rol construye qué, con qué skills y cuándo termina.
3. **Agentes del producto**: las piezas autónomas que corren dentro de jsrbot y lo que cada una puede y no puede
   decidir.

Estado: **código construido en local** (05-10-2026). Los comandos de la §1.3 funcionan; cada carpeta tiene su `LEEME.md` con cifras reales.

---

## 1. Reglas de trabajo

### 1.1 Lectura obligatoria, en este orden

1. [`CONTEXT.md`](CONTEXT.md): qué es, glosario, decisiones, preguntas abiertas.
2. Este archivo.
3. [`PLAN_TRABAJO.md`](PLAN_TRABAJO.md): en qué fase estamos y qué toca.
4. [`ARQUITECTURA.md`](ARQUITECTURA.md): antes de tocar backend, agente o datos.
5. [`.better-web-ui.md`](.better-web-ui.md) y [`DISENO.md`](DISENO.md): antes de tocar cualquier interfaz.
6. [`SKILLS.md`](SKILLS.md): qué skill cargar para la tarea.

### 1.2 Estructura (propuesta)

```
jsr-vs7/
  backend/        Go, el «motor»: incidencias, SLA, asignación, escalamiento, vigía, outbox, golden queries (API interna /interno/*)
  pasarela/       OCaml: API de la consola, auth y roles, webhook de WhatsApp, flujo del caso, avisos, chat web, estado público
  agente/         Python (FastAPI): clasificador, memoria, etapas, RAG, redacción, Jev local
  juez/           llama.cpp server con el modelo de Jev local (contenedor aparte)
  web/            Qwik: consola de la mesa, chat web de prueba, página pública de estado
  analitica/      ClickHouse: esquema, vistas materializadas, golden queries y sus pruebas
  despliegue/     docker-compose, nginx, scripts de respaldo
  referencias/    copias de Baruka (no se editan)
  .agents/skills/ skills de diseño (EDISYS) y del proyecto
```

### 1.3 Comandos (convención)

| Qué | Comando |
|---|---|
| Levantar todo en local | `docker compose up -d` |
| Pruebas del motor (Go) | `cd backend && ./scripts/test-db.sh` |
| Pruebas de la pasarela (OCaml, en Docker) | `cd pasarela && make probar` |
| Pruebas del agente (corren también en el build) | `cd agente && python -m app.prueba_memoria && python -m app.prueba_etapas && python -m app.prueba_estructurado` |
| Regresión del asistente | `cd agente && python -m app.regresion` |
| Evaluación de Jev local | `cd agente && python -m app.evaluar_juez` |
| Golden queries contra el conjunto de prueba | `cd analitica && ./probar_golden.sh` |
| Validar la consola | `cd web && npx tsc --noEmit && npm run build && npm test` |

### 1.4 Reglas que no se negocian

**Datos y seguridad**

1. **Nunca imprimas secretos** (`.env`, claves de API, tokens). Comprueba que existen con un booleano:
   `awk -F= '{print $1, (length($2)>0?"set":"EMPTY")}' .env`.
2. **Datos personales enmascarados** antes de salir del servidor: nombres, correos, DNI, teléfonos, y cualquier
   cosa con forma de contraseña o token que el usuario pegue en el chat. Al LLM externo nunca le llega una
   contraseña; al Jev local sí puede llegarle porque no sale del servidor.
3. **No mandes mensajes de WhatsApp** a números reales para probar. Usa el chat web de prueba. Para un número real,
   pregunta antes y describe el destino.
4. **No inventes datos de la organización** (SLA, horarios, sedes, nombres de técnicos, procedimientos). Lo que no
   está en la configuración o en la base de conocimiento, el asistente lo deriva a una persona. En el código, un
   supuesto lleva el comentario `SUPUESTO:` y se lista en `CONTEXT.md` §7.

**Decisiones**

5. **Los modelos proponen; el código decide.** Prioridad, SLA, asignación, escalamiento y cierre salen de reglas.
   El clasificador y Jev local aportan señales con su confianza; el LLM solo redacta.
6. **Nada nuevo decide sin pasar por sombra.** Un modelo, una regla de escalamiento o un umbral nuevo se enciende
   primero en modo `sombra` (registra, no actúa) y se mide contra lo que pasó de verdad. Pasa a `activo` con una
   cifra que lo justifique.
7. **Un KPI, una golden query.** Ningún tablero, reporte o respuesta del analista calcula un KPI con SQL propio. Si
   la definición cambia, cambia la golden query, con nueva versión.
8. **ClickHouse no es fuente de verdad.** Se puede borrar y reconstruir desde Postgres. Nunca se escribe en
   ClickHouse algo que no exista antes en Postgres.
9. **Los eventos no se editan.** `incidencia_eventos`, `mensajes` y `decisiones` solo reciben inserciones. Una
   corrección es un evento nuevo.

**Calidad**

10. **No borres pruebas** para que pase una cifra. Si una prueba falla, se arregla el código o el entrenamiento. Si
    la prueba está mal, se corrige con una explicación en el commit.
11. **Mide antes de afirmar.** «Mejora la exactitud» lleva la cifra antes y después, sobre el conjunto reservado.
12. **Validar antes de terminar:** compila, pasan las pruebas de la parte tocada y, si cambia la interfaz, se ve en
    393 px y en escritorio, en claro y en oscuro.

**Interfaz**

13. Lee `.better-web-ui.md` antes de tocar la interfaz. Usa las skills de diseño (`SKILLS.md` §1).
14. **Prohibidos** `window.alert`, `window.confirm` y `window.prompt`. Usa `useDialog()` y `toast()`.
15. Antes de dar por terminada una pantalla, pasa `distill` y `a11y`.

**Repositorio y despliegue**

16. **No despliegues sin orden del usuario.** Una orden de desplegar ya es la autorización: no vuelvas a preguntar.
17. **No pises trabajo ajeno.** El usuario suele tener otra sesión en paralelo. Antes de un commit, revisa `git
    status` y añade solo tus archivos.
18. Commits en español, con el tipo (`feat`, `fix`, `docs`, `chore`…) y la línea de coautoría que indique la
    sesión.

---

## 2. Equipo de agentes de desarrollo

Roles para repartir el trabajo entre agentes en paralelo. Cada uno tiene un alcance cerrado: lo que está fuera se
pide al rol dueño, no se toca.

| Rol | Alcance | Skills | Termina cuando |
|---|---|---|---|
| **Arquitecto** | `ARQUITECTURA.md`, contratos entre servicios (`/chat`, eventos, esquema de Postgres), decisiones (ADR en `docs/decisiones/`) | — | El contrato está escrito y los roles afectados lo aceptan |
| **Backend** | `backend/`: incidencias, SLA, asignación, escalamiento, técnicos, roles, webhook, eventos, API | `jsr-sla`, `jsr-escalamiento` | `go test ./...` en verde, con pruebas del caso nuevo |
| **Agente IA** | `agente/`: clasificador, memoria, etapas, RAG, redacción, filtros, integración con Jev local | `jsr-entrenar`, `jsr-regresion` | Pruebas del build y regresión en verde; cifras en el log |
| **Juez** | `juez/` y `agente/app/juez.py`: modelo, prompts, gramáticas, calibración, sombra | `jsr-jev-local` | Evaluación con exactitud y calibración medidas sobre el conjunto dorado |
| **Datos** | `analitica/`: esquema de ClickHouse, réplica desde Postgres, vistas materializadas, golden queries | `jsr-golden-query` | `probar_golden.sh` en verde; cada KPI con su definición |
| **Diseño UI** | `web/`, `.better-web-ui.md`, `DISENO.md` | skills de diseño (`SKILLS.md` §1) | Pantalla con estados reales (carga, vacío, error), `distill` y `a11y` pasados |
| **QA** | Pruebas de punta a punta, regresión, carga, datos sintéticos | `jsr-regresion`, `test` | Informe con lo que falla, reproducible |
| **Revisor de seguridad** | Revisión de cada cambio que toca datos personales, autenticación, roles o salida a servicios externos | `security-ux` | Lista de hallazgos con severidad, o «sin hallazgos» |

**Coordinación:** un rol que necesita cambiar un contrato abre la propuesta en `docs/decisiones/` y espera al
arquitecto. Dos agentes no editan el mismo archivo a la vez: el plan asigna cada archivo nuevo a un rol.

---

## 3. Agentes del producto

Piezas autónomas que corren dentro de jsrbot. Para cada una: qué decide, qué solo propone y qué tiene prohibido.

### 3.1 Asistente (agente conversacional)

- **Hace:** atiende el caso por WhatsApp o web; entiende, pregunta lo que falta, guía con la base de conocimiento,
  abre la incidencia, informa estados, pide la confirmación y la encuesta al cerrar.
- **Decide (con reglas):** la etapa del caso, la siguiente pregunta, cuándo ofrecer un artículo, cuándo abrir
  incidencia.
- **Propone:** tipo, categoría, impacto y urgencia de la incidencia (el backend calcula la prioridad).
- **Prohibido:** prometer plazos que no salgan del SLA; dar pasos que no estén en un artículo; pedir contraseñas;
  cerrar una incidencia sin confirmación del usuario o de un técnico.

### 3.2 Jev local (juez)

- **Hace:** (a) clasifica con todo el contexto cuando el clasificador local duda; (b) revisa la respuesta del LLM
  antes de enviarla: quita lo que no está respaldado por la fuente y comprueba que contesta lo preguntado.
- **Propone:** intención, datos extraídos, veredictos con su confianza.
- **Prohibido:** decidir la etapa, la prioridad o el escalamiento. Sus veredictos son señales.

### 3.3 Despachador (asignación)

- **Hace:** elige técnico o grupo para cada incidencia: por categoría y habilidad, disponibilidad (turno, ausencia),
  carga actual y antigüedad de la última asignación.
- **Decide:** la asignación inicial, con reglas configurables.
- **Prohibido:** asignar a alguien fuera de turno, salvo P1 con guardia.

### 3.4 Vigía de SLA (escalamiento)

- **Hace:** cada minuto revisa los plazos de las incidencias abiertas. Aplica la matriz de escalamiento: aviso al
  75 % del plazo, escalamiento al 100 %, P1 inmediato a la guardia, reapertura y queja a supervisión.
- **Decide:** escalamientos y avisos, según reglas versionadas.
- **Prohibido:** cerrar, cambiar la prioridad o reasignar fuera de la matriz. Cada acción deja un evento.

### 3.5 Analista (reportes en lenguaje natural)

- **Hace:** responde preguntas como «¿cuál fue el MTTR de impresoras en septiembre?».
- **Cómo:** busca primero en el catálogo de golden queries. Si hay una que responde, la usa con sus parámetros. Si
  no, propone un SQL nuevo marcado «sin verificar», con las golden queries como ejemplos.
- **Prohibido:** escribir en ClickHouse, consultar Postgres directamente, presentar como KPI oficial un SQL que no
  es golden query.

### 3.6 Entrenador (ciclo de mejora)

- **Hace:** reúne las señales (👍/👎, encuesta, correcciones de técnicos, reaperturas, escalamientos, confianza
  baja) y arma la cola de revisión semanal. Con lo revisado propone frases nuevas, artículos nuevos y pares de
  preferencia.
- **Decide:** nada solo. Un reentrenamiento se publica cuando una persona lo aprueba y la evaluación supera la
  versión actual.

---

## 4. Privacidad de los datos que salen del servidor

| Destino | Qué sale | Qué nunca sale |
|---|---|---|
| LLM de redacción (OpenRouter) | El caso enmascarado: síntoma, pasos probados, artículo, últimos turnos | Nombres, correos, DNI, teléfonos, contraseñas, tokens, IP internas |
| Jev local | Todo (no sale del servidor) | — |
| ClickHouse | Eventos con identificadores internos; texto de mensajes solo si `ANALITICA_TEXTO=1` | Contraseñas y tokens detectados (se reemplazan por `[oculto]` al guardar el mensaje) |
| Avisos (WhatsApp, correo) | Número de incidencia, estado, técnico, plazo | Notas internas |
