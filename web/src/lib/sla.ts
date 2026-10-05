import { duracion, hmm } from "./format";
import type { Estado, Sla } from "./tipos";

// Regla del color: solo la excepción lleva color. Por vencer (≥ 75 %) → punto y plazo naranja.
// Vencida → plazo en rojo con el tiempo en negativo. Nunca las dos señales a la vez.

export type NivelSla = "normal" | "por_vencer" | "vencida" | "pausada" | "ninguno";

export const UMBRAL_POR_VENCER = 75;

export function nivelSla(sla: Sla | null | undefined, estado?: Estado): NivelSla {
  if (!sla || estado === "resuelta" || estado === "cerrada") return "ninguno";
  if (sla.vencida || sla.restante_min < 0) return "vencida";
  if (sla.pausado || estado === "espera_usuario" || estado === "espera_tercero") return "pausada";
  if (sla.porcentaje >= UMBRAL_POR_VENCER) return "por_vencer";
  return "normal";
}

/** Texto corto de la columna de plazo: «0:40», «−0:12», «3 d», «Pausa». */
export function plazoCorto(sla: Sla | null | undefined, estado?: Estado): string {
  const n = nivelSla(sla, estado);
  if (n === "ninguno" || !sla) return estado === "resuelta" || estado === "cerrada" ? "" : "—";
  if (n === "pausada") return "En pausa";
  const m = sla.restante_min;
  const abs = Math.abs(m);
  const cuerpo = abs >= 48 * 60 ? `${Math.floor(abs / (24 * 60))} d` : hmm(abs);
  return m < 0 ? `−${cuerpo}` : cuerpo;
}

/** Frase larga para el detalle: «vence en 1 h 20 min», «venció hace 12 min». */
export function plazoLargo(sla: Sla | null | undefined, estado?: Estado): string {
  const n = nivelSla(sla, estado);
  if (n === "ninguno" || !sla) return "";
  if (n === "pausada") return "plazo en pausa";
  if (n === "vencida") return `venció hace ${duracion(sla.restante_min)}`;
  return `vence en ${duracion(sla.restante_min)}`;
}
