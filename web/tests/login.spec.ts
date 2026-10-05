import { expect, test } from "@playwright/test";
import { vigilarConsola } from "./util/sesion";

test.describe("01 · Inicio de sesión", () => {
  test("pide correo y clave en palabras simples y no muestra errores sin tocar nada", async ({ page }) => {
    const errores = vigilarConsola(page);
    await page.goto("/login");
    await expect(page.getByRole("heading", { name: "Inicia sesión" })).toBeVisible();
    await expect(page.locator(".campo-error")).toHaveCount(0);
    await page.getByRole("button", { name: "Continuar" }).click();
    await expect(page.getByText("Escribe tu correo.")).toBeVisible();
    await expect(page.getByText("Escribe tu clave.")).toBeVisible();
    await expect(page.getByLabel("Correo")).toBeFocused();
    expect(errores).toEqual([]);
  });

  test("una clave equivocada avisa sin códigos HTTP y conserva el correo", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("Correo").fill("admin@jsr.test");
    await page.getByLabel("Clave").fill("equivocada");
    await page.getByRole("button", { name: "Continuar" }).click();
    const alerta = page.getByRole("alert");
    await expect(alerta).toContainText("El correo o la clave no coinciden");
    await expect(alerta).not.toContainText(/401|403|error \d/i);
    await expect(page.getByLabel("Correo")).toHaveValue("admin@jsr.test");
  });

  test("entra con admin@jsr.test y llega a la bandeja; la sesión queda en sessionStorage", async ({ page }) => {
    const errores = vigilarConsola(page);
    await page.goto("/login");
    await page.getByLabel("Correo").fill("admin@jsr.test");
    await page.getByLabel("Clave").fill("jsr123");
    await page.getByRole("button", { name: "Continuar" }).click();
    await expect(page).toHaveURL(/\/bandeja/);
    await expect(page.getByRole("heading", { level: 1, name: "Bandeja" })).toBeVisible();
    expect(await page.evaluate(() => !!sessionStorage.getItem("jsr_token"))).toBe(true);
    expect(await page.evaluate(() => localStorage.getItem("jsr_token"))).toBeNull();
    expect(errores).toEqual([]);
  });

  test("sin sesión, una pantalla de la consola manda al inicio de sesión", async ({ page }) => {
    await page.goto("/bandeja");
    await expect(page).toHaveURL(/\/login/);
  });

  test("cada rol cae en su inicio: gerencia en Indicadores, entrenador en Entrenamiento", async ({ page }) => {
    for (const [email, ruta] of [
      ["gerencia@jsr.test", /\/indicadores/],
      ["entrenador@jsr.test", /\/asistente\/entrenamiento/],
    ] as const) {
      await page.goto("/login");
      await page.evaluate(() => sessionStorage.clear());
      await page.goto("/login");
      await page.getByLabel("Correo").fill(email);
      await page.getByLabel("Clave").fill("jsr123");
      await page.getByRole("button", { name: "Continuar" }).click();
      await expect(page).toHaveURL(ruta);
    }
  });
});
