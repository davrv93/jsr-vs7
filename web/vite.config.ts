import { defineConfig } from "vite";
import { qwikVite } from "@builder.io/qwik/optimizer";
import { qwikCity } from "@builder.io/qwik-city/vite";
import tsconfigPaths from "vite-tsconfig-paths";

// En desarrollo, /api va al backend (por defecto el mock de web/mock/servidor.mjs, puerto 5599).
const backend = process.env.BACKEND_URL ?? "http://localhost:5599";

export default defineConfig(() => ({
  // "/" o, detrás de un alias de nginx, p. ej. "/jsrbot/" (Dockerfile: ARG BASE_PATH).
  base: process.env.BASE_PATH || "/",
  plugins: [qwikCity({ trailingSlash: (process.env.BASE_PATH || "/") !== "/" }), qwikVite({ devTools: { clickToSource: false } }), tsconfigPaths()],
  server: {
    port: 5173,
    proxy: {
      "/api": { target: backend, changeOrigin: true },
    },
  },
  preview: {
    headers: { "Cache-Control": "public, max-age=600" },
  },
}));
