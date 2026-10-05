// Formatos de Perú: hora de Lima en pantalla (la base guarda UTC), dd/mm/aaaa, plurales y vocabulario cerrado
// (CONTRATOS.md §3). Nunca se muestra un ISO crudo.

const TZ = "America/Lima";

const fHora = new Intl.DateTimeFormat("es-PE", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false });
const fFecha = new Intl.DateTimeFormat("es-PE", { timeZone: TZ, day: "2-digit", month: "2-digit", year: "numeric" });
const fPartes = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" });

const ms = (iso: string | number | Date): number => (typeof iso === "number" ? iso : new Date(iso).getTime());
const valido = (iso: string | number | Date | null | undefined): iso is string | number | Date =>
  iso !== null && iso !== undefined && iso !== "" && !Number.isNaN(ms(iso));

/** Día calendario en Lima (aaaa-mm-dd), para comparar «hoy» y «ayer». */
const dia = (t: number): string => fPartes.format(t);

export const hora = (iso: string | null | undefined): string => (valido(iso) ? fHora.format(ms(iso)) : "—");
export const fecha = (iso: string | null | undefined): string => (valido(iso) ? fFecha.format(ms(iso)) : "—");
export const fechaHora = (iso: string | null | undefined): string =>
  valido(iso) ? `${fFecha.format(ms(iso))} ${fHora.format(ms(iso))}` : "—";

/** «hace 12 min», «hace 3 h», «ayer, 17:40», «02/10/2026». */
export function relativo(iso: string | null | undefined, ahora: number = Date.now()): string {
  if (!valido(iso)) return "—";
  const t = ms(iso);
  const s = (ahora - t) / 1000;
  if (s < -60) return `${fecha(iso)} ${hora(iso)}`;
  if (s < 45) return "ahora";
  if (s < 3600) return `hace ${Math.max(1, Math.round(s / 60))} min`;
  if (dia(t) === dia(ahora)) return `hace ${Math.floor(s / 3600)} h`;
  if (dia(t) === dia(ahora - 86_400_000)) return `ayer, ${hora(iso)}`;
  return fecha(iso);
}

/** Encabezado de día en un hilo: «Hoy», «Ayer» o dd/mm/aaaa. */
export function diaHilo(iso: string, ahora: number = Date.now()): string {
  const t = ms(iso);
  if (dia(t) === dia(ahora)) return "Hoy";
  if (dia(t) === dia(ahora - 86_400_000)) return "Ayer";
  return fecha(iso);
}
export const mismoDia = (a: string, b: string): boolean => dia(ms(a)) === dia(ms(b));

export const plural = (n: number, uno: string, varios: string): string => `${n.toLocaleString("es-PE")} ${n === 1 ? uno : varios}`;

/** Minutos a «1 h 20 min», «45 min», «2 d 3 h». */
export function duracion(min: number | null | undefined): string {
  if (min === null || min === undefined || Number.isNaN(min)) return "—";
  const m = Math.round(Math.abs(min));
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 24) return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d} d ${h % 24} h` : `${d} d`;
}

export const numero = (n: number | null | undefined, dec = 0): string =>
  n === null || n === undefined || Number.isNaN(n)
    ? "—"
    : n.toLocaleString("es-PE", { minimumFractionDigits: dec, maximumFractionDigits: dec });

export const porcentaje = (n: number | null | undefined, dec = 0): string => (n === null || n === undefined ? "—" : `${numero(n, dec)} %`);

/** Confianza de 0 a 1 como «93 %». Un valor ausente (NULL en la base) se muestra «—», nunca «NaN %». */
export const confianzaPct = (c: number | null | undefined): string => (c === null || c === undefined || Number.isNaN(c) ? "—" : `${Math.round(c * 100)} %`);

/** Etiqueta legible de una clave de la ficha del caso (con tildes). Las claves que no están aquí salen con guiones bajos en espacios. */
const CLAVES_FICHA: Record<string, string> = {
  sintoma: "Síntoma",
  categoria: "Categoría",
  aplicacion: "Aplicación",
  mensaje_error: "Mensaje de error",
  desde: "Desde cuándo",
  desde_cuando: "Desde cuándo",
  equipo: "Equipo",
  sede: "Sede",
  piso: "Piso",
  area: "Área",
  afecta_a: "Afecta a",
  impacto: "Impacto",
  urgencia: "Urgencia",
  impresora: "Impresora",
  tipo_red: "Tipo de red",
  anexo: "Anexo",
  solicitud: "Qué solicita",
  caida: "Caída",
  pasos_probados: "Pasos probados",
  pregunta_pendiente: "Pregunta pendiente",
  pendiente: "Pendiente",
  intentos_guia: "Pasos de guía dados",
  articulos_mostrados: "Artículos mostrados",
  detalle: "Detalle",
};
export const claveFicha = (k: string): string => CLAVES_FICHA[k] ?? k.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());

/** Qué espera saber el asistente (`memoria.pendiente`), en palabras de una persona. */
const PENDIENTE_TEXTO: Record<string, string> = {
  que_pasa: "Qué le pasa",
  aplicacion: "En qué programa o sistema le pasa",
  mensaje_error: "Si le aparece un mensaje de error",
  desde: "Desde cuándo le pasa",
  equipo: "El código de su equipo",
  sede_piso: "En qué sede y piso está",
  piso: "En qué piso está",
  area: "De qué área es",
  afecta_otros: "Si le pasa a alguien más",
  imprime_otro: "Si otras personas pueden imprimir",
  impresora: "Qué impresora es",
  tipo_red: "Si está por WiFi o por cable",
  anexo: "El número de su anexo",
  que_solicita: "Qué necesita exactamente",
  resolvio: "Si quedó resuelto",
  puntaje: "Su calificación de la atención",
  ofrecer_tecnico: "Si quiere que un técnico la contacte",
};

const ORDEN_FICHA = ["sintoma", "aplicacion", "mensaje_error", "desde", "desde_cuando", "equipo", "sede", "piso", "area", "impacto", "urgencia", "impresora", "tipo_red", "anexo", "solicitud", "caida", "pasos_probados"];
const ESTRUCTURA = new Set(["etapa", "pendiente", "sabemos", "articulos_mostrados", "intentos_guia", "incidencia", "preguntado"]);

const vacio = (v: unknown): boolean => v === null || v === undefined || v === "" || (Array.isArray(v) && v.length === 0) || (typeof v === "object" && !Array.isArray(v) && Object.keys(v as object).length === 0);

function valorCampo(k: string, v: unknown): string {
  if (v === "desconocido") return "No sabe";
  if (v === "sin mensaje") return "Sin mensaje de error";
  if (typeof v === "string") {
    if (k === "impacto") return IMPACTO_TEXTO[v] ?? v;
    if (k === "urgencia") return URGENCIA_TEXTO[v] ?? v;
    if (k === "categoria") return CATEGORIA_TEXTO[v] ?? v;
  }
  return valorFicha(v);
}

export interface FilaFicha {
  clave: string;
  etiqueta: string;
  valor: string;
}

/** Aplana la memoria del caso para el panel «Memoria»: acepta la forma real del agente (`{sabemos:{…}, pendiente,
 *  articulos_mostrados, intentos_guia, …}`) y también una ficha plana. Lo que el caso ya sabe va primero, en el orden en que se
 *  pregunta; después lo que falta por saber (`pendiente`) y lo que pasó con la guía. */
export function filasFicha(memoria: Record<string, unknown> | null | undefined): FilaFicha[] {
  if (!memoria || typeof memoria !== "object") return [];
  const sab = memoria["sabemos"];
  const conEstructura = !!sab && typeof sab === "object" && !Array.isArray(sab);
  const origen: Record<string, unknown> = conEstructura ? (sab as Record<string, unknown>) : Object.fromEntries(Object.entries(memoria).filter(([k]) => !ESTRUCTURA.has(k)));
  const claves = Object.keys(origen).filter((k) => !vacio(origen[k]));
  claves.sort((a, b) => {
    const ia = ORDEN_FICHA.indexOf(a);
    const ib = ORDEN_FICHA.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
  });
  const filas: FilaFicha[] = claves.map((k) => ({ clave: k, etiqueta: claveFicha(k), valor: valorCampo(k, origen[k]) }));
  if (conEstructura) {
    if (typeof memoria["categoria"] === "string" && memoria["categoria"]) filas.push({ clave: "categoria", etiqueta: claveFicha("categoria"), valor: valorCampo("categoria", memoria["categoria"]) });
    const art = memoria["articulos_mostrados"];
    if (Array.isArray(art) && art.length) filas.push({ clave: "articulos_mostrados", etiqueta: claveFicha("articulos_mostrados"), valor: art.join(" · ") });
    const intentos = memoria["intentos_guia"];
    if (typeof intentos === "number" && intentos > 0) filas.push({ clave: "intentos_guia", etiqueta: claveFicha("intentos_guia"), valor: String(intentos) });
    const pend = memoria["pendiente"];
    if (typeof pend === "string" && pend) filas.push({ clave: "pendiente", etiqueta: claveFicha("pendiente"), valor: PENDIENTE_TEXTO[pend] ?? pend.replace(/_/g, " ") });
  }
  return filas;
}

/** Un valor de la ficha del caso (JSON libre) en una línea legible: listas con «·», objetos como «clave: valor». */
export function valorFicha(v: unknown): string {
  if (v === null || v === undefined || v === "") return "—";
  if (Array.isArray(v)) return v.map(valorFicha).join(" · ");
  if (typeof v === "object") return Object.entries(v as Record<string, unknown>).map(([k, x]) => `${k.replace(/_/g, " ")}: ${valorFicha(x)}`).join(" · ");
  if (typeof v === "boolean") return v ? "Sí" : "No";
  return String(v);
}

/** «0:40» desde minutos (para plazos de SLA). */
export const hmm = (min: number): string => {
  const m = Math.round(Math.abs(min));
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`;
};

const PARTICULAS = new Set(["de", "del", "la", "las", "los", "y", "e"]);
/** Iniciales para el avatar: primera palabra y último apellido que no sea partícula. «José Luis de la Cruz» → «JC». */
export function iniciales(nombre: string | null | undefined): string {
  // Solo palabras que empiezan con letra: «Sergio Alarcón (proveedor)» → «SA», no «S(».
  const t = (nombre ?? "").trim().split(/\s+/).filter((x) => /^\p{L}/u.test(x));
  if (!t.length) return "·";
  const primera = t[0][0] ?? "";
  const resto = t.slice(1).filter((x) => !PARTICULAS.has(x.toLowerCase()));
  const ultima = resto.length ? resto[resto.length - 1][0] : "";
  return (primera + ultima).toUpperCase();
}

/** Nombre corto para filas estrechas: primer nombre y primer apellido (el penúltimo término que no sea partícula).
 *  «María del Carmen Quispe Huamán» → «María Quispe»; «Juan Pérez de la Torre» → «Juan Pérez». */
export function nombreCorto(nombre: string | null | undefined): string {
  const t = (nombre ?? "").trim().split(/\s+/).filter(Boolean);
  if (t.length <= 2) return t.join(" ") || "Sin nombre";
  let i = t.length - 2;
  while (i > 1 && PARTICULAS.has(t[i].toLowerCase())) i--;
  return `${t[0]} ${t[i]}`;
}

// ---- Vocabulario cerrado (CONTRATOS.md §3) ---------------------------------------------------------------------

export const ESTADO_TEXTO: Record<string, string> = {
  nueva: "Nueva",
  asignada: "Asignada",
  en_curso: "En curso",
  espera_usuario: "Esperando a la persona",
  espera_tercero: "Esperando a un tercero",
  resuelta: "Resuelta",
  cerrada: "Cerrada",
  reabierta: "Reabierta",
};

export const PRIORIDAD_TEXTO: Record<string, string> = { P1: "Crítica", P2: "Alta", P3: "Media", P4: "Baja" };

export const CATEGORIA_TEXTO: Record<string, string> = {
  correo: "Correo",
  cuentas_accesos: "Cuentas y accesos",
  red_wifi: "Red y wifi",
  vpn: "VPN",
  impresoras: "Impresoras",
  equipo: "Equipos",
  software_oficina: "Software de oficina",
  sistema_interno: "Sistema interno",
  telefonia: "Telefonía",
  otro: "Otro",
};
export const CATEGORIAS = Object.keys(CATEGORIA_TEXTO);

export const INTENCION_TEXTO: Record<string, string> = {
  reportar_falla: "Reporta una falla",
  solicitar_acceso: "Pide un acceso",
  solicitar_equipo: "Pide un equipo",
  restablecer_clave: "Restablecer clave",
  consultar_estado: "Consulta el estado",
  aportar_dato: "Aporta un dato",
  confirmar_solucion: "Confirma la solución",
  sigue_igual: "Sigue igual",
  pedir_tecnico: "Pide un técnico",
  queja: "Queja",
  agradecer: "Agradece",
  saludo: "Saludo",
  fuera_de_alcance: "Fuera de alcance",
};
export const INTENCIONES = Object.keys(INTENCION_TEXTO);

export const ETAPA_TEXTO: Record<string, string> = {
  recepcion: "Recepción",
  diagnostico: "Diagnóstico",
  guia: "Guía",
  incidencia: "Incidencia",
  seguimiento: "Seguimiento",
  cierre: "Cierre",
  encuesta: "Encuesta",
  consulta_estado: "Consulta de estado",
};
export const ETAPAS = Object.keys(ETAPA_TEXTO);

export const ROL_TEXTO: Record<string, string> = {
  tecnico: "Técnico",
  supervisor: "Supervisor",
  gerencia: "Gerencia",
  entrenador: "Entrenador del asistente",
  admin: "Administrador",
};

export const CANAL_TEXTO: Record<string, string> = { whatsapp: "WhatsApp", web: "Chat web", correo: "Correo", manual: "Alta manual" };
export const IMPACTO_TEXTO: Record<string, string> = { persona: "Una persona", area: "Un área", sede: "Una sede", organizacion: "Toda la organización" };
export const URGENCIA_TEXTO: Record<string, string> = { baja: "Baja", media: "Media", alta: "Alta", critica: "Crítica" };
export const NIVEL_TEXTO: Record<string, string> = { N1: "Nivel 1", N2: "Nivel 2", N3: "Nivel 3" };
export const DIA_TEXTO = ["", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo"];

export const MOTIVO_COLA_TEXTO: Record<string, string> = {
  baja_confianza: "Baja confianza",
  pulgar_abajo: "Marcada con 👎",
  correccion_tecnico: "Corregida por un técnico",
  reapertura: "La incidencia se reabrió",
};

/** Frase para una fila del historial de una incidencia. */
export function textoEvento(e: { tipo: string; actor_tipo: string; actor_nombre?: string; datos: Record<string, unknown> }): string {
  const quien =
    e.actor_nombre ??
    (e.actor_tipo === "asistente" ? "El asistente" : e.actor_tipo === "sistema" ? "El sistema" : e.actor_tipo === "usuario" ? "La persona" : "Un técnico");
  const d = e.datos;
  const s = (k: string) => (typeof d[k] === "string" ? (d[k] as string) : "");
  switch (e.tipo) {
    case "creada":
      return `${quien} abrió la incidencia`;
    case "asignada":
      return `Asignada a ${s("tecnico") || "un técnico"}`;
    case "reasignada":
      return `Reasignada a ${s("tecnico") || "otro técnico"}`;
    case "primera_respuesta":
      return `${quien} dio la primera respuesta`;
    case "estado_cambiado":
      return `Estado: ${ESTADO_TEXTO[s("a")] ?? s("a")}`;
    case "pausa_inicio":
      return `Plazo en pausa${s("motivo") ? ` · ${ESTADO_TEXTO[s("motivo")] ?? s("motivo")}` : ""}`;
    case "pausa_fin":
      return "El plazo volvió a correr";
    case "comentario":
      return `${quien} respondió`;
    case "comentario_interno":
      return `${quien} dejó una nota interna`;
    case "escalada":
      return `Escalada${s("a") ? ` a ${s("a")}` : ""}${s("motivo") ? ` · ${s("motivo")}` : ""}`;
    case "aviso_sla":
      return `Aviso: el plazo va por el ${String(d["porcentaje"] ?? 75)} %`;
    case "prioridad_cambiada":
      return `Prioridad de ${s("de") || "—"} a ${s("a") || "—"}`;
    case "resuelta":
      return `${quien} la marcó como resuelta`;
    case "reabierta":
      return "La persona la reabrió";
    case "cerrada":
      return "Cerrada";
    case "dato_agregado":
      return `Dato nuevo: ${s("clave")} = ${s("valor")}`;
    default:
      return e.tipo.replace(/_/g, " ");
  }
}

// ---- Fechas de calendario en Lima (aaaa-mm-dd), para los selectores de periodo ---------------------------------

const fISO = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" });
export const hoyLima = (): string => fISO.format(Date.now());
/** Resta días a una fecha aaaa-mm-dd (en UTC, sin saltos por zona horaria). */
export const restarDias = (iso: string, dias: number): string => {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d - dias)).toISOString().slice(0, 10);
};
export const primeroDelMes = (iso: string): string => iso.slice(0, 8) + "01";
/** aaaa-mm-dd → dd/mm/aaaa */
export const fechaCorta = (iso: string | null | undefined): string => {
  if (!iso) return "—";
  const [y, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
};

/** Fecha futura para quien no es técnico: «hoy, 16:40», «mañana, 09:00» o dd/mm/aaaa hh:mm. */
export function momentoFuturo(iso: string | null | undefined, ahora: number = Date.now()): string {
  if (!valido(iso)) return "—";
  const t = ms(iso);
  if (dia(t) === dia(ahora)) return `hoy, ${hora(iso)}`;
  if (dia(t) === dia(ahora + 86_400_000)) return `mañana, ${hora(iso)}`;
  return `${fecha(iso)}, ${hora(iso)}`;
}
