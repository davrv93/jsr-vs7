import { $, createContextId } from "@builder.io/qwik";
import type { Usuario } from "./auth";
import type { Bandeja } from "./tipos";

// ---------------------------------------------------------------------------------------------------------------
// Estado global de la consola (un solo contexto). Todo es serializable: lo que no lo es (resolutores de promesas)
// vive en este módulo, solo en el navegador.

export interface AvisoItem {
  id: number;
  texto: string;
  tipo: "info" | "ok" | "error";
}

export interface OpcionElegir {
  valor: string;
  titulo: string;
  detalle?: string;
}

export interface DialogoItem {
  id: number;
  tipo: "alert" | "confirm" | "prompt" | "elegir";
  titulo: string;
  texto?: string;
  icono?: string;
  etiqueta?: string;
  valor?: string;
  placeholder?: string;
  tipoCampo?: string;
  largo?: boolean;
  requerido?: boolean;
  peligro?: boolean;
  ok?: string;
  cancelar?: string;
  opciones?: OpcionElegir[];
}

export interface AnunciosStore {
  avisos: AvisoItem[];
  dialogos: DialogoItem[];
}

export interface UiStore {
  /** Sesión leída del navegador. null hasta que el armazón comprueba. */
  usuario: Usuario | null;
  listo: boolean;
  /** movil < 768, medio 768–1199, ancho ≥ 1200 */
  vp: "movil" | "medio" | "ancho";
  plegado: boolean;
  tema: "sistema" | "claro" | "oscuro";
  conectado: boolean;
  /** Se incrementa con cada evento SSE: las pantallas lo siguen para recargar en silencio. */
  tick: number;
  contador: number;
  buscadorAbierto: boolean;
  /** Lo que la pantalla activa pone en la barra superior. */
  barra: { atras: string; accion: string; accionDeshabilitada: boolean };
  evAccion: number;
  evAtras: number;
  /** Menú «Más» de la barra inferior en móvil. */
  menuMasAbierto: boolean;
}

export const UiCtx = createContextId<UiStore>("jsr.ui");
export const AnunciosCtx = createContextId<AnunciosStore>("jsr.anuncios");

// ---------------------------------------------------------------------------------------------------------------
// toast() y useDialog(): se registran contra el store que monta <Anuncios/> en el navegador.

let host: AnunciosStore | null = null;
let siguiente = 1;
const resolutores = new Map<number, (v: unknown) => void>();
const cola: Array<() => void> = [];

export const registrarAnuncios = (h: AnunciosStore) => {
  host = h;
  while (cola.length) cola.shift()?.();
};

const conHost = (fn: () => void) => {
  if (host) fn();
  else cola.push(fn);
};

/** Aviso breve que no pide respuesta. Preferirlo a un diálogo. */
export function toast(texto: string, tipo: AvisoItem["tipo"] = "info") {
  conHost(() => {
    const id = siguiente++;
    host!.avisos.push({ id, texto, tipo });
    setTimeout(
      () => {
        if (!host) return;
        const i = host.avisos.findIndex((a) => a.id === id);
        if (i >= 0) host.avisos.splice(i, 1);
      },
      tipo === "error" ? 6500 : 3800,
    );
  });
}

export function cerrarAviso(id: number) {
  if (!host) return;
  const i = host.avisos.findIndex((a) => a.id === id);
  if (i >= 0) host.avisos.splice(i, 1);
}

export function abrir<T>(d: Omit<DialogoItem, "id">): Promise<T> {
  return new Promise<T>((resolver) => {
    conHost(() => {
      const id = siguiente++;
      resolutores.set(id, resolver as (v: unknown) => void);
      host!.dialogos.push({ ...d, id });
    });
  });
}

/** Lo llama <Anuncios/> al cerrar un diálogo. */
export function resolverDialogo(id: number, valor: unknown) {
  const r = resolutores.get(id);
  resolutores.delete(id);
  if (host) {
    const i = host.dialogos.findIndex((d) => d.id === id);
    if (i >= 0) host.dialogos.splice(i, 1);
  }
  r?.(valor);
}

export interface OpcionesAlert {
  titulo: string;
  texto?: string;
  icono?: string;
  ok?: string;
}
export interface OpcionesConfirm extends OpcionesAlert {
  peligro?: boolean;
  cancelar?: string;
}
export interface OpcionesPrompt {
  titulo: string;
  texto?: string;
  label?: string;
  valor?: string;
  placeholder?: string;
  type?: "text" | "number" | "email";
  largo?: boolean;
  requerido?: boolean;
  ok?: string;
  cancelar?: string;
}
export interface OpcionesElegir {
  titulo: string;
  texto?: string;
  opciones: { valor: string; titulo: string; detalle?: string }[];
  cancelar?: string;
}

/** Reemplazo de window.alert / confirm / prompt (prohibidos). Mismo patrón que el de PjgFactSalud:
 *  const dialog = useDialog();  const ok = await dialog.confirm({ title… })
 *  Devuelven promesa: alert → true · confirm → bool · prompt → string | null · elegir → string | null. */
export const useDialog = () => {
  const alert = $(
    (o: OpcionesAlert): Promise<boolean> =>
      abrir<boolean>({ tipo: "alert", titulo: o.titulo, texto: o.texto, icono: o.icono, ok: o.ok ?? "Entendido" }),
  );
  const confirm = $(
    (o: OpcionesConfirm): Promise<boolean> =>
      abrir<boolean>({
        tipo: "confirm",
        titulo: o.titulo,
        texto: o.texto,
        icono: o.icono,
        peligro: o.peligro,
        ok: o.ok ?? (o.peligro ? "Continuar" : "Aceptar"),
        cancelar: o.cancelar ?? "Cancelar",
      }),
  );
  const prompt = $(
    (o: OpcionesPrompt): Promise<string | null> =>
      abrir<string | null>({
        tipo: "prompt",
        titulo: o.titulo,
        texto: o.texto,
        etiqueta: o.label,
        valor: o.valor ?? "",
        placeholder: o.placeholder,
        tipoCampo: o.type ?? "text",
        largo: o.largo,
        requerido: o.requerido,
        ok: o.ok ?? "Aceptar",
        cancelar: o.cancelar ?? "Cancelar",
      }),
  );
  const elegir = $(
    (o: OpcionesElegir): Promise<string | null> =>
      abrir<string | null>({ tipo: "elegir", titulo: o.titulo, texto: o.texto, opciones: o.opciones, cancelar: o.cancelar ?? "Cancelar" }),
  );
  return { alert, confirm, prompt, elegir };
};

export type { Bandeja };
