#!/usr/bin/env python3
"""Regenera analitica/catalogo.json desde los meta.yaml de analitica/golden/*/.

El catalogo lo leen el backend (para ejecutar la golden query de un KPI) y el analista (para buscar la mas parecida por
las preguntas equivalentes). No se edita a mano: se cambia el meta.yaml y se vuelve a correr este script.

Uso:
  python3 herramientas/generar_catalogo.py            # escribe analitica/catalogo.json
  python3 herramientas/generar_catalogo.py --verificar # sale con 1 si catalogo.json no esta al dia
"""
import hashlib
import json
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
import miniyaml  # noqa: E402

RAIZ = os.path.abspath(os.path.join(AQUI, ".."))
GOLDEN = os.path.join(RAIZ, "golden")
SALIDA = os.path.join(RAIZ, "catalogo.json")
OBLIGATORIAS = ["kpi", "nombre", "version", "unidad", "dueno", "definicion", "base", "parametros", "columnas",
                "preguntas_equivalentes", "pruebas"]
PARAMETROS_VALIDOS = {"desde", "hasta", "grupo"}


def versiones_de(carpeta):
    vs = []
    for f in os.listdir(carpeta):
        m = re.fullmatch(r"v(\d+)\.sql", f)
        if m:
            vs.append(int(m.group(1)))
    return sorted(vs)


def construir():
    kpis = []
    for nombre in sorted(os.listdir(GOLDEN)):
        carpeta = os.path.join(GOLDEN, nombre)
        meta_ruta = os.path.join(carpeta, "meta.yaml")
        if not os.path.isfile(meta_ruta):
            continue
        meta = miniyaml.cargar_archivo(meta_ruta)
        faltan = [k for k in OBLIGATORIAS if k not in meta or meta[k] in ("", [], None)]
        if faltan:
            raise SystemExit("%s/meta.yaml: faltan campos %s" % (nombre, faltan))
        if meta["kpi"] != nombre:
            raise SystemExit("%s/meta.yaml: kpi=%r no coincide con la carpeta" % (nombre, meta["kpi"]))
        if len(meta["preguntas_equivalentes"]) < 4:
            raise SystemExit("%s/meta.yaml: hacen falta al menos 4 preguntas_equivalentes" % nombre)
        malos = set(meta["parametros"]) - PARAMETROS_VALIDOS
        if malos:
            raise SystemExit("%s/meta.yaml: parametros desconocidos %s" % (nombre, sorted(malos)))
        versiones = versiones_de(carpeta)
        if not versiones or meta["version"] != max(versiones):
            raise SystemExit("%s/meta.yaml: version=%s pero hay %s" % (nombre, meta["version"], ["v%d.sql" % v for v in versiones]))
        vigente = "v%d.sql" % meta["version"]
        with open(os.path.join(carpeta, vigente), "rb") as f:
            sql_bytes = f.read()
        usados = set(re.findall(r"\{(\w+):", sql_bytes.decode("utf-8")))
        if usados - PARAMETROS_VALIDOS:
            raise SystemExit("%s/%s usa parametros desconocidos %s" % (nombre, vigente, sorted(usados - PARAMETROS_VALIDOS)))
        if usados != set(meta["parametros"]):
            raise SystemExit("%s: meta.yaml declara parametros %s pero %s usa %s" % (nombre, sorted(meta["parametros"]), vigente, sorted(usados)))
        for p in meta["pruebas"]:
            if not os.path.isfile(os.path.join(carpeta, p["archivo"])):
                raise SystemExit("%s: falta %s (declarado en pruebas)" % (nombre, p["archivo"]))
        kpis.append({
            "kpi": meta["kpi"],
            "nombre": meta["nombre"],
            "version": meta["version"],
            "versiones": versiones,
            "archivo_sql": "golden/%s/%s" % (nombre, vigente),
            "sha256_sql": hashlib.sha256(sql_bytes).hexdigest(),
            "unidad": meta["unidad"],
            "dueno": meta["dueno"],
            "definicion": meta["definicion"],
            "base": meta["base"],
            "parametros": meta["parametros"],
            "atribucion_grupo": meta.get("atribucion_grupo", ""),
            "columnas": meta["columnas"],
            "bordes": meta.get("bordes", []),
            "objetivo": meta.get("objetivo", ""),
            "preguntas_equivalentes": meta["preguntas_equivalentes"],
            "pruebas": meta["pruebas"],
        })
    return {"formato": 1, "nota": "Generado por analitica/herramientas/generar_catalogo.py desde golden/*/meta.yaml. No editar a mano.",
            "kpis": kpis}


def main():
    cat = construir()
    texto = json.dumps(cat, indent=2, ensure_ascii=False) + "\n"
    if "--verificar" in sys.argv:
        actual = open(SALIDA, encoding="utf-8").read() if os.path.exists(SALIDA) else ""
        if actual != texto:
            print("catalogo.json NO esta al dia: corre python3 herramientas/generar_catalogo.py")
            sys.exit(1)
        print("catalogo.json al dia (%d KPI)" % len(cat["kpis"]))
        return
    with open(SALIDA, "w", encoding="utf-8") as f:
        f.write(texto)
    print("catalogo.json escrito: %d KPI" % len(cat["kpis"]))


if __name__ == "__main__":
    main()
