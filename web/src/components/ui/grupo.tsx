import { component$, Slot, type QRL } from "@builder.io/qwik";
import { Link } from "@builder.io/qwik-city";
import { Icono } from "./icono";

/** Lista agrupada al estilo Ajustes: fondo agrupado, filas de 44 px con separador interior, radio de 12 px. */
export const Grupo = component$<{ titulo?: string; pie?: string; class?: string }>((p) => (
  <section class={`grupo-sec ${p.class ?? ""}`}>
    {p.titulo && <h3 class="grupo-titulo">{p.titulo}</h3>}
    <div class="grupo">
      <Slot />
    </div>
    {p.pie && <p class="grupo-pie">{p.pie}</p>}
  </section>
));

interface FilaProps {
  titulo: string;
  detalle?: string;
  valor?: string;
  /** Muestra › y hace navegable la fila. */
  navega?: boolean;
  href?: string;
  peligro?: boolean;
  deshabilitada?: boolean;
  onClick$?: QRL<() => void>;
}

/** Título de 15 px, detalle de 13 px secundario, valor a la derecha y › si navega. El contenido por defecto
 *  (Slot) va a la derecha: un interruptor, un segmentado, un campo corto. */
export const Fila = component$<FilaProps>((p) => {
  const dentro = (
    <>
      <span class="fila-g-texto">
        <span class={`fila-g-titulo${p.peligro ? " peligro" : ""}`}>{p.titulo}</span>
        {p.detalle && <span class="fila-g-detalle">{p.detalle}</span>}
      </span>
      {p.valor !== undefined && <span class="fila-g-valor">{p.valor}</span>}
      <span class="fila-g-slot">
        <Slot />
      </span>
      {p.navega && <Icono n="der" tam={16} class="fila-g-flecha" />}
    </>
  );
  if (p.href) {
    return (
      <Link href={p.href} class="fila-g fila-g-nav">
        {dentro}
      </Link>
    );
  }
  if (p.onClick$ || p.navega) {
    return (
      <button type="button" class="fila-g fila-g-nav" disabled={p.deshabilitada} onClick$={p.onClick$}>
        {dentro}
      </button>
    );
  }
  return (
    <div class="fila-g">
      {dentro}
    </div>
  );
});
