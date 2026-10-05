import { expect, test } from "@playwright/test";
import { BASE, conSesion, vigilarConsola } from "./util/sesion";


test.describe("Pantallas completas", () => {
  test.beforeEach(async ({ context, page }) => {
    await conSesion(context, BASE);
    await page.setViewportSize({ width: 1280, height: 800 });
  });

  test("04 · Incidencias: búsqueda y filtros", async ({ page }) => {
    const errores = vigilarConsola(page);
    await page.goto("/incidencias");
    await expect(page.locator(".lista-meta")).toContainText(/incidencias/);
    await page.getByLabel("Buscar por número, asunto o persona").fill("zzzz-no-existe");
    await expect(page.getByText("Ninguna incidencia coincide con estos filtros.")).toBeVisible();
    await page.getByRole("button", { name: "Quitar los filtros" }).click();
    await expect(page.locator(".fila-inc").first()).toBeVisible();
    await page.getByRole("radio", { name: "Resueltas" }).click();
    await expect(page.locator(".fila-inc-estado").first()).toHaveText("Resuelta");
    expect(errores).toEqual([]);
  });

  test("06/07 · Equipo y ficha: guarda y valida", async ({ page }) => {
    await page.goto("/equipo?tec=10");
    const ficha = page.getByRole("article", { name: /Ficha de Edith/ });
    await expect(ficha.getByRole("heading", { name: "Edith Mamani Quispe" })).toBeVisible();
    await ficha.getByLabel("WhatsApp").fill("123");
    await ficha.getByRole("button", { name: "Guardar" }).click();
    await expect(ficha.getByText(/Solo dígitos con el prefijo del país/)).toBeVisible();
    await ficha.getByLabel("WhatsApp").fill("51987654321");
    await ficha.getByRole("button", { name: "Guardar" }).click();
    await expect(page.getByRole("status").filter({ hasText: "Ficha guardada." })).toBeVisible();
  });

  test("09 · Indicadores: la cifra que pide acción sube y cada bloque trae su definición", async ({ page }) => {
    await page.goto("/indicadores");
    const primero = page.locator(".kpi").first();
    await expect(primero.locator(".kpi-titulo")).toHaveText(/Pendientes con más de 7 días/);
    await expect(primero.getByText("Pide acción")).toBeVisible();
    await primero.getByRole("button", { name: /Definición/ }).click();
    await expect(primero.getByText(/Golden query/)).toBeVisible();
    await expect(primero.locator("pre.sql")).toContainText("SELECT");
    await expect(primero.getByRole("table")).toBeVisible();
    // Cambiar el periodo vuelve a pedir las cifras.
    await page.getByRole("radio", { name: "Trimestre" }).click();
    await expect(page.locator(".indicadores-periodo")).toContainText("Del");
  });

  test("15 · Ajustes: tema manual y validación de SLA", async ({ page }) => {
    await page.goto("/ajustes");
    await page.getByRole("radio", { name: "Oscuro" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-tema", "oscuro");
    await page.getByRole("radio", { name: "Sistema" }).click();
    await expect(page.locator("html")).not.toHaveAttribute("data-tema", /.+/);
    await page.getByRole("tab", { name: "SLA" }).click();
    const campo = page.getByLabel("Resolución (min)").first();
    await campo.fill("5");
    await page.getByRole("button", { name: "Guardar plazos" }).click();
    await expect(page.getByText(/La resolución no puede ser más corta/).first()).toBeVisible();
  });

  test("15 · Ajustes: quitar un feriado pide confirmación propia y es destructivo", async ({ page }) => {
    await page.goto("/ajustes");
    await page.getByRole("tab", { name: "Calendario" }).click();
    await page.getByRole("button", { name: /Quitar el feriado Combate de Angamos/ }).click();
    const dialogo = page.getByRole("dialog", { name: /¿Quitar «Combate de Angamos»\?/ });
    await expect(dialogo).toBeVisible();
    // Lo seguro lleva el foco: Cancelar.
    await expect(dialogo.getByRole("button", { name: "Cancelar" })).toBeFocused();
    await dialogo.getByRole("button", { name: "Quitar feriado" }).click();
    await expect(page.getByText("Combate de Angamos")).toHaveCount(0);
  });

  test("03 · Memoria del caso: aplana {sabemos:{…}, pendiente} con etiquetas legibles", async ({ page }) => {
    await page.goto("/bandeja?inc=142");
    const detalle = page.getByRole("article", { name: "Incidencia INC-000142" });
    await detalle.getByRole("button", { name: "Más", exact: true }).click();
    await detalle.getByRole("tab", { name: "Memoria" }).click();
    const panel = detalle.getByRole("tabpanel");
    for (const etiqueta of ["Síntoma", "Aplicación", "Desde cuándo", "Equipo", "Sede", "Pasos probados"]) await expect(panel.getByText(etiqueta, { exact: true })).toBeVisible();
    await expect(panel).not.toContainText("[object");
    await expect(panel).not.toContainText("sabemos");
    await expect(panel.getByText("Sin mensaje de error")).toBeVisible();
  });

  test("03 · Memoria y veredictos de la forma real, aunque traigan claves que no son veredictos", async ({ page }) => {
    await page.route("**/api/incidencias/142", async (ruta) => {
      const r = await ruta.fetch();
      const d = await r.json();
      d.memoria = { etapa: "guia", pendiente: "aplicacion", sabemos: { sintoma: "no abre", equipo: "PC-CONT-07", desde: "hoy 08:30", impacto: "persona", mensaje_error: "desconocido" }, articulos_mostrados: ["KB-031"], intentos_guia: 2, incidencia: null, preguntado: ["que_pasa"] };
      d.veredictos = [{ ts: d.creada_en, modo: "sombra", tipo: "clasificacion", veredicto: null, confianza: null }];
      d.clasificacion = { intencion: "reportar_falla", confianza: null, categoria: "correo", categoria_confianza: null };
      await ruta.fulfill({ response: r, json: d });
    });
    await page.goto("/bandeja?inc=142");
    const detalle = page.getByRole("article", { name: "Incidencia INC-000142" });
    await detalle.getByRole("button", { name: "Más", exact: true }).click();
    await detalle.getByRole("tab", { name: "Memoria" }).click();
    const panel = detalle.getByRole("tabpanel");
    await expect(panel.getByText("En qué programa o sistema le pasa")).toBeVisible();
    await expect(panel.getByText("No sabe")).toBeVisible();
    await expect(panel.getByText("Una persona")).toBeVisible();
    await detalle.getByRole("tab", { name: "Clasificación" }).click();
    await expect(panel).not.toContainText("NaN");
    await detalle.getByRole("tab", { name: "Jev local" }).click();
    await expect(panel).not.toContainText(/NaN|undefined|null/);
  });

  test("17 · Chat: «juez.veredictos» con rag y datos sueltos se separa en veredictos y «Otros datos»", async ({ page }) => {
    await page.setViewportSize({ width: 393, height: 852 });
    await page.goto("/chat");
    await page.getByRole("button", { name: "No me abre el correo" }).click();
    await expect(page.getByText(/en qué equipo te pasa/)).toBeVisible({ timeout: 8_000 });
    await page.getByLabel("Escribe un mensaje").fill("Es la PC-CONT-07, desde ayer");
    await page.getByRole("button", { name: "Enviar", exact: true }).click();
    await expect(page.getByRole("button", { name: "Sí, se resolvió" })).toBeVisible({ timeout: 10_000 });
    await page.getByRole("button", { name: "Opciones del chat" }).click();
    await page.getByRole("menuitem", { name: /Análisis/ }).click();
    const cajon = page.getByRole("dialog", { name: "Análisis del asistente" });
    await expect(cajon.getByText("Otros datos")).toBeVisible();
    await expect(cajon.getByText("Búsqueda de artículos")).toBeVisible();
    await expect(cajon.getByText("Pendiente", { exact: true })).toBeVisible();
    await expect(cajon).not.toContainText(/\[object|undefined/);
  });

  test("08 · Escalamiento: el porcentaje se muestra y se guarda como umbral_pct y como porcentaje", async ({ page }) => {
    await page.goto("/escalamiento");
    await page.getByRole("button", { name: /75 % del plazo de primera respuesta/ }).click();
    const hoja = page.getByRole("dialog", { name: /75 % del plazo de primera respuesta/ });
    await expect(hoja.getByLabel("Porcentaje del plazo")).toHaveValue("75");
    // Solo se ofrecen las acciones que entiende el motor.
    await expect(hoja.getByRole("checkbox")).toHaveCount(6);
    await hoja.getByLabel("Porcentaje del plazo").fill("80");
    const peticion = page.waitForRequest((r) => r.url().includes("/api/escalamiento/reglas/") && r.method() === "PUT");
    await hoja.getByRole("button", { name: "Guardar" }).click();
    const cuerpo = (await peticion).postDataJSON();
    expect(cuerpo.umbral_pct).toBe(80);
    expect(cuerpo.condicion.umbral_pct).toBe(80);
    expect(cuerpo.condicion.porcentaje).toBe(80);
    await expect(page.getByRole("status").filter({ hasText: "Regla guardada." })).toBeVisible();
  });

  test("12 · Conocimiento vacío: «Todavía no hay artículos.» con «Nuevo artículo»", async ({ page }) => {
    await page.route("**/api/articulos*", (ruta) => ruta.fulfill({ json: { items: [], total: 0 } }));
    await page.goto("/asistente/conocimiento");
    await expect(page.getByText("Todavía no hay artículos.")).toBeVisible();
    await page.getByRole("button", { name: "Nuevo artículo" }).last().click();
    await expect(page.getByRole("dialog", { name: "Nuevo artículo" })).toBeVisible();
  });

  test("09 · Indicadores sin ClickHouse: cada bloque dice por qué no hay cifra, sin romper la columna", async ({ page }) => {
    await page.route("**/api/indicadores*", (ruta) =>
      ruta.fulfill({
        json: {
          desde: "2026-09-06",
          hasta: "2026-10-05",
          kpis: ["sla_cumplimiento", "mttr", "csat"].map((kpi) => ({ kpi, titulo: `KPI ${kpi}`, definicion: "Definición de prueba.", sql: "", unidad: "", meta: null, sentido: "mayor_mejor", filas: [], valor: null, detalle: "ClickHouse no está configurado: las cifras no se pueden calcular todavía." })),
        },
      }),
    );
    await page.goto("/indicadores");
    await expect(page.getByText(/Ninguna cifra se pudo calcular ahora/)).toBeVisible();
    await expect(page.locator(".kpi-sin-datos")).toHaveCount(3);
    await expect(page.locator(".kpi-vacio").first()).toContainText("ClickHouse no está configurado");
    await expect(page.locator(".cifra")).toHaveCount(0);
    await page.locator(".kpi-sin-datos").first().getByRole("button", { name: /Definición/ }).click();
    await expect(page.getByText("Definición de prueba.")).toBeVisible();
  });

  test("los diálogos se apilan sobre una hoja: Escape cierra solo el de arriba y el foco vuelve a la hoja", async ({ page }) => {
    await page.goto("/asistente/conocimiento");
    await page.locator(".fila-art").first().click();
    const hoja = page.getByRole("dialog", { name: /versión de trabajo/ });
    await expect(hoja).toBeVisible();
    await hoja.getByRole("button", { name: "Archivar" }).click();
    const confirmacion = page.getByRole("dialog", { name: /¿Archivar/ });
    await expect(confirmacion).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(confirmacion).toHaveCount(0);
    await expect(hoja).toBeVisible();
    await expect(hoja.getByRole("button", { name: "Archivar" })).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(hoja).toHaveCount(0);
  });

  test("a11y de teclado: el control segmentado se mueve con las flechas", async ({ page }) => {
    await page.goto("/indicadores");
    const mes = page.getByRole("radio", { name: "Mes", exact: true });
    await mes.focus();
    await page.keyboard.press("ArrowRight");
    await expect(page.getByRole("radio", { name: "Trimestre" })).toBeFocused();
    await expect(page.getByRole("radio", { name: "Trimestre" })).toHaveAttribute("aria-checked", "true");
  });

  test("movimiento reducido: las hojas y los diálogos no animan", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto("/incidencias");
    await page.getByRole("button", { name: "Nueva incidencia" }).click();
    const dur = await page.locator(".hoja").evaluate((el) => getComputedStyle(el).animationDuration);
    expect(parseFloat(dur)).toBeLessThan(0.01);
  });

  test("10 · Reportes: golden query verificada o «Sin verificar» con el SQL", async ({ page }) => {
    await page.goto("/reportes");
    await page.getByLabel("Pregunta lo que quieras saber").fill("¿Cuál fue el MTTR por categoría?");
    await page.getByRole("button", { name: "Preguntar" }).click();
    await expect(page.getByText(/Golden query · MTTR por categoría v3/)).toBeVisible();
    await page.getByLabel("Pregunta lo que quieras saber").fill("¿cuántas incidencias se reabrieron?");
    await page.getByRole("button", { name: "Preguntar" }).click();
    await expect(page.locator(".resultado-origen.sin-verificar")).toHaveText("Sin verificar");
    await expect(page.locator("pre.sql")).toContainText("SELECT");
  });

  test("13 · Entrenamiento: Reentrenar se activa al revisar y se compara antes de publicar", async ({ page }) => {
    test.setTimeout(60_000);
    await page.goto("/asistente/entrenamiento");
    const reentrenar = page.getByRole("button", { name: "Reentrenar" });
    await expect(reentrenar).toBeDisabled();
    await page.getByRole("button", { name: "Entendió bien" }).first().click();
    await expect(reentrenar).toBeEnabled();
    await reentrenar.click();
    await expect(page.getByRole("group", { name: "Comparación de versiones" })).toBeVisible({ timeout: 15_000 });
    await expect(page.getByRole("button", { name: /^Publicar v/ })).toBeEnabled();
  });

  test("12 · Conocimiento: nuevo artículo con validación", async ({ page }) => {
    await page.goto("/asistente/conocimiento");
    await page.getByRole("button", { name: "Nuevo artículo" }).first().click();
    const hoja = page.getByRole("dialog", { name: "Nuevo artículo" });
    await hoja.getByRole("button", { name: "Guardar" }).click();
    await expect(hoja.getByText(/Escribe el título/)).toBeVisible();
    await hoja.getByLabel("Título").fill("Prueba de artículo");
    await hoja.getByLabel("Pasos").fill("Primer paso\nSegundo paso");
    await hoja.getByRole("button", { name: "Guardar" }).click();
    await expect(page.getByRole("status").filter({ hasText: "Artículo creado." })).toBeVisible();
  });

  test("05 · Conversaciones: tomar la conversación pide confirmación propia", async ({ page }) => {
    await page.goto("/conversaciones?caso=900");
    await page.getByRole("button", { name: "Tomar la conversación" }).click();
    await expect(page.getByRole("dialog", { name: "¿Tomar la conversación?" })).toBeVisible();
    await page.getByRole("dialog").getByRole("button", { name: "Tomar la conversación" }).click();
    await expect(page.getByRole("status").filter({ hasText: "Tomaste la conversación" })).toBeVisible();
    await page.getByRole("button", { name: "Devolver al asistente" }).click();
    await expect(page.getByRole("status").filter({ hasText: "Devolviste la conversación" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Tomar la conversación" })).toBeVisible();
  });
});

test.describe("Públicas", () => {
  test("16 · Estado público: sin sesión, por token, con Responder", async ({ page }) => {
    const errores = vigilarConsola(page);
    await page.setViewportSize({ width: 393, height: 852 });
    await page.goto("/estado/ab12cd34ef56ab12cd34ef56ab12cd34");
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page.getByText("INC-000142")).toBeVisible();
    await page.getByRole("button", { name: "Responder" }).click();
    await page.getByLabel("Tu respuesta").fill("Ya probé y sigue igual.");
    await page.getByRole("button", { name: "Enviar" }).click();
    await expect(page.getByRole("status").filter({ hasText: "Enviamos tu respuesta" })).toBeVisible();
    expect(errores).toEqual([]);
  });

  test("16 · Estado público: un enlace que no existe lo dice sin jerga", async ({ page }) => {
    await page.goto("/estado/token-que-no-existe");
    await expect(page.getByText("No encontramos esta incidencia.")).toBeVisible();
  });

  test("17 · Chat web: respuestas rápidas, botones de respuesta y cajón de análisis", async ({ page }) => {
    const errores = vigilarConsola(page);
    await page.setViewportSize({ width: 393, height: 852 });
    await page.goto("/chat");
    await expect(page.getByRole("heading", { name: "Mesa de ayuda" })).toBeVisible();
    await page.getByRole("button", { name: "No me abre el correo" }).click();
    await expect(page.getByText(/en qué equipo te pasa/)).toBeVisible({ timeout: 8_000 });
    await page.getByLabel("Escribe un mensaje").fill("Es la PC-CONT-07, desde ayer");
    await page.getByRole("button", { name: "Enviar", exact: true }).click();
    await expect(page.getByRole("button", { name: "Sí, se resolvió" })).toBeVisible({ timeout: 10_000 });
    await expect(page.getByRole("button", { name: "Sigue igual" })).toBeVisible();
    await page.getByRole("button", { name: "Sigue igual" }).click();
    await expect(page.getByRole("button", { name: "Abrir incidencia" })).toBeVisible({ timeout: 8_000 });
    await expect(page.getByRole("button", { name: "Hablar con un técnico" })).toBeVisible();
    await page.getByRole("button", { name: "Abrir incidencia" }).click();
    await expect(page.getByText(/abrí la incidencia INC-/i)).toBeVisible({ timeout: 8_000 });
    // Análisis: etapa, ficha, clasificación, veredictos y artículos.
    await page.getByRole("button", { name: "Opciones del chat" }).click();
    await page.getByRole("menuitem", { name: /Análisis/ }).click();
    const cajon = page.getByRole("dialog", { name: "Análisis del asistente" });
    await expect(cajon.getByText("Etapa de atención")).toBeVisible();
    await expect(cajon.getByText("Ficha del caso")).toBeVisible();
    await expect(cajon.getByRole("heading", { name: /Jev local/ })).toBeVisible();
    await expect(cajon.getByText("Artículos usados (RAG)")).toBeVisible();
    expect(errores).toEqual([]);
  });

  test("17 · Chat web: no guarda ni repite una contraseña pegada por error", async ({ page }) => {
    await page.goto("/chat");
    await page.getByLabel("Escribe un mensaje").fill("mi clave es hola1234 y no entra");
    await page.getByRole("button", { name: "Enviar", exact: true }).click();
    await expect(page.getByText(/no necesito tu contraseña/)).toBeVisible({ timeout: 8_000 });
  });
});
