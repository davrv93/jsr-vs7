# Investigación: Jev local, clasificador y ClickHouse

Investigación del 05-10-2026 para elegir un juez open source que reemplace a Jev de pago (TypeSafe System One, por
OpenRouter) en un servidor sin GPU. La decisión resultante está en [`../ARQUITECTURA.md`](../ARQUITECTURA.md) §6.

Leyenda:

- **[V]** comprobado en la fuente primaria: ficha de Hugging Face, repositorio o documentación oficial.
- **[S]** solo lo dice un buscador o un tercero.
- **[C]** conocimiento previo, no comprobado de nuevo.
- **[E]** estimación.

## 1. Grounding y alucinación

| Modelo | Tamaño | Licencia | Qué hace | Español |
|---|---|---|---|---|
| `KRLabsOrg/lettucedect-610m-eurobert-es-v1` [V] | 610M | MIT | Marca tramos de la respuesta sin respaldo en el contexto (8K) | **Sí**: F1 73,25 en RAGTruth-ES |
| `MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7` [V] | ~0,3B | MIT | Inferencia natural: implica, neutral o contradice | Sí: 83,2 % en XNLI-es |
| `vectara/hallucination_evaluation_model` (HHEM-2.1-Open) [V] | ~0,1B | Apache 2.0 | Puntúa de 0 a 1 la consistencia con la fuente; ~1,5 s por 2K tokens | **No**: el español solo está en HHEM-2.3, de pago |
| `lytang/MiniCheck-*` [V] | 0,4–0,8B | MIT | Por frase: ¿la respalda la fuente? | Inglés |
| `bespokelabs/Bespoke-MiniCheck-7B` [V] | 7B | **CC BY-NC 4.0** | Lo mismo; primero en LLM-AggreFact | Inglés |
| `PatronusAI/Llama-3-Patronus-Lynx-8B-Instruct-v1.1` [V] | 8B | **CC BY-NC 4.0** | Fidelidad al documento, PASS o FAIL | Principalmente inglés |

## 2. Jueces generales y guardrails

| Modelo | Tamaño | Licencia | Qué hace | Español |
|---|---|---|---|---|
| `AtlaAI/Selene-1-Mini-Llama-3.1-8B` [V] | 8B | Apache 2.0 | Puntuación absoluta, sí/no y por pares | Sí |
| `Unbabel/M-Prometheus-3B` / 7B / 14B [V] | 3–14B | «other» (base Qwen2.5-3B con licencia de investigación [C]) | Puntuación absoluta y por pares | Multilingüe |
| `prometheus-eval/prometheus-7b-v2.0` [V] | 7B | Apache 2.0 | Rúbrica 1–5 y por pares | Inglés |
| `flowaicom/Flow-Judge-v0.1` [V] | 3,8B | Apache 2.0 | Aprobado/suspenso y Likert | Inglés |
| `PatronusAI/glider` [V] | 3,8B | **CC BY-NC 4.0** | Rúbrica con razonamiento | Incluye español |
| `opencompass/CompassJudger-1-1.5B-Instruct` [V] | 1,5B | Apache 2.0 | Puntuación y crítica | Inglés y chino [S] |
| `ibm-granite/granite-guardian-4.1-8b` (y 3.x de 2B a 8B) [V] | 2–8B | Apache 2.0 | Groundedness, relevancia de la respuesta y del contexto | **Solo inglés** |
| `Skywork/Skywork-Reward-V2-Qwen3-0.6B` … 8B [V] | 0,6–8B | Apache 2.0 | Modelo de recompensa: nota escalar | Multilingüe sin lista |
| `Qwen/Qwen3Guard-Gen-0.6B` / 4B / 8B [V] | 0,6–8B | Apache 2.0 | Seguridad. No revisa grounding | 119 idiomas |

**LLM pequeños para usar como juez con gramática:**

- `ibm-granite/granite-4.0-1b` [V]: Apache 2.0, con español.
- Qwen3-0.6B, 1.7B y 4B [C]: Apache 2.0.
- Phi-4-mini 3,8B [C]: MIT.
- SmolLM3-3B [C]: Apache 2.0.

## 3. Rendimiento en CPU

**Medido** [V] (CEUR Vol-4164; ik_llama.cpp #164):

- Llama-3.2-1B en Q4: ~120 tok/s de generación en un Xeon 8480+ y ~25 tok/s en un Xeon E5 antiguo, con 16 vCPU.
- Un modelo 8B: ~17 tok/s por núcleo leyendo el prompt.

**Estimado para el servidor** [E]:

| Modelo Q4_K_M | Lectura del prompt, 4 vCPU | Generación | RAM |
|---|---|---|---|
| 0,6B | 300–500 tok/s | 30–50 tok/s | ~0,5 GB |
| 1,5–1,7B | 120–200 tok/s | 15–25 tok/s | ~1,2 GB |
| 3,8–4B | 50–80 tok/s | 7–12 tok/s | ~2,5 GB |
| 8B | 20–35 tok/s | 3–6 tok/s | ~5 GB |

**Conclusión:**

- En un juez, el costo está en leer el prompt.
- Caben en 1–2 s: los encoders NLI (30–100 ms por par), LettuceDetect (0,5–2 s) y un LLM de 0,6–1,7B con caché del
  prefijo y salida JSON corta.
- Un juez generativo de 4B u 8B no cabe en el camino del usuario: solo sirve para la auditoría nocturna.

## 4. Clasificador de intención

| Modelo | Tamaño | Velocidad [E] | Nota |
|---|---|---|---|
| `minishlab/potion-multilingual-128M` [V] | Estático, 256 dimensiones, MIT | < 1 ms | 90,9 % de LaBSE en MTEB |
| multilingual-e5-small [C] | 118M | 2–15 ms | El de Baruka (98,5 % medido) |
| multilingual-e5-base, gte-multilingual-base [C] | ~300M | 20–40 ms | Más precisión |
| bge-m3 [C] | 568M | 60–150 ms | Contexto de 8K |

## 5. ClickHouse y golden queries

- **RAM** [V, documentación «Usage recommendations»]:
  - Recomiendan 32 GB, pero funciona con 2 GB ajustado y con poca ingesta.
  - Ajustes: `mark_cache_size` ~500 MB, `max_threads` = 1, `max_block_size` = 8192, sin paralelismo de *parsing*,
    sin tablas de log.
- **Ingesta:** con poca RAM se desaconsejan Kafka y S3 [V]. `MaterializedPostgreSQL` es experimental [C]. PeerDB es
  CDC, de disponibilidad general en ClickHouse Cloud [V]; autoalojado añade servicios.
- **Golden queries:**
  - Snowflake las implementa como *Verified Query Repository*: ejemplos *few-shot* y evaluación [V].
  - SpotIt (arXiv 2510.26840) muestra que la comparación por ejecución deja pasar diferencias y que hay errores en
    el SQL «gold» de BIRD y Spider [S]. Hay que versionar y revisar el dorado.

## Fuentes

- https://huggingface.co/KRLabsOrg/lettucedect-610m-eurobert-es-v1 · https://github.com/KRLabsOrg/LettuceDetect
- https://huggingface.co/MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7
- https://huggingface.co/vectara/hallucination_evaluation_model
- https://huggingface.co/lytang/MiniCheck-Flan-T5-Large · https://huggingface.co/bespokelabs/Bespoke-MiniCheck-7B
- https://huggingface.co/PatronusAI/Llama-3-Patronus-Lynx-8B-Instruct-v1.1 · https://huggingface.co/PatronusAI/glider
- https://huggingface.co/prometheus-eval/prometheus-7b-v2.0 · https://huggingface.co/Unbabel/M-Prometheus-3B
- https://huggingface.co/AtlaAI/Selene-1-Mini-Llama-3.1-8B · https://arxiv.org/html/2501.17195v1
- https://huggingface.co/flowaicom/Flow-Judge-v0.1 · https://huggingface.co/opencompass/CompassJudger-1-1.5B-Instruct
- https://huggingface.co/ibm-granite/granite-guardian-4.1-8b · https://huggingface.co/ibm-granite/granite-4.0-1b
- https://huggingface.co/Skywork/Skywork-Reward-V2-Qwen3-0.6B · https://huggingface.co/Qwen/Qwen3Guard-Gen-0.6B
- https://huggingface.co/minishlab/potion-multilingual-128M
- https://ceur-ws.org/Vol-4164/paper11.pdf · https://github.com/ikawrakow/ik_llama.cpp/discussions/164
- https://clickhouse.com/docs/operations/tips · https://clickhouse.com/blog/postgres-cdc-connector-clickpipes-ga
- https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/verified-query-repository
- https://arxiv.org/abs/2510.26840
