import { numero } from "./format";
import type { KpiResultado } from "./tipos";

const fmt = (v: number): string => numero(v, Number.isInteger(v) ? 0 : 1);

/** Cifra y unidad por separado: «92,4» y «%». La unidad va en tinta secundaria al 60 % del tamaño. */
export function cifraKpi(k: KpiResultado): { valor: string; unidad: string } {
  if (k.valor === null || k.valor === undefined) return { valor: "—", unidad: "" };
  return { valor: fmt(k.valor), unidad: k.unidad };
}

const cantidad = (n: number, unidad: string): string => {
  const v = fmt(n);
  if (unidad === "%" || unidad === "/ 5") return `${v} ${n === 1 ? "punto" : "puntos"}`;
  if (unidad === "incidencias") return `${v} ${n === 1 ? "incidencia" : "incidencias"}`;
  return `${v} ${unidad}`;
};
const metaTexto = (n: number, unidad: string): string => (unidad === "%" ? `${fmt(n)} %` : unidad === "/ 5" ? fmt(n) : unidad === "incidencias" ? fmt(n) : `${fmt(n)} ${unidad}`);

/** La frase que interpreta la cifra: «3 puntos por encima de la meta de 90 %». */
export function fraseKpi(k: KpiResultado): string {
  if (k.valor === null || k.valor === undefined) return "Sin datos en este periodo.";
  if (k.meta === null || k.meta === undefined) return "Todavía no hay una meta definida.";
  const dif = k.valor - k.meta;
  if (Math.abs(dif) < 0.05) return `Justo en la meta de ${metaTexto(k.meta, k.unidad)}.`;
  return `${cantidad(Math.abs(dif), k.unidad)} ${dif > 0 ? "por encima" : "por debajo"} de la meta de ${metaTexto(k.meta, k.unidad)}.`;
}

/** Resumen para el lector de pantalla de la sparkline. */
export function resumenSerie(k: KpiResultado): string {
  const filas = k.filas ?? [];
  const v = filas.map((f) => f.valor).filter((x): x is number => x !== null);
  if (v.length < 2) return `${k.titulo}: sin datos suficientes para la tendencia`;
  return `${k.titulo}, últimas ${filas.length} semanas: de ${fmt(v[0])} a ${fmt(v[v.length - 1])} ${k.unidad}`;
}
