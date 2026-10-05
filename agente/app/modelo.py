"""Embeddings locales (ONNX, sin GPU) y las cabezas clasificadoras que se montan encima.

- Embeddings: multilingual-e5-small cuantizado a int8 (Xenova/multilingual-e5-small, MIT), servido con
  fastembed/onnxruntime. Medido en Baruka: ~2 ms por mensaje y ~500 MB de RAM. Se cambia con EMBED_MODEL.
- e5 distingue consultas de pasajes con un prefijo: los mensajes van como «query: » y los artículos como
  «passage: ». Sin eso recupera peor.
- Cabeza: estandarización + regresión logística (scikit-learn). Los vectores de e5 vienen muy apretados entre sí;
  sin estandarizar, la misma regresión acierta mucho menos.
- Calibración: escalado de temperatura. Se ajusta un solo número T con las predicciones «fuera de pliegue», de modo
  que una confianza de 0,8 acierte de verdad ~8 de cada 10. Con eso los umbrales (cascada del juez, «no entendí»)
  significan algo.
- Versionado: los artefactos viven en index/<versión>/ y index/ACTUAL dice cuál sirve el agente.
"""
from __future__ import annotations

import json
import os
import pickle
import threading

import numpy as np

EMBED_MODEL = os.environ.get("EMBED_MODEL", "Xenova/multilingual-e5-small")
# Modelos que fastembed no trae de fábrica: se registran con su archivo ONNX.
MODELOS_PROPIOS = {
    "Xenova/multilingual-e5-small": {"dim": 384, "model_file": "onnx/model_quantized.onnx"},
    "intfloat/multilingual-e5-small": {"dim": 384, "model_file": "onnx/model.onnx"},
}
_AQUI = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.environ.get("EMBED_CACHE_DIR", os.path.join(_AQUI, "..", "modelos"))
INDEX_DIR = os.environ.get("AGENTE_INDEX_DIR", os.path.join(_AQUI, "..", "index"))


class Embedder:
    def __init__(self, model: str = EMBED_MODEL):
        from fastembed import TextEmbedding

        self.model_name = model
        self.e5 = "e5" in model.lower()
        if model in MODELOS_PROPIOS:
            from fastembed.common.model_description import ModelSource, PoolingType
            try:
                TextEmbedding.add_custom_model(model=model, pooling=PoolingType.MEAN, normalization=True,
                                               sources=ModelSource(hf=model), **MODELOS_PROPIOS[model])
            except ValueError:
                pass  # ya registrado en este proceso
        threads = int(os.environ.get("EMBED_THREADS", "2"))
        self._m = TextEmbedding(model_name=model, cache_dir=CACHE_DIR, threads=threads)
        self._lock = threading.Lock()   # onnxruntime admite hilos, pero así la latencia de cada petición es predecible

    def _vec(self, textos: list[str], prefijo: str, batch: int = 32) -> np.ndarray:
        if not textos:
            return np.zeros((0, 384), dtype=np.float32)
        with self._lock:
            vecs = np.array(list(self._m.embed([prefijo + t for t in textos], batch_size=batch)), dtype=np.float32)
        vecs /= np.linalg.norm(vecs, axis=1, keepdims=True) + 1e-9
        return vecs

    def __call__(self, textos: list[str], batch: int = 1) -> np.ndarray:
        """Mensajes de la persona y cualquier texto que se clasifica o que se usa para buscar.

        De uno en uno (batch=1) a propósito: el modelo está cuantizado de forma dinámica (int8), y la escala de la cuantización depende de
        qué otros textos van en el mismo lote. Así el vector de una frase es el mismo cuando se entrena (miles de frases) que cuando se
        clasifica (una sola), y el entrenamiento se repite igual al reconstruir. Cuesta ~3 ms por frase."""
        return self._vec(textos, "query: " if self.e5 else "", batch)

    def pasajes(self, textos: list[str], batch: int = 32) -> np.ndarray:
        """Artículos de la base de conocimiento: lo que se busca."""
        return self._vec(textos, "passage: " if self.e5 else "", batch)


def _softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


class Cabeza:
    """Clasificador calibrado: estandarizar → regresión logística → softmax(logits / T)."""

    def __init__(self, pipeline, T: float = 1.0):
        self.pipeline = pipeline
        self.T = float(T)

    @property
    def classes_(self):
        return self.pipeline.classes_

    def logits(self, X: np.ndarray) -> np.ndarray:
        z = self.pipeline.decision_function(X)
        return z if z.ndim == 2 else np.stack([-z, z], axis=1)

    def predict_proba(self, X: np.ndarray) -> np.ndarray:
        return _softmax(self.logits(X) / self.T)

    def predict(self, X: np.ndarray) -> np.ndarray:
        return self.classes_[np.argmax(self.logits(X), axis=1)]


def nuevo_pipeline(C: float = 8.0):
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    return make_pipeline(StandardScaler(), LogisticRegression(max_iter=5000, C=C, class_weight="balanced"))


def ajustar_temperatura(logits: np.ndarray, y_idx: np.ndarray) -> float:
    """La T que minimiza la log-verosimilitud negativa (búsqueda en malla; basta con un escalar)."""
    mejor, mejor_nll = 1.0, 1e9
    for T in np.concatenate([np.linspace(0.2, 1.0, 17), np.linspace(1.1, 6.0, 50)]):
        p = _softmax(logits / T)
        nll = -float(np.mean(np.log(p[np.arange(len(y_idx)), y_idx] + 1e-12)))
        if nll < mejor_nll:
            mejor, mejor_nll = float(T), nll
    return mejor


def entrenar_cabeza(X: np.ndarray, y: list[str], grupos: list[str] | None = None, calibrar: bool = True, C: float = 8.0) -> Cabeza:
    """Entrena la cabeza con todo X. Si `calibrar`, ajusta T con validación cruzada agrupada (las tres variantes de
    una frase caen en el mismo pliegue, para no calibrar con lo que ya se vio)."""
    from sklearn.model_selection import GroupKFold

    pipe = nuevo_pipeline(C).fit(X, y)
    cabeza = Cabeza(pipe)
    if calibrar and len(set(y)) > 1:
        y = np.array(y)
        grupos = grupos if grupos is not None else [str(i) for i in range(len(y))]
        clases = list(pipe.classes_)
        oof = np.zeros((len(y), len(clases)))
        for tr, te in GroupKFold(n_splits=5).split(X, y, grupos):
            p = nuevo_pipeline(C).fit(X[tr], y[tr])
            z = p.decision_function(X[te])
            if z.ndim == 1:
                z = np.stack([-z, z], axis=1)
            # Si un pliegue no vio alguna clase, sus columnas quedan en -inf lógico (muy bajo).
            full = np.full((len(te), len(clases)), -20.0)
            for j, c in enumerate(p.classes_):
                full[:, clases.index(c)] = z[:, j]
            oof[te] = full
        cabeza.T = ajustar_temperatura(oof, np.array([clases.index(v) for v in y]))
    return cabeza


# --- artefactos versionados -----------------------------------------------------------------------------

def version_actual() -> str:
    try:
        with open(os.path.join(INDEX_DIR, "ACTUAL"), encoding="utf-8") as f:
            return f.read().strip() or "v1"
    except OSError:
        return "v1"


def carpeta(version: str | None = None) -> str:
    return os.path.join(INDEX_DIR, version or version_actual())


def guardar(nombre: str, obj, version: str | None = None) -> None:
    os.makedirs(carpeta(version), exist_ok=True)
    with open(os.path.join(carpeta(version), nombre), "wb") as f:
        pickle.dump(obj, f)


def cargar(nombre: str, version: str | None = None):
    with open(os.path.join(carpeta(version), nombre), "rb") as f:
        return pickle.load(f)


def publicar(version: str) -> None:
    """Marca `version` como la que sirve el agente (escritura atómica del puntero)."""
    os.makedirs(INDEX_DIR, exist_ok=True)
    tmp = os.path.join(INDEX_DIR, "ACTUAL.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(version)
    os.replace(tmp, os.path.join(INDEX_DIR, "ACTUAL"))


def versiones() -> list[str]:
    try:
        return sorted((d for d in os.listdir(INDEX_DIR) if os.path.isdir(os.path.join(INDEX_DIR, d)) and d.startswith("v")),
                      key=lambda v: int(v[1:]) if v[1:].isdigit() else 0)
    except OSError:
        return []


def siguiente_version() -> str:
    vs = [int(v[1:]) for v in versiones() if v[1:].isdigit()]
    return f"v{max(vs) + 1}" if vs else "v1"


def leer_metricas(version: str | None = None) -> dict:
    try:
        with open(os.path.join(carpeta(version), "metricas.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}
