import { $, component$, useComputed$, useContext, useSignal, useVisibleTask$, type QRL } from "@builder.io/qwik";
import { useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { DetalleIncidencia, FilaIncidencia } from "~/components/incidencias";
import { MaestroDetalle } from "~/components/maestro";
import { Campo, Selector } from "~/components/ui/campo";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Hoja } from "~/components/ui/hoja";
import { Icono } from "~/components/ui/icono";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla, Vacio } from "~/components/ui/vacio";
import { api, mensajeError } from "~/lib/api";
import { u } from "~/lib/base";
import { CATEGORIA_TEXTO, ESTADO_TEXTO, plural } from "~/lib/format";
import { useParam } from "~/lib/params";
import { useRecurso } from "~/lib/recurso";
import type { IncDetalle, IncResumen, Lista, Tecnico } from "~/lib/tipos";
import { toast, UiCtx } from "~/lib/ui";

const POR_PAGINA = 40;

/** 04 · Incidencias. ¿Dónde está tal incidencia? Una búsqueda, tres filtros y la lista; el detalle se abre al lado. */
export default component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const inc = useParam("inc");
  const estadoUrl = useParam("estado");
  const tecUrl = useParam("tecnico_id");

  const busca = useSignal("");
  const q = useSignal("");
  const estado = useSignal("abiertas");
  const prio = useSignal("");
  const tec = useSignal("");
  const cat = useSignal("");
  const paginas = useSignal(1);
  const nueva = useSignal(false);
  const tecnicos = useSignal<Tecnico[]>([]);
  const filtrosAbiertos = useSignal(false);

  // Filtros que llegan en la URL (desde la bandeja: ?estado=espera_usuario).
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const e = track(() => estadoUrl.value);
      const t = track(() => tecUrl.value);
      if (e) estado.value = e;
      if (t) tec.value = t;
    },
    { strategy: "document-ready" },
  );

  // Búsqueda con espera de 250 ms: no se consulta en cada tecla.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track, cleanup }) => {
      const t = track(() => busca.value);
      const id = setTimeout(() => (q.value = t), 250);
      cleanup(() => clearTimeout(id));
    },
    { strategy: "document-ready" },
  );

  // Técnicos para el filtro (solo supervisores y superiores pueden listarlos).
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    async () => {
      const rol = ui.usuario?.rol;
      if (rol === "supervisor" || rol === "gerencia" || rol === "admin") {
        try {
          tecnicos.value = (await api<Lista<Tecnico>>("/api/tecnicos?por_pagina=100")).items;
        } catch {
          /* el filtro queda con las opciones fijas */
        }
      }
    },
    { strategy: "document-ready" },
  );

  const ruta = useComputed$(() => {
    const p = new URLSearchParams();
    if (estado.value === "abiertas") p.set("abiertas", "1");
    else if (estado.value === "resueltas") p.set("estado", "resuelta");
    else if (estado.value !== "todas") p.set("estado", estado.value);
    if (prio.value) p.set("prioridad", prio.value);
    if (tec.value) p.set("tecnico_id", tec.value);
    if (cat.value) p.set("categoria", cat.value);
    if (q.value.trim()) p.set("q", q.value.trim());
    p.set("por_pagina", String(POR_PAGINA * paginas.value));
    return `/api/incidencias?${p.toString()}`;
  });
  const { r, recargar } = useRecurso<Lista<IncResumen>>(ruta);

  const volver = $(async () => {
    await nav(u("/incidencias"));
  });
  const limpiar = $(() => {
    busca.value = "";
    q.value = "";
    estado.value = "abiertas";
    prio.value = "";
    tec.value = "";
    cat.value = "";
    paginas.value = 1;
  });

  const sel = Number(inc.value) || 0;
  const modo = ui.vp === "ancho" ? "panel" : ui.vp === "medio" ? "hoja" : "pagina";
  const d = r.datos;
  const hayFiltros = !!(q.value || prio.value || tec.value || cat.value || (estado.value !== "abiertas"));
  const miId = ui.usuario?.tecnico_id;

  return (
    <>
      <MaestroDetalle haySel={sel > 0} titulo="Incidencia" atras="Incidencias" vacio="Elige una incidencia para ver su detalle al lado de la lista." onCerrar$={volver}>
        <div q:slot="lista">
          <div class="filtros">
            <div class="filtros-buscar">
              <Icono n="buscar" tam={16} />
              <input
                type="search"
                aria-label="Buscar por número, asunto o persona"
                placeholder="Buscar por número, asunto o persona"
                value={busca.value}
                onInput$={(_, el) => {
                  busca.value = el.value;
                  paginas.value = 1;
                }}
              />
            </div>
            <div class="filtros-fila">
              <Segmentado
                etiqueta="Estado"
                valor={["abiertas", "resueltas", "todas"].includes(estado.value) ? estado.value : ""}
                onCambio$={(v) => {
                  estado.value = v;
                  paginas.value = 1;
                }}
                opciones={[
                  { valor: "abiertas", titulo: "Abiertas" },
                  { valor: "resueltas", titulo: "Resueltas" },
                  { valor: "todas", titulo: "Todas" },
                ]}
              />
              <button type="button" class="boton boton-secundario boton-pequeno" aria-expanded={filtrosAbiertos.value} onClick$={() => (filtrosAbiertos.value = !filtrosAbiertos.value)}>
                Filtros{prio.value || tec.value || cat.value ? " · activos" : ""}
              </button>
              <button type="button" class="boton boton-secundario boton-pequeno filtros-nueva" onClick$={() => (nueva.value = true)}>
                Nueva incidencia
              </button>
            </div>
            {!["abiertas", "resueltas", "todas"].includes(estado.value) && (
              <p class="filtros-chip">
                Estado: {ESTADO_TEXTO[estado.value] ?? estado.value}{" "}
                <button type="button" class="chip-quitar" aria-label="Quitar el filtro de estado" onClick$={() => (estado.value = "abiertas")}>
                  <Icono n="cerrar" tam={12} />
                </button>
              </p>
            )}
            {filtrosAbiertos.value && (
              <div class="filtros-selects">
                <Selector
                  etiqueta="Prioridad"
                  nombre="prio"
                  valor={prio.value}
                  onValor$={(v) => (prio.value = v)}
                  opciones={[{ valor: "", titulo: "Todas" }, { valor: "P1", titulo: "P1 · Crítica" }, { valor: "P2", titulo: "P2 · Alta" }, { valor: "P3", titulo: "P3 · Media" }, { valor: "P4", titulo: "P4 · Baja" }]}
                />
                <Selector
                  etiqueta="Responsable"
                  nombre="tec"
                  valor={tec.value}
                  onValor$={(v) => (tec.value = v)}
                  opciones={[
                    { valor: "", titulo: "Todos" },
                    { valor: "sin", titulo: "Sin asignar" },
                    ...(miId ? [{ valor: String(miId), titulo: "Mías" }] : []),
                    ...tecnicos.value.filter((t) => t.id !== miId).map((t) => ({ valor: String(t.id), titulo: t.nombre })),
                  ]}
                />
                <Selector
                  etiqueta="Categoría"
                  nombre="cat"
                  valor={cat.value}
                  onValor$={(v) => (cat.value = v)}
                  opciones={[{ valor: "", titulo: "Todas" }, ...Object.entries(CATEGORIA_TEXTO).map(([valor, titulo]) => ({ valor, titulo }))]}
                />
              </div>
            )}
          </div>

          {r.estado === "cargando" && !d && <EsqueletoFilas n={9} etiqueta="Cargando las incidencias" />}
          {r.estado === "error" && !d && <Falla titulo="No pudimos cargar las incidencias." texto={`${r.error} Los filtros que elegiste siguen puestos.`} sinRed={r.sinRed} onReintentar$={recargar} />}
          {d && (
            <div aria-busy={r.estado === "cargando"} class={r.estado === "cargando" ? "recargando" : ""}>
              <p class="lista-meta" role="status">
                {d.total === 0 ? "Sin resultados" : `${plural(d.total, "incidencia", "incidencias")}${d.items.length < d.total ? ` · se muestran ${d.items.length}` : ""}`}
              </p>
              {d.items.length === 0 ? (
                <Vacio
                  titulo={hayFiltros ? "Ninguna incidencia coincide con estos filtros." : "Todavía no hay incidencias."}
                  texto={hayFiltros ? "Prueba con otra palabra o quita algún filtro." : "Cuando el asistente o un técnico abra una, aparecerá aquí."}
                  accion={hayFiltros ? "Quitar los filtros" : undefined}
                  onAccion$={hayFiltros ? limpiar : undefined}
                />
              ) : (
                <ul class="lista-inc">
                  {d.items.map((i) => (
                    <FilaIncidencia key={i.id} inc={i} extra href={u(`/incidencias?inc=${i.id}`)} activa={sel === i.id} />
                  ))}
                </ul>
              )}
              {d.items.length < d.total && (
                <div class="lista-mas">
                  <button type="button" class="boton boton-secundario" onClick$={() => (paginas.value = paginas.value + 1)}>
                    Ver {Math.min(POR_PAGINA, d.total - d.items.length)} más
                  </button>
                </div>
              )}
            </div>
          )}
        </div>
        <div q:slot="detalle">{sel > 0 && <DetalleIncidencia key={sel} id={sel} modo={modo} onCerrar$={volver} />}</div>
      </MaestroDetalle>
      {nueva.value && (
        <NuevaIncidencia
          onCerrar$={() => (nueva.value = false)}
          onCreada$={async (idNueva) => {
            nueva.value = false;
            await recargar();
            await nav(u(`/incidencias?inc=${idNueva}`));
          }}
        />
      )}
    </>
  );
});

// ---------------------------------------------------------------------------------------------------------------
const NuevaIncidencia = component$<{ onCerrar$: QRL<() => void>; onCreada$: QRL<(id: number) => void> }>((p) => {
  const asunto = useSignal("");
  const resumen = useSignal("");
  const persona = useSignal("");
  const categoria = useSignal("otro");
  const prioridad = useSignal("P3");
  const errorAsunto = useSignal("");
  const enviando = useSignal(false);

  const guardar = $(async () => {
    errorAsunto.value = "";
    if (!asunto.value.trim()) {
      errorAsunto.value = "Escribe el asunto: una frase que diga qué pasa.";
      document.getElementById("c-asunto")?.focus();
      return;
    }
    enviando.value = true;
    try {
      const nuevaInc = await api<IncDetalle>("/api/incidencias", {
        method: "POST",
        json: { titulo: asunto.value.trim(), resumen: resumen.value.trim(), persona_texto: persona.value.trim() || undefined, categoria: categoria.value, prioridad: prioridad.value },
      });
      toast(`${nuevaInc.numero} creada.`, "ok");
      await p.onCreada$(nuevaInc.id);
    } catch (e) {
      toast(`No se pudo crear la incidencia. ${mensajeError(e)} Lo que escribiste sigue aquí.`, "error");
    } finally {
      enviando.value = false;
    }
  });

  return (
    <Hoja titulo="Nueva incidencia" subtitulo="Alta manual: para lo que llega por teléfono o en persona." onCerrar$={p.onCerrar$} pie>
      <form class="formulario" preventdefault:submit onSubmit$={guardar} id="form-nueva">
        <Campo etiqueta="Asunto" nombre="asunto" valor={asunto.value} onValor$={(v) => (asunto.value = v)} error={errorAsunto.value} requerido marcador="Ej.: Outlook no recibe correos" />
        <Campo etiqueta="Persona" nombre="persona" valor={persona.value} onValor$={(v) => (persona.value = v)} opcional ayuda="Nombre, correo o WhatsApp de quien reporta." />
        <Campo etiqueta="Descripción" nombre="resumen" valor={resumen.value} onValor$={(v) => (resumen.value = v)} filas={4} opcional />
        <div class="formulario-dos">
          <Selector etiqueta="Categoría" nombre="categoria" valor={categoria.value} onValor$={(v) => (categoria.value = v)} opciones={Object.entries(CATEGORIA_TEXTO).map(([valor, titulo]) => ({ valor, titulo }))} />
          <Selector
            etiqueta="Prioridad"
            nombre="prioridad"
            valor={prioridad.value}
            onValor$={(v) => (prioridad.value = v)}
            ayuda="El plazo sale de la prioridad."
            opciones={[{ valor: "P1", titulo: "P1 · Crítica" }, { valor: "P2", titulo: "P2 · Alta" }, { valor: "P3", titulo: "P3 · Media" }, { valor: "P4", titulo: "P4 · Baja" }]}
          />
        </div>
      </form>
      <div q:slot="pie">
        <button type="button" class="boton boton-secundario" onClick$={p.onCerrar$}>
          Cancelar
        </button>
        <button type="submit" form="form-nueva" class="boton boton-principal" disabled={enviando.value} aria-busy={enviando.value ? "true" : undefined}>
          Crear incidencia
        </button>
      </div>
    </Hoja>
  );
});

export const head: DocumentHead = { title: "Incidencias · jsrbot" };
