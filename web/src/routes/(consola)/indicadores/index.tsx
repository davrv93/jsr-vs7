import { $, component$, useComputed$, useSignal } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { BloqueKpi } from "~/components/kpi";
import { EsqueletoBloques, EsperaLarga } from "~/components/ui/esqueleto";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla, Vacio } from "~/components/ui/vacio";
import { fechaCorta, hoyLima, primeroDelMes, restarDias } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { Indicadores } from "~/lib/tipos";

/** 09 · Indicadores. ¿Cumplimos este mes? Una columna de bloques; sube la cifra que pide acción. */
export default component$(() => {
  const periodo = useSignal("mes");
  const desdeMed = useSignal(restarDias(hoyLima(), 30));
  const hastaMed = useSignal(hoyLima());
  const errorRango = useSignal("");
  const aplicado = useSignal(`${restarDias(hoyLima(), 30)}|${hoyLima()}`);

  const rango = useComputed$(() => {
    const hoy = hoyLima();
    if (periodo.value === "semana") return [restarDias(hoy, 7), hoy];
    if (periodo.value === "mes") return [primeroDelMes(hoy), hoy];
    if (periodo.value === "trimestre") return [restarDias(hoy, 90), hoy];
    const [d, h] = aplicado.value.split("|");
    return [d, h];
  });
  const ruta = useComputed$(() => `/api/indicadores?desde=${rango.value[0]}&hasta=${rango.value[1]}`);
  const { r, recargar } = useRecurso<Indicadores>(ruta);

  const aplicar = $(() => {
    errorRango.value = "";
    if (!desdeMed.value || !hastaMed.value) {
      errorRango.value = "Elige las dos fechas.";
      return;
    }
    if (desdeMed.value > hastaMed.value) {
      errorRango.value = "La fecha de inicio debe ser anterior a la de fin.";
      return;
    }
    aplicado.value = `${desdeMed.value}|${hastaMed.value}`;
  });

  const d = r.datos;
  const kpis = d ? [...(d.kpis ?? [])].sort((a, b) => Number(!!b.pide_accion) - Number(!!a.pide_accion)) : [];
  const etiquetaPeriodo = d ? `del ${fechaCorta(d.desde)} al ${fechaCorta(d.hasta)}` : "";

  return (
    <div class="pagina pagina-indicadores">
      <div class="indicadores-cab">
        <Segmentado
          etiqueta="Periodo"
          valor={periodo.value}
          onCambio$={(v) => (periodo.value = v)}
          opciones={[
            { valor: "semana", titulo: "Semana" },
            { valor: "mes", titulo: "Mes" },
            { valor: "trimestre", titulo: "Trimestre" },
            { valor: "medida", titulo: "A medida" },
          ]}
        />
        {d && <p class="indicadores-periodo">Del {fechaCorta(d.desde)} al {fechaCorta(d.hasta)}</p>}
      </div>
      {periodo.value === "medida" && (
        <form class="rango" preventdefault:submit onSubmit$={aplicar}>
          <div class="campo">
            <label class="campo-etiqueta" for="rango-desde">
              Desde
            </label>
            <input id="rango-desde" type="date" value={desdeMed.value} max={hastaMed.value} onInput$={(_, el) => (desdeMed.value = el.value)} />
          </div>
          <div class="campo">
            <label class="campo-etiqueta" for="rango-hasta">
              Hasta
            </label>
            <input id="rango-hasta" type="date" value={hastaMed.value} min={desdeMed.value} max={hoyLima()} onInput$={(_, el) => (hastaMed.value = el.value)} />
          </div>
          <button type="submit" class="boton boton-principal">
            Aplicar
          </button>
          {errorRango.value && (
            <p class="campo-error" role="alert">
              {errorRango.value}
            </p>
          )}
        </form>
      )}

      {r.estado === "cargando" && !d && (
        <>
          <EsqueletoBloques n={3} />
          {r.lento && <EsperaLarga texto="Calculando las cifras desde ClickHouse… puede tardar unos segundos." />}
        </>
      )}
      {r.estado === "error" && !d && <Falla titulo="No pudimos calcular los indicadores." texto={`${r.error} Las cifras anteriores no se perdieron: están en la base.`} sinRed={r.sinRed} onReintentar$={recargar} />}
      {d && kpis.length > 0 && kpis.every((k) => k.valor === null || k.valor === undefined) && (
        <p class="indicadores-aviso" role="status">
          Ninguna cifra se pudo calcular ahora. {kpis.find((k) => k.detalle)?.detalle ?? "Inténtalo de nuevo en un momento."} Las definiciones siguen disponibles.
        </p>
      )}
      {d && kpis.length === 0 && <Vacio titulo="Todavía no hay indicadores definidos." texto="Las cifras salen de las golden queries del catálogo; cuando haya una, aparecerá aquí." />}
      {d && (
        <div class={`kpis${r.estado === "cargando" ? " recargando" : ""}`} aria-busy={r.estado === "cargando"}>
          {kpis.map((k) => (
            <BloqueKpi key={k.kpi} k={k} periodo={etiquetaPeriodo} />
          ))}
          <p class="kpis-pie">Cada cifra sale de una golden query versionada: una cifra, una definición. Abre «Definición» para ver la consulta.</p>
        </div>
      )}
    </div>
  );
});

export const head: DocumentHead = { title: "Indicadores · jsrbot" };
