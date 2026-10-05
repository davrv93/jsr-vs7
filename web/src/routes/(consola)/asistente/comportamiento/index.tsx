import { $, component$, useSignal, useStore, useVisibleTask$ } from "@builder.io/qwik";
import type { DocumentHead } from "@builder.io/qwik-city";
import { Boton } from "~/components/ui/boton";
import { Campo, Interruptor } from "~/components/ui/campo";
import { EsqueletoFilas } from "~/components/ui/esqueleto";
import { Fila, Grupo } from "~/components/ui/grupo";
import { Segmentado } from "~/components/ui/segmentado";
import { Falla } from "~/components/ui/vacio";
import { api, mensajeError } from "~/lib/api";
import { useAccionBarra } from "~/lib/barra";
import { u } from "~/lib/base";
import { useRecurso } from "~/lib/recurso";
import type { ConfigAsistente } from "~/lib/tipos";
import { toast, useDialog } from "~/lib/ui";

const JUEZ = {
  apagado: "Jev local no revisa nada. El asistente responde sin segunda opinión.",
  sombra: "Jev local revisa cada respuesta y lo registra, pero no cambia lo que se envía. Es el modo para medir antes de encender.",
  activo: "Jev local quita lo que no está respaldado por la fuente antes de enviar. Solo después de medirlo en sombra.",
};

interface Form {
  nombre: string;
  trato: string;
  saludo: string;
  umbral: string;
  pasos: string;
  juez: string;
  puede: ConfigAsistente["puede"];
  errores: Record<string, string>;
  guardando: boolean;
}

/** 11 · Asistente · Comportamiento. ¿Cómo habla y qué puede hacer? Acción principal: Guardar y probar. */
export default component$(() => {
  const { r, recargar } = useRecurso<ConfigAsistente>("/api/asistente/config", { eventos: false });
  const dialog = useDialog();
  const listo = useSignal(false);
  const f = useStore<Form>({
    nombre: "",
    trato: "tu",
    saludo: "",
    umbral: "0.7",
    pasos: "4",
    juez: "sombra",
    puede: { crear_incidencias: true, consultar_estado: true, pedir_encuesta: true, resolver_clave: false },
    errores: {},
    guardando: false,
  });

  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    ({ track }) => {
      const d = track(() => r.datos);
      if (!d || listo.value) return;
      listo.value = true;
      f.nombre = d.nombre;
      f.trato = d.trato;
      f.saludo = d.saludo;
      f.umbral = String(d.umbral_confianza);
      f.pasos = String(d.maximo_pasos_guia);
      f.juez = d.juez_modo;
      f.puede = { ...d.puede };
    },
    { strategy: "document-ready" },
  );

  const guardarYProbar = $(async () => {
    const e: Record<string, string> = {};
    if (!f.nombre.trim()) e.nombre = "El asistente necesita un nombre.";
    if (!f.saludo.trim()) e.saludo = "Escribe el saludo con el que empieza cada conversación.";
    const um = Number(f.umbral);
    if (!(um >= 0.3 && um <= 0.95)) e.umbral = "El umbral va entre 0.30 y 0.95.";
    const pa = Number(f.pasos);
    if (!(Number.isInteger(pa) && pa >= 1 && pa <= 8)) e.pasos = "Entre 1 y 8 pasos.";
    f.errores = e;
    const primero = Object.keys(e)[0];
    if (primero) {
      document.getElementById(`c-cmp-${primero}`)?.focus();
      toast("Hay datos por corregir.", "error");
      return;
    }
    f.guardando = true;
    try {
      await api("/api/asistente/config", {
        method: "PUT",
        json: { nombre: f.nombre.trim(), trato: f.trato, saludo: f.saludo.trim(), umbral_confianza: um, maximo_pasos_guia: pa, juez_modo: f.juez, puede: f.puede },
      });
      toast("Guardado. Abriendo el chat de prueba…", "ok");
      window.open(u("/chat"), "_blank", "noopener");
    } catch (er) {
      await dialog.alert({ icono: "⚠️", titulo: "No se pudo guardar", texto: `${mensajeError(er)} Tus cambios siguen en pantalla.` });
    } finally {
      f.guardando = false;
    }
  });
  useAccionBarra("Guardar y probar", guardarYProbar, "Guardar");

  if (r.estado === "cargando" && !r.datos) {
    return (
      <div class="pagina pagina-agrupada">
        <div class="pagina-interior">
          <EsqueletoFilas n={6} />
        </div>
      </div>
    );
  }
  if (r.estado === "error" && !r.datos) {
    return (
      <div class="pagina pagina-agrupada">
        <div class="pagina-interior">
          <Falla titulo="No pudimos cargar la configuración del asistente." texto={r.error} sinRed={r.sinRed} onReintentar$={recargar} />
        </div>
      </div>
    );
  }
  return (
    <div class="pagina pagina-agrupada">
      <form class="pagina-interior" preventdefault:submit onSubmit$={guardarYProbar} noValidate>
        <Grupo titulo="Nombre y trato">
          <div class="fila-g fila-form fila-uno">
            <Campo etiqueta="Nombre" nombre="cmp-nombre" valor={f.nombre} onValor$={(v) => (f.nombre = v)} error={f.errores.nombre} />
            <div class="campo">
              <span class="campo-etiqueta">Trato</span>
              <Segmentado
                etiqueta="Trato"
                valor={f.trato}
                onCambio$={(v) => (f.trato = v)}
                opciones={[
                  { valor: "tu", titulo: "Tú" },
                  { valor: "usted", titulo: "Usted" },
                ]}
              />
            </div>
            <Campo etiqueta="Saludo" nombre="cmp-saludo" filas={3} valor={f.saludo} onValor$={(v) => (f.saludo = v)} error={f.errores.saludo} ayuda="Es lo primero que lee la persona. Breve y sin prometer plazos." />
          </div>
        </Grupo>

        <Grupo titulo="Qué puede hacer" pie="El asistente nunca promete plazos que no salgan del SLA ni cierra una incidencia sin confirmación.">
          <Fila titulo="Abrir incidencias" detalle="Cuando la guía no resuelve o la persona pide un técnico.">
            <Interruptor etiqueta="Abrir incidencias" activo={f.puede.crear_incidencias} onCambio$={(v) => (f.puede = { ...f.puede, crear_incidencias: v })} />
          </Fila>
          <Fila titulo="Informar el estado" detalle="Número, técnico y plazo de las incidencias de la persona.">
            <Interruptor etiqueta="Informar el estado" activo={f.puede.consultar_estado} onCambio$={(v) => (f.puede = { ...f.puede, consultar_estado: v })} />
          </Fila>
          <Fila titulo="Pedir la encuesta al cerrar" detalle="Una nota del 1 al 5 cuando se confirma la solución.">
            <Interruptor etiqueta="Pedir la encuesta" activo={f.puede.pedir_encuesta} onCambio$={(v) => (f.puede = { ...f.puede, pedir_encuesta: v })} />
          </Fila>
          <Fila titulo="Restablecer claves" detalle="Todavía no: requiere la integración con el directorio.">
            <Interruptor etiqueta="Restablecer claves" activo={f.puede.resolver_clave} deshabilitado onCambio$={() => undefined} />
          </Fila>
        </Grupo>

        <Grupo titulo="Cuándo duda">
          <div class="fila-g fila-form">
            <Campo etiqueta="Umbral de confianza" nombre="cmp-umbral" tipo="number" modo="decimal" valor={f.umbral} onValor$={(v) => (f.umbral = v)} error={f.errores.umbral} ayuda="Por debajo, el asistente pregunta en vez de asumir. Entre 0.30 y 0.95." />
            <Campo etiqueta="Pasos máximos de la guía" nombre="cmp-pasos" tipo="number" modo="numeric" valor={f.pasos} onValor$={(v) => (f.pasos = v)} error={f.errores.pasos} ayuda="Después de estos pasos, ofrece abrir una incidencia." />
          </div>
        </Grupo>

        <Grupo titulo="Jev local" pie={JUEZ[f.juez as keyof typeof JUEZ]}>
          <div class="fila-g">
            <Segmentado
              etiqueta="Modo de Jev local"
              valor={f.juez}
              onCambio$={(v) => (f.juez = v)}
              opciones={[
                { valor: "apagado", titulo: "Apagado" },
                { valor: "sombra", titulo: "Sombra" },
                { valor: "activo", titulo: "Activo" },
              ]}
            />
          </div>
        </Grupo>

        <div class="ajustes-guardar solo-movil-ancho">
          <Boton variante="principal" tipo="submit" cargando={f.guardando}>
            Guardar y probar
          </Boton>
        </div>
      </form>
    </div>
  );
});

export const head: DocumentHead = { title: "Comportamiento del asistente · jsrbot" };
