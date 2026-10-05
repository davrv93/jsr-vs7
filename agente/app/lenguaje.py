"""Reglas de lenguaje compartidas: lo que la persona DICE y manda sobre lo que opine el clasificador.

Las usan memoria.py (para leer una respuesta a la pregunta pendiente), etapas.py (para corregir la intención antes de mirar umbrales)
y animo.py. Están aquí, en un solo sitio, para que una misma frase («sigue igual», «quiero hablar con un técnico») signifique lo mismo
en todas partes. Todo opera sobre texto plano (sin tildes, en minúsculas, con las abreviaturas de chat resueltas).

Sin dependencias: se prueba con prueba_memoria.py y prueba_etapas.py.
"""
from __future__ import annotations

import re

from .datos import plano


_ABREV = {"pa": "para", "xa": "para", "pal": "para el", "q": "que", "ke": "que", "k": "que", "x": "por", "xq": "porque",
          "tb": "tambien", "tmb": "tambien", "d": "de", "xfa": "por favor", "porfa": "por favor", "ps": "pues", "pe": "pues",
          "pc": "pc", "cel": "celular", "lap": "laptop", "compu": "computadora"}
_RE_ABREV = re.compile(r"(?<![\w/-])(?:" + "|".join(k for k in _ABREV if k not in ("pc", "lap", "compu", "cel")) + r")(?![\w/-])")


def _plano(s: str) -> str:
    s = plano(s)
    return _RE_ABREV.sub(lambda m: _ABREV[m.group(0)], s)


RE_AFIRMA = re.compile(r"^(s+i+p?|sii+|claro( que si)?|ok(ey|is)?|dale|ya|bueno|listo|correcto|asi es|por supuesto|de acuerdo|perfecto|"
                       r"si+ (claro|por favor|pe|nomas)|esta bien|afirmativo|exacto|eso)[\s.!,]*(gracias[\s.!,]*)?$")
RE_NIEGA = re.compile(r"^(no+|nop|nel|no gracias|mejor no|todavia no|aun no|ni idea|negativo)[\s.!,]*$")


RE_CONFIRMA = re.compile(
    r"\b(?:ya (?:funciono|funciona|quedo|esta (?:resuelto|solucionado|funcionando|listo|ok)|se (?:arreglo|soluciono|resolvio|normalizo)|pude|puedo|abre|abrio|imprime|imprimio|entro|entre|conecta|conecto|carga|cargo|volvio|ando|anda|sirve|sirvio|salio|escucho|tengo (?:audio|internet|acceso))|"
    r"(?:ahora|ahorita) si (?:abre|funciona|imprime|entra|carga|puedo|me deja|conecta|anda|sirve|sale|escucho|va)|"
    r"(?:se )?(?:soluciono|arreglo|resolvio)\b|problema resuelto|esta resuelto|quedo (?:resuelto|solucionado|perfecto|bien|listo)|funciono\b|con (?:eso|esos pasos) (?:quedo|ya|se arreglo|funciono)|"
    r"todo (?:bien|ok|en orden|listo) (?:ahora|ya)|ya esta (?:todo )?(?:bien|solucionado|resuelto|arreglado|funcionando)|resuelto\b|volvio a funcionar|ya me (?:salio|funciono|dejo)|"
    r"confirmo (?:que )?(?:ya )?(?:quedo|esta|se)|(?:lo )?(?:dejo|dejaron) (?:funcionando|andando)|ya (?:esta|quedo) (?:todo )?perfecto|lo hice tal cual y quedo)\b")
RE_SIGUE_IGUAL = re.compile(
    r"\bsigo sin\b|\bsigue (?:igual|ygual|sin\b|fallando|el mismo|la misma|apareciendo|sin abrir|con (?:el|lo) mismo|lenta|lento|pegad)|\bsigo igual\b|\bsigue la misma\b|\b(?:el|la) (?:problema|falla|error) (?:continua|persiste|sigue|se repite|sigue igual)|\bno (?:funciono|sirvio|se (?:soluciono|arreglo|resolvio)|cambio nada|hubo (?:mejora|cambios?)|paso nada)\b|"
    r"^(?:ah |ps |pues |pe )?(?:otra vez |todo |sigue |sigo con |sale |es )?(?:lo|la) mismo(?: de antes)?(?: pe| nomas| pues| aun)?[\s.!]*$|\btodavia (?:no|sigue)\b|\baun (?:no|sigue)\b|\bnada\b[,.]? ?(?:sigue|no|lo mismo)|\bpersiste\b|\bcontinua\b|\bsin cambios\b|\bigual que antes\b|\bsigue sin\b|\bni asi\b|\bsalio lo mismo\b|"
    r"\bvolvio a salir lo mismo\b|\blamentablemente (?:el problema )?(?:sigue|continua|persiste)\b|\bno paso nada\b|\bestá? igual\b|\besta igual\b|\bhice (?:todo|los pasos|lo que).{0,40}\b(?:y )?(?:nada|sigue|continua)\b|\bsin mejora\b|\bno mejoro\b|\bsigue (?:sin|igual)\b")


def confirma(texto: str) -> bool:
    """¿Dice que ya quedó resuelto? («ya funcionó», «listo, ya abre»)."""
    t = _plano(texto)
    return bool(RE_CONFIRMA.search(t)) and not RE_SIGUE_IGUAL.search(t) and not re.search(r"\bno (?:ha )?(?:funciono|quedo)\b|\bsi (?:ya )?(?:funciona|funcionara)\?", t)


def sigue_igual(texto: str) -> bool:
    """¿Dice que el problema continúa? («sigue igual», «no funcionó»)."""
    t = _plano(texto)
    return bool(RE_SIGUE_IGUAL.search(t)) and not (RE_CONFIRMA.search(t) and not re.search(r"\bsigue\b|\bno funciono\b|\bpersiste\b", t))


def afirma(texto: str) -> bool:
    return bool(RE_AFIRMA.match(_plano(texto)))


# Respuestas cortas que, a «¿quedó resuelto?», quieren decir que NO (y que «niega» solo no cubre).
RE_NIEGA_RESUELTO = re.compile(r"^(?:nada(?: pe| nomas| aun| todavia)?|igual(?:ito)?(?: pe| nomas)?|tampoco|sin cambios?|nel|ni asi|aun no|todavia no|seguimos igual)[\s.!,]*$")


def afirma_resuelto(texto: str) -> bool:
    """Un «sí» claro a «¿quedó resuelto?» y nada más («sí», «sí pe», «claro que sí», «sí, gracias»). «ok», «ya», «dale» o «listo» NO valen
    (pueden querer decir «voy a probarlo») y «sí, desde ayer» tampoco (responde otra cosa): no se cierra un caso por eso."""
    t = _plano(texto)
    if niega(texto):
        return False
    m = re.match(r"^(?:s+i+p?|claro(?: que si)?|correcto|asi es|exacto|por supuesto|afirmativo)\b(.*)$", t)
    if not m:
        return False
    resto = re.findall(r"[a-zñ]+", m.group(1))
    return all(w in {"pe", "pues", "nomas", "gracias", "si", "claro", "ya", "por", "favor", "muchas", "mil", "que", "ahora", "eso", "era"} for w in resto) and len(resto) <= 3


def niega(texto: str) -> bool:
    return bool(RE_NIEGA.match(_plano(texto)))




_PERSONA = r"(?:un |una |el |la |al |a )?(?:tecnic[oa]s?|personas?|humano|alguien|ingenier[oa]|especialista|asesor[a]?|operador[a]?|agente|encargad[oa]|responsable|supervisor[a]?|persona real|ser humano)"
RE_PIDE_TECNICO = re.compile(
    rf"\bhabl(?:ar|e|o) (?:directamente )?con {_PERSONA}\b|\b(?:pasame|pasenme|pasa me|comunicame|comuniquenme|derivame|derivenme|dejenme|derivarme|comunicarme|contactarme|ponme|pongame|pongan me) (?:con|a|en contacto con) {_PERSONA}|"
    rf"\b(?:que )?(?:me )?(?:llame|llamen|atienda|atiendan|contacte|contacten|escriba|escriban) {_PERSONA}|\bquiero que (?:me )?(?:llame|llamen|atienda|atiendan|contacte|contacten)\b|"
    rf"\b(?:necesito|quiero|prefiero|requiero|exijo|quisiera) (?:que (?:me )?(?:atienda|atiendan|vea|revise|ayude) )?{_PERSONA}\b[^.?!]{{0,30}}(?:ayude|atienda|revise|vea|llame|por favor|me )?|"
    rf"\b(?:puede|pueden|podria|podrian) venir {_PERSONA}|\bque (?:venga|vengan|venga a ver|vengan a ver|vea|revise) {_PERSONA}|\b(?:envi\w+|mand\w+) (?:a )?(?:alguien|un tecnico|una persona)\b|"
    rf"\bno quiero (?:seguir )?(?:con )?(?:el |un |la )?(?:bot|asistente|robot|chat|maquina)\b|\bsoporte (?:presencial|humano)\b|\bateni?cion humana\b|\bescal(?:en|a|ar) (?:mi )?(?:caso|incidencia)\b|"
    rf"\bun humano\b|\buna persona (?:real|de verdad)\b|\bhumano por favor\b|\b(?:me )?(?:puede|pueden|podria|podrian) contactar {_PERSONA}|\bpersona (?:de|del) (?:soporte|sistemas|la mesa de ayuda)\b|"
    rf"\balguien (?:de|del) (?:soporte|sistemas|ti|la mesa de ayuda)\b[^.?!]{{0,20}}(?:me llame|me ayude|que vea|que venga)|\bno me (?:sirve|ayuda) el chat\b|\bno logro resolverlo\b[^.?!]{{0,20}}que alguien\b|"
    rf"\bque alguien (?:lo |la )?(?:vea|revise|venga|me llame|me ayude)\b|\bpor telefono\b[^.?!]{{0,20}}{_PERSONA}|\bprefiero hablar con\b")
RE_ESTADO = re.compile(
    r"\bcomo (?:va|vamos|esta|queda)\b[^.?!]{0,25}\b(?:ticket|tiket|incidencia|insidencia|caso|solicitud|solisitud|pedido|reporte|reclamo|requerimiento)\b|\binc-?\d{3,}\b|"
    r"\b(?:novedad(?:es)?|avance|respuesta|noticias?|nobedad)\b[^.?!]{0,12}\b(?:de|sobre|para|del|con|a)\b[^.?!]{0,30}\b(?:ticket|incidencia|caso|solicitud|reporte|pedido|reclamo)\b|"
    r"\bestado de (?:mi|la|el)\b|\ben que (?:va|esta|quedo|ba)\b[^.?!]{0,30}\b(?:ticket|tiket|incidencia|caso|reporte|solicitud|pedido|reclame?|lo que)\b|"
    r"\bya (?:asignaron|resolvieron|vieron|revisaron|aprobaron|atendieron|hay tecnico)\b|\b(?:quien|que tecnico) (?:es|lleva|ve|atiende|tiene|va a ver)\b[^.?!]{0,25}\b(?:caso|incidencia|ticket|reporte)\b|"
    r"\bcuanto (?:falta|mas|tiempo)\b[^.?!]{0,30}\b(?:atiendan|atienda|resuelv\w+|respond\w+|caso|incidencia|esperar|ticket)\b|\bsigue abiert[oa]\b|\bya (?:la |lo )?(?:cerraron|serraron)\b|"
    r"\bse acuerdan de mi\b|\bsigo esperando\b[^.?!]{0,25}\b(?:noticias|respuesta|nobedad)\b|\bpara cuando (?:estaria|esta|seria|va a estar)\b[^.?!]{0,25}\b(?:lista|listo|mi)\b|"
    r"\bya se sabe\b|\bhay (?:alguna )?(?:novedad|respuesta)\b|\balguna novedad\b|\bcuando me (?:van a )?respond\w+\b|\bhay alguna respuesta\b|\bme dicen (?:en que|como)\b|"
    r"\bavance de mi\b|\bquisiera saber (?:en que estado|si ya)\b|\bquiero saber (?:quien|si ya|en que)\b|\bconsulto por\b[^.?!]{0,30}\b(?:avance|estado|caso|reclamo)\b|\bmi (?:caso|incidencia|ticket|solicitud) (?:de|del)\b[^.?!]{0,30}\?")
RE_QUEJA = re.compile(
    r"\bpesim[oa]\b|\binaceptable\b|\bfalta de (?:respeto|seriedad)\b|\bdesastre\b|\bme hacen perder (?:el )?tiempo\b|\bnadie (?:me )?(?:responde|contesta|hace nada|atiende|me atendio|me aviso|vino|lo soluciona|me atiende)\b|"
    r"\b(?:segunda|tercera|cuarta|quinta|sexta) (?:vez|bes)\b|\bya (?:van|llevo|llevamos|ban|llebo) (?:\w+ ){0,2}(?:dias|semanas|horas|sinco dias)\b[^.?!]{0,40}\b(?:nadie|sin respuesta|ninguna respuesta|ni una|y no|esperando)\b|"
    r"\bestoy (?:muy |re |super )?(?:molest|harto|arto|cansad|disgustad|indignad|furios)\w*|\bme (?:harte|canse)\b|\bya me (?:harte|canse)\b|\bburla\b|\bmal servicio\b|\bmal serbicio\b|\bno sirve(?:n)? (?:el )?soporte\b|"
    r"\bquiero (?:poner|presentar|hacer|un) (?:una )?(?:queja|keja|reclamo|reclamar)\b|\bnunca (?:llego|vino|contestan)\b|\bme dejaron (?:plantad|esperando)\b|\bque (?:mal|desastre)\b|\bsiempre (?:es )?lo mismo con ustedes\b|"
    r"\bpeor servicio\b|\bhasta cuando\b|\bson (?:lentisimos|unos inutiles|inutiles)\b|\bfalta de interes\b|\ba nadie le importa\b|\bvoy a reclamar\b|\bme prometieron\b[^.?!]{0,40}\bsigo\b|\bincreible que\b|\bme tienen? (?:esperando|botado)\b|"
    r"\bpesima atencion\b|\bpesimo servicio\b|\bsoporte (?:no sirve|es malo|pesimo)\b|\btrato que recibi\b|\bdisgustad\w+ con\b|\bquiero reclamar\b")
RE_SOLO_ACUSE = re.compile(r"^(?:ok(?:ey|is)?|vale|ya|listo|entiendo|entendido|de acuerdo|bueno|esta bien|perfecto|muy bien|genial|ah+|aja)[\s.!,]*$")


def pide_tecnico(texto: str) -> bool:
    return bool(RE_PIDE_TECNICO.search(_plano(texto)))


def pregunta_por_estado(texto: str) -> bool:
    return bool(RE_ESTADO.search(_plano(texto)))


def es_queja(texto: str) -> bool:
    return bool(RE_QUEJA.search(_plano(texto)))


def numero_en(texto: str) -> str | None:
    """«INC-000142», «inc 142», «el 142»: el número de incidencia que menciona, en su forma canónica (INC-000142)."""
    m = re.search(r"\binc[-\s]?(\d{1,10})\b", (texto or "").lower())
    return f"INC-{int(m.group(1)):06d}" if m else None



def hay_otra_cosa(texto: str) -> bool:
    """¿El mensaje dice algo que NO es el dato que se le pidió (sigue igual, ya funcionó, un técnico, una queja, el estado)? Sirve para no
    tomar «sigue igual» por el nombre de un programa cuando se le preguntó en qué programa le pasa."""
    return confirma(texto) or sigue_igual(texto) or pide_tecnico(texto) or es_queja(texto) or pregunta_por_estado(texto)


# --- categoría por palabras clave -----------------------------------------------------------------------------------------------
# Un respaldo determinista para el clasificador: si el mensaje nombra cosas de UNA sola categoría («la impresora…», «el Outlook…», «la VPN…»), esa es
# la categoría aunque el clasificador dude. Si nombra de dos o más categorías, no dice nada y manda el clasificador.
PALABRAS_CATEGORIA = {
    "correo": re.compile(r"\b(?:correos?|outlook|bandeja de (?:entrada|salida)|e-?mail|buzon(?! de voz)|adjuntos?|webmail)\b"),
    "impresoras": re.compile(r"\b(?:impresoras?|imprimir|imprime[ns]?|impresion|toner|cartucho|escaner|fotocopiadora|multifuncional|papel atascado|atasco de papel)\b"),
    "vpn": re.compile(r"\b(?:vpn|vepeene)\b"),
    "red_wifi": re.compile(r"\b(?:wifi|wi-?fi|internet|interne|ethernet|router|punto de red|cable de red|la red)\b"),
    "telefonia": re.compile(r"\b(?:telefonos?|anexos?|llamadas?|central telefonica|buzon de voz|tono)\b"),
    "software_oficina": re.compile(r"\b(?:excel|ecxel|word|power ?point|teams|tims|zoom|pdf|acrobat|office|onedrive|sharepoint)\b"),
    "sistema_interno": re.compile(r"\b(?:sistema (?:de|interno|contable)|aplicativo|intranet|planillas|facturacion|modulo de)\b"),
    "cuentas_accesos": re.compile(r"\b(?:contrasenas?|claves?|cuenta bloqueada|usuario bloqueado|permisos?|iniciar sesion|codigo de verificacion)\b"),
    "equipo": re.compile(r"\b(?:laptop|lap|computadora|compu|monitor|teclado|mouse|maus|pantalla|bateria|disco duro|ventilador|cargador)\b"),
}


def categoria_por_palabras(texto: str) -> str | None:
    """La única categoría cuyas palabras aparecen en el mensaje; None si no aparece ninguna o si aparecen de varias."""
    t = _plano(texto)
    hits = [c for c, rx in PALABRAS_CATEGORIA.items() if rx.search(t)]
    return hits[0] if len(hits) == 1 else None


def categoria_final(texto: str, cat: str, conf: float, umbral: float = 0.92) -> tuple[str, float, bool]:
    """(categoría, confianza, ¿la corrigieron las palabras?): las palabras mandan sobre un clasificador que no está muy seguro."""
    kw = categoria_por_palabras(texto)
    if kw and kw != cat and conf < umbral:
        return kw, max(conf, 0.8), True
    return cat, conf, False


# Olvidar, perder, bloquear o vencer la contraseña o el usuario: un lenguaje muy formulaico, y el clasificador a veces lo confunde con una falla.
RE_RESTABLECER = re.compile(
    r"\bolvid\w+ (?:mi|la|el|las) (?:contrasena|clave|usuario|pin)\b|\bno (?:me )?(?:acuerdo|recuerdo|se) (?:de )?(?:mi |la |el )?(?:contrasena|clave|usuario)\b|"
    r"\b(?:contrasena|clave|usuario|cuenta)\b[^.?!]{0,25}\b(?:bloquead[oa]|expir\w+|venc\w+|inhabilitad[oa]|caduc\w+)|"
    r"\bse me (?:bloqueo|olvido|vencio|expiro)\b[^.?!]{0,25}\b(?:usuario|cuenta|clave|contrasena)\b|"
    r"\b(?:reset\w+|restablec\w+|recuper\w+|cambiar|desbloque\w+)\b[^.?!]{0,20}\b(?:mi |la |el )?(?:contrasena|clave|usuario|cuenta)\b")
# «mejor olvídalo, ahora la impresora…»: la persona avisa que cambia de tema.
RE_OTRO_TEMA = re.compile(r"\b(?:mejor olvidalo|olvidalo|olvida eso|dejalo asi|dejemoslo|ahora (?:es|tengo|me pasa|me sale|otra|resulta que|el|la|mi|los|las)|aparte|ademas|otra cosa|otro problema|por otro lado|y tambien)\b")
CATEGORIAS_ESPECIFICAS = frozenset({"correo", "impresoras", "vpn", "red_wifi", "telefonia", "software_oficina", "sistema_interno"})   # nombran un objeto concreto: sirven para detectar un cambio de tema


def pide_restablecer(texto: str) -> bool:
    return bool(RE_RESTABLECER.search(_plano(texto)))


def marca_otro_tema(texto: str) -> bool:
    return bool(RE_OTRO_TEMA.search(_plano(texto)))
