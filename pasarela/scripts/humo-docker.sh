#!/usr/bin/env bash
# `make humo`: compila, arranca un Postgres efimero y corre scripts/humo.sh dentro de la imagen de cimientos.
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AQUI"
export CIMIENTOS="${CIMIENTOS:-jsr/pasarela-cimientos:local}"
cleanup() { "$AQUI/scripts/pg-pruebas.sh" parar >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$AQUI/scripts/en-cimientos.sh" dune build ./bin/main.exe ./test/falsos/falsos_main.exe
URL="$("$AQUI/scripts/pg-pruebas.sh" arrancar)"
DOCKER_EXTRA="--network container:jsr-pasarela-pg -e DATABASE_URL=${URL}" \
  "$AQUI/scripts/en-cimientos.sh" bash scripts/humo.sh
