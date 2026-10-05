import { $, component$, useSignal, useVisibleTask$, type QRL } from "@builder.io/qwik";
import { Avatar } from "./avatar";
import { Icono } from "./icono";

export interface ItemMenu {
  valor: string;
  titulo: string;
  peligro?: boolean;
  deshabilitado?: boolean;
  /** Línea fina encima, para separar grupos. */
  separador?: boolean;
}

interface MenuProps {
  etiqueta: string;
  items: ItemMenu[];
  onElegir$: QRL<(valor: string) => void>;
  icono?: string;
  /** Si se pasa, el disparador es el avatar de esa persona en vez del icono. */
  avatar?: string;
  class?: string;
}

/** Menú ··· (popover). Enter o ↓ lo abre y mueve el foco al primer ítem; ↑ ↓ Inicio Fin recorren; Escape cierra y
 *  devuelve el foco al botón. */
export const MenuAcciones = component$<MenuProps>((p) => {
  const abierto = useSignal(false);
  const raiz = useSignal<HTMLElement>();
  const lista = useSignal<HTMLElement>();

  const abrir = $(() => {
    abierto.value = !abierto.value;
  });

  // Foco al primer ítem al abrir, cierre al hacer clic fuera.
  useVisibleTask$(({ track, cleanup }) => {
    const a = track(() => abierto.value);
    if (!a) return;
    const items = () => Array.from(lista.value?.querySelectorAll<HTMLElement>('[role="menuitem"]:not([disabled])') ?? []);
    items()[0]?.focus();
    const fuera = (e: MouseEvent) => {
      if (raiz.value && !raiz.value.contains(e.target as Node)) abierto.value = false;
    };
    const tecla = (e: KeyboardEvent) => {
      const its = items();
      const i = its.indexOf(document.activeElement as HTMLElement);
      if (e.key === "Escape") {
        e.stopPropagation();
        abierto.value = false;
        raiz.value?.querySelector<HTMLElement>("button")?.focus();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        its[(i + 1) % its.length]?.focus();
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        its[(i - 1 + its.length) % its.length]?.focus();
      } else if (e.key === "Home") {
        e.preventDefault();
        its[0]?.focus();
      } else if (e.key === "End") {
        e.preventDefault();
        its[its.length - 1]?.focus();
      } else if (e.key === "Tab") {
        abierto.value = false;
      }
    };
    document.addEventListener("mousedown", fuera);
    raiz.value?.addEventListener("keydown", tecla);
    const r = raiz.value;
    cleanup(() => {
      document.removeEventListener("mousedown", fuera);
      r?.removeEventListener("keydown", tecla);
    });
  });

  return (
    <div class={`menu-raiz ${p.class ?? ""}`} ref={raiz}>
      <button
        type="button"
        class={p.avatar ? "avatar-boton" : "icono-boton"}
        aria-label={p.etiqueta}
        aria-haspopup="menu"
        aria-expanded={abierto.value}
        onClick$={abrir}
      >
        {p.avatar ? <Avatar nombre={p.avatar} tam={32} /> : <Icono n={p.icono ?? "mas"} />}
      </button>
      {abierto.value && (
        <div class="menu" role="menu" aria-label={p.etiqueta} ref={lista}>
          {p.items.map((it) => (
            <button
              key={it.valor}
              type="button"
              role="menuitem"
              class={`menu-item${it.peligro ? " peligro" : ""}${it.separador ? " con-sep" : ""}`}
              disabled={it.deshabilitado}
              onClick$={() => {
                abierto.value = false;
                p.onElegir$(it.valor);
              }}
            >
              {it.titulo}
            </button>
          ))}
        </div>
      )}
    </div>
  );
});
