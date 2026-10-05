import { $, component$, useContext } from "@builder.io/qwik";
import { useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { Fila, Grupo } from "~/components/ui/grupo";
import { cerrarSesion, guardarPref } from "~/lib/auth";
import { u } from "~/lib/base";
import { ROL_TEXTO } from "~/lib/format";
import { PESTANAS_MOVIL, puede, RUTAS } from "~/lib/rutas";
import { UiCtx } from "~/lib/ui";
import { Segmentado } from "~/components/ui/segmentado";

/** «Más» de la barra inferior en móvil: lo que no cabe en las cuatro pestañas, el tema y salir. */
export default component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const rol = ui.usuario?.rol;
  const fijas = PESTANAS_MOVIL.filter((r) => puede(rol, RUTAS.find((x) => x.ruta === r)!.roles)).slice(0, 4);
  const resto = RUTAS.filter((r) => r.lateral && puede(rol, r.roles) && !fijas.includes(r.ruta));
  const salir = $(async () => {
    cerrarSesion();
    await nav(u("/login"));
  });
  return (
    <div class="pagina pagina-agrupada">
      <div class="pagina-interior">
        <Grupo titulo={`${ui.usuario?.nombre ?? ""}${rol ? " · " + ROL_TEXTO[rol] : ""}`}>
          {resto.map((r) => (
            <Fila key={r.ruta} titulo={r.titulo} href={u(r.ruta)} navega />
          ))}
        </Grupo>
        <Grupo titulo="Apariencia">
          <Fila titulo="Tema">
            <Segmentado
              etiqueta="Tema"
              valor={ui.tema}
              onCambio$={(v) => {
                ui.tema = v as "sistema" | "claro" | "oscuro";
                guardarPref("tema", v);
              }}
              opciones={[
                { valor: "sistema", titulo: "Sistema" },
                { valor: "claro", titulo: "Claro" },
                { valor: "oscuro", titulo: "Oscuro" },
              ]}
            />
          </Fila>
        </Grupo>
        <Grupo>
          <Fila titulo="Cerrar sesión" onClick$={salir} navega />
        </Grupo>
      </div>
    </div>
  );
});

export const head: DocumentHead = { title: "Más · jsrbot" };
