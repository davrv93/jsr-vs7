# jsrbot · agente de la mesa de ayuda: clasificador local (e5 int8 + regresión logística) + memoria + etapas + RAG + redacción + verificación.
# El modelo de embeddings y los clasificadores entrenados quedan HORNEADOS en la imagen: arrancar no descarga nada ni re-entrena.
# Al construir: se entrena, se imprime la exactitud y el macro-F1 sobre el conjunto reservado (mira «== v1» en el log) y corren las pruebas y la
# regresión. Si algo falla, la imagen no se construye.
#
#   docker build -t jsrbot_agente ./agente
#   docker run --rm -p 8000:8000 jsrbot_agente
#   NLI opcional (mDeBERTa int8, 317 MB, MIT):  docker build --build-arg CON_NLI=1 -t jsrbot_agente ./agente   y luego  -e VERIFICAR_NLI=1
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    EMBED_CACHE_DIR=/models AGENTE_INDEX_DIR=/app/index AGENTE_DATA_DIR=/app/data SEED_ARTICULOS=/app/seed/articulos.json
ARG EMBED_MODEL=Xenova/multilingual-e5-small
ENV EMBED_MODEL=${EMBED_MODEL}

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Entrenar solo depende de los datos y de estos módulos: tocar main.py no obliga a re-entrenar (la capa se reutiliza).
COPY data ./data
COPY app/__init__.py app/datos.py app/lenguaje.py app/medidas.py app/modelo.py app/entrenar.py ./app/
# Descarga el modelo de embeddings, entrena intención y categoría (calibradas), mide sobre el RESERVADO (data/prueba_soporte.csv) y guarda index/v1.
RUN python -m app.entrenar && chmod -R a+rX /models /app/index

# NLI opcional del verificador (parte b de Jev local). Revisión y SHA-256 fijos: si no coinciden, el build falla.
ARG CON_NLI=0
ARG NLI_REV=0864ced79bf1ef851bfaf9dd9de0aa54d735d9d0
ARG NLI_SHA256=0e00534691cac71d2a9a0319bce19df9d7c6f003acea00bef9967560584c1a77
ARG NLI_TOKENIZER_SHA256=e23095eb61ba944c7be3a5d3e8ec19e37ce7ced0daa03550bde03e83c21b3f8a
RUN if [ "$CON_NLI" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/* \
      && mkdir -p /models/nli/onnx \
      && B=https://huggingface.co/Xenova/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7/resolve/${NLI_REV} \
      && curl -fL --retry 4 -o /models/nli/onnx/model_int8.onnx $B/onnx/model_int8.onnx \
      && curl -fL --retry 4 -o /models/nli/tokenizer.json $B/tokenizer.json \
      && curl -fL --retry 4 -o /models/nli/config.json $B/config.json \
      && echo "${NLI_SHA256}  /models/nli/onnx/model_int8.onnx" | sha256sum -c - \
      && echo "${NLI_TOKENIZER_SHA256}  /models/nli/tokenizer.json" | sha256sum -c - \
      && chmod -R a+rX /models/nli && apt-get purge -y curl && apt-get autoremove -y; \
    fi
ENV NLI_DIR=/models/nli

COPY seed ./seed
COPY app ./app
# Las pruebas se ejecutan en CADA build: si un cambio rompe la memoria, las etapas, la seguridad, la respuesta, el verificador, el juez, la API o la
# regresión (preguntas, conversaciones, entradas raras y carga, sin LLM), la imagen no se construye.
RUN python -m app.prueba_memoria && python -m app.prueba_etapas && python -m app.prueba_seguridad && python -m app.prueba_animo \
 && python -m app.prueba_estructurado && python -m app.prueba_verificar && python -m app.prueba_juez && python -m app.prueba_api && python -m app.regresion
# El modelo ya está dentro: que nada intente bajarlo de Hugging Face al arrancar, ni re-entrenar.
ENV HF_HUB_OFFLINE=1 AUTO_ENTRENAR=0

RUN useradd -r -u 10001 agente && chown -R agente /app/index
USER agente
EXPOSE 8000
HEALTHCHECK --interval=60s --timeout=5s --start-period=60s --retries=3 \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/salud',timeout=4)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
