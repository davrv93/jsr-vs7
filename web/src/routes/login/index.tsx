import { $, component$, useSignal, useVisibleTask$ } from "@builder.io/qwik";
import { useLocation, useNavigate, type DocumentHead } from "@builder.io/qwik-city";
import { Campo } from "~/components/ui/campo";
import { api, mensajeError } from "~/lib/api";
import { getToken, getUsuario, guardarSesion, type Usuario } from "~/lib/auth";
import { u } from "~/lib/base";
import { inicioPara } from "~/lib/rutas";

const rutaSegura = (v: string | null): string | null => (v && v.startsWith("/") && !v.startsWith("//") ? v : null);

/** 01 · Inicio de sesión. ¿Quién eres? Una sola acción: Continuar. */
export default component$(() => {
  const loc = useLocation();
  const nav = useNavigate();
  const correo = useSignal("");
  const clave = useSignal("");
  const verClave = useSignal(false);
  const errorCorreo = useSignal("");
  const errorClave = useSignal("");
  const errorGeneral = useSignal("");
  const enviando = useSignal(false);
  const expiro = loc.url.searchParams.get("expiro") === "1";

  // Quien ya tiene sesión no necesita ver el formulario.
  // eslint-disable-next-line qwik/no-use-visible-task
  useVisibleTask$(
    () => {
      const usuario = getUsuario();
      if (getToken() && usuario) nav(u(inicioPara(usuario.rol)), { replaceState: true });
    },
    { strategy: "document-ready" },
  );

  const entrar = $(async () => {
    errorCorreo.value = "";
    errorClave.value = "";
    errorGeneral.value = "";
    const c = correo.value.trim();
    if (!c) errorCorreo.value = "Escribe tu correo.";
    else if (!/^\S+@\S+\.\S+$/.test(c)) errorCorreo.value = "Ese correo no parece válido. Revisa que tenga @ y un dominio.";
    if (!clave.value) errorClave.value = "Escribe tu clave.";
    if (errorCorreo.value || errorClave.value) {
      // El foco va al primer campo con error.
      (document.getElementById(errorCorreo.value ? "c-correo" : "c-clave") as HTMLElement | null)?.focus();
      return;
    }
    enviando.value = true;
    try {
      const r = await api<{ token: string; usuario: Usuario }>("/api/auth/login", { method: "POST", json: { email: c, clave: clave.value }, publico: true });
      guardarSesion(r.token, r.usuario);
      const volver = rutaSegura(new URLSearchParams(location.search).get("volver"));
      await nav(u(volver ?? inicioPara(r.usuario.rol)));
    } catch (e) {
      errorGeneral.value = mensajeError(e);
      clave.value = "";
      (document.getElementById("c-clave") as HTMLElement | null)?.focus();
    } finally {
      enviando.value = false;
    }
  });

  return (
    <main class="login">
      <form class="login-form" preventdefault:submit onSubmit$={entrar} noValidate>
        <div class="login-marca" aria-hidden="true">
          <span class="lateral-sello login-sello">j</span>
        </div>
        <h1 class="login-titulo">Inicia sesión</h1>
        <p class="login-sub">Consola de la mesa de ayuda</p>

        {expiro && !errorGeneral.value && (
          <p class="login-aviso" role="status">
            Tu sesión expiró. Vuelve a entrar para seguir.
          </p>
        )}
        {errorGeneral.value && (
          <p class="login-error" role="alert">
            {errorGeneral.value}
          </p>
        )}

        <Campo etiqueta="Correo" nombre="correo" tipo="email" valor={correo.value} onValor$={(v) => (correo.value = v)} error={errorCorreo.value} autocompletar="username" modo="email" />
        <div class="campo-clave">
          <Campo etiqueta="Clave" nombre="clave" tipo={verClave.value ? "text" : "password"} valor={clave.value} onValor$={(v) => (clave.value = v)} error={errorClave.value} autocompletar="current-password" />
          <button type="button" class="boton boton-secundario boton-pequeno campo-clave-ver" aria-pressed={verClave.value} onClick$={() => (verClave.value = !verClave.value)}>
            {verClave.value ? "Ocultar" : "Mostrar"}
          </button>
        </div>

        <button type="submit" class="boton boton-principal boton-bloque login-boton" disabled={enviando.value} aria-busy={enviando.value ? "true" : undefined}>
          Continuar
        </button>
      </form>
    </main>
  );
});

export const head: DocumentHead = { title: "Iniciar sesión · jsrbot" };
