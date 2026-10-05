import { $, component$, Slot, type QRL } from "@builder.io/qwik";
import { Link } from "@builder.io/qwik-city";
import { useDialog } from "~/lib/ui";

export interface ConfirmarOpts {
  titulo: string;
  texto?: string;
  ok?: string;
}

interface BotonProps {
  /** principal: píldora azul · secundario: texto azul · peligro: texto rojo, siempre con confirmación */
  variante?: "principal" | "secundario" | "peligro";
  tipo?: "button" | "submit";
  deshabilitado?: boolean;
  cargando?: boolean;
  bloque?: boolean;
  pequeno?: boolean;
  href?: string;
  etiqueta?: string;
  /** id del formulario al que pertenece un botón submit que está fuera de él (pie de una hoja). */
  form?: string;
  class?: string;
  /** Para variante peligro: el diálogo de confirmación que se muestra antes de actuar. */
  confirmar?: ConfirmarOpts;
  onClick$?: QRL<() => void | Promise<void>>;
}

/** Principal: píldora azul de 36 px (44 en móvil). Secundario: texto azul sin fondo. Destructivo: texto rojo;
 *  con `confirmar` pasa antes por useDialog().confirm. Solo debe haber un principal por contexto. */
export const Boton = component$<BotonProps>((p) => {
  const dialog = useDialog();
  const variante = p.variante ?? "secundario";
  const clase = `boton boton-${variante}${p.bloque ? " boton-bloque" : ""}${p.pequeno ? " boton-pequeno" : ""}${p.class ? " " + p.class : ""}`;
  const alClick = $(async () => {
    if (p.confirmar) {
      const ok = await dialog.confirm({ titulo: p.confirmar.titulo, texto: p.confirmar.texto, ok: p.confirmar.ok, peligro: true });
      if (!ok) return;
    }
    await p.onClick$?.();
  });
  if (p.href) {
    return (
      <Link href={p.href} class={clase} aria-label={p.etiqueta}>
        <Slot />
      </Link>
    );
  }
  return (
    <button
      type={p.tipo ?? "button"}
      form={p.form}
      class={clase}
      disabled={p.deshabilitado || p.cargando}
      aria-busy={p.cargando ? "true" : undefined}
      aria-label={p.etiqueta}
      onClick$={p.tipo === "submit" && !p.onClick$ ? undefined : alClick}
    >
      <Slot />
    </button>
  );
});
