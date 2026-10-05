import { $, component$, Slot, useComputed$, useContext, type QRL } from "@builder.io/qwik";
import { useAtrasBarra } from "~/lib/barra";
import { UiCtx } from "~/lib/ui";
import { Hoja } from "./ui/hoja";

interface MaestroProps {
  /** ¿Hay un objeto abierto (?inc=…, ?tec=…)? */
  haySel: boolean;
  /** Título de la hoja en pantallas medianas. */
  titulo: string;
  /** Qué se ve en el panel cuando no hay nada abierto (≥ 1200 px). */
  vacio: string;
  /** «‹ Bandeja» en la barra superior en móvil. */
  atras: string;
  /** Quita la selección (quita ?inc de la URL). */
  onCerrar$: QRL<() => void>;
}

/** Maestro / detalle (DISENO §1, divulgación progresiva): el detalle de cualquier objeto se abre en un panel a la
 *  derecha (≥ 1200 px), en una hoja que se desliza (768–1199 px) o a pantalla completa con «‹ Volver» (móvil). La
 *  lista no se pierde en ningún caso (en móvil queda oculta, no desmontada, para conservar el scroll). */
export const MaestroDetalle = component$<MaestroProps>((p) => {
  const ui = useContext(UiCtx);
  const hay = useComputed$(() => p.haySel);
  const volver = $(() => p.onCerrar$());
  useAtrasBarra(p.atras, hay, volver);
  return (
    <>
      <div class="md">
        <div class={`md-col md-lista${ui.vp === "movil" && p.haySel ? " oculta" : ""}`}>
          <div class="md-lista-interior">
            <Slot name="lista" />
          </div>
        </div>
        {ui.vp === "ancho" && (
          <aside class="md-col md-detalle" aria-label="Detalle">
            {p.haySel ? <Slot name="detalle" /> : <p class="md-detalle-vacio">{p.vacio}</p>}
          </aside>
        )}
        {ui.vp === "movil" && p.haySel && (
          <div class="md-col md-pagina">
            <Slot name="detalle" />
          </div>
        )}
      </div>
      {ui.vp === "medio" && p.haySel && (
        <Hoja titulo={p.titulo} onCerrar$={p.onCerrar$} ancho="ancho" plana>
          <Slot name="detalle" />
        </Hoja>
      )}
    </>
  );
});
