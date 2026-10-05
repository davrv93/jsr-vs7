import { component$ } from "@builder.io/qwik";

const ANCHOS = [62, 48, 71, 55, 66, 44, 58, 69];

/** Carga con la forma real de una fila de la bandeja (punto, asunto, persona, plazo). Sin spinner central. */
export const EsqueletoFilas = component$<{ n?: number; etiqueta?: string }>((p) => (
  <div class="esq" role="status" aria-busy="true" aria-label={p.etiqueta ?? "Cargando"}>
    {Array.from({ length: p.n ?? 6 }).map((_, i) => (
      <div class="esq-fila" key={i}>
        <span class="esq-punto" />
        <div class="esq-textos">
          <span class="esq-linea" style={{ width: `${ANCHOS[i % ANCHOS.length]}%` }} />
          <span class="esq-linea esq-linea-corta" style={{ width: `${ANCHOS[(i + 3) % ANCHOS.length] - 20}%` }} />
        </div>
        <span class="esq-linea esq-plazo" />
      </div>
    ))}
  </div>
));

/** Carga de un bloque de indicador: cifra, frase y sparkline. */
export const EsqueletoBloques = component$<{ n?: number }>((p) => (
  <div class="esq esq-bloques" role="status" aria-busy="true" aria-label="Cargando indicadores">
    {Array.from({ length: p.n ?? 3 }).map((_, i) => (
      <div class="esq-bloque" key={i}>
        <span class="esq-linea esq-etiqueta" />
        <span class="esq-linea esq-cifra" />
        <span class="esq-linea" style={{ width: "46%" }} />
        <span class="esq-linea esq-spark" />
      </div>
    ))}
  </div>
));

/** Carga del detalle de una incidencia. */
export const EsqueletoDetalle = component$(() => (
  <div class="esq esq-detalle" role="status" aria-busy="true" aria-label="Cargando la incidencia">
    <span class="esq-linea esq-etiqueta" />
    <span class="esq-linea esq-titulo" />
    <span class="esq-linea" style={{ width: "40%" }} />
    <span class="esq-linea esq-parrafo" />
    <span class="esq-linea esq-parrafo" style={{ width: "86%" }} />
    <span class="esq-linea esq-parrafo" style={{ width: "62%" }} />
  </div>
));

/** Después de 3 s sin respuesta, una línea dice qué se espera. */
export const EsperaLarga = component$<{ texto: string }>((p) => (
  <p class="espera-larga" role="status">
    {p.texto}
  </p>
));
