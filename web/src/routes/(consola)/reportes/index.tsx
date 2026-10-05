import { $, component$, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { EsperaLarga } from "~/components/ui/esqueleto";
import { Fila, Grupo } from "~/components/ui/grupo";
import { Icono } from "~/components/ui/icono";
import { Falla, Vacio } from "~/components/ui/vacio";
import { api, ApiError, mensajeError } from "~/lib/api";
import { numero } from "~/lib/format";
import { useParam } from "~/lib/params";
import { useRecurso } from "~/lib/recurso";
import type { Lista, ReporteGuardado, RespuestaReporte } from "~/lib/tipos";
import { toast } from "~/lib/ui";

const EJEMPLOS = ["¿Cuál fue el MTTR por categoría este mes?", "¿Cumplimos el SLA en todos los grupos?", "¿Cuántas incidencias se reabrieron?"];

const celda = (v: string | number | null): string => (typeof v === "number" ? numero(v, Number.isInteger(v) ? 0 : 1) : (v ?? "—"));

/** 10 · Reportes. ¿Qué quiero saber? Un campo arriba y la biblioteca debajo. Con una golden query, el resultado lo dice;
 *  sin ella, lleva «Sin verificar» y el SQL visible. */
export default component$(() => {
  const lib = useRecurso<Lista<ReporteGuardado>>("/api/reportes", { eventos: false });
  const repParam = useParam("r");
  const pregunta = useSignal("");
  const errorCampo = useSignal("");
  const verSql = useSignal(false);
  const st = useStore<{ estado: "inicial" | "cargando" | "ok" | "error"; datos: RespuestaReporte | null; error: string; sinRed: boolean; lento: boolean; ultima: string }>({ estado: "inicial", datos: null, error: "", sinRed: false, lento: false, ultima: "" });

  const preguntar = $(async (texto: string) => {
    const t = texto.trim();
    errorCampo.value = "";
    if (!t) {
      errorCampo.value = "Escribe una pregunta, por ejemplo «¿Cuál fue el MTTR de impresoras en septiembre?».";
      document.getElementById("c-pregunta")?.focus();
      return;
    }
    pregunta.value = t;
    st.ultima = t;
    st.estado = "cargando";
    st.lento = false;
    verSql.value = false;
    const espera = setTimeout(() => (st.lento = true), 3000);
    try {
      st.datos = await api<RespuestaReporte>("/api/reportes/preguntar", { method: "POST", json: { pregunta: t } });
      st.estado = "ok";
      setTimeout(() => document.getElementById("resultado-reporte")?.focus({ preventScroll: false }), 50);
    } catch (e) {
      st.estado = "error";
      st.error = mensajeError(e);
      st.sinRed = e instanceof ApiError && e.red;
    } finally {
      clearTimeout(espera);
    }
  });

  // Un reporte abierto desde el buscador (?r=3) se ejecuta al llegar.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const id = Number(track(() => repParam.value)) || 0;
      const rep = lib.r.datos?.items.find((x) => x.id === id);
      track(() => lib.r.datos);
      if (rep && st.ultima !== rep.nombre) preguntar(rep.nombre);
    },
    { strategy: "document-ready" },
  );

  const exportarCsv = $(() => {
    const d = st.datos;
    if (!d) return;
    const esc = (v: string | number | null) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const csv = [d.columnas.map(esc).join(","), ...d.filas.map((f) => f.map(esc).join(","))].join("\r\n");
    const url = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `reporte-${(d.golden?.kpi ?? "consulta").replace(/\W+/g, "-")}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast("CSV descargado.", "ok");
  });

  const d = st.datos;
  const esNumero = (i: number) => !!d && d.filas.length > 0 && d.filas.every((f) => typeof f[i] === "number" || f[i] === null);

  return (
    <div class="pagina">
      <form class="pregunta" preventdefault:submit onSubmit$={() => preguntar(pregunta.value)} noValidate>
        <h2 class="pregunta-titulo">
          <label for="c-pregunta">Pregunta lo que quieras saber</label>
        </h2>
        <div class="pregunta-campo">
          <input id="c-pregunta" type="text" autoComplete="off" value={pregunta.value} placeholder="¿Cuál fue el MTTR de impresoras en septiembre?" aria-invalid={errorCampo.value ? "true" : undefined} aria-describedby={errorCampo.value ? "e-pregunta" : "a-pregunta"} onInput$={(_, el) => (pregunta.value = el.value)} />
          <button type="submit" class="boton boton-principal" disabled={st.estado === "cargando"} aria-busy={st.estado === "cargando" ? "true" : undefined}>
            Preguntar
          </button>
        </div>
        {errorCampo.value ? (
          <p class="campo-error" id="e-pregunta" role="alert">
            {errorCampo.value}
          </p>
        ) : (
          <p class="campo-ayuda" id="a-pregunta">
            Primero busco una consulta verificada (golden query). Si no hay, te muestro una propuesta marcada «Sin verificar».
          </p>
        )}
        {st.estado === "inicial" && (
          <ul class="ejemplos" aria-label="Ejemplos de preguntas">
            {EJEMPLOS.map((e) => (
              <li key={e}>
                <button type="button" class="chip" onClick$={() => preguntar(e)}>
                  {e}
                </button>
              </li>
            ))}
          </ul>
        )}
      </form>

      <div aria-live="polite">
        {st.estado === "cargando" && (
          <div class="esq esq-detalle" role="status" aria-busy="true" aria-label="Consultando">
            <span class="esq-linea esq-etiqueta" />
            <span class="esq-linea esq-titulo" />
            <span class="esq-linea esq-parrafo" />
            <span class="esq-linea esq-parrafo" style={{ width: "70%" }} />
            {st.lento && <EsperaLarga texto="Consultando ClickHouse… las preguntas nuevas pueden tardar unos segundos." />}
          </div>
        )}
        {st.estado === "error" && <Falla titulo="No pudimos responder esa pregunta." texto={`${st.error} Tu pregunta sigue en el campo.`} sinRed={st.sinRed} onReintentar$={() => preguntar(st.ultima)} />}
      </div>

      {d && st.estado === "ok" && (
        <section class="resultado" id="resultado-reporte" tabIndex={-1} aria-label="Resultado">
          <p class="resultado-resumen">{d.resumen}</p>
          <p class={`resultado-origen${d.verificado ? "" : " sin-verificar"}`}>
            {d.verificado && d.golden ? (
              <>
                <Icono n="ok" tam={14} /> Golden query · {d.golden.nombre} v{d.golden.version}
              </>
            ) : (
              <>Sin verificar</>
            )}
          </p>
          {d.nota && <p class="resultado-nota">{d.nota}</p>}
          {d.filas.length === 0 ? (
            <Vacio titulo="La consulta no devolvió filas." texto="No hay datos para ese periodo. Prueba con otro rango o con otra pregunta." />
          ) : (
            <div class="tabla-caja" tabIndex={0} role="region" aria-label="Tabla de resultados">
              <table class="tabla-simple tabla-ancha">
                <thead>
                  <tr>
                    {d.columnas.map((c, i) => (
                      <th key={c} scope="col" class={esNumero(i) ? "num" : ""}>
                        {c}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {d.filas.map((f, i) => (
                    <tr key={i}>
                      {f.map((v, j) => (j === 0 ? <th key={j} scope="row">{celda(v)}</th> : <td key={j} class={esNumero(j) ? "num" : ""}>{celda(v)}</td>))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <div class="resultado-acciones">
            <button type="button" class="boton boton-secundario" onClick$={exportarCsv} disabled={d.filas.length === 0}>
              Exportar CSV
            </button>
            {d.verificado && (
              <button type="button" class="boton boton-secundario" aria-expanded={verSql.value} onClick$={() => (verSql.value = !verSql.value)}>
                {verSql.value ? "Ocultar el SQL" : "Ver el SQL"}
              </button>
            )}
          </div>
          {(!d.verificado || verSql.value) && (
            <pre class="sql" tabIndex={0} aria-label="SQL de la consulta">
              {d.sql}
            </pre>
          )}
        </section>
      )}

      <section class="biblioteca" aria-labelledby="bib-t">
        <h2 class="etiqueta-sec bib-titulo" id="bib-t">
          Biblioteca de reportes
        </h2>
        {lib.r.estado === "cargando" && !lib.r.datos && (
          <div class="esq" role="status" aria-busy="true" aria-label="Cargando la biblioteca">
            {[0, 1, 2].map((i) => (
              <div class="esq-fila" key={i}>
                <div class="esq-textos">
                  <span class="esq-linea" style={{ width: "40%" }} />
                  <span class="esq-linea esq-linea-corta" style={{ width: "62%" }} />
                </div>
              </div>
            ))}
          </div>
        )}
        {lib.r.estado === "error" && !lib.r.datos && <Falla titulo="No pudimos cargar la biblioteca." texto={lib.r.error} sinRed={lib.r.sinRed} onReintentar$={lib.recargar} />}
        {lib.r.datos && lib.r.datos.items.length === 0 && <Vacio titulo="Todavía no hay reportes guardados." texto="Haz una pregunta arriba; los reportes útiles se guardan aquí." />}
        {lib.r.datos && lib.r.datos.items.length > 0 && (
          <Grupo>
            {lib.r.datos.items.map((x) => (
              <Fila key={x.id} titulo={x.nombre} detalle={`${x.descripcion}${x.programado ? " · Se envía: " + x.programado : ""}`} navega onClick$={() => preguntar(x.nombre)} />
            ))}
          </Grupo>
        )}
      </section>
    </div>
  );
});

export const head: DocumentHead = { title: "Reportes · jsrbot" };
