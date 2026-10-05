#!/usr/bin/env bash
# Levanta un Postgres efímero (postgres:16-alpine), exporta JSR_TEST_DB, corre `go test ./...`
# y lo apaga al terminar (también si se interrumpe).
#
# Uso:   cd backend && ./scripts/test-db.sh [argumentos de go test]
# Ej.:   ./scripts/test-db.sh -count=1 -run Vigia ./internal/escala/...
#
# Sin argumentos corre `go test ./...`. Si el primer argumento no empieza por «-» ni es una
# ruta de paquetes (./...), se trata como argumentos extra de `go test` igualmente.
#
# Las pruebas que usan base se saltan (t.Skip) si JSR_TEST_DB no está definida; con este
# script siempre lo está. La imagen postgres:16-alpine ya debe estar en local.
#
# ClickHouse (opcional): si la imagen de ClickHouse está en local y analitica/usuarios.xml existe,
# también levanta un ClickHouse EFÍMERO con el perfil de poca memoria y los usuarios jsr (escritura)
# y analista (solo lectura) de analitica/, y exporta JSR_TEST_CH_URL, JSR_TEST_CH_USUARIO,
# JSR_TEST_CH_CLAVE, JSR_TEST_CH_ANALISTA_USUARIO y JSR_TEST_CH_ANALISTA_CLAVE. Con eso corre la
# prueba que carga el outbox de la semilla en ClickHouse y compara KPI. Sin la imagen (o con
# JSR_TEST_CH=0) esa prueba se salta. Las claves se generan al azar y nunca se imprimen.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGEN="${JSR_TEST_IMAGEN:-postgres:16-alpine}"
CLAVE="jsr_prueba_$$"          # clave efímera: el contenedor no se publica fuera de 127.0.0.1
NOMBRE="jsr-test-db-$$"

if ! command -v docker >/dev/null 2>&1; then
  echo "test-db.sh: docker no está instalado" >&2
  exit 1
fi

contenedor=""
contenedor_ch=""
apagar() {
  if [ -n "$contenedor" ]; then
    docker rm -f "$contenedor" >/dev/null 2>&1 || true
  fi
  if [ -n "$contenedor_ch" ]; then
    docker rm -f "$contenedor_ch" >/dev/null 2>&1 || true
  fi
}
trap apagar EXIT INT TERM

# -p 127.0.0.1::5432 deja que Docker elija un puerto libre del anfitrión.
contenedor="$(docker run -d --rm --name "$NOMBRE" \
  -e POSTGRES_PASSWORD="$CLAVE" \
  -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  -p 127.0.0.1::5432 \
  --tmpfs /var/lib/postgresql/data:rw \
  "$IMAGEN" \
  -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c max_connections=300)"

puerto=""
for _ in $(seq 1 30); do
  puerto="$(docker port "$contenedor" 5432/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
  [ -n "$puerto" ] && break
  sleep 0.5
done
if [ -z "$puerto" ]; then
  echo "test-db.sh: no se obtuvo el puerto del contenedor" >&2
  exit 1
fi

# Espera a que Postgres acepte conexiones (el arranque inicial reinicia el servidor una vez).
listo=0
for _ in $(seq 1 60); do
  if docker exec "$contenedor" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 \
     && docker exec -e PGPASSWORD="$CLAVE" "$contenedor" psql -U postgres -h 127.0.0.1 -tAc 'select 1' >/dev/null 2>&1; then
    listo=1
    break
  fi
  sleep 0.5
done
if [ "$listo" != 1 ]; then
  echo "test-db.sh: Postgres no quedó listo a tiempo" >&2
  docker logs "$contenedor" 2>&1 | tail -n 20 >&2 || true
  exit 1
fi

export JSR_TEST_DB="postgres://postgres:${CLAVE}@127.0.0.1:${puerto}/postgres?sslmode=disable"
echo "test-db.sh: Postgres efímero en 127.0.0.1:${puerto} (contenedor ${NOMBRE})"

# ---- ClickHouse efímero (opcional) ---------------------------------------------------------------------
CH_IMAGEN="${JSR_CH_IMAGEN:-clickhouse/clickhouse-server:26.9.10.4-alpine}"
AN="$(cd .. && pwd)/analitica"
if [ "${JSR_TEST_CH:-auto}" != "0" ] && [ -f "$AN/usuarios.xml" ] && command -v openssl >/dev/null 2>&1 \
   && docker image inspect "$CH_IMAGEN" >/dev/null 2>&1; then
  ch_clave="$(openssl rand -hex 16)"
  ch_clave_an="$(openssl rand -hex 16)"
  contenedor_ch="$(docker run -d --rm --name "jsr-test-ch-$$" --memory "${JSR_TEST_CH_MEMORIA:-3g}" --ulimit nofile=262144:262144 \
    -e CLICKHOUSE_SKIP_USER_SETUP=1 \
    -e JSR_CH_CLAVE_SHA256="$(printf %s "$ch_clave" | openssl dgst -sha256 -r | cut -d' ' -f1)" \
    -e JSR_CH_ANALISTA_CLAVE_SHA256="$(printf %s "$ch_clave_an" | openssl dgst -sha256 -r | cut -d' ' -f1)" \
    -v "$AN/perfil-poca-memoria.xml:/etc/clickhouse-server/config.d/perfil-poca-memoria.xml:ro" \
    -v "$AN/usuarios.xml:/etc/clickhouse-server/users.d/usuarios.xml:ro" \
    -p 127.0.0.1::8123 "$CH_IMAGEN" 2>/dev/null)" || contenedor_ch=""
  if [ -n "$contenedor_ch" ]; then
    ch_puerto=""
    for _ in $(seq 1 30); do
      ch_puerto="$(docker port "$contenedor_ch" 8123/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
      [ -n "$ch_puerto" ] && break
      sleep 0.5
    done
    ch_listo=0
    for _ in $(seq 1 90); do
      if docker exec "$contenedor_ch" clickhouse-client --user jsr --password "$ch_clave" -q 'SELECT 1' >/dev/null 2>&1; then
        ch_listo=1
        break
      fi
      sleep 1
    done
    if [ -n "$ch_puerto" ] && [ "$ch_listo" = 1 ]; then
      export JSR_TEST_CH_URL="http://127.0.0.1:${ch_puerto}"
      export JSR_TEST_CH_USUARIO=jsr JSR_TEST_CH_CLAVE="$ch_clave"
      export JSR_TEST_CH_ANALISTA_USUARIO=analista JSR_TEST_CH_ANALISTA_CLAVE="$ch_clave_an"
      echo "test-db.sh: ClickHouse efímero en 127.0.0.1:${ch_puerto} (contenedor jsr-test-ch-$$)"
    else
      echo "test-db.sh: ClickHouse no arrancó a tiempo; se salta la prueba con ClickHouse" >&2
    fi
  fi
fi

if [ "$#" -eq 0 ]; then
  set -- ./...
fi
# Si solo vinieron banderas (-count=1, -run X), añade el patrón de paquetes.
patron=0
for a in "$@"; do
  case "$a" in ./*|*...) patron=1 ;; esac
done
if [ "$patron" = 0 ]; then
  set -- "$@" ./...
fi

go test "$@"
