#!/usr/bin/env python3
"""Compara el resultado de una golden query con su esperado.csv.

Regla (declarada, la misma en todo el proyecto):
  * mismas columnas, en el mismo orden, y mismas filas, en el mismo orden;
  * NULL (\\N) solo es igual a NULL;
  * dos numeros son iguales si |a - b| <= TOLERANCIA (0,006: medio centesimo mas holgura de punto flotante,
    porque los porcentajes y minutos se redondean a 2 decimales);
  * cualquier otra celda debe ser igual como texto.
"""
import csv
import io
import sys

TOLERANCIA = 0.006


def celda(txt):
    if txt == "\\N":
        return None
    try:
        return float(txt)
    except ValueError:
        return txt


def leer_csv(texto):
    filas = list(csv.reader(io.StringIO(texto)))
    if not filas:
        return [], []
    return filas[0], [[celda(c) for c in f] for f in filas[1:]]


def iguales(a, b, tol=TOLERANCIA):
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, float) and isinstance(b, float):
        return abs(a - b) <= tol
    return a == b


def comparar(texto_esperado, texto_obtenido, tol=TOLERANCIA):
    """Devuelve la lista de diferencias (vacia = iguales)."""
    ce, fe = leer_csv(texto_esperado)
    co, fo = leer_csv(texto_obtenido)
    dif = []
    if ce != co:
        dif.append("columnas distintas: esperado %s, obtenido %s" % (ce, co))
        return dif
    if len(fe) != len(fo):
        dif.append("filas distintas: esperado %d, obtenido %d" % (len(fe), len(fo)))
    for i, (a, b) in enumerate(zip(fe, fo), start=1):
        for j, (x, y) in enumerate(zip(a, b)):
            if not iguales(x, y, tol):
                dif.append("fila %d, %s: esperado %r, obtenido %r" % (i, ce[j], x, y))
    return dif


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("uso: comparar_csv.py esperado.csv obtenido.csv")
        sys.exit(2)
    d = comparar(open(sys.argv[1], encoding="utf-8").read(), open(sys.argv[2], encoding="utf-8").read())
    for x in d:
        print(x)
    sys.exit(1 if d else 0)
