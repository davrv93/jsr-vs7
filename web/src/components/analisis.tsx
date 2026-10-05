import { component$ } from "@builder.io/qwik";
import { CATEGORIA_TEXTO, claveFicha, confianzaPct, ETAPA_TEXTO, ETAPAS, filasFicha, INTENCION_TEXTO, valorFicha } from "~/lib/format";
import type { RespuestaChat } from "~/lib/tipos";

type Analisis = RespuestaChat["analisis"];

const ORDEN_PRINCIPAL = ["recepcion", "diagnostico", "guia", "incidencia", "seguimiento", "cierre"];

type Veredicto = { veredicto?: unknown; confianza?: unknown; intent?: unknown; usado?: unknown };
const esVeredicto = (v: unknown): v is Veredicto => !!v && typeof v === "object" && !Array.isArray(v) && ("veredicto" in v || typeof (v as Veredicto).confianza === "number");
const NOMBRE_VEREDICTO: Record<string, string> = { clasificacion: "Clasificación", verificacion: "Verificación de la respuesta", respaldo: "Respaldo en el artículo", contesta: "Contesta lo preguntado", rag: "Búsqueda de artículos", datos_propuestos: "Datos que propone" };
const textoVeredicto = (k: string, v: Veredicto): string =>
  typeof v.veredicto === "string" && v.veredicto ? (VEREDICTO_TEXTO[v.veredicto] ?? v.veredicto.replace(/_/g, " ")) : typeof v.intent === "string" ? `Entiende «${INTENCION_TEXTO[v.intent] ?? v.intent}»` : (NOMBRE_VEREDICTO[k] ?? k.replace(/_/g, " "));
const corto = (t: string, n = 140): string => (t.length > n ? t.slice(0, n - 1) + "…" : t);

const VEREDICTO_TEXTO: Record<string, string> = {
  respaldada: "La respuesta está respaldada por el artículo",
  contesta_lo_preguntado: "Contesta lo que se preguntó",
  coincide: "Coincide con el clasificador",
  duda: "Duda de la clasificación",
  no_respaldada: "Hay frases sin respaldo",
};

/** Cajón de análisis del chat de prueba: cómo entendió el asistente el último mensaje. Etapa de atención, intención y
 *  confianza, ficha del caso, clasificación, veredictos de Jev local y artículos del RAG. */
export const PanelAnalisis = component$<{ a: Analisis | null; incidencia: string | null }>((p) => {
  const a = p.a;
  if (!a) {
    return <p class="det-vacio">Escribe un mensaje: aquí verás cómo lo entendió el asistente, en qué etapa está el caso y qué decidió.</p>;
  }
  const iEtapa = ORDEN_PRINCIPAL.indexOf(a.etapa);
  // `juez.veredictos` mezcla veredictos de verdad (con `veredicto` o `confianza`) con otros datos del turno (`rag`,
  // `datos_propuestos`…). Los primeros van como veredictos; el resto, aparte y en corto.
  const entradas = Object.entries((a.juez?.veredictos ?? {}) as Record<string, unknown>);
  const veredictos = entradas.filter(([, v]) => esVeredicto(v)) as [string, Veredicto][];
  const otros = entradas.filter(([, v]) => !esVeredicto(v) && v !== null && v !== undefined);
  const ficha = filasFicha(a.memoria);
  return (
    <div class="analisis">
      <section aria-labelledby="an-etapa">
        <h3 class="etiqueta-sec" id="an-etapa">
          Etapa de atención
        </h3>
        <ol class="etapas">
          {ETAPAS.map((e) => {
            const principal = ORDEN_PRINCIPAL.indexOf(e);
            const actual = e === a.etapa;
            const hecha = principal >= 0 && iEtapa >= 0 && principal < iEtapa;
            if (principal < 0 && !actual) return null;
            return (
              <li key={e} class={`etapa${actual ? " actual" : hecha ? " hecha" : ""}`} aria-current={actual ? "step" : undefined}>
                {ETAPA_TEXTO[e]}
                {actual && <span class="solo-lector"> (etapa actual)</span>}
              </li>
            );
          })}
        </ol>
      </section>

      <section aria-labelledby="an-clas">
        <h3 class="etiqueta-sec" id="an-clas">
          Clasificación
        </h3>
        <dl class="datos">
          <div>
            <dt>Intención</dt>
            <dd>
              {INTENCION_TEXTO[a.intencion] ?? a.intencion}
              <span class="dato-sec"> · {confianzaPct(a.confianza)}</span>
              <span class="confianza" role="img" aria-label={`${confianzaPct(a.confianza)} de confianza`}>
                <span style={{ width: `${Math.max(0, Math.min(100, Math.round((a.confianza ?? 0) * 100)))}%` }} />
              </span>
            </dd>
          </div>
          <div>
            <dt>Categoría</dt>
            <dd>
              {a.categoria ? (CATEGORIA_TEXTO[a.categoria] ?? a.categoria) : "Sin categoría todavía"}
              {a.categoria_confianza != null && <span class="dato-sec"> · {confianzaPct(a.categoria_confianza)}</span>}
            </dd>
          </div>
          <div>
            <dt>Acción</dt>
            <dd>
              {a.accion?.tipo && a.accion.tipo !== "ninguno" ? a.accion.tipo.replace(/_/g, " ") : "Ninguna"}
              {p.incidencia && <span class="dato-sec"> · {p.incidencia}</span>}
            </dd>
          </div>
          <div>
            <dt>Señales</dt>
            <dd>
              {[a.senales?.animo && a.senales.animo !== "neutro" ? `ánimo ${a.senales.animo.replace("_", " ")}` : "", a.senales?.queja ? "queja" : "", a.senales?.pide_tecnico ? "pide un técnico" : "", a.senales?.contrasena_oculta ? "se ocultó una contraseña" : ""]
                .filter(Boolean)
                .join(" · ") || "Sin señales"}
            </dd>
          </div>
          <div>
            <dt>Respuesta en</dt>
            <dd>{a.latencia_ms ?? "—"} ms</dd>
          </div>
        </dl>
      </section>

      <section aria-labelledby="an-ficha">
        <h3 class="etiqueta-sec" id="an-ficha">
          Ficha del caso
        </h3>
        {ficha.length ? (
          <dl class="datos">
            {ficha.map((f) => (
              <div key={f.clave}>
                <dt>{f.etiqueta}</dt>
                <dd>{f.valor}</dd>
              </div>
            ))}
          </dl>
        ) : (
          <p class="det-vacio">Todavía no hay datos: el asistente irá llenando la ficha a medida que la persona cuente.</p>
        )}
      </section>

      <section aria-labelledby="an-jev">
        <h3 class="etiqueta-sec" id="an-jev">
          Jev local · modo {a.juez?.modo ?? "apagado"}
        </h3>
        {veredictos.length ? (
          <ul class="lista-simple">
            {veredictos.map(([k, v]) => (
              <li key={k} class="veredicto">
                <span>{textoVeredicto(k, v)}</span>
                <span class="dato-sec">
                  {" "}
                  · {k}
                  {typeof v.confianza === "number" ? ` · ${confianzaPct(v.confianza)}` : ""}
                </span>
              </li>
            ))}
          </ul>
        ) : (
          <p class="det-vacio">Jev local no revisó este turno: la respuesta salió de un flujo fijo o no hubo texto del modelo.</p>
        )}
        {otros.length > 0 && (
          <>
            <h4 class="etiqueta-sec etiqueta-sub">Otros datos</h4>
            <dl class="datos">
              {otros.map(([k, v]) => (
                <div key={k}>
                  <dt>{NOMBRE_VEREDICTO[k] ?? claveFicha(k)}</dt>
                  <dd title={valorFicha(v)}>{corto(valorFicha(v))}</dd>
                </div>
              ))}
            </dl>
          </>
        )}
      </section>

      <section aria-labelledby="an-art">
        <h3 class="etiqueta-sec" id="an-art">
          Artículos usados (RAG)
        </h3>
        {(a.articulos_usados ?? []).length ? (
          <ul class="lista-simple">
            {(a.articulos_usados ?? []).map((x) => (
              <li key={x.clave}>
                <span class="dato-sec">{x.clave}</span> {x.titulo}
                {x.fuente && <span class="dato-sec"> · {x.fuente}</span>}
              </li>
            ))}
          </ul>
        ) : (
          <p class="det-vacio">Este turno no usó la base de conocimiento.</p>
        )}
      </section>
    </div>
  );
});
