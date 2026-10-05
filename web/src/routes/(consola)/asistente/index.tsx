import { component$, useContext, useVisibleTask$ } from "@builder.io/qwik";
import { useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { u } from "~/lib/base";
import { UiCtx } from "~/lib/ui";

/** «/asistente» no tiene vista propia: abre Comportamiento (o Entrenamiento, para quien entrena). */
export default component$(() => {
  const nav = useNavigate();
  const ui = useContext(UiCtx);
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    () => {
      nav(u(ui.usuario?.rol === "entrenador" ? "/asistente/entrenamiento" : "/asistente/comportamiento"), { replaceState: true });
    },
    { strategy: "document-ready" },
  );
  return (
    <div class="pagina">
      <EsqueletoFilas n={4} />
    </div>
  );
});

export const head: DocumentHead = { title: "Asistente · jsrbot" };
