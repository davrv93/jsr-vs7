import { $, component$, useContext, useSignal, useVisibleTask$, type QRL } from "@builder.io/qwik";
import { Link } from "@builder.io/qwik-city";
import { api, mensajeError } from "~/lib/api";
import { guardarBorrador, leerBorrador } from "~/lib/auth";
import { BASE } from "~/lib/base";
import {
  CATEGORIA_TEXTO,
  CANAL_TEXTO,
  confianzaPct,
  filasFicha,
  diaHilo,
  ESTADO_TEXTO,
  fechaHora,
  hora,
  IMPACTO_TEXTO,
  INTENCION_TEXTO,
  mismoDia,
  nombreCorto,
  numero,
  PRIORIDAD_TEXTO,
  textoEvento,
  URGENCIA_TEXTO,
} from "~/lib/format";
import { useRecurso } from "~/lib/recurso";
import { nivelSla, plazoCorto, plazoLargo } from "~/lib/sla";
import type { IncDetalle, IncResumen, MensajeCaso, Tecnico, Lista } from "~/lib/tipos";
import { toast, UiCtx, useDialog } from "~/lib/ui";
import { Falla, Vacio } from "./ui/vacio";
import { EsqueletoDetalle, EsperaLarga } from "./ui/esqueleto";
import { Icono } from "./ui/icono";
import { Interruptor } from "./ui/campo";
import { MenuAcciones, type ItemMenu } from "./ui/menu";
import { Segmentado } from "./ui/segmentado";

// ---------------------------------------------------------------------------------------------------------------
/** Fila de la bandeja y de incidencias: punto (solo la excepción), número en tinta secundaria, asunto de 15 px, persona
 *  y área de 13 px, plazo a la derecha con cifras tabulares. Naranja al 75 %; rojo y en negativo al vencer. */
export const FilaIncidencia = component$<{ inc: IncResumen; href: string; activa?: boolean; extra?: boolean }>((p) => {
  const i = p.inc;
  const nivel = nivelSla(i.sla, i.estado);
  const plazo = plazoCorto(i.sla, i.estado);
  const persona = i.persona ? `${i.persona.nombre}${i.persona.area ? " · " + i.persona.area : ""}` : "Sin persona";
  return (
    <li class="fila-inc-li">
      <Link
        href={p.href}
        class={`fila-inc${p.activa ? " activa" : ""}`}
        data-fila=""
        data-inc-id={i.id}
        data-numero={i.numero}
        aria-current={p.activa ? "true" : undefined}
      >
        <span class="fila-inc-punto" aria-hidden="true">
          {nivel === "por_vencer" && <span class="punto punto-naranja" />}
        </span>
        <span class="fila-inc-cuerpo">
          <span class="fila-inc-l1">
            <span class="fila-inc-num">{i.numero}</span>
            <span class="fila-inc-asunto">{i.titulo}</span>
          </span>
          <span class="fila-inc-l2">
            <span class="fila-inc-num fila-inc-num-m">{i.numero} · </span>
            {i.prioridad === "P1" && <span class="fila-inc-p1">P1 · </span>}
            {persona}
            {p.extra && i.tecnico ? ` · ${nombreCorto(i.tecnico.nombre)}` : ""}
          </span>
        </span>
        {p.extra && <span class="fila-inc-estado">{ESTADO_TEXTO[i.estado]}</span>}
        <span class={`fila-inc-plazo plazo-${nivel}`}>
          {nivel === "por_vencer" && <span class="solo-lector">Por vencer: </span>}
          {nivel === "vencida" && <span class="solo-lector">Vencida: </span>}
          {plazo}
        </span>
      </Link>
    </li>
  );
});

// ---------------------------------------------------------------------------------------------------------------
const Globo = component$<{ m: MensajeCaso }>((p) => {
  const m = p.m;
  const clase = m.rol === "usuario" ? "globo-usuario" : m.rol === "tecnico" ? "globo-tecnico" : "globo-asistente";
  const quien = m.rol === "usuario" ? "" : m.rol === "asistente" ? "Asistente" : m.rol === "sistema" ? "Sistema" : m.autor ? nombreCorto(m.autor) : "Técnico";
  return (
    <li class={`globo-fila ${clase}`}>
      <div class={`globo${m.interno ? " globo-interno" : ""}`}>
        {(quien || m.interno) && (
          <span class="globo-quien">
            {quien}
            {m.interno ? " · nota interna" : ""}
          </span>
        )}
        <p class="globo-texto">{m.texto}</p>
        <time class="globo-hora" dateTime={m.ts}>
          {hora(m.ts)}
        </time>
      </div>
    </li>
  );
});

export const Hilo = component$<{ mensajes: MensajeCaso[]; todos: boolean }>((p) => {
  const lista = p.todos ? p.mensajes : p.mensajes.slice(-6);
  return (
    <ol class="hilo" aria-label="Conversación">
      {lista.map((m, i) => (
        <>
          {(i === 0 || !mismoDia(lista[i - 1].ts, m.ts)) && (
            <li class="hilo-dia" key={`d${m.id}`} aria-hidden="true">
              {diaHilo(m.ts)}
            </li>
          )}
          <Globo key={m.id} m={m} />
        </>
      ))}
    </ol>
  );
});

// ---------------------------------------------------------------------------------------------------------------
const PRIORIDADES = [
  { valor: "P1", titulo: "P1 · Crítica", detalle: "Afecta a toda la organización o a una sede" },
  { valor: "P2", titulo: "P2 · Alta", detalle: "Afecta a un área o bloquea el trabajo de una persona" },
  { valor: "P3", titulo: "P3 · Media", detalle: "Hay una alternativa, pero molesta" },
  { valor: "P4", titulo: "P4 · Baja", detalle: "Puede esperar" },
];

interface DetalleProps {
  id: number;
  modo: "panel" | "hoja" | "pagina";
  onCerrar$?: QRL<() => void>;
}

/** Detalle de una incidencia (DISENO §03): arriba lo que identifica y lo que apura; resumen del asistente; hilo con
 *  globos neutros; Responder con sugerencia editable; «Más» con historial, clasificación, memoria, artículos y Jev.
 *  Una sola acción principal: Enviar. Resolver, Escalar y Reasignar van en el menú ···. */
export const DetalleIncidencia = component$<DetalleProps>((p) => {
  const ui = useContext(UiCtx);
  const dialog = useDialog();
  const { r, recargar, refrescar } = useRecurso<IncDetalle>(`/api/incidencias/${p.id}`);

  const hiloAbierto = useSignal(true);
  const verTodo = useSignal(false);
  const masAbierto = useSignal(false);
  const tituloCompleto = useSignal(false);
  const pestana = useSignal("historial");
  const texto = useSignal("");
  const interna = useSignal(false);
  const sugeridoActivo = useSignal(false);
  const sugeridoOriginal = useSignal("");
  const enviando = useSignal(false);
  const iniciado = useSignal(false);
  const campo = useSignal<HTMLTextAreaElement>();

  // Al llegar los datos: el borrador guardado manda; si no hay, la sugerencia del asistente.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const estado = track(() => r.estado);
      if (estado !== "ok" || iniciado.value || !r.datos) return;
      iniciado.value = true;
      const b = leerBorrador(String(p.id));
      if (b) {
        texto.value = b;
      } else if (r.datos.sugerencia) {
        texto.value = r.datos.sugerencia.texto;
        sugeridoOriginal.value = r.datos.sugerencia.texto;
        sugeridoActivo.value = true;
      }
    },
    { strategy: "document-ready" },
  );

  const enfocar = $(() => {
    campo.value?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    campo.value?.focus();
  });

  const accion = $(async (cuerpo: Record<string, unknown>, aviso: string) => {
    try {
      await api(`/api/incidencias/${p.id}/acciones`, { method: "POST", json: cuerpo });
      toast(aviso, "ok");
      await refrescar();
      ui.tick++;
      return true;
    } catch (e) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudo completar la acción", texto: `${mensajeError(e)} No se perdió nada de lo que escribiste.` });
      return false;
    }
  });

  const enviar = $(async () => {
    const t = texto.value.trim();
    if (!t || enviando.value || !r.datos) return;
    enviando.value = true;
    try {
      await api(`/api/incidencias/${p.id}/acciones`, { method: "POST", json: { accion: interna.value ? "comentario_interno" : "responder", texto: t, interno: interna.value } });
      const canal = CANAL_TEXTO[r.datos.canal] ?? "su canal";
      toast(interna.value ? "Nota interna guardada." : `Enviado a ${nombreCorto(r.datos.persona?.nombre)} por ${canal}.`, "ok");
      texto.value = "";
      sugeridoActivo.value = false;
      guardarBorrador(String(p.id), "");
      await refrescar();
      ui.tick++;
    } catch (e) {
      toast(`No se pudo enviar. ${mensajeError(e)} Tu texto sigue aquí.`, "error");
    } finally {
      enviando.value = false;
    }
  });

  const alMenu = $(async (v: string) => {
    const d = r.datos;
    if (!d) return;
    if (v === "resolver") {
      const nota = await dialog.prompt({ titulo: `Resolver ${d.numero}`, texto: "La persona recibirá el aviso de que quedó resuelta y podrá confirmarlo.", label: "Qué se hizo (opcional)", largo: true, ok: "Resolver" });
      if (nota !== null) await accion({ accion: "resolver", nota }, `${d.numero} resuelta.`);
    } else if (v === "reabrir") {
      if (await dialog.confirm({ titulo: `¿Reabrir ${d.numero}?`, texto: "El plazo vuelve a correr desde ahora.", ok: "Reabrir" })) await accion({ accion: "reabrir" }, `${d.numero} reabierta.`);
    } else if (v === "cerrar") {
      if (await dialog.confirm({ titulo: `¿Cerrar ${d.numero}?`, texto: "Una incidencia cerrada ya no admite respuestas. Se puede reabrir desde el menú.", peligro: true, ok: "Cerrar incidencia" })) await accion({ accion: "cerrar" }, `${d.numero} cerrada.`);
    } else if (v === "escalar") {
      const motivo = await dialog.prompt({ titulo: `Escalar ${d.numero}`, texto: "Pasa al siguiente nivel con lo que ya se probó.", label: "Motivo", requerido: true, largo: true, ok: "Escalar" });
      if (motivo) await accion({ accion: "escalar", motivo }, `${d.numero} escalada.`);
    } else if (v === "asignarme") {
      await accion({ accion: "asignar", tecnico_id: ui.usuario?.tecnico_id }, `${d.numero} asignada a ti.`);
    } else if (v === "reasignar") {
      try {
        const l = await api<Lista<Tecnico>>("/api/tecnicos?por_pagina=100");
        const orden = l.items.filter((t) => t.estado !== "inactivo").sort((a, b) => Number(a.estado === "ausente") - Number(b.estado === "ausente") || a.carga / a.capacidad - b.carga / b.capacidad);
        const elegido = await dialog.elegir({
          titulo: `Reasignar ${d.numero}`,
          texto: "Ordenados por carga: arriba, quien tiene más espacio.",
          opciones: orden.map((t) => ({ valor: String(t.id), titulo: t.nombre, detalle: `${t.nivel} · ${t.carga} de ${t.capacidad}${t.estado === "ausente" ? " · ausente" : ""}` })),
        });
        if (elegido) await accion({ accion: "asignar", tecnico_id: Number(elegido) }, `${d.numero} reasignada.`);
      } catch (e) {
        toast(mensajeError(e), "error");
      }
    } else if (v === "pausar") {
      const motivo = await dialog.elegir({
        titulo: "Pausar el plazo",
        texto: "El reloj de SLA se detiene hasta que se reanude.",
        opciones: [
          { valor: "espera_usuario", titulo: "Espero a la persona", detalle: "Le pedí un dato o una prueba" },
          { valor: "espera_tercero", titulo: "Espero a un tercero", detalle: "Proveedor, compras u otra área" },
        ],
      });
      if (motivo) await accion({ accion: "pausar", motivo }, "Plazo en pausa.");
    } else if (v === "reanudar") {
      await accion({ accion: "reanudar" }, "El plazo vuelve a correr.");
    } else if (v === "prioridad") {
      const pr = await dialog.elegir({ titulo: "Cambiar la prioridad", texto: `Hoy es ${d.prioridad}. El plazo se recalcula.`, opciones: PRIORIDADES.filter((x) => x.valor !== d.prioridad) });
      if (pr) await accion({ accion: "cambiar_prioridad", prioridad: pr }, `Prioridad ${pr}.`);
    } else if (v === "enlace") {
      const url = `${location.origin}${BASE}/estado/${d.token_publico}`;
      try {
        await navigator.clipboard.writeText(url);
        toast("Enlace de estado copiado.", "ok");
      } catch {
        await dialog.prompt({ titulo: "Enlace de estado", texto: "Cópialo y compártelo con la persona.", valor: url, ok: "Listo" });
      }
    }
  });

  if (r.estado === "cargando" && !r.datos) {
    return (
      <div class={`detalle detalle-${p.modo}`}>
        <EsqueletoDetalle />
        {r.lento && <EsperaLarga texto="Sigue cargando la incidencia… el servidor está tardando más de lo normal." />}
      </div>
    );
  }
  if (r.estado === "error" && !r.datos) {
    const noExiste = r.error.includes("No encontramos");
    return (
      <div class={`detalle detalle-${p.modo}`}>
        {noExiste ? (
          <Vacio titulo="Esta incidencia ya no existe." texto="Puede que se haya eliminado o que el enlace esté mal escrito." accion="Volver a la lista" onAccion$={p.onCerrar$} />
        ) : (
          <Falla titulo="No pudimos abrir esta incidencia." texto={`${r.error} Lo que ves en la lista no cambió.`} sinRed={r.sinRed} onReintentar$={recargar} />
        )}
      </div>
    );
  }
  const d = r.datos!;
  const nivel = nivelSla(d.sla, d.estado);
  const esMia = !!d.tecnico && d.tecnico.id === ui.usuario?.tecnico_id;
  const rol = ui.usuario?.rol;
  const abierta = d.estado !== "resuelta" && d.estado !== "cerrada";
  const pausada = d.estado === "espera_usuario" || d.estado === "espera_tercero";
  const items: ItemMenu[] = [
    abierta ? { valor: "resolver", titulo: "Resolver" } : { valor: "reabrir", titulo: "Reabrir" },
    ...(abierta && !esMia && ui.usuario?.tecnico_id ? [{ valor: "asignarme", titulo: "Asignarme" }] : []),
    ...(abierta && (rol === "supervisor" || rol === "admin" || rol === "gerencia") ? [{ valor: "reasignar", titulo: "Reasignar…" }] : []),
    ...(abierta ? [{ valor: "escalar", titulo: "Escalar…" }] : []),
    ...(abierta ? [pausada ? { valor: "reanudar", titulo: "Reanudar el plazo" } : { valor: "pausar", titulo: "Pausar el plazo…" }] : []),
    ...(abierta ? [{ valor: "prioridad", titulo: "Cambiar prioridad…" }] : []),
    { valor: "enlace", titulo: "Copiar enlace de estado", separador: true },
    ...(d.estado === "resuelta" ? [{ valor: "cerrar", titulo: "Cerrar incidencia", peligro: true }] : []),
  ];
  const mensajes = d.mensajes?.items ?? [];
  const estadoLinea = esMia && (d.estado === "asignada" || d.estado === "en_curso") ? "Asignada a ti" : `${ESTADO_TEXTO[d.estado]}${d.tecnico ? " · " + (esMia ? "a ti" : nombreCorto(d.tecnico.nombre)) : " · sin asignar"}`;
  const editado = sugeridoActivo.value && texto.value !== sugeridoOriginal.value;

  return (
    <article class={`detalle detalle-${p.modo}`} aria-label={`Incidencia ${d.numero}`}>
      <div class="detalle-cuerpo">
        <header class="det-cab">
          <div class="det-sup">
            <span class="det-num">
              {d.numero}
              <span class="det-prio">
                {" "}
                · <span class={d.prioridad === "P1" ? "es-p1" : ""}>{d.prioridad}</span> {PRIORIDAD_TEXTO[d.prioridad].toLowerCase()}
              </span>
            </span>
            <div class="det-acc">
              {abierta && (
                <button type="button" class="boton boton-secundario" onClick$={enfocar}>
                  Responder <Icono n="der" tam={14} />
                </button>
              )}
              <MenuAcciones etiqueta="Más acciones" items={items} onElegir$={alMenu} />
              {p.modo === "panel" && p.onCerrar$ && (
                <button type="button" class="icono-boton" aria-label="Cerrar el detalle" onClick$={p.onCerrar$}>
                  <Icono n="cerrar" />
                </button>
              )}
            </div>
          </div>
          <h2 class={`det-titulo${d.titulo.length > 110 && !tituloCompleto.value ? " recortado" : ""}`}>{d.titulo}</h2>
          {d.titulo.length > 110 && (
            <button type="button" class="boton boton-secundario boton-pequeno det-titulo-mas" aria-expanded={tituloCompleto.value} onClick$={() => (tituloCompleto.value = !tituloCompleto.value)}>
              {tituloCompleto.value ? "Ver menos del asunto" : "Ver el asunto completo"}
            </button>
          )}
          <p class="det-persona">
            {d.persona?.nombre ?? "Sin persona"}
            {d.persona?.area ? ` · ${d.persona.area}` : ""}
            {d.persona?.sede ? ` · ${d.persona.sede}` : ""}
            {d.persona_detalle?.vip ? " · VIP" : ""}
          </p>
          <p class="det-estado">
            <span class={`det-plazo plazo-${nivel}`}>
              {nivel === "por_vencer" && <span class="punto punto-naranja" aria-hidden="true" />}
              {nivel === "ninguno" ? ESTADO_TEXTO[d.estado] : plazoLargo(d.sla, d.estado)}
            </span>
            {nivel !== "ninguno" && <span> · {estadoLinea}</span>}
            {d.reaperturas > 0 && <span> · reabierta {d.reaperturas === 1 ? "una vez" : `${d.reaperturas} veces`}</span>}
          </p>
        </header>

        <section class="det-sec" aria-labelledby={`res-${d.id}`}>
          <h3 class="etiqueta-sec" id={`res-${d.id}`}>
            Resumen del asistente
          </h3>
          <p class="det-resumen">{d.resumen || "El asistente no dejó un resumen. Lee la conversación para ver qué pasó."}</p>
        </section>

        <section class="det-sec" aria-labelledby={`con-${d.id}`}>
          <h3 class="etiqueta-sec">
            <button type="button" id={`con-${d.id}`} class="etiqueta-boton" aria-expanded={hiloAbierto.value} onClick$={() => (hiloAbierto.value = !hiloAbierto.value)}>
              Conversación
              <span class="etiqueta-cuenta"> · {d.mensajes?.total ?? mensajes.length}</span>
              <Icono n={hiloAbierto.value ? "abajo" : "der"} tam={14} />
            </button>
          </h3>
          {hiloAbierto.value &&
            (mensajes.length ? (
              <>
                <Hilo mensajes={mensajes} todos={verTodo.value} />
                {mensajes.length > 6 && (
                  <button type="button" class="boton boton-secundario boton-pequeno" onClick$={() => (verTodo.value = !verTodo.value)}>
                    {verTodo.value ? "Ver solo los últimos 6" : `Ver todo (${numero(mensajes.length)})`}
                  </button>
                )}
              </>
            ) : (
              <p class="det-vacio">Todavía no hay mensajes en esta incidencia. Escribe el primero abajo.</p>
            ))}
        </section>

        <section class="det-sec">
          <h3 class="etiqueta-sec">
            <button type="button" class="etiqueta-boton" aria-expanded={masAbierto.value} aria-controls={`mas-${d.id}`} onClick$={() => (masAbierto.value = !masAbierto.value)}>
              Más <Icono n={masAbierto.value ? "abajo" : "der"} tam={14} />
              <span class="etiqueta-ayuda"> Historial · Clasificación · Memoria · Artículos · Jev local</span>
            </button>
          </h3>
          {masAbierto.value && (
            <div class="det-mas" id={`mas-${d.id}`}>
              <Segmentado
                tabs
                etiqueta="Detalle técnico"
                valor={pestana.value}
                onCambio$={(v) => (pestana.value = v)}
                opciones={[
                  { valor: "historial", titulo: "Historial" },
                  { valor: "clasificacion", titulo: "Clasificación" },
                  { valor: "memoria", titulo: "Memoria" },
                  { valor: "articulos", titulo: "Artículos" },
                  { valor: "jev", titulo: "Jev local" },
                ]}
              />
              <div class="det-mas-cuerpo" role="tabpanel">
                {pestana.value === "historial" && (
                  <ol class="eventos">
                    {(d.eventos ?? []).map((e) => (
                      <li class="evento" key={e.id}>
                        <time class="evento-hora" dateTime={e.ts}>
                          {fechaHora(e.ts)}
                        </time>
                        <span class="evento-texto">{textoEvento(e)}</span>
                      </li>
                    ))}
                  </ol>
                )}
                {pestana.value === "clasificacion" &&
                  (d.clasificacion ? (
                    <dl class="datos">
                      <div>
                        <dt>Intención</dt>
                        <dd>
                          {INTENCION_TEXTO[d.clasificacion.intencion] ?? d.clasificacion.intencion}
                          <span class="dato-sec"> · {confianzaPct(d.clasificacion.confianza)} de confianza</span>
                        </dd>
                      </div>
                      <div>
                        <dt>Categoría</dt>
                        <dd>
                          {CATEGORIA_TEXTO[d.clasificacion.categoria] ?? d.clasificacion.categoria}
                          <span class="dato-sec"> · {confianzaPct(d.clasificacion.categoria_confianza)}</span>
                        </dd>
                      </div>
                      <div>
                        <dt>Impacto</dt>
                        <dd>{IMPACTO_TEXTO[d.impacto]}</dd>
                      </div>
                      <div>
                        <dt>Urgencia</dt>
                        <dd>{URGENCIA_TEXTO[d.urgencia]}</dd>
                      </div>
                      <div>
                        <dt>Prioridad</dt>
                        <dd>
                          {d.prioridad} · {PRIORIDAD_TEXTO[d.prioridad]}
                          <span class="dato-sec"> · la calcula la matriz, no el asistente</span>
                        </dd>
                      </div>
                    </dl>
                  ) : (
                    <p class="det-vacio">El asistente no clasificó este caso.</p>
                  ))}
                {pestana.value === "memoria" &&
                  (filasFicha(d.memoria).length ? (
                    <dl class="datos">
                      {filasFicha(d.memoria).map((f) => (
                        <div key={f.clave}>
                          <dt>{f.etiqueta}</dt>
                          <dd>{f.valor}</dd>
                        </div>
                      ))}
                    </dl>
                  ) : (
                    <p class="det-vacio">La ficha del caso está vacía: la persona no dio datos antes de abrir la incidencia.</p>
                  ))}
                {pestana.value === "articulos" &&
                  ((d.articulos ?? []).length ? (
                    <ul class="lista-simple">
                      {(d.articulos ?? []).map((a) => (
                        <li key={a.clave}>
                          <Link href={`${BASE}/asistente/conocimiento`} class="enlace-fila">
                            <span class="dato-sec">{a.clave}</span> {a.titulo}
                            {a.resultado && <span class="dato-sec"> · {a.resultado === "resolvio" ? "resolvió" : a.resultado === "sigue_igual" ? "no resolvió" : "sin respuesta"}</span>}
                          </Link>
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p class="det-vacio">El asistente no usó artículos en este caso.</p>
                  ))}
                {pestana.value === "jev" &&
                  ((d.veredictos ?? []).length ? (
                    <ul class="lista-simple">
                      {(d.veredictos ?? []).map((v, i) => (
                        <li key={i} class="veredicto">
                          <span>{typeof v.veredicto === "string" && v.veredicto ? v.veredicto.replace(/_/g, " ") : "Sin veredicto"}</span>
                          <span class="dato-sec">
                            {" "}
                            · {v.tipo} · {confianzaPct(v.confianza)} · modo {v.modo}
                          </span>
                          {v.detalle && <span class="veredicto-detalle">{v.detalle}</span>}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p class="det-vacio">Jev local no emitió veredictos para este caso.</p>
                  ))}
              </div>
            </div>
          )}
        </section>
      </div>

      {abierta ? (
        <form
          class={`compositor${interna.value ? " es-interna" : ""}`}
          preventdefault:submit
          onSubmit$={enviar}
          aria-label="Responder"
        >
          <label class="solo-lector" for={`resp-${d.id}`}>
            {interna.value ? "Nota interna" : `Respuesta para ${d.persona?.nombre ?? "la persona"}`}
          </label>
          <textarea
            id={`resp-${d.id}`}
            ref={campo}
            rows={3}
            placeholder={interna.value ? "Nota interna: solo la ve el equipo" : `Responder a ${nombreCorto(d.persona?.nombre)}…`}
            value={texto.value}
            onInput$={(_, el) => {
              texto.value = el.value;
              guardarBorrador(String(p.id), el.value);
            }}
            onKeyDown$={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) enviar();
            }}
          />
          <div class="compositor-pie">
            <span class="compositor-sugerido" title={d.sugerencia ? `Confianza del asistente: ${Math.round(d.sugerencia.confianza * 100)} %` : undefined}>
              {sugeridoActivo.value && !interna.value && (editado ? "Sugerido · editado" : "Sugerido")}
            </span>
            <label class="compositor-interna">
              <Interruptor etiqueta="Nota interna" activo={interna.value} onCambio$={(v) => (interna.value = v)} />
              <span>Interna</span>
            </label>
            <button type="submit" class="boton boton-principal" disabled={!texto.value.trim() || enviando.value} aria-busy={enviando.value ? "true" : undefined}>
              {interna.value ? "Guardar nota" : "Enviar"}
            </button>
          </div>
        </form>
      ) : (
        <div class="compositor compositor-cerrada">
          <p class="det-vacio">Esta incidencia está {ESTADO_TEXTO[d.estado].toLowerCase()}. Para escribir, reábrela desde el menú ···.</p>
        </div>
      )}
    </article>
  );
});

