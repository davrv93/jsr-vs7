# Jev local · parte (a): llama-server (llama.cpp) con Qwen3-1.7B Q4_K_M, para la cascada de clasificación y «¿contestó?».
# Sin GPU. El modelo se descarga en el build con revisión fija y se VERIFICA con su SHA-256: si no coincide, el build falla.
#
#   docker build -t jsrbot_juez ./juez
#   docker run --rm -p 8080:8080 --memory 2g jsrbot_juez
#   JUEZ_URL=http://127.0.0.1:8080 python -m app.evaluar_juez --juez-url http://127.0.0.1:8080     (desde agente/)
#
# NO probado en esta máquina: el modelo (1,1 GB) no se descargó (instrucción del encargo). El hash sale de la API de Hugging Face del 05-10-2026.
# Fija también la imagen base por «digest» tras el primer build que funcione (ver juez/README.md §Reproducibilidad).

ARG LLAMA_IMAGEN=ghcr.io/ggml-org/llama.cpp:server

# --- Etapa 1: descargar y verificar el modelo (no llega a la imagen final con curl ni caché) ---
FROM debian:12-slim AS modelo
ARG MODELO_REPO=unsloth/Qwen3-1.7B-GGUF
ARG MODELO_REV=d7f544eead698dbd1f15126ef60b45a1e1933222
ARG MODELO_ARCHIVO=Qwen3-1.7B-Q4_K_M.gguf
ARG MODELO_SHA256=b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897
ARG MODELO_BYTES=1107409472
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /out && curl -fL --retry 4 -o /out/modelo.gguf \
      "https://huggingface.co/${MODELO_REPO}/resolve/${MODELO_REV}/${MODELO_ARCHIVO}" \
 && echo "${MODELO_SHA256}  /out/modelo.gguf" | sha256sum -c - \
 && test "$(stat -c %s /out/modelo.gguf)" = "${MODELO_BYTES}"

# --- Etapa 2: el servidor ---
FROM ${LLAMA_IMAGEN}
COPY --from=modelo /out/modelo.gguf /models/qwen3-1.7b-q4_k_m.gguf
EXPOSE 8080
# -c 4096        : contexto suficiente (instrucciones + ejemplos + conversación ≈ 1.500 tokens)
# -np 2          : dos conversaciones a la vez; cada una con su caché del prefijo fijo
# --cache-reuse  : reutiliza el prefijo del prompt (instrucciones y ejemplos fijos) entre peticiones: es lo que baja la latencia de ~8 s a 1–2 s
# --reasoning-budget 0 : sin modo de razonamiento (Qwen3 pensaría antes de contestar; en CPU son segundos de más)
# --alias        : el nombre que JUEZ_MODEL puede usar
# Las peticiones llevan `response_format: json_schema` (enum cerrado): llama-server lo convierte en una gramática y la salida nunca se sale del vocabulario.
CMD ["-m", "/models/qwen3-1.7b-q4_k_m.gguf", "--host", "0.0.0.0", "--port", "8080", "-c", "4096", "-np", "2", "--threads", "4", \
     "--cache-reuse", "256", "--reasoning-budget", "0", "--jinja", "--alias", "qwen3-1.7b", "--metrics"]
# Salud: GET /health del propio servidor (la imagen base no trae curl: el healthcheck lo define el docker-compose con el cliente que haya).
