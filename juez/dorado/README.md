# Conjunto dorado de Jev local (SINTÉTICO)

Lo lee `agente/app/evaluar_juez.py`. **Es sintético: lo escribió una sola persona (un asistente de IA) para medir, no se etiquetó con dos revisores humanos**, así que no hay acuerdo entre
etiquetadores y las cifras son un **techo optimista**, no una promesa para producción. El plan (F4) pide 300 turnos y 200 pares etiquetados por dos personas con el acuerdo medido; esto
es el arranque, hasta que haya conversaciones reales.

## `clasificacion.jsonl` (65 turnos)

Un turno por línea: `{id, mensaje, historial, etapa, pendiente, intencion}`. Son turnos donde el contexto importa: respuestas cortas a una pregunta pendiente («sí», «ayer», «a todos acá»),
seguimientos con una incidencia abierta, frases ambiguas. `pendiente` es la pregunta abierta del asistente (`resolvio`, `desde`, `aplicacion`…) y `historial` trae su último mensaje.

## `grounding.jsonl` (84 pares, 206 frases, 45 alucinaciones)

Un par respuesta-fuente por línea:

```json
{"id": "GR010", "articulo": "KB-002", "pregunta": "...", "split": "cal|test", "respuesta": "...", "contesta": true,
 "frases": [{"texto": "...", "alucinacion": false, "tipo": "fiel|cortesia|numero|comando|menu|paso|causa|politica"}]}
```

- La **fuente** es el artículo `articulo` de `agente/seed/articulos.json`.
- `alucinacion: true` marca la frase que afirma algo que el artículo no dice. **Tipos:** `numero` (un plazo o cifra inventada), `comando` (un comando que no está), `menu` (una opción de menú
  que no está), `paso` (una acción que el artículo no manda), `causa` (una explicación inventada), `politica` (una política o dato de la organización inventado).
- `cortesia` son frases sociales que no afirman nada (no son alucinación). `fiel`, parafraseos del artículo.
- `split`: `cal` se usa para calibrar los umbrales y `test` para informar. Se reparten alternando por separado los pares con alucinaciones, los fieles y los que no contestan.
- `contesta: false` (4 pares) son respuestas que no atienden la pregunta. `evaluar_juez` además desordena preguntas y respuestas de otro tema para tener más negativos.

## Límites

- Una sola mano escribió el conjunto y las reglas léxicas del verificador se afinaron mirando sus errores (ver `agente/LEEME.md`): el recall medido aquí está inflado respecto al que se
  verá con alucinaciones reales de un LLM.
- Faltan las alucinaciones más difíciles: cambios sutiles de significado sin cifras, comandos o menús (solo el NLI y LettuceDetect los atrapan, y solo en parte).
- 65 turnos y 45 alucinaciones son pocos: un acierto de más o de menos mueve el recall tres puntos.
