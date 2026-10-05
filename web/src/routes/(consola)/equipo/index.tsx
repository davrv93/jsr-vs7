import { $, component$, useContext, useSignal } from "@builder.io/qwik";
import { Link, useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { MaestroDetalle } from "~/components/maestro";
import { FichaTecnico, NuevoTecnico } from "~/components/tecnicos";
import { Avatar } from "~/components/ui/avatar";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Falla, Vacio } from "~/components/ui/vacio";
import { useAccionBarra } from "~/lib/barra";
import { u } from "~/lib/base";
import { plural } from "~/lib/format";
import { useParam } from "~/lib/params";
import { useRecurso } from "~/lib/recurso";
import type { Grupo, Lista, Tecnico } from "~/lib/tipos";
import { UiCtx } from "~/lib/ui";

const FilaTecnico = component$<{ t: Tecnico; activa: boolean }>((p) => {
  const t = p.t;
  const pct = Math.min(100, Math.round((t.carga / Math.max(1, t.capacidad)) * 100));
  const sobre = t.carga > t.capacidad;
  const sinHab = t.habilidades.length === 0;
  const sinTurnos = t.turnos.length === 0;
  const detalle = [t.nivel, sinHab ? "sin habilidades" : plural(t.habilidades.length, "habilidad", "habilidades"), sinTurnos ? "sin turnos" : ""].filter(Boolean).join(" · ");
  return (
    <li class="fila-inc-li">
      <Link href={u(`/equipo?tec=${t.id}`)} class={`fila-inc fila-tec${p.activa ? " activa" : ""}`} aria-current={p.activa ? "true" : undefined} data-fila="">
        <Avatar nombre={t.nombre} tam={32} foto={t.foto} />
        <span class="fila-inc-cuerpo">
          <span class="fila-inc-l1">
            <span class="fila-inc-asunto">{t.nombre}</span>
          </span>
          <span class="fila-inc-l2">{detalle}</span>
        </span>
        {t.estado !== "activo" ? (
          <span class="fila-tec-estado">{t.estado === "ausente" ? "Ausente" : "Inactivo"}</span>
        ) : (
          <span class="fila-tec-carga">
            <span class={`fila-tec-num${sobre ? " plazo-por_vencer" : ""}`}>
              {t.carga} de {t.capacidad}
            </span>
            <span class="barra-fina" role="img" aria-label={`${pct} % de su capacidad`}>
              <span style={{ width: `${pct}%` }} class={sobre ? "llena" : ""} />
            </span>
          </span>
        )}
      </Link>
    </li>
  );
});

/** 06 · Equipo. ¿Quién está, en qué grupo, con cuánta carga? Acción principal: Añadir técnico. */
export default component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const tec = useParam("tec");
  const nuevo = useSignal(false);
  const { r, recargar } = useRecurso<Lista<Tecnico>>("/api/tecnicos?por_pagina=100");
  const g = useRecurso<Lista<Grupo>>("/api/grupos");

  const abrirNuevo = $(() => {
    nuevo.value = true;
  });
  useAccionBarra("Añadir técnico", abrirNuevo, "Añadir");
  const volver = $(async () => {
    await nav(u("/equipo"));
  });

  const sel = Number(tec.value) || 0;
  const modo = ui.vp === "ancho" ? "panel" : ui.vp === "medio" ? "hoja" : "pagina";
  const d = r.datos;
  const grupos = g.r.datos?.items ?? [];
  const secciones = [
    ...grupos.map((gr) => ({ id: gr.id, titulo: gr.nombre, nivel: gr.nivel, tecnicos: (d?.items ?? []).filter((t) => t.grupos.some((x) => x.id === gr.id)) })),
    { id: 0, titulo: "Sin grupo", nivel: "", tecnicos: (d?.items ?? []).filter((t) => t.grupos.length === 0) },
  ].filter((s) => s.id !== 0 || s.tecnicos.length);
  const total = d?.total ?? 0;
  const disponibles = d ? d.items.filter((t) => t.estado === "activo").length : 0;

  return (
    <>
      <MaestroDetalle haySel={sel > 0} titulo="Ficha del técnico" atras="Equipo" vacio="Elige a una persona para ver sus habilidades, turnos y carga." onCerrar$={volver}>
        <div q:slot="lista">
          {r.estado === "cargando" && !d && <EsqueletoFilas n={8} etiqueta="Cargando el equipo" />}
          {r.estado === "error" && !d && <Falla titulo="No pudimos cargar el equipo." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />}
          {d && (
            <>
              <header class="bandeja-titular">
                <h2 class="bandeja-cifra">{plural(total, "persona", "personas")}</h2>
                <p class="bandeja-sub">
                  {disponibles} {disponibles === 1 ? "disponible" : "disponibles"} · {d.items.reduce((n, t) => n + t.carga, 0)} incidencias abiertas repartidas
                </p>
              </header>
              {total === 0 && <Vacio titulo="Todavía no hay técnicos en el equipo." texto="Añade a la primera persona para que pueda recibir incidencias." accion="Añadir técnico" onAccion$={abrirNuevo} />}
              {secciones.map((s) => (
                <section class="lista-grupo" key={s.id} aria-labelledby={`gr-${s.id}`}>
                  <h2 class="lista-grupo-titulo" id={`gr-${s.id}`}>
                    {s.titulo}
                    {s.nivel && <span class="lista-grupo-cuenta"> · {s.nivel}</span>}
                    <span class="lista-grupo-cuenta"> · {s.tecnicos.length}</span>
                  </h2>
                  {s.tecnicos.length === 0 ? (
                    <p class="lista-vacia-grupo">Sin miembros. Añádelos desde la ficha de cada técnico.</p>
                  ) : (
                    <ul class="lista-inc">
                      {s.tecnicos.map((t) => (
                        <FilaTecnico key={`${s.id}-${t.id}`} t={t} activa={sel === t.id} />
                      ))}
                    </ul>
                  )}
                </section>
              ))}
            </>
          )}
        </div>
        <div q:slot="detalle">{sel > 0 && <FichaTecnico key={sel} id={sel} modo={modo} onCerrar$={volver} onGuardada$={recargar} />}</div>
      </MaestroDetalle>
      {nuevo.value && (
        <NuevoTecnico
          onCerrar$={() => (nuevo.value = false)}
          onCreado$={async (id) => {
            nuevo.value = false;
            await recargar();
            await nav(u(`/equipo?tec=${id}`));
          }}
        />
      )}
    </>
  );
});

export const head: DocumentHead = { title: "Equipo · jsrbot" };
