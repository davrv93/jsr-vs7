import type { BrowserContext, Page } from "@playwright/test";

export const CLAVE = "jsr123";
/** Origen bajo prueba: BASE_URL (p. ej. el contenedor con nginx) o el mock que levanta playwright.config.ts. */
export const BASE = process.env.BASE_URL ?? `http://127.0.0.1:${process.env.TEST_PORT ?? 5610}`;

/** Entra por la API y deja la sesión en sessionStorage antes de que cargue la página (como hace la consola). */
export async function conSesion(context: BrowserContext, base: string, email = "admin@jsr.test") {
  const r = await fetch(`${base}/api/auth/login`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, clave: CLAVE }) });
  const { token, usuario } = (await r.json()) as { token: string; usuario: unknown };
  await context.addInitScript(
    ([t, u]) => {
      sessionStorage.setItem("jsr_token", t as string);
      sessionStorage.setItem("jsr_usuario", JSON.stringify(u));
    },
    [token, usuario],
  );
}

/** Errores de consola y de página: una prueba no debería producir ninguno. */
export function vigilarConsola(page: Page): string[] {
  const errores: string[] = [];
  page.on("console", (m) => {
    if (m.type() === "error" && !/fonts\.g|favicon/.test(m.text() + (m.location().url ?? ""))) errores.push(`consola: ${m.text()}`);
  });
  page.on("pageerror", (e) => errores.push(`página: ${e.message}`));
  return errores;
}

export async function ponerFalla(base: string, ruta: string, estado = 500, veces = 1) {
  // Los endpoints de control son del mock, no de nginx: MOCK_URL cuando se prueba contra un contenedor.
  await fetch(`${process.env.MOCK_URL ?? base}/mock/falla`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ruta, estado, veces }) });
}
