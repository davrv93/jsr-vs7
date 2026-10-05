"""Medidas comunes (exactitud, macro-F1, ECE, percentiles). Sin dependencias pesadas."""
from __future__ import annotations

import math


def exactitud(esp: list, obt: list) -> float:
    return sum(a == b for a, b in zip(esp, obt)) / len(esp) if esp else 0.0


def macro_f1(esp: list, obt: list) -> float:
    """Media de la F1 de cada clase que aparece en lo esperado (las clases que nunca se esperan no cuentan)."""
    clases = sorted(set(esp))
    f1s = []
    for c in clases:
        tp = sum(1 for a, b in zip(esp, obt) if a == c and b == c)
        fp = sum(1 for a, b in zip(esp, obt) if a != c and b == c)
        fn = sum(1 for a, b in zip(esp, obt) if a == c and b != c)
        f1s.append(0.0 if tp == 0 else 2 * tp / (2 * tp + fp + fn))
    return sum(f1s) / len(f1s) if f1s else 0.0


def ece(confianza: list[float], acierto: list[bool], cubos: int = 10) -> float:
    """Error de calibración esperado: 0 = «0,8» acierta 8 de cada 10."""
    if not confianza:
        return 0.0
    total, err = len(confianza), 0.0
    for k in range(cubos):
        lo, hi = k / cubos, (k + 1) / cubos
        idx = [i for i, c in enumerate(confianza) if lo <= c < hi or (k == cubos - 1 and c == 1.0)]
        if idx:
            err += len(idx) / total * abs(sum(acierto[i] for i in idx) / len(idx) - sum(confianza[i] for i in idx) / len(idx))
    return err


def auroc(puntajes: list[float], etiquetas: list[bool]) -> float:
    """Área bajo la curva ROC (probabilidad de que una frase mala puntúe más alto que una buena; empates cuentan la mitad)."""
    pos = [p for p, e in zip(puntajes, etiquetas) if e]
    neg = [p for p, e in zip(puntajes, etiquetas) if not e]
    if not pos or not neg:
        return float("nan")
    ganadas = sum((1.0 if a > b else 0.5 if a == b else 0.0) for a in pos for b in neg)
    return ganadas / (len(pos) * len(neg))


def percentil(valores: list[float], p: float) -> float:
    if not valores:
        return 0.0
    v = sorted(valores)
    k = max(0, min(len(v) - 1, math.ceil(p / 100 * len(v)) - 1))
    return v[k]


def curva_cobertura(confianza: list[float], acierto: list[bool], umbrales=(0.5, 0.6, 0.7, 0.8, 0.9)) -> list[tuple[float, float, float]]:
    """Por umbral: (umbral, cobertura = % de mensajes con confianza ≥ umbral, precisión de ese grupo)."""
    out = []
    for u in umbrales:
        idx = [i for i, c in enumerate(confianza) if c >= u]
        out.append((u, len(idx) / len(confianza) if confianza else 0.0, (sum(acierto[i] for i in idx) / len(idx)) if idx else 0.0))
    return out
