"""Lector minimo del subconjunto de YAML que usan los meta.yaml (sin dependencias externas).

Soporta: «clave: valor» (texto, entre comillas dobles, numero), listas de textos («- texto») y listas de
mapas planos («- clave: valor» seguido de lineas con mas sangria). Es un subconjunto estricto de YAML: cualquier
lector YAML completo entiende los mismos archivos. Los comentarios empiezan por # al inicio de una linea.
"""
import re


def _escalar(txt):
    txt = txt.strip()
    if txt.startswith('"'):
        if not txt.endswith('"') or len(txt) < 2:
            raise ValueError("comillas sin cerrar: " + txt)
        cuerpo = txt[1:-1]
        return re.sub(r'\\(["\\])', r"\1", cuerpo)
    if re.fullmatch(r"-?\d+", txt):
        return int(txt)
    if re.fullmatch(r"-?\d+\.\d+", txt):
        return float(txt)
    if txt in ("true", "false"):
        return txt == "true"
    return txt


def cargar(texto):
    out = {}
    clave = None
    item_mapa = None
    for n, crudo in enumerate(texto.splitlines(), start=1):
        if not crudo.strip() or crudo.lstrip().startswith("#"):
            continue
        sangria = len(crudo) - len(crudo.lstrip(" "))
        linea = crudo.strip()
        if sangria == 0:
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$", linea)
            if not m:
                raise ValueError("linea %d no valida: %r" % (n, crudo))
            clave, valor = m.group(1), m.group(2)
            item_mapa = None
            if valor is None or valor == "":
                out[clave] = []
            else:
                out[clave] = _escalar(valor)
        else:
            if clave is None or not isinstance(out[clave], list):
                raise ValueError("linea %d: sangria sin lista" % n)
            if linea.startswith("- "):
                cuerpo = linea[2:]
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$", cuerpo)
                if m and not cuerpo.startswith('"'):
                    item_mapa = {m.group(1): _escalar(m.group(2) or "")}
                    out[clave].append(item_mapa)
                else:
                    item_mapa = None
                    out[clave].append(_escalar(cuerpo))
            else:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$", linea)
                if not m or item_mapa is None:
                    raise ValueError("linea %d no valida: %r" % (n, crudo))
                item_mapa[m.group(1)] = _escalar(m.group(2) or "")
    return out


def cargar_archivo(ruta):
    with open(ruta, encoding="utf-8") as f:
        return cargar(f.read())
