#!/usr/bin/env bash
# Prueba de punta a punta con los servicios REALES (motor Go + agente Python + pasarela) sobre un Postgres efimero.
# NO es parte de `make probar` (depende de las imagenes de los otros servicios). Requisitos: imagenes locales
#   MOTOR_IMAGEN  (por defecto jsrbot/motor:prueba)        = docker build -t jsrbot/motor:prueba backend
#   AGENTE_IMAGEN (por defecto jsrbot_agente:prueba)       = docker build -t jsrbot_agente:prueba agente
# Evolution va simulado: no se envia nada a WhatsApp. ClickHouse no se levanta: las golden queries contestan «no configurado».
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
RAIZ="$(cd "$AQUI/.." && pwd)"
cd "$AQUI"
export CIMIENTOS="${CIMIENTOS:-jsr/pasarela-cimientos:local}"
MOTOR_IMAGEN="${MOTOR_IMAGEN:-jsrbot/motor:prueba}"
AGENTE_IMAGEN="${AGENTE_IMAGEN:-jsrbot_agente:prueba}"
for img in "$MOTOR_IMAGEN" "$AGENTE_IMAGEN"; do
  docker image inspect "$img" >/dev/null 2>&1 || { echo "falta la imagen $img (ver el encabezado de este script)" >&2; exit 1; }
done
MOTOR_CLAVE="clave-motor-e2e-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
DSN_MOTOR="postgres://postgres:prueba@localhost:5432/jsr_test?sslmode=disable"

cleanup() {
  docker rm -f jsr-e2e-motor jsr-e2e-agente >/dev/null 2>&1 || true
  "$AQUI/scripts/pg-pruebas.sh" parar >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

"$AQUI/scripts/en-cimientos.sh" dune build ./bin/main.exe
# Base VACIA: el motor aplica su propio esquema (backend/migrations) y siembra la configuracion por defecto.
SIN_MIGRACIONES=1 "$AQUI/scripts/pg-pruebas.sh" arrancar >/dev/null
docker run -d --name jsr-e2e-motor --network container:jsr-pasarela-pg -e DATABASE_URL="$DSN_MOTOR" -e MOTOR_CLAVE="$MOTOR_CLAVE" \
  -e MOTOR_ADDR=":8090" -v "$RAIZ/analitica:/analitica:ro" "$MOTOR_IMAGEN" >/dev/null
for i in $(seq 1 40); do
  docker run --rm --network container:jsr-pasarela-pg curlimages/curl -s -o /dev/null -H "X-Interno-Clave: $MOTOR_CLAVE" http://127.0.0.1:8090/interno/salud && break
  sleep 1
done
docker run --rm --entrypoint /semilla --network container:jsr-pasarela-pg -e DATABASE_URL="$DSN_MOTOR" "$MOTOR_IMAGEN" -limpiar -incidencias 60 >/dev/null 2>&1
docker run -d --name jsr-e2e-agente --network container:jsr-pasarela-pg "$AGENTE_IMAGEN" >/dev/null
for i in $(seq 1 60); do
  docker run --rm --network container:jsr-pasarela-pg curlimages/curl -s -o /dev/null -f http://127.0.0.1:8000/salud && break
  sleep 1
done

DOCKER_EXTRA="--network container:jsr-pasarela-pg -e DATABASE_URL=postgresql://postgres:prueba@localhost:5432/jsr_test -e MOTOR_CLAVE=$MOTOR_CLAVE" \
  "$AQUI/scripts/en-cimientos.sh" bash scripts/e2e.sh
