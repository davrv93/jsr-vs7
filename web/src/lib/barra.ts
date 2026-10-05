import { useContext, useSignal, useVisibleTask$, type QRL, type ReadonlySignal } from "@builder.io/qwik";
import { UiCtx } from "./ui";

/** Pone la acción principal de la pantalla en la barra superior (una sola, píldora azul) y avisa cuando se pulsa.
 *  Al salir de la pantalla la quita. El contador de eventos persiste entre pantallas, por eso se ignora el valor con
 *  el que ya llegó. */
export function useAccionBarra(texto: string, onAccion$: QRL<() => void>, corto?: string, deshabilitada?: ReadonlySignal<boolean>) {
  const ui = useContext(UiCtx);
  const visto = useSignal(-1);

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track, cleanup }) => {
      const vp = track(() => ui.vp);
      const off = deshabilitada ? track(() => deshabilitada.value) : false;
      ui.barra.accion = vp === "movil" && corto ? corto : texto;
      ui.barra.accionDeshabilitada = off;
      cleanup(() => {
        ui.barra.accion = "";
        ui.barra.accionDeshabilitada = false;
      });
    },
    { strategy: "document-ready" },
  );

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const n = track(() => ui.evAccion);
      if (visto.value === -1) {
        visto.value = n;
        return;
      }
      if (n !== visto.value) {
        visto.value = n;
        onAccion$();
      }
    },
    { strategy: "document-ready" },
  );
}

/** «‹ Bandeja» en la barra superior (móvil, lista → detalle). Solo mientras `activo` sea verdadero. */
export function useAtrasBarra(etiqueta: string, activo: ReadonlySignal<boolean>, onAtras$: QRL<() => void>) {
  const ui = useContext(UiCtx);
  const visto = useSignal(-1);

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track, cleanup }) => {
      const a = track(() => activo.value);
      const vp = track(() => ui.vp);
      ui.barra.atras = a && vp === "movil" ? etiqueta : "";
      cleanup(() => {
        ui.barra.atras = "";
      });
    },
    { strategy: "document-ready" },
  );

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const n = track(() => ui.evAtras);
      if (visto.value === -1) {
        visto.value = n;
        return;
      }
      if (n !== visto.value) {
        visto.value = n;
        onAtras$();
      }
    },
    { strategy: "document-ready" },
  );
}
