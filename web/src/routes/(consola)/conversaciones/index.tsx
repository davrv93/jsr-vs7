import { $, component$, useComputed$, useContext, useSignal } from "@builder.io/qwik";
import { Link, useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { DetalleCaso } from "~/components/casos";
import { MaestroDetalle } from "~/components/maestro";
import { Avatar } from "~/components/ui/avatar";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla, Vacio } from "~/components/ui/vacio";
import { u } from "~/lib/base";
import { plural, relativo } from "~/lib/format";
import { useParam } from "~/lib/params";
import { useRecurso } from "~/lib/recurso";
import type { Caso, Lista } from "~/lib/tipos";
import { UiCtx } from "~/lib/ui";

const quien = (c: Caso, yo?: string): string => {
  if (c.pausado_por_tecnico) return c.tomado_por === yo ? "Tú" : (c.tomado_por ?? "Técnico").split(" ")[0];
  if (c.incidencia_numero) return c.incidencia_numero;
  if (c.estado === "resuelto_asistente") return "Resuelta";
  return "Asistente";
};

/** 05 · Conversaciones. ¿Qué está atendiendo el asistente ahora? Acción principal: Tomar la conversación (en el detalle). */
export default component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const caso = useParam("caso");
  const filtro = useSignal("");
  const ruta = useComputed$(() => `/api/casos?por_pagina=100${filtro.value ? `&estado=${filtro.value}` : ""}`);
  const { r, recargar } = useRecurso<Lista<Caso>>(ruta);
  const volver = $(async () => {
    await nav(u("/conversaciones"));
  });
  const sel = Number(caso.value) || 0;
  const modo = ui.vp === "ancho" ? "panel" : ui.vp === "medio" ? "hoja" : "pagina";
  const d = r.datos;
  return (
    <MaestroDetalle haySel={sel > 0} titulo="Conversación" atras="Conversaciones" vacio="Elige una conversación para leerla y, si hace falta, tomarla." onCerrar$={volver}>
      <div q:slot="lista">
        <div class="filtros">
          <Segmentado
            etiqueta="Estado de la conversación"
            valor={filtro.value}
            onCambio$={(v) => (filtro.value = v)}
            opciones={[
              { valor: "", titulo: "Todas" },
              { valor: "abierto", titulo: "Abiertas" },
              { valor: "con_incidencia", titulo: "Con incidencia" },
              { valor: "resuelto_asistente", titulo: "Resueltas" },
            ]}
          />
        </div>
        {r.estado === "cargando" && !d && <EsqueletoFilas n={8} etiqueta="Cargando las conversaciones" />}
        {r.estado === "error" && !d && <Falla titulo="No pudimos cargar las conversaciones." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />}
        {d && (
          <div class={r.estado === "cargando" ? "recargando" : ""}>
            <p class="lista-meta" role="status">
              {plural(d.total, "conversación", "conversaciones")}
            </p>
            {d.items.length === 0 ? (
              <Vacio titulo="No hay conversaciones con este filtro." texto="Cuando alguien escriba por WhatsApp o por el chat web, aparecerá aquí." accion={filtro.value ? "Ver todas" : undefined} onAccion$={filtro.value ? $(() => (filtro.value = "")) : undefined} />
            ) : (
              <ul class="lista-inc">
                {d.items.map((c) => (
                  <li class="fila-inc-li" key={c.id}>
                    <Link href={u(`/conversaciones?caso=${c.id}`)} class={`fila-inc fila-tec${sel === c.id ? " activa" : ""}`} data-fila="" aria-current={sel === c.id ? "true" : undefined}>
                      <Avatar nombre={c.persona?.nombre} tam={32} />
                      <span class="fila-inc-cuerpo">
                        <span class="fila-inc-l1">
                          <span class="fila-inc-asunto">{c.persona?.nombre ?? "Persona sin identificar"}</span>
                        </span>
                        <span class="fila-inc-l2">{c.ultimo_texto}</span>
                      </span>
                      <span class="fila-caso-der">
                        <span class="fila-caso-hora">{relativo(c.ultimo_mensaje)}</span>
                        <span class="fila-caso-quien">{quien(c, ui.usuario?.nombre)}</span>
                      </span>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>
      <div q:slot="detalle">{sel > 0 && <DetalleCaso key={sel} id={sel} modo={modo} onCerrar$={volver} />}</div>
    </MaestroDetalle>
  );
});

export const head: DocumentHead = { title: "Conversaciones · jsrbot" };
