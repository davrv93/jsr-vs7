"""Pruebas del verificador (app/verificar.py): sin red; usa el modelo de embeddings local. Se ejecutan a mano y en el build:

    python -m app.prueba_verificar
"""
from __future__ import annotations

import os
import subprocess
import sys

import logging

logging.getLogger("agente.verificar").setLevel(logging.CRITICAL)      # la prueba apunta a un NLI que no existe, a propósito

from .modelo import Embedder
from . import verificar as V

fallos: list[str] = []
total = 0


def caso(nombre, obtenido, esperado):
    global total
    total += 1
    if obtenido != esperado:
        fallos.append(f"   ✗ {nombre}: {obtenido!r} (esperado {esperado!r})")


ART = ("Excel se cierra solo o se congela. Abre Excel en modo seguro: pulsa Windows + R, escribe excel /safe y pulsa Enter. "
       "Si en modo seguro funciona, desactiva los complementos en Archivo > Opciones > Complementos > «Ir…». "
       "Guarda una copia del archivo con otro nombre en Archivo > «Guardar como». Cierra los demás programas pesados mientras trabajas con archivos grandes.")
USUARIO = "mi excel se cierra solo cuando abro un archivo grande"

# AGENTS.md regla 6: lo nuevo no decide sin pasar por sombra. Sin la variable de entorno el modo es `sombra`; `activo` hay que pedirlo.
def modo_con(valor: str | None) -> str:
    entorno = {k: v for k, v in os.environ.items() if k != "VERIFICAR_MODO"} | ({"VERIFICAR_MODO": valor} if valor is not None else {})
    r = subprocess.run([sys.executable, "-c", "from app import verificar; print(verificar.MODO)"], env=entorno, capture_output=True, text=True, timeout=120)
    return r.stdout.strip()


caso("modo por defecto · sombra", modo_con(None), "sombra")
caso("modo por entorno · activo explícito", modo_con("activo"), "activo")
caso("modo por entorno · apagado", modo_con("apagado"), "apagado")

caso("dividir_frases · numeración y decimales", V.dividir_frases("1. Abre Excel.\n2. Versión 10.0.19045 y listo."), ["Abre Excel.", "Versión 10.0.19045 y listo."])
caso("dividir_frases · vacío", V.dividir_frases(""), [])
d = V.datos_en("Pulsa Windows + R, escribe excel /safe y espera 15 minutos en Archivo > Opciones.")
caso("datos_en · teclas", d["teclas"], ["windows+r"])
caso("datos_en · comando", d["comandos"], ["excel /safe"])
caso("datos_en · número", d["numeros"], ["15"])
caso("datos_en · menú", "opciones" in d["menus"] and "archivo" in d["menus"], True)
caso("datos_en · verbos de paso", {"pulsa", "escribe"} <= set(d["verbos"]), True)
caso("datos_en · «espera» y «revisa» no son pasos que haya que respaldar", V.datos_en("Espera un momento y revisa tu bandeja.")["verbos"], [])
caso("datos_en · con pronombre pegado («envíame»)", V.datos_en("Envíame tu clave y ábrelo luego.")["verbos"], ["envia", "abre"])
caso("datos_en · comando con todas sus banderas", V.datos_en("Abre Excel con excel /safe /recover.")["comandos"], ["excel /safe /recover"])
caso("datos_en · menú con sus tres niveles", V.datos_en("Luego ve a Archivo > Información > «Herramientas de limpieza».")["menus"][:2], ["archivo", "informacion"])
caso("pedir una contraseña nunca está respaldado", V.Verificador(Embedder(), nli=None).revisar("Envíame tu contraseña para ayudarte.", ["Abre Excel en modo seguro."], [], modo="activo")["texto"], "")
caso("datos_en · sin datos", {k: v for k, v in V.datos_en("Entiendo, lamento el inconveniente.").items() if v}, {})

emb = Embedder()
ver = V.Verificador(emb, nli=None)

def respaldadas(texto, fuentes=(ART,), ctx=(USUARIO,)):
    r = ver.revisar(texto, list(fuentes), list(ctx), modo="activo")
    return [f["respaldada"] for f in r["frases"]], r

# Lo fiel pasa.
ok, _ = respaldadas("Entiendo, vamos a revisar tu Excel. Abre Excel en modo seguro con Windows + R.")
caso("fiel · cortesía y paso de la fuente", ok, [True, True])
ok, _ = respaldadas("Guarda una copia del archivo con otro nombre.")
caso("fiel · paso de la fuente", ok, [True])
ok, _ = respaldadas("Lamento que Excel se cierre solo con archivos grandes.")
caso("fiel · eco de lo que dijo la persona", ok, [True])
ok, _ = respaldadas("¿Te aparece algún mensaje de error?")
caso("fiel · las preguntas no se verifican", ok, [True])
# Lo inventado se quita.
for inventada in ("Espera 15 minutos antes de volver a abrirlo.", "Ejecuta ipconfig /renew en el símbolo del sistema.", "Reinstala Windows y listo.",
                  "Borra la carpeta C:\\Windows\\Temp.", "Esto suele deberse a un virus en tu equipo.", "Llama a la extensión 4455 de soporte.",
                  "Desinstala el antivirus y reinicia el router."):
    ok, r = respaldadas(inventada)
    caso(f"inventada · {inventada}", ok, [False])
# Mezcla: se queda lo fiel y se va lo inventado.
r = ver.revisar("Entiendo. Abre Excel en modo seguro. Luego reinstala Windows.", [ART], [USUARIO], modo="activo")
caso("mezcla · el texto queda sin la inventada", r["texto"], "Entiendo. Abre Excel en modo seguro.")
caso("mezcla · pide regenerar", r["regenerar"], True)
caso("mezcla · dice cuál quitó y por qué", len(r["quitadas"]) == 1 and "Windows" in r["quitadas"][0]["texto"] and bool(r["quitadas"][0]["motivo"]), True)
# Modos.
r = ver.revisar("Reinstala Windows y listo.", [ART], [USUARIO], modo="sombra")
caso("sombra · registra pero no quita", (r["texto"], len(r["quitadas"]), r["regenerar"]), ("Reinstala Windows y listo.", 1, False))
r = ver.revisar("Reinstala Windows y listo.", [ART], [USUARIO], modo="apagado")
caso("apagado · no revisa", (r["texto"], r["frases"]), ("Reinstala Windows y listo.", []))
caso("vacío", ver.revisar("", [ART])["texto"], "")
# El dato puede estar respaldado por lo que la persona dijo, no solo por el artículo.
ok, _ = respaldadas("Veo que desde hace 3 días te pasa.", ctx=("me pasa desde hace 3 días",))
caso("dato respaldado por el mensaje de la persona", ok, [True])
ok, _ = respaldadas("Veo que desde hace 3 días te pasa.")
caso("dato que nadie dijo", ok, [False])
# ¿Contestó?
caso("contesta · sí", ver.contesta("¿cómo hago para que Excel no se cierre solo?", "Abre Excel en modo seguro con Windows + R y desactiva los complementos.") >= V.TAU_CONTESTA, True)
caso("contesta · no", ver.contesta("¿cómo hago para que Excel no se cierre solo?", "La reunión general es el lunes a las 9.") >= V.TAU_CONTESTA, False)
caso("contesta · vacío", ver.contesta("", "algo"), 0.0)
# Sin NLI instalado, el verificador sigue funcionando (degrada).
n = V.NLI(carpeta="/no/existe")
caso("NLI inexistente degrada sin error", (n.disponible(), n.probs("a", "b")), (False, None))
ver2 = V.Verificador(emb, nli=n)
caso("verificador con NLI ausente funciona igual", ver2.revisar("Reinstala Windows.", [ART], [USUARIO], modo="activo")["texto"], "")
# Rarezas
for raro in ("a" * 5000, "😀" * 300, "¿" * 100, "1. 2. 3.", "\n\n\n"):
    try:
        ver.revisar(raro, [ART], [USUARIO], pregunta="x")
        caso(f"rareza {raro[:6]!r}", True, True)
    except Exception as e:  # noqa: BLE001
        caso(f"rareza {raro[:6]!r}", repr(e), "sin error")

print(f"prueba_verificar: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
