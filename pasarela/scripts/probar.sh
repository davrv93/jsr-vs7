#!/usr/bin/env bash
# `make probar`: compila y corre TODAS las pruebas (unitarias, de flujo y de la API) dentro de la imagen de cimientos, contra un
# Postgres efimero (postgres:16-alpine local) con el esquema de backend/migrations. Nada se instala en la maquina ni se publica
# ningun puerto. Sale con el codigo de dune: 0 = todo en verde.
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AQUI"

docker image inspect "${CIMIENTOS:-jsr/pasarela-cimientos:local}" >/dev/null 2>&1 || { echo "falta la imagen de cimientos: corre 'make cimientos'" >&2; exit 1; }

cleanup() { "$AQUI/scripts/pg-pruebas.sh" parar >/dev/null 2>&1 || true; }
trap cleanup EXIT
URL="$("$AQUI/scripts/pg-pruebas.sh" arrancar)"

export DOCKER_EXTRA="--network container:jsr-pasarela-pg -e JSR_TEST_DB=${URL}"
# -j 1: los tests de integracion y de API comparten la misma base de prueba (cada uno la vacia al empezar).
# --force: que se vuelvan a correr aunque dune crea que no cambiaron.
"$AQUI/scripts/en-cimientos.sh" dune test --force -j 1 2>&1
