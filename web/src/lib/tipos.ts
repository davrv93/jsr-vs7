// Formas de las respuestas de la API de la consola. Salen de docs/CONTRATOS.md §2 y del esquema de Postgres;
// lo que el contrato no fijaba está anotado en CONTRATOS.md «Cambios» (propuesta de la UI al backend).

export type Prioridad = "P1" | "P2" | "P3" | "P4";
export type Estado =
  | "nueva"
  | "asignada"
  | "en_curso"
  | "espera_usuario"
  | "espera_tercero"
  | "resuelta"
  | "cerrada"
  | "reabierta";
export type Impacto = "persona" | "area" | "sede" | "organizacion";
export type Urgencia = "baja" | "media" | "alta" | "critica";

export interface Sla {
  /** Porcentaje del plazo de resolución consumido (puede pasar de 100). */
  porcentaje: number;
  /** Minutos laborales que quedan; negativo si ya venció. */
  restante_min: number;
  vencida: boolean;
  pausado?: boolean;
}

export interface PersonaRef {
  id: number;
  nombre: string;
  area?: string;
  sede?: string;
}

export interface TecnicoRef {
  id: number;
  nombre: string;
}

/** Fila de lista: bandeja, incidencias. */
export interface IncResumen {
  id: number;
  numero: string;
  titulo: string;
  prioridad: Prioridad;
  estado: Estado;
  categoria: string;
  canal: string;
  persona: PersonaRef | null;
  tecnico: TecnicoRef | null;
  grupo: string | null;
  creada_en: string;
  actualizada_en: string;
  vence_resolucion_en: string | null;
  sla: Sla | null;
}

export interface Bandeja {
  vencen_pronto: IncResumen[];
  mias: IncResumen[];
  sin_asignar: IncResumen[];
  contador: number;
  /** Lo siguiente que pide atención cuando nada vence: «2 esperan respuesta del usuario desde ayer». */
  espera_usuario?: { cantidad: number; desde: string | null };
}

export interface Lista<T> {
  items: T[];
  total: number;
}

export interface EventoInc {
  id: number;
  ts: string;
  tipo: string;
  actor_tipo: "usuario" | "tecnico" | "asistente" | "sistema";
  actor_nombre?: string;
  datos: Record<string, unknown>;
}

export interface MensajeCaso {
  id: number;
  ts: string;
  rol: "usuario" | "asistente" | "tecnico" | "sistema";
  autor?: string;
  texto: string;
  interno?: boolean;
  meta?: {
    intencion?: string;
    confianza?: number;
    categoria?: string;
    latencia_ms?: number;
    articulos?: string[];
  };
}

export interface Veredicto {
  ts: string;
  modo: "sombra" | "activo";
  tipo: string;
  veredicto: string;
  confianza: number;
  detalle?: string;
}

export interface PersonaDetalle extends PersonaRef {
  correo?: string;
  whatsapp?: string;
  vip?: boolean;
  equipos?: string[];
}

export interface ArticuloRef {
  clave: string;
  titulo: string;
  resultado?: "resolvio" | "sigue_igual" | "sin_respuesta" | null;
}

export interface IncDetalle extends IncResumen {
  resumen: string;
  tipo: string;
  impacto: Impacto;
  urgencia: Urgencia;
  nivel: string;
  reaperturas: number;
  escalamientos: number;
  token_publico: string;
  persona_detalle: PersonaDetalle | null;
  eventos: EventoInc[];
  mensajes: Lista<MensajeCaso>;
  memoria: Record<string, unknown>;
  clasificacion: { intencion: string; confianza: number; categoria: string; categoria_confianza: number } | null;
  veredictos: Veredicto[];
  articulos: ArticuloRef[];
  sugerencia: { texto: string; confianza: number; articulo?: string } | null;
}

export interface Caso {
  id: number;
  canal: "whatsapp" | "web";
  persona: PersonaRef | null;
  etapa: string;
  estado: "abierto" | "resuelto_asistente" | "con_incidencia" | "cerrado";
  pausado_por_tecnico: boolean;
  tomado_por?: string | null;
  inicio: string;
  ultimo_mensaje: string;
  ultimo_texto: string;
  incidencia_numero: string | null;
  mensajes_total: number;
}

export interface Habilidad {
  categoria: string;
  nivel: 1 | 2 | 3;
}

export interface Turno {
  dia_semana: number;
  desde: string;
  hasta: string;
}

export interface Tecnico {
  id: number;
  nombre: string;
  nivel: "N1" | "N2" | "N3";
  estado: "activo" | "ausente" | "inactivo";
  capacidad: number;
  carga: number;
  correo?: string;
  whatsapp?: string;
  foto?: string | null;
  grupos: { id: number; nombre: string }[];
  habilidades: Habilidad[];
  turnos: Turno[];
  ausencia?: { desde: string; hasta: string; motivo?: string } | null;
  rendimiento?: { resueltas_30d: number; sla_cumplido_pct: number | null; primera_respuesta_mediana_min: number | null };
}

export interface Grupo {
  id: number;
  nombre: string;
  nivel: "N1" | "N2" | "N3";
  escala_a_grupo_id: number | null;
  responsable_tecnico_id: number | null;
  miembros: number[];
}

export interface Categoria {
  id: number;
  clave: string;
  nombre: string;
  grupo_id: number | null;
  activa: boolean;
}

export interface PoliticaSla {
  id: number;
  prioridad: Prioridad;
  categoria: string | null;
  calendario_id: number;
  respuesta_min: number;
  resolucion_min: number;
}

export interface Calendario {
  id: number;
  nombre: string;
  zona: string;
  veinticuatro_siete: boolean;
  horario: Record<string, [string, string][]>;
  feriados: { fecha: string; nombre: string }[];
}

export interface CeldaMatriz {
  impacto: Impacto;
  urgencia: Urgencia;
  prioridad: Prioridad;
}

export interface ReglaEscalamiento {
  id: number;
  clave: string;
  version: number;
  activa: boolean;
  modo: "sombra" | "activo";
  descripcion: string;
  condicion: Record<string, unknown>;
  /** Porcentaje del plazo en que dispara. El motor lo guarda como `umbral_pct`; la pasarela también lo copia a `condicion.porcentaje`. */
  umbral_pct?: number | null;
  acciones: { tipo: string }[];
  disparos_7d?: number;
}

export interface UsuarioConsola {
  id: number;
  email: string;
  nombre: string;
  rol: "tecnico" | "supervisor" | "gerencia" | "entrenador" | "admin";
  activo: boolean;
}

export interface Articulo {
  id: number;
  clave: string;
  titulo: string;
  categoria: string | null;
  sintomas: string[];
  pasos: string[];
  cuerpo: string;
  estado: "borrador" | "publicado" | "archivado";
  supuesto: boolean;
  version: number;
  actualizado_en: string;
  usos?: number;
  resolvio_pct?: number | null;
}

export interface ItemCola {
  id: number;
  mensaje_id: number;
  texto: string;
  intencion_modelo: string;
  confianza: number;
  motivo: "baja_confianza" | "pulgar_abajo" | "correccion_tecnico" | "reapertura";
  estado: "pendiente" | "confirmada" | "corregida" | "descartada";
  ts: string;
  caso_id: number | null;
  intencion_correcta?: string | null;
}

export interface ModeloIA {
  version: string;
  exactitud: number;
  macro_f1: number;
  estado: "candidato" | "publicado" | "retirado";
  creado_en: string;
  ejemplos?: number;
}

export interface EstadoEntrenamiento {
  publicado: ModeloIA;
  candidato: ModeloIA | null;
  fase: "ninguno" | "entrenando" | "listo";
  cambios_pendientes: number;
  progreso?: number;
}

export interface Calidad {
  semanas: string[];
  confianza_media: number[];
  pulgar_abajo_pct: number[];
  contencion_pct: number[];
  modelos: ModeloIA[];
}

export interface ConfigAsistente {
  nombre: string;
  trato: "tu" | "usted";
  saludo: string;
  umbral_confianza: number;
  maximo_pasos_guia: number;
  juez_modo: "apagado" | "sombra" | "activo";
  puede: { crear_incidencias: boolean; consultar_estado: boolean; pedir_encuesta: boolean; resolver_clave: boolean };
}

export interface KpiResultado {
  kpi: string;
  version: number;
  titulo: string;
  definicion: string;
  sql: string;
  unidad: string;
  valor: number | null;
  meta: number | null;
  sentido: "mayor_mejor" | "menor_mejor";
  /** Serie semanal más reciente al final: 12 puntos. */
  filas: { periodo: string; valor: number | null }[];
  pide_accion?: boolean;
  detalle?: string;
}

export interface Indicadores {
  desde: string;
  hasta: string;
  kpis: KpiResultado[];
}

export interface RespuestaReporte {
  pregunta: string;
  golden: { kpi: string; nombre: string; version: number } | null;
  verificado: boolean;
  sql: string;
  resumen: string;
  unidad?: string;
  columnas: string[];
  filas: (string | number | null)[][];
  nota?: string;
}

export interface ReporteGuardado {
  id: number;
  nombre: string;
  descripcion: string;
  golden: string | null;
  programado: string | null;
}

export interface RespuestaChat {
  respuesta: string | null;
  mensajes?: string[];
  botones?: string[];
  incidencia?: { numero: string } | null;
  analisis: {
    etapa: string;
    memoria: Record<string, unknown>;
    intencion: string;
    confianza: number;
    categoria: string | null;
    categoria_confianza: number | null;
    accion: { tipo: string; numero?: string; puntaje?: number; incidencia?: Record<string, unknown> } | null;
    articulos_usados: { clave: string; titulo: string; fuente?: string }[];
    senales: { animo: string; queja: boolean; pide_tecnico: boolean; contrasena_oculta: boolean };
    juez: { modo: string; veredictos: Record<string, unknown> };
    latencia_ms: number;
  };
}

export interface EstadoPublico {
  numero: string;
  titulo: string;
  estado: Estado;
  estado_texto: string;
  tecnico: string | null;
  prioridad: Prioridad;
  vence_resolucion_en: string | null;
  sla_texto?: string;
  creada_en: string;
  ultimo_mensaje_tecnico: { ts: string; texto: string; autor: string } | null;
  puede_responder: boolean;
}
