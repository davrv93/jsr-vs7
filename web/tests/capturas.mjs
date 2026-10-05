// Capturas de revisión visual: pantallas clave a 393 / 1280 / 1600 px, en claro y oscuro, con el Chrome del sistema.
// Uso:  node tests/capturas.mjs                  (todas)
//       node tests/capturas.mjs bandeja detalle  (solo las que contienen esas palabras)
//       BASE=http://127.0.0.1:5599 node tests/capturas.mjs   (contra el build estático servido por el mock)
// Las imágenes quedan en web/capturas/. También avisa de errores de consola, de página y peticiones fallidas.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const AQUI = dirname(fileURLToPath(import.meta.url));
const SALIDA = join(AQUI, "..", "capturas");
const BASE = (process.env.BASE ?? "http://localhost:5173").replace(/\/$/, "");
const API = (process.env.API ?? "http://127.0.0.1:5599").replace(/\/$/, "");
mkdirSync(SALIDA, { recursive: true });

const TAM = { movil: { width: 393, height: 852 }, medio: { width: 1024, height: 768 }, laptop: { width: 1280, height: 800 }, ancho: { width: 1600, height: 900 } };

async function sesion(email) {
  const r = await fetch(`${API}/api/auth/login`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email, clave: "jsr123" }) });
  return r.json();
}

// [nombre, ruta, rol, [tamaños], (page)=>antes]
const ESCENAS = [
  ["login", "/login", null, ["movil", "laptop"]],
  ["bandeja", "/bandeja", "admin@jsr.test", ["movil", "laptop", "ancho"]],
  ["bandeja-detalle", "/bandeja?inc=142", "admin@jsr.test", ["movil", "laptop", "ancho"]],
  ["incidencias", "/incidencias", "admin@jsr.test", ["movil", "laptop"]],
  ["indicadores", "/indicadores", "admin@jsr.test", ["movil", "laptop", "ancho"]],
  ["equipo", "/equipo", "admin@jsr.test", ["movil", "laptop"]],
  ["ajustes", "/ajustes", "admin@jsr.test", ["movil", "laptop"]],
  ["conversaciones", "/conversaciones", "admin@jsr.test", ["movil", "laptop"]],
  ["escalamiento", "/escalamiento", "admin@jsr.test", ["laptop"]],
  ["reportes", "/reportes", "admin@jsr.test", ["movil", "laptop"]],
  ["asistente-conocimiento", "/asistente/conocimiento", "admin@jsr.test", ["laptop"]],
  ["asistente-entrenamiento", "/asistente/entrenamiento", "admin@jsr.test", ["laptop"]],
  ["asistente-comportamiento", "/asistente/comportamiento", "admin@jsr.test", ["laptop"]],
  ["asistente-calidad", "/asistente/calidad", "admin@jsr.test", ["laptop"]],
  ["estado", "/estado/ab12cd34ef56ab12cd34ef56ab12cd34", null, ["movil", "laptop"]],
  ["equipo-ficha", "/equipo?tec=2", "admin@jsr.test", ["movil", "laptop", "ancho"]],
  ["buscador", "/bandeja", "admin@jsr.test", ["movil", "laptop"], async (p) => {
    await p.keyboard.press("Meta+k");
    await p.waitForTimeout(400);
    await p.keyboard.type("outlook", { delay: 40 });
    await p.waitForTimeout(900);
  }],
  ["dialogo-resolver", "/bandeja", "admin@jsr.test", ["movil", "laptop"], async (p) => {
    await p.locator("[data-fila]").first().focus();
    await p.keyboard.press("e");
    await p.waitForTimeout(500);
  }],
  ["hoja-nueva", "/incidencias", "admin@jsr.test", ["movil", "laptop"], async (p) => {
    await p.getByRole("button", { name: "Nueva incidencia" }).click();
    await p.waitForTimeout(700);
  }],
  ["menu-detalle", "/bandeja?inc=142", "admin@jsr.test", ["laptop"], async (p) => {
    await p.getByRole("button", { name: "Más acciones" }).click();
    await p.waitForTimeout(400);
  }],
  ["estado-vacio-bandeja", "/bandeja", "admin@jsr.test", ["movil", "laptop"], null, async (p) => {
    await p.route("**/api/bandeja", (r) => r.fulfill({ json: { vencen_pronto: [], mias: [], sin_asignar: [], contador: 0, espera_usuario: { cantidad: 2, desde: new Date(Date.now() - 30 * 3600e3).toISOString() } } }));
  }],
  ["estado-error-bandeja", "/bandeja", "admin@jsr.test", ["movil", "laptop"], null, async (p) => {
    await p.route("**/api/bandeja", (r) => r.fulfill({ status: 500, json: { codigo: "interno" } }));
  }],
  ["estado-carga-bandeja", "/bandeja", "admin@jsr.test", ["movil", "laptop"], async (p) => { await p.waitForTimeout(0); }, async (p) => {
    await p.route("**/api/bandeja", async (r) => { await new Promise((x) => setTimeout(x, 6000)); await r.continue(); });
  }],
  ["detalle-largo", "/bandeja?inc=140", "admin@jsr.test", ["movil", "laptop"]],
  ["detalle-80-mensajes", "/bandeja?inc=118", "admin@jsr.test", ["laptop"], async (p) => {
    await p.getByRole("button", { name: /Ver todo/ }).click().catch(() => {});
    await p.waitForTimeout(500);
  }],
  ["mas", "/mas", "admin@jsr.test", ["movil"]],
  ["medio-hoja", "/bandeja?inc=142", "admin@jsr.test", ["medio"]],
  ["lateral-plegado", "/bandeja", "admin@jsr.test", ["laptop"], async (p) => {
    await p.getByRole("button", { name: /Plegar el menú lateral/ }).click();
    await p.waitForTimeout(400);
  }],
  ["reportes-resultado", "/reportes", "admin@jsr.test", ["movil", "laptop"], async (p) => {
    await p.getByLabel("Pregunta lo que quieras saber").fill("¿cuántas incidencias se reabrieron?");
    await p.getByRole("button", { name: "Preguntar" }).click();
    await p.waitForTimeout(1800);
  }],
  ["entrenamiento-comparar", "/asistente/entrenamiento", "admin@jsr.test", ["laptop"], async (p) => {
    // El mock conserva el estado: en la segunda pasada (otro tema) ya hay un candidato y no hay nada que pulsar.
    await p.getByRole("button", { name: "Entendió bien" }).first().click({ timeout: 2000 }).catch(() => {});
    await p.waitForTimeout(600);
    const hay = await p.getByRole("button", { name: "Reentrenar" }).isVisible().catch(() => false);
    if (hay) await p.getByRole("button", { name: "Reentrenar" }).click({ timeout: 2000 }).catch(() => {});
    await p.waitForTimeout(6500);
  }],
  ...["SLA", "Calendario", "Categorías", "Matriz", "Roles"].map((t) => [`ajustes-${t.toLowerCase().replace("í", "i")}`, "/ajustes", "admin@jsr.test", ["laptop", "movil"], async (p) => {
    await p.getByRole("tab", { name: t }).click();
    await p.waitForTimeout(900);
  }]),
  ["escalamiento-hoja", "/escalamiento", "admin@jsr.test", ["laptop", "movil"], async (p) => {
    await p.getByRole("button", { name: /75 % del plazo de primera/ }).click();
    await p.waitForTimeout(800);
  }],
  ["conocimiento-editor", "/asistente/conocimiento", "admin@jsr.test", ["laptop"], async (p) => {
    await p.locator(".fila-art").first().click();
    await p.waitForTimeout(800);
  }],
  ["conversacion-detalle", "/conversaciones?caso=900", "admin@jsr.test", ["laptop", "movil"]],
  ["calidad", "/asistente/calidad", "admin@jsr.test", ["laptop", "movil"]],
  ["comportamiento-abajo", "/asistente/comportamiento", "admin@jsr.test", ["movil"], async (p) => {
    await p.mouse.wheel(0, 2000);
    await p.waitForTimeout(500);
  }],
  ["chat", "/chat", null, ["movil", "laptop"]],
  ["chat-analisis", "/chat", null, ["movil", "ancho"], async (p) => {
    await p.getByRole("button", { name: "No me abre el correo" }).click().catch(() => {});
    await p.waitForTimeout(2500);
    await p.getByRole("button", { name: "Opciones del chat" }).click().catch(() => {});
    await p.getByRole("menuitem", { name: /Análisis/ }).click().catch(() => {});
    await p.waitForTimeout(600);
  }],
];

const filtros = process.argv.slice(2);
const temas = (process.env.TEMAS ?? "claro,oscuro").split(",");
const navegador = await chromium.launch({ channel: "chrome", headless: true });
const problemas = [];

for (const [nombre, ruta, rol, tamanos, antes, previo] of ESCENAS) {
  if (filtros.length && !filtros.some((f) => nombre.includes(f))) continue;
  const ses = rol ? await sesion(rol) : null;
  for (const tamano of tamanos) {
    for (const tema of temas) {
      const ctx = await navegador.newContext({
        viewport: TAM[tamano],
        colorScheme: tema === "oscuro" ? "dark" : "light",
        deviceScaleFactor: tamano === "movil" ? 2 : 1,
        locale: "es-PE",
        timezoneId: "America/Lima",
        isMobile: tamano === "movil",
        hasTouch: tamano === "movil",
      });
      if (ses) {
        await ctx.addInitScript(([t, u]) => {
          try {
            sessionStorage.setItem("jsr_token", t);
            sessionStorage.setItem("jsr_usuario", JSON.stringify(u));
          } catch {}
        }, [ses.token, ses.usuario]);
      }
      const page = await ctx.newPage();
      const etiqueta = `${nombre}@${tamano}-${tema}`;
      page.on("console", (m) => {
        if (m.type() === "error" || m.type() === "warning") problemas.push(`${etiqueta} consola ${m.type()}: ${m.text().slice(0, 200)}`);
      });
      page.on("pageerror", (e) => problemas.push(`${etiqueta} error de página: ${e.message.slice(0, 200)}`));
      page.on("requestfailed", (r) => {
        if (!r.url().includes("fonts.g")) problemas.push(`${etiqueta} petición fallida: ${r.url().slice(0, 100)}`);
      });
      if (previo) await previo(page);
      await page.goto(BASE + ruta, { waitUntil: "load" }).catch(() => {});
      await page.waitForTimeout(Number(process.env.ESPERA ?? 2200));
      if (antes) await antes(page);
      await page.screenshot({ path: join(SALIDA, `${nombre}-${tamano}-${tema}.png`), fullPage: false });
      await ctx.close();
    }
  }
}
await navegador.close();
console.log(problemas.length ? "PROBLEMAS:\n" + [...new Set(problemas)].join("\n") : "Sin errores de consola ni de red.");
console.log("Capturas en", SALIDA);
