import { component$, type QRL } from "@builder.io/qwik";
import { Link } from "@builder.io/qwik-city";
import { Icono } from "./icono";

interface VacioProps {
  titulo: string;
  texto?: string;
  accion?: string;
  href?: string;
  onAccion$?: QRL<() => void>;
  /** Para estados que ocupan toda la pantalla (error de página, sin acceso). */
  grande?: boolean;
}

/** Una frase y una acción. Sin ilustración. Dice qué significa y qué hacer. */
export const Vacio = component$<VacioProps>((p) => (
  <div class={`vacio${p.grande ? " vacio-grande" : ""}`} role="status">
    <p class="vacio-titulo">{p.titulo}</p>
    {p.texto && <p class="vacio-texto">{p.texto}</p>}
    {p.accion && p.href && (
      <Link href={p.href} class="vacio-accion">
        {p.accion} <Icono n="der" tam={14} />
      </Link>
    )}
    {p.accion && !p.href && p.onAccion$ && (
      <button type="button" class="vacio-accion" onClick$={p.onAccion$}>
        {p.accion}
      </button>
    )}
  </div>
));

interface FallaProps {
  /** Qué falló, en palabras simples. */
  titulo: string;
  /** Qué no se perdió o por qué pasó. */
  texto?: string;
  sinRed?: boolean;
  onReintentar$: QRL<() => void>;
}

/** Error: qué falló, qué no se perdió y «Reintentar». Nunca un código HTTP solo. */
export const Falla = component$<FallaProps>((p) => (
  <div class="vacio falla" role="alert">
    <Icono n={p.sinRed ? "sin_red" : "alerta"} tam={22} class="falla-icono" />
    <p class="vacio-titulo">{p.titulo}</p>
    {p.texto && <p class="vacio-texto">{p.texto}</p>}
    <button type="button" class="boton boton-secundario" onClick$={p.onReintentar$}>
      Reintentar
    </button>
  </div>
));
