import { component$ } from "@builder.io/qwik";
import { useDocumentHead } from "@builder.io/qwik-city";
import { u } from "~/lib/base";

// Aplica el tema guardado antes de pintar, para que no haya un destello claro en una consola oscura.
const TEMA_INICIAL = `(function(){try{var d=document.documentElement,t=localStorage.getItem('jsr_tema');if(t==='claro'||t==='oscuro')d.setAttribute('data-tema',t);if(localStorage.getItem('jsr_plegado')==='1')d.setAttribute('data-plegado','1')}catch(e){}})()`;

export const RouterHead = component$(() => {
  const head = useDocumentHead();
  return (
    <>
      <title>{head.title || "jsrbot · Mesa de ayuda"}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
      <meta name="robots" content="noindex" />
      <meta name="color-scheme" content="light dark" />
      <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)" />
      <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)" />
      <link rel="icon" type="image/svg+xml" href={u("/favicon.svg")} />
      <link rel="preconnect" href="https://fonts.googleapis.com" />
      <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
      <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" />
      <script dangerouslySetInnerHTML={TEMA_INICIAL} />
      {head.meta.map((m) => (
        <meta key={m.key} {...m} />
      ))}
    </>
  );
});
