import { $, component$, useContext, useSignal, type QRL } from "@builder.io/qwik";
import { api, mensajeError } from "~/lib/api";
import { CANAL_TEXTO, ETAPA_TEXTO, nombreCorto } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { Caso, MensajeCaso } from "~/lib/tipos";
import { toast, UiCtx, useDialog } from "~/lib/ui";
import { Hilo } from "./incidencias";
import { Icono } from "./ui/icono";
import { EsqueletoDetalle } from "./ui/esqueleto";
import { Falla, Vacio } from "./ui/vacio";

interface Props {
  id: number;
  modo: "panel" | "hoja" | "pagina";
  onCerrar$?: QRL<() => void>;
}

interface Respuesta {
  caso: Caso;
  items: MensajeCaso[];
  total: number;
}

/** Detalle de una conversación (05): qué está atendiendo el asistente ahora. Acción principal: Tomar la conversación;
 *  el asistente deja de contestar y escribe la persona. */
export const DetalleCaso = component$<Props>((p) => {
  const ui = useContext(UiCtx);
  const dialog = useDialog();
  const { r, recargar, refrescar } = useRecurso<Respuesta>(`/api/casos/${p.id}/mensajes`);
  const texto = useSignal("");
  const enviando = useSignal(false);
  const tomando = useSignal(false);
  const verTodo = useSignal(false);

  const tomar = $(async () => {
    const ok = await dialog.confirm({ titulo: "¿Tomar la conversación?", texto: "El asistente dejará de contestar y escribirás tú. Puedes devolvérsela cuando termines.", ok: "Tomar la conversación" });
    if (!ok) return;
    tomando.value = true;
    try {
      await api(`/api/casos/${p.id}/tomar`, { method: "POST", json: {} });
      toast("Tomaste la conversación. El asistente ya no contesta.", "ok");
      await refrescar();
      ui.tick++;
    } catch (e) {
      toast(mensajeError(e), "error");
    } finally {
      tomando.value = false;
    }
  });

  const devolver = $(async () => {
    try {
      await api(`/api/casos/${p.id}/devolver`, { method: "POST", json: {} });
      toast("Devolviste la conversación al asistente.", "ok");
      await refrescar();
      ui.tick++;
    } catch (e) {
      toast(mensajeError(e), "error");
    }
  });

  const enviar = $(async () => {
    const t = texto.value.trim();
    if (!t || enviando.value) return;
    enviando.value = true;
    try {
      await api(`/api/casos/${p.id}/mensajes`, { method: "POST", json: { texto: t } });
      texto.value = "";
      await refrescar();
    } catch (e) {
      toast(`No se pudo enviar. ${mensajeError(e)} Tu texto sigue aquí.`, "error");
    } finally {
      enviando.value = false;
    }
  });

  if (r.estado === "cargando" && !r.datos) return <div class={`detalle detalle-${p.modo}`}><EsqueletoDetalle /></div>;
  if (r.estado === "error" && !r.datos) {
    return (
      <div class={`detalle detalle-${p.modo}`}>
        {r.error.includes("No encontramos") ? <Vacio titulo="Esta conversación ya no existe." accion="Volver a la lista" onAccion$={p.onCerrar$} /> : <Falla titulo="No pudimos abrir la conversación." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />}
      </div>
    );
  }
  const { caso, items } = r.datos!;
  const mia = caso.pausado_por_tecnico && caso.tomado_por === ui.usuario?.nombre;
  const deOtro = caso.pausado_por_tecnico && !mia;

  return (
    <article class={`detalle detalle-${p.modo}`} aria-label="Conversación">
      <div class="detalle-cuerpo">
        <header class="det-cab">
          <div class="det-sup">
            <span class="det-num">
              {CANAL_TEXTO[caso.canal]} · {ETAPA_TEXTO[caso.etapa] ?? caso.etapa}
            </span>
            <div class="det-acc">
              {p.modo === "panel" && p.onCerrar$ && (
                <button type="button" class="icono-boton" aria-label="Cerrar la conversación" onClick$={p.onCerrar$}>
                  <Icono n="cerrar" />
                </button>
              )}
            </div>
          </div>
          <h2 class="det-titulo">{caso.persona?.nombre ?? "Persona sin identificar"}</h2>
          <p class="det-persona">
            {caso.persona?.area ?? "Sin área"}
            {caso.persona?.sede ? ` · ${caso.persona.sede}` : ""}
            {caso.incidencia_numero ? ` · ${caso.incidencia_numero}` : ""}
          </p>
          <p class="det-estado">
            {caso.pausado_por_tecnico ? (mia ? "La atiendes tú. El asistente no contesta." : `La atiende ${nombreCorto(caso.tomado_por)}. El asistente no contesta.`) : caso.estado === "resuelto_asistente" ? "El asistente la resolvió." : "La está atendiendo el asistente."}
          </p>
        </header>
        <section class="det-sec">
          <h3 class="etiqueta-sec">Conversación · {items.length}</h3>
          {items.length ? (
            <>
              <Hilo mensajes={items} todos={verTodo.value} />
              {items.length > 6 && (
                <button type="button" class="boton boton-secundario boton-pequeno" onClick$={() => (verTodo.value = !verTodo.value)}>
                  {verTodo.value ? "Ver solo los últimos 6" : `Ver todo (${items.length})`}
                </button>
              )}
            </>
          ) : (
            <p class="det-vacio">Todavía no hay mensajes.</p>
          )}
        </section>
      </div>
      {!caso.pausado_por_tecnico ? (
        <div class="compositor compositor-fila">
          <p class="compositor-sugerido">Tómala si el asistente no está resolviendo el caso.</p>
          <button type="button" class="boton boton-principal" onClick$={tomar} disabled={tomando.value} aria-busy={tomando.value ? "true" : undefined}>
            Tomar la conversación
          </button>
        </div>
      ) : mia ? (
        <form class="compositor" preventdefault:submit onSubmit$={enviar} aria-label="Responder en la conversación">
          <label class="solo-lector" for={`caso-${p.id}`}>
            Mensaje para {caso.persona?.nombre ?? "la persona"}
          </label>
          <textarea id={`caso-${p.id}`} rows={3} placeholder="Escribe a la persona…" value={texto.value} onInput$={(_, el) => (texto.value = el.value)} onKeyDown$={(e) => e.key === "Enter" && (e.metaKey || e.ctrlKey) && enviar()} />
          <div class="compositor-pie">
            <span class="compositor-sugerido">
              Va por {CANAL_TEXTO[caso.canal]}.{" "}
              <button type="button" class="enlace-boton" onClick$={devolver}>
                Devolver al asistente
              </button>
            </span>
            <button type="submit" class="boton boton-principal" disabled={!texto.value.trim() || enviando.value} aria-busy={enviando.value ? "true" : undefined}>
              Enviar
            </button>
          </div>
        </form>
      ) : (
        deOtro && (
          <div class="compositor compositor-cerrada">
            <p class="det-vacio">{nombreCorto(caso.tomado_por)} ya tomó esta conversación.</p>
          </div>
        )
      )}
    </article>
  );
});
