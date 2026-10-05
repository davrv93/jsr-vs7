"""Seguridad de los datos que pasan por el agente (AGENTS.md §1.4 reglas 1–2 y §4).

Dos trabajos distintos:

1. **Contraseñas, tokens y claves pegadas por error** (`ocultar_secretos`). Se detectan ANTES de guardar el mensaje y se
   reemplazan por `[oculto]`; el agente devuelve ese texto en `texto_usuario_guardar`, activa la señal
   `contrasena_oculta` y le avisa a la persona (`AVISO_CONTRASENA`). Nada de eso llega nunca a un LLM, ni al Jev local
   ni al registro.
2. **Enmascarado de datos personales** (`enmascarar_pii`) ANTES de cualquier llamada a un LLM externo: nombres, correos,
   DNI, RUC, teléfonos e IP. El LLM de redacción solo ve el caso enmascarado: síntoma, pasos probados, artículo y los
   últimos turnos.

Límites que conviene conocer (y que la prueba documenta):
- Los nombres propios se enmascaran con certeza cuando vienen del perfil, del técnico asignado o de una presentación
  («me llamo Ana», «Ing. Pérez»). Un nombre suelto escrito en minúsculas, sin ninguna de esas pistas, no se puede
  distinguir de una palabra común sin un modelo de entidades; por eso el LLM nunca recibe el mensaje completo sin pasar
  por aquí y el caso que ve es corto.
- Un secreto pegado sin ninguna etiqueta («Perro123» solo) solo se detecta si tiene forma de secreto (largo y mezcla de
  clases de caracteres).

Sin dependencias: se prueba con `python -m app.prueba_seguridad`.
"""
from __future__ import annotations

import re

from .datos import plano

OCULTO = "[oculto]"
AVISO_CONTRASENA = "No compartas tu contraseña por aquí; ya la oculté."

# --- 1. Secretos -------------------------------------------------------------------------------------------------
_RX_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\b")
_RX_CLAVES_CONOCIDAS = [
    re.compile(r"\b(?:sk|pk|rk)-(?:or-|live-|test-|ant-)?[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(r"\b(?:bearer|token)\s+[A-Za-z0-9._~+/=-]{20,}", re.I),
]
_RX_BLOQUE_CLAVE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)", re.S)
# «mi clave es X», «password: X», «contraseña nueva = X», «token: X»
_ETIQUETA = (r"contrase(?:ñ|n)a|clave|password|passwd|pass|pwd|pin|token|api[ _-]?key|apikey|secret|secreto|credenciales?|codigo de acceso|código de acceso|passcode|llave")
_RX_ETIQUETADO = re.compile(
    rf"\b(?P<et>{_ETIQUETA})\b(?P<medio>(?:\s+(?:de|del|para)\s+\w+(?:\s+\w+)?|\s+(?:nueva|actual|anterior|temporal|vieja|antigua))?)\s*"
    rf"(?:(?:es|era|seria|sería|fue|=|:|->|→|-)\s*)+(?:[\"'«“](?P<q>[^\"'»”\n]{{1,100}})[\"'»”]|[\"'«“]?(?P<valor>[^\s\"'»”,;]{{1,200}}))", re.I)
# «la clave que puse fue X», «mi password lo cambié a X»
_RX_ETIQUETADO_LARGO = re.compile(
    rf"\b(?:{_ETIQUETA})\b[^.?!\n]{{0,30}}?\b(?:puse|pongo|uso|usaba|use|usé|cambie|cambié|cambio|escribi|escribí|tecleo|tecleé)\b(?:\s+(?:fue|era|es|como|de|a|en|con))*\s+[\"'«“]?(?P<valor>[^\s\"'»”,;]{{3,200}})", re.I)
# Palabras que, tras «clave es …», describen la clave en vez de serlo.
_NO_SECRETO = set("""la el lo los las mi tu su un una otra otro esa ese esta este que no nunca siempre correcta correcto incorrecta incorrecto invalida
invalido valida valido expirada expirado caducada caducado vencida vencido bloqueada bloqueado antigua antiguo vieja viejo nueva nuevo igual misma mismo
muy demasiado corta corto larga largo debil segura seguro insegura rara raro comun simple complicada dificil facil olvidada olvidado y pero porque cuando como si
ya aun todavia tambien solo solamente para por con sin del al de en se me te le les nos obligatoria obligatorio necesaria necesario temporal personal
secreta secreto privada privado dura fuerte""".split())
# Un token delimitado por espacios con forma de secreto: largo y con mezcla de clases de caracteres.
_RX_SUELTO = re.compile(r"(?<![\w@./:-])[A-Za-z0-9+/_=#$%&*!?@-]{16,200}(?![\w@./:-])")


def _parece_secreto_suelto(tok: str) -> bool:
    if len(tok) < 16 or re.fullmatch(r"[\w.+%-]+@[\w-]+(?:\.[\w-]+)+", tok):     # un correo no es un secreto (se enmascara aparte)
        return False
    clases = sum(bool(re.search(p, tok)) for p in (r"[a-z]", r"[A-Z]", r"\d", r"[^A-Za-z0-9]"))
    if re.fullmatch(r"[0-9a-fA-F]{32,}", tok):                      # hash o clave hexadecimal
        return True
    if re.fullmatch(r"[A-Za-z0-9+/=_-]{24,}", tok) and re.search(r"\d", tok) and re.search(r"[A-Za-z]", tok) and clases >= 3:
        return True                                                    # base64 / clave de API
    return clases >= 3 and len(tok) >= 16 and re.search(r"\d", tok) is not None and re.search(r"[^A-Za-z0-9]", tok) is not None


def _valor_es_secreto(valor: str, etiqueta: str) -> bool:
    v = plano(valor)
    if v in _NO_SECRETO or not v:
        return False
    if len(v) < 3 and not re.fullmatch(r"\d{4,}", v):
        return False
    return True


def ocultar_secretos(texto: str) -> tuple[str, list[str]]:
    """El texto con las contraseñas, tokens y claves reemplazados por `[oculto]`, y los tipos que se encontraron:
    `contrasena` (dicha con su etiqueta), `token` (JWT, Bearer, clave de API), `clave_privada`, `secuencia`
    (algo con forma de secreto, sin etiqueta). Es idempotente: no vuelve a tocar un `[oculto]`."""
    if not isinstance(texto, str) or not texto:
        return texto if isinstance(texto, str) else "", []
    t = texto[:20000]
    tipos: list[str] = []

    def marca(tipo: str) -> None:
        if tipo not in tipos:
            tipos.append(tipo)

    def sub_bloque(m):
        marca("clave_privada")
        return OCULTO

    t = _RX_BLOQUE_CLAVE.sub(sub_bloque, t)

    def sub_jwt(m):
        marca("token")
        return OCULTO

    t = _RX_JWT.sub(sub_jwt, t)
    for rx in _RX_CLAVES_CONOCIDAS:
        t = rx.sub(lambda m: (marca("token"), OCULTO)[1], t)

    def sub_etiqueta(m):
        g = "q" if m.group("q") is not None else "valor"
        v = m.group(g)
        if v == OCULTO or v.startswith("[oculto"):
            return m.group(0)
        # Entre comillas se oculta todo lo que haya, aunque tenga espacios («Mi Clave 99»).
        if g == "valor" and not _valor_es_secreto(v, m.group("et")):
            return m.group(0)
        marca("token" if re.match(r"token|api|secret|llave", m.group("et"), re.I) else "contrasena")
        return m.group(0)[: m.start(g) - m.start(0)] + OCULTO + m.group(0)[m.end(g) - m.start(0):]

    t = _RX_ETIQUETADO.sub(sub_etiqueta, t)
    t = _RX_ETIQUETADO_LARGO.sub(sub_etiqueta_largo(marca), t)

    def sub_suelto(m):
        if _parece_secreto_suelto(m.group(0)):
            marca("secuencia")
            return OCULTO
        return m.group(0)

    t = _RX_SUELTO.sub(sub_suelto, t)
    return t, tipos


def sub_etiqueta_largo(marca):
    def f(m):
        v = m.group("valor")
        if v == OCULTO or v.startswith("[oculto") or not _valor_es_secreto(v, ""):
            return m.group(0)
        marca("contrasena")
        return m.group(0)[: m.start("valor") - m.start(0)] + OCULTO
    return f


def tiene_secreto(texto: str) -> bool:
    return bool(ocultar_secretos(texto)[1])


# --- 2. Datos personales -----------------------------------------------------------------------------------------
_RX_CORREO = re.compile(r"[\w.+%-]+@[\w-]+(?:\.[\w-]+)+")
_RX_IP = re.compile(r"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])")
_RX_HOST = re.compile(r"\b[\w-]+(?:\.[\w-]+)*\.(?:local|lan|corp|internal|intra|interno)\b", re.I)
_RX_TELEFONO = re.compile(r"(?<![\w-])(?:\+?51[\s.-]?)?9\d{2}[\s.-]?\d{3}[\s.-]?\d{3}(?![\w-])|(?<![\w-])\(?0\d{1,2}\)?[\s.-]?\d{3}[\s.-]?\d{4}(?![\w-])|"
                          r"(?<![\w-])\+\d{1,3}[\s.-]?\d{6,12}(?![\w-])")
_RX_RUC = re.compile(r"(?<![\w-])(?:10|15|17|20)\d{9}(?![\w-])")
_RX_DNI = re.compile(r"(?<![\w.-])\d{8}(?![\w-]|\.\d)")
_TITULO = r"(?i:Sr\.?|Sra\.?|Srta\.?|Se(?:ñ|n)or(?:a|ita)?|Ing\.?|Lic\.?|Dr\.?|Dra\.?|Don|Do(?:ñ|n)a|Arq\.?|Mg\.?|Abg\.?|Econ\.?)"
_NOMBRE = r"[A-ZÁÉÍÓÚÑ][a-záéíóúñ]{1,20}"
_RX_TITULO = re.compile(rf"\b{_TITULO}\s+{_NOMBRE}(?:\s+{_NOMBRE}){{0,2}}")
_RX_PRESENTA = re.compile(rf"\b(?:[Mm]e llamo|[Mm]i nombre es|[Ss]oy|[Hh]abla|[Hh]ola,? soy|[Ss]aluda)\s+(?P<n>{_NOMBRE}(?:\s+{_NOMBRE}){{0,2}})")
_RX_RELACION = re.compile(rf"\b(?:[Mm]i |[Ee]l |[Ll]a )?(?:jefe|jefa|gerente|supervisor|supervisora|compa(?:ñ|n)er[oa]|colega|practicante|asistente|t(?:é|e)cnico|t(?:é|e)cnica)\s+(?P<n>{_NOMBRE}(?:\s+{_NOMBRE}){{0,2}})")
# Palabras con mayúscula que NO son nombres de persona aunque sigan a «soy» o a una relación.
_NO_NOMBRE = {"de", "del", "el", "la", "un", "una", "nuevo", "nueva", "Contabilidad", "Logística", "Ventas", "Gerencia", "Sistemas", "Marketing",
              "Finanzas", "Compras", "Legal", "Recepción", "Soporte", "Windows", "Outlook", "Teams", "Excel", "Word", "Centro", "Surco", "Lima",
              "Administración", "Producción", "Calidad", "Operaciones", "Almacén", "Tesorería", "Comercial", "Planillas", "Proyectos", "Recursos", "Humanos"}


def _variantes_nombre(n: str) -> list[str]:
    """Nombre completo y cada palabra de 3 letras o más (para «Ana Ríos» → «Ana Ríos», «Ana», «Ríos»)."""
    partes = [p for p in re.split(r"\s+", n.strip()) if p]
    out = [" ".join(partes)] if len(partes) > 1 else []
    out += [p for p in partes if len(p) >= 3 and p.lower() not in ("del", "los", "las", "van", "von")]
    return out


def enmascarar_pii(texto: str, nombres=(), extra=()) -> tuple[str, dict[str, int]]:
    """El texto sin datos personales, para mandarlo a un LLM externo, y cuántos se enmascararon por tipo.

    `nombres`: nombres que se conocen (perfil, técnico asignado): se enmascaran dondequiera que aparezcan, sin importar
    mayúsculas ni tildes. `extra`: otras cadenas literales a enmascarar (por ejemplo, un correo del perfil).
    Marcadores: [nombre], [correo], [dni], [ruc], [telefono], [ip], [host]. Siempre pasa antes por `ocultar_secretos`.
    """
    if not isinstance(texto, str) or not texto:
        return "", {}
    t, _ = ocultar_secretos(texto[:20000])
    cuenta: dict[str, int] = {}

    def sub(rx, marcador, s, grupo=0):
        def f(m):
            cuenta[marcador] = cuenta.get(marcador, 0) + 1
            if grupo:
                return m.group(0).replace(m.group(grupo), f"[{marcador}]", 1)
            return f"[{marcador}]"
        return rx.sub(f, s)

    t = sub(_RX_CORREO, "correo", t)
    t = sub(_RX_IP, "ip", t)
    t = sub(_RX_HOST, "host", t)
    t = sub(_RX_TELEFONO, "telefono", t)
    t = sub(_RX_RUC, "ruc", t)
    t = sub(_RX_DNI, "dni", t)
    t = sub(_RX_TITULO, "nombre", t)

    def sub_pila(rx, s):
        def f(m):
            n = m.group("n")
            if all(p in _NO_NOMBRE for p in n.split()) or n.split()[0] in _NO_NOMBRE:
                return m.group(0)
            cuenta["nombre"] = cuenta.get("nombre", 0) + 1
            return m.group(0).replace(n, "[nombre]", 1)
        return rx.sub(f, s)

    t = sub_pila(_RX_PRESENTA, t)
    t = sub_pila(_RX_RELACION, t)
    conocidos = []
    for n in nombres or ():
        if isinstance(n, str):
            conocidos += _variantes_nombre(n)
    for v in sorted(set(conocidos), key=len, reverse=True):
        # sin distinguir mayúsculas ni tildes: se busca en el texto plano y se corta en el original
        rx = re.compile(rf"(?<![\w]){re.escape(v)}(?![\w])", re.I)
        t, k = rx.subn("[nombre]", t)
        if not k and plano(v) != v.lower():     # el texto trae «rios» y el nombre «Ríos»
            for m in list(re.finditer(rf"(?<![\w]){re.escape(plano(v))}(?![\w])", plano(t))):
                if len(plano(t)) == len(t):
                    t = t[: m.start()] + "[nombre]" + t[m.end():]
                    k += 1
                    break
        if k:
            cuenta["nombre"] = cuenta.get("nombre", 0) + k
    for e in extra or ():
        if isinstance(e, str) and len(e) >= 4:
            t, k = re.subn(re.escape(e), "[dato]", t, flags=re.I)
            if k:
                cuenta["dato"] = cuenta.get("dato", 0) + k
    return t, cuenta


def sin_datos_personales(texto: str, nombres=()) -> str:
    """El texto sin las cláusulas que traen datos personales («soy Ana Ríos, mi correo es ana@x.pe, el Excel no abre» → «el Excel no abre»).
    Es lo que se guarda como síntoma de la ficha y como título de la incidencia: lo que importa es el problema, no quién lo cuenta. Si todo
    el texto trae datos personales, se devuelve sin ellos pero entero."""
    masc, cuenta = enmascarar_pii(texto, nombres)
    if not cuenta:
        return (texto or "").strip()
    marcador = re.compile(r"\[(?:nombre|correo|dni|ruc|telefono|ip|host|dato)\]")
    partes = [p for p in re.split(r"(?<=[,;.])\s+", masc) if p.strip()]
    buenas = [p for p in partes if not marcador.search(p)]
    if buenas:
        return " ".join(buenas).strip(" ,;")
    return quitar_marcadores(masc)


def nombres_del_caso(perfil: dict | None, incidencias: list | None = (), historial: list | None = ()) -> list[str]:
    """Los nombres que se conocen del caso y hay que enmascarar: la persona (perfil) y los técnicos de sus incidencias."""
    out = []
    if isinstance(perfil, dict) and isinstance(perfil.get("nombre"), str):
        out.append(perfil["nombre"])
    for i in incidencias or ():
        if isinstance(i, dict) and isinstance(i.get("tecnico"), str) and i["tecnico"]:
            out.append(i["tecnico"])
    return out


def quitar_marcadores(texto: str, nombre_pila: str = "") -> str:
    """Si el LLM repite un marcador ([nombre], [correo]…), no debe llegar a la persona: [nombre] se vuelve su nombre de pila
    (o desaparece) y los demás se quitan."""
    t = re.sub(r"\[nombre\]", nombre_pila or "", texto or "")
    t = re.sub(r"\[(?:correo|dni|ruc|telefono|ip|host|dato)\]", "", t)
    t = re.sub(r"\s+([,.;:!?])", r"\1", t)
    return re.sub(r"[ \t]{2,}", " ", t).strip()


def preparar_para_llm(texto: str, nombres=(), extra=()) -> str:
    """Todo lo que se manda a un LLM externo pasa por aquí: sin secretos y sin datos personales."""
    return enmascarar_pii(texto, nombres, extra)[0]
