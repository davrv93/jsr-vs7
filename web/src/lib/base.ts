// Ruta base de la consola: "/" con dominio propio o, p. ej., "/jsrbot/" detrás de un alias de nginx.
// La fija BASE_PATH al compilar (vite.config.ts → base).
export const BASE = import.meta.env.BASE_URL.replace(/\/$/, "");

/** Origen de la API. Vacío = mismo origen (nginx hace proxy de /api). Para apuntar al backend real sin tocar
 *  código: VITE_API_BASE=https://jsr.ejemplo.pe al compilar o al arrancar `npm run dev`. */
export const API_BASE: string = ((import.meta.env.VITE_API_BASE as string | undefined) ?? "").replace(/\/$/, "");

/** Antepone la ruta base a una ruta absoluta del sitio ("/login", "/favicon.svg").
 *  Deja igual las URL completas, blob: y data:. */
export const u = (p?: string | null): string =>
  p && p.startsWith("/") && !p.startsWith("//") ? BASE + p : (p ?? "");

/** URL de la API: VITE_API_BASE si existe; si no, la ruta base de la consola. */
export const apiUrl = (p: string): string => (API_BASE ? API_BASE + p : BASE + p);
