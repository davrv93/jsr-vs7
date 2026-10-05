#!/usr/bin/env bash
# Ejecuta un comando dentro de la imagen de cimientos, con el codigo montado y un volumen persistente para _build.
# Uso: scripts/en-cimientos.sh dune build
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
IMAGEN="${CIMIENTOS:-jsr/pasarela-cimientos:local}"
exec docker run --rm -v "$AQUI":/w -v jsr-pasarela-build:/home/opam/_build ${DOCKER_EXTRA:-} -w /w -e DUNE_BUILD_DIR=/home/opam/_build "$IMAGEN" "$@"
