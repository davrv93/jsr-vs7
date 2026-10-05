import { $, component$, useContext, useSignal, useStore, useVisibleTask$, type QRL } from "@builder.io/qwik";
import { api, mensajeError } from "~/lib/api";
import { CATEGORIA_TEXTO, DIA_TEXTO, duracion, ESTADO_TEXTO, fecha, NIVEL_TEXTO, numero } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { Grupo, Lista, Tecnico } from "~/lib/tipos";
import { toast, UiCtx, useDialog } from "~/lib/ui";
import { Avatar } from "./ui/avatar";
import { Campo, CampoHora, horaValida, Interruptor, Selector } from "./ui/campo";
import { EsqueletoDetalle } from "./ui/esqueleto";
import { Hoja } from "./ui/hoja";
import { Icono } from "./ui/icono";
import { Segmentado } from "./ui/segmentado";
import { Enlace } from "./ui/enlace";
import { Falla, Vacio } from "./ui/vacio";

const NIVELES_HAB = [
  { valor: "0", titulo: "No" },
  { valor: "1", titulo: "Básico" },
  { valor: "2", titulo: "Medio" },
  { valor: "3", titulo: "Experto" },
];

interface FormTecnico {
  nombre: string;
  correo: string;
  whatsapp: string;
  nivel: string;
  capacidad: string;
  estado: string;
  habilidades: Record<string, string>;
  turnos: Record<string, { activo: boolean; desde: string; hasta: string }>;
  grupos: number[];
  errores: Record<string, string>;
  sucio: boolean;
  guardando: boolean;
}

interface FichaProps {
  id: number;
  modo: "panel" | "hoja" | "pagina";
  onCerrar$?: QRL<() => void>;
  onGuardada$?: QRL<() => void>;
}

/** 07 · Ficha del técnico: ¿qué sabe hacer, cuándo trabaja, cómo le va? Una sola acción: Guardar. */
export const FichaTecnico = component$<FichaProps>((p) => {
  const ui = useContext(UiCtx);
  const dialog = useDialog();
  const { r, recargar } = useRecurso<Tecnico>(`/api/tecnicos/${p.id}`);
  const grupos = useSignal<Grupo[]>([]);
  const f = useStore<FormTecnico>({
    nombre: "",
    correo: "",
    whatsapp: "",
    nivel: "N1",
    capacidad: "8",
    estado: "activo",
    habilidades: {},
    turnos: {},
    grupos: [],
    errores: {},
    sucio: false,
    guardando: false,
  });
  const cargado = useSignal(false);

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    async ({ track }) => {
      const d = track(() => r.datos);
      if (!d || cargado.value) return;
      cargado.value = true;
      f.nombre = d.nombre;
      f.correo = d.correo ?? "";
      f.whatsapp = d.whatsapp ?? "";
      f.nivel = d.nivel;
      f.capacidad = String(d.capacidad);
      f.estado = d.estado;
      f.habilidades = Object.fromEntries(Object.keys(CATEGORIA_TEXTO).map((c) => [c, String(d.habilidades.find((h) => h.categoria === c)?.nivel ?? 0)]));
      f.turnos = Object.fromEntries(
        [1, 2, 3, 4, 5, 6, 7].map((dia) => {
          const t = d.turnos.find((x) => x.dia_semana === dia);
          return [String(dia), { activo: !!t, desde: t?.desde ?? "08:30", hasta: t?.hasta ?? "18:00" }];
        }),
      );
      f.grupos = d.grupos.map((g) => g.id);
      try {
        grupos.value = (await api<Lista<Grupo>>("/api/grupos")).items;
      } catch {
        grupos.value = [];
      }
    },
    { strategy: "document-ready" },
  );

  const guardar = $(async () => {
    const e: Record<string, string> = {};
    if (!f.nombre.trim()) e.nombre = "Falta el nombre.";
    if (f.correo && !/^\S+@\S+\.\S+$/.test(f.correo)) e.correo = "Ese correo no parece válido.";
    if (f.whatsapp && !/^\d{9,15}$/.test(f.whatsapp)) e.whatsapp = "Solo dígitos con el prefijo del país, por ejemplo 51987654321.";
    const cap = Number(f.capacidad);
    if (!(cap >= 1 && cap <= 50)) e.capacidad = "Entre 1 y 50 incidencias a la vez.";
    for (const [dia, t] of Object.entries(f.turnos)) {
      if (!t.activo) continue;
      if (!horaValida(t.desde) || !horaValida(t.hasta)) e[`turno${dia}`] = `Turno del ${DIA_TEXTO[Number(dia)].toLowerCase()}: escribe las horas como 08:30 (24 horas).`;
      else if (t.desde >= t.hasta) e[`turno${dia}`] = `El turno del ${DIA_TEXTO[Number(dia)].toLowerCase()} debe terminar después de empezar.`;
    }
    f.errores = e;
    const primero = Object.keys(e)[0];
    if (primero) {
      document.getElementById(`c-t-${primero}`)?.focus();
      toast("Hay datos por corregir. Revisa los campos marcados.", "error");
      return;
    }
    f.guardando = true;
    try {
      await api(`/api/tecnicos/${p.id}`, {
        method: "PUT",
        json: {
          nombre: f.nombre.trim(),
          correo: f.correo,
          whatsapp: f.whatsapp,
          nivel: f.nivel,
          capacidad: cap,
          estado: f.estado,
          habilidades: Object.entries(f.habilidades).map(([categoria, n]) => ({ categoria, nivel: Number(n) })),
          turnos: Object.entries(f.turnos)
            .filter(([, t]) => t.activo)
            .map(([dia, t]) => ({ dia_semana: Number(dia), desde: t.desde, hasta: t.hasta })),
          grupo_ids: f.grupos,
        },
      });
      f.sucio = false;
      toast("Ficha guardada.", "ok");
      await recargar();
      await p.onGuardada$?.();
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudo guardar la ficha", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      f.guardando = false;
    }
  });

  const cambia = $(() => {
    f.sucio = true;
  });

  if (r.estado === "cargando" && !r.datos) return <div class={`detalle detalle-${p.modo}`}><EsqueletoDetalle /></div>;
  if (r.estado === "error" && !r.datos) {
    return (
      <div class={`detalle detalle-${p.modo}`}>
        {r.error.includes("No encontramos") ? (
          <Vacio titulo="Esa persona ya no está en el equipo." accion="Volver al equipo" onAccion$={p.onCerrar$} />
        ) : (
          <Falla titulo="No pudimos abrir la ficha." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />
        )}
      </div>
    );
  }
  const d = r.datos!;
  const carga = d.carga;
  const pct = Math.min(100, Math.round((carga / Math.max(1, d.capacidad)) * 100));
  const sobrecargado = carga > d.capacidad;
  const puedeEditar = ui.usuario?.rol === "supervisor" || ui.usuario?.rol === "admin" || ui.usuario?.rol === "gerencia";

  return (
    <article class={`detalle detalle-${p.modo}`} aria-label={`Ficha de ${d.nombre}`}>
      <div class="detalle-cuerpo">
        <header class="ficha-cab">
          <Avatar nombre={d.nombre} tam={56} foto={d.foto} />
          <div class="ficha-cab-texto">
            <div class="det-sup">
              <span class="det-num">{NIVEL_TEXTO[d.nivel]}</span>
              {p.modo === "panel" && p.onCerrar$ && (
                <button type="button" class="icono-boton" aria-label="Cerrar la ficha" onClick$={p.onCerrar$}>
                  <Icono n="cerrar" />
                </button>
              )}
            </div>
            <h2 class="det-titulo">{d.nombre}</h2>
            <p class="det-persona">
              {d.grupos.length ? d.grupos.map((g) => g.nombre).join(" · ") : "Sin grupo"}
              {d.estado !== "activo" ? ` · ${d.estado === "ausente" ? "Ausente" : "Inactivo"}` : ""}
            </p>
            {d.ausencia && (
              <p class="det-estado">
                {d.ausencia.motivo ?? "Ausencia"} hasta el {fecha(d.ausencia.hasta)}
              </p>
            )}
          </div>
        </header>

        <section class="det-sec" aria-label="Carga y rendimiento">
          <div class="ficha-carga">
            <div>
              <p class="etiqueta-sec">Carga ahora</p>
              <p class={`ficha-carga-cifra${sobrecargado ? " plazo-por_vencer" : ""}`}>
                {carga} <span class="dato-sec">de {d.capacidad}</span>
              </p>
              <div class="barra-fina" role="img" aria-label={`${pct} % de su capacidad`}>
                <span style={{ width: `${pct}%` }} class={sobrecargado ? "llena" : ""} />
              </div>
              <p class="ficha-enlace">
                <Enlace a={`/incidencias?tecnico_id=${d.id}`}>Ver sus incidencias</Enlace>
              </p>
            </div>
            <dl class="ficha-rend">
              <div>
                <dt>Resueltas en 30 días</dt>
                <dd>{numero(d.rendimiento?.resueltas_30d)}</dd>
              </div>
              <div>
                <dt>Dentro del plazo</dt>
                <dd>{d.rendimiento?.sla_cumplido_pct != null ? `${numero(d.rendimiento.sla_cumplido_pct)} %` : "—"}</dd>
              </div>
              <div>
                <dt>Primera respuesta</dt>
                <dd>{d.rendimiento?.primera_respuesta_mediana_min != null ? duracion(d.rendimiento.primera_respuesta_mediana_min) : "—"}</dd>
              </div>
            </dl>
          </div>
          {!d.rendimiento?.sla_cumplido_pct && <p class="det-vacio">Todavía no hay datos de rendimiento: no tiene turnos ni incidencias resueltas.</p>}
        </section>

        <form class="formulario ficha-form" preventdefault:submit onSubmit$={guardar} id={`ficha-${d.id}`} onInput$={cambia} onChange$={cambia}>
          <section class="det-sec">
            <h3 class="etiqueta-sec">Datos</h3>
            <div class="formulario">
              <Campo etiqueta="Nombre" nombre="t-nombre" valor={f.nombre} onValor$={(v) => (f.nombre = v)} error={f.errores.nombre} requerido deshabilitado={!puedeEditar} />
              <div class="formulario-dos">
                <Campo etiqueta="Correo" nombre="t-correo" tipo="email" valor={f.correo} onValor$={(v) => (f.correo = v)} error={f.errores.correo} opcional deshabilitado={!puedeEditar} />
                <Campo etiqueta="WhatsApp" nombre="t-whatsapp" tipo="tel" modo="numeric" valor={f.whatsapp} onValor$={(v) => (f.whatsapp = v.replace(/\D/g, ""))} error={f.errores.whatsapp} opcional marcador="51987654321" deshabilitado={!puedeEditar} />
              </div>
              <div class="formulario-tres">
                <Selector etiqueta="Nivel" nombre="t-nivel" valor={f.nivel} onValor$={(v) => (f.nivel = v)} opciones={[{ valor: "N1", titulo: "N1" }, { valor: "N2", titulo: "N2" }, { valor: "N3", titulo: "N3" }]} deshabilitado={!puedeEditar} />
                <Selector etiqueta="Estado" nombre="t-estado" valor={f.estado} onValor$={(v) => (f.estado = v)} opciones={[{ valor: "activo", titulo: "Activo" }, { valor: "ausente", titulo: "Ausente" }, { valor: "inactivo", titulo: "Inactivo" }]} deshabilitado={!puedeEditar} />
                <Campo etiqueta="Capacidad" nombre="t-capacidad" tipo="number" modo="numeric" valor={f.capacidad} onValor$={(v) => (f.capacidad = v)} error={f.errores.capacidad} ayuda="Incidencias a la vez." deshabilitado={!puedeEditar} />
              </div>
            </div>
          </section>

          <section class="det-sec">
            <h3 class="etiqueta-sec">Grupos</h3>
            {grupos.value.length === 0 ? (
              <p class="det-vacio">No hay grupos creados todavía.</p>
            ) : (
              <ul class="lista-interruptores">
                {grupos.value.map((g) => (
                  <li key={g.id}>
                    <span>
                      {g.nombre} <span class="dato-sec">· {g.nivel}</span>
                    </span>
                    <Interruptor
                      etiqueta={`Pertenece a ${g.nombre}`}
                      activo={f.grupos.includes(g.id)}
                      deshabilitado={!puedeEditar}
                      onCambio$={(v) => {
                        f.grupos = v ? [...f.grupos, g.id] : f.grupos.filter((x) => x !== g.id);
                        f.sucio = true;
                      }}
                    />
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section class="det-sec">
            <h3 class="etiqueta-sec">Habilidades</h3>
            <p class="det-vacio habilidades-nota">El despachador asigna según estas habilidades. Sin ninguna, no recibe incidencias de forma automática.</p>
            <ul class="habilidades">
              {Object.keys(CATEGORIA_TEXTO).map((c) => (
                <li key={c}>
                  <span>{CATEGORIA_TEXTO[c]}</span>
                  <Segmentado
                    etiqueta={`Nivel en ${CATEGORIA_TEXTO[c]}`}
                    valor={f.habilidades[c] ?? "0"}
                    opciones={NIVELES_HAB}
                    onCambio$={(v) => {
                      if (!puedeEditar) return;
                      f.habilidades = { ...f.habilidades, [c]: v };
                      f.sucio = true;
                    }}
                  />
                </li>
              ))}
            </ul>
          </section>

          <section class="det-sec">
            <h3 class="etiqueta-sec">Turnos</h3>
            <ul class="turnos">
              {[1, 2, 3, 4, 5, 6, 7].map((dia) => {
                const t = f.turnos[String(dia)] ?? { activo: false, desde: "08:30", hasta: "18:00" };
                return (
                  <li key={dia} class={t.activo ? "" : "turno-libre"}>
                    <span class="turno-dia">{DIA_TEXTO[dia]}</span>
                    <Interruptor
                      etiqueta={`Trabaja el ${DIA_TEXTO[dia].toLowerCase()}`}
                      activo={t.activo}
                      deshabilitado={!puedeEditar}
                      onCambio$={(v) => {
                        f.turnos = { ...f.turnos, [String(dia)]: { ...t, activo: v } };
                        f.sucio = true;
                      }}
                    />
                    {t.activo ? (
                      <span class="turno-horas">
                        <CampoHora etiqueta={`Entrada del ${DIA_TEXTO[dia].toLowerCase()}`} valor={t.desde} deshabilitado={!puedeEditar} onValor$={(v) => (f.turnos = { ...f.turnos, [String(dia)]: { ...t, desde: v } })} />
                        <span aria-hidden="true">–</span>
                        <CampoHora etiqueta={`Salida del ${DIA_TEXTO[dia].toLowerCase()}`} id={`c-t-turno${dia}`} invalido={!!f.errores[`turno${dia}`]} valor={t.hasta} deshabilitado={!puedeEditar} onValor$={(v) => (f.turnos = { ...f.turnos, [String(dia)]: { ...t, hasta: v } })} />
                      </span>
                    ) : (
                      <span class="dato-sec turno-no">No trabaja</span>
                    )}
                    {f.errores[`turno${dia}`] && <p class="campo-error turno-error">{f.errores[`turno${dia}`]}</p>}
                  </li>
                );
              })}
            </ul>
            {d.turnos.length === 0 && <p class="det-vacio">Sin turnos, el despachador no le asigna nada fuera de una guardia.</p>}
          </section>
        </form>
      </div>
      {puedeEditar ? (
        <div class="compositor ficha-pie">
          <span class="compositor-sugerido">{f.sucio ? "Hay cambios sin guardar." : ESTADO_TEXTO[d.estado] ? "" : ""}</span>
          <button type="submit" form={`ficha-${d.id}`} class="boton boton-principal" disabled={!f.sucio || f.guardando} aria-busy={f.guardando ? "true" : undefined}>
            Guardar
          </button>
        </div>
      ) : (
        <div class="compositor compositor-cerrada">
          <p class="det-vacio">Solo supervisores y administradores pueden editar la ficha.</p>
        </div>
      )}
    </article>
  );
});

/** Añadir técnico: lo mínimo para empezar; el resto se completa en su ficha. */
export const NuevoTecnico = component$<{ onCerrar$: QRL<() => void>; onCreado$: QRL<(id: number) => void> }>((p) => {
  const nombre = useSignal("");
  const correo = useSignal("");
  const whatsapp = useSignal("");
  const nivel = useSignal("N1");
  const grupo = useSignal("");
  const grupos = useSignal<Grupo[]>([]);
  const errores = useStore<Record<string, string>>({});
  const enviando = useSignal(false);

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    async () => {
      try {
        grupos.value = (await api<Lista<Grupo>>("/api/grupos")).items;
      } catch {
        grupos.value = [];
      }
    },
    { strategy: "document-ready" },
  );

  const guardar = $(async () => {
    errores.nombre = !nombre.value.trim() ? "Escribe el nombre del técnico." : "";
    errores.correo = correo.value && !/^\S+@\S+\.\S+$/.test(correo.value) ? "Ese correo no parece válido." : "";
    errores.whatsapp = whatsapp.value && !/^\d{9,15}$/.test(whatsapp.value) ? "Solo dígitos con el prefijo del país, por ejemplo 51987654321." : "";
    const primero = ["nombre", "correo", "whatsapp"].find((k) => errores[k]);
    if (primero) {
      document.getElementById(`c-n-${primero}`)?.focus();
      return;
    }
    enviando.value = true;
    try {
      const t = await api<Tecnico>("/api/tecnicos", { method: "POST", json: { nombre: nombre.value.trim(), correo: correo.value, whatsapp: whatsapp.value, nivel: nivel.value, grupo_id: grupo.value || undefined } });
      toast(`${t.nombre} se añadió al equipo. Completa sus habilidades y turnos.`, "ok");
      await p.onCreado$(t.id);
    } catch (e) {
      toast(`No se pudo añadir. ${mensajeError(e)}`, "error");
    } finally {
      enviando.value = false;
    }
  });

  return (
    <Hoja titulo="Añadir técnico" subtitulo="Después completa sus habilidades y turnos en su ficha." onCerrar$={p.onCerrar$} pie>
      <form class="formulario" preventdefault:submit onSubmit$={guardar} id="form-tecnico">
        <Campo etiqueta="Nombre completo" nombre="n-nombre" valor={nombre.value} onValor$={(v) => (nombre.value = v)} error={errores.nombre} requerido autocompletar="off" />
        <Campo etiqueta="Correo" nombre="n-correo" tipo="email" valor={correo.value} onValor$={(v) => (correo.value = v)} error={errores.correo} opcional />
        <Campo etiqueta="WhatsApp" nombre="n-whatsapp" tipo="tel" modo="numeric" valor={whatsapp.value} onValor$={(v) => (whatsapp.value = v.replace(/\D/g, ""))} error={errores.whatsapp} opcional marcador="51987654321" ayuda="Para los avisos de escalamiento." />
        <div class="formulario-dos">
          <Selector etiqueta="Nivel" nombre="n-nivel" valor={nivel.value} onValor$={(v) => (nivel.value = v)} opciones={[{ valor: "N1", titulo: "N1 · Mesa de ayuda" }, { valor: "N2", titulo: "N2 · Especialista" }, { valor: "N3", titulo: "N3 · Proveedor" }]} />
          <Selector etiqueta="Grupo" nombre="n-grupo" valor={grupo.value} onValor$={(v) => (grupo.value = v)} opciones={[{ valor: "", titulo: "Sin grupo todavía" }, ...grupos.value.map((g) => ({ valor: String(g.id), titulo: g.nombre }))]} />
        </div>
      </form>
      <div q:slot="pie">
        <button type="button" class="boton boton-secundario" onClick$={p.onCerrar$}>
          Cancelar
        </button>
        <button type="submit" form="form-tecnico" class="boton boton-principal" disabled={enviando.value} aria-busy={enviando.value ? "true" : undefined}>
          Añadir
        </button>
      </div>
    </Hoja>
  );
});
