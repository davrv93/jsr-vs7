import type { Rol } from "./auth";
import type { IconoNombre } from "~/components/ui/icono";

// Mapa de la consola: qué rol entra a qué sección (CONTRATOS.md §2). admin entra a todo.

export interface Ruta {
  ruta: string;
  titulo: string;
  icono: IconoNombre;
  roles: Rol[];
  /** Bloque del lateral (DISENO §1): 1 trabajo, 2 equipo, 3 datos y ajustes. */
  bloque: 1 | 2 | 3;
  lateral: boolean;
}

const TODOS: Rol[] = ["tecnico", "supervisor", "gerencia", "entrenador", "admin"];

export const RUTAS: Ruta[] = [
  { ruta: "/bandeja", titulo: "Bandeja", icono: "bandeja", roles: ["tecnico", "supervisor", "gerencia", "admin"], bloque: 1, lateral: true },
  { ruta: "/incidencias", titulo: "Incidencias", icono: "lista", roles: ["tecnico", "supervisor", "gerencia", "admin"], bloque: 1, lateral: true },
  { ruta: "/conversaciones", titulo: "Conversaciones", icono: "chat", roles: ["tecnico", "supervisor", "gerencia", "entrenador", "admin"], bloque: 1, lateral: true },
  { ruta: "/equipo", titulo: "Equipo", icono: "equipo", roles: ["supervisor", "gerencia", "admin"], bloque: 2, lateral: true },
  { ruta: "/escalamiento", titulo: "Escalamiento", icono: "escalar", roles: ["supervisor", "gerencia", "admin"], bloque: 2, lateral: true },
  { ruta: "/indicadores", titulo: "Indicadores", icono: "grafico", roles: ["gerencia", "admin"], bloque: 3, lateral: true },
  { ruta: "/reportes", titulo: "Reportes", icono: "reporte", roles: ["gerencia", "admin"], bloque: 3, lateral: true },
  { ruta: "/asistente", titulo: "Asistente", icono: "libro", roles: ["entrenador", "admin"], bloque: 3, lateral: true },
  { ruta: "/ajustes", titulo: "Ajustes", icono: "ajustes", roles: TODOS, bloque: 3, lateral: true },
  { ruta: "/mas", titulo: "Más", icono: "mas", roles: TODOS, bloque: 3, lateral: false },
];

export const puede = (rol: Rol | undefined, roles: Rol[]): boolean => !!rol && (rol === "admin" || roles.includes(rol));

export const rutaDe = (pathname: string): Ruta | undefined => {
  const p = pathname.replace(/\/+$/, "") || "/";
  return RUTAS.filter((r) => p === r.ruta || p.startsWith(r.ruta + "/")).sort((a, b) => b.ruta.length - a.ruta.length)[0];
};

export const inicioPara = (rol: Rol | undefined): string => {
  if (rol === "gerencia") return "/indicadores";
  if (rol === "entrenador") return "/asistente/entrenamiento";
  return "/bandeja";
};

/** Pestañas de la barra inferior en móvil: hasta 4 de estas, según el rol, y siempre «Más». */
export const PESTANAS_MOVIL = ["/bandeja", "/incidencias", "/indicadores", "/asistente", "/conversaciones", "/equipo"];
