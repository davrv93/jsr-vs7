#!/usr/bin/env node
// Servidor de pruebas de la consola de jsrbot: implementa la API de docs/CONTRATOS.md §2 con datos sintéticos, sin
// dependencias. Sirve para construir y probar la interfaz antes de que exista el backend real.
//
//   node mock/servidor.mjs                 → API en http://127.0.0.1:5599
//   SERVIR_DIST=1 node mock/servidor.mjs   → además sirve web/dist (lo que hace nginx: fallback de /estado/:token)
//
// Entradas: admin@jsr.test · tecnico@jsr.test · supervisor@jsr.test · gerencia@jsr.test · entrenador@jsr.test
// Clave de todos: jsr123.
//
// Control para pruebas (no existe en el backend real):
//   POST /mock/falla     {"ruta":"/api/bandeja","estado":500,"veces":1}   hace fallar la próxima petición
//   POST /mock/latencia  {"ms":3500}                                      retraso fijo para todas las respuestas
//   POST /mock/evento    {"evento":"incidencia_actualizada","id":142}     emite un evento SSE
//   POST /mock/clickhouse {"configurado":false}                           los indicadores salen sin cifra («ClickHouse no está configurado»)

import http from "node:http";
import { readFile, stat } from "node:fs/promises";
import { createHmac } from "node:crypto";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import * as D from "./datos.mjs";

const PUERTO = Number(process.env.PORT ?? 5599);
const HOST = process.env.HOST ?? "127.0.0.1";
const SECRETO = "mock-no-es-secreto";
const MIN = 60_000;
const AQUI = dirname(fileURLToPath(import.meta.url));
const DIST = process.env.DIST_DIR ? join(AQUI, "..", process.env.DIST_DIR) : join(AQUI, "..", "dist");
// Detrás de un alias de nginx (BASE_PATH=/jsrbot/): el proxy quita el prefijo antes de llegar aquí. STRIP_PREFIX=/jsrbot lo imita.
const PREFIJO = (process.env.STRIP_PREFIX ?? "").replace(/\/$/, "");
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

D.incidencias.forEach((i) => (i.ref_ts = D.AHORA0));
const extraEventos = new Map(); // incidencia.id → eventos añadidos por acciones
const control = { latencia: null, fallas: [], sinClickhouse: !!process.env.MOCK_SIN_CLICKHOUSE };
const sesionesChat = new Map();

// ---------------------------------------------------------------------------------------------------------------
// Utilidades
const norm = (s) => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
const ahoraISO = () => new Date().toISOString();

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
function firmar(payload) {
  const cab = b64({ alg: "HS256", typ: "JWT" });
  const cuerpo = b64(payload);
  const firma = createHmac("sha256", SECRETO).update(`${cab}.${cuerpo}`).digest("base64url");
  return `${cab}.${cuerpo}.${firma}`;
}
function verificar(token) {
  const [cab, cuerpo, firma] = String(token ?? "").split(".");
  if (!cab || !cuerpo || !firma) return null;
  const esperada = createHmac("sha256", SECRETO).update(`${cab}.${cuerpo}`).digest("base64url");
  if (esperada !== firma) return null;
  try {
    const p = JSON.parse(Buffer.from(cuerpo, "base64url").toString());
    return p.exp * 1000 > Date.now() ? p : null;
  } catch {
    return null;
  }
}

class HttpError extends Error {
  constructor(estado, mensaje, codigo) {
    super(mensaje);
    this.estado = estado;
    this.codigo = codigo;
  }
}
const prohibido = () => new HttpError(403, "Tu rol no tiene permiso para esto.", "no_autorizado");
const noEncontrado = (m = "No encontramos lo que buscabas.") => new HttpError(404, m, "no_encontrado");
const invalido = (m) => new HttpError(400, m, "invalido");

const RANGO = { tecnico: 1, supervisor: 2, gerencia: 3 };
// Rol mínimo según CONTRATOS.md §2. «entrenador» y «admin» son aparte; admin puede todo.
function exigir(u, req) {
  if (!u) throw new HttpError(401, "Tu sesión expiró. Vuelve a entrar.", "no_autorizado");
  if (u.rol === "admin") return;
  if (req === "entrenador") {
    if (u.rol !== "entrenador") throw prohibido();
    return;
  }
  if (req === "admin") throw prohibido();
  if (req === "conversaciones") {
    if (u.rol === "entrenador" || RANGO[u.rol] >= 1) return;
    throw prohibido();
  }
  if ((RANGO[u.rol] ?? 0) < RANGO[req]) throw prohibido();
}

// ---------------------------------------------------------------------------------------------------------------
// Proyecciones
function slaDe(inc) {
  if (inc.resuelta) return null;
  const restante = inc.pausado ? inc.restante_min : Math.round(inc.restante_min - (Date.now() - inc.ref_ts) / MIN);
  const pct = Math.max(0, Math.round(((inc.total_min - restante) / inc.total_min) * 1000) / 10);
  return { porcentaje: pct, restante_min: restante, vencida: restante < 0, pausado: inc.pausado };
}
const personaRef = (id) => {
  const p = D.personas.find((x) => x.id === id);
  return p ? { id: p.id, nombre: p.nombre, area: p.area, sede: p.sede } : null;
};
const tecnicoRef = (id) => {
  const t = D.tecnicos.find((x) => x.id === id);
  return t ? { id: t.id, nombre: t.nombre } : null;
};
function resumen(inc) {
  const sla = slaDe(inc);
  return {
    id: inc.id,
    numero: inc.numero,
    titulo: inc.titulo,
    prioridad: inc.prioridad,
    estado: inc.estado,
    categoria: inc.categoria,
    canal: inc.canal,
    persona: personaRef(inc.persona_id),
    tecnico: tecnicoRef(inc.tecnico_id),
    grupo: D.grupos.find((g) => g.id === inc.grupo_id)?.nombre ?? null,
    creada_en: inc.creada_en,
    actualizada_en: inc.actualizada_en,
    vence_resolucion_en: sla ? new Date(Date.now() + sla.restante_min * MIN).toISOString() : null,
    sla,
  };
}
const abierta = (i) => !["resuelta", "cerrada"].includes(i.estado);

function detalle(inc) {
  const persona = D.personas.find((p) => p.id === inc.persona_id);
  const ultUsuario = [...inc.mensajes].reverse().find((m) => m.rol === "usuario");
  const arts = D.articulos.filter((a) => a.categoria === inc.categoria && a.estado !== "archivado").slice(0, 3);
  return {
    ...resumen(inc),
    resumen: inc.resumen,
    tipo: inc.tipo,
    impacto: inc.impacto,
    urgencia: inc.urgencia,
    nivel: inc.nivel,
    reaperturas: inc.reaperturas,
    escalamientos: inc.escalamientos,
    token_publico: inc.token_publico,
    persona_detalle: persona
      ? { id: persona.id, nombre: persona.nombre, area: persona.area, sede: persona.sede, correo: persona.correo, whatsapp: persona.whatsapp, vip: persona.vip, equipos: persona.equipos }
      : null,
    eventos: [...D.eventosDe(inc), ...(extraEventos.get(inc.id) ?? [])].sort((a, b) => new Date(a.ts) - new Date(b.ts)),
    mensajes: { items: inc.mensajes, total: inc.mensajes.length },
    memoria: D.memoriaDe(inc),
    clasificacion: {
      intencion: ultUsuario?.meta?.intencion ?? "reportar_falla",
      confianza: Math.round((ultUsuario?.meta?.confianza ?? 0.93) * 100) / 100,
      categoria: inc.categoria,
      categoria_confianza: 0.88,
    },
    veredictos: [
      { ts: inc.creada_en, modo: "sombra", tipo: "clasificacion", veredicto: "coincide", confianza: 0.91, detalle: "Jev local coincide con el clasificador: reportar_falla." },
      { ts: inc.creada_en, modo: "sombra", tipo: "respaldo", veredicto: "respaldada", confianza: 0.94, detalle: "La respuesta del asistente está respaldada por el artículo KB." },
      { ts: inc.creada_en, modo: "sombra", tipo: "contesta", veredicto: "contesta_lo_preguntado", confianza: 0.86 },
    ],
    articulos: arts.map((a, i) => ({ clave: a.clave, titulo: a.titulo, resultado: i === 0 ? "sigue_igual" : null })),
    sugerencia: inc.sugerencia,
  };
}

function evento(inc, tipo, actor_tipo, actor_nombre, datos = {}) {
  const lista = extraEventos.get(inc.id) ?? [];
  lista.push({ id: Date.now() + lista.length, ts: ahoraISO(), tipo, actor_tipo, actor_nombre, datos });
  extraEventos.set(inc.id, lista);
  inc.actualizada_en = ahoraISO();
}

// ---------------------------------------------------------------------------------------------------------------
// SSE
const clientes = new Set();
function emitir(nombre, datos = {}) {
  const linea = `event: ${nombre}\ndata: ${JSON.stringify(datos)}\n\n`;
  for (const res of clientes) res.write(linea);
}
setInterval(() => {
  for (const res of clientes) res.write(": ping\n\n");
}, 20_000).unref();

// ---------------------------------------------------------------------------------------------------------------
// Lectura del cuerpo
async function cuerpo(req) {
  const trozos = [];
  for await (const t of req) trozos.push(t);
  if (!trozos.length) return {};
  try {
    return JSON.parse(Buffer.concat(trozos).toString("utf8"));
  } catch {
    throw invalido("El cuerpo de la petición no es JSON válido.");
  }
}
const pagina = (lista, q) => {
  const por = Math.min(200, Math.max(1, Number(q.get("por_pagina") ?? 50)));
  const pag = Math.max(1, Number(q.get("pagina") ?? 1));
  return { items: lista.slice((pag - 1) * por, pag * por), total: lista.length };
};

// ---------------------------------------------------------------------------------------------------------------
// Chat web de prueba: simula al asistente (etapa, ficha, clasificación, veredictos de Jev local, artículos).
function clasificar(msg, etapa) {
  const m = norm(msg);
  const p = (intencion, confianza, categoria = null) => ({ intencion, confianza, categoria, catConf: categoria ? 0.74 + (confianza - 0.5) * 0.4 : null });
  if (/sigue igual|sigue sin|no funciono|no sirvio|sigue fallando|igual que antes/.test(m)) return p("sigue_igual", 0.94);
  if (/si,? se resolvio|ya funciono|ya funcion|quedo ok|ya quedo|se arreglo|resuelto/.test(m)) return p(etapa === "guia" ? "confirmar_solucion" : "agradecer", 0.93);
  if (/gracias|muchas gracias/.test(m)) return p("agradecer", 0.9);
  if (/abrir incidencia|abre una incidencia|abre un ticket|creame un ticket/.test(m)) return p("pedir_tecnico", 0.95);
  if (/tecnico|humano|asesor|alguien de soporte|hablar con una persona/.test(m)) return p("pedir_tecnico", 0.92);
  if (/ticket|incidencia|inc-|como va|en que quedo|estado de mi/.test(m)) return p("consultar_estado", 0.9);
  if (/(contrasena|clave|password)/.test(m) && /(olvid|no entra|no me deja|bloque|restablec|cambiar|recuper)/.test(m)) return p("restablecer_clave", 0.9, "cuentas_accesos");
  if (/(acceso|permiso|carpeta)/.test(m)) return p("solicitar_acceso", 0.86, "cuentas_accesos");
  if (/(mouse|teclado|monitor|laptop nueva|solicito|necesito un)/.test(m)) return p("solicitar_equipo", 0.82, "equipo");
  if (/^(hola|buenas|buen dia|buenos dias|buenas tardes|hey)\b/.test(m) && m.length < 30) return p("saludo", 0.96);
  if (/correo|outlook|bandeja|buzon/.test(m)) return p("reportar_falla", 0.93, "correo");
  if (/impresora|imprim|toner/.test(m)) return p("reportar_falla", 0.93, "impresoras");
  if (/vpn/.test(m)) return p("reportar_falla", 0.91, "vpn");
  if (/wifi|internet|red |conexion/.test(m)) return p("reportar_falla", 0.88, "red_wifi");
  if (/excel|word|office|powerpoint/.test(m)) return p("reportar_falla", 0.87, "software_oficina");
  if (/factura|sistema|lento|se congela|error/.test(m)) return p("reportar_falla", 0.7, "sistema_interno");
  if (/pc-|laptop|equipo|desde (ayer|hoy|el lunes|esta)|piso|oficina/.test(m)) return p("aportar_dato", 0.78);
  return p("fuera_de_alcance", 0.38);
}

function crearIncidenciaDesdeChat(s, motivo) {
  const id = Math.max(...D.incidencias.map((i) => i.id)) + 1;
  const cat = s.memoria.categoria ?? "otro";
  const persona = D.personas[0];
  const sintoma = s.memoria.sintoma ?? "Reporte desde el chat web";
  const prioridad = cat === "red_wifi" && motivo === "p1" ? "P1" : "P3";
  const inc = {
    id,
    numero: "INC-" + String(id).padStart(6, "0"),
    titulo: sintoma.length > 90 ? sintoma.slice(0, 87) + "…" : sintoma[0].toUpperCase() + sintoma.slice(1),
    resumen: `La persona reporta: «${sintoma}». ${s.memoria.pasos_probados?.length ? "Ya probó: " + s.memoria.pasos_probados.join("; ") + "." : ""} ${s.memoria.equipo ? "Equipo " + s.memoria.equipo + "." : ""}`.trim(),
    tipo: "incidente",
    prioridad,
    estado: "nueva",
    categoria: cat,
    canal: "web",
    persona_id: persona.id,
    tecnico_id: null,
    grupo_id: null,
    impacto: "persona",
    urgencia: "media",
    nivel: "N1",
    reaperturas: 0,
    escalamientos: 0,
    token_publico: "w" + id.toString(16) + "y".repeat(30),
    creada_en: ahoraISO(),
    actualizada_en: ahoraISO(),
    total_min: 1440,
    restante_min: 1440,
    ref_ts: Date.now(),
    pausado: false,
    resuelta: false,
    mensajes: s.historial.map((h, i) => ({ id: 90000 + i, ts: h.ts, rol: h.rol, texto: h.texto })),
    sugerencia: null,
    p1: false,
  };
  D.incidencias.unshift(inc);
  emitir("incidencia_creada", { id: inc.id, numero: inc.numero });
  return inc;
}

// Lo que de verdad devuelve el agente en `juez.veredictos`: algunas claves son veredictos (con `confianza`) y otras, datos del turno (`rag`).
function veredictosReales(cl, orden) {
  return {
    clasificacion: { intent: cl.intencion, confianza: cl.confianza, ms: 41, fuente: "local", local: { intent: cl.intencion, confianza: cl.confianza }, usado: false },
    rag: { modo_bandido: false, orden_puro: orden, orden_bandido: orden },
    verificacion: { veredicto: "respaldada", confianza: 0.92, contesta: true, regenerada: false },
  };
}

const GUIA = {
  correo: ["Cierra Outlook por completo y ábrelo otra vez.", "Cierra sesión en Outlook y vuelve a entrar con tu usuario.", "Comprueba que tu buzón no esté lleno."],
  impresoras: ["Comprueba que la impresora esté encendida y con papel.", "Cancela los trabajos de la cola de impresión.", "Reinicia la impresora y vuelve a imprimir."],
  vpn: ["Comprueba que tengas internet sin la VPN.", "Cierra el cliente VPN y ábrelo de nuevo.", "Usa tu usuario completo, con el dominio."],
  red_wifi: ["Olvida la red y vuelve a conectarte.", "Acércate al punto de acceso más cercano.", "Prueba con el cable de red si tu equipo lo permite."],
  cuentas_accesos: ["Entra a la página de autoservicio de contraseñas.", "Elige «Olvidé mi contraseña» y sigue el enlace que llega a tu correo alterno."],
  software_oficina: ["Abre la aplicación en modo seguro.", "Desactiva los complementos y vuelve a abrir tu archivo."],
  sistema_interno: ["Prueba con otro navegador.", "Cierra sesión, borra la caché y vuelve a entrar."],
  equipo: ["Tu solicitud se registra con el nombre del equipo y el motivo; tu jefatura la aprueba y Almacén entrega en 3 días hábiles."],
};
const ARTICULO_DE = { correo: "KB-031", impresoras: "KB-044", vpn: "KB-052", red_wifi: "KB-060", cuentas_accesos: "KB-001", software_oficina: "KB-070", sistema_interno: "KB-090", equipo: "KB-081" };

async function turnoChat({ sesion, mensaje }) {
  if (!sesion || typeof mensaje !== "string" || !mensaje.trim()) throw invalido("Escribe un mensaje para empezar.");
  const t0 = Date.now();
  let s = sesionesChat.get(sesion);
  if (!s) {
    s = { etapa: "recepcion", memoria: { pasos_probados: [] }, historial: [], incidencia: null };
    sesionesChat.set(sesion, s);
  }
  const texto = mensaje.trim().slice(0, 1000);
  const cl = clasificar(texto, s.etapa);
  const oculta = /(clave|contrasena|password)\s*(es|:|=)?\s*\S{4,}/i.test(norm(texto)) && /(mi |la )(clave|contrasena|password) (es|:)/i.test(norm(texto));
  const guardar = oculta ? texto.replace(/((?:clave|contraseña|password)\s*(?:es|:|=)?\s*)\S+/i, "$1[oculto]") : texto;
  s.historial.push({ ts: ahoraISO(), rol: "usuario", texto: guardar });

  // Ficha del caso
  const eq = texto.match(/\b(pc|lap|nb)-[a-z0-9-]+/i);
  if (eq) s.memoria.equipo = eq[0].toUpperCase();
  const desde = texto.match(/desde (ayer|hoy|el lunes|el viernes|esta mañana|hace \w+ (?:días|dias|horas))/i);
  if (desde) s.memoria.desde_cuando = desde[1];
  const sede = D.SEDES.find((x) => norm(texto).includes(norm(x.replace("Sede ", ""))));
  if (sede) s.memoria.sede = sede;
  if (cl.categoria && cl.intencion === "reportar_falla") {
    s.memoria.categoria = cl.categoria;
    s.memoria.sintoma = s.memoria.sintoma ?? texto;
  }

  let parrafos = [];
  let botones = [];
  let etapa = s.etapa;
  let accion = { tipo: "ninguno" };
  let articulos = [];
  let juez = { modo: "sombra", veredictos: {} };
  let incidencia = null;
  const senales = { animo: /cansé|harto|molest|pésim|pesim|inaceptable|tercera vez/.test(norm(texto)) ? "molesto" : "neutro", queja: /queja|reclamo|inaceptable|pesimo/.test(norm(texto)), pide_tecnico: cl.intencion === "pedir_tecnico", contrasena_oculta: oculta };

  if (oculta) {
    parrafos = ["Por seguridad no necesito tu contraseña, y no la voy a guardar. Te recomiendo cambiarla cuando termines.", "Cuéntame qué pasó al intentar entrar y lo revisamos."];
    etapa = s.etapa === "recepcion" ? "diagnostico" : s.etapa;
  } else if (cl.intencion === "saludo") {
    parrafos = ["¡Hola! Soy el asistente de la mesa de ayuda.", "Cuéntame qué está pasando y lo revisamos juntos."];
    etapa = "recepcion";
  } else if (cl.intencion === "reportar_falla" || cl.intencion === "solicitar_acceso" || cl.intencion === "solicitar_equipo" || cl.intencion === "restablecer_clave") {
    if (!s.memoria.equipo && etapa === "recepcion" && cl.intencion === "reportar_falla") {
      parrafos = [`Entiendo, vamos a revisarlo. Para ayudarte mejor, ¿en qué equipo te pasa y desde cuándo?`];
      etapa = "diagnostico";
    } else {
      const cat = cl.categoria ?? s.memoria.categoria ?? "otro";
      const art = ARTICULO_DE[cat];
      const pasos = GUIA[cat] ?? ["Cuéntame un poco más para ayudarte."];
      parrafos = ["Gracias, con eso ya tengo lo necesario. Prueba lo siguiente:", pasos.map((x, i) => `${i + 1}. ${x}`).join("\n"), "¿Se resolvió?"];
      botones = ["Sí, se resolvió", "Sigue igual"];
      etapa = "guia";
      s.memoria.pasos_probados.push(...pasos.slice(0, 2));
      if (art) {
        const a = D.articulos.find((x) => x.clave === art);
        articulos = [{ clave: art, titulo: a?.titulo ?? art, fuente: "base de conocimiento" }];
        juez.veredictos = veredictosReales(cl, [art, "KB-032"]);
      }
    }
  } else if (cl.intencion === "aportar_dato") {
    if (s.etapa === "diagnostico" || s.etapa === "recepcion") {
      const cat = s.memoria.categoria ?? "otro";
      const pasos = GUIA[cat] ?? ["Reinicia el equipo y vuelve a intentarlo."];
      parrafos = ["Gracias por el dato. Prueba lo siguiente:", pasos.map((x, i) => `${i + 1}. ${x}`).join("\n"), "¿Se resolvió?"];
      botones = ["Sí, se resolvió", "Sigue igual"];
      etapa = "guia";
      if (ARTICULO_DE[cat]) articulos = [{ clave: ARTICULO_DE[cat], titulo: D.articulos.find((x) => x.clave === ARTICULO_DE[cat])?.titulo ?? "", fuente: "base de conocimiento" }];
      juez.veredictos = veredictosReales(cl, ARTICULO_DE[cat] ? [ARTICULO_DE[cat]] : []);
    } else {
      parrafos = ["Anotado, lo agrego a tu caso."];
      accion = { tipo: "agregar_dato", dato: { clave: "detalle", valor: texto.slice(0, 60) } };
    }
  } else if (cl.intencion === "confirmar_solucion") {
    parrafos = ["Me alegra que se haya resuelto.", "Si quieres, cuéntame cómo te atendimos: ¿del 1 al 5, qué nota nos pones?"];
    botones = ["5", "4", "3", "2", "1"];
    etapa = "encuesta";
    accion = { tipo: "confirmar_solucion" };
  } else if (cl.intencion === "agradecer") {
    parrafos = ["¡Con gusto! Si vuelve a pasar, aquí estoy."];
    etapa = "cierre";
  } else if (cl.intencion === "sigue_igual") {
    parrafos = ["Lamento que siga igual. Puedo abrir una incidencia con todo lo que me contaste, o pasarte con un técnico ahora."];
    botones = ["Abrir incidencia", "Hablar con un técnico"];
    etapa = "guia";
    accion = { tipo: "sigue_igual" };
  } else if (cl.intencion === "pedir_tecnico") {
    const inc = crearIncidenciaDesdeChat(s, "pidio_tecnico");
    s.incidencia = inc.numero;
    incidencia = { numero: inc.numero };
    parrafos = [`Listo, abrí la incidencia ${inc.numero} (prioridad ${inc.prioridad}).`, "El plazo de resolución es de 1 día laboral. Un técnico te escribirá por este mismo chat y te aviso de cada cambio."];
    etapa = "seguimiento";
    accion = { tipo: "crear_incidencia", numero: inc.numero, incidencia: { motivo: "pidio_tecnico", categoria: inc.categoria, titulo: inc.titulo } };
  } else if (cl.intencion === "consultar_estado") {
    const inc = D.incidencias.find((i) => i.persona_id === 1 && abierta(i));
    if (inc) {
      const sla = slaDe(inc);
      parrafos = [`Tu incidencia ${inc.numero} («${inc.titulo}») está ${inc.estado === "en_curso" ? "en curso" : inc.estado.replace("_", " ")}.`, `La atiende ${D.tecnicos.find((t) => t.id === inc.tecnico_id)?.nombre ?? "el equipo de soporte"}${sla ? ` y vence en ${Math.max(0, sla.restante_min)} min` : ""}.`];
      accion = { tipo: "consultar_estado", numero: inc.numero };
    } else parrafos = ["No veo incidencias abiertas a tu nombre."];
    etapa = "consulta_estado";
  } else {
    parrafos = ["No estoy seguro de haberte entendido. ¿Puedes contarme con otras palabras qué problema tienes?"];
    botones = ["Hablar con un técnico"];
    etapa = s.etapa === "recepcion" ? "recepcion" : s.etapa;
    juez.veredictos = { clasificacion: { intent: cl.intencion, confianza: cl.confianza, ms: 38, fuente: "local", local: { intent: cl.intencion, confianza: cl.confianza }, usado: false } };
  }

  s.etapa = etapa;
  const respuesta = parrafos.join("\n\n");
  // Forma real de la memoria (ARQUITECTURA §2.2): lo sabido va en `sabemos`; el resto la rodea.
  const { categoria: catMem, desde_cuando, pasos_probados, ...sab } = s.memoria;
  const memoriaReal = {
    etapa,
    pendiente: etapa === "diagnostico" ? "equipo" : etapa === "guia" ? "resolvio" : etapa === "encuesta" ? "puntaje" : null,
    categoria: catMem ?? null,
    sabemos: { ...sab, ...(desde_cuando ? { desde: desde_cuando } : {}), ...(pasos_probados?.length ? { pasos_probados: [...new Set(pasos_probados)] } : {}) },
    articulos_mostrados: articulos.map((x) => x.clave),
    intentos_guia: etapa === "guia" ? 1 : 0,
    incidencia: s.incidencia ?? null,
    preguntado: etapa === "recepcion" ? [] : ["que_pasa", "equipo"],
  };
  s.historial.push({ ts: ahoraISO(), rol: "asistente", texto: respuesta });
  await dormir(220 + Math.random() * 380);
  return {
    respuesta,
    mensajes: parrafos,
    botones,
    incidencia,
    analisis: {
      etapa,
      memoria: memoriaReal,
      intencion: cl.intencion,
      confianza: cl.confianza,
      categoria: cl.categoria ?? s.memoria.categoria ?? null,
      categoria_confianza: cl.catConf,
      accion,
      articulos_usados: articulos,
      senales,
      juez,
      latencia_ms: Date.now() - t0,
    },
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Indicadores y reportes
function indicadores(q) {
  if (control.sinClickhouse) {
    const hasta0 = q.get("hasta") ?? new Date().toISOString().slice(0, 10);
    const desde0 = q.get("desde") ?? new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
    return {
      desde: desde0,
      hasta: hasta0,
      kpis: D.KPIS.map((k) => ({ kpi: k.kpi, version: k.version, titulo: k.titulo, definicion: k.definicion, sql: "", unidad: "", meta: null, sentido: k.sentido, filas: [], valor: null, detalle: "ClickHouse no está configurado: las cifras no se pueden calcular todavía." })),
    };
  }
  const hasta = q.get("hasta") ? new Date(q.get("hasta")) : new Date();
  const desde = q.get("desde") ? new Date(q.get("desde")) : new Date(hasta.getTime() - 30 * 86400000);
  const dias = Math.max(1, Math.round((hasta - desde) / 86400000));
  const n = Math.min(12, Math.max(1, Math.round(dias / 7)));
  const kpis = D.KPIS.map((k) => {
    const filas = k.valores.map((v, i) => ({ periodo: k.semanas[i], valor: v }));
    const ult = k.valores.slice(-n);
    const valor = k.unidad === "incidencias" ? ult[ult.length - 1] : Math.round((ult.reduce((a, b) => a + b, 0) / ult.length) * 10) / 10;
    const pide = k.kpi === "pendientes_antiguedad" && valor > k.meta * 2;
    return {
      kpi: k.kpi,
      version: k.version,
      titulo: k.titulo,
      definicion: k.definicion,
      sql: k.sql,
      unidad: k.unidad,
      valor,
      meta: k.meta,
      sentido: k.sentido,
      filas,
      pide_accion: pide,
      detalle: pide ? `${valor} incidencias llevan más de 7 días abiertas; 6 son de Redes y telecomunicaciones.` : undefined,
    };
  });
  return { desde: desde.toISOString().slice(0, 10), hasta: hasta.toISOString().slice(0, 10), kpis };
}

function preguntar(pregunta) {
  const m = norm(pregunta);
  if (!m.trim()) throw invalido("Escribe una pregunta.");
  if (/mttr|resolucion|tiempo de resolucion/.test(m)) {
    return {
      pregunta,
      golden: { kpi: "mttr_por_categoria", nombre: "MTTR por categoría", version: 3 },
      verificado: true,
      sql: "SELECT categoria, round(avg(mttr_min) / 60, 1) AS horas\nFROM incidencias_tiempos FINAL\nWHERE resuelta_en BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY categoria ORDER BY horas DESC",
      resumen: "Las incidencias de sistema interno son las que más tardan: 14,2 h. Impresoras y correo están por debajo de la meta de 8 h.",
      unidad: "h",
      columnas: ["Categoría", "Horas (MTTR)"],
      filas: [["Sistema interno", 14.2], ["Red y wifi", 10.4], ["VPN", 9.1], ["Equipos", 8.8], ["Correo", 6.9], ["Impresoras", 5.7]],
    };
  }
  if (/sla|plazo|cumpl/.test(m)) {
    return {
      pregunta,
      golden: { kpi: "sla_cumplimiento", nombre: "Cumplimiento de SLA", version: 3 },
      verificado: true,
      sql: "SELECT grupo, round(100 * avg(sla_resolucion_ok), 1) AS cumplimiento\nFROM incidencias_tiempos FINAL\nWHERE resuelta_en BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY grupo ORDER BY cumplimiento",
      resumen: "Se cumple la meta de 90 % en la mesa de ayuda N1; Redes y telecomunicaciones queda 4 puntos por debajo.",
      unidad: "%",
      columnas: ["Grupo", "Cumplimiento (%)"],
      filas: [["Redes y telecomunicaciones", 86.1], ["Sistemas internos", 90.5], ["Mesa de ayuda N1", 93.7]],
    };
  }
  if (/contencion|asistente resolvi|sin abrir incidencia/.test(m)) {
    return {
      pregunta,
      golden: { kpi: "contencion_asistente", nombre: "Contención del asistente", version: 2 },
      verificado: true,
      sql: "SELECT toStartOfMonth(inicio) AS mes,\n       round(100 * countIf(NOT tiene_incidencia AND confirmado_resuelto) / count(), 1) AS contencion\nFROM casos_estado FINAL\nGROUP BY mes ORDER BY mes DESC LIMIT 6",
      resumen: "El asistente resolvió por sí solo el 51 % de los casos de octubre, 6 puntos más que en mayo.",
      unidad: "%",
      columnas: ["Mes", "Contención (%)"],
      filas: [["Octubre 2026", 51.0], ["Setiembre 2026", 49.2], ["Agosto 2026", 47.5], ["Julio 2026", 46.1], ["Junio 2026", 45.3], ["Mayo 2026", 45.0]],
    };
  }
  if (/pendiente|antiguedad|mas de 7 dias/.test(m)) {
    return {
      pregunta,
      golden: { kpi: "pendientes_antiguedad", nombre: "Pendientes con más de 7 días", version: 2 },
      verificado: true,
      sql: "SELECT tecnico, count() AS pendientes\nFROM incidencias_abiertas_diarias\nWHERE snapshot = today() AND dias_abierta > 7\nGROUP BY tecnico ORDER BY pendientes DESC",
      resumen: "Hay 14 incidencias abiertas con más de 7 días; 6 son de Andrea Cárdenas Flores, que está al tope de su carga.",
      unidad: "incidencias",
      columnas: ["Técnico", "Pendientes"],
      filas: [["Andrea Cárdenas Flores", 6], ["Rodrigo Echevarría Lazo", 4], ["Javier Palomino Ccori", 2], ["Sin asignar", 2]],
    };
  }
  if (/csat|satisfaccion|encuesta/.test(m)) {
    return {
      pregunta,
      golden: { kpi: "csat", nombre: "Satisfacción (CSAT)", version: 1 },
      verificado: true,
      sql: "SELECT tecnico, round(avg(puntaje), 2) AS csat, count() AS encuestas\nFROM encuestas e JOIN incidencias_estado i USING (incidencia_id)\nGROUP BY tecnico ORDER BY csat DESC",
      resumen: "La satisfacción promedio es 4.4 sobre 5. Karina Soto Ramírez lidera con 4.8; hay pocas encuestas de Edith Mamani Quispe para sacar conclusiones.",
      unidad: "/ 5",
      columnas: ["Técnico", "CSAT", "Encuestas"],
      filas: [["Karina Soto Ramírez", 4.8, 31], ["Luis Paz Medina", 4.5, 28], ["Rodrigo Echevarría Lazo", 4.4, 40], ["Miguel Ángel Torres Delgado", 4.1, 22], ["Edith Mamani Quispe", 5, 2]],
    };
  }
  if (/reabr|reapertura/.test(m)) {
    return {
      pregunta,
      golden: null,
      verificado: false,
      sql: "SELECT categoria, count() AS reabiertas\nFROM incidencias_estado FINAL\nWHERE reaperturas > 0 AND creada_en >= today() - 90\nGROUP BY categoria ORDER BY reabiertas DESC LIMIT 20",
      resumen: "Hay 11 incidencias reabiertas en los últimos 90 días; correo y sistema interno concentran la mitad.",
      columnas: ["Categoría", "Reabiertas"],
      filas: [["Correo", 4], ["Sistema interno", 3], ["Impresoras", 2], ["VPN", 2]],
      nota: "Esta consulta no es una golden query: no la uses como cifra oficial hasta que Datos la verifique.",
    };
  }
  return {
    pregunta,
    golden: null,
    verificado: false,
    sql: "SELECT categoria, count() AS total\nFROM incidencias_estado FINAL\nWHERE creada_en >= today() - 30\nGROUP BY categoria ORDER BY total DESC LIMIT 20",
    resumen: "No encontré un reporte verificado para esa pregunta. Te muestro las incidencias de los últimos 30 días por categoría.",
    columnas: ["Categoría", "Incidencias"],
    filas: [["Correo", 31], ["Cuentas y accesos", 24], ["Impresoras", 19], ["Equipos", 17], ["Red y wifi", 12]],
    nota: "Sin verificar: el SQL lo propuso el analista. Revísalo antes de usarlo como cifra oficial.",
  };
}

// Entrenamiento: «Reentrenar» tarda unos segundos y devuelve un candidato. El primero mejora; el siguiente empeora, para
// poder ver los dos desenlaces (Publicar activo o bloqueado).
const entrenamiento = { fase: "ninguno", candidato: null, intentos: 0, inicio: 0 };
const modeloPublicado = () => D.modelos.find((m) => m.estado === "publicado");
const estadoEntrenamiento = () => {
  if (entrenamiento.fase === "entrenando" && Date.now() - entrenamiento.inicio > 4200) {
    const pub = modeloPublicado();
    const delta = entrenamiento.intentos % 2 === 1 ? 0.013 : -0.007;
    entrenamiento.candidato = { version: "v1.4", exactitud: Math.round((pub.exactitud + delta) * 1000) / 1000, macro_f1: Math.round((pub.macro_f1 + delta * 1.1) * 1000) / 1000, estado: "candidato", creado_en: ahoraISO(), ejemplos: pub.ejemplos + 61 };
    entrenamiento.fase = "listo";
  }
  const revisadas = D.cola.filter((c) => c.estado === "confirmada" || c.estado === "corregida").length;
  return {
    publicado: modeloPublicado(),
    candidato: entrenamiento.candidato,
    fase: entrenamiento.fase,
    cambios_pendientes: revisadas - (entrenamiento.revisadasAlEntrenar ?? 0),
    progreso: entrenamiento.fase === "entrenando" ? Math.min(0.95, (Date.now() - entrenamiento.inicio) / 4400) : undefined,
  };
};

// ---------------------------------------------------------------------------------------------------------------
// Rutas
const rutas = [];
const ruta = (metodo, patron, manejador) => rutas.push({ metodo, re: new RegExp("^" + patron.replace(/:(\w+)/g, "(?<$1>[^/]+)") + "$"), manejador });

ruta("GET", "/api/salud", () => ({ ok: true, db: "mock", agente: "mock", version: "mock-1" }));

ruta("POST", "/api/auth/login", async ({ body }) => {
  const u = D.usuarios.find((x) => x.email === String(body.email ?? "").trim().toLowerCase());
  if (!u || !u.activo || u.clave !== body.clave) throw new HttpError(401, "El correo o la clave no coinciden. Revísalos e inténtalo de nuevo.", "no_autorizado");
  const usuario = { id: u.id, nombre: u.nombre, rol: u.rol, tecnico_id: u.tecnico_id };
  return { token: firmar({ sub: u.id, rol: u.rol, exp: Math.floor(Date.now() / 1000) + 12 * 3600 }), usuario };
});
ruta("GET", "/api/yo", ({ u }) => {
  if (!u) throw new HttpError(401, "Tu sesión expiró. Vuelve a entrar.", "no_autorizado");
  return { id: u.id, nombre: u.nombre, rol: u.rol, tecnico_id: u.tecnico_id };
});

// Bandeja ----------------------------------------------------------------------------------------------------
ruta("GET", "/api/bandeja", ({ u }) => {
  exigir(u, "tecnico");
  const yo = u.tecnico_id;
  const miGrupo = D.grupos.find((g) => g.miembros.includes(yo))?.id;
  const verTodo = u.rol === "supervisor" || u.rol === "admin" || u.rol === "gerencia";
  const abiertas = D.incidencias.filter(abierta);
  const porPlazo = (a, b) => (slaDe(a)?.restante_min ?? 1e9) - (slaDe(b)?.restante_min ?? 1e9);
  const vencen = abiertas
    .filter((i) => {
      const s = slaDe(i);
      return s && !s.pausado && s.porcentaje >= 75 && (verTodo || i.tecnico_id === yo || i.grupo_id === miGrupo);
    })
    .sort(porPlazo);
  const ids = new Set(vencen.map((i) => i.id));
  const mias = abiertas.filter((i) => i.tecnico_id === yo && !ids.has(i.id)).sort(porPlazo);
  const nivel1 = D.tecnicos.find((t) => t.id === yo)?.nivel === "N1";
  const sin = verTodo || nivel1 ? abiertas.filter((i) => !i.tecnico_id).sort(porPlazo) : [];
  const espera = abiertas.filter((i) => i.estado === "espera_usuario" && (verTodo || i.tecnico_id === yo));
  const desde = espera.map((i) => i.actualizada_en).sort()[0] ?? null;
  return {
    vencen_pronto: vencen.map(resumen),
    mias: mias.map(resumen),
    sin_asignar: sin.map(resumen),
    contador: vencen.length,
    espera_usuario: { cantidad: espera.length, desde },
  };
});

// Incidencias ------------------------------------------------------------------------------------------------
ruta("GET", "/api/incidencias", ({ u, q }) => {
  exigir(u, "tecnico");
  const estado = q.get("estado");
  const prio = q.get("prioridad");
  const tec = q.get("tecnico_id");
  const grp = q.get("grupo_id");
  const cat = q.get("categoria");
  const bus = norm(q.get("q") ?? "");
  let l = D.incidencias.slice();
  if (q.get("abiertas") === "1") l = l.filter(abierta);
  if (estado) l = l.filter((i) => i.estado === estado);
  if (prio) l = l.filter((i) => i.prioridad === prio);
  if (tec === "sin") l = l.filter((i) => !i.tecnico_id);
  else if (tec) l = l.filter((i) => i.tecnico_id === Number(tec));
  if (grp) l = l.filter((i) => i.grupo_id === Number(grp));
  if (cat) l = l.filter((i) => i.categoria === cat);
  if (bus) l = l.filter((i) => norm(`${i.numero} ${i.titulo} ${D.personas.find((p) => p.id === i.persona_id)?.nombre}`).includes(bus));
  l.sort((a, b) => new Date(b.creada_en) - new Date(a.creada_en));
  const p = pagina(l, q);
  return { items: p.items.map(resumen), total: p.total };
});
ruta("POST", "/api/incidencias", ({ u, body }) => {
  exigir(u, "tecnico");
  if (!String(body.titulo ?? "").trim()) throw invalido("Falta el asunto de la incidencia.");
  const id = Math.max(...D.incidencias.map((i) => i.id)) + 1;
  const persona = D.personas.find((p) => p.id === Number(body.persona_id)) ?? D.personas[0];
  const prioridad = body.prioridad ?? "P3";
  const inc = {
    id, numero: "INC-" + String(id).padStart(6, "0"), titulo: String(body.titulo).trim(), resumen: String(body.resumen ?? ""), tipo: "incidente", prioridad, estado: "nueva",
    categoria: body.categoria ?? "otro", canal: "manual", persona_id: persona.id, tecnico_id: null, grupo_id: null, impacto: "persona", urgencia: "media", nivel: "N1",
    reaperturas: 0, escalamientos: 0, token_publico: "m" + id.toString(16) + "z".repeat(30), creada_en: ahoraISO(), actualizada_en: ahoraISO(),
    total_min: { P1: 120, P2: 480, P3: 1440, P4: 2880 }[prioridad], restante_min: { P1: 120, P2: 480, P3: 1440, P4: 2880 }[prioridad], ref_ts: Date.now(), pausado: false, resuelta: false, mensajes: [], sugerencia: null, p1: false,
  };
  D.incidencias.unshift(inc);
  emitir("incidencia_creada", { id });
  return detalle(inc);
});
ruta("GET", "/api/incidencias/:id", ({ u, params }) => {
  exigir(u, "tecnico");
  const inc = D.incidencias.find((i) => i.id === Number(params.id));
  if (!inc) throw noEncontrado("No encontramos esa incidencia. Puede que ya no exista.");
  return detalle(inc);
});
ruta("POST", "/api/incidencias/:id/acciones", ({ u, params, body }) => {
  exigir(u, "tecnico");
  const inc = D.incidencias.find((i) => i.id === Number(params.id));
  if (!inc) throw noEncontrado("No encontramos esa incidencia. Puede que ya no exista.");
  const yo = D.tecnicos.find((t) => t.id === u.tecnico_id);
  const actual = slaDe(inc);
  switch (body.accion) {
    case "asignar": {
      const t = D.tecnicos.find((x) => x.id === Number(body.tecnico_id ?? u.tecnico_id));
      if (!t) throw invalido("Elige a quién asignar la incidencia.");
      inc.tecnico_id = t.id;
      inc.grupo_id = D.grupos.find((g) => g.miembros.includes(t.id))?.id ?? inc.grupo_id;
      if (inc.estado === "nueva") inc.estado = "asignada";
      evento(inc, inc.escalamientos && body.tecnico_id ? "reasignada" : "asignada", "tecnico", yo?.nombre, { tecnico: t.nombre });
      break;
    }
    case "responder":
    case "comentario_interno": {
      const texto = String(body.texto ?? "").trim();
      if (!texto) throw invalido("Escribe el mensaje antes de enviarlo.");
      const interno = body.accion === "comentario_interno" || body.interno === true;
      inc.mensajes.push({ id: Date.now(), ts: ahoraISO(), rol: "tecnico", autor: yo?.nombre ?? u.nombre, texto, interno });
      if (!interno) {
        if (["nueva", "asignada", "reabierta"].includes(inc.estado)) inc.estado = "en_curso";
        if (!inc.tecnico_id && yo) inc.tecnico_id = yo.id;
        inc.sugerencia = null;
      }
      evento(inc, interno ? "comentario_interno" : "comentario", "tecnico", yo?.nombre ?? u.nombre);
      emitir("mensaje", { id: inc.id });
      break;
    }
    case "pausar": {
      if (!["espera_usuario", "espera_tercero"].includes(body.motivo)) throw invalido("Elige por qué se pausa: espera a la persona o a un tercero.");
      inc.restante_min = actual?.restante_min ?? inc.restante_min;
      inc.pausado = true;
      inc.estado = body.motivo;
      evento(inc, "pausa_inicio", "tecnico", yo?.nombre, { motivo: body.motivo });
      break;
    }
    case "reanudar":
      inc.restante_min = actual?.restante_min ?? inc.restante_min;
      inc.ref_ts = Date.now();
      inc.pausado = false;
      inc.estado = "en_curso";
      evento(inc, "pausa_fin", "tecnico", yo?.nombre);
      break;
    case "resolver":
      inc.estado = "resuelta";
      inc.resuelta = true;
      evento(inc, "resuelta", "tecnico", yo?.nombre, { nota: body.nota ?? "" });
      break;
    case "reabrir":
      inc.estado = "reabierta";
      inc.resuelta = false;
      inc.reaperturas++;
      inc.restante_min = Math.round(inc.total_min * 0.4);
      inc.ref_ts = Date.now();
      inc.pausado = false;
      evento(inc, "reabierta", "tecnico", yo?.nombre);
      break;
    case "cerrar":
      inc.estado = "cerrada";
      inc.resuelta = true;
      evento(inc, "cerrada", "tecnico", yo?.nombre);
      break;
    case "escalar": {
      const g = D.grupos.find((x) => x.id === Number(body.grupo_id)) ?? D.grupos.find((x) => x.id === D.grupos.find((y) => y.id === inc.grupo_id)?.escala_a_grupo_id) ?? D.grupos[1];
      inc.grupo_id = g.id;
      inc.nivel = g.nivel;
      inc.tecnico_id = g.miembros[0] ?? null;
      inc.escalamientos++;
      inc.estado = inc.tecnico_id ? "asignada" : "nueva";
      evento(inc, "escalada", "tecnico", yo?.nombre, { a: g.nombre, motivo: body.motivo ?? "" });
      break;
    }
    case "cambiar_prioridad": {
      if (!["P1", "P2", "P3", "P4"].includes(body.prioridad)) throw invalido("Elige una prioridad entre P1 y P4.");
      evento(inc, "prioridad_cambiada", "tecnico", yo?.nombre, { de: inc.prioridad, a: body.prioridad });
      inc.prioridad = body.prioridad;
      break;
    }
    default:
      throw invalido("Esa acción no existe.");
  }
  emitir("incidencia_actualizada", { id: inc.id, numero: inc.numero });
  return detalle(inc);
});

// Conversaciones ---------------------------------------------------------------------------------------------
ruta("GET", "/api/casos", ({ u, q }) => {
  exigir(u, "conversaciones");
  const estado = q.get("estado");
  let l = D.casos.slice().sort((a, b) => new Date(b.ultimo_mensaje) - new Date(a.ultimo_mensaje));
  if (estado) l = l.filter((c) => c.estado === estado);
  const p = pagina(l, q);
  return { items: p.items.map(({ mensajes, persona_id, ...c }) => ({ ...c, persona: personaRef(persona_id), mensajes_total: mensajes.length })), total: p.total };
});
ruta("GET", "/api/casos/:id/mensajes", ({ u, params }) => {
  exigir(u, "conversaciones");
  const c = D.casos.find((x) => x.id === Number(params.id));
  if (!c) throw noEncontrado("No encontramos esa conversación.");
  const { mensajes, persona_id, ...caso } = c;
  return { caso: { ...caso, persona: personaRef(persona_id), mensajes_total: mensajes.length }, items: mensajes, total: mensajes.length };
});
ruta("POST", "/api/casos/:id/tomar", ({ u, params }) => {
  exigir(u, "tecnico");
  const c = D.casos.find((x) => x.id === Number(params.id));
  if (!c) throw noEncontrado("No encontramos esa conversación.");
  c.pausado_por_tecnico = true;
  c.tomado_por = u.nombre;
  emitir("mensaje", { caso_id: c.id });
  const { mensajes, persona_id, ...caso } = c;
  return { ...caso, persona: personaRef(persona_id), mensajes_total: mensajes.length };
});
ruta("POST", "/api/casos/:id/devolver", ({ u, params }) => {
  exigir(u, "tecnico");
  const c = D.casos.find((x) => x.id === Number(params.id));
  if (!c) throw noEncontrado("No encontramos esa conversación.");
  c.pausado_por_tecnico = false;
  c.tomado_por = null;
  emitir("mensaje", { caso_id: c.id });
  const { mensajes, persona_id, ...caso } = c;
  return { ...caso, persona: personaRef(persona_id), mensajes_total: mensajes.length };
});
ruta("POST", "/api/casos/:id/mensajes", ({ u, params, body }) => {
  exigir(u, "tecnico");
  const c = D.casos.find((x) => x.id === Number(params.id));
  if (!c) throw noEncontrado("No encontramos esa conversación.");
  if (!c.pausado_por_tecnico) throw new HttpError(409, "Toma la conversación antes de escribir: así el asistente deja de contestar.", "conflicto");
  const texto = String(body.texto ?? "").trim();
  if (!texto) throw invalido("Escribe el mensaje antes de enviarlo.");
  c.mensajes.push({ id: Date.now(), ts: ahoraISO(), rol: "tecnico", autor: u.nombre, texto });
  c.ultimo_mensaje = ahoraISO();
  c.ultimo_texto = texto;
  emitir("mensaje", { caso_id: c.id });
  return { ok: true };
});

// Equipo ------------------------------------------------------------------------------------------------------
const cargaDe = (id) => D.incidencias.filter((i) => i.tecnico_id === id && abierta(i)).length;
function tecnicoOut(t) {
  const hab = Object.entries(t.hab ?? {}).map(([categoria, nivel]) => ({ categoria, nivel }));
  const resueltas = D.incidencias.filter((i) => i.tecnico_id === t.id && i.resuelta).length;
  return {
    id: t.id, nombre: t.nombre, nivel: t.nivel, estado: t.estado, capacidad: t.capacidad, carga: cargaDe(t.id), correo: t.correo ?? undefined, whatsapp: t.whatsapp ?? undefined, foto: t.foto,
    grupos: D.grupos.filter((g) => g.miembros.includes(t.id)).map((g) => ({ id: g.id, nombre: g.nombre })),
    habilidades: hab, turnos: t.turnos, ausencia: t.ausencia ?? null,
    rendimiento: { resueltas_30d: resueltas * 3 + (t.id % 4), sla_cumplido_pct: t.turnos.length ? 84 + ((t.id * 7) % 14) : null, primera_respuesta_mediana_min: t.turnos.length ? 12 + ((t.id * 5) % 20) : null },
  };
}
ruta("GET", "/api/tecnicos", ({ u, q }) => {
  exigir(u, "supervisor");
  const l = D.tecnicos.map(tecnicoOut);
  const p = pagina(l, q);
  return p;
});
ruta("GET", "/api/tecnicos/:id", ({ u, params }) => {
  exigir(u, "supervisor");
  const t = D.tecnicos.find((x) => x.id === Number(params.id));
  if (!t) throw noEncontrado("No encontramos a esa persona.");
  return tecnicoOut(t);
});
function validarTecnico(b, nuevo) {
  if (nuevo || "nombre" in b) if (!String(b.nombre ?? "").trim()) throw invalido("Falta el nombre del técnico.");
  if (b.whatsapp && !/^\d{9,15}$/.test(String(b.whatsapp))) throw invalido("El WhatsApp va solo con dígitos y el prefijo del país, por ejemplo 51987654321.");
  if (b.correo && !/^\S+@\S+\.\S+$/.test(String(b.correo))) throw invalido("Ese correo no parece válido.");
  if (b.capacidad !== undefined && !(Number(b.capacidad) >= 1 && Number(b.capacidad) <= 50)) throw invalido("La capacidad debe estar entre 1 y 50 incidencias.");
}
ruta("POST", "/api/tecnicos", ({ u, body }) => {
  exigir(u, "supervisor");
  validarTecnico(body, true);
  const t = { id: Math.max(...D.tecnicos.map((x) => x.id)) + 1, nombre: String(body.nombre).trim(), nivel: body.nivel ?? "N1", estado: "activo", capacidad: Number(body.capacidad ?? 8), correo: body.correo || null, whatsapp: body.whatsapp || null, foto: null, turnos: [], hab: {} };
  D.tecnicos.push(t);
  if (body.grupo_id) D.grupos.find((g) => g.id === Number(body.grupo_id))?.miembros.push(t.id);
  emitir("incidencia_actualizada", {});
  return tecnicoOut(t);
});
ruta("PUT", "/api/tecnicos/:id", ({ u, params, body }) => {
  exigir(u, "supervisor");
  const t = D.tecnicos.find((x) => x.id === Number(params.id));
  if (!t) throw noEncontrado("No encontramos a esa persona.");
  validarTecnico(body, false);
  for (const k of ["nombre", "nivel", "estado", "capacidad", "correo", "whatsapp"]) if (k in body) t[k] = body[k] === "" ? null : body[k];
  if (Array.isArray(body.habilidades)) t.hab = Object.fromEntries(body.habilidades.filter((h) => h.nivel > 0).map((h) => [h.categoria, h.nivel]));
  if (Array.isArray(body.turnos)) t.turnos = body.turnos;
  if (Array.isArray(body.grupo_ids)) D.grupos.forEach((g) => { g.miembros = g.miembros.filter((m) => m !== t.id); if (body.grupo_ids.includes(g.id)) g.miembros.push(t.id); });
  return tecnicoOut(t);
});
ruta("GET", "/api/grupos", ({ u }) => {
  exigir(u, "supervisor");
  return { items: D.grupos, total: D.grupos.length };
});

// Configuración (admin) ---------------------------------------------------------------------------------------
ruta("GET", "/api/categorias", ({ u }) => (exigir(u, "admin"), { items: D.CATEGORIAS, total: D.CATEGORIAS.length }));
ruta("PUT", "/api/categorias", ({ u, body }) => {
  exigir(u, "admin");
  for (const c of body.items ?? []) {
    const x = D.CATEGORIAS.find((k) => k.id === c.id);
    if (x) Object.assign(x, { nombre: String(c.nombre ?? x.nombre).trim() || x.nombre, grupo_id: c.grupo_id ?? null, activa: !!c.activa });
  }
  return { items: D.CATEGORIAS, total: D.CATEGORIAS.length };
});
ruta("GET", "/api/calendarios", ({ u }) => (exigir(u, "admin"), { items: D.calendarios, total: D.calendarios.length }));
ruta("PUT", "/api/calendarios", ({ u, body }) => {
  exigir(u, "admin");
  for (const c of body.items ?? []) {
    const x = D.calendarios.find((k) => k.id === c.id);
    if (!x) continue;
    for (const [dia, tramos] of Object.entries(c.horario ?? {})) for (const [d, h] of tramos) if (d >= h) throw invalido("Cada tramo debe terminar después de empezar.");
    Object.assign(x, c);
  }
  return { items: D.calendarios, total: D.calendarios.length };
});
ruta("GET", "/api/sla", ({ u }) => (exigir(u, "admin"), { items: D.politicasSla, total: D.politicasSla.length }));
ruta("PUT", "/api/sla", ({ u, body }) => {
  exigir(u, "admin");
  for (const p of body.items ?? []) {
    if (!(p.respuesta_min > 0) || !(p.resolucion_min > 0)) throw invalido("Los plazos deben ser mayores que cero.");
    if (p.resolucion_min < p.respuesta_min) throw invalido(`En ${p.prioridad}, la resolución no puede ser más corta que la primera respuesta.`);
    const x = D.politicasSla.find((k) => k.id === p.id);
    if (x) Object.assign(x, { respuesta_min: p.respuesta_min, resolucion_min: p.resolucion_min });
  }
  return { items: D.politicasSla, total: D.politicasSla.length };
});
ruta("GET", "/api/matriz", ({ u }) => (exigir(u, "admin"), { items: D.matriz, total: D.matriz.length }));
ruta("PUT", "/api/matriz", ({ u, body }) => {
  exigir(u, "admin");
  for (const c of body.items ?? []) {
    const x = D.matriz.find((k) => k.impacto === c.impacto && k.urgencia === c.urgencia);
    if (x && ["P1", "P2", "P3", "P4"].includes(c.prioridad)) x.prioridad = c.prioridad;
  }
  return { items: D.matriz, total: D.matriz.length };
});
ruta("GET", "/api/escalamiento/reglas", ({ u }) => {
  exigir(u, "supervisor");
  return { items: D.reglas, total: D.reglas.length };
});
const ACCIONES_MOTOR = ["avisar_tecnico", "escalar_nivel", "avisar_responsable", "avisar_guardia", "avisar_supervisor", "nota"];
ruta("PUT", "/api/escalamiento/reglas/:id", ({ u, params, body }) => {
  exigir(u, "admin");
  const r = D.reglas.find((x) => x.id === Number(params.id));
  if (!r) throw noEncontrado("No encontramos esa regla.");
  if ("modo" in body && !["sombra", "activo"].includes(body.modo)) throw invalido("El modo es «sombra» o «activo».");
  // La consola manda el porcentaje como `umbral_pct` y como `condicion.porcentaje`; el motor guarda `umbral_pct`.
  const pct = body.umbral_pct ?? body.condicion?.umbral_pct ?? body.condicion?.porcentaje;
  if (pct !== undefined && !(Number.isInteger(Number(pct)) && Number(pct) >= 1 && Number(pct) <= 200)) throw invalido("El porcentaje del plazo debe estar entre 1 y 200.");
  if (Array.isArray(body.acciones)) for (const a of body.acciones) if (!ACCIONES_MOTOR.includes(a.tipo)) throw invalido("Ese tipo de acción no existe.");
  for (const k of ["activa", "modo", "acciones", "descripcion"]) if (k in body) r[k] = body[k];
  if ("condicion" in body) {
    const { porcentaje, umbral_pct, ...resto } = body.condicion ?? {};
    r.condicion = { ...resto };
  }
  if (pct !== undefined) r.condicion = { ...r.condicion, umbral_pct: Number(pct), porcentaje: Number(pct) };
  return r;
});
ruta("GET", "/api/usuarios", ({ u }) => (exigir(u, "admin"), { items: D.usuarios.map(({ clave, ...x }) => x), total: D.usuarios.length }));
ruta("PUT", "/api/usuarios/:id", ({ u, params, body }) => {
  exigir(u, "admin");
  const x = D.usuarios.find((k) => k.id === Number(params.id));
  if (!x) throw noEncontrado("No encontramos a ese usuario.");
  if (x.id === u.id && body.rol && body.rol !== "admin") throw new HttpError(409, "No puedes quitarte tu propio rol de administrador.", "conflicto");
  if (body.rol) x.rol = body.rol;
  if ("activo" in body) x.activo = !!body.activo;
  const { clave, ...out } = x;
  return out;
});

// Asistente ---------------------------------------------------------------------------------------------------
ruta("GET", "/api/asistente/config", ({ u }) => (exigir(u, "entrenador"), D.asistenteConfig));
ruta("PUT", "/api/asistente/config", ({ u, body }) => {
  exigir(u, "entrenador");
  if (body.umbral_confianza !== undefined && !(body.umbral_confianza >= 0.3 && body.umbral_confianza <= 0.95)) throw invalido("El umbral de confianza va entre 0.30 y 0.95.");
  if (body.maximo_pasos_guia !== undefined && !(body.maximo_pasos_guia >= 1 && body.maximo_pasos_guia <= 8)) throw invalido("Los pasos de guía van de 1 a 8.");
  if ("nombre" in body && !String(body.nombre).trim()) throw invalido("El asistente necesita un nombre.");
  Object.assign(D.asistenteConfig, body);
  return D.asistenteConfig;
});
ruta("GET", "/api/articulos", ({ u, q }) => {
  exigir(u, "entrenador");
  let l = D.articulos.slice();
  if (q.get("estado")) l = l.filter((a) => a.estado === q.get("estado"));
  if (q.get("q")) l = l.filter((a) => norm(a.titulo + a.clave + a.sintomas.join(" ")).includes(norm(q.get("q"))));
  const p = pagina(l, q);
  return p;
});
function validarArticulo(b) {
  if (!String(b.titulo ?? "").trim()) throw invalido("Falta el título del artículo.");
  if (!Array.isArray(b.pasos) || !b.pasos.filter((x) => String(x).trim()).length) throw invalido("Un artículo necesita al menos un paso.");
}
ruta("POST", "/api/articulos", ({ u, body }) => {
  exigir(u, "entrenador");
  validarArticulo(body);
  const n = Math.max(...D.articulos.map((a) => a.id)) + 1;
  const a = { id: n, clave: "KB-" + String(100 + n).padStart(3, "0"), titulo: String(body.titulo).trim(), categoria: body.categoria ?? null, sintomas: (body.sintomas ?? []).filter(Boolean), pasos: body.pasos.filter((x) => String(x).trim()), cuerpo: body.cuerpo ?? "", estado: body.estado ?? "borrador", supuesto: true, version: 1, actualizado_en: ahoraISO(), usos: 0, resolvio_pct: null };
  D.articulos.unshift(a);
  return a;
});
ruta("PUT", "/api/articulos/:id", ({ u, params, body }) => {
  exigir(u, "entrenador");
  const a = D.articulos.find((x) => x.id === Number(params.id));
  if (!a) throw noEncontrado("No encontramos ese artículo.");
  if (!("estado" in body && Object.keys(body).length === 1)) validarArticulo({ ...a, ...body });
  Object.assign(a, body, { version: a.version + 1, actualizado_en: ahoraISO(), supuesto: body.supuesto ?? false });
  return a;
});
ruta("GET", "/api/entrenamiento/cola", ({ u, q }) => {
  exigir(u, "entrenador");
  const estado = q.get("estado") ?? "pendiente";
  const l = D.cola.filter((c) => (estado === "todas" ? true : c.estado === estado));
  const p = pagina(l, q);
  return p;
});
ruta("POST", "/api/entrenamiento/:id/revisar", ({ u, params, body }) => {
  exigir(u, "entrenador");
  const c = D.cola.find((x) => x.id === Number(params.id));
  if (!c) throw noEncontrado("No encontramos ese mensaje en la cola.");
  if (body.decision === "confirmar") c.estado = "confirmada";
  else if (body.decision === "descartar") c.estado = "descartada";
  else if (body.decision === "corregir") {
    if (!D.INTENCIONES.includes(body.intencion)) throw invalido("Elige la intención correcta de la lista.");
    c.estado = "corregida";
    c.intencion_correcta = body.intencion;
  } else throw invalido("Esa decisión no existe.");
  return c;
});
ruta("GET", "/api/entrenamiento/estado", ({ u }) => (exigir(u, "entrenador"), estadoEntrenamiento()));
ruta("POST", "/api/entrenamiento/reentrenar", ({ u }) => {
  exigir(u, "entrenador");
  const e = estadoEntrenamiento();
  if (e.fase === "entrenando") throw new HttpError(409, "Ya hay un entrenamiento en curso.", "conflicto");
  if (e.cambios_pendientes <= 0) throw invalido("Revisa al menos un mensaje antes de reentrenar.");
  entrenamiento.fase = "entrenando";
  entrenamiento.candidato = null;
  entrenamiento.intentos++;
  entrenamiento.inicio = Date.now();
  entrenamiento.revisadasAlEntrenar = D.cola.filter((c) => c.estado === "confirmada" || c.estado === "corregida").length;
  return estadoEntrenamiento();
});
ruta("POST", "/api/entrenamiento/publicar", ({ u }) => {
  exigir(u, "entrenador");
  const e = estadoEntrenamiento();
  if (!e.candidato) throw invalido("No hay una versión nueva para publicar.");
  if (e.candidato.exactitud < e.publicado.exactitud) throw new HttpError(409, "La versión nueva es peor que la publicada. No se publica.", "conflicto");
  D.modelos.forEach((m) => m.estado === "publicado" && (m.estado = "retirado"));
  D.modelos.unshift({ ...e.candidato, estado: "publicado" });
  entrenamiento.fase = "ninguno";
  entrenamiento.candidato = null;
  return estadoEntrenamiento();
});
ruta("POST", "/api/entrenamiento/descartar", ({ u }) => {
  exigir(u, "entrenador");
  entrenamiento.fase = "ninguno";
  entrenamiento.candidato = null;
  return estadoEntrenamiento();
});
ruta("GET", "/api/calidad", ({ u }) => (exigir(u, "entrenador"), { ...D.calidad, modelos: D.modelos }));

// Indicadores y reportes ---------------------------------------------------------------------------------------
ruta("GET", "/api/indicadores", ({ u, q }) => (exigir(u, "gerencia"), indicadores(q)));
ruta("GET", "/api/reportes", ({ u }) => (exigir(u, "gerencia"), { items: D.reportes, total: D.reportes.length }));
ruta("POST", "/api/reportes/preguntar", async ({ u, body }) => {
  exigir(u, "gerencia");
  await dormir(500 + Math.random() * 500);
  return preguntar(String(body.pregunta ?? ""));
});

// Públicas ---------------------------------------------------------------------------------------------------
ruta("POST", "/api/chat-web", async ({ body }) => turnoChat(body));
ruta("GET", "/api/estado/:token", ({ params }) => {
  const inc = D.incidencias.find((i) => i.token_publico === params.token);
  if (!inc) throw noEncontrado("No encontramos ese enlace. Puede que haya caducado; pide uno nuevo a la mesa de ayuda.");
  const sla = slaDe(inc);
  const ult = [...inc.mensajes].reverse().find((m) => m.rol === "tecnico" && !m.interno);
  const texto = { nueva: "Recibimos tu solicitud", asignada: "Ya tiene un técnico asignado", en_curso: "Estamos trabajando en ella", espera_usuario: "Esperamos tu respuesta", espera_tercero: "Esperamos a un proveedor", resuelta: "Resuelta: confírmanos si quedó bien", cerrada: "Cerrada", reabierta: "Reabierta: volvimos a revisarla" }[inc.estado];
  return {
    numero: inc.numero,
    titulo: inc.titulo,
    estado: inc.estado,
    estado_texto: texto,
    tecnico: D.tecnicos.find((t) => t.id === inc.tecnico_id)?.nombre ?? null,
    prioridad: inc.prioridad,
    vence_resolucion_en: sla ? new Date(Date.now() + sla.restante_min * MIN).toISOString() : null,
    creada_en: inc.creada_en,
    ultimo_mensaje_tecnico: ult ? { ts: ult.ts, texto: ult.texto, autor: ult.autor ?? "Soporte" } : null,
    puede_responder: inc.estado !== "cerrada",
  };
});
ruta("POST", "/api/estado/:token/responder", ({ params, body }) => {
  const inc = D.incidencias.find((i) => i.token_publico === params.token);
  if (!inc) throw noEncontrado("No encontramos ese enlace. Puede que haya caducado.");
  const texto = String(body.texto ?? "").trim();
  if (!texto) throw invalido("Escribe tu respuesta antes de enviarla.");
  if (texto.length > 1000) throw invalido("Tu respuesta es muy larga; resúmela en menos de 1000 caracteres.");
  inc.mensajes.push({ id: Date.now(), ts: ahoraISO(), rol: "usuario", texto });
  if (inc.estado === "espera_usuario") {
    inc.restante_min = slaDe(inc)?.restante_min ?? inc.restante_min;
    inc.ref_ts = Date.now();
    inc.pausado = false;
    inc.estado = "en_curso";
  }
  evento(inc, "comentario", "usuario", undefined);
  emitir("mensaje", { id: inc.id });
  emitir("incidencia_actualizada", { id: inc.id });
  return { ok: true };
});

// SSE
function abrirSse(req, res, u) {
  exigir(u, "conversaciones");
  res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive", "X-Accel-Buffering": "no", ...cors(req) });
  res.write("retry: 3000\n\n: conectado\n\n");
  clientes.add(res);
  req.on("close", () => clientes.delete(res));
}

// Control de pruebas
ruta("POST", "/mock/falla", async ({ body }) => (control.fallas.push({ ruta: body.ruta, estado: body.estado ?? 500, veces: body.veces ?? 1 }), { ok: true }));
ruta("POST", "/mock/latencia", async ({ body }) => ((control.latencia = body.ms ?? null), { ok: true }));
ruta("POST", "/mock/clickhouse", async ({ body }) => ((control.sinClickhouse = body.configurado === false), { ok: true }));
ruta("POST", "/mock/evento", async ({ body }) => (emitir(body.evento ?? "incidencia_actualizada", { id: body.id }), { ok: true }));

// ---------------------------------------------------------------------------------------------------------------
// Servidor
const cors = (req) => ({
  "Access-Control-Allow-Origin": req.headers.origin ?? "*",
  "Access-Control-Allow-Headers": "Authorization, Content-Type",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  Vary: "Origin",
});
const json = (req, res, estado, datos) => {
  res.writeHead(estado, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...cors(req) });
  res.end(JSON.stringify(datos));
};

const TIPOS = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon", ".txt": "text/plain", ".woff2": "font/woff2" };
async function estatico(req, res, pathname) {
  // Lo mismo que hace nginx: /estado/<token> → la página única de estado.
  let p = pathname;
  if (/^\/estado\/[^/]+\/?$/.test(p) && p !== "/estado/_/" && p !== "/estado/_") p = "/estado/_/";
  const candidatos = [p, p.replace(/\/$/, "") + "/index.html", p + ".html"];
  for (const c of candidatos) {
    const ruta = normalize(join(DIST, c));
    if (!ruta.startsWith(DIST)) continue;
    try {
      const st = await stat(ruta);
      if (st.isFile()) {
        const datos = await readFile(ruta);
        const cache = /^\/(build|assets)\//.test(c) ? "public, max-age=31536000, immutable" : "no-cache";
        res.writeHead(200, { "Content-Type": TIPOS[extname(ruta)] ?? "application/octet-stream", "Cache-Control": cache });
        return res.end(datos);
      }
    } catch {
      /* siguiente candidato */
    }
  }
  try {
    const datos = await readFile(join(DIST, "404.html"));
    res.writeHead(404, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(datos);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end("No encontrado");
  }
}

const servidor = http.createServer(async (req, res) => {
  if (PREFIJO && req.url?.startsWith(PREFIJO)) req.url = req.url.slice(PREFIJO.length) || "/";
  const url = new URL(req.url ?? "/", "http://x");
  const { pathname } = url;
  try {
    if (req.method === "OPTIONS") {
      res.writeHead(204, cors(req));
      return res.end();
    }
    const esApi = pathname.startsWith("/api/") || pathname.startsWith("/mock/");
    if (!esApi) {
      if (process.env.SERVIR_DIST) return await estatico(req, res, pathname);
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      return res.end("Mock de jsrbot: la API está en /api. Con SERVIR_DIST=1 también sirve web/dist.");
    }

    // Usuario
    const auth = req.headers.authorization ?? "";
    const p = auth.startsWith("Bearer ") ? verificar(auth.slice(7)) : null;
    const u = p ? D.usuarios.find((x) => x.id === p.sub && x.activo) : null;

    if (pathname === "/api/eventos" && req.method === "GET") return abrirSse(req, res, u);

    // Fallas y latencia de prueba
    const iF = control.fallas.findIndex((f) => pathname.startsWith(f.ruta));
    if (iF >= 0 && !pathname.startsWith("/mock/")) {
      const f = control.fallas[iF];
      if (--f.veces <= 0) control.fallas.splice(iF, 1);
      await dormir(80);
      return json(req, res, f.estado, { error: "Fallo simulado por el mock.", codigo: "simulado" });
    }
    await dormir(control.latencia ?? 40 + Math.random() * 110);

    const r = rutas.find((x) => x.metodo === req.method && x.re.test(pathname));
    if (!r) {
      const hayRuta = rutas.some((x) => x.re.test(pathname));
      return json(req, res, hayRuta ? 405 : 404, { error: hayRuta ? "Esa operación no está disponible." : "No encontramos esa ruta.", codigo: "no_encontrado" });
    }
    const params = r.re.exec(pathname).groups ?? {};
    const body = req.method === "GET" || req.method === "DELETE" ? {} : await cuerpo(req);
    const salida = await r.manejador({ req, u, params, body, q: url.searchParams });
    return json(req, res, 200, salida ?? { ok: true });
  } catch (e) {
    if (e instanceof HttpError) return json(req, res, e.estado, { error: e.message, codigo: e.codigo });
    console.error(e);
    return json(req, res, 500, { error: "Algo falló en el servidor.", codigo: "interno" });
  }
});

servidor.listen(PUERTO, HOST, () => {
  console.log(`Mock de jsrbot en http://${HOST}:${PUERTO}  (admin@jsr.test / jsr123)${process.env.SERVIR_DIST ? "  · sirve " + DIST : ""}`);
});
