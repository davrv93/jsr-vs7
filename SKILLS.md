# Skills — jsrbot

Una *skill* es un paquete de instrucciones que un agente carga para hacer bien un tipo de tarea. jsrbot tiene dos
grupos:

1. **Skills de diseño**, copiadas de EDISYS a `.agents/skills/` (33 skills).
2. **Skills del proyecto**: procedimientos propios de jsrbot. Se crean en la fase F0 del plan; aquí está su
   definición.

Antes de cualquier trabajo de interfaz, el agente lee [`.better-web-ui.md`](.better-web-ui.md). Todas las skills de
diseño lo usan como contexto, y sus valores por defecto ceden ante él.

---

## 1. Skills de diseño (de EDISYS)

**Origen:** [`aladicf/better-web-ui`](https://github.com/aladicf/better-web-ui), licencia Apache 2.0 (basada en la
skill `frontend-design` de Anthropic). Versiones fijadas en [`skills-lock.json`](skills-lock.json). Se copiaron de
`../EDISYS/.agents/skills/` el 05-10-2026. Para actualizarlas, se copian de nuevo desde su origen y se revisa el
diff. No se editan aquí.

### Cuándo usar cada una en jsrbot

**Para empezar o rehacer una pantalla:**

| Skill | Úsala para |
|---|---|
| `setup` | Revisar o completar `.better-web-ui.md` si cambia el público o la dirección. |
| `frontend-design` | Construir una pantalla nueva de la consola (bandeja, detalle, reportes). Es la base de las demás. |
| `add-ui` | Explorar cinco variantes de una pieza nueva (p. ej. el detalle de incidencia) antes de elegir una. |
| `arrange` | Composición, espaciado y agrupación de una pantalla. |
| `hierarchy` | Cuando no queda claro qué es lo principal (p. ej. la bandeja no deja ver qué vence). |

**Para quitar, no para añadir (las más usadas con minimalismo extremo):**

| Skill | Úsala para |
|---|---|
| `distill` | Quitar controles, opciones y elementos que compiten. Antes de cerrar cualquier pantalla. |
| `quieter` | Bajar intensidad: color, peso, contraste de más. |
| `normalize` | Volver a los tokens y patrones cuando una pantalla se aparta del sistema. |
| `polish` | Pasada final: alineación, espaciado, detalles. |

**Piezas concretas:**

| Skill | Úsala para |
|---|---|
| `data-viz` | Reportes y KPI: elegir el gráfico, hacerlo legible y accesible. |
| `forms` | Nueva incidencia, ficha del técnico, reglas de escalamiento, ajustes del asistente. |
| `search` | Buscador global (⌘K), filtros de la bandeja, búsqueda en la base de conocimiento. |
| `empty-state` | Bandeja vacía, reporte sin datos, sin resultados. |
| `typeset` | Escala tipográfica, cifras tabulares, jerarquía de texto. |
| `colorize` | Solo para revisar el color semántico (vencido, por vencer). No para añadir color. |
| `depth` | Sombra y elevación de hojas, menús y *popovers*. Solo lo que flota. |
| `animate` | Transiciones de hojas, paneles y cambios de estado. Solo si explican algo. |
| `imagery` | Capturas y fotos que manda el usuario (pantallazos de errores). |
| `clarify` | Textos de interfaz, errores y mensajes del asistente. |
| `localize` | Formatos de Perú: fechas, horas, moneda, plurales. |
| `onboard` | Primer uso: conectar WhatsApp, crear el primer técnico, cargar la base de conocimiento. |
| `security-ux` | Inicio de sesión, roles, datos sensibles en el chat (contraseñas pegadas por error). |
| `adapt` | Consola en pantallas estrechas; página pública de estado en el móvil. |

**Calidad:**

| Skill | Úsala para |
|---|---|
| `a11y` | Teclado, lector de pantalla, contraste, movimiento reducido. Obligatoria antes de publicar una pantalla. |
| `audit` | Informe con severidad P0–P3 de accesibilidad, rendimiento, temas y antipatrones. |
| `critique` | Revisión de UX de conjunto con puntuación. |
| `harden` | Errores, textos largos, datos reales feos, red lenta. |
| `optimize` | Carga, tamaño del paquete, animaciones lentas. |
| `test` | Pruebas visuales y de interacción. |
| `extract` | Pasar componentes repetidos al sistema (`Lista`, `Fila`, `Grupo`…). |

**Rara vez en jsrbot:**

| Skill | Por qué casi no se usa |
|---|---|
| `bolder`, `showcase`, `delight` | Van contra el minimalismo extremo. Solo para la página pública o una demo comercial, y con permiso. |

---

## 2. Skills del proyecto

Se crean en `.agents/skills/<nombre>/SKILL.md` durante la fase F0 (ver `PLAN_TRABAJO.md`). Cada una documenta un
procedimiento que se repite y que tiene trampas.

| Skill | Qué hace | Cuándo |
|---|---|---|
| `jsr-golden-query` | Añadir o cambiar una golden query: escribir el SQL de ClickHouse, documentar la definición del KPI, fijar el resultado esperado sobre el conjunto de prueba, registrar la versión. | Al crear o cambiar un KPI o un reporte. |
| `jsr-entrenar` | Añadir frases al conjunto de intenciones (en tríos: correcta, informal y con faltas), reentrenar, comparar con el conjunto reservado, publicar o descartar. | Al ampliar intenciones o categorías, o cuando baja la exactitud. |
| `jsr-jev-local` | Cambiar el modelo de juicio, su prompt o su gramática; correr la evaluación de calibración; pasar de sombra a activo. | Antes de cambiar cualquier cosa de Jev local. |
| `jsr-regresion` | Correr la prueba de regresión del asistente (preguntas, conversaciones, entradas raras, carga) y leer el resultado. | Antes de cada despliegue del agente. |
| `jsr-sla` | Cambiar la matriz de prioridades, los SLA o el calendario laboral, y recalcular las incidencias abiertas afectadas. | Al cambiar plazos u horarios. |
| `jsr-escalamiento` | Añadir o cambiar una regla de escalamiento y probarla contra incidencias históricas en modo sombra. | Al cambiar reglas de escalamiento. |
| `jsr-desplegar` | Despliegue paso a paso con respaldo previo y verificación. | Cuando exista servidor. |
| `jsr-revisar-conversaciones` | Tomar las conversaciones con baja confianza, 👎 o reapertura, etiquetarlas y convertirlas en datos de entrenamiento o en artículos. | Semanalmente. |

### Plantilla

```markdown
---
name: jsr-<nombre>
description: <qué hace y cuándo usarla, en una frase; esto decide si un agente la carga>
---

## Cuándo
## Antes de empezar (qué leer, qué comprobar)
## Pasos
## Cómo verificar
## Trampas conocidas
```

---

## 3. Skills de otros proyectos que sirven de referencia

No se copian; se leen cuando hace falta.

| Dónde | Qué aporta |
|---|---|
| `../ddesign-k/agente/README.md` | Mediciones del clasificador, memoria, etapas, Jev. |
| `../ddesign-k/DEPLOY.md` §1 y §3.1 | Cómo se corre la regresión y qué mirar en el log del build. |
| `../EDISYS/design/DISENO.md` | Ejemplo de inventario de pantallas con datos de demostración coherentes. |
