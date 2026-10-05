import { component$ } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { u } from "~/lib/base";

/** Página que no existe: lo dice en palabras simples y lleva al inicio. */
export default component$(() => (
  <main class="login">
    <div class="login-form">
      <h1 class="login-titulo">No encontramos esa página.</h1>
      <p class="login-sub">Puede que el enlace esté mal escrito o que ya no exista.</p>
      <a class="boton boton-principal" href={u("/")}>
        Ir al inicio
      </a>
    </div>
  </main>
));

export const head: DocumentHead = { title: "Página no encontrada · jsrbot" };
