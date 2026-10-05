import { $, component$, sync$, useContext, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import { useNavigate } from "@builder.io/qwik-city";
import { buscarTodo, type GrupoBusqueda } from "~/lib/buscar";
import { atraparTab, bloquearScroll } from "~/lib/foco";
import { irA } from "~/lib/params";
import { UiCtx } from "~/lib/ui";
import { Icono } from "./icono";

/** Buscador ⌘K: hoja central con resultados agrupados (incidencias, personas, artículos, reportes y secciones),
 *  navegable con teclado: ↑ ↓ para moverse, ↵ para ir, Escape para cerrar. */
export const Buscador = component$(() => {
  const ui = useContext(UiCtx);
  const nav = useNavigate();
  const q = useSignal("");
  const idx = useSignal(0);
  const ref = useSignal<HTMLElement>();
  const campo = useSignal<HTMLInputElement>();
  const res = useStore<{ grupos: GrupoBusqueda[]; cargando: boolean }>({ grupos: [], cargando: false }, { deep: false });
  const seq = useSignal(0);

  const cerrar = $(() => {
    ui.buscadorAbierto = false;
    q.value = "";
    idx.value = 0;
  });

  const ir = $(async (destino: string) => {
    await cerrar();
    await irA(nav, destino);
  });

  // Búsqueda con espera de 180 ms.
  useVisibleTask$(({ track, cleanup }) => {
    const abierto = track(() => ui.buscadorAbierto);
    const texto = track(() => q.value);
    if (!abierto) return;
    const n = ++seq.value;
    res.cargando = texto.trim().length >= 2;
    const t = setTimeout(
      async () => {
        const g = await buscarTodo(texto, ui.usuario?.rol);
        if (n !== seq.value) return;
        res.grupos = g;
        res.cargando = false;
        idx.value = 0;
      },
      texto ? 180 : 0,
    );
    cleanup(() => clearTimeout(t));
  });

  // Foco, trampa de Tab, Escape y bloqueo de scroll mientras está abierto.
  useVisibleTask$(({ track, cleanup }) => {
    const abierto = track(() => ui.buscadorAbierto);
    if (!abierto) return;
    const el = ref.value;
    if (!el) return;
    const previo = document.activeElement as HTMLElement | null;
    const soltar = bloquearScroll();
    const quitar = atraparTab(el);
    const tecla = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        cerrar();
      }
    };
    el.addEventListener("keydown", tecla);
    campo.value?.focus();
    cleanup(() => {
      el.removeEventListener("keydown", tecla);
      quitar();
      soltar();
      if (previo && document.contains(previo)) previo.focus({ preventScroll: true });
    });
  });

  if (!ui.buscadorAbierto) return null;

  const plano = res.grupos.flatMap((g) => g.items);
  const activo = plano[idx.value];

  return (
    <div class="buscador-capa">
      <div class="buscador-velo" aria-hidden="true" onClick$={cerrar} />
      <div class="buscador" role="dialog" aria-modal="true" aria-label="Buscar" ref={ref} tabIndex={-1}>
        <div class="buscador-campo">
          <Icono n="buscar" tam={18} />
          <input
            ref={campo}
            type="search"
            role="combobox"
            aria-expanded="true"
            aria-controls="buscador-lista"
            aria-activedescendant={activo ? `bus-${activo.id}` : undefined}
            aria-label="Buscar incidencias, personas, artículos y reportes"
            placeholder="Buscar incidencias, personas, artículos…"
            autoComplete="off"
            value={q.value}
            onInput$={(_, el) => (q.value = el.value)}
            onKeyDown$={[
              sync$((e: KeyboardEvent) => {
                // Las flechas y Enter no deben mover el cursor ni enviar nada.
                if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Enter") e.preventDefault();
              }),
              $((e: KeyboardEvent) => {
                if (e.key === "ArrowDown") idx.value = plano.length ? (idx.value + 1) % plano.length : 0;
                else if (e.key === "ArrowUp") idx.value = plano.length ? (idx.value - 1 + plano.length) % plano.length : 0;
                else if (e.key === "Enter" && activo) ir(activo.ir);
              }),
            ]}
          />
          <kbd class="buscar-tecla" aria-hidden="true">
            esc
          </kbd>
        </div>
        <div class="buscador-lista" id="buscador-lista" role="listbox" aria-label="Resultados">
          {res.cargando && <p class="buscador-estado">Buscando…</p>}
          {!res.cargando && q.value.trim().length >= 2 && plano.every((r) => r.id.startsWith("ir-")) && (
            <p class="buscador-estado">No hay resultados para «{q.value.trim()}». Prueba con el número (INC-000142) o con una palabra del asunto.</p>
          )}
          {res.grupos.map((g) => (
            <div class="buscador-grupo" key={g.titulo} role="group" aria-label={g.titulo}>
              <p class="buscador-grupo-titulo">{g.titulo}</p>
              {g.items.map((r) => (
                <button
                  key={r.id}
                  type="button"
                  id={`bus-${r.id}`}
                  role="option"
                  aria-selected={activo?.id === r.id}
                  tabIndex={-1}
                  class={`buscador-item${activo?.id === r.id ? " activo" : ""}`}
                  onClick$={() => ir(r.ir)}
                  onMouseMove$={() => {
                    const i = plano.findIndex((x) => x.id === r.id);
                    if (i >= 0 && i !== idx.value) idx.value = i;
                  }}
                >
                  <span class="buscador-item-titulo">{r.titulo}</span>
                  {r.detalle && <span class="buscador-item-detalle">{r.detalle}</span>}
                </button>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
});
