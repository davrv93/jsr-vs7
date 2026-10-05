// Datos sintéticos de la consola de jsrbot. Realistas y deliberadamente feos (DISENO §4.5): asuntos de 200 caracteres,
// nombres compuestos, una incidencia con 80 mensajes, técnicos sin foto ni habilidades, plazos vencidos, vacíos.
// Semilla fija: la misma interfaz cada vez. Los plazos se miden desde el arranque del mock y siguen corriendo.

function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(20261005);
const entre = (a, b) => Math.floor(rnd() * (b - a + 1)) + a;
const elige = (arr) => arr[Math.floor(rnd() * arr.length)];

export const AHORA0 = Date.now();
const MIN = 60_000;
export const haceMin = (m) => new Date(AHORA0 - m * MIN).toISOString();
export const enMin = (m) => new Date(AHORA0 + m * MIN).toISOString();

// ---------------------------------------------------------------------------------------------------------------
export const SEDES = ["Sede Centro", "Sede Norte", "Campus Lima Este", "Sede Miraflores", "Sede Arequipa"];
export const AREAS = [
  "Contabilidad",
  "Logística",
  "Recursos Humanos",
  "Admisión",
  "Biblioteca",
  "Tesorería",
  "Gerencia General",
  "Marketing",
  "Soporte Académico",
  "Dirección de Estudios",
  "Almacén central",
];

const NOMBRES = [
  "Ana Ríos Paz",
  "María del Carmen Quispe Huamán",
  "José Luis de la Cruz Vásquez",
  "Rosa Elvira Chávez de la Torre",
  "Carlos Alberto Mendoza Salazar",
  "Lucía Fernanda Paredes Villanueva",
  "Juan Pérez",
  "Milagros Huamaní Condori",
  "Jorge Luis Tapia Rojas",
  "Giovanna Bustamante Ñahui",
  "Fernando Quispe",
  "Patricia del Pilar Gonzales Arévalo",
  "Walter Anccasi Mamani",
  "Sofía Valdivia",
  "Ricardo Alonso Benavides Cáceres",
  "Yessenia Choque Apaza",
  "Héctor Manuel Rojas de la Vega",
  "Carmen Rosa Aguirre",
  "Luz Marina Ccopa Huaman",
  "Víctor Hugo Zevallos Pinto",
  "Daniela Sánchez Ugarte",
  "Mónica Lizárraga",
  "Pedro Pablo Machaca Flores",
  "Nancy Yupanqui Tito",
  "Óscar Iván Linares Montalvo",
  "Gladys Cutipa",
  "Raúl Eduardo Palacios Samanez",
  "Teresa de Jesús Ramos Escobar",
  "Alonso Del Castillo",
  "Verónica Cárdenas Ibáñez",
];

export const personas = NOMBRES.map((nombre, i) => ({
  id: i + 1,
  nombre,
  correo: nombre.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").split(" ").slice(0, 2).join(".").replace(/[^a-z.]/g, "") + "@empresa.pe",
  whatsapp: "519" + String(87000000 + i * 137).slice(0, 8),
  area: AREAS[i % AREAS.length],
  sede: SEDES[i % SEDES.length],
  vip: i === 14 || i === 2,
  equipos: [`PC-${AREAS[i % AREAS.length].slice(0, 4).toUpperCase().replace(/[^A-Z]/g, "X")}-${String(i + 3).padStart(2, "0")}`],
}));

// Categorías ----------------------------------------------------------------------------------------------------
export const CATEGORIAS = [
  ["correo", "Correo", 1],
  ["cuentas_accesos", "Cuentas y accesos", 1],
  ["red_wifi", "Red y wifi", 2],
  ["vpn", "VPN", 2],
  ["impresoras", "Impresoras", 1],
  ["equipo", "Equipos", 1],
  ["software_oficina", "Software de oficina", 1],
  ["sistema_interno", "Sistema interno", 3],
  ["telefonia", "Telefonía", 2],
  ["otro", "Otro", 1],
].map(([clave, nombre, grupo_id], i) => ({ id: i + 1, clave, nombre, grupo_id, activa: clave !== "telefonia" || true }));

// Grupos y técnicos ---------------------------------------------------------------------------------------------
export const grupos = [
  { id: 1, nombre: "Mesa de ayuda N1", nivel: "N1", escala_a_grupo_id: 2, responsable_tecnico_id: 2, miembros: [1, 2, 3, 4, 5, 10] },
  { id: 2, nombre: "Redes y telecomunicaciones", nivel: "N2", escala_a_grupo_id: 4, responsable_tecnico_id: 6, miembros: [6, 7] },
  { id: 3, nombre: "Sistemas internos", nivel: "N2", escala_a_grupo_id: 4, responsable_tecnico_id: 8, miembros: [8] },
  { id: 4, nombre: "Proveedor externo", nivel: "N3", escala_a_grupo_id: null, responsable_tecnico_id: 9, miembros: [9] },
  { id: 5, nombre: "Seguridad de la información", nivel: "N2", escala_a_grupo_id: null, responsable_tecnico_id: null, miembros: [] },
];

const TURNO_ESTANDAR = [1, 2, 3, 4, 5].map((d) => ({ dia_semana: d, desde: "08:30", hasta: "18:00" }));
const TURNO_TARDE = [1, 2, 3, 4, 5, 6].map((d) => ({ dia_semana: d, desde: "11:00", hasta: "19:30" }));

export const tecnicos = [
  { id: 1, nombre: "Rodrigo Echevarría Lazo", nivel: "N1", estado: "activo", capacidad: 10, correo: "rodrigo.echevarria@empresa.pe", whatsapp: "51987100001", foto: null, turnos: TURNO_ESTANDAR, hab: { correo: 3, cuentas_accesos: 3, vpn: 2, equipo: 2, impresoras: 2 } },
  { id: 2, nombre: "Luis Paz Medina", nivel: "N1", estado: "activo", capacidad: 8, correo: "luis.paz@empresa.pe", whatsapp: "51987100002", foto: null, turnos: TURNO_ESTANDAR, hab: { correo: 2, impresoras: 3, equipo: 3, software_oficina: 2 } },
  { id: 3, nombre: "Karina Soto Ramírez", nivel: "N1", estado: "activo", capacidad: 8, correo: "karina.soto@empresa.pe", whatsapp: "51987100003", foto: null, turnos: TURNO_TARDE, hab: { cuentas_accesos: 3, software_oficina: 3, correo: 2 } },
  { id: 4, nombre: "Miguel Ángel Torres Delgado", nivel: "N1", estado: "activo", capacidad: 8, correo: "miguel.torres@empresa.pe", whatsapp: "51987100004", foto: null, turnos: TURNO_ESTANDAR, hab: { red_wifi: 2, equipo: 2, impresoras: 2 } },
  {
    id: 5,
    nombre: "Pamela Vargas",
    nivel: "N1",
    estado: "ausente",
    capacidad: 8,
    correo: "pamela.vargas@empresa.pe",
    whatsapp: null,
    foto: null,
    turnos: TURNO_ESTANDAR,
    hab: { correo: 2, cuentas_accesos: 2 },
    ausencia: { desde: haceMin(60 * 24 * 2), hasta: enMin(60 * 24 * 5), motivo: "Vacaciones" },
  },
  { id: 6, nombre: "Andrea Cárdenas Flores", nivel: "N2", estado: "activo", capacidad: 6, correo: "andrea.cardenas@empresa.pe", whatsapp: "51987100006", foto: null, turnos: TURNO_ESTANDAR, hab: { red_wifi: 3, vpn: 3, telefonia: 2 } },
  { id: 7, nombre: "Javier Palomino Ccori", nivel: "N2", estado: "activo", capacidad: 6, correo: "javier.palomino@empresa.pe", whatsapp: "51987100007", foto: null, turnos: TURNO_TARDE, hab: { red_wifi: 3, telefonia: 3, vpn: 2 } },
  { id: 8, nombre: "Rocío del Pilar Mejía Sánchez", nivel: "N2", estado: "activo", capacidad: 6, correo: "rocio.mejia@empresa.pe", whatsapp: "51987100008", foto: null, turnos: TURNO_ESTANDAR, hab: { sistema_interno: 3, cuentas_accesos: 2, software_oficina: 2 } },
  { id: 9, nombre: "Sergio Alarcón (proveedor)", nivel: "N3", estado: "activo", capacidad: 4, correo: "soporte@proveedor.example", whatsapp: null, foto: null, turnos: [], hab: { sistema_interno: 3, red_wifi: 3 } },
  // Recién añadido: sin habilidades ni turnos. El caso feo de siempre.
  { id: 10, nombre: "Edith Mamani Quispe", nivel: "N1", estado: "activo", capacidad: 8, correo: null, whatsapp: null, foto: null, turnos: [], hab: {} },
  { id: 11, nombre: "Óscar Tello", nivel: "N2", estado: "inactivo", capacidad: 6, correo: "oscar.tello@empresa.pe", whatsapp: null, foto: null, turnos: [], hab: { vpn: 1 } },
];

// ---------------------------------------------------------------------------------------------------------------
// Incidencias
const T_PRIO = { P1: 120, P2: 480, P3: 1440, P4: 2880 }; // minutos totales del plazo de resolución (en el mock, de reloj)

const ASUNTOS = [
  ["correo", "Outlook no sincroniza el buzón compartido de la oficina"],
  ["correo", "No llegan los correos externos desde ayer"],
  ["correo", "Buzón lleno: no puedo enviar ni recibir"],
  ["cuentas_accesos", "Olvidé mi contraseña del sistema académico"],
  ["cuentas_accesos", "Cuenta bloqueada tras tres intentos"],
  ["cuentas_accesos", "Necesito acceso a la carpeta de Tesorería en el servidor"],
  ["red_wifi", "El wifi de la sala de reuniones se cae cada 10 minutos"],
  ["red_wifi", "No hay internet en el segundo piso"],
  ["vpn", "No puedo conectarme a la VPN desde casa"],
  ["vpn", "La VPN conecta pero no abre el sistema de planillas"],
  ["impresoras", "La impresora del 3.er piso no imprime"],
  ["impresoras", "Atasco constante en la multifuncional de Almacén"],
  ["impresoras", "Instalar la impresora nueva en tres equipos"],
  ["equipo", "La laptop no enciende desde el lunes"],
  ["equipo", "Pantalla parpadea y se apaga sola"],
  ["equipo", "Solicito mouse y teclado inalámbricos"],
  ["software_oficina", "Excel se cierra al abrir el archivo de cierre mensual"],
  ["software_oficina", "Instalar Office en el equipo nuevo de Marketing"],
  ["sistema_interno", "Error al emitir facturas en el sistema contable"],
  ["sistema_interno", "El reporte de asistencia no carga los datos de octubre"],
  ["telefonia", "El anexo 214 no recibe llamadas"],
  ["otro", "Consulta sobre el procedimiento de baja de equipos"],
];

const ASUNTO_200 =
  "Desde el viernes por la tarde el sistema de matrícula en línea se queda cargando al intentar registrar a los alumnos de intercambio de la Sede Arequipa y, además, el reporte de pagos pendientes no coincide con lo que muestra Tesorería; ya probé con otro navegador";

// [id, asunto|[cat, asunto], persona, prioridad, estado, tecnico, restante(min), total(min), canal, nMensajes, extra]
const MANUALES = [
  [142, ["correo", "Correo no sincroniza en Outlook"], 1, "P2", "en_curso", 1, 40, 480, "whatsapp", 12, { sugerencia: true }],
  [139, ["impresoras", "Impresora 3.er piso no imprime"], 3, "P3", "asignada", 1, 135, 600, "whatsapp", 7, {}],
  [137, ["vpn", "Acceso a VPN"], 1, "P3", "en_curso", 1, 520, 1440, "web", 9, {}],
  [141, ["equipo", "Laptop con pantalla negra al iniciar"], 5, "P2", "asignada", 1, -12, 480, "whatsapp", 6, {}],
  [138, ["cuentas_accesos", "Reinicio de contraseña del Sistema Académico"], 8, "P4", "en_curso", 1, 1900, 2880, "whatsapp", 5, {}],
  [143, ["red_wifi", "Sin internet en toda la Sede Norte"], 9, "P1", "nueva", null, 25, 120, "whatsapp", 4, { p1: true }],
  [140, ["sistema_interno", ASUNTO_200], 14, "P2", "asignada", 8, 330, 480, "web", 10, { largo: true }],
  [118, ["correo", "Reenvío automático de correos que no se detiene"], 6, "P3", "en_curso", 1, 700, 1440, "whatsapp", 80, { muchos: true }],
  [136, ["software_oficina", "Excel se cierra al abrir el archivo de cierre mensual"], 2, "P3", "espera_usuario", 1, 800, 1440, "whatsapp", 8, { pausa: true, desdeAyer: true }],
  [135, ["equipo", "Solicito monitor adicional para contabilidad"], 12, "P4", "espera_usuario", 3, 2000, 2880, "web", 6, { pausa: true, desdeAyer: true }],
  [134, ["telefonia", "El anexo 214 no recibe llamadas"], 16, "P3", "espera_tercero", 7, 900, 1440, "whatsapp", 5, { pausa: true }],
  [144, ["impresoras", "Atasco constante en la multifuncional de Almacén"], 10, "P3", "nueva", null, 480, 1440, "whatsapp", 3, {}],
  [145, ["cuentas_accesos", "Cuenta bloqueada tras tres intentos"], 18, "P3", "nueva", null, 700, 1440, "web", 3, {}],
  [146, ["correo", "No llegan los correos externos desde ayer"], 20, "P2", "nueva", null, 110, 480, "whatsapp", 4, {}],
  [133, ["vpn", "La VPN conecta pero no abre el sistema de planillas"], 4, "P2", "en_curso", 6, 250, 480, "web", 11, {}],
  [132, ["red_wifi", "El wifi de la sala de reuniones se cae cada 10 minutos"], 11, "P3", "en_curso", 4, 200, 1440, "whatsapp", 9, {}],
  [131, ["software_oficina", "Instalar Office en el equipo nuevo de Marketing"], 22, "P4", "asignada", 3, 1500, 2880, "web", 4, {}],
  [130, ["sistema_interno", "Error al emitir facturas en el sistema contable"], 15, "P2", "reabierta", 8, -75, 480, "whatsapp", 14, { reapertura: true }],
  [129, ["equipo", "Pantalla parpadea y se apaga sola"], 17, "P3", "resuelta", 2, 0, 1440, "whatsapp", 8, { resuelta: true }],
  [128, ["correo", "Buzón lleno: no puedo enviar ni recibir"], 19, "P3", "cerrada", 3, 0, 1440, "whatsapp", 7, { cerrada: true }],
  [127, ["impresoras", "Instalar la impresora nueva en tres equipos"], 21, "P4", "resuelta", 2, 0, 2880, "web", 6, { resuelta: true }],
];

const TEXTO_USUARIO = [
  "Buenas, desde esta mañana no me llegan los correos nuevos",
  "Ya reinicié la computadora y sigue igual",
  "Es solo en mi equipo, mis compañeros sí reciben",
  "Me aparece un mensaje que dice «Desconectado»",
  "Gracias, ya probé eso y no funcionó",
  "¿Cuánto se va a demorar? Tengo una entrega hoy",
  "Sigue sin funcionar, por favor",
  "El equipo es PC-CONT-07, está en la oficina del segundo piso",
  "Ahora sí abre pero muy lento",
  "Okay, espero entonces",
];
const TEXTO_ASISTENTE = [
  "Entiendo, vamos a revisarlo. ¿Desde cuándo pasa esto y en qué equipo?",
  "Gracias. Prueba cerrar sesión en Outlook y volver a entrar. ¿Te funcionó?",
  "Lamento que siga igual. Voy a abrir una incidencia con lo que me contaste.",
  "Listo: abrí la incidencia y la asigné a un técnico. Te avisaré de cada cambio.",
];
const TEXTO_TECNICO = [
  "Hola, soy del equipo de soporte. Ya revisé tu buzón y veo un bloqueo en la sincronización.",
  "¿Podrías cerrar Outlook por completo y abrirlo de nuevo? Mientras tanto limpio la caché del perfil.",
  "Listo, quedó sincronizando. Te aviso si necesito algo más.",
];

function hilo(n, creadaMin, tecnicoNombre, conTecnico) {
  const items = [];
  let t = creadaMin;
  const paso = Math.max(1, Math.floor(creadaMin / (n + 1)));
  for (let i = 0; i < n; i++) {
    let rol;
    if (i === 0) rol = "usuario";
    else if (i % 4 === 1) rol = "asistente";
    else if (i % 4 === 2) rol = "usuario";
    else rol = conTecnico && i > 3 ? (i % 2 === 0 ? "usuario" : "tecnico") : i % 2 === 0 ? "usuario" : "asistente";
    const texto =
      rol === "usuario"
        ? TEXTO_USUARIO[i % TEXTO_USUARIO.length]
        : rol === "asistente"
          ? TEXTO_ASISTENTE[i % TEXTO_ASISTENTE.length]
          : TEXTO_TECNICO[i % TEXTO_TECNICO.length];
    items.push({
      id: 0,
      ts: haceMin(Math.max(0, t)),
      rol,
      autor: rol === "tecnico" ? tecnicoNombre : undefined,
      texto: i === 1 && rol === "usuario" ? "Mi contraseña de correo es hola1234 por si la necesitan" : texto,
      meta:
        rol === "usuario"
          ? { intencion: i === 0 ? "reportar_falla" : "aportar_dato", confianza: 0.62 + rnd() * 0.36, categoria: "correo" }
          : rol === "asistente"
            ? { latencia_ms: 380 + Math.floor(rnd() * 600), articulos: i === 3 ? ["KB-031"] : [] }
            : undefined,
    });
    t -= paso;
  }
  // Las contraseñas pegadas por error ya vienen enmascaradas (texto_usuario_guardar).
  items.forEach((m) => {
    if (m.texto.includes("hola1234")) m.texto = "Mi contraseña de correo es [oculto] por si la necesitan";
  });
  return items;
}

let siguienteIdMsg = 5000;
export const incidencias = [];

function crearInc(def) {
  const [id, asu, pIdx, prioridad, estado, tecId, restante, total, canal, nMsg, extra] = def;
  const [categoria, titulo] = Array.isArray(asu) ? asu : [asu.cat, asu.titulo];
  const persona = personas[pIdx - 1];
  const creadaMin = total - restante + (extra.desdeAyer ? 60 * 20 : 0) + (estado === "resuelta" || estado === "cerrada" ? 60 * 30 : 0);
  const inc = {
    id,
    numero: "INC-" + String(id).padStart(6, "0"),
    titulo,
    resumen: resumenDe(categoria, persona, titulo, extra),
    tipo: titulo.startsWith("Solicit") || titulo.startsWith("Instalar") ? "solicitud" : "incidente",
    prioridad,
    estado,
    categoria,
    canal,
    persona_id: persona.id,
    tecnico_id: tecId,
    grupo_id: tecId ? grupos.find((g) => g.miembros.includes(tecId))?.id ?? 1 : null,
    impacto: prioridad === "P1" ? "sede" : prioridad === "P2" ? "area" : "persona",
    urgencia: prioridad === "P1" ? "critica" : prioridad === "P2" ? "alta" : prioridad === "P3" ? "media" : "baja",
    nivel: tecId && tecnicos.find((t) => t.id === tecId)?.nivel ? tecnicos.find((t) => t.id === tecId).nivel : "N1",
    reaperturas: extra.reapertura ? 1 : 0,
    escalamientos: tecId && tecnicos.find((t) => t.id === tecId)?.nivel !== "N1" ? 1 : 0,
    token_publico: id === 142 ? "ab12cd34ef56ab12cd34ef56ab12cd34" : "t" + id.toString(16).padStart(3, "0") + "x".repeat(28),
    creada_en: haceMin(creadaMin),
    actualizada_en: haceMin(Math.max(2, Math.floor(rnd() * 90) + (extra.desdeAyer ? 60 * 20 : 0))),
    total_min: total,
    restante_min: restante,
    pausado: !!extra.pausa,
    resuelta: !!extra.resuelta || !!extra.cerrada,
    mensajes: hilo(nMsg, creadaMin, tecId ? tecnicos.find((t) => t.id === tecId).nombre : "", !!tecId),
    sugerencia: extra.sugerencia
      ? {
          texto:
            "Hola Ana, ya revisé la configuración de tu buzón. Te pido cerrar Outlook por completo y abrirlo otra vez; mientras tanto reinicio la sincronización desde el servidor. Si en 10 minutos no llegan los correos, me avisas por aquí.",
          confianza: 0.81,
          articulo: "KB-031",
        }
      : null,
    p1: !!extra.p1,
  };
  inc.mensajes.forEach((m) => (m.id = siguienteIdMsg++));
  incidencias.push(inc);
}
function resumenDe(cat, persona, titulo, extra) {
  const base = {
    correo: "Outlook no recibe correos nuevos desde esta mañana. Probó reiniciar la computadora y cerrar sesión. Afecta solo a esta persona; sus compañeros reciben con normalidad.",
    impresoras: "La impresora del piso no imprime y la cola de impresión queda detenida. Ya se reinició la impresora sin éxito. Afecta a todo el área.",
    vpn: "La VPN pide credenciales y vuelve a la pantalla de inicio. Probó otra red doméstica. El equipo está dentro de la política de acceso.",
    equipo: "El equipo no completa el arranque. Probó con otro cargador y dejar descargar la batería. Necesita revisión en sitio.",
    cuentas_accesos: "La persona no puede ingresar al sistema. Ya intentó el restablecimiento por autoservicio sin recibir el correo.",
    red_wifi: "La conexión se cae de forma intermitente. Afecta a varias personas de la misma zona; el resto del edificio funciona.",
    software_oficina: "La aplicación se cierra al abrir el archivo. Probó con otra copia del archivo y con el modo seguro.",
    sistema_interno: "El sistema devuelve un error al completar la operación. Ya probó con otro navegador. Hay datos pendientes que no se pueden registrar.",
    telefonia: "El anexo no recibe llamadas internas ni externas. El teléfono enciende y muestra su número.",
    otro: "Consulta general sobre un procedimiento interno.",
  }[cat];
  if (extra.largo) return "El sistema de matrícula en línea se queda cargando al registrar a los alumnos de intercambio de la Sede Arequipa. El reporte de pagos pendientes tampoco coincide con Tesorería. Probó con otro navegador sin éxito.";
  return base;
}

for (const d of MANUALES) crearInc(d);

// Generadas: ruido realista para llenar listas y filtros.
const ESTADOS_GEN = ["nueva", "asignada", "en_curso", "en_curso", "en_curso", "espera_usuario", "resuelta", "resuelta", "cerrada", "cerrada"];
for (let k = 0; k < 44; k++) {
  const id = 100 + k + (k >= 18 ? 60 : 0);
  if (incidencias.some((i) => i.id === id)) continue;
  const [cat, titulo] = elige(ASUNTOS);
  const prio = elige(["P2", "P3", "P3", "P3", "P4", "P4"]);
  const estado = elige(ESTADOS_GEN);
  const cerrada = estado === "resuelta" || estado === "cerrada";
  const tec = estado === "nueva" ? null : elige([1, 2, 2, 3, 4, 6, 7, 8]);
  const total = T_PRIO[prio];
  const restante = cerrada ? 0 : Math.round((rnd() * 1.02 - 0.03) * total);
  crearInc([
    id,
    [cat, titulo],
    entre(1, 30),
    prio,
    estado,
    tec,
    restante,
    total,
    elige(["whatsapp", "whatsapp", "web"]),
    entre(3, 15),
    { pausa: estado === "espera_usuario", resuelta: estado === "resuelta", cerrada: estado === "cerrada" },
  ]);
}
// Un asunto de 200 caracteres más, en una sin asignar (la lista debe resistirlo en cualquier columna).
crearInc([250, { cat: "red_wifi", titulo: ASUNTO_200.replace("matrícula en línea", "campus virtual") }, 13, "P3", "nueva", null, 300, 1440, "web", 3, {}]);

incidencias.sort((a, b) => b.id - a.id);

// Eventos de una incidencia (inmutables, derivados de su historia).
export function eventosDe(inc) {
  const ev = [];
  let id = inc.id * 100;
  const tec = tecnicos.find((t) => t.id === inc.tecnico_id);
  const push = (min, tipo, actor_tipo, datos = {}, actor_nombre) =>
    ev.push({ id: id++, ts: haceMin(min), tipo, actor_tipo, actor_nombre, datos });
  const edad = Math.round((AHORA0 - new Date(inc.creada_en).getTime()) / MIN);
  push(edad, "creada", "asistente", { motivo: inc.p1 ? "p1" : "guia_agotada" });
  if (tec) {
    push(edad - 1, "asignada", "sistema", { tecnico: tec.nombre });
    push(Math.max(1, edad - 6), "primera_respuesta", "tecnico", {}, tec.nombre);
  }
  if (inc.estado === "espera_usuario" || inc.estado === "espera_tercero") push(Math.max(1, Math.floor(edad / 2)), "pausa_inicio", "tecnico", { motivo: inc.estado }, tec?.nombre);
  if (inc.reaperturas) push(Math.max(1, Math.floor(edad / 3)), "reabierta", "usuario");
  if (inc.nivel !== "N1") push(Math.max(1, Math.floor(edad / 2)), "escalada", "sistema", { a: inc.nivel, motivo: "habilidad" });
  const pct = 100 - Math.round((inc.restante_min / inc.total_min) * 100);
  if (pct >= 75 && !inc.resuelta) push(Math.max(1, Math.floor((inc.total_min * 0.25 - inc.restante_min) | 0) + 1), "aviso_sla", "sistema", { porcentaje: 75 });
  if (inc.resuelta) push(Math.max(1, edad - 90), "resuelta", "tecnico", {}, tec?.nombre);
  if (inc.estado === "cerrada") push(Math.max(1, edad - 120), "cerrada", "sistema");
  return ev.sort((a, b) => new Date(a.ts) - new Date(b.ts));
}

export function memoriaDe(inc) {
  const persona = personas.find((p) => p.id === inc.persona_id);
  const por = {
    correo: ["Outlook no recibe correos nuevos", "desde esta mañana", ["Reiniciar el equipo", "Cerrar sesión y volver a entrar"]],
    impresoras: ["La impresora no imprime", "desde ayer por la tarde", ["Reiniciar la impresora", "Revisar el papel y los cables"]],
    vpn: ["La VPN no conecta", "hace dos días", ["Probar con otra red", "Reinstalar el cliente VPN"]],
    equipo: ["El equipo no enciende", "desde el lunes", ["Probar otro cargador"]],
    cuentas_accesos: ["No puede iniciar sesión", "hoy", ["Restablecer la clave por autoservicio"]],
    red_wifi: ["El wifi se cae", "esta semana", ["Olvidar la red y volver a conectar"]],
    software_oficina: ["La aplicación se cierra", "desde la actualización", ["Abrir en modo seguro"]],
    sistema_interno: ["Error al completar la operación", "desde el viernes", ["Probar con otro navegador"]],
    telefonia: ["El anexo no recibe llamadas", "hoy", []],
    otro: ["Consulta general", "hoy", []],
  }[inc.categoria];
  // La forma real del agente (ARQUITECTURA §2.2): lo que se sabe va dentro de `sabemos`; alrededor, lo que falta y la guía.
  return {
    etapa: inc.estado === "nueva" ? "incidencia" : "seguimiento",
    pendiente: inc.estado === "espera_usuario" ? "mensaje_error" : null,
    categoria: inc.categoria,
    sabemos: {
      sintoma: por[0],
      aplicacion: inc.categoria === "correo" ? "Outlook" : inc.categoria === "software_oficina" ? "Excel" : undefined,
      mensaje_error: inc.categoria === "vpn" ? "Error 809" : "sin mensaje",
      desde: por[1],
      equipo: persona.equipos[0],
      sede: persona.sede,
      area: persona.area,
      impacto: inc.impacto,
      urgencia: inc.urgencia,
      pasos_probados: por[2],
    },
    articulos_mostrados: articulos.filter((a) => a.categoria === inc.categoria).slice(0, 2).map((a) => a.clave),
    intentos_guia: por[2].length ? 1 : 0,
    incidencia: inc.numero,
    preguntado: ["que_pasa", "desde", "equipo"],
  };
}

// Conversaciones -----------------------------------------------------------------------------------------------
export const casos = [];
(function () {
  const textos = [
    "No me abre el correo desde ayer",
    "Quiero saber cómo va mi ticket",
    "Olvidé mi contraseña del campus",
    "La impresora no imprime, ya la reinicié",
    "¿Pueden darme acceso a la carpeta de ventas?",
    "Ya funcionó, gracias",
    "Hola",
    "¿Dónde pido un mouse nuevo?",
    "Mi wifi se corta cada rato",
    "No puedo entrar a la VPN",
    "Necesito hablar con un técnico, es urgente",
    "Me llegó un correo raro, ¿es peligroso?",
    "Se congela el sistema de facturación",
    "Gracias por la ayuda",
  ];
  const etapas = ["diagnostico", "guia", "incidencia", "seguimiento", "recepcion", "cierre", "recepcion", "diagnostico", "guia", "incidencia", "incidencia", "diagnostico", "incidencia", "encuesta"];
  textos.forEach((t, i) => {
    const incs = [142, 139, null, 144, 145, null, null, 131, 132, 137, 143, null, 140, 129];
    const num = incs[i] ? "INC-" + String(incs[i]).padStart(6, "0") : null;
    casos.push({
      id: 900 + i,
      canal: i % 3 === 0 ? "web" : "whatsapp",
      persona_id: i + 1,
      etapa: etapas[i],
      estado: num ? "con_incidencia" : i === 5 || i === 13 ? "resuelto_asistente" : "abierto",
      pausado_por_tecnico: i === 10,
      tomado_por: i === 10 ? "Rodrigo Echevarría" : null,
      inicio: haceMin(30 + i * 47),
      ultimo_mensaje: haceMin(2 + i * 11),
      ultimo_texto: t,
      incidencia_numero: num,
      mensajes: hilo(3 + (i % 6), 30 + i * 47, "Rodrigo Echevarría", false).map((m, j) => (j === 0 ? { ...m, texto: t } : m)),
    });
  });
  casos.forEach((c) => c.mensajes.forEach((m) => (m.id = siguienteIdMsg++)));
})();

// Conocimiento ---------------------------------------------------------------------------------------------------
export const articulos = [
  ["KB-001", "Restablecer la contraseña del correo", "cuentas_accesos", ["no recuerdo mi contraseña", "olvidé la clave del correo"], ["Entra a la página de autoservicio.", "Elige «Olvidé mi contraseña».", "Sigue el enlace que llega a tu correo alterno.", "Crea una clave nueva con 12 caracteres."], "publicado", false],
  ["KB-012", "Cuenta bloqueada tras varios intentos", "cuentas_accesos", ["cuenta bloqueada", "demasiados intentos"], ["Espera 15 minutos: el bloqueo se levanta solo.", "Si sigue bloqueada, un técnico la desbloquea desde el directorio."], "publicado", false],
  ["KB-031", "Outlook no recibe correos nuevos", "correo", ["no llegan correos", "outlook no sincroniza", "bandeja no actualiza"], ["Cierra Outlook por completo desde el Administrador de tareas.", "Ábrelo otra vez y espera dos minutos.", "Si sigue igual, elimina el perfil y créalo de nuevo.", "Comprueba que el buzón no esté lleno."], "publicado", false],
  ["KB-032", "Buzón lleno", "correo", ["buzón lleno", "no puedo enviar correos"], ["Vacía la carpeta Elementos eliminados.", "Archiva los correos de más de un año.", "Pide ampliar la cuota si trabajas con adjuntos grandes."], "publicado", true],
  ["KB-044", "La impresora no imprime", "impresoras", ["impresora no imprime", "cola de impresión detenida"], ["Comprueba que la impresora esté encendida y con papel.", "Cancela los trabajos de la cola de impresión.", "Reinicia el servicio de cola de impresión.", "Reinstala el controlador si el error continúa."], "publicado", false],
  ["KB-045", "Atasco de papel", "impresoras", ["atasco", "papel atascado"], ["Apaga la impresora.", "Abre las tapas y retira el papel en el sentido del recorrido.", "No uses herramientas metálicas."], "publicado", true],
  ["KB-052", "Conectarse a la VPN desde casa", "vpn", ["no puedo conectarme a la vpn", "vpn pide credenciales"], ["Comprueba que tengas internet sin la VPN.", "Cierra el cliente VPN y ábrelo con permisos de administrador.", "Usa tu usuario completo con el dominio.", "Si el error es 809, pide al técnico abrir el puerto."], "publicado", false],
  ["KB-060", "El wifi se corta", "red_wifi", ["wifi se cae", "internet intermitente"], ["Olvida la red y vuelve a conectar.", "Acércate al punto de acceso más cercano.", "Prueba con el cable de red si el equipo lo permite."], "publicado", false],
  ["KB-070", "Excel se cierra al abrir un archivo", "software_oficina", ["excel se cierra", "excel deja de funcionar"], ["Abre Excel en modo seguro (mantén Ctrl al abrirlo).", "Desactiva los complementos.", "Repara Office desde Panel de control."], "publicado", false],
  ["KB-081", "Solicitar un equipo o periférico", "equipo", ["necesito un mouse", "solicito monitor", "pedir equipo"], ["Registra la solicitud con el nombre del equipo y el motivo.", "Tu jefatura debe aprobarla.", "Almacén entrega en 3 días hábiles."], "publicado", true],
  ["KB-090", "Error al emitir facturas", "sistema_interno", ["error al emitir facturas", "factura no se emite"], ["Revisa que el certificado digital esté vigente.", "Comprueba la fecha y hora del equipo.", "Si el error continúa, escala a Sistemas internos."], "borrador", true],
  ["KB-095", "Teléfono sin tono", "telefonia", ["anexo no funciona", "teléfono sin tono"], ["Revisa el cable del teléfono y del puerto.", "Reinicia el aparato desconectándolo 10 segundos."], "publicado", true],
  ["KB-099", "Procedimiento de baja de equipos", "otro", ["baja de equipos", "dar de baja una laptop"], ["Solicita la baja con el formato de Almacén.", "Entrega el equipo con su cargador.", "Sistemas borra el disco y lo registra."], "archivado", true],
].map(([clave, titulo, categoria, sintomas, pasos, estado, supuesto], i) => ({
  id: i + 1,
  clave,
  titulo,
  categoria,
  sintomas,
  pasos,
  cuerpo: "",
  estado,
  supuesto,
  version: 1 + (i % 3),
  actualizado_en: haceMin(60 * 24 * (i + 1) * 3),
  usos: [86, 21, 142, 12, 97, 8, 64, 71, 38, 22, 5, 9, 0][i],
  resolvio_pct: [74, 66, 81, 58, 69, 50, 72, 61, 70, 64, null, 55, null][i],
}));

// Reglas de escalamiento -------------------------------------------------------------------------------------
// Las claves y las acciones son las del motor: el SLA se parte por métrica (respuesta/resolución) y el porcentaje viaja como
// `umbral_pct` (la pasarela lo copia también a `condicion.porcentaje`, que es el nombre que edita la consola).
export const reglas = [
  { id: 1, clave: "sla_75_respuesta", version: 1, activa: true, modo: "activo", descripcion: "Aviso al técnico al 75 % del plazo de primera respuesta", condicion: { umbral_pct: 75, porcentaje: 75, metrica: "respuesta" }, acciones: [{ tipo: "avisar_tecnico" }], disparos_7d: 22 },
  { id: 2, clave: "sla_75_resolucion", version: 1, activa: true, modo: "activo", descripcion: "Aviso al técnico al 75 % del plazo de resolución", condicion: { umbral_pct: 75, porcentaje: 75, metrica: "resolucion" }, acciones: [{ tipo: "avisar_tecnico" }], disparos_7d: 41 },
  { id: 3, clave: "sla_100_respuesta", version: 1, activa: true, modo: "sombra", descripcion: "Escalamiento y aviso al responsable al vencer la primera respuesta", condicion: { umbral_pct: 100, porcentaje: 100, metrica: "respuesta" }, acciones: [{ tipo: "escalar_nivel" }, { tipo: "avisar_responsable" }], disparos_7d: 4 },
  { id: 4, clave: "sla_100_resolucion", version: 2, activa: true, modo: "sombra", descripcion: "Escalamiento y aviso al responsable al vencer la resolución", condicion: { umbral_pct: 100, porcentaje: 100, metrica: "resolucion" }, acciones: [{ tipo: "escalar_nivel" }, { tipo: "avisar_responsable" }], disparos_7d: 9 },
  { id: 5, clave: "p1_creada", version: 1, activa: true, modo: "activo", descripcion: "Aviso a la guardia y al supervisor cuando se crea una P1", condicion: { prioridad: "P1" }, acciones: [{ tipo: "avisar_guardia" }, { tipo: "avisar_supervisor" }], disparos_7d: 2 },
  { id: 6, clave: "reapertura_2", version: 1, activa: true, modo: "sombra", descripcion: "Escalamiento y aviso al supervisor a la segunda reapertura", condicion: { reaperturas: 2 }, acciones: [{ tipo: "escalar_nivel" }, { tipo: "avisar_supervisor" }], disparos_7d: 3 },
  { id: 7, clave: "queja", version: 1, activa: true, modo: "sombra", descripcion: "Aviso al supervisor ante una queja o ánimo muy negativo", condicion: { senal: "queja" }, acciones: [{ tipo: "avisar_supervisor" }], disparos_7d: 5 },
  { id: 8, clave: "vip", version: 1, activa: false, modo: "sombra", descripcion: "Aviso al supervisor cuando la persona es VIP", condicion: { vip: true }, acciones: [{ tipo: "avisar_supervisor" }], disparos_7d: 0 },
  { id: 9, clave: "guia_agotada", version: 1, activa: true, modo: "activo", descripcion: "Nota cuando el asistente agotó la guía antes de abrir la incidencia", condicion: { motivo: "guia_agotada" }, acciones: [{ tipo: "nota" }], disparos_7d: 63 },
];

// Configuración -------------------------------------------------------------------------------------------------
export const calendarios = [
  {
    id: 1,
    nombre: "Horario de oficina",
    zona: "America/Lima",
    veinticuatro_siete: false,
    horario: {
      1: [["08:30", "13:00"], ["14:00", "18:00"]],
      2: [["08:30", "13:00"], ["14:00", "18:00"]],
      3: [["08:30", "13:00"], ["14:00", "18:00"]],
      4: [["08:30", "13:00"], ["14:00", "18:00"]],
      5: [["08:30", "13:00"], ["14:00", "17:00"]],
      6: [],
      7: [],
    },
    feriados: [
      { fecha: "2026-10-08", nombre: "Combate de Angamos" },
      { fecha: "2026-11-01", nombre: "Día de Todos los Santos" },
      { fecha: "2026-12-08", nombre: "Inmaculada Concepción" },
      { fecha: "2026-12-25", nombre: "Navidad" },
    ],
  },
  { id: 2, nombre: "Guardia 24 × 7", zona: "America/Lima", veinticuatro_siete: true, horario: {}, feriados: [] },
];

export const politicasSla = [
  { id: 1, prioridad: "P1", categoria: null, calendario_id: 2, respuesta_min: 15, resolucion_min: 120 },
  { id: 2, prioridad: "P2", categoria: null, calendario_id: 1, respuesta_min: 60, resolucion_min: 480 },
  { id: 3, prioridad: "P3", categoria: null, calendario_id: 1, respuesta_min: 240, resolucion_min: 1440 },
  { id: 4, prioridad: "P4", categoria: null, calendario_id: 1, respuesta_min: 480, resolucion_min: 2880 },
  { id: 5, prioridad: "P2", categoria: "vpn", calendario_id: 1, respuesta_min: 30, resolucion_min: 360 },
];

const MAT = {
  persona: { baja: "P4", media: "P4", alta: "P3", critica: "P2" },
  area: { baja: "P4", media: "P3", alta: "P2", critica: "P1" },
  sede: { baja: "P3", media: "P2", alta: "P1", critica: "P1" },
  organizacion: { baja: "P2", media: "P1", alta: "P1", critica: "P1" },
};
export const matriz = Object.entries(MAT).flatMap(([impacto, u]) => Object.entries(u).map(([urgencia, prioridad]) => ({ impacto, urgencia, prioridad })));

export const usuarios = [
  { id: 1, email: "admin@jsr.test", nombre: "Rodrigo Echevarría Lazo", rol: "admin", tecnico_id: 1, activo: true, clave: "jsr123" },
  { id: 2, email: "tecnico@jsr.test", nombre: "Luis Paz Medina", rol: "tecnico", tecnico_id: 2, activo: true, clave: "jsr123" },
  { id: 3, email: "supervisor@jsr.test", nombre: "Karina Soto Ramírez", rol: "supervisor", tecnico_id: 3, activo: true, clave: "jsr123" },
  { id: 4, email: "gerencia@jsr.test", nombre: "Marcela Ugarte Benites", rol: "gerencia", tecnico_id: null, activo: true, clave: "jsr123" },
  { id: 5, email: "entrenador@jsr.test", nombre: "Hugo Sandoval Reyes", rol: "entrenador", tecnico_id: null, activo: true, clave: "jsr123" },
  { id: 6, email: "exusuario@jsr.test", nombre: "Pedro Aliaga (ya no trabaja aquí)", rol: "tecnico", tecnico_id: null, activo: false, clave: "jsr123" },
];

export const asistenteConfig = {
  nombre: "Asistente de la mesa de ayuda",
  trato: "tu",
  saludo: "Hola, soy el asistente de la mesa de ayuda. Cuéntame qué está pasando y lo revisamos juntos.",
  umbral_confianza: 0.7,
  maximo_pasos_guia: 4,
  juez_modo: "sombra",
  puede: { crear_incidencias: true, consultar_estado: true, pedir_encuesta: true, resolver_clave: false },
};

// Entrenamiento -------------------------------------------------------------------------------------------------
const INTENCIONES = ["reportar_falla", "solicitar_acceso", "solicitar_equipo", "restablecer_clave", "consultar_estado", "aportar_dato", "confirmar_solucion", "sigue_igual", "pedir_tecnico", "queja", "agradecer", "saludo", "fuera_de_alcance"];
const FRASES_COLA = [
  ["no me carga la cosa esa del correo", "fuera_de_alcance", 0.34, "baja_confianza"],
  ["necesito que me den permiso pa la carpeta de ventas", "solicitar_equipo", 0.41, "baja_confianza"],
  ["ya me cansé, es la tercera vez que falla el wifi", "reportar_falla", 0.58, "pulgar_abajo"],
  ["mi clave no entra", "reportar_falla", 0.49, "baja_confianza"],
  ["¿y mi caso? nadie me contesta", "queja", 0.55, "correccion_tecnico"],
  ["lo de ayer sigue", "aportar_dato", 0.46, "reapertura"],
  ["pásame con alguien por favor", "saludo", 0.37, "baja_confianza"],
  ["el sistema se pone lentísimo", "reportar_falla", 0.62, "pulgar_abajo"],
  ["necesito instalar el zoom", "solicitar_equipo", 0.52, "baja_confianza"],
  ["sigue sin imprimir pero ya reinicié todo", "sigue_igual", 0.66, "reapertura"],
  ["gracias, quedó ok", "agradecer", 0.88, "pulgar_abajo"],
  ["me bloquearon la cuenta", "restablecer_clave", 0.5, "correccion_tecnico"],
  ["¿a qué hora atienden?", "fuera_de_alcance", 0.44, "baja_confianza"],
  ["el correo que le mandé no le llega a mi jefe", "reportar_falla", 0.59, "baja_confianza"],
  ["hola buenas, una consulta nomás", "saludo", 0.71, "baja_confianza"],
  ["no puedo ver el calendario compartido", "reportar_falla", 0.53, "pulgar_abajo"],
  ["quiero cambiar mi laptop que ya está vieja y lenta y además la batería no dura nada y el ventilador hace mucho ruido", "solicitar_equipo", 0.57, "baja_confianza"],
  ["asdf jkl", "fuera_de_alcance", 0.2, "baja_confianza"],
];
export const cola = FRASES_COLA.map(([texto, intencion_modelo, confianza, motivo], i) => ({
  id: i + 1,
  mensaje_id: 7000 + i,
  texto,
  intencion_modelo,
  confianza,
  motivo,
  estado: "pendiente",
  ts: haceMin(30 + i * 190),
  caso_id: 900 + (i % 14),
  intencion_correcta: null,
}));
export { INTENCIONES };

export const modelos = [
  { version: "v1.3", exactitud: 0.921, macro_f1: 0.904, estado: "publicado", creado_en: haceMin(60 * 24 * 6), ejemplos: 1840 },
  { version: "v1.2", exactitud: 0.907, macro_f1: 0.889, estado: "retirado", creado_en: haceMin(60 * 24 * 21), ejemplos: 1702 },
  { version: "v1.1", exactitud: 0.884, macro_f1: 0.861, estado: "retirado", creado_en: haceMin(60 * 24 * 40), ejemplos: 1511 },
];

// Reportes guardados -----------------------------------------------------------------------------------------
export const reportes = [
  { id: 1, nombre: "MTTR por categoría", descripcion: "Tiempo de resolución medio por categoría, por mes", golden: "mttr_por_categoria", programado: "Lunes 08:00 · gerencia@empresa.pe" },
  { id: 2, nombre: "Cumplimiento de SLA por grupo", descripcion: "Porcentaje de incidencias dentro del plazo", golden: "sla_cumplimiento", programado: null },
  { id: 3, nombre: "Contención del asistente", descripcion: "Casos resueltos sin abrir incidencia", golden: "contencion_asistente", programado: "1.er día del mes · gerencia@empresa.pe" },
  { id: 4, nombre: "Incidencias abiertas con más de 7 días", descripcion: "Pendientes y su antigüedad por técnico", golden: "pendientes_antiguedad", programado: null },
  { id: 5, nombre: "CSAT por técnico", descripcion: "Satisfacción de las encuestas de cierre", golden: "csat", programado: null },
  { id: 6, nombre: "Reaperturas por categoría", descripcion: "Incidencias reabiertas y su causa", golden: null, programado: null },
];

// Indicadores: 12 semanas por KPI ------------------------------------------------------------------------------
function serie(base, ruido, tendencia, dec = 1) {
  const r = mulberry32(base * 1000);
  return Array.from({ length: 12 }, (_, i) => Math.round((base + (i - 11) * tendencia + (r() - 0.5) * ruido) * 10 ** dec) / 10 ** dec);
}
const semanas = Array.from({ length: 12 }, (_, i) => {
  const d = new Date(AHORA0 - (11 - i) * 7 * 86400000);
  const y = d.getUTCFullYear();
  const onejan = new Date(Date.UTC(y, 0, 1));
  const w = Math.ceil(((d - onejan) / 86400000 + onejan.getUTCDay() + 1) / 7);
  return `${y}-S${String(w).padStart(2, "0")}`;
});

export const KPIS = [
  {
    kpi: "sla_cumplimiento",
    version: 3,
    titulo: "Cumplimiento de SLA",
    unidad: "%",
    meta: 90,
    sentido: "mayor_mejor",
    base: 92.4,
    ruido: 4,
    tendencia: 0.25,
    definicion: "Porcentaje de incidencias resueltas dentro del plazo de resolución de su prioridad, sobre las resueltas del periodo. Se miden minutos laborales y se descuentan las pausas por espera del usuario o de un tercero.",
    sql: "SELECT toStartOfWeek(resuelta_en) AS periodo,\n       round(100 * avg(sla_resolucion_ok), 1) AS valor\nFROM incidencias_tiempos FINAL\nWHERE resuelta_en BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY periodo ORDER BY periodo",
  },
  {
    kpi: "primera_respuesta",
    version: 2,
    titulo: "Tiempo de primera respuesta",
    unidad: "min",
    meta: 30,
    sentido: "menor_mejor",
    base: 22,
    ruido: 8,
    tendencia: -0.4,
    definicion: "Mediana de minutos laborales entre que se crea la incidencia y la primera respuesta de una persona (no cuenta el asistente).",
    sql: "SELECT toStartOfWeek(creada_en) AS periodo,\n       round(quantile(0.5)(frt_min), 1) AS valor\nFROM incidencias_tiempos FINAL\nWHERE creada_en BETWEEN {desde:Date} AND {hasta:Date} AND frt_min IS NOT NULL\nGROUP BY periodo ORDER BY periodo",
  },
  {
    kpi: "mttr",
    version: 3,
    titulo: "Tiempo de resolución (MTTR)",
    unidad: "h",
    meta: 8,
    sentido: "menor_mejor",
    base: 9.6,
    ruido: 2.5,
    tendencia: 0.12,
    definicion: "Promedio de horas laborales entre la creación y la resolución, sin contar las pausas. Solo incidencias resueltas en el periodo.",
    sql: "SELECT toStartOfWeek(resuelta_en) AS periodo,\n       round(avg(mttr_min) / 60, 1) AS valor\nFROM incidencias_tiempos FINAL\nWHERE resuelta_en BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY periodo ORDER BY periodo",
  },
  {
    kpi: "primer_contacto",
    version: 1,
    titulo: "Resolución al primer contacto",
    unidad: "%",
    meta: 70,
    sentido: "mayor_mejor",
    base: 64,
    ruido: 6,
    tendencia: -0.2,
    definicion: "Porcentaje de incidencias resueltas por el primer técnico, sin escalamiento ni reapertura.",
    sql: "SELECT toStartOfWeek(resuelta_en) AS periodo,\n       round(100 * avg(primer_contacto), 1) AS valor\nFROM incidencias_tiempos FINAL\nWHERE resuelta_en BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY periodo ORDER BY periodo",
  },
  {
    kpi: "contencion_asistente",
    version: 2,
    titulo: "Contención del asistente",
    unidad: "%",
    meta: 45,
    sentido: "mayor_mejor",
    base: 51,
    ruido: 5,
    tendencia: 0.5,
    definicion: "Casos resueltos por el asistente sin abrir incidencia y confirmados por la persona, sobre el total de casos del periodo.",
    sql: "SELECT toStartOfWeek(inicio) AS periodo,\n       round(100 * countIf(NOT tiene_incidencia AND confirmado_resuelto) / count(), 1) AS valor\nFROM casos_estado FINAL\nWHERE inicio BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY periodo ORDER BY periodo",
  },
  {
    kpi: "csat",
    version: 1,
    titulo: "Satisfacción (CSAT)",
    unidad: "/ 5",
    meta: 4.2,
    sentido: "mayor_mejor",
    base: 4.4,
    ruido: 0.4,
    tendencia: 0.01,
    definicion: "Promedio de puntaje (1 a 5) de las encuestas contestadas al cerrar la incidencia. Excluye encuestas sin puntaje.",
    sql: "SELECT toStartOfWeek(ts) AS periodo, round(avg(puntaje), 2) AS valor\nFROM encuestas\nWHERE ts BETWEEN {desde:Date} AND {hasta:Date}\nGROUP BY periodo ORDER BY periodo",
  },
  {
    kpi: "pendientes_antiguedad",
    version: 2,
    titulo: "Pendientes con más de 7 días",
    unidad: "incidencias",
    meta: 5,
    sentido: "menor_mejor",
    base: 14,
    ruido: 3,
    tendencia: 0.5,
    definicion: "Cantidad de incidencias abiertas (no resueltas ni cerradas) con más de 7 días desde su creación, al final de cada semana.",
    sql: "SELECT toStartOfWeek(snapshot) AS periodo, count() AS valor\nFROM incidencias_abiertas_diarias\nWHERE snapshot BETWEEN {desde:Date} AND {hasta:Date} AND dias_abierta > 7\nGROUP BY periodo ORDER BY periodo",
  },
].map((k) => {
  const valores = serie(k.base, k.ruido, k.tendencia).map((v) => (k.unidad === "incidencias" ? Math.max(0, Math.round(v)) : v));
  return { ...k, valores, semanas };
});

// Calidad del asistente ------------------------------------------------------------------------------------------
export const calidad = {
  semanas,
  confianza_media: serie(0.78, 0.05, 0.004, 3),
  pulgar_abajo_pct: serie(7.5, 2, -0.2),
  contencion_pct: serie(48, 5, 0.4),
};
