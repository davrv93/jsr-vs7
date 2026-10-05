import { component$, useContext, useSignal } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { SeccionCalendario, SeccionCategorias, SeccionGeneral, SeccionMatriz, SeccionRoles, SeccionSla } from "~/components/ajustes";
import { Segmentado } from "~/components/ui/segmentado";
import { UiCtx } from "~/lib/ui";

/** 15 · Ajustes. Canales, SLA, horario, categorías, roles. Cualquier rol cambia su tema; la configuración es del admin. */
export default component$(() => {
  const ui = useContext(UiCtx);
  const seccion = useSignal("general");
  const admin = ui.usuario?.rol === "admin";
  const opciones = [
    { valor: "general", titulo: "General" },
    ...(admin
      ? [
          { valor: "sla", titulo: "SLA" },
          { valor: "calendario", titulo: "Calendario" },
          { valor: "categorias", titulo: "Categorías" },
          { valor: "matriz", titulo: "Matriz" },
          { valor: "roles", titulo: "Roles" },
        ]
      : []),
  ];
  return (
    <div class="pagina pagina-agrupada">
      <div class="pagina-interior">
        {opciones.length > 1 && <Segmentado tabs etiqueta="Sección de ajustes" valor={seccion.value} opciones={opciones} onCambio$={(v) => (seccion.value = v)} class="ajustes-seg" />}
        <div class="ajustes-cuerpo" role="tabpanel" aria-label="Ajustes">
          {seccion.value === "general" && <SeccionGeneral />}
          {admin && seccion.value === "sla" && <SeccionSla />}
          {admin && seccion.value === "calendario" && <SeccionCalendario />}
          {admin && seccion.value === "categorias" && <SeccionCategorias />}
          {admin && seccion.value === "matriz" && <SeccionMatriz />}
          {admin && seccion.value === "roles" && <SeccionRoles />}
        </div>
        {!admin && <p class="ajustes-nota">La configuración de SLA, calendario, categorías, matriz y roles es del administrador.</p>}
      </div>
    </div>
  );
});

export const head: DocumentHead = { title: "Ajustes · jsrbot" };
