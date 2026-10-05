# jsrbot · imagen del motor (Go). Contiene SOLO dos binarios: /motor (API interna + vigía + outbox)
# y /semilla (datos sintéticos). Se construye con el contexto en backend/:
#
#   docker build -t jsrbot/motor --build-arg VERSION=$(git rev-parse --short HEAD) backend
#
# En ejecución necesita (ver cmd/motor/main.go): DATABASE_URL, MOTOR_CLAVE (>= 16 caracteres) y,
# opcionalmente, JSR_CH_* (ClickHouse). La carpeta analitica/ (catalogo.json, golden/, esquema.sql)
# se monta de solo lectura en /analitica. La API escucha en :8090 y NO se publica fuera de la red
# del compose.
#
#   docker run --rm -e DATABASE_URL=... -e MOTOR_CLAVE=... -v ./analitica:/analitica:ro jsrbot/motor
#   docker run --rm --entrypoint /semilla -e DATABASE_URL=... jsrbot/motor -limpiar

FROM golang:1.27-bookworm AS construir
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-trimpath
# Primero las dependencias: la capa se reutiliza mientras no cambie go.mod/go.sum.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN go build -ldflags="-s -w -X main.version=${VERSION}" -o /out/motor ./cmd/motor \
 && go build -ldflags="-s -w" -o /out/semilla ./cmd/semilla

# Imagen final mínima, sin shell ni gestor de paquetes. La base de zonas horarias (America/Lima)
# va dentro del binario (time/tzdata), no depende de esta imagen. Corre sin ser root.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=construir /out/motor /motor
COPY --from=construir /out/semilla /semilla
ENV MOTOR_ADDR=:8090 ANALITICA_DIR=/analitica
EXPOSE 8090
USER nonroot:nonroot
# Sin shell: el motor se comprueba a sí mismo (GET /interno/salud con MOTOR_CLAVE).
HEALTHCHECK --interval=30s --timeout=6s --start-period=30s --retries=3 CMD ["/motor", "-salud"]
ENTRYPOINT ["/motor"]
