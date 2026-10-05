"""Verificación de las respuestas antes de enviarlas: grounding por frase y «¿contestó?» (Jev local, partes b y c).

Qué comprueba: que lo que dice la respuesta (la pieza «responde» que redacta un LLM; los pasos los pone el código y
siempre salen del artículo) está respaldado por la fuente (el artículo, lo que la persona escribió y la ficha del caso).

Backends enchufables, de lo obligatorio a lo opcional:

(a) **Obligatorio y sin descargas extra** (`VerificadorLocal`): por frase,
    · coincidencia léxica de DATOS: números, nombres entre comillas o de menú, comandos, rutas, combinaciones de teclas,
      siglas y nombres propios a mitad de frase, y VERBOS DE PASO (reinstala, borra, ejecuta…): si la frase trae algo de eso y la
      fuente no lo tiene, la frase no está respaldada;
    · similitud de embeddings e5 entre la frase y el pasaje más parecido de la fuente: una frase que AFIRMA algo (da un paso,
      una causa, una cifra) y no se parece a nada de la fuente, no está respaldada. Las frases de cortesía y las preguntas no se verifican.
(b) **NLI mDeBERTa-xnli** (`NLI`, opcional, perezoso): inferencia natural frase↔pasajes, en ONNX int8 (317 MB, MIT).
    Se activa con `VERIFICAR_NLI=1` y el modelo en `NLI_DIR` (por defecto `modelos/nli`); cómo bajarlo: LEEME.md y juez/README.md.
    Si no está, se degrada solo al backend (a), sin error.
(b′) **LettuceDetect-es** (`Lettuce`, opcional, perezoso): tramos sin respaldo en la respuesta entera. Se activa con
    `VERIFICAR_LETTUCE=1` y `pip install lettucedetect` (el modelo pesa 2,4 GB: NO se baja aquí).
(c) **«¿Contestó?»** (`contesta`): cobertura de las palabras de la pregunta en la respuesta + similitud de embeddings. Reranker
    opcional (`CONTESTA_RERANKER`): no se baja aquí.

Política (ARQUITECTURA §6), que orquesta main.py con lo que devuelve `revisar`:
    1. se parte la respuesta en frases;  2. se quita la frase con un dato o un paso que la fuente no respalda;
    3. si se quitó algo de peso, se regenera UNA vez con la fuente;  4. si vuelve a fallar, se responde con los pasos
    del artículo armados por código (plantillas.py);  5. si «¿contestó?» sale negativo, se regenera una vez.

Modo (`VERIFICAR_MODO`, por defecto `sombra`): `sombra` calcula y registra lo que quitaría pero deja pasar el texto; `activo` quita y avisa
(hay que pedirlo por entorno, con una cifra que lo justifique); `apagado` no revisa.
Sin dependencias pesadas para (a): se prueba con `python -m app.prueba_verificar` y se mide con `python -m app.evaluar_juez`.
"""
from __future__ import annotations

import logging
import os
import re
import threading
import time

import numpy as np

from .datos import plano

log = logging.getLogger("agente.verificar")

MODO = os.environ.get("VERIFICAR_MODO", "sombra").strip().lower()         # sombra | activo | apagado (AGENTS.md regla 6: lo nuevo arranca en sombra)
TAU_SIM = float(os.environ.get("VERIFICAR_TAU_SIM", "0.90"))              # parecido mínimo de una frase que afirma algo (calibrado en la mitad `cal` del dorado)
TAU_NLI = float(os.environ.get("VERIFICAR_TAU_NLI", "0.50"))              # P(implica) mínima, si el NLI está activo
TAU_ECO = float(os.environ.get("VERIFICAR_TAU_ECO", "0.92"))               # parecido mínimo con lo que la persona escribió para ser un eco
TAU_CONTESTA = float(os.environ.get("CONTESTA_TAU", "0.35"))
USAR_NLI = os.environ.get("VERIFICAR_NLI", "0") == "1"
USAR_LETTUCE = os.environ.get("VERIFICAR_LETTUCE", "0") == "1"
NLI_DIR = os.environ.get("NLI_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "modelos", "nli"))
NLI_ARCHIVO = os.environ.get("NLI_ARCHIVO", "onnx/model_int8.onnx")

# --- partir en frases ----------------------------------------------------------------------------------------------
_RX_NUMERACION = re.compile(r"^\s*(?:\d+[.)]|[-*•])\s+")


def dividir_frases(texto: str) -> list[str]:
    """Las frases de un texto: por salto de línea y por puntuación final. Los números con decimales («10.0.19045») no parten."""
    out = []
    for linea in (texto or "").replace("\r", "").split("\n"):
        linea = _RX_NUMERACION.sub("", linea).strip()
        if not linea:
            continue
        t = re.sub(r"(?<=\d)\.(?=\d)", "\u2024", linea)
        t = re.sub(r"\b(Ctrl|Alt|Mayús|Shift|Supr|Ej|etc|Sr|Sra|Ing|Lic)\.(?=\s)", lambda m: m.group(1) + "\u2024", t)
        for f in re.split(r"(?<=[.!?])\s+(?=[A-ZÁÉÍÓÚ¿¡«\"])", t):
            f = f.replace("\u2024", ".").strip()
            if len(re.findall(r"\w", f)) >= 2:
                out.append(f)
    return out


# --- datos que hay que respaldar -----------------------------------------------------------------------------------
_RX_NUMERO = re.compile(r"(?<![\w.,])\d+(?:[.,]\d+)?(?![\w])")
_RX_COMILLAS = re.compile(r"«([^»]{2,60})»|\"([^\"]{2,60})\"|“([^”]{2,60})”")
_RX_COMBO = re.compile(r"\b(?:ctrl|alt|shift|may[uú]s|windows|win|supr|fn)\s*\+\s*[A-Za-z0-9]+(?:\s*\+\s*[A-Za-z0-9]+)*", re.I)
_RX_COMANDO = re.compile(r"\b[a-z][a-z0-9]{2,}(?:\.exe)?(?:\s+/[a-z]+\b)+|\b(?:ipconfig|nslookup|tracert|netsh|regedit|powershell|gpupdate|chkdsk|taskmgr|msconfig|services\.msc|sfc|dism|cmd)\b", re.I)
_RX_RUTA = re.compile(r"\\\\[\w.$-]+(?:\\[\w .$-]+)*|\b[A-Za-z]:\\[\w\\ .-]+|\b[\w-]+\.(?:exe|msc|dll|bat|ini|pst|ost)\b|\bhttps?://\S+", re.I)
_RX_SIGLA = re.compile(r"\b[A-Z]{3,}[A-Z0-9_]*\b")
_RX_MENU = re.compile(r"[A-ZÁÉÍÓÚ][\wáéíóúñ ]{1,35}(?:\s*>\s*[A-ZÁÉÍÓÚ«“\"][\wáéíóúñ ]{1,35})+")

# Verbos que dan un PASO. Solo se miran las formas imperativas («reinstala») y los infinitivos que siguen a un modal de obligación
# («debes reinstalar», «hay que borrar»): «vamos a revisar tu correo» no manda hacer nada.
_IMPERATIVOS = """abre cierra reinicia apaga enciende prende desconecta conecta instala reinstala desinstala borra elimina vacia ejecuta escribe pulsa
presiona haz selecciona elige activa desactiva entra ingresa actualiza descarga cambia restablece repara limpia revisa comprueba verifica prueba
copia guarda espera anota marca desmarca retira coloca acomoda agita imprime cancela olvida formatea configura habilita deshabilita reemplaza
desbloquea bloquea sustituye llama contacta envia pide solicita compra mueve arrastra restaura respalda clona sal inicia""".split()
_INFINITIVOS = """abrir cerrar reiniciar apagar encender prender desconectar conectar instalar reinstalar desinstalar borrar eliminar vaciar ejecutar escribir
pulsar presionar hacer seleccionar elegir activar desactivar entrar ingresar actualizar descargar cambiar restablecer reparar limpiar revisar comprobar
verificar probar copiar guardar esperar anotar marcar desmarcar retirar colocar acomodar agitar imprimir cancelar olvidar formatear configurar habilitar
deshabilitar reemplazar desbloquear bloquear sustituir llamar contactar enviar pedir solicitar comprar mover arrastrar restaurar respaldar clonar salir iniciar""".split()
assert len(_IMPERATIVOS) == len(_INFINITIVOS), "las dos listas de verbos van alineadas una a una"
# Cada verbo, en sus dos formas, pertenece a una «familia» (su infinitivo): «abre» y «abrir» son lo mismo; «cierra» y «cerrar», también.
_FAMILIA = {}
for _imp, _inf in zip(_IMPERATIVOS, _INFINITIVOS):
    _FAMILIA[plano(_imp)] = plano(_inf)
    _FAMILIA[plano(_inf)] = plano(_inf)
_IMP_PLANOS = {plano(v) for v in _IMPERATIVOS}
_CLITICOS = ("me", "te", "lo", "la", "los", "las", "le", "les", "se", "nos", "melo", "telo", "selo")
# Verbos que no cambian nada en el sistema (mirar, anotar, probar): una frase que dice «revisa» o «prueba» no inventa un paso.
_VERBOS_BLANDOS = {plano(v) for v in "prueba probar revisa revisar comprueba comprobar verifica verificar anota anotar espera esperar".split()}
_STEM_VERBO = {v: f for v, f in _FAMILIA.items()}
_RX_MODAL = re.compile(r"\b(?:debes|debe|tienes que|tiene que|hay que|necesitas|necesita|puedes|podrias|conviene|intenta|procura|tendras que|deberas)\s+(?:\w+\s+){0,1}?([a-záéíóúñ]+(?:ar|er|ir))\b")

# Señales de que la frase AFIRMA algo verificable (una causa, un plazo, una garantía, un hecho técnico) aunque no dé un paso.
_RX_AFIRMA = re.compile(
    r"\b(?:se debe|se debio|es causad[oa]|suele\w*|probablemente|seguramente|casi siempre|la mayoria de (?:los )?casos|normalmente|generalmente|a veces|en general|"
    r"garantiz\w+|asegur\w+|siempre|nunca|tarda\w*|demora\w*|dura\w*|plazo|"
    r"soluciona\w*|resuelve\w*|arregla\w*|se arregla|quedara|hay que|debes|tienes que|necesitas|requiere\w*|obligatori\w*|politica|norma|regla|costo|precio|gratis|cuesta|licencia|"
    r"debido a|a causa de|por (?:falta|exceso|culpa) de|puede(?:n)? (?:causar|deberse|ser|provocar|generar)|se produce|ocurre (?:cuando|porque)|es por|porque|ya que|"
    r"esto (?:pasa|ocurre|sucede)|el servidor|la base de datos|el proveedor|el administrador|nivel \d|sistema operativo|version)\b")
_RX_SOCIAL = re.compile(
    r"^(?:entiendo|entendido|lamento|lo siento|gracias|perfecto|claro|con gusto|de nada|vamos a|veamos|tranquil\w+|hola|buen\w+|disculpa\w*|ok\b|listo|anot[eé]|"
    r"encontr[eé] esta gu[ií]a|prueba(?:mos)? con otra gu[ií]a|salt[eé] lo que|te (?:comparto|ayudo|ayudar[eé]|paso)|voy a|estoy (?:aqu[ií]|atento)|no te preocupes|cu[eé]ntame|av[ií]same|"
    r"escr[ií]beme|quedo atent\w+|si (?:necesitas|quieres|tienes)|cuando (?:los|lo|la) pruebes|me alegra|qu[eé] bueno|dime|esperamos|con (?:estos|esos) pasos|en (?:seguida|un momento)|"
    r"tu (?:mensaje|solicitud) (?:fue|ha sido)|estamos (?:para|aqu[ií])|cualquier (?:cosa|duda)|aqu[ií] estoy)\b")
# Pedir una contraseña o un dato de acceso nunca está respaldado: ningún artículo manda dárselos al asistente (AGENTS.md §3.1).
_RX_PIDE_SECRETO = re.compile(r"\b(?:env[ií]a(?:me)?|dame|m[aá]nda(?:me)?|comparte(?:me)?|dime|escribe(?:me)?|pasa(?:me)?|ind[ií]ca(?:me)?)\b[^.?!]{0,30}\b(?:contrase(?:ñ|n)a|clave|password|pin|token|c[oó]digo de acceso)\b", re.I)
_MAYUS_PERMITIDAS = {"windows", "outlook", "teams", "excel", "word", "powerpoint", "chrome", "edge", "firefox", "microsoft", "office", "onedrive", "sharepoint"}


def _toks(t: str) -> list[str]:
    return re.findall(r"[a-z0-9ñ]+", plano(t))


def datos_en(frase: str) -> dict[str, list[str]]:
    """Lo que la frase trae y que la fuente tiene que respaldar: {tipo: [valores en forma plana]}."""
    f = frase.strip()
    out: dict[str, list[str]] = {"numeros": [], "comillas": [], "comandos": [], "rutas": [], "teclas": [], "menus": [], "siglas": [], "propios": [], "verbos": []}
    for m in _RX_COMILLAS.finditer(f):
        v = next(g for g in m.groups() if g)
        out["comillas"].append(plano(v).strip(" .,:;"))
    if ">" in f:
        partes = re.split(r"\s*>\s*", f)
        for k, seg in enumerate(partes):
            seg = seg.strip()
            if k == 0:
                m = re.search(r"((?:[A-ZÁÉÍÓÚ«“\"][\wáéíóúñ»”\"]*\s*){1,3})$", seg)                  # el último elemento antes del primer «>»
                palabras = m.group(1).split() if m else re.findall(r"[\wáéíóúñ«»“”\"]+", seg)[-1:]
            elif k == len(partes) - 1:
                palabras = re.split(r"[,.:;]| y | para | si | en | con ", seg)[0].split()[:3]     # el primero después del último «>»
            else:
                palabras = seg.split()[:4]
            item = plano(" ".join(palabras)).strip(" .,:;«»\"“”")
            if item:
                out["menus"].append(item)
    for m in _RX_COMBO.finditer(f):
        out["teclas"].append(re.sub(r"\s+", "", plano(m.group(0))))
    for m in _RX_COMANDO.finditer(f):
        out["comandos"].append(re.sub(r"\s+", " ", plano(m.group(0))))
    for m in _RX_RUTA.finditer(f):
        out["rutas"].append(plano(m.group(0)))
    # lo que ya se capturó como comando, ruta o tecla no se cuenta de nuevo como número o sigla
    resto = _RX_COMBO.sub(" ", _RX_COMANDO.sub(" ", _RX_RUTA.sub(" ", f)))
    for m in _RX_NUMERO.finditer(resto):
        out["numeros"].append(m.group(0).replace(",", "."))
    for m in _RX_SIGLA.finditer(resto):
        out["siglas"].append(plano(m.group(0)))
    for m in re.finditer(r"(?<=[a-záéíóúñ,;:] )([A-ZÁÉÍÓÚ][a-záéíóúñ]{3,})\b", resto):
        w = plano(m.group(1))
        if w not in _MAYUS_PERMITIDAS:
            out["propios"].append(w)
    pf = plano(resto)
    for w in re.findall(r"[a-z]+", pf):
        base = w
        if w not in _IMP_PLANOS:
            base = next((w[: -len(c)] for c in _CLITICOS if w.endswith(c) and w[: -len(c)] in _IMP_PLANOS), "")      # «envíame», «ábrelo»
        if base and _FAMILIA[base] not in _VERBOS_BLANDOS:
            out["verbos"].append(base)
    for m in _RX_MODAL.finditer(pf):
        if m.group(1) in _FAMILIA and _FAMILIA[m.group(1)] not in _VERBOS_BLANDOS:
            out["verbos"].append(m.group(1))
    return out


def _soporte_plano(textos: list[str]) -> tuple[str, set[str], set[str]]:
    plano_t = " ".join(plano(t) for t in textos if t)
    palabras = set(re.findall(r"[a-z0-9ñ]+", plano_t))
    return plano_t, palabras, {w[:5] for w in palabras if len(w) >= 5}


def _respaldado(valor: str, tipo: str, plano_t: str, palabras: set[str], stems: set[str]) -> bool:
    if not valor:
        return True
    if tipo == "numeros":
        return bool(re.search(rf"(?<![\w.,]){re.escape(valor)}(?![\w])", plano_t.replace(",", ".")))
    if tipo == "verbos":
        # cualquier forma de la misma familia en la fuente (abre ≈ abrir ≈ ábrelo; reinicia ≈ reiniciar ≈ reinicié)
        fam = _FAMILIA[valor]
        raiz = re.sub(r"(?:ar|er|ir)$", "", fam)
        return any(_FAMILIA.get(w) == fam or (len(raiz) >= 4 and w.startswith(raiz)) for w in palabras) or any(
            _FAMILIA.get(w[: -len(c)]) == fam for w in palabras for c in _CLITICOS if w.endswith(c))
    if tipo in ("teclas", "comandos", "rutas"):
        compacto = re.sub(r"\s+", "", plano_t)
        return re.sub(r"\s+", "", valor) in compacto
    if " " in valor:
        ws = [w for w in re.findall(r"[a-z0-9ñ]+", valor) if len(w) > 2]
        return all(w in palabras for w in ws) if ws else True
    return valor in palabras or valor in plano_t


# --- NLI (opcional) --------------------------------------------------------------------------------------------------
class NLI:
    """mDeBERTa-v3 xnli multilingüe en ONNX int8. Perezoso: no carga nada hasta la primera frase."""

    def __init__(self, carpeta: str = NLI_DIR, archivo: str = NLI_ARCHIVO):
        self.carpeta, self.archivo = carpeta, archivo
        self._s = self._tok = None
        self._intentado = False
        self._lock = threading.Lock()

    def disponible(self) -> bool:
        if not self._intentado:
            with self._lock:
                if not self._intentado:
                    self._intentado = True
                    try:
                        import onnxruntime as ort
                        from tokenizers import Tokenizer
                        ruta = os.path.join(self.carpeta, self.archivo)
                        if not os.path.exists(ruta):
                            raise FileNotFoundError(ruta)
                        self._tok = Tokenizer.from_file(os.path.join(self.carpeta, "tokenizer.json"))
                        self._tok.enable_truncation(512)
                        op = ort.SessionOptions()
                        op.intra_op_num_threads = int(os.environ.get("NLI_THREADS", "2"))
                        self._s = ort.InferenceSession(ruta, op, providers=["CPUExecutionProvider"])
                        self._entradas = {i.name for i in self._s.get_inputs()}
                    except Exception as e:  # noqa: BLE001
                        log.warning("NLI no disponible (%s): la verificación sigue con el backend local", e)
                        self._s = None
        return self._s is not None

    def probs(self, premisa: str, hipotesis: str) -> tuple[float, float, float] | None:
        """(implica, neutral, contradice) o None si no hay NLI."""
        if not self.disponible():
            return None
        e = self._tok.encode(premisa, hipotesis)
        feed = {"input_ids": np.array([e.ids], dtype=np.int64), "attention_mask": np.array([e.attention_mask], dtype=np.int64)}
        if "token_type_ids" in self._entradas:
            feed["token_type_ids"] = np.array([e.type_ids], dtype=np.int64)
        z = self._s.run(None, feed)[0][0]
        p = np.exp(z - z.max())
        p /= p.sum()
        return float(p[0]), float(p[1]), float(p[2])


class Lettuce:
    """LettuceDetect-es (KRLabsOrg/lettucedect-610m-eurobert-es-v1): marca TRAMOS de la respuesta sin respaldo en el contexto.
    Opcional y perezoso: necesita `pip install lettucedetect` y el modelo (2,4 GB). NO se baja en el build por defecto."""

    def __init__(self, modelo: str = os.environ.get("LETTUCE_MODEL", "KRLabsOrg/lettucedect-610m-eurobert-es-v1")):
        self.modelo = modelo
        self._d = None
        self._intentado = False

    def disponible(self) -> bool:
        if not self._intentado:
            self._intentado = True
            try:
                from lettucedetect.models.inference import HallucinationDetector
                self._d = HallucinationDetector(method="transformer", model_path=self.modelo, lang="es")
            except Exception as e:  # noqa: BLE001
                log.warning("LettuceDetect no disponible (%s)", e)
        return self._d is not None

    def tramos(self, contexto: list[str], pregunta: str, respuesta: str) -> list[dict]:
        if not self.disponible():
            return []
        try:
            return list(self._d.predict(context=contexto, question=pregunta, answer=respuesta, output_format="spans"))
        except Exception as e:  # noqa: BLE001
            log.warning("LettuceDetect falló: %s", e)
            return []


def motivo_de(sin: list, afirma: bool, nli, sim: float, tau_sim: float, tau_nli: float) -> str:
    """Por qué una frase no está respaldada ('' si lo está). Es la regla de decisión, aparte para poder calibrar los umbrales (evaluar_juez.py)."""
    if sin:
        return "dato sin respaldo: " + ", ".join(sin[:4])
    if afirma and nli is not None:
        if nli[0] < tau_nli and sim < 0.95:
            return f"el NLI no la implica ({nli[0]:.2f})" + (" y la contradice" if nli[2] >= 0.5 else "")
        return ""
    if afirma and sim < tau_sim:
        return f"afirma algo que no se parece a la fuente (similitud {sim:.2f})"
    return ""


# --- el verificador -------------------------------------------------------------------------------------------------
class Verificador:
    def __init__(self, emb, nli: NLI | None = None, lettuce: Lettuce | None = None):
        self.emb = emb
        self.nli = nli if nli is not None else (NLI() if USAR_NLI else None)
        self.lettuce = lettuce if lettuce is not None else (Lettuce() if USAR_LETTUCE else None)
        self._cache: dict[str, np.ndarray] = {}

    # pasajes de la fuente, ya embebidos (el artículo se repite turno a turno: se guarda)
    def _pasajes(self, fuentes: list[str]) -> tuple[list[str], np.ndarray]:
        frases = []
        for fu in fuentes:
            frases += dividir_frases(fu)
            frases.append(fu.strip()[:300]) if len(fu) < 300 else None
        frases = list(dict.fromkeys(f for f in frases if f))[:60]
        if not frases:
            return [], np.zeros((0, 384), dtype=np.float32)
        faltan = [f for f in frases if f not in self._cache]
        if faltan:
            for f, v in zip(faltan, self.emb.pasajes(faltan)):
                self._cache[f] = v
            if len(self._cache) > 4000:
                self._cache.clear()
                for f, v in zip(faltan, self.emb.pasajes(faltan)):
                    self._cache[f] = v
        return frases, np.vstack([self._cache[f] for f in frases])

    def puntuar(self, frases: list[str], fuentes: list[str], contexto: list[str] = ()) -> list[dict]:
        """El veredicto de cada frase: {texto, tipo, sim, datos_sin_respaldo, nli, respaldada, motivo}.

        Toda frase que no es una pregunta ni una cortesía EXPLÍCITA cuenta como una afirmación y se verifica (en la duda, se
        verifica). Una frase que repite lo que la persona escribió («Entiendo que tu Excel se cierra solo») es un eco: se parece
        mucho más al mensaje que a la fuente y no afirma nada nuevo."""
        pas, X = self._pasajes(fuentes)
        ctx, Xc = self._pasajes(list(contexto))
        plano_t, palabras, stems = _soporte_plano(list(fuentes) + list(contexto))
        stems_ctx = _soporte_plano(list(contexto))[2]
        Q = self.emb(frases) if frases else np.zeros((0, 384), dtype=np.float32)
        out = []
        for i, f in enumerate(frases):
            d = datos_en(f)
            sin = [f"{t}: {v}" for t, vs in d.items() for v in vs if not _respaldado(v, t, plano_t, palabras, stems)]
            sims = X @ Q[i] if len(pas) else np.zeros(0)
            simc = Xc @ Q[i] if len(ctx) else np.zeros(0)
            sim = float(sims.max()) if len(sims) else 0.0
            sim_ctx = float(simc.max()) if len(simc) else 0.0
            plano_f = plano(f)
            es_pregunta = "?" in f
            tiene_datos = any(d[t] for t in ("numeros", "comillas", "comandos", "rutas", "teclas", "menus", "verbos"))
            cortesia = bool(_RX_SOCIAL.match(plano_f)) and not tiene_datos and not _RX_AFIRMA.search(plano_f)
            cw = [w for w in _toks(f) if len(w) >= 4 and w not in _PARO]
            cobertura_ctx = (sum(1 for w in cw if w[:5] in stems_ctx) / len(cw)) if len(cw) >= 2 else 0.0
            eco = (not sin) and (sim_ctx >= TAU_ECO or cobertura_ctx >= 0.8) and sim_ctx >= sim - 0.03 and not _RX_AFIRMA.search(plano_f) \
                and not any(d[t] for t in ("comandos", "rutas", "teclas", "menus", "verbos"))
            afirma = not (es_pregunta or cortesia or eco)
            nli = None
            if self.nli is not None and afirma and (len(pas) or len(ctx)) and self.nli.disponible():
                pool = list(pas) + list(ctx)
                allsims = np.concatenate([sims, simc]) if len(ctx) else sims
                top = [pool[k] for k in np.argsort(-allsims)[:3]]
                nli = self.nli.probs(" ".join(top)[:1200], f)
            if _RX_PIDE_SECRETO.search(f):
                sin = sin + ["pide una contraseña"]
                afirma = True
            motivo = motivo_de(sin, afirma, nli, sim, TAU_SIM, TAU_NLI)
            out.append({"texto": f, "tipo": "pregunta" if es_pregunta else ("afirmacion" if afirma else ("eco" if eco else "cortesia")), "sim": round(sim, 3),
                        "datos_sin_respaldo": sin, "nli": None if nli is None else [round(x, 3) for x in nli], "afirma": afirma, "respaldada": not motivo, "motivo": motivo})
        return out

    def revisar(self, respuesta: str, fuentes: list[str], contexto: list[str] = (), pregunta: str = "", modo: str | None = None) -> dict:
        """Revisa un texto: quita las frases sin respaldo (en modo activo) y dice si contesta lo preguntado.
        Devuelve {texto, quitadas: [{texto, motivo}], frases: [...], contesta, regenerar, modo, ms}."""
        t0 = time.time()
        modo = (modo or MODO)
        if modo == "apagado" or not (respuesta or "").strip():
            return {"texto": respuesta, "quitadas": [], "frases": [], "contesta": None, "regenerar": False, "modo": "apagado", "ms": 0}
        frases = dividir_frases(respuesta)
        veredictos = self.puntuar(frases, fuentes, contexto)
        quitadas = [{"texto": v["texto"], "motivo": v["motivo"]} for v in veredictos if not v["respaldada"]]
        # LettuceDetect, si está activo: los tramos sin respaldo en la respuesta entera suman a las frases quitadas.
        if self.lettuce is not None and self.lettuce.disponible():
            for tr in self.lettuce.tramos(list(fuentes), pregunta, respuesta):
                txt = (tr.get("text") if isinstance(tr, dict) else "") or ""
                for v in veredictos:
                    if v["respaldada"] and txt and txt in v["texto"]:
                        v["respaldada"], v["motivo"] = False, "LettuceDetect marca un tramo sin respaldo"
                        quitadas.append({"texto": v["texto"], "motivo": v["motivo"]})
        quedan = [v["texto"] for v in veredictos if v["respaldada"]]
        texto = " ".join(quedan) if modo == "activo" else respuesta
        contest = self.contesta(pregunta, texto if modo == "activo" else respuesta) if pregunta else None
        return {"texto": texto, "quitadas": quitadas, "frases": veredictos, "contesta": contest, "regenerar": bool(quitadas) and modo == "activo",
                "modo": modo, "ms": int((time.time() - t0) * 1000)}

    # ¿Contestó lo preguntado? --------------------------------------------------------------------------------
    def contesta(self, pregunta: str, respuesta: str) -> float:
        """Puntaje 0..1 de que `respuesta` contesta `pregunta`: lo mayor entre la cobertura de las palabras de la pregunta y la
        similitud de embeddings reescalada. Con ≥ TAU_CONTESTA se da por contestada. (Reranker opcional: no se baja aquí.)"""
        if not (pregunta or "").strip() or not (respuesta or "").strip():
            return 0.0
        pt = [w for w in _toks(pregunta) if len(w) >= 4 and w not in _PARO]
        rt = _toks(respuesta)
        rs = {w[:5] for w in rt if len(w) >= 4}
        cobertura = (sum(1 for w in pt if w[:5] in rs) / len(pt)) if pt else 0.0
        v = self.emb([pregunta[:400], respuesta[:600]])
        sim = float(v[0] @ v[1])
        return round(max(cobertura, min(1.0, max(0.0, (sim - 0.76) / 0.18))), 3)


_PARO = set("""para como pero porque cuando donde desde hasta entre sobre tambien todo todos esta este estos estas esa ese esos esas aqui alla ahora
cada algo algun alguna alguno otro otra otros otras puedo puede pueden quiero quisiera necesito tengo tiene tienen hace hacer hacen favor hola buenas buenos
tardes dias noches muy mas menos poco mucho muchos tanto solo solamente ayuda ayudar""".split())
