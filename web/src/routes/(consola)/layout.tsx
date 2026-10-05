import { component$, Slot, useContext, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import { useLocation, useNavigate } from "@builder.io/qwik-city";
import { BarraInferior, BarraSinRed, BarraSuperior, Lateral } from "~/components/armazon";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Buscador } from "~/components/ui/buscador";
import { Vacio } from "~/components/ui/vacio";
import { api } from "~/lib/api";
import { getToken, getUsuario, type Usuario } from "~/lib/auth";
import { apiUrl, BASE, u } from "~/lib/base";
import { ROL_TEXTO } from "~/lib/format";
import { inicioPara, puede, rutaDe } from "~/lib/rutas";
import type { Bandeja } from "~/lib/tipos";
import { UiCtx } from "~/lib/ui";

const sinBase = (pathname: string) => (BASE && pathname.startsWith(BASE) ? pathname.slice(BASE.length) : pathname) || "/";

/** Armazón de la consola (DISENO §1): lateral, barra superior, barra inferior en móvil, buscador ⌘K y guardas por rol.
 *  Comprueba la sesión; sin token manda al inicio de sesión. Abre el flujo de eventos en vivo (SSE). */
export default component$(() => {
  const ui = useContext(UiCtx);
  const loc = useLocation();
  const nav = useNavigate();
  const path = sinBase(loc.url.pathname);
  const ruta = rutaDe(path);
  const principal = useSignal<HTMLElement>();
  const ultimaRuta = useSignal("");

  // 1 · Sesión
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    () => {
      const token = getToken();
      const usuario = getUsuario();
      if (!token || !usuario) {
        const volver = sinBase(location.pathname) + location.search;
        nav(u(`/login${volver && volver !== "/" ? `?volver=${encodeURIComponent(volver)}` : ""}`));
        return;
      }
      ui.usuario = usuario;
      ui.listo = true;
      if (path === "/" || path === "") nav(u(inicioPara(usuario.rol)), { replaceState: true });
      // Confirma con el servidor (un rol cambiado o un token vencido se nota aquí).
      api<Usuario>("/api/yo")
        .then((yo) => {
          if (yo && yo.rol) ui.usuario = { ...usuario, ...yo };
        })
        .catch(() => undefined);
    },
    { strategy: "document-ready" },
  );

  // 2 · Eventos en vivo (SSE por fetch, para poder mandar Authorization). Cada evento sube `ui.tick`.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track, cleanup }) => {
      if (!track(() => ui.listo)) return;
      let parar = false;
      let ctrl: AbortController | null = null;
      const bucle = async () => {
        let espera = 1000;
        while (!parar) {
          try {
            ctrl = new AbortController();
            const res = await fetch(apiUrl("/api/eventos"), {
              headers: { Authorization: `Bearer ${getToken() ?? ""}`, Accept: "text/event-stream" },
              signal: ctrl.signal,
            });
            if (res.status === 401 || res.status === 403) return;
            if (!res.ok || !res.body) throw new Error("sin flujo");
            espera = 1000;
            const lector = res.body.getReader();
            const dec = new TextDecoder();
            let buf = "";
            for (;;) {
              const { value, done } = await lector.read();
              if (done) break;
              buf += dec.decode(value, { stream: true });
              let i: number;
              while ((i = buf.indexOf("\n\n")) >= 0) {
                const bloque = buf.slice(0, i);
                buf = buf.slice(i + 2);
                if (/^(event|data):/m.test(bloque)) ui.tick++;
              }
            }
          } catch {
            if (parar) return;
          }
          await new Promise((r) => setTimeout(r, espera));
          espera = Math.min(espera * 2, 15000);
        }
      };
      bucle();
      cleanup(() => {
        parar = true;
        ctrl?.abort();
      });
    },
    { strategy: "document-ready" },
  );

  // 3 · Contador de la Bandeja en el lateral (la propia Bandeja lo actualiza con su carga).
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    async ({ track }) => {
      const listo = track(() => ui.listo);
      track(() => ui.tick);
      const enBandeja = sinBase(location.pathname).startsWith("/bandeja");
      if (!listo || enBandeja || !puede(ui.usuario?.rol, ["tecnico", "supervisor", "gerencia"])) return;
      try {
        const b = await api<Bandeja>("/api/bandeja");
        ui.contador = b.contador;
      } catch {
        /* el aviso de conexión ya lo muestra la barra */
      }
    },
    { strategy: "document-ready" },
  );

  // 4 · ⌘K / Ctrl+K abre el buscador
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ cleanup }) => {
      const tecla = (e: KeyboardEvent) => {
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
          e.preventDefault();
          ui.buscadorAbierto = !ui.buscadorAbierto;
        }
      };
      window.addEventListener("keydown", tecla);
      cleanup(() => window.removeEventListener("keydown", tecla));
    },
    { strategy: "document-ready" },
  );

  // 5 · En una navegación (no en la primera carga) el foco pasa al contenido, para teclado y lector de pantalla.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const p = track(() => loc.url.pathname);
      const antes = ultimaRuta.value;
      ultimaRuta.value = p;
      // No en la primera carga, ni cuando solo cambia el ?query (abrir un detalle no debe quitarle el foco a la fila).
      if (!antes || antes === p) return;
      principal.value?.focus({ preventScroll: true });
    },
    { strategy: "document-ready" },
  );

  const rol = ui.usuario?.rol;
  const permitido = !ruta || puede(rol, ruta.roles);

  return (
    <div class="app" data-vp={ui.vp}>
      <a href="#contenido" class="saltar">
        Saltar al contenido
      </a>
      <Lateral />
      <div class={`app-col${ui.conectado ? "" : " sin-conexion"}`}>
        <BarraSuperior />
        <BarraSinRed />
        <main id="contenido" class="contenido" tabIndex={-1} ref={principal}>
          {!ui.listo ? (
            <div class="pagina">
              <EsqueletoFilas n={7} />
            </div>
          ) : permitido ? (
            <Slot />
          ) : (
            <div class="pagina">
              <Vacio
                grande
                titulo="Esta sección no está disponible para tu rol."
                texto={`Entraste como ${ROL_TEXTO[rol ?? "tecnico"].toLowerCase()}. Pide acceso al administrador si lo necesitas.`}
                accion="Ir a mi inicio"
                href={u(inicioPara(rol))}
              />
            </div>
          )}
        </main>
      </div>
      <BarraInferior />
      {ui.listo && <Buscador />}
    </div>
  );
});
