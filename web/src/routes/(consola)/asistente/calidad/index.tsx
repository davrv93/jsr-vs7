import { $, component$ } from "@builder.io/qwik";
import { useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { BloqueKpi } from "~/components/kpi";
import { EsqueletoBloques } from "~/components/ui/esqueleto";
import { Fila, Grupo } from "~/components/ui/grupo";
import { Falla } from "~/components/ui/vacio";
import { useAccionBarra } from "~/lib/barra";
import { u } from "~/lib/base";
import { fecha, numero } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { Calidad, KpiResultado } from "~/lib/tipos";

const ESTADO_MODELO: Record<string, string> = { publicado: "Publicada", candidato: "Candidata", retirado: "Retirada" };

/** 14 · Asistente · Calidad. ¿Está mejorando? Tres señales de 12 semanas y las versiones del modelo. Acción principal:
 *  Publicar versión (lleva a Entrenamiento, donde se compara antes de publicar). */
export default component$(() => {
  const nav = useNavigate();
  const { r, recargar } = useRecurso<Calidad>("/api/calidad", { eventos: false });
  useAccionBarra(
    "Publicar versión",
    $(async () => {
      await nav(u("/asistente/entrenamiento"));
    }),
    "Publicar",
  );
  const d = r.datos;
  const serie = (valores: number[]) => d!.semanas.map((s, i) => ({ periodo: s, valor: valores[i] ?? null }));
  const pctRed = (v: number) => Math.round(v * 10) / 10;
  const bloques: KpiResultado[] = d
    ? [
        {
          kpi: "confianza_media",
          version: 1,
          titulo: "Confianza media del clasificador",
          definicion: "Promedio de la confianza con que el clasificador local etiquetó los mensajes de personas en la semana.",
          sql: "",
          unidad: "%",
          valor: pctRed(d.confianza_media[d.confianza_media.length - 1] * 100),
          meta: 80,
          sentido: "mayor_mejor",
          filas: serie(d.confianza_media.map((v) => pctRed(v * 100))),
        },
        {
          kpi: "pulgar_abajo",
          version: 1,
          titulo: "Respuestas marcadas con 👎",
          definicion: "Porcentaje de respuestas del asistente que la persona o un técnico marcó con 👎, sobre las respuestas de la semana.",
          sql: "",
          unidad: "%",
          valor: pctRed(d.pulgar_abajo_pct[d.pulgar_abajo_pct.length - 1]),
          meta: 5,
          sentido: "menor_mejor",
          filas: serie(d.pulgar_abajo_pct.map(pctRed)),
        },
        {
          kpi: "contencion_semanal",
          version: 1,
          titulo: "Contención del asistente",
          definicion: "Casos resueltos por el asistente sin abrir incidencia y confirmados por la persona.",
          sql: "",
          unidad: "%",
          valor: pctRed(d.contencion_pct[d.contencion_pct.length - 1]),
          meta: 45,
          sentido: "mayor_mejor",
          filas: serie(d.contencion_pct.map(pctRed)),
        },
      ]
    : [];
  return (
    <div class="pagina pagina-calidad">
      {r.estado === "cargando" && !d && <EsqueletoBloques n={3} />}
      {r.estado === "error" && !d && <Falla titulo="No pudimos cargar la calidad del asistente." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />}
      {d && (
        <>
          <div class="kpis">
            {bloques.map((k) => (
              <BloqueKpi key={k.kpi} k={k} tam={34} sinGolden periodo="últimas 12 semanas" />
            ))}
          </div>
          <Grupo titulo="Versiones del modelo" pie="Una versión nueva solo se publica si no empeora sobre el conjunto reservado. Se compara en Entrenamiento.">
            {d.modelos.map((m) => (
              <Fila key={m.version} titulo={`${m.version} · ${ESTADO_MODELO[m.estado]}`} detalle={`Exactitud ${numero(m.exactitud * 100, 1)} % · F1 macro ${numero(m.macro_f1 * 100, 1)} % · ${m.ejemplos ? numero(m.ejemplos) + " ejemplos · " : ""}${fecha(m.creado_en)}`} />
            ))}
          </Grupo>
        </>
      )}
    </div>
  );
});

export const head: DocumentHead = { title: "Calidad del asistente · jsrbot" };
