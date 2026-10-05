# jsrbot — Diseño de pantallas

Identidad, colores, tipografía y principios: [`.better-web-ui.md`](.better-web-ui.md). Este archivo fija la forma de
la consola, sus pantallas y el chat.

Dirección: **al estilo Apple, minimalismo extremo**. Cada pantalla responde una sola pregunta y tiene una sola
acción principal.

---

## 1. Armazón de la consola

```
┌──────────────┬───────────────────────────────────────────────────────────────┐
│ ● ● ●        │  Bandeja                                   ⌕ Buscar   ⌘K  (DR) │  barra translúcida, 52 px
│              ├───────────────────────────────────────────────────────────────┤
│ Bandeja    12│  Vencen pronto                                                 │
│ Incidencias  │  ─────────────────────────────────────────────────────────── │
│ Conversac.   │  ● INC-0142  Correo no sincroniza · Contabilidad   vence 0:40 │  fila de 44 px
│              │    INC-0139  Impresora 3.er piso · Sede Centro     vence 2:15 │
│ Equipo       │                                                               │
│ Escalamiento │  Mías · 7                                                      │
│              │  ─────────────────────────────────────────────────────────── │
│ Indicadores  │    INC-0137  Acceso a VPN · Ana Ríos               hace 12 min │
│ Reportes     │    …                                                          │
│              │                                                               │
│ Asistente    │                                                               │
│ Ajustes      │                                                               │
└──────────────┴───────────────────────────────────────────────────────────────┘
   lateral 232 px, translúcido; plegable a iconos (64 px)
```

- **Lateral** como la lista de fuentes de macOS: texto de 13 px, sin iconos de color, el activo con fondo gris
  suave y tinta en azul. Agrupado en tres bloques sin títulos, separados por espacio:
  1. Trabajo: Bandeja, Incidencias, Conversaciones.
  2. Equipo: Equipo (técnicos y grupos), Escalamiento.
  3. Datos y ajustes: Indicadores, Reportes, Asistente, Ajustes.
- **Contador** solo en Bandeja: lo que pide acción ahora. Ningún otro elemento del lateral lleva número.
- **Barra superior:** título de la sección a la izquierda; buscador global (⌘K) y avatar a la derecha. La acción
  principal de la sección va aquí, en píldora azul, y solo hay una.
- **Móvil (≤ 768 px):** el lateral pasa a una barra inferior de 5 pestañas (Bandeja, Incidencias, Indicadores,
  Asistente, Más). La lista abre el detalle a pantalla completa, con «‹ Bandeja» arriba, como Mail.
- **Divulgación progresiva:** el detalle de cualquier objeto se abre en un panel a la derecha (≥ 1200 px) o en una
  hoja que sube (< 1200 px). La lista no se pierde.

---

## 2. Pantallas

| # | Pantalla | Pregunta que responde | Acción principal |
|---|---|---|---|
| 01 | **Inicio de sesión** | ¿Quién eres? | Continuar |
| 02 | **Bandeja** | ¿Qué atiendo ahora? | Abrir la que vence primero |
| 03 | **Detalle de incidencia** | ¿Qué le pasa, qué se probó y qué falta? | Responder (o Resolver) |
| 04 | **Incidencias** (todas, con filtros) | ¿Dónde está tal incidencia? | Filtrar / buscar |
| 05 | **Conversaciones** | ¿Qué está atendiendo el asistente ahora? | Tomar la conversación |
| 06 | **Equipo** | ¿Quién está, en qué grupo, con cuánta carga? | Añadir técnico |
| 07 | **Ficha del técnico** | ¿Qué sabe hacer, cuándo trabaja, cómo le va? | Guardar |
| 08 | **Escalamiento** | ¿Qué pasa cuando algo vence? | Editar regla |
| 09 | **Indicadores** | ¿Cumplimos este mes? | Cambiar periodo |
| 10 | **Reportes** | ¿Qué quiero saber? | Preguntar / abrir reporte |
| 11 | **Asistente · Comportamiento** | ¿Cómo habla y qué puede hacer? | Guardar y probar |
| 12 | **Asistente · Conocimiento** | ¿Qué sabe responder? | Nuevo artículo |
| 13 | **Asistente · Entrenamiento** | ¿Qué entiende mal y cómo lo corrijo? | Revisar pendientes |
| 14 | **Asistente · Calidad** | ¿Está mejorando? | Publicar versión |
| 15 | **Ajustes** | Canales, SLA, horario, categorías, roles | Guardar |
| 16 | **Estado público** (móvil, sin sesión) | ¿Cómo va mi incidencia? | Responder al técnico |
| 17 | **Chat web de prueba** | ¿Qué contestaría el asistente? | Escribir |

### 02 · Bandeja

- Tres grupos, en este orden y sin tarjetas:
  1. **Vencen pronto**: SLA ≥ 75 %, de toda la cola del técnico o del grupo.
  2. **Mías**: asignadas a mí, por plazo.
  3. **Sin asignar** (solo supervisores y N1).
- **Fila:** punto de estado (solo si es excepción), número en tinta secundaria, asunto en 15 px, persona y área
  en 13 px secundaria, plazo alineado a la derecha con cifras tabulares.
- El plazo cambia de color solo en la excepción: naranja al 75 %, rojo y con el tiempo en negativo al vencer
  («−0:12»).
- Atajos de teclado como Mail: `j`/`k` para moverse, `↵` para abrir, `a` para asignarme, `e` para resolver.
- **Vacío:** «Nada vence hoy.» y, debajo, lo siguiente que sí pide atención («2 esperan respuesta del usuario desde
  ayer · Ver»).

### 03 · Detalle de incidencia

```
INC-0142                                                        Responder ▸
Correo no sincroniza en Outlook
Ana Ríos · Contabilidad · Sede Centro            P2 · vence en 0:40 · Asignada a ti

Resumen del asistente
  Desde esta mañana Outlook no recibe correos. Probó reiniciar y cerrar sesión.
  Afecta solo a ella. Equipo PC-CONT-07.

Conversación                                                         ▾
  [hilo con piel neutra, últimos 6 mensajes; «Ver todo»]

Responder  [campo]                                   Interna ◯   Enviar
──────────────────────────────────────────────────────────────────────
Más ▸  Historial · Clasificación · Memoria del caso · Artículos sugeridos
```

- Arriba lo que identifica y lo que apura. El resumen del asistente reemplaza a leer el chat.
- **Una acción principal:** Responder. Resolver, Escalar y Reasignar van en el menú `···`.
- La respuesta puede partir de una **sugerencia** del asistente, marcada «Sugerido», que el técnico edita. Si la
  edita, la diferencia se guarda como par de preferencia (refuerzo).
- **Más:** eventos con hora, intención y confianza del clasificador, veredictos de Jev local, ficha de memoria,
  artículos usados.

### 09 · Indicadores

- **Sin rejilla de tarjetas.** Una columna de bloques, cada uno con:
  - la cifra en 48 px;
  - una frase que la interpreta («3 puntos sobre la meta»);
  - un *sparkline* de 12 semanas.
- **Orden de los bloques:**
  1. Cumplimiento de SLA.
  2. Tiempo de primera respuesta.
  3. Tiempo de resolución (MTTR).
  4. Resolución al primer contacto.
  5. Contención del asistente.
  6. Satisfacción (CSAT).
  7. Pendientes y antigüedad.
- **La cifra que pide acción va primero.** Si el SLA está bien pero hay 14 incidencias con más de 7 días, sube el
  bloque de antigüedad.
- **Origen de cada cifra:** cada bloque dice su golden query («Definición ▸») y el periodo. Al tocarla se ve la
  definición en palabras y el SQL.
- **Selector de periodo:** control segmentado (Semana · Mes · Trimestre) más un rango a medida.

### 10 · Reportes

- **Arriba, un campo:** «Pregunta lo que quieras saber». Lo responde el analista.
  - Con una golden query: cifra, tabla o gráfico y «Golden query · MTTR por categoría v3».
  - Sin golden query: el resultado lleva «Sin verificar» y el SQL visible.
- **Debajo, la biblioteca de reportes guardados**, en lista, no en tarjetas.
- **Explorador:** elegir medida, dimensiones y filtros; exportar CSV o XLSX; programar el envío por correo.

### 13 · Asistente · Entrenamiento

- **Cola de revisión:** mensajes con baja confianza, 👎, corrección del técnico o reapertura.
- **Cada fila:** el mensaje, lo que entendió el asistente y botones para confirmar o elegir otra intención.
- «Reentrenar» queda desactivado hasta que haya cambios. Al pulsarlo:
  1. se entrena en segundo plano;
  2. se compara con la versión publicada sobre el conjunto reservado;
  3. se muestran las dos cifras lado a lado;
  4. «Publicar» solo se activa si la nueva no empeora.

### 16 · Estado público

Página móvil sin sesión, enlazada desde el aviso de WhatsApp: número, estado en una línea, quién la atiende, plazo
y el último mensaje del técnico. Una acción: «Responder».

### 17 · Chat web de prueba

Reutiliza la piel de WhatsApp de Baruka, documentada en
[`referencias/baruka/DISENO_WHATSAPP.md`](referencias/baruka/DISENO_WHATSAPP.md), con estos cambios:

- Cabecera: nombre de la mesa de ayuda y avatar con sus iniciales.
- Respuestas rápidas de ejemplo de soporte: «No me abre el correo», «La impresora no imprime», «Olvidé mi
  contraseña», «¿Cómo va mi ticket?», «Necesito acceso a una carpeta», «Ya funcionó, gracias».
- Botones de respuesta: «Sí, se resolvió» / «Sigue igual», «Abrir incidencia», «Hablar con un técnico».
- El cajón de análisis muestra la etapa de atención, la ficha del caso, la clasificación, los veredictos de Jev
  local y los artículos del RAG.

La consola, en cambio, nunca imita WhatsApp: el hilo dentro del detalle de una incidencia usa globos neutros (gris
para el usuario, tinta secundaria para el asistente, azul suave para el técnico).

---

## 3. Componentes base

| Componente | Forma |
|---|---|
| `Grupo` | Lista agrupada estilo Ajustes: fondo `#F5F5F7`, filas blancas de 44 px con separador interior, radio 12 px. Para formularios y ajustes. |
| `Fila` | Título 15 px, detalle 13 px secundario, valor a la derecha, `›` si navega. |
| `Cifra` | 48 / 34 / 22 px, tabular, con unidad en tinta secundaria y 60 % del tamaño. |
| `Estado` | Texto en tinta secundaria («En curso»). Solo «Vencida» y «Por vencer» llevan color, y como punto o texto, nunca como pastilla rellena. |
| `Segmentado` | Control segmentado de iOS: fondo gris, opción activa en blanco con sombra mínima. |
| `Hoja` | Panel que sube (móvil) o se desliza desde la derecha (escritorio), 350 ms con curva de resorte, con asa en móvil. |
| `Boton` | Principal: píldora azul, 15 px, peso 500, 36 px de alto (44 px en móvil). Secundario: texto azul sin fondo. Destructivo: texto rojo, siempre con confirmación por `useDialog()`. |
| `Buscador` | ⌘K: hoja central con resultados agrupados (incidencias, personas, artículos, reportes), navegable con teclado. |
| `Vacio` | Una frase y una acción. Sin ilustración. |

---

## 4. Estados que toda pantalla debe tener

1. **Carga:** esqueleto con la forma real de las filas, sin spinner central. Si tarda más de 3 s, una línea dice qué
   espera.
2. **Vacío:** qué significa y qué hacer (§3, `Vacio`).
3. **Error:** qué falló en palabras simples, qué no se perdió y un «Reintentar». Nunca un código HTTP solo.
4. **Sin conexión:** barra fina bajo la barra superior; lo escrito se conserva.
5. **Datos reales feos:** asuntos de 200 caracteres, nombres compuestos, incidencias con 80 mensajes, técnicos sin
   foto. Se prueban con los datos sintéticos de la fase F1.

---

## 5. Revisión antes de dar una pantalla por terminada

1. `distill`: quitar el 20 %.
2. `hierarchy`: ¿se ve en un segundo cuál es la acción principal?
3. `a11y`: teclado, lector de pantalla, contraste AA, movimiento reducido.
4. `adapt`: 393 px, 1280 px y 1600 px.
5. Claro y oscuro.
6. `polish`.
