import { $, component$, useContext, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import { atraparTab, bloquearScroll, focalizables } from "~/lib/foco";
import { AnunciosCtx, cerrarAviso, registrarAnuncios, resolverDialogo, type DialogoItem } from "~/lib/ui";
import { Icono } from "./icono";

/** Diálogo propio (alert / confirm / prompt / elegir). Reemplaza a window.alert, confirm y prompt: se puede estilar,
 *  tiene foco atrapado, cierra con Escape y se apila sobre hojas y otros diálogos. */
export const Dialogo = component$<{ d: DialogoItem; activo: boolean }>((p) => {
  const ref = useSignal<HTMLElement>();
  const campo = useSignal(p.d.valor ?? "");
  const error = useSignal("");

  const cerrar = $((valor: unknown) => resolverDialogo(p.d.id, valor));
  const valorCancelado = (): unknown => (p.d.tipo === "alert" ? true : p.d.tipo === "confirm" ? false : null);

  const aceptar = $(() => {
    if (p.d.tipo === "prompt") {
      const v = campo.value.trim();
      if (p.d.requerido && !v) {
        error.value = "Escribe algo para continuar.";
        return;
      }
      cerrar(v);
    } else {
      cerrar(true);
    }
  });

  useVisibleTask$(
    ({ cleanup }) => {
      const el = ref.value;
      if (!el) return;
      const previo = document.activeElement as HTMLElement | null;
      const soltar = bloquearScroll();
      const quitarTab = atraparTab(el);
      const alTeclear = (e: KeyboardEvent) => {
        if (!p.activo) return;
        if (e.key === "Escape") {
          e.stopPropagation();
          e.preventDefault();
          cerrar(valorCancelado());
        } else if (e.key === "Enter" && p.d.tipo === "prompt" && !(e.target as HTMLElement).matches("textarea, button")) {
          e.preventDefault();
          aceptar();
        } else if (e.key === "Enter" && e.target instanceof HTMLTextAreaElement && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          aceptar();
        }
      };
      el.addEventListener("keydown", alTeclear);
      // Foco inicial: el campo; en confirmaciones peligrosas, «Cancelar» (lo seguro); si no, el botón principal.
      const f = focalizables(el);
      const objetivo =
        f.find((x) => x.matches("input, textarea")) ??
        (p.d.peligro ? f.find((x) => x.dataset.rol === "cancelar") : f.find((x) => x.dataset.rol === "ok")) ??
        f[0];
      (objetivo ?? el).focus({ preventScroll: true });
      cleanup(() => {
        el.removeEventListener("keydown", alTeclear);
        quitarTab();
        soltar();
        if (previo && document.contains(previo)) previo.focus({ preventScroll: true });
      });
    },
    { strategy: "document-ready" },
  );

  const d = p.d;
  return (
    <div class="dialogo-capa" aria-hidden={p.activo ? undefined : "true"}>
      <div class="dialogo-velo" onClick$={() => p.activo && d.tipo !== "alert" && cerrar(valorCancelado())} aria-hidden="true" />
      <div
        class={`dialogo${d.tipo === "elegir" ? " dialogo-elegir" : ""}`}
        role={d.tipo === "alert" ? "alertdialog" : "dialog"}
        aria-modal="true"
        aria-labelledby={`dlg-t-${d.id}`}
        aria-describedby={d.texto ? `dlg-x-${d.id}` : undefined}
        tabIndex={-1}
        ref={ref}
      >
        <div class="dialogo-cuerpo">
          {d.icono && (
            <span class="dialogo-icono" aria-hidden="true">
              {d.icono}
            </span>
          )}
          <h2 class="dialogo-titulo" id={`dlg-t-${d.id}`}>
            {d.titulo}
          </h2>
          {d.texto && (
            <p class="dialogo-texto" id={`dlg-x-${d.id}`}>
              {d.texto}
            </p>
          )}
          {d.tipo === "prompt" && (
            <div class={`campo${error.value ? " con-error" : ""}`}>
              {d.etiqueta && (
                <label class="campo-etiqueta" for={`dlg-c-${d.id}`}>
                  {d.etiqueta}
                </label>
              )}
              {d.largo ? (
                <textarea
                  id={`dlg-c-${d.id}`}
                  rows={4}
                  value={campo.value}
                  placeholder={d.placeholder}
                  aria-invalid={error.value ? "true" : undefined}
                  aria-describedby={error.value ? `dlg-e-${d.id}` : undefined}
                  onInput$={(_, el) => {
                    campo.value = el.value;
                    error.value = "";
                  }}
                />
              ) : (
                <input
                  id={`dlg-c-${d.id}`}
                  type={d.tipoCampo ?? "text"}
                  value={campo.value}
                  placeholder={d.placeholder}
                  aria-invalid={error.value ? "true" : undefined}
                  aria-describedby={error.value ? `dlg-e-${d.id}` : undefined}
                  onInput$={(_, el) => {
                    campo.value = el.value;
                    error.value = "";
                  }}
                />
              )}
              {error.value && (
                <p class="campo-error" id={`dlg-e-${d.id}`} role="alert">
                  {error.value}
                </p>
              )}
            </div>
          )}
          {d.tipo === "elegir" && (
            <ul class="dialogo-opciones" role="list">
              {d.opciones?.map((o) => (
                <li key={o.valor}>
                  <button type="button" class="dialogo-opcion" onClick$={() => cerrar(o.valor)}>
                    <span class="dialogo-opcion-titulo">{o.titulo}</span>
                    {o.detalle && <span class="dialogo-opcion-detalle">{o.detalle}</span>}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        <div class="dialogo-pie">
          {d.tipo !== "alert" && (
            <button type="button" class="boton boton-secundario" data-rol="cancelar" onClick$={() => cerrar(valorCancelado())}>
              {d.cancelar ?? "Cancelar"}
            </button>
          )}
          {d.tipo !== "elegir" && (
            <button type="button" class={`boton ${d.peligro ? "boton-peligro-lleno" : "boton-principal"}`} data-rol="ok" onClick$={aceptar}>
              {d.ok ?? "Aceptar"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
});

/** Anfitrión de avisos (toast) y de diálogos. Se monta una sola vez en la raíz. */
export const Anuncios = component$(() => {
  const st = useContext(AnunciosCtx);

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    () => {
      registrarAnuncios(st);
    },
    { strategy: "document-ready" },
  );

  const ultimo = st.dialogos.length - 1;
  return (
    <>
      <div class="avisos" role="status" aria-live="polite" aria-atomic="false">
        {st.avisos.map((a) => (
          <div key={a.id} class={`aviso aviso-${a.tipo}`}>
            {a.tipo === "error" && <Icono n="alerta" tam={16} class="aviso-icono" />}
            {a.tipo === "ok" && <Icono n="ok" tam={16} class="aviso-icono" />}
            <span>{a.texto}</span>
            <button type="button" class="aviso-cerrar" aria-label="Cerrar aviso" onClick$={() => cerrarAviso(a.id)}>
              <Icono n="cerrar" tam={14} />
            </button>
          </div>
        ))}
      </div>
      {st.dialogos.map((d, i) => (
        <Dialogo key={d.id} d={d} activo={i === ultimo} />
      ))}
    </>
  );
});
