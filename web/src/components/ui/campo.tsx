import { component$, type QRL } from "@builder.io/qwik";

interface CampoProps {
  etiqueta: string;
  nombre: string;
  valor: string;
  tipo?: "text" | "email" | "tel" | "number" | "password" | "date" | "time" | "search";
  filas?: number;
  error?: string;
  ayuda?: string;
  requerido?: boolean;
  opcional?: boolean;
  autocompletar?: string;
  marcador?: string;
  deshabilitado?: boolean;
  modo?: "numeric" | "text" | "email" | "tel" | "decimal";
  class?: string;
  onValor$: QRL<(valor: string) => void>;
  onBlur$?: QRL<() => void>;
}

/** Campo con etiqueta arriba (nunca el marcador como etiqueta), ayuda y error enlazados con aria-describedby. */
export const Campo = component$<CampoProps>((p) => {
  const idc = `c-${p.nombre}`;
  const desc = p.error ? `${idc}-e` : p.ayuda ? `${idc}-a` : undefined;
  return (
    <div class={`campo${p.error ? " con-error" : ""} ${p.class ?? ""}`}>
      <label class="campo-etiqueta" for={idc}>
        {p.etiqueta}
        {p.opcional && <span class="campo-opcional"> · opcional</span>}
      </label>
      {p.filas ? (
        <textarea
          id={idc}
          name={p.nombre}
          rows={p.filas}
          value={p.valor}
          placeholder={p.marcador}
          required={p.requerido}
          disabled={p.deshabilitado}
          aria-invalid={p.error ? "true" : undefined}
          aria-describedby={desc}
          onInput$={(_, el) => p.onValor$(el.value)}
          onBlur$={p.onBlur$}
        />
      ) : (
        <input
          id={idc}
          name={p.nombre}
          type={p.tipo ?? "text"}
          value={p.valor}
          placeholder={p.marcador}
          required={p.requerido}
          disabled={p.deshabilitado}
          autoComplete={p.autocompletar}
          inputMode={p.modo}
          aria-invalid={p.error ? "true" : undefined}
          aria-describedby={desc}
          onInput$={(_, el) => p.onValor$(el.value)}
          onBlur$={p.onBlur$}
        />
      )}
      {p.error ? (
        <p class="campo-error" id={`${idc}-e`}>
          {p.error}
        </p>
      ) : p.ayuda ? (
        <p class="campo-ayuda" id={`${idc}-a`}>
          {p.ayuda}
        </p>
      ) : null}
    </div>
  );
});

interface SelectorProps {
  etiqueta: string;
  nombre: string;
  valor: string;
  opciones: { valor: string; titulo: string }[];
  ayuda?: string;
  deshabilitado?: boolean;
  class?: string;
  onValor$: QRL<(valor: string) => void>;
}

export const Selector = component$<SelectorProps>((p) => {
  const idc = `s-${p.nombre}`;
  return (
    <div class={`campo ${p.class ?? ""}`}>
      <label class="campo-etiqueta" for={idc}>
        {p.etiqueta}
      </label>
      <select id={idc} name={p.nombre} disabled={p.deshabilitado} onChange$={(_, el) => p.onValor$(el.value)} aria-describedby={p.ayuda ? `${idc}-a` : undefined}>
        {p.opciones.map((o) => (
          <option key={o.valor} value={o.valor} selected={o.valor === p.valor}>
            {o.titulo}
          </option>
        ))}
      </select>
      {p.ayuda && (
        <p class="campo-ayuda" id={`${idc}-a`}>
          {p.ayuda}
        </p>
      )}
    </div>
  );
});

interface InterruptorProps {
  etiqueta: string;
  activo: boolean;
  deshabilitado?: boolean;
  onCambio$: QRL<(v: boolean) => void>;
}

/** Interruptor tipo iOS (role=switch). La etiqueta va fuera, en la fila; aquí solo el nombre accesible. */
export const Interruptor = component$<InterruptorProps>((p) => (
  <button
    type="button"
    role="switch"
    class={`interruptor${p.activo ? " activo" : ""}`}
    aria-checked={p.activo}
    aria-label={p.etiqueta}
    disabled={p.deshabilitado}
    onClick$={() => p.onCambio$(!p.activo)}
  >
    <span class="interruptor-bola" />
  </button>
));

interface CampoHoraProps {
  /** Nombre accesible (no hay etiqueta visible: va en una fila con el día). */
  etiqueta: string;
  valor: string;
  id?: string;
  invalido?: boolean;
  deshabilitado?: boolean;
  onValor$: QRL<(valor: string) => void>;
}

/** Hora de 24 h «HH:mm». Un `<input type="time">` pinta 12 horas en es-PE y corta el «p. m.»; los horarios de la mesa se
 *  escriben y se leen en 24 h. Acepta «8», «830» o «08:30» y lo deja como «08:30» al salir del campo. */
export const CampoHora = component$<CampoHoraProps>((p) => (
  <input
    id={p.id}
    class="campo-hora"
    type="text"
    inputMode="numeric"
    autoComplete="off"
    maxLength={5}
    placeholder="hh:mm"
    aria-label={p.etiqueta}
    aria-invalid={p.invalido ? "true" : undefined}
    disabled={p.deshabilitado}
    value={p.valor}
    onInput$={(_, el) => {
      const d = el.value.replace(/\D/g, "").slice(0, 4);
      const v = d.length >= 3 ? `${d.slice(0, 2)}:${d.slice(2)}` : d;
      if (v !== el.value) el.value = v;
      p.onValor$(v);
    }}
    onBlur$={(_, el) => {
      const d = el.value.replace(/\D/g, "");
      if (!d) return;
      const h = d.length <= 2 ? d.padStart(2, "0") : d.slice(0, d.length - 2).padStart(2, "0");
      const m = d.length <= 2 ? "00" : d.slice(-2);
      const v = `${h}:${m}`;
      el.value = v;
      p.onValor$(v);
    }}
  />
));

/** ¿Es «HH:mm» válida de 24 h? */
export const horaValida = (v: string): boolean => /^([01]\d|2[0-3]):[0-5]\d$/.test(v);
