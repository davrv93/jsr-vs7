import { $, component$, useContext, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import { useNavigate } from "@builder.io/qwik-city";
import { api, mensajeError } from "~/lib/api";
import { cerrarSesion, guardarPref } from "~/lib/auth";
import { u } from "~/lib/base";
import { CATEGORIA_TEXTO, DIA_TEXTO, duracion, fechaCorta, IMPACTO_TEXTO, PRIORIDAD_TEXTO, ROL_TEXTO, URGENCIA_TEXTO } from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import type { Calendario, CeldaMatriz, Categoria, Grupo, Lista, PoliticaSla, UsuarioConsola } from "~/lib/tipos";
import { toast, UiCtx, useDialog } from "~/lib/ui";
import { Boton } from "./ui/boton";
import { Campo, CampoHora, horaValida, Interruptor, Selector } from "./ui/campo";
import { Fila, Grupo as GrupoUI } from "./ui/grupo";
import { EsqueletoFilas } from "./ui/esqueleto";
import { Segmentado } from "./ui/segmentado";
import { Falla } from "./ui/vacio";

// ---------------------------------------------------------------------------------------------------------------
/** General: apariencia, cuenta y atajos. Lo que ve cualquier rol. */
export const SeccionGeneral = component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const salir = $(async () => {
    cerrarSesion();
    await nav(u("/login"));
  });
  const rol = ui.usuario?.rol;
  return (
    <>
      <GrupoUI titulo="Apariencia" pie="«Sistema» sigue el modo claro u oscuro de tu equipo.">
        <Fila titulo="Tema">
          <Segmentado
            etiqueta="Tema"
            valor={ui.tema}
            onCambio$={(v) => {
              ui.tema = v as "sistema" | "claro" | "oscuro";
              guardarPref("tema", v);
            }}
            opciones={[
              { valor: "sistema", titulo: "Sistema" },
              { valor: "claro", titulo: "Claro" },
              { valor: "oscuro", titulo: "Oscuro" },
            ]}
          />
        </Fila>
      </GrupoUI>
      <GrupoUI titulo="Cuenta">
        <Fila titulo="Nombre" valor={ui.usuario?.nombre ?? "—"} />
        <Fila titulo="Rol" valor={rol ? ROL_TEXTO[rol] : "—"} />
        <Fila titulo="Cerrar sesión" detalle="Tendrás que volver a entrar con tu correo y clave." onClick$={salir} navega />
      </GrupoUI>
      <GrupoUI titulo="Atajos de teclado">
        <Fila titulo="Buscar en toda la consola" valor="⌘K" />
        <Fila titulo="Moverse por la bandeja" valor="j  k" />
        <Fila titulo="Abrir · asignarme · resolver" valor="↵  a  e" />
      </GrupoUI>
    </>
  );
});

// ---------------------------------------------------------------------------------------------------------------
interface FormSla {
  filas: { id: number; prioridad: string; categoria: string | null; calendario_id: number; respuesta: string; resolucion: string }[];
  errores: Record<string, string>;
  guardando: boolean;
}

/** SLA: plazos de primera respuesta y de resolución por prioridad (en minutos laborales). */
export const SeccionSla = component$(() => {
  const { r, recargar } = useRecurso<Lista<PoliticaSla>>("/api/sla", { eventos: false });
  const cal = useRecurso<Lista<Calendario>>("/api/calendarios", { eventos: false });
  const f = useStore<FormSla>({ filas: [], errores: {}, guardando: false });
  const listo = useSignal(false);
  const dialog = useDialog();

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const d = track(() => r.datos);
      if (!d || listo.value) return;
      listo.value = true;
      f.filas = d.items.map((p) => ({ id: p.id, prioridad: p.prioridad, categoria: p.categoria, calendario_id: p.calendario_id, respuesta: String(p.respuesta_min), resolucion: String(p.resolucion_min) }));
    },
    { strategy: "document-ready" },
  );

  const guardar = $(async () => {
    const e: Record<string, string> = {};
    f.filas.forEach((x) => {
      const a = Number(x.respuesta);
      const b = Number(x.resolucion);
      if (!(a > 0)) e[`r${x.id}`] = "Escribe los minutos de la primera respuesta (más de 0).";
      if (!(b > 0)) e[`s${x.id}`] = "Escribe los minutos de resolución (más de 0).";
      else if (b < a) e[`s${x.id}`] = "La resolución no puede ser más corta que la primera respuesta.";
    });
    f.errores = e;
    const primero = Object.keys(e)[0];
    if (primero) {
      document.getElementById(`c-sla-${primero}`)?.focus();
      return;
    }
    f.guardando = true;
    try {
      await api("/api/sla", { method: "PUT", json: { items: f.filas.map((x) => ({ id: x.id, respuesta_min: Number(x.respuesta), resolucion_min: Number(x.resolucion) })) } });
      toast("Plazos guardados. Las incidencias abiertas se recalculan.", "ok");
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudieron guardar los plazos", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      f.guardando = false;
    }
  });

  if (r.estado === "cargando" && !r.datos) return <EsqueletoFilas n={4} />;
  if (r.estado === "error" && !r.datos) return <Falla titulo="No pudimos cargar los plazos." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />;
  return (
    <form preventdefault:submit onSubmit$={guardar} noValidate>
      <p class="ajustes-intro">Plazos en minutos laborales: solo cuentan las horas del calendario y se descuentan las pausas por espera.</p>
      {f.filas.map((x) => (
        <GrupoUI key={x.id} titulo={`${x.prioridad} · ${PRIORIDAD_TEXTO[x.prioridad]}${x.categoria ? ` · solo ${CATEGORIA_TEXTO[x.categoria] ?? x.categoria}` : ""}`} pie={`Calendario: ${cal.r.datos?.items.find((c) => c.id === x.calendario_id)?.nombre ?? "—"}`}>
          <div class="fila-g fila-form">
            <Campo
              etiqueta="Primera respuesta (min)"
              nombre={`sla-r${x.id}`}
              tipo="number"
              modo="numeric"
              valor={x.respuesta}
              onValor$={(v) => (x.respuesta = v)}
              error={f.errores[`r${x.id}`]}
              ayuda={Number(x.respuesta) > 0 ? duracion(Number(x.respuesta)) : undefined}
            />
            <Campo
              etiqueta="Resolución (min)"
              nombre={`sla-s${x.id}`}
              tipo="number"
              modo="numeric"
              valor={x.resolucion}
              onValor$={(v) => (x.resolucion = v)}
              error={f.errores[`s${x.id}`]}
              ayuda={Number(x.resolucion) > 0 ? duracion(Number(x.resolucion)) : undefined}
            />
          </div>
        </GrupoUI>
      ))}
      <div class="ajustes-guardar">
        <Boton variante="principal" tipo="submit" cargando={f.guardando}>
          Guardar plazos
        </Boton>
      </div>
    </form>
  );
});

// ---------------------------------------------------------------------------------------------------------------
interface DiaForm {
  activo: boolean;
  a1: string;
  b1: string;
  a2: string;
  b2: string;
}
interface FormCal {
  id: number;
  nombre: string;
  zona: string;
  h24: boolean;
  dias: Record<string, DiaForm>;
  feriados: { fecha: string; nombre: string }[];
  nuevoFecha: string;
  nuevoNombre: string;
}

/** Calendario: horario laboral por día (hasta dos tramos), 24 × 7 y feriados. */
export const SeccionCalendario = component$(() => {
  const { r, recargar } = useRecurso<Lista<Calendario>>("/api/calendarios", { eventos: false });
  const cals = useStore<{ items: FormCal[]; errores: Record<string, string>; guardando: boolean }>({ items: [], errores: {}, guardando: false });
  const listo = useSignal(false);
  const dialog = useDialog();

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const d = track(() => r.datos);
      if (!d || listo.value) return;
      listo.value = true;
      cals.items = d.items.map((c) => ({
        id: c.id,
        nombre: c.nombre,
        zona: c.zona,
        h24: c.veinticuatro_siete,
        dias: Object.fromEntries(
          [1, 2, 3, 4, 5, 6, 7].map((dia) => {
            const t = c.horario[String(dia)] ?? [];
            return [String(dia), { activo: t.length > 0, a1: t[0]?.[0] ?? "08:30", b1: t[0]?.[1] ?? "13:00", a2: t[1]?.[0] ?? "", b2: t[1]?.[1] ?? "" }];
          }),
        ),
        feriados: c.feriados.map((x) => ({ ...x })),
        nuevoFecha: "",
        nuevoNombre: "",
      }));
    },
    { strategy: "document-ready" },
  );

  const guardar = $(async () => {
    const e: Record<string, string> = {};
    for (const c of cals.items) {
      if (c.h24) continue;
      for (const [dia, t] of Object.entries(c.dias)) {
        if (!t.activo) continue;
        const nom = DIA_TEXTO[Number(dia)];
        if (!horaValida(t.a1) || !horaValida(t.b1)) e[`${c.id}-${dia}`] = `${nom}: escribe las horas como 08:30 (formato de 24 horas).`;
        else if (t.a1 >= t.b1) e[`${c.id}-${dia}`] = `${nom}: el primer tramo debe terminar después de empezar.`;
        else if ((t.a2 && !horaValida(t.a2)) || (t.b2 && !horaValida(t.b2))) e[`${c.id}-${dia}`] = `${nom}: escribe las horas como 14:00 (formato de 24 horas).`;
        else if ((t.a2 || t.b2) && (!t.a2 || !t.b2 || t.a2 >= t.b2)) e[`${c.id}-${dia}`] = `${nom}: completa el segundo tramo o déjalo vacío.`;
        else if (t.a2 && t.a2 < t.b1) e[`${c.id}-${dia}`] = `${nom}: el segundo tramo debe empezar después del primero.`;
      }
    }
    cals.errores = e;
    const primero = Object.keys(e)[0];
    if (primero) {
      document.getElementById(`dia-${primero}`)?.scrollIntoView({ block: "center" });
      toast("Revisa los horarios marcados.", "error");
      return;
    }
    cals.guardando = true;
    try {
      await api("/api/calendarios", {
        method: "PUT",
        json: {
          items: cals.items.map((c) => ({
            id: c.id,
            nombre: c.nombre,
            zona: c.zona,
            veinticuatro_siete: c.h24,
            horario: Object.fromEntries(
              Object.entries(c.dias).map(([dia, t]) => [dia, t.activo ? [[t.a1, t.b1], ...(t.a2 && t.b2 ? [[t.a2, t.b2]] : [])] : []]),
            ),
            feriados: c.feriados,
          })),
        },
      });
      toast("Calendarios guardados.", "ok");
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudieron guardar los calendarios", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      cals.guardando = false;
    }
  });

  if (r.estado === "cargando" && !r.datos) return <EsqueletoFilas n={5} />;
  if (r.estado === "error" && !r.datos) return <Falla titulo="No pudimos cargar los calendarios." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />;
  return (
    <form preventdefault:submit onSubmit$={guardar} noValidate>
      <p class="ajustes-intro">El reloj de SLA solo avanza en estos horarios y no cuenta los feriados. Hora de Lima.</p>
      {cals.items.map((c) => (
        <section key={c.id} class="ajustes-bloque">
          <GrupoUI titulo={c.nombre}>
            <Fila titulo="Atiende las 24 horas, todos los días" detalle="Para la guardia de P1. Ignora el horario de abajo.">
              <Interruptor etiqueta={`${c.nombre}: 24 × 7`} activo={c.h24} onCambio$={(v) => (c.h24 = v)} />
            </Fila>
          </GrupoUI>
          {!c.h24 && (
            <GrupoUI titulo="Horario laboral">
              {[1, 2, 3, 4, 5, 6, 7].map((dia) => {
                const t = c.dias[String(dia)];
                const err = cals.errores[`${c.id}-${dia}`];
                return (
                  <div class="fila-g fila-dia" key={dia} id={`dia-${c.id}-${dia}`}>
                    <div class="fila-dia-cab">
                      <span class="fila-g-titulo">{DIA_TEXTO[dia]}</span>
                      <Interruptor etiqueta={`${DIA_TEXTO[dia]} es laborable`} activo={t.activo} onCambio$={(v) => (t.activo = v)} />
                    </div>
                    {t.activo ? (
                      <div class="fila-dia-horas">
                        <CampoHora etiqueta={`${DIA_TEXTO[dia]}, entrada de la mañana`} valor={t.a1} invalido={!!err} onValor$={(v) => (t.a1 = v)} />
                        <span aria-hidden="true">–</span>
                        <CampoHora etiqueta={`${DIA_TEXTO[dia]}, salida de la mañana`} valor={t.b1} invalido={!!err} onValor$={(v) => (t.b1 = v)} />
                        <span class="fila-dia-sep" aria-hidden="true">
                          y
                        </span>
                        <CampoHora etiqueta={`${DIA_TEXTO[dia]}, entrada de la tarde (opcional)`} valor={t.a2} invalido={!!err} onValor$={(v) => (t.a2 = v)} />
                        <span aria-hidden="true">–</span>
                        <CampoHora etiqueta={`${DIA_TEXTO[dia]}, salida de la tarde (opcional)`} valor={t.b2} invalido={!!err} onValor$={(v) => (t.b2 = v)} />
                      </div>
                    ) : (
                      <span class="dato-sec">No laborable</span>
                    )}
                    {err && <p class="campo-error fila-dia-error">{err}</p>}
                  </div>
                );
              })}
            </GrupoUI>
          )}
          <GrupoUI titulo="Feriados" pie={c.feriados.length === 0 ? "Sin feriados cargados: el reloj corre todos los días laborables." : undefined}>
            {c.feriados.map((fe, i) => (
              <div class="fila-g" key={`${fe.fecha}-${i}`}>
                <span class="fila-g-texto">
                  <span class="fila-g-titulo">{fe.nombre}</span>
                  <span class="fila-g-detalle">{fechaCorta(fe.fecha)}</span>
                </span>
                <Boton
                  variante="peligro"
                  pequeno
                  etiqueta={`Quitar el feriado ${fe.nombre}`}
                  confirmar={{ titulo: `¿Quitar «${fe.nombre}»?`, texto: "Ese día volverá a contar como laborable en el reloj de SLA.", ok: "Quitar feriado" }}
                  onClick$={() => {
                    c.feriados = c.feriados.filter((_, j) => j !== i);
                  }}
                >
                  Quitar
                </Boton>
              </div>
            ))}
            <div class="fila-g fila-form">
              <Campo etiqueta="Fecha" nombre={`fe-f-${c.id}`} tipo="date" valor={c.nuevoFecha} onValor$={(v) => (c.nuevoFecha = v)} />
              <Campo etiqueta="Nombre" nombre={`fe-n-${c.id}`} valor={c.nuevoNombre} onValor$={(v) => (c.nuevoNombre = v)} marcador="Ej.: Día del Trabajo" />
              <button
                type="button"
                class="boton boton-secundario fila-form-boton"
                disabled={!c.nuevoFecha || !c.nuevoNombre.trim()}
                onClick$={() => {
                  c.feriados = [...c.feriados, { fecha: c.nuevoFecha, nombre: c.nuevoNombre.trim() }].sort((a, b) => a.fecha.localeCompare(b.fecha));
                  c.nuevoFecha = "";
                  c.nuevoNombre = "";
                }}
              >
                Añadir
              </button>
            </div>
          </GrupoUI>
        </section>
      ))}
      <div class="ajustes-guardar">
        <Boton variante="principal" tipo="submit" cargando={cals.guardando}>
          Guardar calendarios
        </Boton>
      </div>
    </form>
  );
});

// ---------------------------------------------------------------------------------------------------------------
/** Categorías: nombre, grupo que las atiende y si están activas. */
export const SeccionCategorias = component$(() => {
  const { r, recargar } = useRecurso<Lista<Categoria>>("/api/categorias", { eventos: false });
  const gr = useRecurso<Lista<Grupo>>("/api/grupos", { eventos: false });
  const f = useStore<{ items: Categoria[]; errores: Record<number, string>; guardando: boolean }>({ items: [], errores: {}, guardando: false });
  const listo = useSignal(false);
  const dialog = useDialog();

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const d = track(() => r.datos);
      if (!d || listo.value) return;
      listo.value = true;
      f.items = d.items.map((c) => ({ ...c }));
    },
    { strategy: "document-ready" },
  );

  const guardar = $(async () => {
    const e: Record<number, string> = {};
    f.items.forEach((c) => {
      if (!c.nombre.trim()) e[c.id] = "La categoría necesita un nombre.";
    });
    f.errores = e;
    const primero = Object.keys(e)[0];
    if (primero) {
      document.getElementById(`c-cat-${primero}`)?.focus();
      return;
    }
    f.guardando = true;
    try {
      await api("/api/categorias", { method: "PUT", json: { items: f.items } });
      toast("Categorías guardadas.", "ok");
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudieron guardar las categorías", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      f.guardando = false;
    }
  });

  if (r.estado === "cargando" && !r.datos) return <EsqueletoFilas n={6} />;
  if (r.estado === "error" && !r.datos) return <Falla titulo="No pudimos cargar las categorías." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />;
  const grupos = gr.r.datos?.items ?? [];
  return (
    <form preventdefault:submit onSubmit$={guardar} noValidate>
      <p class="ajustes-intro">El grupo de cada categoría recibe sus incidencias. Una categoría inactiva ya no se ofrece al asistente.</p>
      <GrupoUI>
        {f.items.map((c) => (
          <div class="fila-g fila-form fila-cat" key={c.id}>
            <Campo etiqueta="Nombre" nombre={`cat-${c.id}`} valor={c.nombre} onValor$={(v) => (c.nombre = v)} error={f.errores[c.id]} />
            <Selector
              etiqueta="Grupo que la atiende"
              nombre={`catg-${c.id}`}
              valor={c.grupo_id ? String(c.grupo_id) : ""}
              onValor$={(v) => (c.grupo_id = v ? Number(v) : null)}
              opciones={[{ valor: "", titulo: "Sin grupo" }, ...grupos.map((g) => ({ valor: String(g.id), titulo: g.nombre }))]}
            />
            <label class="fila-cat-activa">
              <Interruptor etiqueta={`${c.nombre} activa`} activo={c.activa} onCambio$={(v) => (c.activa = v)} />
              <span>Activa</span>
            </label>
          </div>
        ))}
      </GrupoUI>
      <div class="ajustes-guardar">
        <Boton variante="principal" tipo="submit" cargando={f.guardando}>
          Guardar categorías
        </Boton>
      </div>
    </form>
  );
});

// ---------------------------------------------------------------------------------------------------------------
const IMPACTOS = ["persona", "area", "sede", "organizacion"] as const;
const URGENCIAS = ["baja", "media", "alta", "critica"] as const;

/** Matriz de prioridad: impacto × urgencia → P1 a P4. La prioridad nunca la escribe el asistente. */
export const SeccionMatriz = component$(() => {
  const { r, recargar } = useRecurso<Lista<CeldaMatriz>>("/api/matriz", { eventos: false });
  const f = useStore<{ celdas: Record<string, string>; guardando: boolean }>({ celdas: {}, guardando: false });
  const listo = useSignal(false);
  const dialog = useDialog();

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const d = track(() => r.datos);
      if (!d || listo.value) return;
      listo.value = true;
      f.celdas = Object.fromEntries(d.items.map((c) => [`${c.impacto}|${c.urgencia}`, c.prioridad]));
    },
    { strategy: "document-ready" },
  );

  const guardar = $(async () => {
    f.guardando = true;
    try {
      await api("/api/matriz", { method: "PUT", json: { items: Object.entries(f.celdas).map(([k, prioridad]) => ({ impacto: k.split("|")[0], urgencia: k.split("|")[1], prioridad })) } });
      toast("Matriz guardada. Aplica a las incidencias nuevas.", "ok");
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudo guardar la matriz", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      f.guardando = false;
    }
  });

  if (r.estado === "cargando" && !r.datos) return <EsqueletoFilas n={5} />;
  if (r.estado === "error" && !r.datos) return <Falla titulo="No pudimos cargar la matriz." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />;
  return (
    <form preventdefault:submit onSubmit$={guardar}>
      <p class="ajustes-intro">Cruza a cuántas personas afecta con cuán urgente es. El asistente propone impacto y urgencia; esta tabla decide la prioridad.</p>
      <div class="matriz" role="group" aria-label="Matriz de prioridad">
        <div class="matriz-cab" aria-hidden="true">
          <span />
          {URGENCIAS.map((ur) => (
            <span key={ur}>Urgencia {URGENCIA_TEXTO[ur].toLowerCase()}</span>
          ))}
        </div>
        {IMPACTOS.map((im) => (
          <div class="matriz-fila" key={im}>
            <span class="matriz-impacto">{IMPACTO_TEXTO[im]}</span>
            {URGENCIAS.map((ur) => {
              const k = `${im}|${ur}`;
              return (
                <label class="matriz-celda" key={ur}>
                  <span class="matriz-etiqueta">Urgencia {URGENCIA_TEXTO[ur].toLowerCase()}</span>
                  <select aria-label={`Impacto: ${IMPACTO_TEXTO[im].toLowerCase()}, urgencia ${URGENCIA_TEXTO[ur].toLowerCase()}`} onChange$={(_, el) => (f.celdas[k] = el.value)}>
                    {["P1", "P2", "P3", "P4"].map((pr) => (
                      <option key={pr} value={pr} selected={f.celdas[k] === pr}>
                        {`${pr} · ${PRIORIDAD_TEXTO[pr]}`}
                      </option>
                    ))}
                  </select>
                </label>
              );
            })}
          </div>
        ))}
      </div>
      <div class="ajustes-guardar">
        <Boton variante="principal" tipo="submit" cargando={f.guardando}>
          Guardar matriz
        </Boton>
      </div>
    </form>
  );
});

// ---------------------------------------------------------------------------------------------------------------
/** Roles: quién entra y con qué rol. Los cambios se aplican al momento. */
export const SeccionRoles = component$(() => {
  const ui = useContext(UiCtx);
  const { r, recargar, refrescar } = useRecurso<Lista<UsuarioConsola>>("/api/usuarios", { eventos: false });
  const cambiar = $(async (id: number, cambio: Record<string, unknown>) => {
    try {
      await api(`/api/usuarios/${id}`, { method: "PUT", json: cambio });
      toast("Cambio aplicado.", "ok");
      await refrescar();
    } catch (e) {
      toast(`${mensajeError(e)}`, "error");
      await refrescar();
    }
  });
  if (r.estado === "cargando" && !r.datos) return <EsqueletoFilas n={5} />;
  if (r.estado === "error" && !r.datos) return <Falla titulo="No pudimos cargar los usuarios." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />;
  const d = r.datos!;
  return (
    <>
      <p class="ajustes-intro">El técnico atiende incidencias; el supervisor reasigna y ve al equipo; gerencia ve los indicadores; el entrenador cuida al asistente; el administrador puede todo.</p>
      <GrupoUI>
        {d.items.map((x) => (
          <div class="fila-g fila-form fila-rol" key={x.id}>
            <span class="fila-g-texto">
              <span class="fila-g-titulo">{x.nombre}</span>
              <span class="fila-g-detalle">{x.email}{!x.activo ? " · sin acceso" : ""}</span>
            </span>
            <Selector
              etiqueta={`Rol de ${x.nombre}`}
              nombre={`rol-${x.id}`}
              valor={x.rol}
              deshabilitado={x.id === ui.usuario?.id}
              ayuda={x.id === ui.usuario?.id ? "Tu propio rol no se cambia." : undefined}
              onValor$={(v) => cambiar(x.id, { rol: v })}
              opciones={Object.entries(ROL_TEXTO).map(([valor, titulo]) => ({ valor, titulo }))}
            />
            <label class="fila-cat-activa">
              <Interruptor etiqueta={`${x.nombre} puede entrar`} activo={x.activo} deshabilitado={x.id === ui.usuario?.id} onCambio$={(v) => cambiar(x.id, { activo: v })} />
              <span>Acceso</span>
            </label>
          </div>
        ))}
      </GrupoUI>
    </>
  );
});
