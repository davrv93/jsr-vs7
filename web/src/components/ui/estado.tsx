import { component$ } from "@builder.io/qwik";
import type { NivelSla } from "~/lib/sla";

/** Estado como texto en tinta secundaria. Solo «Por vencer» y «Vencida» llevan color, y como punto o texto,
 *  nunca como pastilla rellena. */
export const Estado = component$<{ texto: string; nivel?: NivelSla }>((p) => (
  <span class={`estado${p.nivel === "vencida" ? " es-vencida" : p.nivel === "por_vencer" ? " es-por-vencer" : ""}`}>
    {p.nivel === "por_vencer" && <span class="punto punto-naranja" aria-hidden="true" />}
    {p.texto}
  </span>
));
