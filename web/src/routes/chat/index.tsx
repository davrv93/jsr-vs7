import { $, component$, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { PanelAnalisis } from "~/components/analisis";
import { Hoja } from "~/components/ui/hoja";
import { Icono } from "~/components/ui/icono";
import { MenuAcciones } from "~/components/ui/menu";
import { api } from "~/lib/api";
import { hora } from "~/lib/format";
import { PATRON_CSS } from "~/lib/patron";
import type { RespuestaChat } from "~/lib/tipos";
import { toast } from "~/lib/ui";
import { hexAleatorio, pausa } from "~/lib/util";

interface Msg {
  id: number;
  rol: "usuario" | "bot";
  texto: string;
  ts: string;
  leido: boolean;
  botones?: string[];
  /** Primer globo de una tanda del mismo autor: lleva cola. */
  cola: boolean;
}

const RAPIDAS = ["No me abre el correo", "La impresora no imprime", "Olvidé mi contraseña", "¿Cómo va mi ticket?", "Necesito acceso a una carpeta", "Ya funcionó, gracias"];
const SALUDO = "Hola, soy el asistente de la mesa de ayuda. Cuéntame qué está pasando y lo revisamos juntos.";
const CLAVE_SESION = "jsr_chat_sesion";

/** *negrita* y _cursiva_ de WhatsApp, sin tocar HTML: devuelve fragmentos para pintar como elementos. */
const formatoWa = (t: string): { k: "n" | "i" | "t"; v: string }[] =>
  t
    .split(/(\*[^*\n]+\*|_[^_\n]+_)/g)
    .filter(Boolean)
    .map((x) => (x.length > 2 && x.startsWith("*") && x.endsWith("*") ? { k: "n" as const, v: x.slice(1, -1) } : x.length > 2 && x.startsWith("_") && x.endsWith("_") ? { k: "i" as const, v: x.slice(1, -1) } : { k: "t" as const, v: x }));

const Checks = component$<{ leido: boolean }>((p) => (
  <svg class={`wa-checks${p.leido ? " leido" : ""}`} width="16" height="11" viewBox="0 0 16 11" role="img" aria-label={p.leido ? "Leído" : "Enviado"}>
    <path d="M11.07.65 5.3 7.9 2.9 5.5l-.9.9 3.3 3.3L12 1.55z" fill="currentColor" />
    <path d="M14.9.65 9.1 7.9l-.8-.8-.9.9 1.7 1.7L15.8 1.55z" fill="currentColor" />
  </svg>
));

const Globo = component$<{ m: Msg }>((p) => {
  const m = p.m;
  return (
    <div class={`wa-fila wa-${m.rol}${m.cola ? " con-cola" : ""}`}>
      <div class="wa-globo">
        <span class="wa-texto">
          {formatoWa(m.texto).map((x, i) => (x.k === "n" ? <b key={i}>{x.v}</b> : x.k === "i" ? <i key={i}>{x.v}</i> : <span key={i}>{x.v}</span>))}
        </span>
        <span class="wa-esp" aria-hidden="true" />
        <span class="wa-meta">
          <time dateTime={m.ts}>{hora(m.ts)}</time>
          {m.rol === "usuario" && <Checks leido={m.leido} />}
        </span>
      </div>
    </div>
  );
});

/** 17 · Chat web de prueba, con la piel de WhatsApp de Baruka (referencias/baruka/DISENO_WHATSAPP.md). ¿Qué contestaría
 *  el asistente? Llama a POST /api/chat-web, el mismo contrato que el canal real. La consola nunca imita WhatsApp: solo esta
 *  pantalla, que existe para ver en la web lo mismo que verá la persona. */
export default component$(() => {
  const st = useStore<{
    msgs: Msg[];
    escribiendo: boolean;
    ocupado: boolean;
    sesion: string;
    analisis: RespuestaChat["analisis"] | null;
    incidencia: string | null;
    rapidas: boolean;
    cajon: boolean;
    texto: string;
  }>({ msgs: [], escribiendo: false, ocupado: false, sesion: "", analisis: null, incidencia: null, rapidas: true, cajon: false, texto: "" });
  const lista = useSignal<HTMLElement>();
  const entrada = useSignal<HTMLInputElement>();
  const lado = useSignal(false);

  const nuevoChat = $(() => {
    st.sesion = "web-" + hexAleatorio(16);
    try {
      sessionStorage.setItem(CLAVE_SESION, st.sesion);
    } catch {
      /* sin almacenamiento */
    }
    st.msgs = [{ id: Date.now(), rol: "bot", texto: SALUDO, ts: new Date().toISOString(), leido: true, cola: true }];
    st.analisis = null;
    st.incidencia = null;
    st.escribiendo = false;
    st.ocupado = false;
    st.texto = "";
  });

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ cleanup }) => {
      let s = "";
      try {
        s = sessionStorage.getItem(CLAVE_SESION) ?? "";
      } catch {
        /* sin almacenamiento */
      }
      nuevoChat();
      if (s) st.sesion = s;
      const m = window.matchMedia("(min-width: 1000px) and (min-height: 561px)");
      const f = () => (lado.value = m.matches);
      f();
      m.addEventListener("change", f);
      cleanup(() => m.removeEventListener("change", f));
    },
    { strategy: "document-ready" },
  );

  // La lista baja sola con cada mensaje nuevo.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      track(() => st.msgs.length);
      track(() => st.escribiendo);
      const el = lista.value;
      if (el) el.scrollTo({ top: el.scrollHeight, behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    },
    { strategy: "document-ready" },
  );

  const enviar = $(async (crudo: string) => {
    const texto = crudo.trim();
    if (!texto || st.ocupado) return;
    st.ocupado = true;
    st.texto = "";
    st.msgs = st.msgs.map((m) => ({ ...m, botones: undefined }));
    const id = Date.now();
    st.msgs.push({ id, rol: "usuario", texto, ts: new Date().toISOString(), leido: false, cola: st.msgs[st.msgs.length - 1]?.rol !== "usuario" });
    setTimeout(() => {
      const m = st.msgs.find((x) => x.id === id);
      if (m) m.leido = true;
    }, 350);
    st.escribiendo = true;
    try {
      const r = await api<RespuestaChat>("/api/chat-web", { method: "POST", json: { sesion: st.sesion, mensaje: texto }, publico: true });
      const partes = r.mensajes?.length ? r.mensajes : (r.respuesta ?? "").split(/\n{2,}/).filter(Boolean);
      for (let i = 0; i < partes.length; i++) {
        if (i > 0) {
          st.escribiendo = true;
          await pausa(Math.min(2200, Math.max(600, partes[i].length * 25)));
        }
        st.escribiendo = false;
        st.msgs.push({ id: Date.now() + i, rol: "bot", texto: partes[i], ts: new Date().toISOString(), leido: true, cola: i === 0 && st.msgs[st.msgs.length - 1]?.rol !== "bot" });
        if (i < partes.length - 1) await pausa(80);
      }
      if (r.botones?.length && st.msgs.length) st.msgs[st.msgs.length - 1].botones = r.botones;
      st.analisis = r.analisis;
      if (r.incidencia) st.incidencia = r.incidencia.numero;
    } catch {
      st.escribiendo = false;
      st.msgs.push({ id: Date.now(), rol: "bot", texto: "Se cortó la conexión. ¿Me lo repites?", ts: new Date().toISOString(), leido: true, cola: st.msgs[st.msgs.length - 1]?.rol !== "bot" });
      toast("No se pudo contactar al asistente. Prueba otra vez.", "error");
    } finally {
      st.escribiendo = false;
      st.ocupado = false;
      entrada.value?.focus({ preventScroll: true });
    }
  });

  const alMenu = $((v: string) => {
    if (v === "nuevo") nuevoChat();
    else if (v === "rapidas") st.rapidas = !st.rapidas;
    else if (v === "analisis") st.cajon = true;
  });

  const ultimoBot = st.msgs[st.msgs.length - 1];
  const botones = ultimoBot?.rol === "bot" ? (ultimoBot.botones ?? []) : [];
  const dosColumnas = botones.length === 2 && botones.every((b) => b.length <= 18);

  return (
    <div class={`wa${lado.value && st.cajon ? " wa-con-lado" : ""}`} data-tema-wa="" style={{ "--wa-patron": PATRON_CSS }}>
      <div class="wa-franja" aria-hidden="true" />
      <section class="wa-ventana" aria-label="Chat de prueba con el asistente">
        <header class="wa-cab">
          <button type="button" class="wa-atras" aria-label="Volver" onClick$={() => history.back()}>
            <Icono n="izq" tam={22} />
          </button>
          <span class="wa-avatar" aria-hidden="true">
            MA
          </span>
          <div class="wa-titulos">
            <h1 class="wa-nombre">Mesa de ayuda</h1>
            <p class="wa-estado" aria-live="polite">
              {st.escribiendo ? "escribiendo…" : "en línea"}
            </p>
          </div>
          <MenuAcciones
            etiqueta="Opciones del chat"
            icono="puntos_v"
            class="wa-menu"
            onElegir$={alMenu}
            items={[
              { valor: "nuevo", titulo: "Nuevo chat" },
              { valor: "rapidas", titulo: st.rapidas ? "Ocultar respuestas rápidas" : "Mostrar respuestas rápidas" },
              { valor: "analisis", titulo: "Análisis del asistente" },
            ]}
          />
        </header>

        <div class="wa-caja">
        <div class="wa-cuerpo" ref={lista} role="log" aria-live="polite" aria-relevant="additions" aria-label="Mensajes">
          <p class="wa-dia">Hoy</p>
          <p class="wa-aviso">Chat de prueba del asistente. Aquí no se envía nada a WhatsApp ni se avisa a nadie.</p>
          {st.msgs.map((m) => (
            <Globo key={m.id} m={m} />
          ))}
          {botones.length > 0 && (
            <div class={`wa-botones${dosColumnas ? " dos" : ""}`}>
              {botones.map((b) => (
                <button key={b} type="button" class="wa-boton" disabled={st.ocupado} onClick$={() => enviar(b)}>
                  {b}
                </button>
              ))}
            </div>
          )}
          {st.escribiendo && (
            <div class="wa-fila wa-bot con-cola" role="status" aria-label="Escribiendo">
              <div class="wa-globo wa-puntos" aria-hidden="true">
                <span />
                <span />
                <span />
              </div>
            </div>
          )}
        </div>
        </div>

        {st.rapidas && (
          <div class="wa-rapidas" role="group" aria-label="Respuestas rápidas de ejemplo">
            {RAPIDAS.map((r) => (
              <button key={r} type="button" class="wa-chip" disabled={st.ocupado} onClick$={() => enviar(r)}>
                {r}
              </button>
            ))}
          </div>
        )}

        <form class="wa-barra" preventdefault:submit onSubmit$={() => enviar(st.texto)}>
          <div class="wa-campo">
            <label class="solo-lector" for="wa-entrada">
              Escribe un mensaje
            </label>
            <input id="wa-entrada" ref={entrada} type="text" autoComplete="off" enterKeyHint="send" placeholder="Escribe un mensaje" value={st.texto} onInput$={(_, el) => (st.texto = el.value)} />
          </div>
          {st.texto.trim() ? (
            <button type="submit" class="wa-enviar" aria-label="Enviar" disabled={st.ocupado}>
              <Icono n="enviar" tam={22} class="wa-avion" />
            </button>
          ) : (
            <button type="button" class="wa-enviar" aria-label="Mensaje de voz (no disponible en la prueba)" onClick$={() => toast("La voz no está disponible en el chat de prueba.")}>
              <Icono n="mic" tam={22} />
            </button>
          )}
        </form>
      </section>

      {st.cajon && lado.value && (
        <aside class="wa-lado" aria-label="Análisis del asistente">
          <header class="wa-lado-cab">
            <h2>Análisis del asistente</h2>
            <button type="button" class="icono-boton" aria-label="Cerrar el análisis" onClick$={() => (st.cajon = false)}>
              <Icono n="cerrar" />
            </button>
          </header>
          <div class="wa-lado-cuerpo">
            <PanelAnalisis a={st.analisis} incidencia={st.incidencia} />
          </div>
        </aside>
      )}
      {st.cajon && !lado.value && (
        <Hoja titulo="Análisis del asistente" subtitulo="Cómo entendió el último mensaje" onCerrar$={() => (st.cajon = false)}>
          <PanelAnalisis a={st.analisis} incidencia={st.incidencia} />
        </Hoja>
      )}
    </div>
  );
});

export const head: DocumentHead = { title: "Chat de prueba · jsrbot" };
