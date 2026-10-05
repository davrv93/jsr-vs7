import { component$ } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { EsqueletoFilas } from "~/components/ui/esqueleto";

/** «/» no tiene pantalla propia: el armazón comprueba la sesión y manda al inicio que toca según el rol. */
export default component$(() => (
  <div class="pagina">
    <EsqueletoFilas n={6} />
  </div>
));

export const head: DocumentHead = { title: "jsrbot · Mesa de ayuda" };
