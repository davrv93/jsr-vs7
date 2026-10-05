import { component$ } from "@builder.io/qwik";

/** Cifra grande: 48 / 34 / 22 px, tabular, con la unidad en tinta secundaria al 60 % del tamaño. */
export const Cifra = component$<{ valor: string; unidad?: string; tam?: 48 | 34 | 22; etiqueta?: string }>((p) => (
  <span class={`cifra cifra-${p.tam ?? 48}`} aria-label={p.etiqueta}>
    <span class="cifra-valor">{p.valor}</span>
    {p.unidad && <span class="cifra-unidad">{p.unidad}</span>}
  </span>
));
