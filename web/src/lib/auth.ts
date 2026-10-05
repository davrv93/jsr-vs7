// Sesión: el token vive en memoria y se copia a sessionStorage (con try/catch: modo privado, sitio bloqueado…).
// Se pierde al cerrar la pestaña; es lo que se quiere en una consola de soporte compartida.

export type Rol = "tecnico" | "supervisor" | "gerencia" | "entrenador" | "admin";

export interface Usuario {
  id: number;
  nombre: string;
  rol: Rol;
  tecnico_id: number | null;
  email?: string;
}

const CLAVE_TOKEN = "jsr_token";
const CLAVE_USUARIO = "jsr_usuario";

let tokenMemoria: string | null = null;
let usuarioMemoria: Usuario | null = null;

const leer = (k: string): string | null => {
  try {
    return sessionStorage.getItem(k);
  } catch {
    return null;
  }
};
const escribir = (k: string, v: string | null) => {
  try {
    if (v === null) sessionStorage.removeItem(k);
    else sessionStorage.setItem(k, v);
  } catch {
    /* sin almacenamiento: la sesión vive solo en memoria */
  }
};

export const getToken = (): string | null => tokenMemoria ?? (tokenMemoria = leer(CLAVE_TOKEN));

export const getUsuario = (): Usuario | null => {
  if (usuarioMemoria) return usuarioMemoria;
  const crudo = leer(CLAVE_USUARIO);
  if (!crudo) return null;
  try {
    usuarioMemoria = JSON.parse(crudo) as Usuario;
  } catch {
    usuarioMemoria = null;
  }
  return usuarioMemoria;
};

export const guardarSesion = (token: string, usuario: Usuario) => {
  tokenMemoria = token;
  usuarioMemoria = usuario;
  escribir(CLAVE_TOKEN, token);
  escribir(CLAVE_USUARIO, JSON.stringify(usuario));
};

export const cerrarSesion = () => {
  tokenMemoria = null;
  usuarioMemoria = null;
  escribir(CLAVE_TOKEN, null);
  escribir(CLAVE_USUARIO, null);
};

// Preferencias por persona (no secretos): tema y lateral plegado. localStorage con try/catch.
export const leerPref = (k: string): string | null => {
  try {
    return localStorage.getItem("jsr_" + k);
  } catch {
    return null;
  }
};
export const guardarPref = (k: string, v: string) => {
  try {
    localStorage.setItem("jsr_" + k, v);
  } catch {
    /* ignorar */
  }
};

// Borradores de respuesta: lo escrito se conserva si se cae la red o se cambia de incidencia.
export const leerBorrador = (id: string): string => leer("jsr_borrador_" + id) ?? "";
export const guardarBorrador = (id: string, texto: string) => escribir("jsr_borrador_" + id, texto || null);
