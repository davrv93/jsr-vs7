import { $, component$, useComputed$, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { Cifra } from "~/components/ui/cifra";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla, Vacio } from "~/components/ui/vacio";
import { api, mensajeError } from "~/lib/api";
import { INTENCION_TEXTO, INTENCIONES, MOTIVO_COLA_TEXTO, numero, plural, relativo } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { EstadoEntrenamiento, ItemCola, Lista } from "~/lib/tipos";
import { toast, useDialog } from "~/lib/ui";

const pct = (v: number) => numero(v * 100, 1);

/** 13 · Asistente · Entrenamiento. ¿Qué entiende mal y cómo lo corrijo? Cola de revisión → Reentrenar → comparar las dos
 *  cifras → Publicar solo si la nueva no empeora. El asistente propone; una persona decide. */
export default component$(() => {
  const dialog = useDialog();
  const filtro = useSignal("pendiente");
  const ruta = useComputed$(() => `/api/entrenamiento/cola?estado=${filtro.value}&por_pagina=100`);
  const cola = useRecurso<Lista<ItemCola>>(ruta, { eventos: false });
  const est = useRecurso<EstadoEntrenamiento>("/api/entrenamiento/estado", { eventos: false });
  const trabajando = useSignal(false);

  // Mientras entrena, se consulta el estado cada segundo y medio.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track, cleanup }) => {
      const fase = track(() => est.r.datos?.fase);
      if (fase !== "entrenando") return;
      const id = setInterval(() => est.refrescar(), 1500);
      cleanup(() => clearInterval(id));
    },
    { strategy: "document-ready" },
  );

  const revisar = $(async (id: number, decision: string, intencion?: string) => {
    try {
      await api(`/api/entrenamiento/${id}/revisar`, { method: "POST", json: { decision, intencion } });
      toast(decision === "confirmar" ? "Confirmada: el asistente entendió bien." : decision === "corregir" ? `Corregida a «${INTENCION_TEXTO[intencion ?? ""] ?? intencion}».` : "Descartada de la cola.", "ok");
      await cola.refrescar();
      await est.refrescar();
    } catch (e) {
      toast(mensajeError(e), "error");
    }
  });

  const reentrenar = $(async () => {
    trabajando.value = true;
    try {
      await api("/api/entrenamiento/reentrenar", { method: "POST", json: {} });
      toast("Entrenando en segundo plano. Puedes seguir revisando.", "ok");
      await est.refrescar();
    } catch (e) {
      toast(mensajeError(e), "error");
    } finally {
      trabajando.value = false;
    }
  });

  const publicar = $(async () => {
    const e = est.r.datos;
    if (!e?.candidato) return;
    const ok = await dialog.confirm({
      titulo: `¿Publicar ${e.candidato.version}?`,
      texto: `Reemplaza a ${e.publicado.version} en el asistente. La exactitud sube de ${pct(e.publicado.exactitud)} % a ${pct(e.candidato.exactitud)} %. Puedes volver atrás publicando la anterior.`,
      ok: "Publicar",
    });
    if (!ok) return;
    trabajando.value = true;
    try {
      await api("/api/entrenamiento/publicar", { method: "POST", json: {} });
      toast(`${e.candidato.version} publicada.`, "ok");
      await est.refrescar();
    } catch (er) {
      toast(mensajeError(er), "error");
    } finally {
      trabajando.value = false;
    }
  });

  const descartar = $(async () => {
    await api("/api/entrenamiento/descartar", { method: "POST", json: {} }).catch(() => undefined);
    await est.refrescar();
  });

  const e = est.r.datos;
  const c = cola.r.datos;
  const dif = e?.candidato ? e.candidato.exactitud - e.publicado.exactitud : 0;
  const empeora = !!e?.candidato && dif < 0;

  return (
    <div class="pagina">
      <section class="entren" aria-labelledby="entren-t">
        {est.r.estado === "cargando" && !e && <EsqueletoFilas n={2} />}
        {est.r.estado === "error" && !e && <Falla titulo="No pudimos cargar el estado del entrenamiento." texto={est.r.error} sinRed={est.r.sinRed} onReintentar$={est.recargar} />}
        {e && (
          <>
            <h2 class="bandeja-cifra" id="entren-t">
              {c && filtro.value === "pendiente" ? (c.total === 0 ? "Nada pendiente de revisar." : `${plural(c.total, "mensaje", "mensajes")} por revisar`) : "Revisión del asistente"}
            </h2>
            <p class="bandeja-sub">
              Versión publicada {e.publicado.version} · exactitud {pct(e.publicado.exactitud)} % sobre el conjunto reservado
            </p>

            {e.fase === "ninguno" && (
              <div class="entren-accion">
                <button type="button" class="boton boton-principal" disabled={e.cambios_pendientes <= 0 || trabajando.value} aria-busy={trabajando.value ? "true" : undefined} onClick$={reentrenar}>
                  Reentrenar
                </button>
                <p class="entren-ayuda">{e.cambios_pendientes > 0 ? `${plural(e.cambios_pendientes, "cambio listo", "cambios listos")} para entrenar.` : "Confirma o corrige al menos un mensaje para poder reentrenar."}</p>
              </div>
            )}

            {e.fase === "entrenando" && (
              <div class="entren-accion" role="status">
                <div class="progreso" role="progressbar" aria-label="Entrenando" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round((e.progreso ?? 0) * 100)}>
                  <span style={{ width: `${Math.round((e.progreso ?? 0.05) * 100)}%` }} />
                </div>
                <p class="entren-ayuda">Entrenando en segundo plano y comparando con la versión publicada. Puedes seguir revisando.</p>
              </div>
            )}

            {e.fase === "listo" && e.candidato && (
              <div class="comparar" role="group" aria-label="Comparación de versiones">
                <div class="comparar-col">
                  <p class="etiqueta-sec">Publicada · {e.publicado.version}</p>
                  <Cifra valor={pct(e.publicado.exactitud)} unidad="%" tam={34} />
                  <p class="comparar-sub">F1 macro {pct(e.publicado.macro_f1)} %</p>
                </div>
                <div class="comparar-col">
                  <p class="etiqueta-sec">Nueva · {e.candidato.version}</p>
                  <Cifra valor={pct(e.candidato.exactitud)} unidad="%" tam={34} />
                  <p class="comparar-sub">F1 macro {pct(e.candidato.macro_f1)} %</p>
                </div>
                <p class={`comparar-frase${empeora ? " es-peor" : ""}`}>
                  {dif === 0 ? "Igual que la publicada." : `${numero(Math.abs(dif) * 100, 1)} ${Math.abs(dif * 100) === 1 ? "punto" : "puntos"} ${dif > 0 ? "mejor" : "peor"} sobre el conjunto reservado.`}
                  {empeora && " No se puede publicar: una versión que empeora no sale."}
                </p>
                <div class="comparar-acciones">
                  <button type="button" class="boton boton-principal" disabled={empeora || trabajando.value} onClick$={publicar}>
                    Publicar {e.candidato.version}
                  </button>
                  <button type="button" class="boton boton-secundario" onClick$={descartar}>
                    Descartar
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </section>

      <div class="filtros">
        <Segmentado
          etiqueta="Estado de la revisión"
          valor={filtro.value}
          onCambio$={(v) => (filtro.value = v)}
          opciones={[
            { valor: "pendiente", titulo: "Pendientes" },
            { valor: "confirmada", titulo: "Confirmadas" },
            { valor: "corregida", titulo: "Corregidas" },
            { valor: "todas", titulo: "Todas" },
          ]}
        />
      </div>

      {cola.r.estado === "cargando" && !c && <EsqueletoFilas n={5} etiqueta="Cargando la cola" />}
      {cola.r.estado === "error" && !c && <Falla titulo="No pudimos cargar la cola de revisión." texto={cola.r.error} sinRed={cola.r.sinRed} onReintentar$={cola.recargar} />}
      {c && c.items.length === 0 && (
        <Vacio
          titulo={filtro.value === "pendiente" ? "No hay mensajes por revisar." : "No hay mensajes con este filtro."}
          texto={filtro.value === "pendiente" ? "Los mensajes con baja confianza, con 👎, corregidos por un técnico o de incidencias reabiertas llegan aquí." : undefined}
        />
      )}
      {c && c.items.length > 0 && (
        <ul class={`cola${cola.r.estado === "cargando" ? " recargando" : ""}`}>
          {c.items.map((it) => (
            <li class="cola-item" key={it.id}>
              <p class="cola-texto">«{it.texto}»</p>
              <p class="cola-meta">
                Entendió <strong>{INTENCION_TEXTO[it.intencion_modelo] ?? it.intencion_modelo}</strong> · {Math.round(it.confianza * 100)} % · {MOTIVO_COLA_TEXTO[it.motivo]} · {relativo(it.ts)}
              </p>
              {it.estado === "pendiente" ? (
                <div class="cola-acciones">
                  <button type="button" class="boton boton-secundario boton-pequeno" onClick$={() => revisar(it.id, "confirmar")}>
                    Entendió bien
                  </button>
                  <div class="cola-otra">
                    <label class="solo-lector" for={`otra-${it.id}`}>
                      Elegir la intención correcta de «{it.texto.slice(0, 40)}»
                    </label>
                    <select id={`otra-${it.id}`} onChange$={(_, el) => el.value && revisar(it.id, "corregir", el.value)}>
                      <option value="">Es otra intención…</option>
                      {INTENCIONES.filter((x) => x !== it.intencion_modelo).map((x) => (
                        <option key={x} value={x}>
                          {INTENCION_TEXTO[x]}
                        </option>
                      ))}
                    </select>
                  </div>
                  <button type="button" class="boton boton-secundario boton-pequeno" onClick$={() => revisar(it.id, "descartar")}>
                    Descartar
                  </button>
                </div>
              ) : (
                <p class="cola-hecho">{it.estado === "confirmada" ? "Confirmada" : it.estado === "corregida" ? `Corregida a «${INTENCION_TEXTO[it.intencion_correcta ?? ""] ?? it.intencion_correcta}»` : "Descartada"}</p>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
});

export const head: DocumentHead = { title: "Entrenamiento del asistente · jsrbot" };
