import { component$ } from "@builder.io/qwik";
import { iniciales } from "~/lib/format";

/** Avatar neutro con iniciales. Un técnico sin foto es lo normal, no un caso aparte. */
export const Avatar = component$<{ nombre: string | null | undefined; tam?: 24 | 32 | 40 | 56; foto?: string | null }>((p) => (
  <span class={`avatar avatar-${p.tam ?? 32}`} aria-hidden="true">
    {p.foto ? <img src={p.foto} alt="" width={p.tam ?? 32} height={p.tam ?? 32} /> : iniciales(p.nombre)}
  </span>
));
