import { $, component$, useComputed$, useContext, useVisibleTask$ } from "@builder.io/qwik";
import { useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { DetalleIncidencia, FilaIncidencia } from "~/components/incidencias";
import { EsqueletoFilas, EsperaLarga } from "~/components/ui/esqueleto";
import { MaestroDetalle } from "~/components/maestro";
import { Enlace } from "~/components/ui/enlace";
import { Falla, Vacio } from "~/components/ui/vacio";
import { api, mensajeError } from "~/lib/api";
import { u } from "~/lib/base";
import { escribiendo } from "~/lib/foco";
import { useParam } from "~/lib/params";
import { plural, relativo } from "~/lib/format";
import { useAccionBarra } from "~/lib/barra";
import { useRecurso } from "~/lib/recurso";
import type { Bandeja, IncResumen } from "~/lib/tipos";
import { toast, UiCtx, useDialog } from "~/lib/ui";

const desdeTexto = (iso: string | null): string => {
  if (!iso) return "";
  const r = relativo(iso);
  if (r.startsWith("ayer")) return "desde ayer";
  if (r.startsWith("hace")) return `desde ${r}`;
  return `desde el ${r}`;
};

const GrupoLista = component$<{ id: string; titulo: string; items: IncResumen[]; sel: number }>((p) => (
  <section class="lista-grupo" aria-labelledby={p.id}>
    <h2 class="lista-grupo-titulo" id={p.id}>
      {p.titulo}
      <span class="lista-grupo-cuenta"> · {p.items.length}</span>
    </h2>
    <ul class="lista-inc">
      {p.items.map((i) => (
        <FilaIncidencia key={i.id} inc={i} href={u(`/bandeja?inc=${i.id}`)} activa={p.sel === i.id} />
      ))}
    </ul>
  </section>
));

/** 02 · Bandeja. ¿Qué atiendo ahora? Tres grupos sin tarjetas: Vencen pronto, Mías, Sin asignar. Atajos como en Mail:
 *  j / k para moverse, ↵ para abrir, a para asignarme, e para resolver. */
export default component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const dialog = useDialog();
  const { r, recargar, refrescar } = useRecurso<Bandeja>("/api/bandeja", { cadaMs: 60_000 });
  const inc = useParam("inc");

  // El contador del lateral es lo que pide acción ahora.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const d = track(() => r.datos);
      if (d) ui.contador = d.contador;
    },
    { strategy: "document-ready" },
  );

  const abrirPrimera = $(async () => {
    const b = r.datos;
    const primero = b?.vencen_pronto[0] ?? b?.mias[0] ?? b?.sin_asignar[0];
    if (primero) await nav(u(`/bandeja?inc=${primero.id}`));
    else toast("No hay nada que atender ahora.");
  });
  const nadaQueAbrir = useComputed$(() => !r.datos || r.datos.vencen_pronto.length + r.datos.mias.length + r.datos.sin_asignar.length === 0);
  useAccionBarra("Abrir la que vence primero", abrirPrimera, "Abrir primera", nadaQueAbrir);

  const volver = $(async () => {
    await nav(u("/bandeja"));
  });

  const asignarme = $(async (id: number, numero: string) => {
    if (!ui.usuario?.tecnico_id) {
      toast("Tu usuario no está vinculado a un técnico, así que no puede recibir incidencias.");
      return;
    }
    try {
      await api(`/api/incidencias/${id}/acciones`, { method: "POST", json: { accion: "asignar", tecnico_id: ui.usuario.tecnico_id } });
      toast(`${numero} asignada a ti.`, "ok");
      await refrescar();
    } catch (e) {
      toast(mensajeError(e), "error");
    }
  });

  const resolver = $(async (id: number, numero: string) => {
    const nota = await dialog.prompt({ titulo: `Resolver ${numero}`, texto: "La persona recibirá el aviso de que quedó resuelta.", label: "Qué se hizo (opcional)", largo: true, ok: "Resolver" });
    if (nota === null) return;
    try {
      await api(`/api/incidencias/${id}/acciones`, { method: "POST", json: { accion: "resolver", nota } });
      toast(`${numero} resuelta.`, "ok");
      if (Number(inc.value) === id) await nav(u("/bandeja"));
      await refrescar();
    } catch (e) {
      toast(mensajeError(e), "error");
    }
  });

  // Atajos de teclado (solo cuando no se escribe ni hay un diálogo, hoja o buscador encima).
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ cleanup }) => {
      const tecla = (e: KeyboardEvent) => {
        if (e.metaKey || e.ctrlKey || e.altKey || escribiendo(e.target)) return;
        if (document.querySelector(".dialogo-capa, .hoja-capa, .buscador-capa")) return;
        const filas = Array.from(document.querySelectorAll<HTMLElement>(".md-lista [data-fila]"));
        if (!filas.length) return;
        const actual = document.activeElement?.closest<HTMLElement>("[data-fila]") ?? null;
        const i = actual ? filas.indexOf(actual) : -1;
        if (e.key === "j") {
          e.preventDefault();
          (filas[Math.min(filas.length - 1, i + 1)] ?? filas[0]).focus();
        } else if (e.key === "k") {
          e.preventDefault();
          (filas[Math.max(0, i - 1)] ?? filas[0]).focus();
        } else if ((e.key === "a" || e.key === "e") && actual) {
          e.preventDefault();
          const id = Number(actual.dataset.incId);
          const numero = actual.dataset.numero ?? "";
          if (e.key === "a") asignarme(id, numero);
          else resolver(id, numero);
        }
      };
      window.addEventListener("keydown", tecla);
      cleanup(() => window.removeEventListener("keydown", tecla));
    },
    { strategy: "document-ready" },
  );

  const b = r.datos;
  const vencidas = b ? b.vencen_pronto.filter((i) => i.sla?.vencida).length : 0;
  const proxHora = b ? b.vencen_pronto.filter((i) => !i.sla?.vencida && (i.sla?.restante_min ?? 999) <= 60).length : 0;
  const total = b ? b.vencen_pronto.length + b.mias.length + b.sin_asignar.length : 0;
  const mias = b ? b.mias.length + b.vencen_pronto.filter((i) => i.tecnico?.id === ui.usuario?.tecnico_id).length : 0;

  let titular = "";
  if (b) {
    const partes: string[] = [];
    if (vencidas) partes.push(plural(vencidas, "vencida", "vencidas"));
    if (proxHora) partes.push(`${proxHora} ${proxHora === 1 ? "vence" : "vencen"} en la próxima hora`);
    titular = partes.length ? partes.join(" · ") : b.vencen_pronto.length ? "Nada vence en la próxima hora." : "Nada vence hoy.";
  }

  const sel = Number(inc.value) || 0;
  const modo = ui.vp === "ancho" ? "panel" : ui.vp === "medio" ? "hoja" : "pagina";

  return (
    <MaestroDetalle haySel={sel > 0} titulo="Incidencia" atras="Bandeja" vacio="Elige una incidencia para ver su resumen y responder sin salir de la lista." onCerrar$={volver}>
      <div q:slot="lista">
        {r.estado === "cargando" && !b && (
          <>
            <div class="bandeja-titular esq-titular">
              <span class="esq-linea" style={{ width: "62%", height: "26px" }} />
            </div>
            <EsqueletoFilas n={8} etiqueta="Cargando la bandeja" />
            {r.lento && <EsperaLarga texto="Sigue cargando… el servidor está tardando más de lo normal." />}
          </>
        )}
        {r.estado === "error" && !b && (
          <Falla titulo="No pudimos cargar la bandeja." texto={`${r.error} Tus incidencias no cambiaron.`} sinRed={r.sinRed} onReintentar$={recargar} />
        )}
        {b && (
          <>
            <header class="bandeja-titular">
              <h2 class="bandeja-cifra">{titular}</h2>
              {total > 0 && (
                <p class="bandeja-sub">
                  {b.vencen_pronto.length > 0 && <span>{plural(b.vencen_pronto.length, "pasó", "pasaron")} del 75 % del plazo · </span>}
                  <span>{plural(mias, "mía", "mías")}</span>
                  {b.sin_asignar.length > 0 && <span> · {b.sin_asignar.length} sin asignar</span>}
                </p>
              )}
              {b.vencen_pronto.length === 0 && b.espera_usuario && b.espera_usuario.cantidad > 0 && (
                <p class="bandeja-espera">
                  {plural(b.espera_usuario.cantidad, "espera", "esperan")} respuesta de la persona {desdeTexto(b.espera_usuario.desde)} ·{" "}
                  <Enlace a="/incidencias?estado=espera_usuario">Ver</Enlace>
                </p>
              )}
            </header>
            {total === 0 && !(b.espera_usuario && b.espera_usuario.cantidad > 0) && (
              <Vacio titulo="No tienes nada pendiente." texto="Ninguna incidencia asignada y ninguna sin asignar." accion="Ver todas las incidencias" href={u("/incidencias")} />
            )}
            {b.vencen_pronto.length > 0 && <GrupoLista id="g-vencen" titulo="Vencen pronto" items={b.vencen_pronto} sel={sel} />}
            {b.mias.length > 0 && <GrupoLista id="g-mias" titulo="Mías" items={b.mias} sel={sel} />}
            {b.sin_asignar.length > 0 && <GrupoLista id="g-sin" titulo="Sin asignar" items={b.sin_asignar} sel={sel} />}
            {total > 0 && (
              <p class="atajos" aria-hidden="true">
                <kbd>j</kbd> <kbd>k</kbd> moverse · <kbd>↵</kbd> abrir · <kbd>a</kbd> asignarme · <kbd>e</kbd> resolver
              </p>
            )}
          </>
        )}
      </div>
      <div q:slot="detalle">{sel > 0 && <DetalleIncidencia key={sel} id={sel} modo={modo} onCerrar$={volver} />}</div>
    </MaestroDetalle>
  );
});

export const head: DocumentHead = { title: "Bandeja · jsrbot" };
