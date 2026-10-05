# jsrbot

Mesa de ayuda con asistente conversacional por WhatsApp y web: gestor de incidencias, personal técnico,
escalamiento, KPI, entrenamiento y reportería en ClickHouse con golden queries. Se construye a partir de kddesign
(`../ddesign-k`).

| Documento | Para qué |
|---|---|
| [CONTEXT.md](CONTEXT.md) | Qué es, glosario, decisiones, preguntas abiertas |
| [AGENTS.md](AGENTS.md) | Reglas de trabajo, equipo de agentes, agentes del producto |
| [SKILLS.md](SKILLS.md) | Skills de diseño (EDISYS) y del proyecto |
| [PLAN_TRABAJO.md](PLAN_TRABAJO.md) | Fases F0–F10 y mapa del port desde kddesign |
| [ARQUITECTURA.md](ARQUITECTURA.md) | Servicios, caso, incidencias, Jev local, datos, ClickHouse |
| [docs/CONTRATOS.md](docs/CONTRATOS.md) | Contratos entre servicios y cambios acordados |
| [DISENO.md](DISENO.md) · [.better-web-ui.md](.better-web-ui.md) | Consola al estilo Apple |
| [docs/INVESTIGACION_JEV_LOCAL.md](docs/INVESTIGACION_JEV_LOCAL.md) | Modelos de juicio open source, con fuentes |

Estado (05-10-2026): **construido de punta a punta en local** (F1–F8 en código; F9 y F10 pendientes). Servicios:
motor Go (`backend/`), pasarela OCaml (`pasarela/`), agente Python (`agente/`), consola Qwik (`web/`), ClickHouse y
golden queries (`analitica/`). Arranque: `./despliegue/generar-env.sh && docker compose up -d`. Contratos entre
servicios: [docs/CONTRATOS.md](docs/CONTRATOS.md). Cifras y límites de cada pieza: el `LEEME.md` de su carpeta.
