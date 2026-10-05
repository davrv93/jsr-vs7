import { expect, test } from "@playwright/test";
import { BASE, conSesion, ponerFalla, vigilarConsola } from "./util/sesion";


test.describe("02 · Bandeja", () => {
  test.beforeEach(async ({ context }) => {
    await conSesion(context, BASE);
  });

  test("lo primero que dice es lo que vence, y el color solo marca la excepción", async ({ page }) => {
    const errores = vigilarConsola(page);
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/bandeja");
    await expect(page.locator(".bandeja-cifra")).toContainText(/vencid|vence|Nada vence/);
    // Tres grupos, sin tarjetas, en este orden.
    const titulos = await page.locator(".lista-grupo-titulo").allTextContents();
    expect(titulos[0]).toMatch(/^Vencen pronto/);
    expect(titulos.some((t) => /^Mías/.test(t))).toBe(true);
    expect(titulos.some((t) => /^Sin asignar/.test(t))).toBe(true);
    // Vencida: tiempo en negativo (signo menos tipográfico) y en rojo.
    const vencida = page.locator(".fila-inc-plazo.plazo-vencida").first();
    await expect(vencida).toHaveText(/−\d+:\d{2}$/);
    // Por vencer: punto naranja y plazo naranja, nunca las dos señales rojas a la vez.
    await expect(page.locator(".fila-inc .punto-naranja").first()).toBeVisible();
    await expect(page.locator(".fila-inc-plazo.plazo-vencida .punto")).toHaveCount(0);
    expect(errores).toEqual([]);
  });

  test("abrir una incidencia la muestra al lado de la lista sin perder la lista (1280 px)", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/bandeja");
    await page.locator(".fila-inc", { hasText: "Correo no sincroniza en Outlook" }).click();
    await expect(page).toHaveURL(/inc=142/);
    const detalle = page.getByRole("article", { name: "Incidencia INC-000142" });
    await expect(detalle.getByRole("heading", { name: "Correo no sincroniza en Outlook" })).toBeVisible();
    await expect(detalle.getByText("Resumen del asistente")).toBeVisible();
    await expect(page.locator(".fila-inc", { hasText: "INC-000141" })).toBeVisible();
    // Sugerencia del asistente, editable y marcada.
    await expect(detalle.getByText("Sugerido", { exact: true })).toBeVisible();
    await detalle.getByLabel(/Respuesta para/).fill("Gracias, ya lo reviso.");
    await expect(detalle.getByText("Sugerido · editado")).toBeVisible();
  });

  test("teclado como Mail: j y k se mueven, Enter abre, e pide la nota con un diálogo propio", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/bandeja");
    const filas = page.locator(".md-lista [data-fila]");
    await expect(filas.first()).toBeVisible();
    await page.keyboard.press("j");
    await expect(filas.nth(0)).toBeFocused();
    await page.keyboard.press("j");
    await expect(filas.nth(1)).toBeFocused();
    await page.keyboard.press("k");
    await expect(filas.nth(0)).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/inc=\d+/);
    // «e» abre el diálogo de la consola (no window.prompt) y Escape lo cierra devolviendo el foco.
    await filas.nth(0).focus();
    await page.keyboard.press("e");
    const dialogo = page.getByRole("dialog", { name: /^Resolver INC-/ });
    await expect(dialogo).toBeVisible();
    await expect(dialogo.getByLabel(/Qué se hizo/)).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(dialogo).toHaveCount(0);
    await expect(filas.nth(0)).toBeFocused();
  });

  test("asignarme con «a» avisa con un toast y recarga la lista", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/bandeja");
    const sinAsignar = page.locator("#g-sin").locator("xpath=..").locator("[data-fila]").first();
    const numero = await sinAsignar.getAttribute("data-numero");
    await sinAsignar.focus();
    await page.keyboard.press("a");
    await expect(page.getByRole("status").filter({ hasText: `${numero} asignada a ti.` })).toBeVisible();
  });

  test("error: palabras simples, qué no se perdió y Reintentar; nunca un código HTTP solo", async ({ page }) => {
    await ponerFalla(BASE, "/api/bandeja", 500, 1);
    await page.goto("/bandeja");
    const alerta = page.getByRole("alert");
    await expect(alerta).toContainText("No pudimos cargar la bandeja.");
    await expect(alerta).not.toContainText(/\b500\b/);
    await alerta.getByRole("button", { name: "Reintentar" }).click();
    await expect(page.locator(".bandeja-cifra")).toBeVisible();
  });

  test("sin conexión: barra fina bajo la barra superior", async ({ page, context }) => {
    await page.goto("/bandeja");
    await expect(page.locator(".bandeja-cifra")).toBeVisible();
    await context.setOffline(true);
    await page.evaluate(() => window.dispatchEvent(new Event("offline")));
    await expect(page.getByRole("status").filter({ hasText: "Sin conexión con el servidor" })).toBeVisible();
    await context.setOffline(false);
    await page.evaluate(() => window.dispatchEvent(new Event("online")));
    await expect(page.getByText("Sin conexión con el servidor")).toHaveCount(0);
  });

  test("móvil 393 px: barra inferior de 5 pestañas y lista → detalle a pantalla completa con «‹ Bandeja»", async ({ page }) => {
    await page.setViewportSize({ width: 393, height: 852 });
    await page.goto("/bandeja");
    const pestanas = page.getByRole("navigation", { name: "Navegación principal" }).last().getByRole("link");
    await expect(pestanas).toHaveCount(5);
    await expect(page.locator(".lateral")).toBeHidden();
    await page.locator(".fila-inc", { hasText: "Correo no sincroniza en Outlook" }).click();
    await expect(page.getByRole("article", { name: "Incidencia INC-000142" })).toBeVisible();
    await expect(page.locator(".fila-inc").first()).toBeHidden();
    await page.getByRole("button", { name: /Bandeja/ }).first().click();
    await expect(page.locator(".fila-inc").first()).toBeVisible();
    // No hay desbordamiento horizontal.
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });

  test("el buscador ⌘K abre una hoja central, se navega con flechas y Enter lleva a la incidencia", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/bandeja");
    await expect(page.locator(".bandeja-cifra")).toBeVisible();
    await page.keyboard.press("Control+k");
    const buscador = page.getByRole("dialog", { name: "Buscar" });
    await expect(buscador).toBeVisible();
    await page.keyboard.type("outlook");
    await expect(buscador.getByRole("option").first()).toContainText(/Outlook/i);
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(/\/incidencias\?inc=\d+/);
    await expect(buscador).toHaveCount(0);
  });
});

test.describe("Guardas por rol", () => {
  test("un técnico no entra a Indicadores: se le explica y se le lleva a su inicio", async ({ page, context }) => {
    await conSesion(context, BASE, "tecnico@jsr.test");
    await page.goto("/indicadores");
    await expect(page.getByText("Esta sección no está disponible para tu rol.")).toBeVisible();
    await expect(page.getByRole("link", { name: /Ir a mi inicio/ })).toBeVisible();
    // Y su lateral solo trae lo suyo.
    await expect(page.locator(".lateral").getByRole("link", { name: "Indicadores" })).toHaveCount(0);
    await expect(page.locator(".lateral").getByRole("link", { name: "Bandeja" })).toBeVisible();
  });
});
