import { component$, Slot, useContextProvider, useStore, useVisibleTask$ } from "@builder.io/qwik";
import { Anuncios } from "~/components/ui/anuncios";
import { leerPref } from "~/lib/auth";
import { AnunciosCtx, UiCtx, type AnunciosStore, type UiStore } from "~/lib/ui";

/** Raíz de todas las rutas (incluidas las públicas: inicio de sesión, estado y chat de prueba). Reparte el estado
 *  global de la interfaz, monta los avisos y diálogos, y vigila el tamaño de ventana, el tema y la conexión. */
export default component$(() => {
  const ui = useStore<UiStore>({
    usuario: null,
    listo: false,
    vp: "ancho",
    plegado: false,
    tema: "sistema",
    conectado: true,
    tick: 0,
    contador: 0,
    buscadorAbierto: false,
    barra: { atras: "", accion: "", accionDeshabilitada: false },
    evAccion: 0,
    evAtras: 0,
    menuMasAbierto: false,
  });
  const anuncios = useStore<AnunciosStore>({ avisos: [], dialogos: [] });
  useContextProvider(UiCtx, ui);
  useContextProvider(AnunciosCtx, anuncios);

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ cleanup }) => {
      // Tema y lateral guardados.
      const t = leerPref("tema");
      ui.tema = t === "claro" || t === "oscuro" ? t : "sistema";
      ui.plegado = leerPref("plegado") === "1";

      // Tamaño de ventana: móvil < 768, medio 768–1199, ancho ≥ 1200.
      const mMovil = window.matchMedia("(max-width: 767.98px)");
      const mAncho = window.matchMedia("(min-width: 1200px)");
      const vp = () => {
        ui.vp = mMovil.matches ? "movil" : mAncho.matches ? "ancho" : "medio";
      };
      vp();
      mMovil.addEventListener("change", vp);
      mAncho.addEventListener("change", vp);

      // Conexión: la API avisa con «jsr:red» y el navegador con online/offline.
      const red = (e: Event) => {
        ui.conectado = (e as CustomEvent<{ ok: boolean }>).detail.ok;
      };
      const arriba = () => (ui.conectado = true);
      const abajo = () => (ui.conectado = false);
      window.addEventListener("jsr:red", red);
      window.addEventListener("online", arriba);
      window.addEventListener("offline", abajo);
      if (!navigator.onLine) ui.conectado = false;
      cleanup(() => {
        mMovil.removeEventListener("change", vp);
        mAncho.removeEventListener("change", vp);
        window.removeEventListener("jsr:red", red);
        window.removeEventListener("online", arriba);
        window.removeEventListener("offline", abajo);
      });
    },
    { strategy: "document-ready" },
  );

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const t = track(() => ui.tema);
      if (t === "sistema") document.documentElement.removeAttribute("data-tema");
      else document.documentElement.setAttribute("data-tema", t);
    },
    { strategy: "document-ready" },
  );

  return (
    <>
      <Slot />
      <Anuncios />
    </>
  );
});
