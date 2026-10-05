"""Pruebas del ánimo y la urgencia (app/animo.py). Sin red ni modelos.

    python -m app.prueba_animo
"""
from __future__ import annotations

import sys

from . import memoria as M
from .animo import evaluar

fallos: list[str] = []
total = 0


def caso(nombre, obtenido, esperado):
    global total
    total += 1
    if obtenido != esperado:
        fallos.append(f"   ✗ {nombre}: {obtenido!r} (esperado {esperado!r})")


CASOS = [  # (mensaje, animo, queja)
    ("no me abre el correo desde esta mañana", "neutro", False),
    ("hola, buenas tardes", "neutro", False),
    ("la impresora del tercer piso no imprime", "neutro", False),
    ("gracias por la ayuda", "neutro", False),
    ("ya funcionó, gracias", "neutro", False),
    ("estoy molesto porque nadie me responde", "molesto", True),
    ("es la tercera vez que reporto esto y nadie lo soluciona", "molesto", True),
    ("otra vez se cayó el internet, qué lata", "molesto", False),
    ("el sistema va lentísimo hoy", "molesto", False),
    ("pésima atención, esto es una burla", "muy_negativo", True),
    ("inaceptable, ya llevo una semana sin mi laptop", "muy_negativo", True),
    ("ESTO NO PUEDE SEGUIR ASÍ, NADIE HACE NADA", "muy_negativo", True),
    ("son unos inútiles, qué desastre de servicio", "muy_negativo", True),
    ("quiero presentar una queja formal por la demora", "muy_negativo", True),
    ("mi compu no prende!!!", "molesto", False),
    ("🙂 hola", "neutro", False),
    ("😡😡 no funciona", "molesto", False),
    ("", "neutro", False),
]
for msg, animo, queja in CASOS:
    r = evaluar(msg)
    caso(f"ánimo de {msg!r}", r["animo"], animo)
    caso(f"queja de {msg!r}", r["queja"], queja)

caso("urgencia: «urgente»", evaluar("es urgente, tengo cierre contable hoy")["urgencia"] >= 0.5, True)
caso("urgencia: sin señales", evaluar("no me abre el correo")["urgencia"], 0.0)
caso("urgencia: «no podemos trabajar»", evaluar("no podemos trabajar")["urgencia"] >= 0.5, True)
m = M.nueva()
m["sabemos"]["urgencia"] = "critica"
caso("urgencia: la ficha la sube", evaluar("hola", m)["urgencia"], 1.0)
m["sabemos"]["urgencia"] = None
m["sabemos"]["caida"] = True
caso("urgencia: una caída la sube", evaluar("hola", m)["urgencia"] >= 0.8, True)
caso("sentimiento en rango", all(-1 <= evaluar(x)["sentimiento"] <= 0 for x, _, _ in CASOS), True)
caso("motivo en español", evaluar("pésima atención")["motivo"] != "sin señales", True)
for raro in (None, "a" * 20000, "\x00" * 100, "😡" * 500):
    try:
        evaluar(raro)
        caso(f"rareza {str(raro)[:8]!r}", True, True)
    except Exception as e:  # noqa: BLE001
        caso(f"rareza {str(raro)[:8]!r}", repr(e), "sin error")

print(f"prueba_animo: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
