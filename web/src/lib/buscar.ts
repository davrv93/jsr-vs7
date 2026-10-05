import type { Rol } from "./auth";
import { api } from "./api";
import { CATEGORIA_TEXTO, ESTADO_TEXTO } from "./format";
import { puede, RUTAS } from "./rutas";
import type { Articulo, IncResumen, Lista, ReporteGuardado, Tecnico } from "./tipos";

// Buscador global (⌘K). El contrato no trae un endpoint de búsqueda: se combinan los listados existentes y se
// filtra en el cliente. Si el backend ofrece GET /api/buscar?q=, bastaría con reemplazar esta función.

export interface ResultadoBusqueda {
  id: string;
  titulo: string;
  detalle?: string;
  /** Ruta de la consola, con su query. */
  ir: string;
}
export interface GrupoBusqueda {
  titulo: string;
  items: ResultadoBusqueda[];
}

const norm = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

let cacheTecnicos: Tecnico[] | null = null;
let cacheArticulos: Articulo[] | null = null;
let cacheReportes: ReporteGuardado[] | null = null;

export const olvidarCacheBusqueda = () => {
  cacheTecnicos = cacheArticulos = cacheReportes = null;
};

export async function buscarTodo(texto: string, rol: Rol | undefined): Promise<GrupoBusqueda[]> {
  const t = texto.trim();
  const n = norm(t);
  const grupos: GrupoBusqueda[] = [];

  const secciones = RUTAS.filter((r) => r.lateral && puede(rol, r.roles) && (!n || norm(r.titulo).includes(n)));
  const consultas: Promise<void>[] = [];

  if (t.length >= 2) {
    if (puede(rol, ["tecnico", "supervisor", "gerencia"])) {
      consultas.push(
        api<Lista<IncResumen>>(`/api/incidencias?q=${encodeURIComponent(t)}&por_pagina=6`)
          .then((d) => {
            if (d.items.length)
              grupos.push({
                titulo: "Incidencias",
                items: d.items.map((i) => ({
                  id: `inc-${i.id}`,
                  titulo: `${i.numero}  ${i.titulo}`,
                  detalle: `${ESTADO_TEXTO[i.estado] ?? i.estado}${i.persona ? " · " + i.persona.nombre : ""}`,
                  ir: `/incidencias?inc=${i.id}`,
                })),
              });
          })
          .catch(() => undefined),
      );
    }
    if (puede(rol, ["supervisor", "gerencia"])) {
      consultas.push(
        (cacheTecnicos
          ? Promise.resolve(cacheTecnicos)
          : api<Lista<Tecnico>>("/api/tecnicos?por_pagina=100").then((d) => (cacheTecnicos = d.items))
        )
          .then((ts) => {
            const hallados = ts.filter((x) => norm(x.nombre).includes(n)).slice(0, 5);
            if (hallados.length)
              grupos.push({
                titulo: "Personas",
                items: hallados.map((x) => ({ id: `tec-${x.id}`, titulo: x.nombre, detalle: `${x.nivel} · ${x.carga} abiertas`, ir: `/equipo?tec=${x.id}` })),
              });
          })
          .catch(() => undefined),
      );
    }
    if (puede(rol, ["entrenador"])) {
      consultas.push(
        (cacheArticulos
          ? Promise.resolve(cacheArticulos)
          : api<Lista<Articulo>>("/api/articulos?por_pagina=200").then((d) => (cacheArticulos = d.items))
        )
          .then((as) => {
            const hallados = as.filter((x) => norm(x.titulo + " " + x.clave + " " + x.sintomas.join(" ")).includes(n)).slice(0, 5);
            if (hallados.length)
              grupos.push({
                titulo: "Artículos",
                items: hallados.map((x) => ({ id: `art-${x.id}`, titulo: `${x.clave}  ${x.titulo}`, detalle: x.categoria ? CATEGORIA_TEXTO[x.categoria] : undefined, ir: `/asistente/conocimiento?art=${x.id}` })),
              });
          })
          .catch(() => undefined),
      );
    }
    if (puede(rol, ["gerencia"])) {
      consultas.push(
        (cacheReportes
          ? Promise.resolve(cacheReportes)
          : api<Lista<ReporteGuardado>>("/api/reportes").then((d) => (cacheReportes = d.items))
        )
          .then((rs) => {
            const hallados = rs.filter((x) => norm(x.nombre + " " + x.descripcion).includes(n)).slice(0, 5);
            if (hallados.length)
              grupos.push({
                titulo: "Reportes",
                items: hallados.map((x) => ({ id: `rep-${x.id}`, titulo: x.nombre, detalle: x.descripcion, ir: `/reportes?r=${x.id}` })),
              });
          })
          .catch(() => undefined),
      );
    }
  }
  await Promise.all(consultas);

  // Orden fijo: incidencias, personas, artículos, reportes, secciones.
  const orden = ["Incidencias", "Personas", "Artículos", "Reportes"];
  grupos.sort((a, b) => orden.indexOf(a.titulo) - orden.indexOf(b.titulo));
  if (secciones.length) grupos.push({ titulo: "Ir a", items: secciones.map((r) => ({ id: `ir-${r.ruta}`, titulo: r.titulo, ir: r.ruta })) });
  return grupos;
}
