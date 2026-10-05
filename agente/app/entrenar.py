"""Entrena los clasificadores (intención y categoría) y guarda los artefactos versionados.

    python -m app.entrenar                 # entrena, mide sobre el RESERVADO, guarda en index/v1 y lo publica
    python -m app.entrenar --version v2    # otra versión (no se publica sola; se compara con la actual)

Tres medidas, de la más optimista a la más honesta:
1. Validación cruzada agrupada (las tres variantes de una frase caen siempre en el mismo pliegue).
2. Con y sin calibración, ECE sobre esa validación.
3. El conjunto RESERVADO (data/prueba_soporte.csv): frases que NO entran al entrenamiento. Es la cifra que cuenta
   (AGENTS.md §1.4 regla 11).
"""
from __future__ import annotations

import argparse
import json
import os
import time
from collections import Counter

import numpy as np

from . import datos, lenguaje, medidas
from .modelo import Embedder, carpeta, entrenar_cabeza, guardar, nuevo_pipeline, publicar, version_actual

PISO_EXACTITUD = float(os.environ.get("EXACTITUD_MINIMA", "0.85"))
UMBRAL_INTENCION = float(os.environ.get("UMBRAL_INTENCION", "0.45"))   # por debajo: «no se entendió bien»
UMBRAL_CATEGORIA = float(os.environ.get("UMBRAL_CATEGORIA", "0.45"))


def validacion_cruzada(X, y, grupos, pliegues: int = 5) -> dict:
    from sklearn.model_selection import GroupKFold

    pred = np.empty(len(y), dtype=object)
    for tr, te in GroupKFold(n_splits=pliegues).split(X, y, grupos):
        p = nuevo_pipeline().fit(X[tr], [y[i] for i in tr])
        pred[te] = p.predict(X[te])
    return {"exactitud": round(medidas.exactitud(y, list(pred)), 4), "f1_macro": round(medidas.macro_f1(y, list(pred)), 4),
            "pred": list(pred)}


def evaluar_reservado(emb, cab_i, cab_c, imprimir: bool = True) -> dict:
    """Intención (todas las filas) y categoría (las filas que traen categoría) sobre el conjunto reservado."""
    filas = datos.prueba()
    X = emb([f["mensaje"] for f in filas])
    Pi = cab_i.predict_proba(X)
    pred_i = [str(cab_i.classes_[int(np.argmax(p))]) for p in Pi]
    conf_i = [float(p.max()) for p in Pi]
    esp_i = [f["intencion"] for f in filas]
    fallos_i = [f"{f['mensaje']} → {p} {c:.2f} (esperado {f['intencion']})" for f, p, c in zip(filas, pred_i, conf_i) if p != f["intencion"]]
    ok_i = [a == b for a, b in zip(esp_i, pred_i)]
    res = {"n": len(filas), "exactitud": round(medidas.exactitud(esp_i, pred_i), 4), "f1_macro": round(medidas.macro_f1(esp_i, pred_i), 4),
           "ece": round(medidas.ece(conf_i, ok_i), 4), "fallos": fallos_i,
           "cobertura": [(u, round(c, 3), round(p, 3)) for u, c, p in medidas.curva_cobertura(conf_i, ok_i)]}
    con_cat = [k for k, f in enumerate(filas) if f["categoria"]]
    Pc = cab_c.predict_proba(X[con_cat])
    pred_c = [str(cab_c.classes_[int(np.argmax(p))]) for p in Pc]
    conf_c = [float(p.max()) for p in Pc]
    esp_c = [filas[k]["categoria"] for k in con_cat]
    ok_c = [a == b for a, b in zip(esp_c, pred_c)]
    # lo que de verdad hace el agente: el clasificador y, si duda, las palabras clave (lenguaje.categoria_final)
    pred_p = [lenguaje.categoria_final(filas[k]["mensaje"], p, c)[0] for k, p, c in zip(con_cat, pred_c, conf_c)]
    res_c = {"n": len(con_cat), "exactitud": round(medidas.exactitud(esp_c, pred_c), 4), "f1_macro": round(medidas.macro_f1(esp_c, pred_c), 4),
             "exactitud_con_palabras": round(medidas.exactitud(esp_c, pred_p), 4), "f1_macro_con_palabras": round(medidas.macro_f1(esp_c, pred_p), 4),
             "ece": round(medidas.ece(conf_c, ok_c), 4),
             "fallos": [f"{filas[k]['mensaje']} → {p} {c:.2f} (esperado {filas[k]['categoria']})"
                        for k, p, c in zip(con_cat, pred_c, conf_c) if p != filas[k]["categoria"]]}
    if imprimir:
        print(f"intención  RESERVADO: exactitud={res['exactitud']} macro-F1={res['f1_macro']} ECE={res['ece']} "
              f"({res['n'] - len(fallos_i)}/{res['n']})")
        for x in fallos_i:
            print("   ✗", x)
        print(f"categoría  RESERVADO: exactitud={res_c['exactitud']} macro-F1={res_c['f1_macro']} ECE={res_c['ece']} "
              f"({res_c['n'] - len(res_c['fallos'])}/{res_c['n']})  · con las palabras clave de respaldo: exactitud={res_c['exactitud_con_palabras']} macro-F1={res_c['f1_macro_con_palabras']}")
        for x in res_c["fallos"]:
            print("   ✗", x)
    return {"intencion": res, "categoria": res_c}


def entrenar(version: str | None = None, extra: list[dict] | None = None, emb: Embedder | None = None, imprimir: bool = True) -> dict:
    """Entrena y guarda en index/<version>. `extra`: ejemplos revisados [{mensaje, intencion?, categoria?}] que se suman."""
    t0 = time.time()
    version = version or version_actual()
    emb = emb or Embedder()
    if imprimir:
        print(f"modelo de embeddings: {emb.model_name}   versión: {version}")
    sol = datos.solapes()
    assert not sol, f"el reservado comparte frases con el entrenamiento: {sol[:3]}"

    ei = datos.ejemplos_intencion()
    ec = datos.ejemplos_categoria()
    for k, r in enumerate(extra or []):
        m = (r.get("mensaje") or "").strip()
        if not m:
            continue
        if r.get("intencion") in datos.INTENCIONES:
            ei.append(datos.Ejemplo(m, r["intencion"], "revisado", f"XR{k}"))
        if r.get("categoria") in datos.CATEGORIAS:
            ec.append(datos.Ejemplo(m, r["categoria"], "revisado", f"XC{k}"))
    Xi, yi, gi = emb([e.texto for e in ei]), [e.etiqueta for e in ei], [e.grupo for e in ei]
    Xc, yc, gc = emb([e.texto for e in ec]), [e.etiqueta for e in ec], [e.grupo for e in ec]
    if imprimir:
        print("intenciones:", dict(sorted(Counter(yi).items())))
        print("categorías :", dict(sorted(Counter(yc).items())))

    cv_i, cv_c = validacion_cruzada(Xi, yi, gi), validacion_cruzada(Xc, yc, gc)
    por_variante = {}
    for v in ("correcta", "informal", "errores_ortograficos"):
        idx = [k for k, e in enumerate(ei) if e.variante == v]
        if idx:
            por_variante[v] = round(sum(cv_i["pred"][k] == yi[k] for k in idx) / len(idx), 4)
    if imprimir:
        print(f"intención  CV: exactitud={cv_i['exactitud']} macro-F1={cv_i['f1_macro']} por variante={por_variante}")
        print(f"categoría  CV: exactitud={cv_c['exactitud']} macro-F1={cv_c['f1_macro']}")

    cab_i = entrenar_cabeza(Xi, yi, gi)
    cab_c = entrenar_cabeza(Xc, yc, gc)
    cab_i_sin = entrenar_cabeza(Xi, yi, gi, calibrar=False)
    if imprimir:
        print(f"temperatura de calibración: intención T={cab_i.T:.2f}  categoría T={cab_c.T:.2f}")
    res = evaluar_reservado(emb, cab_i, cab_c, imprimir)
    # Para ver qué aporta calibrar: ECE del reservado sin escalar (T = 1).
    X_res = emb([f["mensaje"] for f in datos.prueba()])
    P0 = cab_i_sin.predict_proba(X_res)
    esp = [f["intencion"] for f in datos.prueba()]
    ece_sin = round(medidas.ece([float(p.max()) for p in P0], [str(cab_i_sin.classes_[int(np.argmax(p))]) == e for p, e in zip(P0, esp)]), 4)
    if imprimir:
        print(f"ECE intención en el reservado: sin calibrar {ece_sin} → calibrado {res['intencion']['ece']}")

    guardar("intencion.pkl", cab_i, version)
    guardar("categoria.pkl", cab_c, version)
    guardar("ejemplos.pkl", {"intencion": ei, "categoria": ec, "Xi": Xi, "Xc": Xc}, version)
    metricas = {
        "version": version, "modelo_embeddings": emb.model_name, "n_ejemplos_intencion": len(ei), "n_ejemplos_categoria": len(ec),
        "intencion": {"cv": {k: v for k, v in cv_i.items() if k != "pred"} | {"por_variante": por_variante},
                      "reservado": {k: v for k, v in res["intencion"].items() if k != "fallos"}, "fallos": res["intencion"]["fallos"],
                      "T": round(cab_i.T, 3), "ece_sin_calibrar": ece_sin},
        "categoria": {"cv": {k: v for k, v in cv_c.items() if k != "pred"},
                      "reservado": {k: v for k, v in res["categoria"].items() if k != "fallos"}, "fallos": res["categoria"]["fallos"],
                      "T": round(cab_c.T, 3)},
        "umbral_intencion": UMBRAL_INTENCION, "umbral_categoria": UMBRAL_CATEGORIA,
        "segundos": round(time.time() - t0, 1),
    }
    with open(os.path.join(carpeta(version), "metricas.json"), "w", encoding="utf-8") as f:
        json.dump(metricas, f, ensure_ascii=False, indent=1)
    return metricas


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="", help="p. ej. v2; por defecto, la actual (o v1 si no hay ninguna)")
    a = ap.parse_args(argv)
    sin_ninguna = not os.path.exists(os.path.join(carpeta("v1"), "intencion.pkl")) and not a.version
    version = a.version or ("v1" if sin_ninguna else version_actual())
    m = entrenar(version)
    if not a.version or sin_ninguna:
        publicar(version)
    r_i, r_c = m["intencion"]["reservado"], m["categoria"]["reservado"]
    print(f"== {version}: intención exactitud {r_i['exactitud']} macro-F1 {r_i['f1_macro']} · "
          f"categoría exactitud {r_c['exactitud']} macro-F1 {r_c['f1_macro']} (conjunto reservado) · {m['segundos']} s")
    # La meta es 0,90, pero la cuantización del modelo de embeddings hace que la cifra cambie ±3 puntos entre plataformas (LEEME.md): el build solo cae
    # bajo un piso de seguridad, que detecta datos rotos o un modelo que no cargó, no una variación numérica.
    if min(r_i["exactitud"], r_c["exactitud"]) < PISO_EXACTITUD:
        print(f"✗ por debajo del piso de seguridad ({PISO_EXACTITUD}): los datos o el modelo están rotos")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
