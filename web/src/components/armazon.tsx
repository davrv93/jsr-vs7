import { $, component$, useContext } from "@builder.io/qwik";
import { Link, useLocation, useNavigate } from "@builder.io/qwik-city";
import { cerrarSesion, guardarPref } from "~/lib/auth";
import { BASE, u } from "~/lib/base";
import { ROL_TEXTO } from "~/lib/format";
import { PESTANAS_MOVIL, puede, RUTAS, rutaDe, type Ruta } from "~/lib/rutas";
import { UiCtx } from "~/lib/ui";
import { Icono } from "./ui/icono";
import { MenuAcciones } from "./ui/menu";

const sinBase = (pathname: string) => (BASE && pathname.startsWith(BASE) ? pathname.slice(BASE.length) : pathname) || "/";

/** Lateral de 232 px, translúcido, plegable a iconos (64 px). Tres bloques sin títulos. Contador solo en Bandeja. */
export const Lateral = component$(() => {
  const ui = useContext(UiCtx);
  const loc = useLocation();
  const path = sinBase(loc.url.pathname);
  const visibles = ui.listo ? RUTAS.filter((r) => r.lateral && puede(ui.usuario?.rol, r.roles)) : [];
  const bloques = [1, 2, 3].map((b) => visibles.filter((r) => r.bloque === b)).filter((b) => b.length);
  return (
    <aside class="lateral" aria-label="Navegación principal">
      <div class="lateral-cab">
        <span class="lateral-marca" aria-hidden="true">
          <span class="lateral-sello">j</span>
          <span class="lateral-nombre">jsrbot</span>
        </span>
        <button
          type="button"
          class="icono-boton lateral-plegar"
          aria-label={ui.plegado ? "Expandir el menú lateral" : "Plegar el menú lateral"}
          aria-pressed={ui.plegado}
          onClick$={() => {
            ui.plegado = !ui.plegado;
            guardarPref("plegado", ui.plegado ? "1" : "0");
            if (ui.plegado) document.documentElement.setAttribute("data-plegado", "1");
            else document.documentElement.removeAttribute("data-plegado");
          }}
        >
          <Icono n="panel" />
        </button>
      </div>
      <nav class="lateral-nav">
        {!ui.listo && (
          <div class="esq lateral-esq" aria-hidden="true">
            {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
              <span class="esq-linea" key={i} />
            ))}
          </div>
        )}
        {bloques.map((bloque, i) => (
          <ul class="lateral-bloque" key={i} role="list">
            {bloque.map((r: Ruta) => {
              const activo = path === r.ruta || path.startsWith(r.ruta + "/");
              return (
                <li key={r.ruta}>
                  <Link
                    href={u(r.ruta)}
                    class={`lateral-item${activo ? " activo" : ""}`}
                    aria-current={activo ? "page" : undefined}
                    title={ui.plegado ? r.titulo : undefined}
                  >
                    <Icono n={r.icono} tam={18} />
                    <span class="lateral-texto">{r.titulo}</span>
                    {r.ruta === "/bandeja" && ui.contador > 0 && (
                      <span class="lateral-contador" aria-label={`${ui.contador} piden acción`}>
                        {ui.contador}
                      </span>
                    )}
                  </Link>
                </li>
              );
            })}
          </ul>
        ))}
      </nav>
    </aside>
  );
});

/** Barra superior translúcida de 52 px: título (o «‹ Bandeja» en móvil), buscador ⌘K, la acción principal de la
 *  sección (una sola, píldora azul) y el avatar. */
export const BarraSuperior = component$(() => {
  const ui = useContext(UiCtx);
  const loc = useLocation();
  const nav = useNavigate();
  const ruta = rutaDe(sinBase(loc.url.pathname));
  const rol = ui.usuario?.rol;

  const elegir = $(async (v: string) => {
    if (v === "ajustes") await nav(u("/ajustes"));
    else if (v === "salir") {
      cerrarSesion();
      await nav(u("/login"));
    }
  });

  return (
    <header class="barra">
      <div class="barra-izq">
        {ui.barra.atras ? (
          <button type="button" class="barra-atras" onClick$={() => ui.evAtras++}>
            <Icono n="izq" tam={20} />
            <span>{ui.barra.atras}</span>
          </button>
        ) : (
          <h1 class="barra-titulo">{ruta?.titulo ?? "jsrbot"}</h1>
        )}
      </div>
      <div class="barra-der">
        <button type="button" class="buscar-disparo" aria-label="Buscar (Comando K)" disabled={!ui.listo} onClick$={() => (ui.buscadorAbierto = true)}>
          <Icono n="buscar" tam={16} />
          <span class="buscar-texto">Buscar</span>
          <kbd class="buscar-tecla" aria-hidden="true">
            ⌘K
          </kbd>
        </button>
        {ui.barra.accion && !ui.barra.atras && (
          <button type="button" class="boton boton-principal" disabled={ui.barra.accionDeshabilitada} onClick$={() => ui.evAccion++}>
            {ui.barra.accion}
          </button>
        )}
        {ui.listo && ui.usuario && (
          <MenuAcciones
            etiqueta={`Cuenta de ${ui.usuario.nombre}`}
            avatar={ui.usuario.nombre}
            items={[
              { valor: "nombre", titulo: `${ui.usuario.nombre} · ${ROL_TEXTO[rol ?? "tecnico"]}`, deshabilitado: true },
              { valor: "ajustes", titulo: "Ajustes", separador: true },
              { valor: "salir", titulo: "Cerrar sesión" },
            ]}
            onElegir$={elegir}
          />
        )}
      </div>
    </header>
  );
});

/** Barra inferior de 5 pestañas en móvil (≤ 768 px). */
export const BarraInferior = component$(() => {
  const ui = useContext(UiCtx);
  const loc = useLocation();
  const path = sinBase(loc.url.pathname);
  const rol = ui.usuario?.rol;
  const tabs = ui.listo
    ? PESTANAS_MOVIL.map((r) => RUTAS.find((x) => x.ruta === r)!)
        .filter((r) => puede(rol, r.roles))
        .slice(0, 4)
    : PESTANAS_MOVIL.slice(0, 4).map((r) => RUTAS.find((x) => x.ruta === r)!);
  const mas = RUTAS.find((r) => r.ruta === "/mas")!;
  const todas = [...tabs, mas];
  return (
    <nav class="inferior" aria-label="Navegación principal">
      {todas.map((r) => {
        const activa = path === r.ruta || path.startsWith(r.ruta + "/");
        return (
          <Link key={r.ruta} href={u(r.ruta)} class={`inferior-item${activa ? " activo" : ""}`} aria-current={activa ? "page" : undefined}>
            <span class="inferior-icono">
              <Icono n={r.icono} tam={22} />
              {r.ruta === "/bandeja" && ui.contador > 0 && (
                <span class="inferior-contador" aria-label={`${ui.contador} piden acción`}>
                  {ui.contador > 99 ? "99+" : ui.contador}
                </span>
              )}
            </span>
            <span class="inferior-texto">{r.titulo}</span>
          </Link>
        );
      })}
    </nav>
  );
});

/** Barra fina bajo la barra superior cuando no hay conexión. */
export const BarraSinRed = component$(() => {
  const ui = useContext(UiCtx);
  if (ui.conectado) return null;
  return (
    <div class="sin-red" role="status">
      <Icono n="sin_red" tam={14} />
      <span>Sin conexión con el servidor. Lo que escribas se conserva y se reintenta solo.</span>
    </div>
  );
});
