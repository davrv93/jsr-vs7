import { useSignal, useVisibleTask$ } from "@builder.io/qwik";
import { useLocation } from "@builder.io/qwik-city";
import { u } from "./base";

/** Valor de un parámetro de la URL (?inc=142). En un sitio estático la ubicación que Qwik serializó no trae la query,
 *  así que la primera lectura sale de window.location; después, de cada navegación de Qwik City. Cadena vacía = no hay. */
export function useParam(nombre: string) {
  const loc = useLocation();
  const v = useSignal("");
  const primera = useSignal(true);
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const search = track(() => loc.url.search);
      if (primera.value) {
        primera.value = false;
        v.value = new URLSearchParams(location.search).get(nombre) ?? "";
      } else {
        v.value = new URLSearchParams(search).get(nombre) ?? "";
      }
    },
    { strategy: "document-ready" },
  );
  return v;
}

type Navegar = (ruta: string, opts?: { replaceState?: boolean; scroll?: boolean }) => Promise<void>;

/** Navega a una ruta de la consola con su query. En un sitio estático, Qwik City pierde el ?query cuando el salto cambia
 *  de pantalla (el q-data.json de cada página no lo trae); dentro de la misma pantalla sí lo conserva. Por eso, si cambia
 *  la pantalla, se navega en dos tiempos: primero a la ruta y luego a la ruta con su query, sin dejar una entrada de más
 *  en el historial. */
export async function irA(nav: Navegar, destino: string): Promise<void> {
  const [ruta, query] = destino.split("?");
  const rutaCompleta = u(ruta);
  const actual = location.pathname.replace(/\/+$/, "") || "/";
  const destinoPath = rutaCompleta.replace(/\/+$/, "") || "/";
  if (!query) {
    await nav(rutaCompleta);
    return;
  }
  if (actual === destinoPath) {
    await nav(u(destino));
    return;
  }
  await nav(rutaCompleta);
  await nav(u(destino), { replaceState: true });
}
