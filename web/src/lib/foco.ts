// Utilidades de foco y de scroll para hojas, diálogos y el buscador (solo navegador).

const FOCALIZABLE =
  'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export const focalizables = (el: HTMLElement): HTMLElement[] =>
  Array.from(el.querySelectorAll<HTMLElement>(FOCALIZABLE)).filter((e) => !e.hasAttribute("aria-hidden") && e.offsetParent !== null);

/** Atrapa Tab dentro de `el`. Devuelve la función que lo desactiva. No maneja Escape: lo hace cada componente. */
export function atraparTab(el: HTMLElement): () => void {
  const alTeclear = (e: KeyboardEvent) => {
    if (e.key !== "Tab") return;
    const f = focalizables(el);
    if (!f.length) {
      e.preventDefault();
      el.focus();
      return;
    }
    const primero = f[0];
    const ultimo = f[f.length - 1];
    const activo = document.activeElement as HTMLElement | null;
    if (e.shiftKey && (activo === primero || !el.contains(activo))) {
      e.preventDefault();
      ultimo.focus();
    } else if (!e.shiftKey && (activo === ultimo || !el.contains(activo))) {
      e.preventDefault();
      primero.focus();
    }
  };
  el.addEventListener("keydown", alTeclear);
  return () => el.removeEventListener("keydown", alTeclear);
}

let bloqueos = 0;
/** Bloquea el scroll del fondo mientras haya algo modal abierto. Cuenta las capas apiladas. */
export function bloquearScroll(): () => void {
  bloqueos++;
  document.documentElement.classList.add("sin-scroll");
  let liberado = false;
  return () => {
    if (liberado) return;
    liberado = true;
    bloqueos = Math.max(0, bloqueos - 1);
    if (bloqueos === 0) document.documentElement.classList.remove("sin-scroll");
  };
}

/** Duración de una transición del sistema en ms (0 con movimiento reducido). */
export const duracion = (nombre: "--d1" | "--d2" | "--d3" = "--d3"): number => {
  const v = getComputedStyle(document.documentElement).getPropertyValue(nombre).trim();
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : 0;
};

/** ¿Está escribiendo la persona? Los atajos de teclado no deben dispararse. */
export const escribiendo = (t: EventTarget | null): boolean => {
  const el = t as HTMLElement | null;
  if (!el || !el.tagName) return false;
  const tag = el.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable;
};
