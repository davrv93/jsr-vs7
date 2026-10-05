#!/usr/bin/env bash
# Postgres efimero para las pruebas de integracion y el humo. Usa la imagen local postgres:16-alpine, aplica
# backend/migrations/*.sql (el esquema del contrato) y NO publica ningun puerto. Los contenedores de prueba se unen a
# su red con `--network container:jsr-pasarela-pg` y lo ven en localhost:5432 (no se crea una red propia: el
# Docker de esta maquina ya agoto sus rangos de direcciones).
#
#   scripts/pg-pruebas.sh arrancar   crea la red y el contenedor, espera y aplica las migraciones
#   scripts/pg-pruebas.sh parar      lo apaga y lo borra
#   scripts/pg-pruebas.sh url        imprime el DSN para otros contenedores de la red
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
MIGRACIONES="$AQUI/../backend/migrations"
NOMBRE=jsr-pasarela-pg
CLAVE=prueba          # clave de un contenedor desechable sin puertos publicados; no protege nada real
DB=jsr_test
URL="postgresql://postgres:${CLAVE}@localhost:5432/${DB}"

case "${1:-}" in
  arrancar)
    docker rm -f "$NOMBRE" >/dev/null 2>&1 || true
    # PUBLICAR=127.0.0.1:18080:8080 publica ESE puerto del espacio de red compartido (para usar la consola web contra la pasarela).
    docker run -d --rm --name "$NOMBRE" --tmpfs /var/lib/postgresql/data ${PUBLICAR:+-p "$PUBLICAR"} \
      -e POSTGRES_PASSWORD="$CLAVE" -e POSTGRES_DB="$DB" \
      postgres:16-alpine -c fsync=off -c synchronous_commit=off -c full_page_writes=off >/dev/null
    for i in $(seq 1 60); do
      if docker exec "$NOMBRE" pg_isready -U postgres -d "$DB" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    # pg_isready contesta antes de que termine el arranque definitivo: se confirma con una consulta.
    for i in $(seq 1 30); do
      if docker exec "$NOMBRE" psql -U postgres -d "$DB" -c 'select 1' >/dev/null 2>&1; then break; fi
      sleep 1
    done
    # SIN_MIGRACIONES=1: base vacia (la prueba de punta a punta deja que el MOTOR real aplique su propio esquema).
    if [ "${SIN_MIGRACIONES:-0}" != "1" ]; then
      for f in $(ls "$MIGRACIONES"/*.sql | sort); do
        docker exec -i "$NOMBRE" psql -q -v ON_ERROR_STOP=1 -U postgres -d "$DB" < "$f" >/dev/null
      done
    fi
    echo "$URL"
    ;;
  parar)
    docker rm -f "$NOMBRE" >/dev/null 2>&1 || true
    ;;
  url)
    echo "$URL"
    ;;
  *)
    echo "uso: $0 arrancar|parar|url" >&2
    exit 2
    ;;
esac
