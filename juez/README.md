# juez · Jev local (el juez open source de jsrbot)

Contenedor aparte con **`llama-server`** (llama.cpp) y **Qwen3-1.7B en Q4_K_M**. Sirve la parte (a) de Jev local
([`ARQUITECTURA.md`](../ARQUITECTURA.md) §6): la **cascada de clasificación con contexto** cuando el clasificador local duda, y un
«¿contestó?» de respaldo. La parte (b) de Jev (grounding por frase: NLI, LettuceDetect) corre **dentro del agente**
([`agente/app/verificar.py`](../agente/app/verificar.py)), no aquí.

El agente lo llama con `agente/app/juez.py`. El juez **propone** (intención, confianza, datos); el código decide
([`AGENTS.md`](../AGENTS.md) §3.2). Nunca decide la etapa, la prioridad ni el escalamiento.

## Qué hay

| Archivo | Para qué |
|---|---|
| `Dockerfile` | Imagen oficial de llama.cpp + el modelo bajado con **revisión fija y SHA-256 verificado** en el build |
| `dorado/` | Conjunto dorado sintético (`clasificacion.jsonl`, `grounding.jsonl`) con el que `python -m app.evaluar_juez` mide al juez |
| este `README.md` | Cómo levantarlo, probarlo y medirlo |

## Estado: lo que se probó y lo que no

- **Probado:** el cliente (`agente/app/juez.py`) contra un servidor simulado compatible con OpenAI (`prueba_juez.py`, 40 casos) y contra **Ollama** con
  `qwen2.5:3b`, `llama3.2:1b` y `gemma3:1b` (los modelos que había en la máquina): el esquema JSON con enum cerrado, `logprobs` y los tiempos funcionan.
- **NO probado:** este `Dockerfile` ni `Qwen3-1.7B Q4_K_M`. El modelo pesa 1,1 GB y el encargo era no bajarlo en la máquina de desarrollo. Las cifras del juez en
  `agente/LEEME.md` son las de los sustitutos de Ollama y **no** valen para Qwen3-1.7B: hay que correr `evaluar_juez` contra este contenedor antes de pasar a `activo`.

## Levantarlo

```bash
docker build -t jsrbot_juez ./juez                         # baja 1,1 GB y verifica el hash; si no coincide, falla
docker run --rm -p 8080:8080 --memory 2g jsrbot_juez
curl -s localhost:8080/health                              # {"status":"ok"}
```

Con el agente (variables de `agente/app/juez.py`):

```bash
JUEZ_URL=http://juez:8080 JUEZ_MODO=sombra uvicorn app.main:app      # sombra: registra y no cambia nada (valor por defecto con URL)
JUEZ_MODO=activo ...                                                 # solo cuando la evaluación lo justifique (AGENTS.md §1.4 regla 6)
```

## Medirlo

```bash
cd agente
python -m app.evaluar_juez --juez-url http://127.0.0.1:8080 --juez-modelo qwen3-1.7b
```

Imprime macro-F1, ECE y la curva de la cascada (cuántos errores del agente arregla el juez y cuántos aciertos rompe), con p50/p95 de latencia. **La salida de F4 pide**
([`PLAN_TRABAJO.md`](../PLAN_TRABAJO.md) F4): cascada con macro-F1 ≥ al del clasificador local en los casos dudosos y p95 del juez < 2 s en el servidor de referencia. Hasta
tenerlo, el juez se queda en `sombra`.

## Cómo funciona la cascada (y por qué es rápida)

- **Prefijo fijo.** `INSTRUCCIONES` (13 intenciones descritas, reglas y 14 ejemplos) va siempre igual al inicio del prompt; la conversación, al final. `llama-server` guarda en
  caché el cálculo del prefijo (`cache_prompt`, `--cache-reuse`), y como en CPU lo caro es leer el prompt, no generar, el tiempo baja de ~8 s a 1–2 s **[E, a medir]**.
- **Salida forzada.** `response_format: json_schema` con `intencion` como `enum` de las 13 intenciones: el servidor la convierte en gramática, así que nunca contesta fuera del vocabulario.
- **Confianza.** Si el servidor devuelve `logprobs`, la confianza sale de la distribución de probabilidad en el token que abre el valor de `intencion` (más fiable que la que el
  modelo dice tener; ambas se registran). Si no, se usa la que dice el modelo.
- **No bloquea.** Tiempo máximo (1,8 s por defecto) y cortacircuitos: tras 3 fallos seguidos no se consulta durante 30 s. El chat sigue con el clasificador local.
- **Sin razonamiento.** Qwen3 puede «pensar» antes de contestar; aquí se apaga (`--reasoning-budget 0` y `enable_thinking: false`).

## Reproducibilidad

El modelo está fijado por revisión y SHA-256 (leídos de la API de Hugging Face el 05-10-2026, sin descargar el archivo):

| Dato | Valor |
|---|---|
| Repositorio | `unsloth/Qwen3-1.7B-GGUF` (licencia Apache 2.0 de Qwen3) |
| Revisión | `d7f544eead698dbd1f15126ef60b45a1e1933222` |
| Archivo | `Qwen3-1.7B-Q4_K_M.gguf`, 1 107 409 472 bytes |
| SHA-256 | `b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897` |

La imagen base (`ghcr.io/ggml-org/llama.cpp:server`) es la etiqueta móvil: tras el primer build que funcione, fíjala por *digest*
(`docker inspect --format '{{index .RepoDigests 0}}' <imagen>`) y pásala como `--build-arg LLAMA_IMAGEN=…`. Con `llama-server` 0.5.0 (build 11146, el de Homebrew de esta máquina) existen todas las banderas que usa el `CMD`.

## Memoria (ARQUITECTURA §9)

~1,2–1,5 GB para Qwen3-1.7B Q4_K_M con contexto de 4096 y 2 ranuras. Si no cabe: `granite-4.0-1b` (Apache 2.0, con español) o `Qwen3-0.6B`; se cambia el `.gguf` y se vuelve a medir.

## Alternativas

| Modelo | Cuándo |
|---|---|
| `ibm-granite/granite-4.0-1b` | Si Qwen3-1.7B no cabe en la latencia o en la RAM |
| `Qwen3-0.6B` | Servidor de 2 vCPU y 4 GB |
| `Qwen3Guard-Gen-0.6B` | Capa de seguridad opcional (no se usa hoy) |
| `Selene-1-Mini-Llama-3.1-8B` Q4 | Auditoría nocturna por lotes, en otro contenedor y de noche (F8) |
