import { $, component$, Slot, sync$ } from "@builder.io/qwik";
import { useNavigate } from "@builder.io/qwik-city";
import { u } from "~/lib/base";
import { irA } from "~/lib/params";

/** Enlace interno con query (/incidencias?estado=…). Se comporta como un enlace normal (clic derecho, clic con Ctrl o ⌘ y
 *  clic central abren aparte) y, en un clic simple, navega con `irA`, que conserva el ?query en un sitio estático. */
export const Enlace = component$<{ a: string; class?: string }>((p) => {
  const nav = useNavigate();
  const ir = $(async (e: MouseEvent) => {
    if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
    await irA(nav, p.a);
  });
  return (
    <a
      href={u(p.a)}
      class={p.class}
      onClick$={[
        sync$((e: MouseEvent) => {
          if (e.button === 0 && !e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey) e.preventDefault();
        }),
        ir,
      ]}
    >
      <Slot />
    </a>
  );
});
