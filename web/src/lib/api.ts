// Cliente de la API de la consola (CONTRATOS.md §2). Solo se usa en el navegador: el sitio es estático.

import { apiUrl, u } from "./base";
import { cerrarSesion, getToken } from "./auth";

export class ApiError extends Error {
  status: number;
  codigo: string;
  /** true si ni siquiera hubo respuesta (sin red, servidor caído). */
  red: boolean;
  constructor(mensaje: string, status: number, codigo = "", red = false) {
    super(mensaje);
    this.status = status;
    this.codigo = codigo;
    this.red = red;
  }
}

const porEstado = (s: number): string => {
  if (s === 400 || s === 422) return "Hay datos que no son válidos. Revísalos e inténtalo de nuevo.";
  if (s === 403) return "Tu rol no tiene permiso para esto.";
  if (s === 404) return "No encontramos lo que buscabas. Puede que ya no exista.";
  if (s === 409) return "Alguien más cambió esto mientras lo mirabas. Recarga y vuelve a intentarlo.";
  if (s === 429) return "Demasiados intentos seguidos. Espera un momento.";
  return "Algo falló en el servidor. Lo que hiciste antes está a salvo; inténtalo de nuevo.";
};

const avisarRed = (ok: boolean) => {
  try {
    window.dispatchEvent(new CustomEvent("jsr:red", { detail: { ok } }));
  } catch {
    /* sin ventana */
  }
};

export interface OpcionesApi {
  method?: string;
  json?: unknown;
  signal?: AbortSignal;
  /** Páginas públicas (estado, chat web): sin token y sin redirigir al inicio de sesión. */
  publico?: boolean;
}

export async function api<T = unknown>(path: string, opts: OpcionesApi = {}): Promise<T> {
  const headers = new Headers();
  const token = opts.publico ? null : getToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  let body: string | undefined;
  if (opts.json !== undefined) {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(opts.json);
  }
  let res: Response;
  try {
    res = await fetch(apiUrl(path), { method: opts.method ?? (body ? "POST" : "GET"), headers, body, signal: opts.signal });
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
    avisarRed(false);
    throw new ApiError("No hay conexión con el servidor. Lo que escribiste se conserva.", 0, "sin_red", true);
  }
  avisarRed(true);
  let data: unknown = {};
  try {
    data = await res.json();
  } catch {
    /* sin cuerpo */
  }
  const d = data as { error?: string; codigo?: string };
  if (res.status === 401 && !opts.publico && !path.startsWith("/api/auth")) {
    cerrarSesion();
    location.assign(u("/login?expiro=1"));
    throw new ApiError("Tu sesión expiró. Vuelve a entrar.", 401, "no_autorizado");
  }
  if (!res.ok) throw new ApiError(d.error ?? porEstado(res.status), res.status, d.codigo ?? "");
  return data as T;
}

/** Texto para mostrar de cualquier error, sin códigos HTTP sueltos. */
export const mensajeError = (e: unknown): string =>
  e instanceof ApiError ? e.message : "Algo salió mal. Inténtalo de nuevo.";
