"""Memoria del caso: la ficha que el agente lleva de cada persona y el hilo de la última pregunta.

Es la técnica de Baruka adaptada a soporte (ARQUITECTURA §2.2):

1. **Pregunta pendiente (el hilo).** Cada vez que el asistente pregunta algo se anota qué espera (`pendiente`). El
   mensaje siguiente se lee PRIMERO como respuesta a esa pregunta: si la responde, se guarda el dato y se limpia; si no,
   sigue pendiente y nadie inventa la respuesta.
2. **Extraer, no adivinar.** De cada mensaje se sacan con reglas los datos que trae: equipo (PC-CONT-07), sede, piso,
   área, aplicación, mensaje de error, desde cuándo, impacto («a todos», «solo a mí»), urgencia, pasos que ya probó.
3. **La siguiente pregunta la elige el código** (`siguiente`), según la categoría: la primera de su lista que no se
   sepa ni se haya preguntado ya. Lo que la persona ya dijo no se vuelve a preguntar.

El agente no guarda estado: la memoria llega en la petición y vuelve en la respuesta (CONTRATOS §1). Si no llega, se
reconstruye repasando el historial con las mismas funciones (`reconstruir`).

Sin dependencias: se prueba con `python -m app.prueba_memoria`.
"""
from __future__ import annotations

import copy
import re

from .datos import CATEGORIAS, IMPACTOS, URGENCIAS, plano

# SUPUESTO: lugares y áreas habituales para reconocer una sede o un área en el texto. Si la organización tiene otros,
# llegan en el perfil (`sede`, `area`) y se reconocen igual. Lo que no esté aquí se pregunta, no se adivina.
LUGARES = ("centro", "san isidro", "surco", "santiago de surco", "miraflores", "san borja", "la molina", "san miguel", "callao",
           "los olivos", "ate", "lince", "jesus maria", "barranco", "chorrillos", "san juan de lurigancho", "villa el salvador",
           "arequipa", "cusco", "trujillo", "piura", "chiclayo", "huancayo", "ica", "tacna", "lima", "iquitos", "puno")
AREAS = {"contabilidad": "Contabilidad", "logistica": "Logística", "ventas": "Ventas", "recursos humanos": "Recursos Humanos",
         "rrhh": "Recursos Humanos", "gerencia": "Gerencia", "sistemas": "Sistemas", "marketing": "Marketing", "finanzas": "Finanzas",
         "administracion": "Administración", "legal": "Legal", "compras": "Compras", "almacen": "Almacén", "tesoreria": "Tesorería",
         "atencion al cliente": "Atención al cliente", "operaciones": "Operaciones", "produccion": "Producción", "calidad": "Calidad",
         "comercial": "Comercial", "planillas": "Planillas", "proyectos": "Proyectos", "recepcion": "Recepción", "soporte": "Soporte"}

CAMPOS = ("sintoma", "aplicacion", "mensaje_error", "desde", "equipo", "sede", "piso", "area", "impacto", "urgencia",
          "impresora", "tipo_red", "anexo", "solicitud", "caida")
DESCONOCIDO = "desconocido"          # contestó «no sé»: es una respuesta, no se le vuelve a preguntar
SIN_MENSAJE = "sin mensaje"          # contestó que no le sale ningún error

# Preguntas de datos que el asistente puede dejar pendientes, y las que no son de datos.
PEND_DATOS = ("aplicacion", "mensaje_error", "desde", "equipo", "sede_piso", "piso", "area", "afecta_otros", "imprime_otro",
              "impresora", "tipo_red", "anexo", "que_solicita", "que_pasa")
PEND_OTRAS = ("resolvio", "puntaje", "ofrecer_tecnico")
PENDIENTES = set(PEND_DATOS) | set(PEND_OTRAS)
# Qué campo de `sabemos` resuelve cada pendiente.
DATO_DE = {"aplicacion": "aplicacion", "mensaje_error": "mensaje_error", "desde": "desde", "equipo": "equipo", "sede_piso": "sede",
           "piso": "piso", "area": "area", "afecta_otros": "impacto", "imprime_otro": "impacto", "impresora": "impresora",
           "tipo_red": "tipo_red", "anexo": "anexo", "que_solicita": "solicitud", "que_pasa": "sintoma"}
# Las que el código no suelta solo porque el texto no volvió a preguntarlas.
PERSISTENTES = {"resolvio", "puntaje", "ofrecer_tecnico"}
# Las que se repiten una vez si no se contestaron; el resto se pregunta una sola vez.
REPETIBLES = ("que_pasa",)
VECES_REPETIBLE = 2
MAX_PREGUNTAS_DATOS = 3     # tope de preguntas de datos por caso antes de pasar a guiar o a abrir la incidencia

# Qué preguntar según la categoría, en orden. Lo sabido o ya preguntado se salta (ARQUITECTURA §2.2).
ORDEN = {
    "correo": ("aplicacion", "mensaje_error", "desde", "afecta_otros"),
    "cuentas_accesos": ("aplicacion", "mensaje_error", "desde"),
    "red_wifi": ("tipo_red", "desde", "afecta_otros"),
    "vpn": ("mensaje_error", "desde", "afecta_otros"),
    "impresoras": ("sede_piso", "impresora", "imprime_otro", "mensaje_error"),
    "equipo": ("equipo", "mensaje_error", "desde"),
    "software_oficina": ("aplicacion", "mensaje_error", "desde"),
    "sistema_interno": ("aplicacion", "mensaje_error", "afecta_otros"),
    "telefonia": ("anexo", "desde", "afecta_otros"),
    "otro": ("que_pasa", "sede_piso", "desde"),
}
ORDEN_SOLICITUD = {"solicitar_acceso": ("que_solicita",), "solicitar_equipo": ("que_solicita",), "restablecer_clave": ("aplicacion",)}

PREGUNTAS = {
    "que_pasa": "Cuéntame qué está pasando, con tus palabras.",
    "aplicacion": "¿En qué programa o sistema te pasa?",
    "mensaje_error": "¿Te aparece algún mensaje de error? Si lo ves, escríbelo tal cual.",
    "desde": "¿Desde cuándo te pasa?",
    "equipo": "¿Cuál es el código de tu equipo? Suele estar en una etiqueta, por ejemplo PC-CONT-07.",
    "sede_piso": "¿En qué sede y piso está?",
    "piso": "¿En qué piso está?",
    "area": "¿De qué área eres?",
    "afecta_otros": "¿A alguien más le pasa lo mismo, o solo a ti?",
    "imprime_otro": "¿Otras personas sí pueden imprimir en esa impresora?",
    "impresora": "¿Cómo se llama la impresora o qué modelo es? Suele tener una etiqueta.",
    "tipo_red": "¿Estás conectado por WiFi o por cable de red?",
    "anexo": "¿Cuál es el número de tu anexo?",
    "que_solicita": "¿Qué necesitas exactamente? Dime a qué acceso o equipo te refieres.",
    "resolvio": "Cuando los pruebes, cuéntame: ¿quedó resuelto?",
    "puntaje": "¿Cómo calificarías la atención del 1 al 5?",
    "ofrecer_tecnico": "¿Quieres que un técnico te contacte?",
}
ESPERA = {   # qué está esperando el asistente, en palabras (para el prompt y la consola)
    "aplicacion": "el programa o sistema", "mensaje_error": "el mensaje de error", "desde": "desde cuándo ocurre",
    "equipo": "el código del equipo", "sede_piso": "la sede y el piso", "piso": "el piso", "area": "el área",
    "afecta_otros": "si afecta a alguien más", "imprime_otro": "si otras personas pueden imprimir", "impresora": "el nombre o modelo de la impresora",
    "tipo_red": "si usa WiFi o cable", "anexo": "el número de anexo", "que_solicita": "qué acceso o equipo necesita",
    "que_pasa": "qué problema tiene", "resolvio": "si quedó resuelto", "puntaje": "la calificación de 1 a 5",
    "ofrecer_tecnico": "si quiere que un técnico lo contacte",
}


def nueva() -> dict:
    return {"etapa": "recepcion", "pendiente": "", "sabemos": {k: None for k in CAMPOS} | {"pasos_probados": []},
            "articulos_mostrados": [], "intentos_guia": 0, "incidencia": None, "preguntado": [], "categoria": "",
            "sin_entender": 0, "turnos": 0, "turnos_guia": 0, "intencion_caso": ""}


_TEXTO_MAX = 160


def normalizar(m: dict | None) -> dict:
    """La memoria que llega de fuera, con todos sus campos, los tipos correctos y sin lo que no conocemos."""
    base = nueva()
    if not isinstance(m, dict):
        return base
    for k in ("etapa", "pendiente", "categoria", "intencion_caso"):
        if isinstance(m.get(k), str):
            base[k] = m[k][:40]
    if base["intencion_caso"] not in ("reportar_falla", "solicitar_acceso", "solicitar_equipo", "restablecer_clave"):
        base["intencion_caso"] = ""
    if base["pendiente"] not in PENDIENTES:
        base["pendiente"] = ""
    if base["categoria"] not in CATEGORIAS:
        base["categoria"] = ""
    for k in ("intentos_guia", "sin_entender", "turnos", "turnos_guia"):
        v = m.get(k)
        base[k] = v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 1000 else 0
    if isinstance(m.get("incidencia"), str) and re.fullmatch(r"INC-\d{1,10}", m["incidencia"]):
        base["incidencia"] = m["incidencia"]
    for k in ("articulos_mostrados", "preguntado"):
        if isinstance(m.get(k), list):
            base[k] = [x[:30] for x in m[k] if isinstance(x, str) and x][-30:]
    sab = m.get("sabemos") if isinstance(m.get("sabemos"), dict) else {}
    for k in CAMPOS:
        v = sab.get(k)
        if k == "caida":
            base["sabemos"][k] = True if v is True else None
            continue
        v = str(v)[:_TEXTO_MAX] if isinstance(v, (str, int, float)) and not isinstance(v, bool) and v != "" else None
        if k == "impacto" and v not in IMPACTOS:
            v = None
        if k == "urgencia" and v not in URGENCIAS:
            v = None
        base["sabemos"][k] = v
    pp = sab.get("pasos_probados")
    if isinstance(pp, list):
        base["sabemos"]["pasos_probados"] = [x[:60] for x in pp if isinstance(x, str) and x][-10:]
    return base


def copia(mem: dict) -> dict:
    return copy.deepcopy(mem)


# ---------------------------------------------------------------------------
# Texto plano y respuestas cortas
# Texto plano y respuestas cortas: están en lenguaje.py y se reexportan aquí.
from .lenguaje import (RE_AFIRMA, RE_CONFIRMA, RE_NIEGA, RE_SIGUE_IGUAL, _plano, afirma, afirma_resuelto, categoria_por_palabras, confirma,  # noqa: E402,F401
                       hay_otra_cosa, niega, sigue_igual)

# ---------------------------------------------------------------------------
# Qué pregunta hizo el asistente, por su texto (para las preguntas que escribió un LLM)

DETECTOR = [
    ("puntaje", re.compile(r"del 1 al 5|de 1 a 5|califica\w* (la )?atencion")),
    ("ofrecer_tecnico", re.compile(r"que un tecnico te (contacte|llame|atienda)|quieres que (un|una) (tecnico|persona)")),
    ("resolvio", re.compile(r"quedo resuelto|se (soluciono|arreglo|resolvio)|ya funciona|funciono|resolvi\w+ (el|tu) (problema|caso)")),
    ("imprime_otro", re.compile(r"(otras|mas) personas (si )?(pueden )?imprim|alguien mas (puede )?imprim")),
    ("afecta_otros", re.compile(r"alguien mas (le )?pasa|solo (a ti|te pasa)|tambien (a|les|le) (tus )?(companer|pasa)|afecta a (alguien|mas)")),
    ("mensaje_error", re.compile(r"mensaje de error|mensaje o codigo|algun error|algun mensaje|te (sale|aparece|muestra) algun|que dice el (error|mensaje)")),
    ("sede_piso", re.compile(r"(en )?que sede|sede y (el )?piso|que sede (y|e)")),
    ("piso", re.compile(r"en que piso|que piso")),
    ("tipo_red", re.compile(r"wifi o (por )?cable|por cable o|conectado por (wifi|cable)")),
    ("impresora", re.compile(r"como se llama la impresora|modelo (es )?la impresora|nombre de la impresora|que impresora")),
    ("equipo", re.compile(r"codigo de (tu )?equipo|etiqueta del equipo|que equipo|nombre (de tu|del) (equipo|pc)")),
    ("anexo", re.compile(r"numero de (tu )?anexo|cual es (tu|el) anexo")),
    ("desde", re.compile(r"desde cuando|cuando (empezo|comenzo|paso)|hace cuanto")),
    ("aplicacion", re.compile(r"en que (programa|aplicacion|sistema)|que (programa|aplicacion|sistema) (usas|es)|usas outlook|lo usas en|en outlook, en el correo|a que (programa|sistema)|excel, word, teams")),
    ("area", re.compile(r"de que area|en que area")),
    ("que_solicita", re.compile(r"que necesitas exactamente|a que (acceso|carpeta|sistema|equipo)|que (acceso|equipo) necesitas")),
    ("que_pasa", re.compile(r"cuentame (que|como)|que (problema|esta pasando)|en que (te )?(puedo )?ayud")),
]
RE_PREGUNTA = re.compile(r"[^.!?\n¿]*¿[^?]*\?|[^.!?\n]*\?")


def preguntas_en(texto: str) -> list[str]:
    """Las frases que preguntan, en orden («¿…?» o terminadas en «?»)."""
    return [m.group(0).strip() for m in RE_PREGUNTA.finditer(texto or "")]


def clave_de(pregunta: str) -> str:
    p = _plano(pregunta)
    return next((k for k, rx in DETECTOR if rx.search(p)), "")


def pregunta_de(texto: str) -> str:
    """La clave de la ÚLTIMA pregunta del texto que reconocemos ('' si no pregunta nada conocido)."""
    claves = [k for k in (clave_de(p) for p in preguntas_en(texto)) if k]
    return claves[-1] if claves else ""


# ---------------------------------------------------------------------------
# Extraer datos del mensaje (reglas)

RE_EQUIPO = re.compile(r"\b((?:pc|lap|laptop|nb|ws|cpu|dt|mac|desk|port|eq)-[a-z0-9]{2,6}(?:-[a-z0-9]{1,4}){0,2})\b", re.I)
RE_CODIGO_GENERICO = re.compile(r"\b([a-z]{2,5}-[a-z0-9]{2,8}(?:-[a-z0-9]{1,4})?)\b", re.I)
RE_IMPRESORA_NOMBRE = re.compile(r"\b(?:impresora|multifuncional|fotocopiadora|plotter)\s+(?:(?:es|se llama|llamada|modelo|marca)\s+)?(?:la\s+|el\s+|una\s+|un\s+)?"
                                 r"((?=[^\s,.;]*[-\d])[a-z0-9]+(?:-[a-z0-9]+)+|(?:hp|epson|brother|canon|ricoh|xerox|kyocera|lexmark|samsung)(?: [a-z0-9-]+){0,2})", re.I)
RE_IMPRESORA_MARCA = re.compile(r"\b((?:hp|epson|brother|canon|ricoh|xerox|kyocera|lexmark)(?: [a-z0-9-]+){0,2}(?: de (?:tinta|laser|toner))?)\b", re.I)
RE_ANEXO = re.compile(r"\banexo\s*(?:es|numero|nro|n°|:)?\s*(?:el\s+)?(\d{3,5})\b|\b(?:mi\s+)?(?:numero|nro) de anexo\s*(?:es)?\s*(\d{3,5})\b|"
                      r"\banexo\s+(?:es\s+)?(?:el\s+)?(?:dos mil|mil)\s+\w+(?:\s+\w+){0,3}")

_NUMS = r"(?:un|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|doce|quince|veinte|media|\d+)"
_DIAS = r"lunes|martes|miercoles|jueves|viernes|sabado|domingo"
_MOMENTO = r"(?:hoy|ayer|anoche|anteayer|antes de ayer|esta manana|esta tarde|esta noche|temprano|ayer por la (?:manana|tarde|noche)|hoy por la (?:manana|tarde|noche))"
RE_DESDE = [
    re.compile(rf"\b(?:desde )?hace (?:como |casi |mas o menos |unos |unas |ya )?{_NUMS}(?: y media)? (?:minutos?|horas?|dias?|semanas?|meses|mes)\b"),
    re.compile(r"\bdesde que (?:\w+ ){0,3}\w+\b"),
    re.compile(rf"\bdesde (?:el )?(?:{_DIAS})(?: (?:por|en) la (?:manana|tarde|noche))?(?: a las \d{{1,2}}(?::\d{{2}})?)?\b"),
    re.compile(rf"\bdesde (?:{_MOMENTO}|la (?:manana|tarde|noche)|la semana pasada|el mes pasado|el (?:dia )?\d{{1,2}}|las? \d{{1,2}}(?::\d{{2}})?(?: ?(?:am|pm|h|horas))?|"
               rf"siempre|anoche|esta semana|el fin de semana)(?: (?:por|en) la (?:manana|tarde|noche))?\b"),
    re.compile(rf"\b(?:empezo|comenzo|paso|ocurrio|fallo|sucedio|se cayo|se malogro|dejo de funcionar|me pasa|me paso|fue) (?:desde )?(?:el )?(?:{_DIAS}|{_MOMENTO})"
               rf"(?: (?:por|en) la (?:manana|tarde|noche))?(?: a las \w+(?: \w+){{0,3}}?(?: de la (?:manana|tarde|noche))?)?\b"),
]
RE_DESDE_SUELTO = re.compile(rf"^(?:(?:es |fue |pasa |paso |ocurre |ocurrio |empezo |a eso de )?(?:desde )?(?:el )?(?:{_DIAS}|{_MOMENTO}|ayer en la (?:manana|tarde|noche)))"
                             rf"(?: (?:por|en) la (?:manana|tarde|noche))?(?: a las \w+(?: \w+){{0,3}})?[\s.!,]*(?:nomas|pe|pues)?[\s.!]*$")

RE_ERROR_CODIGO = re.compile(r"\b(0x[0-9a-f]{4,8}|error\s*(?:de\s+\w+\s+)?\d{3,4}\b|codigo\s*(?:de error\s*)?[a-z0-9_\-]{4,30}\b)", re.I)
RE_ERROR_COMILLAS = re.compile(r"[«\"“'‘](.{3,120}?)[»\"”'’]")
RE_ERROR_DICE = re.compile(r"\b(?:(?:el |un )?(?:mensaje|error|aviso|cuadro|ventana|letrero)(?: que)?(?: (?:me )?(?:sale|aparece|muestra|dice|es))|"
                           r"me (?:sale|aparece|muestra|bota|da|tira)(?: un| el| este)? (?:mensaje|aviso|cuadro)(?: que dice)?|dice(?: que)?)\s*[:,]?\s*(.{3,110})", re.I)
RE_ERROR_NOMBRADO = re.compile(r"\bme (?:sale|aparece|muestra|bota|da|tira)(?: un| el| este)? (error(?: de| en| del)? [^.?!,;]{3,100})", re.I)
RE_SIN_ERROR = re.compile(r"\b(?:no|ningun)\b[^.?!]{0,25}\b(?:sale|aparece|muestra|da|bota|hay|veo|tiene)\b[^.?!]{0,15}\b(?:error|mensaje|aviso|nada)\b|"
                          r"\bsin (?:ningun )?(?:error|mensaje)\b|\bningun (?:error|mensaje)\b")

APLICACIONES = [
    ("Outlook", re.compile(r"\boutloo?k\b|\boutlok\b|\bowa\b")),
    ("correo web", re.compile(r"correo web|webmail|correo (?:en|por) (?:el )?(?:navegador|web)")),
    ("Gmail", re.compile(r"\bgmail\b")),
    ("Teams", re.compile(r"\bteams\b|\btims\b|\btean?s\b")),
    ("Zoom", re.compile(r"\bzoom\b")),
    ("Excel", re.compile(r"\be[cx]+el\b")),
    ("Word", re.compile(r"\bword\b")),
    ("PowerPoint", re.compile(r"power ?point")),
    ("Power BI", re.compile(r"power ?bi\b")),
    ("Chrome", re.compile(r"\bchrome\b|\bcrome\b")),
    ("Edge", re.compile(r"\bedge\b")),
    ("Firefox", re.compile(r"\bfirefox\b")),
    ("OneDrive", re.compile(r"one ?drive")),
    ("SharePoint", re.compile(r"share ?point")),
    ("cliente VPN", re.compile(r"\bvpn\b|\bvepeene\b")),
    ("Windows", re.compile(r"\bwindo?u?s\b")),
    ("Adobe Acrobat", re.compile(r"acrobat|adobe reader")),
    ("AutoCAD", re.compile(r"autocad")),
    ("antivirus", re.compile(r"\bantivirus\b|\bantibirus\b")),
]
RE_SISTEMA = re.compile(r"\b((?:el |la )?(?:sistema|aplicativo|modulo|aplicacion|plataforma|intranet|portal)(?: interno)?(?: de| del| para)? ?(?:[a-z]+(?: de [a-z]+)?)?)\b")
_NO_SISTEMA = {"interno", "no", "se", "esta", "me", "nos", "de", "del", "y", "que", "esta", "dice", "carga", "abre", "funciona", "cayo", "va", "tiene", "es", "con", "en", "no", "sale", "bota", "da", "muestra", "siempre", "cada", "tarda"}

PASOS_PROBADOS = [
    ("reiniciar el equipo", re.compile(r"\breinici(?:e|amos)\b|\bapague y prendi\b|\bapague y encendi\b|\blo apague y\b|\bla apague y\b|reinicie (?:la|el|mi)")),
    ("reiniciar el router", re.compile(r"\b(?:apague|reinicie|desconecte|prendi|encendi)\b[^.?!]{0,20}\b(?:router|modem)\b")),
    ("cerrar y abrir la aplicación", re.compile(r"\bcerre (?:el |la )?\w+ y (?:lo |la )?(?:volvi a )?abr|\bcerre y (?:volvi a )?abr|cerrando y abriendo")),
    ("cerrar sesión", re.compile(r"\bcerre (?:la )?sesion\b|\bcerrando sesion\b|\bsalir y volver a entrar\b")),
    ("desconectar y reconectar", re.compile(r"\bdesconecte\b[^.?!]{0,30}\b(?:cable|usb|conect)|\bdesconecte y\b|\bvolvi a conectar")),
    ("probar otro navegador", re.compile(r"otro navegador|(?:con|en) (?:edge|chrome|firefox)\b")),
    ("cambiar la contraseña", re.compile(r"\bcambie (?:la |mi )?(?:contrasena|clave)\b")),
    ("actualizar", re.compile(r"\bactualice\b|\bactualizando\b")),
    ("reinstalar", re.compile(r"\breinstale\b|\bdesinstale\b")),
]
_YA = re.compile(r"\b(?:ya|probe|intente|hice|lo hice|acabo de|recien|despues de)\b")


def _forma(valor: str) -> str:
    return re.sub(r"\s+", " ", valor).strip(" .,;:!¡¿?\"'«»")


def _sin_que(v: str) -> str:
    return re.sub(r"^que\s+(?=\w)", "", v, flags=re.I)


def _equipo(texto: str, plano_t: str, pend: str) -> str | None:
    m = RE_EQUIPO.search(texto)
    if m:
        return m.group(1).upper()
    if pend == "equipo":
        m = RE_CODIGO_GENERICO.search(texto)
        if m:
            return m.group(1).upper()
    return None


def _impresora(texto: str, plano_t: str, pend: str) -> str | None:
    m = RE_IMPRESORA_NOMBRE.search(texto)
    if m:
        return _forma(m.group(1))[:60]
    if "impresora" in plano_t or "multifuncional" in plano_t or pend == "impresora":
        m = RE_CODIGO_GENERICO.search(texto) if not RE_EQUIPO.search(texto) else None
        if m and re.search(r"[-\d]", m.group(1)) and pend in ("impresora", "") and ("impresora" in plano_t or pend == "impresora"):
            return _forma(m.group(1))[:60]
        m = RE_IMPRESORA_MARCA.search(texto)
        if m:
            return _forma(m.group(1))[:60]
    return None


def _piso(plano_t: str) -> str | None:
    m = re.search(r"(?<![-\w])(\d{1,2})\s*(?:er|ro|do|to|vo|mo|no|\.?º|°)?\s*piso\b|(?<![-\w])piso\s*(?:n[°º.]?\s*)?(\d{1,2})\b", plano_t)
    if m:
        return f"piso {m.group(1) or m.group(2)}"
    m = re.search(r"\b(primer|primero|segundo|tercer|tercero|cuarto|quinto|sexto|septimo|octavo|noveno|decimo|2do|3er|4to|5to)\s+piso\b", plano_t)
    if m:
        n = {"primer": 1, "primero": 1, "segundo": 2, "2do": 2, "tercer": 3, "tercero": 3, "3er": 3, "cuarto": 4, "4to": 4, "quinto": 5, "5to": 5,
             "sexto": 6, "septimo": 7, "octavo": 8, "noveno": 9, "decimo": 10}[m.group(1)]
        return f"piso {n}"
    return None


_PARO_SEDE = {"y", "no", "nadie", "esta", "con", "que", "pero", "donde", "hay", "se", "le", "me", "nos", "todos", "toda", "todo", "en", "de", "del", "la", "el", "a", "pe", "nomas", "tercer", "segundo", "primer", "cuarto", "quinto", "piso"}


def _sede(texto: str, plano_t: str, pend: str, conocidas: tuple[str, ...] = ()) -> str | None:
    lugares = sorted({*LUGARES, *(plano(c) for c in conocidas if c)}, key=len, reverse=True)
    rx_lug = "|".join(re.escape(x) for x in lugares)
    m = re.search(rf"\b(?:sede|local|oficina|sucursal|agencia|tienda)\s+(?:de\s+|del\s+|en\s+)?({rx_lug})\b", plano_t) or \
        re.search(rf"\b(?:estoy|trabajo|me encuentro|vivo|soy|estamos|trabajamos)\s+(?:aqui )?(?:en|de|desde)\s+(?:la\s+|el\s+)?(?:sede\s+|oficina\s+|local\s+)?(?:de\s+)?({rx_lug})\b", plano_t)
    if m:
        return _bonita(m.group(1), texto)
    m = re.search(r"\b(?:sede|local|sucursal)\s+(?:de\s+|del\s+)?([a-z]+(?: [a-z]+)?)", plano_t)
    if m:
        w = [p for p in m.group(1).split() if p not in _PARO_SEDE][:2]
        if w and m.group(1).split()[0] not in _PARO_SEDE and " ".join(w) not in AREAS:
            return _bonita(" ".join(w), texto)
    if pend in ("sede_piso",):
        sol = re.sub(r"\b(?:en el|en la|en|el|la|sede|local|oficina|estoy|estamos|es|esta|queda|piso|\d+\w*)\b", " ", plano_t)
        sol = [p for p in re.sub(r"[^a-z ]", " ", sol).split() if p not in _PARO_SEDE]
        if 0 < len(sol) <= 3:
            return _bonita(" ".join(sol), texto)
    m = re.search(rf"\b(?:en|de)\s+(?:el\s+|la\s+)?({rx_lug})\b", plano_t) if pend == "sede_piso" else None
    return _bonita(m.group(1), texto) if m else None


def _bonita(plano_val: str, original: str) -> str:
    """El nombre con mayúsculas; se toma del texto original si aparece escrito así."""
    m = re.search(re.escape(plano_val).replace(r"\ ", r"\s+"), plano(original))
    if m:
        orig = re.sub(r"\s+", " ", original[m.start():m.end()]) if len(plano(original)) == len(original) else plano_val
        return orig.title() if orig.islower() else orig
    return plano_val.title()


def _area(texto: str, plano_t: str, pend: str) -> str | None:
    claves = "|".join(sorted((re.escape(k) for k in AREAS), key=len, reverse=True))
    m = re.search(rf"\b(?:area|departamento|gerencia|equipo|oficina|seccion|unidad)\s+(?:de\s+)?({claves})\b", plano_t) or \
        re.search(rf"\b(?:soy|somos|trabajo|trabajamos|pertenezco|estoy|estamos)\s+(?:de|del|en|al)\s+(?:el\s+|la\s+)?(?:area\s+(?:de\s+)?|departamento\s+(?:de\s+)?)?({claves})\b", plano_t) or \
        re.search(rf"\b(?:del|de la|de)\s+(?:area\s+(?:de\s+)?)?({claves})\b", plano_t) if (pend == "area" or re.search(r"\b(?:soy|trabajo|pertenezco|somos|area)\b", plano_t)) else None
    if m:
        return AREAS[m.group(1)]
    if pend == "area":
        for k, v in AREAS.items():
            if re.search(rf"\b{re.escape(k)}\b", plano_t):
                return v
    return None


def _aplicacion(texto: str, plano_t: str, pend: str) -> str | None:
    for nombre, rx in APLICACIONES:
        if rx.search(plano_t):
            return nombre
    m = RE_SISTEMA.search(plano_t)
    if m:
        t = _forma(m.group(1))
        palabras = t.split()
        # «el sistema no abre» no nombra ningún sistema: hace falta «de ventas» o similar.
        util = [p for p in palabras if p not in _NO_SISTEMA and p not in ("el", "la", "sistema", "aplicativo", "modulo", "aplicacion", "plataforma", "portal", "interno")]
        if util and re.search(r"\b(?:de|del|para)\b", t):
            return re.sub(r"^(?:el|la) ", "", t)[:50]
        if re.search(r"\bintranet\b", t):
            return "intranet"
    return None


_RE_VERBO_INICIAL = re.compile(r"^(?:empezo|comenzo|paso|ocurrio|fallo|sucedio|se cayo|se malogro|dejo de funcionar|me pasa|me paso|fue)\s+(?:desde\s+)?")


_ACENTOS = (("manana", "mañana"), ("miercoles", "miércoles"), ("sabado", "sábado"), ("dias", "días"), ("dia ", "día "), ("antes de ayer", "antes de ayer"))


def _sin_verbo(v: str) -> str:
    v = _RE_VERBO_INICIAL.sub("", v)
    for a, b in _ACENTOS:
        v = re.sub(rf"\b{a.strip()}\b", b.strip(), v)
    return v


def _desde(plano_t: str, pend: str) -> str | None:
    for rx in RE_DESDE:
        m = rx.search(plano_t)
        if m:
            return _sin_verbo(_forma(m.group(0)))[:60]
    if pend == "desde":
        m = RE_DESDE_SUELTO.match(plano_t) or re.match(rf"^(?:es |pasa |paso )?({_MOMENTO}|{_NUMS} (?:dias?|horas?|semanas?))[\s.!]*$", plano_t)
        if m:
            return _forma(m.group(0))[:60]
        m = re.search(rf"\b{_MOMENTO}\b", plano_t)
        if m:
            return _forma(m.group(0))
    return None


def _mensaje_error(texto: str, plano_t: str, pend: str) -> str | None:
    if RE_SIN_ERROR.search(plano_t) and not RE_ERROR_CODIGO.search(texto) and not re.search(r"\b(?:dice|sale el|el mensaje)\b", plano_t):
        return SIN_MENSAJE
    m = RE_ERROR_COMILLAS.search(texto)
    if m and (pend == "mensaje_error" or re.search(r"\b(?:dice|mensaje|error|aviso|sale|aparece)\b", plano_t)):
        return _forma(m.group(1))[:100]
    m = RE_ERROR_CODIGO.search(texto)
    if m:
        return _forma(m.group(1))[:100]
    m = RE_ERROR_NOMBRADO.search(texto)
    if m:
        return _forma(m.group(1))[:100]
    m = RE_ERROR_DICE.search(texto)
    if m:
        v = _sin_que(_forma(re.split(r"[.?!\n]|,? y (?:no|ya|ahora|luego)\b", m.group(1))[0]))
        if len(v) >= 3:
            return v[:100]
    return None


_RE_PERSONA = re.compile(r"\bsolo (?:me pasa |ocurre |sucede |es |pasa |falla |le pasa )?(?:a mi|en mi|mio|yo|conmigo)\b|\bsolo a mi\b|\bsolo me pasa\b|\bsolo yo\b|"
                         r"\bsolo (?:en|con) mi (?:compu|pc|computadora|equipo|laptop|lap|cuenta|usuario|telefono|anexo)\b|\ba nadie mas\b|\bnadie mas (?:tiene|le pasa|lo tiene)\b|"
                         r"\bmis companer\w+ (?:estan|esta) bien\b|\blos demas (?:estan|esta) bien\b|\bsolo (?:es )?(?:mi|a mi)\b|\bsolo a mi\b|"
                         r"\ben la de mi companer\w+ si\b|\bsolo ocurre en mi\b|\bsolo en mi\b")
_RE_AREA = re.compile(r"\ba (?:todos|todas) (?:los|las) de (?:mi|el|la) (?:piso|area|equipo|oficina|seccion)\b|\b(?:mis|a mis|los) companer\w+ (?:tambien|de al lado|de mi)\b|"
                      r"\ba (?:mi|la) companer\w+ (?:de al lado )?tambien\b|\btambien (?:le|les) pasa\b|\b(?:varios|varias|algunos|otros) (?:companer\w+|usuarios|de mi)\b|"
                      r"\b(?:nos pasa|les pasa|le pasa|pasa) a todos\b|\ba todos (?:aca|aqui|en)\b|\bnadie (?:de mi (?:equipo|area|piso)|puede|pudo|mas de mi)\b|"
                      r"\btodo el (?:piso|area|equipo)\b|\btoda (?:el area|mi area)\b|\ben todo (?:el|mi) piso\b|\bnadie puede\b|\bnadie mas (?:puede|pudo|logra|consigue)\b|\bning(?:un|una) (?:companer\w+|persona|usuario) (?:puede|pudo)\b|\btodos (?:los de|en) mi (?:area|piso|equipo)\b|"
                      r"\bcompaneros? (?:de al lado )?(?:tambien|igual)\b|\bles pasa lo mismo\b|\blo mismo (?:a|les|le) (?:mis|los)\b")
_RE_SEDE = re.compile(r"\btoda la (?:sede|oficina|sucursal|agencia|tienda)\b|\btodo el (?:local|edificio)\b|\btodos los pisos\b|\ben toda la (?:sede|oficina)\b|"
                      r"\b(?:caida|caido|cayo) (?:en|de) (?:toda )?la (?:sede|oficina)\b|\ben todo el (?:local|edificio)\b|\bnadie en la (?:sede|oficina)\b|"
                      r"\btodos en la (?:oficina|sede)\b|\ba todos en la (?:oficina|sede)\b|\bleste a todos\b|\ben la oficina,? (?:nadie|todos)\b|\ba todos en la oficina\b|"
                      r"\bde la sede\b[^.?!]{0,20}\b(?:caido|caida|nadie)\b|\btodo(?:s)? (?:el internet|los equipos) de la (?:sede|oficina)\b|"
                      r"\bnadie (?:en|de) (?:toda )?la (?:sede|oficina)\b|\btoda la sede\b")
_RE_ORG = re.compile(r"\btoda la (?:empresa|organizacion|institucion|compania)\b|\btodas las sedes\b|\btodas las oficinas\b|\ben toda la empresa\b|"
                     r"\btodos los usuarios\b|\ba todo el mundo\b|\bnadie en la empresa\b|\btodos los colaboradores\b|\btoda la institucion\b")
_RE_NO_OTROS = re.compile(r"\b(?:solo|nada mas) (?:yo|a mi|me pasa a mi)\b|^(?:no|nop|solo yo|solo a mi|solo me pasa a mi|nadie mas)[\s.!,]*(?:solo a mi|a mi nomas|solo yo)?[\s.!]*$")


def _impacto(plano_t: str, pend: str) -> str | None:
    if _RE_ORG.search(plano_t):
        return "organizacion"
    if _RE_SEDE.search(plano_t):
        return "sede"
    if _RE_PERSONA.search(plano_t) and not re.search(r"\bsolo (?:yo|a mi)\b[^.?!]*\b(?:y|tambien)\b[^.?!]*\bcompan", plano_t):
        return "persona"
    if _RE_AREA.search(plano_t):
        return "area"
    if pend == "afecta_otros":
        if afirma(plano_t) or re.match(r"^(?:creo que |parece que |me parece que )?(?:si+|sip|claro)\b", plano_t) or re.search(r"\b(?:a|con) (?:mi|varios|otros|todos|dos|tres|algunos|mas)\b|\bmas personas\b|\btambien\b", plano_t):
            return "area"
        if niega(plano_t) or _RE_NO_OTROS.search(plano_t) or re.match(r"^(?:creo que |parece que |me parece que )?no\b|\bno creo\b|^ninguno\b|^nadie\b", plano_t):
            return "persona"
    if pend == "imprime_otro":
        if afirma(plano_t) or re.match(r"^(?:si+|sip|claro|los demas si|otros si|si pueden)\b", plano_t):
            return "persona"       # los demás sí imprimen: el problema es de su equipo o de su cola
        if niega(plano_t) or re.match(r"^no\b|\bnadie (?:puede|pudo|imprime)\b|\bninguno\b|\bnadie\b", plano_t):
            return "area"
    return None


_CRITICA = re.compile(r"\bse cayo (?:todo|el sistema|el internet|la red)\b|\bno podemos trabajar\b|\bparalizad\w+|\bemergencia\b|\bcritic[oa]\b|\bnadie puede trabajar\b|\bto?do parado\b|"
                      r"\bno hay (?:internet|red|sistema|luz)\b[^.?!]{0,30}\b(?:nadie|todos|toda)\b|\bsin sistema\b[^.?!]{0,20}\b(?:todos|toda)\b|\bsistema caido\b[^.?!]{0,30}\b(?:todos|nadie)\b")
_ALTA = re.compile(r"\burgent\w*|\bme urge\b|\blo antes posible\b|\bcuanto antes\b|\bde inmediato\b|\bya mismo\b|\bpara hoy\b|\btengo (?:una |un |el )?(?:entrega|cierre|reunion|presentacion|exposicion|plazo|auditoria|inventario)\b|"
                   r"\bcierre contable\b|\bno puedo trabajar\b|\bme esta urgiendo\b|\bmi jefe\b[^.?!]{0,30}\b(?:pide|espera|necesita)\b|\bcon urgencia\b|\bmuy importante\b")
_BAJA = re.compile(r"\bno es urgente\b|\bcuando puedan\b|\bsin apuro\b|\bno corre prisa\b|\bno hay apuro\b|\bcuando tengan tiempo\b|\bno me urge\b|\bsin prisa\b")
_CAIDA = re.compile(r"\bse cayo\b|\bestan? caid[oa]s?\b|\bcaid[oa]\b|\bno funciona nada\b|\bnadie puede (?:entrar|trabajar|abrir|conectar\w*|imprimir|usar)\b|\bsin (?:internet|servicio|sistema|luz|red)\b|"
                    r"\bno hay (?:internet|red|luz|sistema|servicio)\b|\bparalizad\w+|\bno podemos trabajar\b|\btodo parado\b|\bsin conexion\b|\bno (?:abre|carga|responde)n? (?:para )?(?:nadie|ninguno|todos)\b")


def _urgencia(plano_t: str) -> str | None:
    if _BAJA.search(plano_t):
        return "baja"
    if _CRITICA.search(plano_t):
        return "critica"
    if _ALTA.search(plano_t):
        return "alta"
    return None


def _tipo_red(plano_t: str) -> str | None:
    wifi, cable = bool(re.search(r"\bwi ?-?fi\b|\binalambric\w+|\bred wifi\b", plano_t)), bool(re.search(r"\bcable\b|\bpor red cableada\b|\bpunto de red\b|\bethernet\b|\blan\b", plano_t))
    if re.search(r"\bno\b[^.?!,]{0,12}\bwi ?-?fi\b|\bsin wi ?-?fi\b", plano_t):
        wifi = False
    if re.search(r"\bno\b[^.?!,]{0,12}\bcable\b|\bsin cable\b", plano_t):
        cable = False
    if wifi and not cable:
        return "wifi"
    if cable and not wifi:
        return "cable"
    return None


def _pasos(plano_t: str) -> list[str]:
    if not _YA.search(plano_t) and not re.search(r"\b(?:reinicie|apague|cerre|desconecte|actualice|reinstale|cambie)\b", plano_t):
        return []
    out = [nombre for nombre, rx in PASOS_PROBADOS if rx.search(plano_t)]
    if "reiniciar el router" in out and "reiniciar el equipo" in out and not re.search(r"\b(?:pc|computadora|compu|equipo|laptop|lap|maquina)\b", plano_t):
        out.remove("reiniciar el equipo")
    return out


def _anexo(plano_t: str, pend: str) -> str | None:
    m = re.search(r"\banexo\s*(?:es|numero|nro|:)?\s*(?:el\s+)?(\d{3,5})\b|\b(?:numero|nro) de anexo\s*(?:es)?\s*(?:el\s+)?(\d{3,5})\b|\banexo\s+(\d{3,5})\b", plano_t)
    if m:
        return next(g for g in m.groups() if g)
    if pend == "anexo":
        m = re.fullmatch(r"\D{0,20}?(\d{3,5})\D{0,10}", plano_t)
        if m:
            return m.group(1)
    return None


def _solicitud(texto: str, plano_t: str) -> str | None:
    """Qué pide, si lo dice: «acceso a la carpeta de Contabilidad», «una laptop nueva», «instalen AutoCAD»."""
    m = re.search(r"\b(?:acceso|permisos?|usuario|cuenta|alta|habilit\w+|autoriza\w*)\b[^.?!]{0,12}?\b(?:a|al|a la|a los|de|del|para|en|el|la)\b\s+(.{4,90})", plano_t)
    if m:
        return _forma(m.group(0))[:100]
    m = re.search(r"\b(?:necesito|necesitamos|quiero|quisiera|solicito|requiero|requerimos|me falta|me hace falta|pido|pedir)\s+(?:que\s+(?:me\s+)?(?:instal\w+|den|presten|cambien)\s+)?(?:un|una|unos|unas|el|la|mi|otro|otra)?\s*"
                  r"(laptop|computadora|pc|mouse|maus|teclado|monitor|pantalla|impresora|celular|telefono|tablet|proyector|cargador|diadema|audifonos|licencia|adaptador|cable|mochila|camara|disco|memoria|router|escritorio)\b[^.?!]{0,60}", plano_t)
    if m:
        return _forma(m.group(0))[:100]
    m = re.search(r"\b(?:instal\w+|instalacion de|licencia de)\s+(?:de\s+)?(.{3,60})", plano_t)
    if m:
        return _forma(m.group(0))[:100]
    return None


def extraer(texto: str, pendiente: str = "", sedes: tuple[str, ...] = (), categoria: str = "") -> dict:
    """Los datos que trae el mensaje, por reglas: {campo: valor}. `pendiente` ayuda a leer respuestas cortas («Centro»); `categoria`, un código
    suelto («es la HP-Piso3»): en un caso de impresoras es la impresora, en uno de equipos es el equipo."""
    texto = (texto or "")[:600]
    t = _plano(texto)
    out: dict = {}
    if (v := _equipo(texto, t, pendiente)):
        out["equipo"] = v
    if (v := _impresora(texto, t, pendiente)) and not out.get("equipo", "").lower() == v.lower():
        out["impresora"] = v
    if categoria in ("impresoras", "equipo") and "impresora" not in out and "equipo" not in out and re.fullmatch(r"\W*(?:es |la |el |mi |se llama )*([a-z]{2,5}-[a-z0-9-]{2,12})\W*", texto.strip(), re.I):
        out["impresora" if categoria == "impresoras" else "equipo"] = RE_CODIGO_GENERICO.search(texto).group(1).upper()
    if (v := _piso(t)):
        out["piso"] = v
    if (v := _sede(texto, t, pendiente, sedes)):
        out["sede"] = v
    if (v := _area(texto, t, pendiente)):
        out["area"] = v
    if (v := _aplicacion(texto, t, pendiente)):
        out["aplicacion"] = v
    if (v := _desde(t, pendiente)):
        out["desde"] = v
    if (v := _mensaje_error(texto, t, pendiente)):
        out["mensaje_error"] = v
    if (v := _impacto(t, pendiente)):
        out["impacto"] = v
    if (v := _urgencia(t)):
        out["urgencia"] = v
    if (v := _tipo_red(t)):
        out["tipo_red"] = v
    if (v := _anexo(t, pendiente)):
        out["anexo"] = v
    if _solicitud(texto, t):
        out["solicitud"] = _limpiar_valor(texto, 100)
    if _CAIDA.search(t):
        out["caida"] = True
    if (v := _pasos(t)):
        out["pasos_probados"] = v
    return out


# ---------------------------------------------------------------------------
# Leer el mensaje nuevo contra la pendiente

RE_CONTRAPREGUNTA = re.compile(r"^\W*(?:que|cual|cuales|como|donde|cuando|quien|cuanto|por que|porque|para que|a que|en que)\b")


_SIGLAS_SIN_VOCAL = {"vpn", "pdf", "sms", "dns", "usb", "tcp", "ftp", "cpu", "ram", "rrhh", "pc", "ssd", "hdd", "tv", "ip", "lan", "wlan", "smtp", "html", "css", "sql", "ssh", "rdp", "ups", "cd", "dvd"}


def ilegible(texto: str) -> bool:
    """¿Es ruido de teclado? («asdkjh qwe», «zzzz xxxx», «qqqq wwww»). Palabras sin vocales o con rachas de 5 consonantes o más,
    que ocupan más de la mitad de las letras. Las siglas de TI (VPN, PDF, USB…) no cuentan como ruido."""
    t = _plano(texto)
    if re.search(r"\d", t):
        return False
    toks = re.findall(r"[a-zñ]+", t)
    if not toks:
        return False
    malas = letras = 0
    for w in toks:
        letras += len(w)
        if w in _SIGLAS_SIN_VOCAL:
            continue
        sin_vocal = len(w) >= 3 and not re.search(r"[aeiou]", w)
        racha = bool(re.search(r"[^aeiou]{5,}", w))
        repetida = len(w) >= 3 and len(set(w)) == 1
        poco_vocal = len(w) >= 5 and sum(c in "aeiou" for c in w) / len(w) < 0.2
        if sin_vocal or racha or repetida or poco_vocal or re.fullmatch(r"(?:qwe|asd|zxc|qaz|wsx|ert|sdf|dfg|fgh|ghj|hjk|jkl|xcv|cvb|vbn)+[a-z]?", w):
            malas += len(w)
    return malas / max(letras, 1) > 0.5


def es_contrapregunta(texto: str) -> bool:
    """«¿cuál es el correo web?»: pregunta algo en vez de responder a lo que se le preguntó."""
    return "?" in (texto or "") and bool(RE_CONTRAPREGUNTA.match(_plano(texto)))

RE_NO_SABE = re.compile(r"\bno (lo )?se\b|\bni idea\b|\bno (me )?acuerdo\b|\bno recuerdo\b|\bno tengo (idea|el dato)\b|\bno lo (tengo|veo|encuentro)\b|\bno se (cual|cuando|como se llama)\b|"
                        r"\bno se donde\b|\bno hay (etiqueta|numero)\b|\bno tiene (etiqueta|nombre)\b|\bno sabria\b")
RE_ESPERA = re.compile(r"\b(un momento|un momentito|un segundo|un ratito|a ver|dejame (ver|buscar|revisar|mirar)|ahorita (te|lo|la)|ahora te|ya te (digo|paso|mando)|espera(me)?\b|lo busco|la busco|voy a (ver|buscar|revisar))\b")


def _limpiar_valor(texto: str, maximo: int = 80) -> str:
    return _forma(re.sub(r"\s+", " ", texto))[:maximo]


def leer(mem: dict, texto: str, perfil: dict | None = None) -> dict:
    """Actualiza la memoria con el mensaje y dice qué pasó con la pregunta pendiente.

    Devuelve {"pendiente": la que había, "respondio": bool, "espera": bool, "no_sabe": bool, "datos": {...extraídos y
    guardados}, "nuevos": {campo: valor de lo que no se sabía}}.
    """
    pend = mem.get("pendiente", "")
    t = _plano(texto)
    sedes = tuple(x for x in ((perfil or {}).get("sede"),) if isinstance(x, str))
    contra = es_contrapregunta(texto) and pend in DATO_DE
    datos = {} if contra else extraer(texto, pend, sedes, mem.get("categoria", ""))
    pregunta = "?" in (texto or "")
    palabras = len(t.split())
    nuevos = {}
    sab = mem["sabemos"]

    # Respuestas cortas a una pregunta abierta: el texto mismo es el dato.
    if pend in ("aplicacion", "impresora", "area", "que_solicita") and pend and DATO_DE[pend] not in datos and not pregunta \
            and 0 < palabras <= 8 and not RE_NO_SABE.search(t) and not afirma(texto) and not niega(texto) and not RE_ESPERA.search(t) and not hay_otra_cosa(texto):
        datos[DATO_DE[pend]] = _limpiar_valor(texto)
    if pend == "mensaje_error" and "mensaje_error" not in datos and not pregunta and 0 < palabras <= 25 and not RE_NO_SABE.search(t) \
            and not niega(texto) and not afirma(texto) and not RE_ESPERA.search(t) and not hay_otra_cosa(texto):
        datos["mensaje_error"] = _limpiar_valor(texto, 100)
    if pend == "mensaje_error" and "mensaje_error" not in datos and niega(texto):
        datos["mensaje_error"] = SIN_MENSAJE
    if pend == "sede_piso" and "sede" not in datos and "piso" in datos and not sab.get("sede") and not (perfil or {}).get("sede"):
        pass   # dijo solo el piso: la sede sigue faltando
    for k, v in list(datos.items()):
        if k == "pasos_probados":
            hechos = sab.setdefault("pasos_probados", [])
            for p in v:
                if p not in hechos:
                    hechos.append(p)
                    nuevos.setdefault("pasos_probados", []).append(p)
            sab["pasos_probados"] = hechos[-10:]
            continue
        previo = sab.get(k)
        if k == "impacto" and previo and v == "persona" and pend not in ("afecta_otros", "imprime_otro"):
            continue            # «solo yo» no estrecha lo que ya se sabía de otro modo; solo si se le preguntó
        if k == "caida":
            if not previo:
                sab["caida"] = True
                nuevos["caida"] = True
            continue
        if k == "urgencia" and previo and URGENCIAS.index(previo) > URGENCIAS.index(v) and v != "baja":
            continue            # la urgencia no baja sola
        if k in ("sintoma",):
            continue
        if previo != v:
            if previo in (None, DESCONOCIDO, SIN_MENSAJE) or k in ("impacto", "urgencia", "equipo", "sede", "piso", "area", "mensaje_error", "desde"):
                nuevos[k] = v
        sab[k] = v

    res = {"pendiente": pend, "respondio": False, "espera": False, "no_sabe": False, "datos": datos, "nuevos": nuevos}
    if pend == "puntaje":
        n = puntaje_en(texto)
        if n:
            sab["puntaje"] = n
            res["respondio"] = True
            datos["puntaje"] = n
    elif pend in ("resolvio", "ofrecer_tecnico"):
        res["respondio"] = bool(afirma(texto) or niega(texto) or confirma(texto) or sigue_igual(texto) or re.match(r"^(?:si+|no+)\b", t))
    elif pend in DATO_DE:
        campo = DATO_DE[pend]
        res["respondio"] = bool(datos.get(campo)) or (pend == "sede_piso" and "piso" in datos and sabe(mem, "sede", perfil))
        if not res["respondio"] and not pregunta and RE_NO_SABE.search(t) and pend != "que_pasa":
            sab[campo] = DESCONOCIDO
            res["respondio"] = res["no_sabe"] = True
    if not res["respondio"] and RE_ESPERA.search(t) and not pregunta:
        res["espera"] = True
    if res["respondio"]:
        mem["pendiente"] = ""
    return res


_PUNTAJE_PAL = {"uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "pesimo": 1, "pesima": 1, "malo": 1, "mala": 1, "regular": 3,
                "bueno": 4, "buena": 4, "muy bueno": 5, "muy buena": 5, "excelente": 5}


def puntaje_en(texto: str) -> int | None:
    """La calificación de 1 a 5 que dice el mensaje (cifra o palabra); None si no dice ninguna."""
    t = _plano(texto)
    m = re.search(r"(?<![\d.,])(?<!las )(?<!la )(?<!el )(?<!hace )(?<!piso )(?<!pc-)([1-5])(?![\d.,]|\s*(?:horas|dias|minutos|pm|am|:|ya\b|veces|intentos))", t)
    if m and len(t.split()) <= 8:
        return int(m.group(1))
    for pal in sorted(_PUNTAJE_PAL, key=len, reverse=True):
        if re.search(rf"\b{pal}\b", t):
            return _PUNTAJE_PAL[pal]
    return None


def registrar_respuesta(mem: dict, respuesta: str = "", forzar: str | None = None) -> str:
    """Anota lo que preguntó el asistente. `forzar` lo fija el código cuando la pregunta es suya. Si el texto no
    pregunta nada reconocible, la pendiente sin responder sigue (solo las persistentes); el resto se limpia."""
    clave = forzar if forzar is not None else pregunta_de(respuesta)
    if clave:
        mem["pendiente"] = clave
        if clave in PEND_DATOS and (clave not in mem["preguntado"] or (clave in REPETIBLES and mem["preguntado"].count(clave) < VECES_REPETIBLE)):
            mem["preguntado"].append(clave)
        elif clave in PEND_OTRAS and clave not in mem["preguntado"]:
            mem["preguntado"].append(clave)
    elif mem.get("pendiente") not in PERSISTENTES:
        mem["pendiente"] = ""
    return mem["pendiente"]


def veces(mem: dict, k: str) -> int:
    return mem["preguntado"].count(k)


def ya_hecha(mem: dict, k: str) -> bool:
    """Se preguntó y no toca repetirla: la de `REPETIBLES`, tras dos intentos; el resto, tras uno."""
    return veces(mem, k) >= (VECES_REPETIBLE if k in REPETIBLES else 1)


def sabe(mem: dict, campo: str, perfil: dict | None = None) -> bool:
    """¿Ya tenemos ese dato (dicho por la persona, aunque sea «no sé») o lo da su perfil?"""
    if mem["sabemos"].get(campo):
        return True
    perfil = perfil or {}
    if campo == "sede" and perfil.get("sede"):
        return True
    if campo == "area" and perfil.get("area"):
        return True
    if campo == "equipo" and isinstance(perfil.get("equipos"), list) and len(perfil["equipos"]) == 1:
        return True
    return False


def datos_de_pregunta(k: str) -> tuple[str, ...]:
    return {"sede_piso": ("sede", "piso")}.get(k, (DATO_DE.get(k, k),))


def preguntas_hechas(mem: dict) -> int:
    """Cuántas preguntas de datos (no las de resolvió/puntaje/qué pasa) se le hicieron ya en este caso."""
    return sum(1 for k in mem["preguntado"] if k in PEND_DATOS and k != "que_pasa")


def siguiente(mem: dict, categoria: str = "", intencion: str = "", perfil: dict | None = None, maximo: int = MAX_PREGUNTAS_DATOS) -> str:
    """La pregunta de datos que toca: la primera de la categoría que no se sepa ni se haya hecho ya. '' si no queda
    ninguna (o si ya se hicieron `maximo`: no se interroga a nadie)."""
    if preguntas_hechas(mem) >= maximo:
        return ""
    if intencion in ORDEN_SOLICITUD:
        orden = ORDEN_SOLICITUD[intencion]
    else:
        orden = ORDEN.get(categoria or mem.get("categoria") or "otro", ORDEN["otro"])
    for k in orden:
        if all(sabe(mem, c, perfil) for c in datos_de_pregunta(k)) and k != "que_pasa":
            continue
        if k == "que_pasa" and mem["sabemos"].get("sintoma"):
            continue
        if k == "sede_piso" and sabe(mem, "sede", perfil) and sabe(mem, "piso"):
            continue
        if k in ("afecta_otros", "imprime_otro") and mem["sabemos"].get("impacto"):
            continue
        if ya_hecha(mem, k):
            continue
        if k == "piso" and sabe(mem, "piso"):
            continue
        return k
    return ""


def texto_pregunta(k: str, mem: dict, categoria: str = "", perfil: dict | None = None) -> str:
    """El texto de la pregunta `k`, ajustado a la categoría y a lo que ya se sabe. Cada variante se reconoce con
    DETECTOR igual que la de PREGUNTAS (lo comprueba la prueba)."""
    cat = categoria or mem.get("categoria") or ""
    if k == "aplicacion":
        if cat == "correo":
            return "¿Lo usas en Outlook, en el correo web o en el celular?"
        if cat == "sistema_interno":
            return "¿En qué sistema te pasa? Dime su nombre, por ejemplo «sistema de ventas»."
        if cat == "cuentas_accesos":
            return "¿En qué programa o sistema no puedes entrar?"
        if cat == "software_oficina":
            return "¿En qué programa te pasa: Excel, Word, Teams u otro?"
    if k == "sede_piso" and sabe(mem, "sede", perfil) and not sabe(mem, "piso"):
        return PREGUNTAS["piso"] if cat != "impresoras" else "¿En qué piso está la impresora?"
    if k == "sede_piso" and cat == "impresoras":
        return "¿En qué sede y piso está la impresora?"
    if k == "mensaje_error" and cat == "vpn":
        return "¿La VPN te muestra algún mensaje o código de error? Si lo ves, escríbelo tal cual."
    if k == "que_solicita" and cat in ("cuentas_accesos", "sistema_interno"):
        return "¿A qué carpeta o sistema necesitas acceso? Dime el nombre."
    if k == "que_solicita" and cat in ("equipo", "software_oficina", "impresoras", "telefonia"):
        return "¿Qué equipo o programa necesitas y para qué lo vas a usar?"
    return PREGUNTAS.get(k, "")


def quitar_repetidas(texto: str, mem: dict, permitida: str = "", vaciar: bool = False, perfil: dict | None = None) -> str:
    """Quita del texto del LLM las preguntas que ya se hicieron o cuya respuesta ya sabemos (salvo `permitida`).
    Si un párrafo se queda vacío, se va entero; si todo se iría, se deja como estaba (o vacío con `vaciar`)."""
    hechas = set(mem["preguntado"])

    def sobra(q: str) -> bool:
        k = clave_de(q)
        if not k or k == permitida or k in PERSISTENTES:
            return False
        if k in hechas and k not in REPETIBLES:
            return True
        return k in DATO_DE and all(sabe(mem, c, perfil) for c in datos_de_pregunta(k))

    partes = []
    for p in (texto or "").split("\n\n"):
        frases, quitando = [], False
        for fr in re.split(r"(?<=[.!?])\s+", p.strip()):
            if "?" in fr:
                quitando = sobra(fr)
                if not quitando:
                    frases.append(fr)
            elif not quitando:          # lo que sigue a una pregunta quitada suele ser su porqué: se va con ella
                frases.append(fr)
        nuevo = re.sub(r"\s{2,}", " ", " ".join(frases)).strip()
        if re.search(r"\w", nuevo):
            partes.append(nuevo)
    return "\n\n".join(partes) if partes else ("" if vaciar else (texto or ""))


NOMBRES = {"sintoma": "problema", "aplicacion": "programa o sistema", "mensaje_error": "mensaje de error", "desde": "desde cuándo",
           "equipo": "equipo", "sede": "sede", "piso": "piso", "area": "área", "impacto": "a cuántos afecta", "urgencia": "urgencia",
           "impresora": "impresora", "tipo_red": "conexión", "anexo": "anexo", "solicitud": "lo que pide"}


def lo_que_sabemos(mem: dict, perfil: dict | None = None) -> str:
    """Resumen de la ficha para el prompt del LLM y para la consola."""
    sab = mem["sabemos"]
    partes = [f"{NOMBRES[k]}: {v}" for k, v in sab.items() if k in NOMBRES and v and v not in (DESCONOCIDO, SIN_MENSAJE)]
    if sab.get("caida"):
        partes.append("es una caída")
    if sab.get("pasos_probados"):
        partes.append("ya probó: " + ", ".join(sab["pasos_probados"]))
    perfil = perfil or {}
    for k, nombre in (("sede", "sede"), ("area", "área")):
        if perfil.get(k) and not sab.get(k):
            partes.append(f"{nombre} (perfil): {perfil[k]}")
    return "; ".join(partes) or "nada todavía"


def completar_con_perfil(mem: dict, perfil: dict | None) -> dict:
    """Copia a la ficha lo que el perfil sabe y la persona no dijo (sede, área, el único equipo que tiene registrado).
    Se usa al proponer una incidencia, no antes: así no se pregunta lo que ya se sabe, pero tampoco se afirma que lo dijo."""
    perfil = perfil or {}
    sab = mem["sabemos"]
    for k in ("sede", "area"):
        if not sab.get(k) and isinstance(perfil.get(k), str) and perfil[k]:
            sab[k] = perfil[k][:80]
    eq = perfil.get("equipos")
    if not sab.get("equipo") and isinstance(eq, list) and len(eq) == 1 and isinstance(eq[0], str):
        sab["equipo"] = eq[0][:40]
    return mem


def anotar_turno(mem: dict, etapa: str, categoria: str = "", articulos: list[str] = ()) -> None:
    mem["etapa"] = etapa or mem["etapa"]
    if categoria in CATEGORIAS:
        mem["categoria"] = categoria
    for c in articulos:
        if c and c not in mem["articulos_mostrados"]:
            mem["articulos_mostrados"].append(c)
    mem["articulos_mostrados"] = mem["articulos_mostrados"][-20:]
    mem["turnos"] = min(mem.get("turnos", 0) + 1, 1000)


def nuevo_tema(mem: dict, categoria: str = "", conservar_pendiente: bool = False) -> dict:
    """La persona cambió de tema: ficha en blanco para el problema nuevo. Se conserva lo que es de la persona (sede, área,
    equipo, impresora no) y se reinician artículos, intentos y preguntas hechas."""
    viejo = mem["sabemos"]
    mem["sabemos"] = {k: None for k in CAMPOS} | {"pasos_probados": []}
    for k in ("sede", "piso", "area", "equipo"):
        mem["sabemos"][k] = viejo.get(k)
    mem["articulos_mostrados"], mem["intentos_guia"], mem["preguntado"], mem["incidencia"] = [], 0, [], None
    mem["turnos_guia"] = 0
    mem["intencion_caso"] = ""
    mem["sin_entender"] = 0
    if not conservar_pendiente:
        mem["pendiente"] = ""
    mem["categoria"] = categoria if categoria in CATEGORIAS else ""
    return mem


def reconstruir(historial: list, etapa: str = "", perfil: dict | None = None) -> dict:
    """Memoria para quien no la manda (llamadas viejas): se repasa el historial con las mismas reglas."""
    mem = nueva()
    mem["etapa"] = etapa if etapa else "recepcion"
    bot = []
    for t in (historial or [])[-30:]:
        rol = t.get("rol") if isinstance(t, dict) else getattr(t, "rol", "")
        txt = (t.get("texto") if isinstance(t, dict) else getattr(t, "texto", "")) or ""
        if rol == "usuario":
            if bot:
                registrar_respuesta(mem, "\n\n".join(bot))
                bot = []
            leer(mem, txt, perfil)
            # El primer mensaje con contenido es el síntoma, y sus palabras dicen la categoría (aquí no hay clasificador): sin esto, una incidencia
            # propuesta con la memoria perdida saldría sin título ni categoría.
            if not mem["sabemos"].get("sintoma") and len(txt.split()) >= 3 and not (afirma(txt) or niega(txt) or confirma(txt) or sigue_igual(txt)):
                mem["sabemos"]["sintoma"] = txt.strip()[:140]
                mem["categoria"] = categoria_por_palabras(txt) or ""
                mem["intencion_caso"] = "reportar_falla"
        else:
            bot.append(txt)
    if bot:
        registrar_respuesta(mem, "\n\n".join(bot))
    return mem
