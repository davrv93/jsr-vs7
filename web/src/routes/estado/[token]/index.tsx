import { $, component$, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import type { DocumentHead, StaticGenerateHandler } from "@builder.io/qwik-city";
import { Campo } from "~/components/ui/campo";
import { api, ApiError, mensajeError } from "~/lib/api";
import { ESTADO_TEXTO, momentoFuturo, nombreCorto, PRIORIDAD_TEXTO, relativo } from "~/lib/format";
import type { EstadoPublico } from "~/lib/tipos";

// Sitio estático: la página se genera una sola vez con un token de relleno y nginx reescribe /estado/<token> a ella.
// El token real se lee de la URL en el navegador.
export const onStaticGenerate: StaticGenerateHandler = () => ({ params: [{ token: "_" }] });

const tokenDeLaUrl = (): string => {
  const partes = location.pathname.split("/").filter(Boolean);
  const i = partes.lastIndexOf("estado");
  return i >= 0 ? (partes[i + 1] ?? "") : "";
};

/** 16 · Estado público. ¿Cómo va mi incidencia? Móvil, sin sesión, por enlace con token. Una acción: Responder. */
export default component$(() => {
  const st = useStore<{ estado: "cargando" | "ok" | "error" | "sin_enlace"; datos: EstadoPublico | null; error: string; sinRed: boolean }>({ estado: "cargando", datos: null, error: "", sinRed: false });
  const token = useSignal("");
  const respondiendo = useSignal(false);
  const texto = useSignal("");
  const errorTexto = useSignal("");
  const enviando = useSignal(false);
  const enviado = useSignal(false);

  const cargar = $(async (silencioso: boolean) => {
    if (!token.value) return;
    if (!silencioso) st.estado = "cargando";
    try {
      st.datos = await api<EstadoPublico>(`/api/estado/${encodeURIComponent(token.value)}`, { publico: true });
      st.estado = "ok";
    } catch (e) {
      if (silencioso && st.datos) return;
      st.error = mensajeError(e);
      st.sinRed = e instanceof ApiError && e.red;
      st.estado = e instanceof ApiError && e.status === 404 ? "sin_enlace" : "error";
    }
  });

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ cleanup }) => {
      token.value = tokenDeLaUrl();
      if (!token.value || token.value === "_") {
        st.estado = "sin_enlace";
        st.error = "Falta el enlace de tu incidencia. Usa el que te llegó por WhatsApp.";
        return;
      }
      cargar(false);
      const id = setInterval(() => cargar(true), 60_000);
      cleanup(() => clearInterval(id));
    },
    { strategy: "document-ready" },
  );

  const enviar = $(async () => {
    errorTexto.value = "";
    const t = texto.value.trim();
    if (!t) {
      errorTexto.value = "Escribe tu respuesta antes de enviarla.";
      return;
    }
    if (t.length > 1000) {
      errorTexto.value = "Tu respuesta es muy larga. Resúmela en menos de 1000 caracteres.";
      return;
    }
    enviando.value = true;
    try {
      await api(`/api/estado/${encodeURIComponent(token.value)}/responder`, { method: "POST", json: { texto: t }, publico: true });
      enviado.value = true;
      respondiendo.value = false;
      texto.value = "";
      await cargar(true);
    } catch (e) {
      errorTexto.value = `${mensajeError(e)} Tu texto sigue aquí.`;
    } finally {
      enviando.value = false;
    }
  });

  const d = st.datos;
  return (
    <main class="estado-pub">
      <header class="estado-pub-marca">
        <span class="lateral-sello" aria-hidden="true">
          j
        </span>
        <span>Mesa de ayuda</span>
      </header>

      {st.estado === "cargando" && (
        <div class="esq esq-detalle" role="status" aria-busy="true" aria-label="Cargando el estado">
          <span class="esq-linea esq-etiqueta" />
          <span class="esq-linea esq-titulo" />
          <span class="esq-linea" style={{ width: "50%" }} />
        </div>
      )}

      {st.estado === "sin_enlace" && (
        <div class="vacio" role="alert">
          <p class="vacio-titulo">No encontramos esta incidencia.</p>
          <p class="vacio-texto">{st.error} Si el enlace es antiguo, escribe «¿Cómo va mi ticket?» al asistente por WhatsApp y te mandará uno nuevo.</p>
        </div>
      )}

      {st.estado === "error" && (
        <div class="vacio falla" role="alert">
          <p class="vacio-titulo">{st.sinRed ? "No hay conexión." : "No pudimos cargar el estado."}</p>
          <p class="vacio-texto">{st.error} Tu incidencia sigue su curso; esto solo afecta a esta página.</p>
          <button type="button" class="boton boton-secundario" onClick$={() => cargar(false)}>
            Reintentar
          </button>
        </div>
      )}

      {d && st.estado === "ok" && (
        <>
          <p class="estado-pub-num">
            {d.numero} · {d.prioridad} {PRIORIDAD_TEXTO[d.prioridad].toLowerCase()}
          </p>
          <h1 class="estado-pub-estado">{d.estado_texto}</h1>
          <p class="estado-pub-titulo">{d.titulo}</p>

          <dl class="estado-pub-datos">
            <div>
              <dt>La atiende</dt>
              <dd>{d.tecnico ? nombreCorto(d.tecnico) : "Todavía no tiene responsable"}</dd>
            </div>
            <div>
              <dt>Estado</dt>
              <dd>{ESTADO_TEXTO[d.estado] ?? d.estado}</dd>
            </div>
            {d.vence_resolucion_en && d.estado !== "resuelta" && d.estado !== "cerrada" && (
              <div>
                <dt>Plazo estimado</dt>
                <dd>antes de {momentoFuturo(d.vence_resolucion_en)}</dd>
              </div>
            )}
            <div>
              <dt>Abierta</dt>
              <dd>{relativo(d.creada_en)}</dd>
            </div>
          </dl>

          {d.ultimo_mensaje_tecnico ? (
            <section class="estado-pub-mensaje" aria-labelledby="ult-msg">
              <h2 id="ult-msg" class="etiqueta-sec">
                Último mensaje de {nombreCorto(d.ultimo_mensaje_tecnico.autor)} · {relativo(d.ultimo_mensaje_tecnico.ts)}
              </h2>
              <p>{d.ultimo_mensaje_tecnico.texto}</p>
            </section>
          ) : (
            <p class="det-vacio">Todavía no hay mensajes del técnico. Te avisaremos por WhatsApp cuando haya novedades.</p>
          )}

          {enviado.value && !respondiendo.value && (
            <p class="estado-pub-ok" role="status">
              Enviamos tu respuesta. El técnico la verá en cuanto abra la incidencia.
            </p>
          )}

          {d.puede_responder ? (
            respondiendo.value ? (
              <form class="estado-pub-form" preventdefault:submit onSubmit$={enviar} noValidate>
                <Campo etiqueta="Tu respuesta" nombre="resp-publica" filas={4} valor={texto.value} onValor$={(v) => (texto.value = v)} error={errorTexto.value} marcador="Cuéntale al técnico lo que probaste o lo que cambió" />
                <div class="estado-pub-botones">
                  <button type="button" class="boton boton-secundario" onClick$={() => (respondiendo.value = false)}>
                    Cancelar
                  </button>
                  <button type="submit" class="boton boton-principal" disabled={enviando.value} aria-busy={enviando.value ? "true" : undefined}>
                    Enviar
                  </button>
                </div>
              </form>
            ) : (
              <button type="button" class="boton boton-principal boton-bloque estado-pub-responder" onClick$={() => (respondiendo.value = true)}>
                Responder
              </button>
            )
          ) : (
            <p class="det-vacio">Esta incidencia está cerrada. Si el problema volvió, escribe al asistente por WhatsApp.</p>
          )}
        </>
      )}
    </main>
  );
});

export const head: DocumentHead = { title: "Estado de tu incidencia · jsrbot" };
