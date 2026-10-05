import { $, component$, Slot, useSignal, useVisibleTask$, type QRL } from "@builder.io/qwik";
import { atraparTab, bloquearScroll, duracion, focalizables } from "~/lib/foco";
import { Icono } from "./icono";

interface HojaProps {
  titulo: string;
  subtitulo?: string;
  onCerrar$: QRL<() => void>;
  /** Pie fijo con las acciones (Guardar…). */
  pie?: boolean;
  ancho?: "normal" | "ancho";
  /** Sin relleno en el cuerpo: lo trae el contenido (detalle con compositor fijo abajo). */
  plana?: boolean;
}

/** Hoja modal: se desliza desde la derecha en escritorio y sube desde abajo en móvil (con asa), 350 ms con curva de
 *  resorte. Atrapa el foco, cierra con Escape o tocando el velo, y devuelve el foco a quien la abrió. */
export const Hoja = component$<HojaProps>((p) => {
  const ref = useSignal<HTMLElement>();
  const saliendo = useSignal(false);
  const cerrar = $(() => {
    if (saliendo.value) return;
    saliendo.value = true;
    setTimeout(() => p.onCerrar$(), duracion("--d3"));
  });

  useVisibleTask$(
    ({ cleanup }) => {
      const el = ref.value;
      if (!el) return;
      const previo = document.activeElement as HTMLElement | null;
      const soltar = bloquearScroll();
      const quitarTab = atraparTab(el);
      const alTeclear = (e: KeyboardEvent) => {
        if (e.key === "Escape" && !e.defaultPrevented) {
          e.stopPropagation();
          cerrar();
        }
      };
      el.addEventListener("keydown", alTeclear);
      // Foco inicial: el primer campo si lo hay; si no, la propia hoja (para que el lector lea el título).
      // En una hoja plana (detalle con el compositor abajo) el foco va a la hoja, no a un campo: no se abre el teclado en una tableta.
      const campo = p.plana ? undefined : focalizables(el).find((x) => x.matches("input, textarea, select"));
      (campo ?? el).focus({ preventScroll: true });
      cleanup(() => {
        el.removeEventListener("keydown", alTeclear);
        quitarTab();
        soltar();
        if (previo && document.contains(previo)) previo.focus({ preventScroll: true });
      });
    },
    { strategy: "document-ready" },
  );

  return (
    <div class={`hoja-capa${saliendo.value ? " saliendo" : ""}`}>
      <div class="hoja-velo" onClick$={cerrar} aria-hidden="true" />
      <div
        class={`hoja${p.ancho === "ancho" ? " hoja-ancha" : ""}`}
        role="dialog"
        aria-modal="true"
        aria-label={p.titulo}
        tabIndex={-1}
        ref={ref}
      >
        <span class="hoja-asa" aria-hidden="true" />
        <header class="hoja-cab">
          <div class="hoja-titulos">
            <h2 class="hoja-titulo">{p.titulo}</h2>
            {p.subtitulo && <p class="hoja-subtitulo">{p.subtitulo}</p>}
          </div>
          <button type="button" class="icono-boton" aria-label="Cerrar" onClick$={cerrar}>
            <Icono n="cerrar" />
          </button>
        </header>
        <div class={`hoja-cuerpo${p.plana ? " hoja-cuerpo-plano" : ""}`}>
          <Slot />
        </div>
        {p.pie && (
          <footer class="hoja-pie">
            <Slot name="pie" />
          </footer>
        )}
      </div>
    </div>
  );
});
