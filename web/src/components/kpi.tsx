import { component$, useSignal } from "@builder.io/qwik";
import { numero } from "~/lib/format";
import { cifraKpi, fraseKpi, resumenSerie } from "~/lib/kpi";
import type { KpiResultado } from "~/lib/tipos";
import { Cifra } from "./ui/cifra";
import { Icono } from "./ui/icono";
import { Spark } from "./ui/spark";

/** Bloque de un indicador (DISENO §09): la cifra en 48 px, una frase que la interpreta, la sparkline de 12 semanas y
 *  «Definición ▸» con la golden query, su versión, el periodo, el SQL y la tabla de valores. Sin tarjeta. */
export const BloqueKpi = component$<{ k: KpiResultado; periodo: string; tam?: 48 | 34; sinGolden?: boolean }>((p) => {
  const k = p.k;
  const abierta = useSignal(false);
  const c = cifraKpi(k);
  const filas = k.filas ?? [];
  const valores = filas.map((f) => f.valor);
  const sinValor = k.valor === null || k.valor === undefined;
  // Sin cifra (la golden query no se pudo calcular, p. ej. «ClickHouse no está configurado»): una línea clara en vez de un «—»
  // gigante y una gráfica vacía. El bloque conserva su título y su definición para no romper la columna.
  if (sinValor) {
    return (
      <section class="kpi kpi-sin-datos" aria-labelledby={`kpi-${k.kpi}`}>
        <div class="kpi-cab">
          <h2 class="kpi-titulo" id={`kpi-${k.kpi}`}>
            {k.titulo}
          </h2>
          <span class="kpi-estado-vacio">Sin cifra</span>
        </div>
        <p class="kpi-vacio" role="status">
          {k.detalle || "Sin datos en este periodo."}
        </p>
        {k.definicion && (
          <>
            <button type="button" class="kpi-def-boton" aria-expanded={abierta.value} aria-controls={`def-${k.kpi}`} onClick$={() => (abierta.value = !abierta.value)}>
              Definición <Icono n={abierta.value ? "abajo" : "der"} tam={14} />
            </button>
            {abierta.value && (
              <div class="kpi-def" id={`def-${k.kpi}`}>
                <p class="kpi-golden">
                  {p.sinGolden ? "Señal del asistente" : <>Golden query · <code>{k.kpi}</code>{k.version ? ` v${k.version}` : ""}</>}
                </p>
                <p class="kpi-def-texto">{k.definicion}</p>
              </div>
            )}
          </>
        )}
      </section>
    );
  }
  return (
    <section class="kpi" aria-labelledby={`kpi-${k.kpi}`}>
      <div class="kpi-cab">
        <h2 class="kpi-titulo" id={`kpi-${k.kpi}`}>
          {k.titulo}
        </h2>
        {k.pide_accion && <span class="kpi-accion">Pide acción</span>}
      </div>
      <Cifra valor={c.valor} unidad={c.unidad} tam={p.tam ?? 48} />
      <p class="kpi-frase">{fraseKpi(k)}</p>
      {k.detalle && <p class="kpi-detalle">{k.detalle}</p>}
      {filas.length >= 2 && (
        <div class="kpi-grafico">
          <Spark valores={valores} meta={k.meta} etiqueta={resumenSerie(k)} />
          <div class="kpi-ejes" aria-hidden="true">
            <span>Hace {filas.length} semanas</span>
            <span>Esta semana</span>
          </div>
        </div>
      )}
      <button type="button" class="kpi-def-boton" aria-expanded={abierta.value} aria-controls={`def-${k.kpi}`} onClick$={() => (abierta.value = !abierta.value)}>
        Definición <Icono n={abierta.value ? "abajo" : "der"} tam={14} />
      </button>
      {abierta.value && (
        <div class="kpi-def" id={`def-${k.kpi}`}>
          <p class="kpi-golden">
            {p.sinGolden ? "Señal del asistente" : <>Golden query · <code>{k.kpi}</code>{k.version ? ` v${k.version}` : ""}</>}
            <span class="dato-sec"> · {p.periodo}</span>
          </p>
          <p class="kpi-def-texto">{k.definicion}</p>
          {!p.sinGolden && k.sql && (
            <pre class="sql" tabIndex={0} aria-label={`SQL de ${k.titulo}`}>
              {k.sql}
            </pre>
          )}
          {filas.length > 0 && (
          <table class="tabla-simple">
            <caption>Valores semanales ({k.unidad || "cifra"})</caption>
            <thead>
              <tr>
                <th scope="col">Semana</th>
                <th scope="col" class="num">
                  Valor
                </th>
              </tr>
            </thead>
            <tbody>
              {filas.map((f) => (
                <tr key={f.periodo}>
                  <th scope="row">{f.periodo}</th>
                  <td class="num">{f.valor === null ? "—" : numero(f.valor, Number.isInteger(f.valor) ? 0 : 1)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          )}
          {k.meta !== null && k.meta !== undefined && (
            <p class="dato-sec kpi-meta-nota">
              Meta: {numero(k.meta, Number.isInteger(k.meta) ? 0 : 1)} {k.unidad} · {k.sentido === "mayor_mejor" ? "mientras más alta, mejor" : "mientras más baja, mejor"}
            </p>
          )}
        </div>
      )}
    </section>
  );
});

