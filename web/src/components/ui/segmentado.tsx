import { $, component$, type QRL } from "@builder.io/qwik";

export interface OpcionSeg {
  valor: string;
  titulo: string;
}

interface SegProps {
  opciones: OpcionSeg[];
  valor: string;
  etiqueta: string;
  onCambio$: QRL<(valor: string) => void>;
  /** «tabs» cuando cambia una vista; por defecto es un grupo de opciones (radiogroup). */
  tabs?: boolean;
  class?: string;
}

/** Control segmentado de iOS: fondo gris, la opción activa en blanco con sombra mínima. Flechas ← → mueven la selección. */
export const Segmentado = component$<SegProps>((p) => {
  const alTeclear = $((e: KeyboardEvent, el: HTMLElement) => {
    const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
    if (!d) return;
    const botones = Array.from(el.parentElement!.querySelectorAll<HTMLButtonElement>("button"));
    const i = botones.indexOf(el as HTMLButtonElement);
    const sig = botones[(i + d + botones.length) % botones.length];
    sig.focus();
    sig.click();
  });
  return (
    <div class={`segmentado ${p.class ?? ""}`} role={p.tabs ? "tablist" : "radiogroup"} aria-label={p.etiqueta}>
      {p.opciones.map((o) => {
        const activa = o.valor === p.valor;
        return (
          <button
            key={o.valor}
            type="button"
            class={`seg-op${activa ? " activa" : ""}`}
            role={p.tabs ? "tab" : "radio"}
            aria-selected={p.tabs ? activa : undefined}
            aria-checked={p.tabs ? undefined : activa}
            tabIndex={activa ? 0 : -1}
            onClick$={() => p.onCambio$(o.valor)}
            onKeyDown$={alTeclear}
          >
            {o.titulo}
          </button>
        );
      })}
    </div>
  );
});
