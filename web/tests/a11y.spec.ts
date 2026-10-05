import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";
import { BASE, conSesion } from "./util/sesion";


// WCAG 2.1 AA, en claro y oscuro, en las pantallas que más se usan.
const PANTALLAS = [
  ["login", "/login", false],
  ["bandeja", "/bandeja", true],
  ["detalle", "/bandeja?inc=142", true],
  ["incidencias", "/incidencias", true],
  ["equipo", "/equipo?tec=2", true],
  ["indicadores", "/indicadores", true],
  ["ajustes", "/ajustes", true],
  ["reportes", "/reportes", true],
  ["conocimiento", "/asistente/conocimiento", true],
  ["estado", "/estado/ab12cd34ef56ab12cd34ef56ab12cd34", false],
  ["chat", "/chat", false],
] as const;

for (const tema of ["light", "dark"] as const) {
  for (const [nombre, ruta, sesion] of PANTALLAS) {
    test(`a11y ${nombre} (${tema})`, async ({ page, context }) => {
      await page.emulateMedia({ colorScheme: tema });
      if (sesion) await conSesion(context, BASE);
      await page.setViewportSize({ width: nombre === "estado" || nombre === "chat" ? 393 : 1280, height: 850 });
      await page.goto(ruta);
      await page.waitForTimeout(1800);
      const r = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"]).analyze();
      const graves = r.violations.map((v) => `${v.id} (${v.impact}): ${v.nodes.slice(0, 3).map((n) => n.target.join(" ")).join(" | ")}`);
      expect(graves, graves.join("\n")).toEqual([]);
    });
  }
}
