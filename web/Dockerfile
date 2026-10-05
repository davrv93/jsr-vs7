# Consola de jsrbot: build estático de Qwik + nginx que sirve el sitio y enruta /api al backend.
#
#   docker build -t jsrbot-web .
#   docker build -t jsrbot-web --build-arg BASE_PATH=/jsrbot/ .     (detrás de un alias de nginx)
#   docker run -p 8081:80 -e BACKEND_URL=http://backend:8080 jsrbot-web
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
ARG PUBLIC_URL=http://localhost:8081
ENV PUBLIC_URL=${PUBLIC_URL}
# Ruta base: "/" o, detrás de un alias de nginx, p. ej. "/jsrbot/".
ARG BASE_PATH=/
ENV BASE_PATH=${BASE_PATH}
# Origen de la API si no es el mismo del sitio (vacío = mismo origen, que es lo normal con el proxy de abajo).
ARG VITE_API_BASE=
ENV VITE_API_BASE=${VITE_API_BASE}
RUN npm run build \
 # Con ruta base, Qwik deja el sitio en dist/<base>/: se sube a la raíz, porque el alias de nginx quita el prefijo
 # antes de llegar a este contenedor.
 && if [ "$BASE_PATH" != "/" ]; then mv "dist/${BASE_PATH#/}" /tmp/site && rm -rf dist && mv /tmp/site dist; fi

FROM nginx:1.29-alpine
ENV BACKEND_URL=http://backend:8080
# Hace que el entrypoint de nginx exporte NGINX_LOCAL_RESOLVERS (los DNS de /etc/resolv.conf) para la plantilla.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=60s --timeout=5s --start-period=5s --retries=3 CMD wget -qO- http://127.0.0.1/healthz || exit 1
