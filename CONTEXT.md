# Contexto — jsrbot (`jsr-vs7`)

Este archivo reúne lo que el código no dice por sí solo: qué es jsrbot, para quién es, qué palabras usamos, qué
decidimos y por qué, y qué no sabemos todavía. Lo leen las personas y los agentes antes de tocar nada.

- Reglas de trabajo para agentes: [`AGENTS.md`](AGENTS.md).
- Skills disponibles y cuándo usar cada una: [`SKILLS.md`](SKILLS.md).
- Plan por fases: [`PLAN_TRABAJO.md`](PLAN_TRABAJO.md).
- Arquitectura: [`ARQUITECTURA.md`](ARQUITECTURA.md).
- Diseño: [`DISENO.md`](DISENO.md) y la base que leen las skills, [`.better-web-ui.md`](.better-web-ui.md).

Estado: **construido en local** (05-10-2026): motor Go, pasarela OCaml, agente Python, consola Qwik y analítica en ClickHouse, con pruebas propias. Sin desplegar. Los datos de entrenamiento, semilla y artículos son sintéticos (`SUPUESTO:`).

---

## 1. Qué es

**jsrbot** es una **mesa de ayuda con asistente conversacional**. El nombre del proyecto y de la carpeta es
`jsr-vs7`; `jsrbot` es su alias en el código, los contenedores y la interfaz.

Una persona escribe por WhatsApp o por el chat web («no me abre el correo», «la impresora del 3.er piso no
imprime»). El asistente:

1. entiende el problema;
2. pregunta lo que falta (equipo, sede, desde cuándo, a cuántos afecta);
3. intenta resolverlo con la base de conocimiento, paso a paso;
4. si no se resuelve, **abre una incidencia** con todo lo que ya sabe;
5. la asigna al técnico adecuado;
6. la **escala** si vence el plazo o si el caso lo pide;
7. avisa a la persona de cada cambio;
8. al cerrar, pregunta si quedó resuelto y cómo la atendieron.

Alrededor del asistente hay una **plataforma**:

- gestor de incidencias;
- registro del personal técnico;
- reglas de escalamiento;
- indicadores y KPI;
- configuración del asistente;
- entrenamiento, refuerzo, memoria y feedback;
- reportería avanzada sobre ClickHouse, con un catálogo de *golden queries*.

---

## 2. De dónde viene

jsrbot reutiliza la arquitectura del asistente de ventas de **Baruka Design** (`../ddesign-k`), que ya está en
producción. Las copias de referencia están en [`referencias/baruka/`](referencias/baruka/):

- [`ARQUITECTURA.md`](referencias/baruka/ARQUITECTURA.md): canales, pipeline del agente, memoria, etapas, Jev,
  pruebas.
- [`DISENO_WHATSAPP.md`](referencias/baruka/DISENO_WHATSAPP.md): el chat web con piel de WhatsApp.

| De Baruka se toma | En jsrbot se convierte en |
|---|---|
| evolution-go + webhook al backend Go | Igual: canal WhatsApp |
| Embeddings `multilingual-e5-small` int8 + regresión logística | Clasificador local de intención de soporte y de categoría de incidencia |
| Etapas comerciales decididas por reglas | Etapas de atención: recepción → diagnóstico → guía → incidencia → seguimiento → cierre |
| Memoria con pregunta pendiente y siguiente pregunta elegida por código | Ficha del caso: equipo, sede, síntoma, impacto, urgencia, pasos probados |
| Stock como herramienta en vivo | Estado de incidencias, inventario de equipos y disponibilidad de técnicos como herramientas |
| RAG sobre el catálogo | RAG sobre la base de conocimiento (artículos y soluciones de incidencias cerradas) |
| Respuesta estructurada (JSON) + filtros + verificación | Igual |
| Jev (TypeSafe, de pago, por OpenRouter) | **Jev local**: modelo de juicio open source que corre en el servidor |
| Capa de juicio en sombra, `decisiones`, `pares_dpo` | Base del refuerzo y del feedback |
| Prueba de regresión (preguntas + conversaciones + entradas raras + carga) | Igual, con casos de soporte |
| Integración con Kommo | No aplica: el gestor de incidencias es propio |

**Lo que no se toma:** stock de tallas, pedidos y pagos, citas para probarse, temperatura de venta.

---

## 3. Para quién

| Persona | Dónde | Qué necesita |
|---|---|---|
| **Usuario final** (colaborador, alumno, cliente) | WhatsApp, chat web, móvil | Contar su problema una vez, que se lo resuelvan o le digan quién y cuándo. Saber el estado sin preguntar. |
| **Técnico N1 · mesa de ayuda** | Consola, escritorio, jornada completa | Bandeja de lo suyo ordenada por urgencia y plazo. Contexto completo sin releer el chat. Responder rápido. |
| **Especialista N2 / proveedor N3** | Consola o avisos por WhatsApp y correo | Solo lo que le escalan, con el diagnóstico ya hecho. |
| **Supervisor de la mesa** | Consola, escritorio | Lo que vence hoy, la carga de cada técnico, lo escalado. Reasignar en un gesto. |
| **Jefe de TI / gerencia** | Reportes, escritorio o móvil | KPI del mes contra la meta, tendencias, dónde se va el tiempo. |
| **Entrenador del asistente** | Consola, sección Asistente | Revisar conversaciones dudosas, corregir, reentrenar, medir antes de publicar. |
| **Administrador** | Consola, Ajustes | Canales, horarios, SLA, categorías, roles, integraciones. |

Tono con el usuario final: español de Perú, trato de «tú» o de «usted» según lo configure la organización, breve,
sin tecnicismos innecesarios. Tono en la consola: neutro, concreto, con la cifra y la siguiente acción.

---

## 4. Glosario

Una palabra, un significado. El código, la interfaz y los documentos usan estas palabras.

| Término | Significado |
|---|---|
| **Caso** | Una conversación de soporte con una persona, de principio a fin. Puede terminar sin incidencia (resuelto por el asistente). |
| **Incidencia** | Registro formal en el gestor (ticket). Tiene número `INC-000123`, estado, prioridad, SLA y responsable. |
| **Tipo** | `incidente` (algo dejó de funcionar), `solicitud` (pide algo: acceso, equipo, instalación), `consulta` (pregunta), `problema` (causa raíz de varios incidentes). |
| **Impacto** | A cuántos afecta: `persona`, `area`, `sede`, `organizacion`. |
| **Urgencia** | Cuánto puede esperar: `baja`, `media`, `alta`, `critica`. |
| **Prioridad** | P1–P4, calculada con la matriz impacto × urgencia. Nunca la escribe el LLM. |
| **SLA** | Plazos de primera respuesta y de resolución por prioridad (y opcionalmente por categoría), en horario laboral. |
| **Escalamiento funcional** | Pasar a otro nivel técnico (N1 → N2 → N3). |
| **Escalamiento jerárquico** | Avisar a un responsable (supervisor, jefe de TI) sin cambiar quién la trabaja. |
| **Contención** | Caso resuelto por el asistente sin abrir incidencia, y confirmado por la persona. |
| **Artículo** | Entrada de la base de conocimiento: síntoma, causa, pasos de solución. |
| **Golden query** | Consulta SQL canónica y verificada que define un KPI. Es la fuente única de verdad de esa cifra. |
| **Jev local** | Modelo de juicio open source que corre en el servidor: clasifica con contexto y verifica respuestas. Propone; las reglas deciden. |
| **Sombra** | Modo en que un modelo o regla nuevo registra lo que habría hecho, sin actuar, para medirlo antes de encenderlo. |

---

## 5. Decisiones tomadas

| Decisión | Motivo |
|---|---|
| **Los modelos proponen; el código decide.** Prioridad, SLA, asignación, escalamiento y cierre los decide el código con reglas configurables. | Herencia de Baruka: un proceso que se puede auditar. Un SLA no puede depender de lo que redacte un LLM. |
| **Clasificador local** (e5-small int8 + regresión logística) como primera capa. | 2 ms por mensaje en CPU, 98,5 % en Baruka, sin costo por mensaje. |
| **Jev local open source** en vez de Jev de pago. | Sin dependencia de saldo externo para decidir y verificar. Elección del modelo: `ARQUITECTURA.md` §6. |
| **Reparto de lenguajes:** el motor de incidencias queda en **Go** y lo que faltaba (API de la consola, webhook, flujo del caso, avisos) se escribe en **OCaml** (`pasarela/`). | Pedido del usuario (05-10-2026). Contratos en `docs/CONTRATOS.md` §5. |
| **LLM por API para redactar** (DeepSeek por OpenRouter), con respaldo por código. | En CPU, un LLM generativo local tarda minutos por mensaje (medido en Baruka). Se revisa si hay GPU. |
| **Postgres** para lo transaccional (incidencias, técnicos, configuración). | Varios usuarios concurrentes, transacciones, y fuente de la réplica hacia ClickHouse. Baruka usa SQLite porque es un solo bot. |
| **ClickHouse** solo para reportería. | Consultas de KPI sobre millones de eventos en milisegundos; nunca es fuente de verdad. |
| **Eventos inmutables** (`incidencia_eventos`, `mensajes`, `decisiones`) como base de todo KPI. | Un KPI se recalcula desde los hechos, no desde un campo que alguien sobrescribió. |
| **Golden queries** versionadas con su resultado esperado. | Una cifra, una definición. El tablero, el reporte programado y la pregunta en lenguaje natural usan la misma consulta. |
| **Diseño al estilo Apple, minimalismo extremo.** Base y reglas en `.better-web-ui.md`; skills de diseño de EDISYS. | Pedido del usuario (05-10-2026). |
| **El chat web de prueba reutiliza la piel de WhatsApp** de Baruka. | Probar en la web lo mismo que se verá en WhatsApp. La consola sí es estilo Apple. |

---

## 6. Restricciones

- **Sin GPU.** Todo lo que corre en el servidor (clasificador, Jev local, embeddings) debe caber en CPU con
  latencia de un mensaje de chat (objetivo: menos de 1,5 s sin contar el LLM de redacción).
- **RAM limitada.** Referencia: el EC2 de Baruka tiene 2 vCPU y ~7,8 GB. ClickHouse, Postgres, el agente y el Jev
  local deben caber juntos con márgenes (`ARQUITECTURA.md` §9).
- **Datos personales.** Las conversaciones traen nombres, correos, números de equipo y a veces contraseñas que la
  persona pega por error. Nada de eso sale a un servicio externo sin enmascarar (`AGENTS.md` §4).
- **Español de Perú** en todo lo visible. Fechas `dd/mm/aaaa` y «octubre 2026»; hora de Lima en la interfaz; UTC
  en la base.

---

## 7. Lo que no sabemos todavía

Preguntas abiertas. No se inventan respuestas: se marcan como supuestos en el código hasta que alguien las conteste.

1. **Cliente y alcance:** ¿para qué organización es jsrbot (mesa interna de TI, soporte a clientes externos,
   universidad)? ¿Qué significa «vs7»?
2. **Volumen esperado:** casos por día, técnicos, sedes. Define el tamaño del servidor y si ClickHouse se
   justifica desde el día uno.
3. **Servidor:** ¿el EC2 de Baruka (3.132.249.89), uno nuevo o el del cliente? ¿Dominio?
4. **Canales:** ¿WhatsApp con un número propio? ¿Correo entrante como canal (crear incidencia desde un correo)?
5. **Identidad:** ¿cómo se identifica al usuario final (número de WhatsApp, correo corporativo, código de
   empleado)? ¿Hay directorio (LDAP, Google Workspace, Microsoft Entra)?
6. **SLA y horario reales** de la organización, y su matriz de prioridades.
7. **Integraciones:** inventario de equipos (CMDB), correo, Teams, herramientas actuales de tickets que haya que
   migrar.
8. **Datos para entrenar:** ¿existen conversaciones o tickets históricos? Sin ellos se arranca con un conjunto
   sintético revisado a mano.
