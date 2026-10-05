# Datos de entrenamiento y prueba del agente (SINTÉTICOS)

**Todo lo de esta carpeta es sintético.** Lo escribió un asistente de IA para arrancar (PLAN_TRABAJO F1 punto 5), en español de Perú, con jerga e imprecisiones, y **ninguna persona lo ha
revisado todavía**. No hay conversaciones reales de ninguna organización. Mientras no existan, estas cifras miden qué tan bien aprende el clasificador *este* estilo de frases,
no qué tan bien entenderá a las personas reales. El plan manda revisarlas a mano y reemplazarlas con aprendizaje activo desde el piloto (F10).

| Archivo | Filas | Qué es |
|---|---|---|
| `intenciones_soporte.csv` | 1053 | **Entrenamiento** de la intención: 13 intenciones × 45–195 frases (las más variadas, `reportar_falla` y `aportar_dato`, tienen más), en **tríos** (correcta, informal, con faltas de ortografía) |
| `categorias.csv` | 429 | **Entrenamiento** de la categoría: 10 categorías × 30–66 frases, también en tríos |
| `prueba_soporte.csv` | 153 | **RESERVADO**: no entra al entrenamiento. 153 con intención; 87 también con categoría |
| `regresion_preguntas.csv` | 72 | Preguntas sueltas con su contexto (etapa, memoria, incidencias abiertas) para `python -m app.regresion` |
| `extra_revisados.csv` | (opcional) | Frases confirmadas por la cola de revisión (F8): `mensaje,intencion,categoria`. Si existe, entra al entrenamiento |

Columnas: `intenciones_soporte.csv` y `categorias.csv` → `mensaje,<intencion|categoria>,variante,grupo_id`. `variante` es `correcta`, `informal` o `errores_ortograficos`; las tres variantes de una frase comparten
`grupo_id`, y la validación cruzada los mantiene juntos para no evaluar con la versión mal escrita de algo que ya vio bien escrito. `prueba_soporte.csv` → `mensaje,intencion,categoria` (la categoría va
vacía cuando el mensaje no describe un caso: saludos, agradecimientos, consultas de estado…).

## Reglas

1. **El reservado no se toca para que suba una cifra.** Si no llega a la meta, se mejoran los datos de entrenamiento (AGENTS.md §1.4 regla 10). `app/datos.py:solapes()` y `entrenar.py` abortan si una frase del
   reservado está (casi) copiada en el entrenamiento; `python -m app.regresion --solapes` hace lo mismo con la regresión.
2. **Honestidad sobre el reservado.** El reservado y el entrenamiento los escribió la misma mano en la misma sesión, y se miró qué errores tenía el reservado al ir ampliando el entrenamiento (cuatro rondas, cada una con frases
   nuevas y generales, nunca copiadas). Las cifras del reservado son por eso **optimistas**; la validación cruzada agrupada (más baja) es la cifra más conservadora de las dos.
3. Las frases con datos (códigos de equipo, nombres de impresora, números de incidencia) son inventadas.

## Definiciones que importan

- `solicitar_equipo` incluye **periféricos y también software** («instálenme AutoCAD», «una licencia de Acrobat»), porque el vocabulario cerrado (CONTRATOS §3) no tiene una intención aparte para instalaciones.
- `restablecer_clave` es olvidar, perder, bloquear o vencer la contraseña o el usuario y pedir recuperarlos; «me bota usuario o clave incorrecta» (falla al entrar) es `reportar_falla`.
- `aportar_dato` son frases sueltas que dan un dato (equipo, sede, desde cuándo, error, programa, a quién afecta) o responden a lo que se preguntó. Es la intención más difícil sin contexto: el agente la resuelve con la
  pregunta pendiente de la memoria (`memoria.leer`) y con las reglas de `lenguaje.py`, no solo con el clasificador.
- `fuera_de_alcance` es todo lo que no es soporte técnico (clima, fútbol, vacaciones, sueldo…).
- Categoría `otro`: lo físico o administrativo que no es de TI (aire acondicionado, ascensor, extintores, torniquetes) y lo que no se sabe a quién corresponde.
