import { component$ } from "@builder.io/qwik";

interface SparkProps {
  valores: (number | null)[];
  /** Resumen para lector de pantalla: «Cumplimiento de SLA, últimas 12 semanas: de 88 a 92». */
  etiqueta: string;
  /** Línea punteada de la meta (mismo eje). */
  meta?: number | null;
  alto?: number;
}

/** Sparkline de 12 semanas en SVG propio: una línea de tinta secundaria y el último punto en tinta. Sin ejes ni
 *  color; el detalle numérico está en la tabla de «Definición». El SVG se estira a lo ancho; el punto final es HTML
 *  para que no se deforme. */
export const Spark = component$<SparkProps>((p) => {
  const w = 100;
  const h = p.alto ?? 48;
  const pad = 5;
  const vs = p.valores.filter((v): v is number => v !== null);
  if (vs.length < 2) {
    return (
      <div class="spark-caja" style={{ height: `${h}px` }}>
        <svg class="spark" viewBox={`0 0 ${w} ${h}`} role="img" aria-label={`${p.etiqueta}: sin datos suficientes`} preserveAspectRatio="none">
          <line x1="0" y1={h / 2} x2={w} y2={h / 2} class="spark-vacio" vector-effect="non-scaling-stroke" />
        </svg>
      </div>
    );
  }
  // La meta entra en la escala solo si está cerca de la serie: una meta lejana aplastaría la línea.
  const vmin = Math.min(...vs);
  const vmax = Math.max(...vs);
  const holgura = (vmax - vmin || Math.abs(vmax) || 1) * 0.6;
  const metaCerca = p.meta != null && p.meta >= vmin - holgura && p.meta <= vmax + holgura;
  const todos = metaCerca ? [...vs, p.meta as number] : vs;
  const min = Math.min(...todos);
  const max = Math.max(...todos);
  const rango = max - min || 1;
  const n = Math.max(1, p.valores.length - 1);
  const x = (i: number) => (i * w) / n;
  const y = (v: number) => h - pad - ((v - min) / rango) * (h - pad * 2);
  let d = "";
  let corte = true;
  p.valores.forEach((v, i) => {
    if (v === null) {
      corte = true;
      return;
    }
    d += `${corte ? "M" : "L"}${x(i).toFixed(2)},${y(v).toFixed(2)} `;
    corte = false;
  });
  let ult = p.valores.length - 1;
  while (ult > 0 && p.valores[ult] === null) ult--;
  const uv = p.valores[ult] as number;
  return (
    <div class="spark-caja" style={{ height: `${h}px` }}>
      <svg class="spark" viewBox={`0 0 ${w} ${h}`} role="img" aria-label={p.etiqueta} preserveAspectRatio="none">
        {metaCerca && p.meta != null && <line x1="0" x2={w} y1={y(p.meta)} y2={y(p.meta)} class="spark-meta" vector-effect="non-scaling-stroke" />}
        <path d={d} class="spark-linea" vector-effect="non-scaling-stroke" />
      </svg>
      <span class="spark-punto" style={{ left: `${(x(ult) / w) * 100}%`, top: `${y(uv)}px` }} aria-hidden="true" />
    </div>
  );
});
