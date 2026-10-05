# web/ · consola de jsrbot

Consola de la mesa de ayuda, chat web de prueba y página pública de estado. Qwik City 1.20 + TypeScript, sitio estático
(adaptador estático) servido por nginx, CSS propio sobre variables (sin Tailwind ni librerías de componentes). Identidad y
reglas: [`../.better-web-ui.md`](../.better-web-ui.md); pantallas y estados: [`../DISENO.md`](../DISENO.md); la API que
consume: [`../docs/CONTRATOS.md`](../docs/CONTRATOS.md) §2 y su sección «Cambios».

## Comandos

```bash
cd web
npm install

npm run mock          # API de pruebas en http://127.0.0.1:5599 (sin dependencias; datos sintéticos «feos»)
npm run dev           # consola en http://localhost:5173, con /api → el mock (o BACKEND_URL=http://host:8080 npm run dev)

npx tsc --noEmit      # tipos
npm run build         # tipos + sitio estático en dist/ (19 páginas)
npm run preview       # dist/ servido por el mock en 5599, con el fallback de /estado/<token> que hace nginx

npm test              # Playwright con el Chrome del sistema, contra dist/ (hay que compilar antes); 58 pruebas
BASE_URL=http://127.0.0.1:19511 npm test      # lo mismo contra un contenedor ya levantado (nginx real)
npm run capturas      # capturas a 393 / 1024 / 1280 / 1600 px, claro y oscuro, en web/capturas/ (dev: :5173; BASE=… para otro origen)
```

**Entradas del mock** (clave de todas: `jsr123`): `admin@jsr.test` (admin; es la técnica Rodrigo Echevarría, por eso tiene
«Mías»), `tecnico@jsr.test`, `supervisor@jsr.test`, `gerencia@jsr.test`, `entrenador@jsr.test`. Cada rol ve su lateral y su inicio.
Estado público: `/estado/ab12cd34ef56ab12cd34ef56ab12cd34`. Chat de prueba: `/chat`.

Control del mock para probar estados (no existe en el backend real):

```bash
curl -X POST :5599/mock/falla    -d '{"ruta":"/api/bandeja","estado":500,"veces":1}'   # la próxima petición falla
curl -X POST :5599/mock/latencia -d '{"ms":3500}'                                       # todo tarda 3,5 s
curl -X POST :5599/mock/evento   -d '{"evento":"incidencia_actualizada","id":142}'      # empuja un evento SSE
curl -X POST :5599/mock/clickhouse -d '{"configurado":false}'                           # indicadores sin cifra («ClickHouse no está configurado»)
```

## Apuntar al backend real (sin tocar código)

| Qué | Cómo |
|---|---|
| Dev con proxy | `BACKEND_URL=http://localhost:8080 npm run dev` (por defecto, el mock) |
| Otro origen para la API | `VITE_API_BASE=https://jsr.ejemplo.pe` al compilar o al arrancar `npm run dev`; el backend debe responder CORS (`Authorization`, `Content-Type`) |
| Mismo origen (lo normal) | nginx de `web/` hace proxy de `/api` → `BACKEND_URL` (por defecto `http://backend:8080`) |
| Detrás de un alias (`/jsrbot/`) | `BASE_PATH=/jsrbot/` al compilar; el alias de nginx quita el prefijo (patrón de kddesign) |

```bash
docker build -t jsrbot-web .                                   # build estático + nginx (probado: 200 en las rutas, proxy y SSE OK)
docker build -t jsrbot-web --build-arg BASE_PATH=/jsrbot/ .
docker run -p 8081:80 -e BACKEND_URL=http://backend:8080 jsrbot-web
```

`nginx/default.conf.template`: `/api` y `/api/eventos` (SSE sin búfer, 1 h) al backend, con DNS dinámico (si el backend está apagado, la
consola arranca y `/api` da 502 hasta que vuelva); `/webhook/` → 404; `/estado/<token>` → la página estática única; caché larga en
`/build` y `/assets`; sin caché en el resto. **Sin CSP**: Qwik inserta scripts en línea y habría que repartir *nonces*.

## Pantallas

Todas tienen carga (esqueleto con la forma real; después de 3 s una línea dice qué espera), vacío (frase + acción), error (palabras
simples, qué no se perdió, «Reintentar»; nunca un código HTTP solo) y sin conexión (barra fina bajo la barra superior; los borradores de
respuesta se guardan en `sessionStorage`). Probadas con los datos feos del mock: asunto de 200 caracteres, incidencia con 80 mensajes,
nombres compuestos, técnicos sin foto, sin habilidades ni turnos, plazos vencidos, grupo sin miembros.

| # | Pantalla | Estado |
|---|---|---|
| 01 | Inicio de sesión | **Completa** · validación, error sin códigos, `?volver=`, cada rol a su inicio |
| 02 | Bandeja | **Completa** · tres grupos, `j` `k` `↵` `a` `e`, plazo naranja al 75 % y rojo en negativo, «Nada vence hoy.» |
| 03 | Detalle de incidencia | **Completa** · resumen, hilo con globos neutros, Responder con «Sugerido» editable, menú ··· (Resolver, Reabrir, Asignarme, Reasignar, Escalar, Pausar, Prioridad, Cerrar), «Más» con 5 vistas |
| 04 | Incidencias | **Completa** · búsqueda, estado, prioridad, responsable, categoría, «Ver más», alta manual |
| 05 | Conversaciones | **Completa** · hilo, tomar la conversación, escribir tras tomarla, devolverla al asistente |
| 06 / 07 | Equipo y ficha | **Completa** · carga, rendimiento, datos, grupos, habilidades, turnos, añadir técnico |
| 08 | Escalamiento | **Completa** · reglas con modo sombra/activo, porcentaje y acciones; pasar a activa pide confirmación |
| 09 | Indicadores | **Completa** · cifra de 48 px, frase, sparkline de 12 semanas, «Definición ▸» con golden query, versión, SQL y tabla; sube la que pide acción |
| 10 | Reportes | **Parcial** · pregunta + «Golden query · nombre vN» / «Sin verificar» + SQL, biblioteca, CSV. **Falta** el explorador (medida, dimensiones, filtros), XLSX y programar el envío por correo |
| 11 | Asistente · Comportamiento | **Completa** · «Guardar y probar» abre el chat |
| 12 | Asistente · Conocimiento | **Completa** · CRUD de artículos, archivar con confirmación, «sin revisar» (supuesto) |
| 13 | Asistente · Entrenamiento | **Completa** · cola, confirmar/corregir/descartar, Reentrenar → comparar → Publicar solo si no empeora |
| 14 | Asistente · Calidad | **Completa** · tres señales de 12 semanas y versiones del modelo |
| 15 | Ajustes | **Completa** · tema, cuenta, SLA, calendario (24 h, feriados), categorías, matriz, roles. **Falta** alta de usuarios, canales/integraciones y SLA por categoría nuevo |
| 16 | Estado público | **Completa** · sin sesión, por token, «Responder» |
| 17 | Chat web de prueba | **Completa** · piel de WhatsApp, respuestas rápidas, botones, cajón de análisis (etapa, ficha, clasificación, Jev local, artículos). Voz, adjuntos y bandeja de emojis no existen (la voz avisa) |

### Pendientes (honestos)

- Reportes: explorador, XLSX, reportes programados por correo.
- Equipo: crear y editar **grupos**; ausencias y guardias solo se ven, no se editan.
- Escalamiento: crear una regla nueva; reproducción histórica («qué habría hecho en sombra») sobre la semilla.
- Ajustes: alta y baja de usuarios; pantalla de canales (WhatsApp); políticas de SLA por categoría nuevas.
- Incidencias: ordenar por columna, exportar, acciones en lote. Detalle: ver capturas de pantalla que mande la persona.
- Conocimiento: historial de versiones y vista previa de cómo lo diría el asistente.
- Entrenamiento: ver y editar los ejemplos y los pares de preferencia; matriz de confusión.
- Contra la pasarela real: la forma de `memoria` (`{sabemos:{…}, pendiente, …}`), de `juez.veredictos` (con claves que no son veredictos,
  como `rag`), de las reglas (`umbral_pct`, acciones del motor) y de los KPI sin cifra («ClickHouse no está configurado») ya está tratada
  y probada con el mock en esa forma. **No se ha corrido la consola contra la pasarela levantada** (`pasarela/scripts/ui-docker.sh`
  comparte el Postgres de `make probar`); las formas son las de `src/lib/tipos.ts` y `../docs/CONTRATOS.md` «Cambios» (Diseño UI).
- Sin pruebas de regresión visual (solo capturas para mirar) ni CSP.

## Decisiones que se apartan de lo escrito (y por qué)

- **Texto en azul `#0066CC`, relleno en `#0071E3`.** `#0071E3` sobre el gris del lateral y de los campos da 3,8:1; `#0066CC` pasa AA. El
  acento sigue siendo uno solo. Igual con la tinta secundaria: `#666669` en vez de `#6E6E73` (daba 4,3:1 sobre la fila abierta y el globo del técnico).
- **Plazo**: por vencer = punto naranja + plazo naranja; vencida = plazo en rojo con signo menos, sin punto. Nunca las dos señales a la vez.
  El texto de color usa `--naranja-texto` / `--rojo-texto` (AA); los puntos usan los de la base.
- **Una sola píldora azul por contexto.** En el detalle de incidencia, «Responder ▸» de la cabecera es texto y lleva al compositor fijo
  abajo, cuyo «Enviar» es la píldora.
- **Horas en 24 h con un campo propio** (`CampoHora`): `<input type="time">` pinta 12 horas en es-PE y corta el «p. m.».
- **Decimales con punto** (`92.4`), como `es-PE`.
- **Navegación con query en un sitio estático.** Qwik City pierde el `?query` cuando el salto cambia de pantalla (el `q-data.json` de cada
  página no lo trae). `irA()` (`src/lib/params.ts`) navega en dos tiempos y `useParam()` lee `window.location` en la primera carga. Los
  detalles (`?inc=`, `?tec=`, `?caso=`) son enlaces reales: se puede abrir en otra pestaña y el botón Atrás funciona.
- **`/estado/<token>`**: una sola página generada (`/estado/_/`); nginx (y el mock con `SERVIR_DIST=1`) reescribe cualquier token a ella y el
  token se lee de la URL en el navegador.
- **SSE por `fetch`** con `Authorization` (un `EventSource` no manda cabeceras). Cada evento recarga en silencio lo que está en pantalla.
- **El armazón se renderiza igual en el servidor y en el cliente** (lateral y barras siempre, visibilidad por CSS): sin saltos de diseño.

## Estructura

```
src/tokens.css          tokens de .better-web-ui.md, claro y oscuro (prefers-color-scheme + <html data-tema>), 8 pt, movimiento reducido
src/ui.css              componentes · armazon.css · pantallas.css · chat.css (piel de WhatsApp, aislada en .wa)
src/lib/                api.ts (cliente), auth.ts (token en memoria + sessionStorage), recurso.ts (carga con 4 estados), format.ts (hora de Lima,
                        vocabulario cerrado), sla.ts, ui.ts (toast() y useDialog()), rutas.ts (guardas por rol), params.ts, buscar.ts, tipos.ts
src/components/ui/      Boton, Grupo/Fila, Cifra, Estado, Segmentado, Hoja, Menu, Dialogo (en anuncios.tsx), Buscador ⌘K, Vacio/Falla,
                        Esqueleto, Campo/Selector/Interruptor/CampoHora, Avatar, Spark, Icono
src/components/         armazon.tsx, maestro.tsx (lista + panel | hoja | pantalla completa), incidencias.tsx, tecnicos.tsx, casos.tsx,
                        ajustes.tsx, kpi.tsx, analisis.tsx
src/routes/             login · chat · estado/[token] · (consola)/{bandeja,incidencias,conversaciones,equipo,escalamiento,indicadores,
                        reportes,asistente/*,ajustes,mas} · 404
mock/                   servidor.mjs (API + SSE + chat + estático) y datos.mjs (semilla fija)
tests/                  *.spec.ts (Playwright) y capturas.mjs
```

Los diálogos nativos están prohibidos (`window.alert/confirm/prompt`): se usa `useDialog()` (alert, confirm, prompt, elegir) y `toast()` de
`src/lib/ui.ts`. Un botón destructivo (`<Boton variante="peligro" confirmar={…}>`) siempre pasa por la confirmación; el foco inicial va a «Cancelar».

## Cómo se verificó

- `npx tsc --noEmit` y `npm run build` en verde (19 páginas).
- 58 pruebas de Playwright con el Chrome del sistema: sesión y guardas por rol, bandeja (plazos, teclado, diálogo propio, error con
  Reintentar, sin conexión, móvil con «‹ Bandeja», ⌘K), cada pantalla completa, diálogos apilados sobre una hoja, movimiento reducido, chat
  (incluida la contraseña pegada por error) y **axe-core WCAG 2.1 AA sin violaciones en 11 pantallas, en claro y en oscuro**.
  Corren también contra el contenedor con nginx real (`BASE_URL=…`).
- Revisión de capturas a 393, 1024, 1280 y 1600 px, claro y oscuro (`web/capturas/`, 150 imágenes).
- `docker build` y arranque del contenedor: rutas, fallback de `/estado/<token>`, proxy de `/api` y SSE contra el mock.
