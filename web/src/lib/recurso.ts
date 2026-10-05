import { $, useContext, useSignal, useStore, useVisibleTask$, type QRL, type ReadonlySignal } from "@builder.io/qwik";
import { api, ApiError, mensajeError } from "./api";
import { UiCtx } from "./ui";

export interface Recurso<T> {
  /** cargando: primera carga o cambio de ruta · ok · error */
  estado: "cargando" | "ok" | "error";
  datos: T | null;
  error: string;
  sinRed: boolean;
  /** Más de 3 s esperando: la pantalla dice qué espera. */
  lento: boolean;
}

export interface OpcionesRecurso {
  /** Recarga silenciosa cada tanto (los plazos de SLA se mueven solos). */
  cadaMs?: number;
  /** Recarga silenciosa con cada evento en vivo (SSE). Por defecto sí. */
  eventos?: boolean;
}

/** Carga una ruta de la API con los cuatro estados que toda pantalla debe tener (DISENO §4): carga con esqueleto,
 *  error en palabras simples con Reintentar, sin conexión, y datos. `ruta` puede ser una señal: al cambiar, recarga;
 *  una cadena vacía no carga (para esperar a que haya una selección). */
export function useRecurso<T>(ruta: string | ReadonlySignal<string>, opts: OpcionesRecurso = {}) {
  const ui = useContext(UiCtx);
  const propia = useSignal(typeof ruta === "string" ? ruta : "");
  const sig: ReadonlySignal<string> = typeof ruta === "string" ? propia : ruta;
  const r = useStore<Recurso<T>>({ estado: "cargando", datos: null, error: "", sinRed: false, lento: false }, { deep: false });
  const seq = useSignal(0);

  const cargar: QRL<(silencioso: boolean) => Promise<void>> = $(async (silencioso: boolean) => {
    const url = sig.value;
    if (!url) return;
    const n = ++seq.value;
    if (!silencioso) {
      r.estado = "cargando";
      r.error = "";
      r.lento = false;
      setTimeout(() => {
        if (seq.value === n && r.estado === "cargando") r.lento = true;
      }, 3000);
    }
    try {
      const d = await api<T>(url);
      if (n !== seq.value) return;
      r.datos = d;
      r.estado = "ok";
      r.error = "";
      r.sinRed = false;
    } catch (e) {
      if (n !== seq.value || (e as Error).name === "AbortError") return;
      if (silencioso && r.datos) return;
      r.estado = "error";
      r.error = mensajeError(e);
      r.sinRed = e instanceof ApiError && e.red;
    }
  });

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      track(() => sig.value);
      cargar(false);
    },
    { strategy: "document-ready" },
  );

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const t = track(() => ui.tick);
      if (t > 0 && opts.eventos !== false) cargar(true);
    },
    { strategy: "document-ready" },
  );

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ cleanup }) => {
      if (!opts.cadaMs) return;
      const id = setInterval(() => cargar(true), opts.cadaMs);
      cleanup(() => clearInterval(id));
    },
    { strategy: "document-ready" },
  );

  const recargar = $(() => cargar(false));
  const refrescar = $(() => cargar(true));
  return { r, recargar, refrescar };
}
