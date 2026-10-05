import { $, component$, useContext, useSignal, useStore } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { Boton } from "~/components/ui/boton";
import { Campo, Interruptor } from "~/components/ui/campo";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Fila, Grupo } from "~/components/ui/grupo";
import { Hoja } from "~/components/ui/hoja";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla, Vacio } from "~/components/ui/vacio";
import { api, mensajeError } from "~/lib/api";
import { plural } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { Lista, ReglaEscalamiento } from "~/lib/tipos";
import { toast, UiCtx, useDialog } from "~/lib/ui";

// Las acciones que el motor entiende (la pasarela rechaza cualquier otra con 400).
const ACCIONES: Record<string, string> = {
  avisar_tecnico: "Avisar al técnico",
  escalar_nivel: "Escalar al siguiente nivel",
  avisar_responsable: "Avisar al responsable del grupo",
  avisar_supervisor: "Avisar al supervisor",
  avisar_guardia: "Avisar a la guardia",
  nota: "Dejar una nota interna",
};
const textoAccion = (t: string): string => ACCIONES[t] ?? t.replace(/_/g, " ");
/** Porcentaje del plazo de una regla: `umbral_pct` (el motor) o `condicion.porcentaje` (alias de la pasarela). */
const umbralDe = (r: ReglaEscalamiento): number | null => {
  if (typeof r.umbral_pct === "number") return r.umbral_pct;
  const c = r.condicion?.["umbral_pct"] ?? r.condicion?.["porcentaje"];
  return typeof c === "number" ? c : null;
};

const estadoRegla = (r: ReglaEscalamiento): string => (!r.activa ? "Apagada" : r.modo === "sombra" ? "En sombra" : "Activa");

/** 08 · Escalamiento. ¿Qué pasa cuando algo vence? Una regla nueva entra en modo sombra: registra lo que habría hecho,
 *  sin actuar, y pasa a activa cuando su cifra lo justifica. */
export default component$(() => {
  const ui = useContext(UiCtx);
  const dialog = useDialog();
  const { r, recargar, refrescar } = useRecurso<Lista<ReglaEscalamiento>>("/api/escalamiento/reglas", { eventos: false });
  const abierta = useSignal(0);
  const f = useStore({ activa: true, modo: "sombra", porcentaje: "", acciones: [] as string[], error: "", guardando: false });
  const puedeEditar = ui.usuario?.rol === "admin";

  const abrir = $((regla: ReglaEscalamiento) => {
    f.activa = regla.activa;
    f.modo = regla.modo;
    const u = umbralDe(regla);
    f.porcentaje = u !== null ? String(u) : "";
    f.acciones = regla.acciones.map((a) => a.tipo);
    f.error = "";
    abierta.value = regla.id;
  });

  const guardar = $(async () => {
    const regla = r.datos?.items.find((x) => x.id === abierta.value);
    if (!regla) return;
    f.error = "";
    const pct = f.porcentaje === "" ? undefined : Number(f.porcentaje);
    if (pct !== undefined && !(pct >= 1 && pct <= 200)) {
      f.error = "El porcentaje del plazo va entre 1 y 200.";
      document.getElementById("c-reg-pct")?.focus();
      return;
    }
    if (f.activa && f.acciones.length === 0) {
      f.error = "Una regla activa necesita al menos una acción. Apágala o elige qué hace.";
      return;
    }
    if (f.modo === "activo" && regla.modo === "sombra") {
      const ok = await dialog.confirm({
        titulo: `¿Pasar «${regla.descripcion}» a activa?`,
        texto: `Hoy solo registra lo que habría hecho (${plural(regla.disparos_7d ?? 0, "vez", "veces")} en 7 días). Activa, empezará a actuar sobre las incidencias reales.`,
        ok: "Pasar a activa",
      });
      if (!ok) return;
    }
    f.guardando = true;
    try {
      await api(`/api/escalamiento/reglas/${regla.id}`, {
        method: "PUT",
        // El porcentaje viaja con los dos nombres: `umbral_pct` (el del motor) y `porcentaje` (el de la consola).
        json: {
          activa: f.activa,
          modo: f.modo,
          ...(pct !== undefined ? { umbral_pct: pct } : {}),
          condicion: pct !== undefined ? { ...regla.condicion, umbral_pct: pct, porcentaje: pct } : regla.condicion,
          acciones: f.acciones.map((tipo) => ({ tipo })),
        },
      });
      toast("Regla guardada.", "ok");
      abierta.value = 0;
      await refrescar();
    } catch (e) {
      f.error = `${mensajeError(e)} Tus cambios siguen en pantalla.`;
    } finally {
      f.guardando = false;
    }
  });

  const d = r.datos;
  const regla = d?.items.find((x) => x.id === abierta.value);
  return (
    <div class="pagina pagina-agrupada">
      <div class="pagina-interior">
        <p class="ajustes-intro">
          Una regla en <strong>sombra</strong> registra lo que habría hecho, sin actuar. Pásala a <strong>activa</strong> cuando su cifra lo justifique.
          {!puedeEditar && " Solo el administrador puede editarlas."}
        </p>
        {r.estado === "cargando" && !d && <EsqueletoFilas n={6} />}
        {r.estado === "error" && !d && <Falla titulo="No pudimos cargar las reglas." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />}
        {d && d.items.length === 0 && <Vacio titulo="Todavía no hay reglas de escalamiento." texto="Sin reglas, ninguna incidencia sube sola cuando vence." />}
        {d && d.items.length > 0 && (
          <Grupo>
            {d.items.map((x) => (
              <Fila
                key={x.id}
                titulo={x.descripcion}
                detalle={`${plural(x.disparos_7d ?? 0, "disparo", "disparos")} en 7 días · ${x.acciones.map((a) => textoAccion(a.tipo)).join(" + ") || "sin acciones"}`}
                valor={estadoRegla(x)}
                navega
                onClick$={() => abrir(x)}
              />
            ))}
          </Grupo>
        )}
      </div>
      {regla && (
        <Hoja titulo={regla.descripcion} subtitulo={`Regla ${regla.clave} · versión ${regla.version}`} onCerrar$={() => (abierta.value = 0)} pie>
          <form class="formulario" preventdefault:submit onSubmit$={guardar} id="form-regla">
            <div class="fila-g fila-interna">
              <span class="fila-g-texto">
                <span class="fila-g-titulo">Regla activa</span>
                <span class="fila-g-detalle">Apagada, no se evalúa ni en sombra.</span>
              </span>
              <Interruptor etiqueta="Regla activa" activo={f.activa} deshabilitado={!puedeEditar} onCambio$={(v) => (f.activa = v)} />
            </div>
            <div class="campo">
              <span class="campo-etiqueta" id="modo-et">
                Modo
              </span>
              <Segmentado
                etiqueta="Modo de la regla"
                valor={f.modo}
                onCambio$={(v) => puedeEditar && (f.modo = v)}
                opciones={[
                  { valor: "sombra", titulo: "Sombra" },
                  { valor: "activo", titulo: "Activo" },
                ]}
              />
              <p class="campo-ayuda">{f.modo === "sombra" ? "Registra lo que habría hecho. No avisa ni escala." : "Actúa de verdad: avisa, escala y deja un evento en la incidencia."}</p>
            </div>
            {umbralDe(regla) !== null && (
              <Campo etiqueta="Porcentaje del plazo" nombre="reg-pct" tipo="number" modo="numeric" valor={f.porcentaje} onValor$={(v) => (f.porcentaje = v)} ayuda="75 avisa al llegar a tres cuartas partes del plazo; 100, al vencer." deshabilitado={!puedeEditar} />
            )}
            <fieldset class="acciones-regla">
              <legend class="campo-etiqueta">Qué hace</legend>
              {[...Object.keys(ACCIONES), ...regla.acciones.map((a) => a.tipo).filter((t) => !(t in ACCIONES))].map((k) => (
                <label class="check" key={k}>
                  <input
                    type="checkbox"
                    checked={f.acciones.includes(k)}
                    disabled={!puedeEditar}
                    onChange$={(_, el) => {
                      f.acciones = el.checked ? [...f.acciones, k] : f.acciones.filter((x) => x !== k);
                    }}
                  />
                  <span>{textoAccion(k)}</span>
                </label>
              ))}
            </fieldset>
            {f.error && (
              <p class="campo-error" role="alert">
                {f.error}
              </p>
            )}
          </form>
          <div q:slot="pie">
            <Boton
              onClick$={() => {
                abierta.value = 0;
              }}
            >
              {puedeEditar ? "Cancelar" : "Cerrar"}
            </Boton>
            {puedeEditar && (
              <Boton variante="principal" tipo="submit" form="form-regla" cargando={f.guardando}>
                Guardar
              </Boton>
            )}
          </div>
        </Hoja>
      )}
    </div>
  );
});

export const head: DocumentHead = { title: "Escalamiento · jsrbot" };
