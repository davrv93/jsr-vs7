import { $, component$, Slot } from "@builder.io/qwik";
import { useLocation, useNavigate } from "@builder.io/qwik-city";
import { Segmentado } from "~/components/ui/segmentado";
import { BASE, u } from "~/lib/base";

const SECCIONES = [
  { valor: "comportamiento", titulo: "Comportamiento" },
  { valor: "conocimiento", titulo: "Conocimiento" },
  { valor: "entrenamiento", titulo: "Entrenamiento" },
  { valor: "calidad", titulo: "Calidad" },
];

/** Asistente (11 a 14): cuatro vistas del mismo objeto. El control segmentado navega entre ellas. */
export default component$(() => {
  const loc = useLocation();
  const nav = useNavigate();
  const path = (BASE && loc.url.pathname.startsWith(BASE) ? loc.url.pathname.slice(BASE.length) : loc.url.pathname).replace(/\/+$/, "");
  const actual = SECCIONES.find((s) => path.endsWith("/" + s.valor))?.valor ?? "";
  const ir = $(async (v: string) => {
    await nav(u(`/asistente/${v}`));
  });
  return (
    <div class="asistente-seccion">
      <div class="asistente-nav">
        <Segmentado tabs etiqueta="Secciones del asistente" valor={actual} opciones={SECCIONES} onCambio$={ir} />
      </div>
      <Slot />
    </div>
  );
});
