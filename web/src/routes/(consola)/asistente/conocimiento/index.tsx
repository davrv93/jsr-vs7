import { $, component$, useComputed$, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import { useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { Boton } from "~/components/ui/boton";
import { Campo, Selector } from "~/components/ui/campo";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Hoja } from "~/components/ui/hoja";
import { Icono } from "~/components/ui/icono";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla, Vacio } from "~/components/ui/vacio";
import { api, mensajeError } from "~/lib/api";
import { useAccionBarra } from "~/lib/barra";
import { u } from "~/lib/base";
import { CATEGORIA_TEXTO, plural, relativo } from "~/lib/format";
import { useParam } from "~/lib/params";
import { useRecurso } from "~/lib/recurso";
import type { Articulo, Lista } from "~/lib/tipos";
import { toast, useDialog } from "~/lib/ui";

const ESTADO_ART: Record<string, string> = { publicado: "Publicado", borrador: "Borrador", archivado: "Archivado" };

interface FormArt {
  id: number;
  titulo: string;
  categoria: string;
  sintomas: string;
  pasos: string;
  estado: string;
  supuesto: boolean;
  clave: string;
  errores: Record<string, string>;
  guardando: boolean;
}

/** 12 · Asistente · Conocimiento. ¿Qué sabe responder? Acción principal: Nuevo artículo. El asistente solo da pasos que
 *  están en un artículo; un artículo «sin revisar» es un supuesto hasta que la organización lo confirme. */
export default component$(() => {
  const nav = useNavigate();
  const dialog = useDialog();
  const artParam = useParam("art");
  const filtro = useSignal("publicado");
  const busca = useSignal("");
  const q = useSignal("");
  const editor = useSignal<"" | "nuevo" | "editar">("");
  const f = useStore<FormArt>({ id: 0, titulo: "", categoria: "otro", sintomas: "", pasos: "", estado: "borrador", supuesto: true, clave: "", errores: {}, guardando: false });

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track, cleanup }) => {
      const t = track(() => busca.value);
      const id = setTimeout(() => (q.value = t), 250);
      cleanup(() => clearTimeout(id));
    },
    { strategy: "document-ready" },
  );

  const ruta = useComputed$(() => `/api/articulos?por_pagina=200${filtro.value && filtro.value !== "todos" ? `&estado=${filtro.value}` : ""}${q.value.trim() ? `&q=${encodeURIComponent(q.value.trim())}` : ""}`);
  const { r, recargar, refrescar } = useRecurso<Lista<Articulo>>(ruta, { eventos: false });

  const abrirNuevo = $(() => {
    Object.assign(f, { id: 0, titulo: "", categoria: "otro", sintomas: "", pasos: "", estado: "borrador", supuesto: true, clave: "", errores: {}, guardando: false });
    editor.value = "nuevo";
  });
  useAccionBarra("Nuevo artículo", abrirNuevo, "Nuevo");

  const abrirEditar = $((a: Articulo) => {
    Object.assign(f, { id: a.id, titulo: a.titulo, categoria: a.categoria ?? "otro", sintomas: a.sintomas.join("\n"), pasos: a.pasos.join("\n"), estado: a.estado, supuesto: a.supuesto, clave: a.clave, errores: {}, guardando: false });
    editor.value = "editar";
  });

  // Un artículo abierto desde el buscador (?art=3).
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    async ({ track }) => {
      const id = Number(track(() => artParam.value)) || 0;
      if (!id) return;
      try {
        const l = await api<Lista<Articulo>>("/api/articulos?por_pagina=200");
        const a = l.items.find((x) => x.id === id);
        if (a) abrirEditar(a);
      } catch {
        /* sin el artículo, queda la lista */
      }
    },
    { strategy: "document-ready" },
  );

  const cerrar = $(async () => {
    editor.value = "";
    if (artParam.value) await nav(u("/asistente/conocimiento"), { replaceState: true });
  });

  const guardar = $(async () => {
    const e: Record<string, string> = {};
    const pasos = f.pasos.split("\n").map((x) => x.trim()).filter(Boolean);
    if (!f.titulo.trim()) e.titulo = "Escribe el título: el problema, como lo diría la persona.";
    if (pasos.length === 0) e.pasos = "Un artículo necesita al menos un paso.";
    f.errores = e;
    const primero = Object.keys(e)[0];
    if (primero) {
      document.getElementById(`c-art-${primero}`)?.focus();
      return;
    }
    f.guardando = true;
    try {
      const cuerpo = { titulo: f.titulo.trim(), categoria: f.categoria, sintomas: f.sintomas.split("\n").map((x) => x.trim()).filter(Boolean), pasos, estado: f.estado };
      if (editor.value === "nuevo") await api("/api/articulos", { method: "POST", json: cuerpo });
      else await api(`/api/articulos/${f.id}`, { method: "PUT", json: { ...cuerpo, supuesto: false } });
      toast(editor.value === "nuevo" ? "Artículo creado." : "Artículo guardado.", "ok");
      await cerrar();
      await refrescar();
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudo guardar el artículo", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      f.guardando = false;
    }
  });

  const archivar = $(async () => {
    try {
      await api(`/api/articulos/${f.id}`, { method: "PUT", json: { estado: "archivado" } });
      toast("Artículo archivado. El asistente deja de usarlo.", "ok");
      await cerrar();
      await refrescar();
    } catch (er) {
      toast(mensajeError(er), "error");
    }
  });

  const d = r.datos;
  return (
    <div class="pagina">
      <div class="filtros">
        <div class="filtros-buscar">
          <Icono n="buscar" tam={16} />
          <input type="search" aria-label="Buscar un artículo" placeholder="Buscar por título o síntoma" value={busca.value} onInput$={(_, el) => (busca.value = el.value)} />
        </div>
        <div class="filtros-fila">
          <Segmentado
            etiqueta="Estado del artículo"
            valor={filtro.value}
            onCambio$={(v) => (filtro.value = v)}
            opciones={[
              { valor: "publicado", titulo: "Publicados" },
              { valor: "borrador", titulo: "Borradores" },
              { valor: "archivado", titulo: "Archivados" },
              { valor: "todos", titulo: "Todos" },
            ]}
          />
        </div>
      </div>
      {r.estado === "cargando" && !d && <EsqueletoFilas n={7} etiqueta="Cargando los artículos" />}
      {r.estado === "error" && !d && <Falla titulo="No pudimos cargar los artículos." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />}
      {d && (
        <div class={r.estado === "cargando" ? "recargando" : ""}>
          <p class="lista-meta" role="status">
            {plural(d.total, "artículo", "artículos")}
          </p>
          {d.items.length === 0 ? (
            <Vacio
              titulo={q.value ? "Ningún artículo coincide con esa búsqueda." : filtro.value === "borrador" ? "No hay borradores." : filtro.value === "archivado" ? "No hay artículos archivados." : "Todavía no hay artículos."}
              texto={q.value ? "Prueba con otra palabra del síntoma." : "Sin artículos, el asistente no da pasos: deriva a una persona. Cada artículo es un síntoma y los pasos para resolverlo."}
              accion="Nuevo artículo"
              onAccion$={abrirNuevo}
            />
          ) : (
            <ul class="lista-inc">
              {d.items.map((a) => (
                <li class="fila-inc-li" key={a.id}>
                  <button type="button" class="fila-inc fila-art" onClick$={() => abrirEditar(a)}>
                    <span class="fila-inc-cuerpo">
                      <span class="fila-inc-l1">
                        <span class="fila-inc-num">{a.clave}</span>
                        <span class="fila-inc-asunto">{a.titulo}</span>
                      </span>
                      <span class="fila-inc-l2">
                        {a.categoria ? CATEGORIA_TEXTO[a.categoria] : "Sin categoría"} · {ESTADO_ART[a.estado]}
                        {a.supuesto ? " · sin revisar" : ""} · actualizado {relativo(a.actualizado_en)}
                      </span>
                    </span>
                    <span class="fila-art-uso">
                      <span class="fila-art-num">{a.usos ?? 0}</span>
                      <span class="fila-art-et">{a.resolvio_pct != null ? `${a.resolvio_pct} % resolvió` : "usos"}</span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {editor.value && (
        <Hoja
          titulo={editor.value === "nuevo" ? "Nuevo artículo" : `${f.clave} · versión de trabajo`}
          subtitulo={editor.value === "editar" && f.supuesto ? "Sin revisar: lo escribió un supuesto, confírmalo al guardar." : undefined}
          onCerrar$={cerrar}
          ancho="ancho"
          pie
        >
          <form class="formulario" preventdefault:submit onSubmit$={guardar} id="form-articulo" noValidate>
            <Campo etiqueta="Título" nombre="art-titulo" valor={f.titulo} onValor$={(v) => (f.titulo = v)} error={f.errores.titulo} marcador="Ej.: Outlook no recibe correos nuevos" />
            <div class="formulario-dos">
              <Selector etiqueta="Categoría" nombre="art-categoria" valor={f.categoria} onValor$={(v) => (f.categoria = v)} opciones={Object.entries(CATEGORIA_TEXTO).map(([valor, titulo]) => ({ valor, titulo }))} />
              <Selector
                etiqueta="Estado"
                nombre="art-estado"
                valor={f.estado}
                onValor$={(v) => (f.estado = v)}
                ayuda="Solo los publicados los usa el asistente."
                opciones={[{ valor: "borrador", titulo: "Borrador" }, { valor: "publicado", titulo: "Publicado" }, { valor: "archivado", titulo: "Archivado" }]}
              />
            </div>
            <Campo etiqueta="Síntomas" nombre="art-sintomas" filas={4} valor={f.sintomas} onValor$={(v) => (f.sintomas = v)} ayuda="Una frase por línea, como la escribiría la persona: «no llegan correos», «outlook no sincroniza»." opcional />
            <Campo etiqueta="Pasos" nombre="art-pasos" filas={7} valor={f.pasos} onValor$={(v) => (f.pasos = v)} error={f.errores.pasos} ayuda="Un paso por línea, en orden. El asistente los da de uno en uno." />
          </form>
          <div q:slot="pie">
            {editor.value === "editar" && f.estado !== "archivado" && (
              <Boton variante="peligro" confirmar={{ titulo: `¿Archivar «${f.titulo}»?`, texto: "El asistente dejará de usarlo. Podrás recuperarlo cambiando su estado.", ok: "Archivar" }} onClick$={archivar}>
                Archivar
              </Boton>
            )}
            <span class="pie-espacio" />
            <Boton onClick$={cerrar}>Cancelar</Boton>
            <Boton variante="principal" tipo="submit" form="form-articulo" cargando={f.guardando}>
              Guardar
            </Boton>
          </div>
        </Hoja>
      )}
    </div>
  );
});

export const head: DocumentHead = { title: "Conocimiento del asistente · jsrbot" };
