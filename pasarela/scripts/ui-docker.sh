#!/usr/bin/env bash
# Levanta TODO para usar la consola web (web/) contra la pasarela de verdad: Postgres efimero, motor Go y agente Python reales (si las
# imagenes existen), la semilla sintetica y la pasarela, publicada en http://127.0.0.1:${UI_PUERTO:-18480}. Evolution va simulado.
#
#   scripts/ui-docker.sh arrancar   crea todo y crea los usuarios de desarrollo
#   scripts/ui-docker.sh parar      lo apaga y lo borra
#   cd web && BACKEND_URL=http://127.0.0.1:${UI_PUERTO:-18480} npm run dev        -> http://localhost:5173
#
# Usuarios de DESARROLLO (base efimera, solo en tu maquina): tecnico@jsr.test, supervisor@jsr.test, gerencia@jsr.test, entrenador@jsr.test,
# admin@jsr.test; clave de todos: jsr123jsr123. El tecnico queda vinculado a un tecnico de la semilla.
set -euo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
RAIZ="$(cd "$AQUI/.." && pwd)"
cd "$AQUI"
export CIMIENTOS="${CIMIENTOS:-jsr/pasarela-cimientos:local}"
MOTOR_IMAGEN="${MOTOR_IMAGEN:-jsrbot/motor:prueba}"
AGENTE_IMAGEN="${AGENTE_IMAGEN:-jsrbot_agente:prueba}"
DSN_MOTOR="postgres://postgres:prueba@localhost:5432/jsr_test?sslmode=disable"
DSN="postgresql://postgres:prueba@localhost:5432/jsr_test"
CLAVE_DEV="jsr123jsr123"
RED="--network container:jsr-pasarela-pg"

parar() {
  docker rm -f jsr-ui-pasarela jsr-e2e-motor jsr-e2e-agente >/dev/null 2>&1 || true
  "$AQUI/scripts/pg-pruebas.sh" parar >/dev/null 2>&1 || true
}

case "${1:-}" in
  parar) parar; echo "apagado" ;;
  arrancar)
    parar
    "$AQUI/scripts/en-cimientos.sh" dune build ./bin/main.exe
    MOTOR_CLAVE="clave-motor-ui-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    SIN_MIGRACIONES=1 PUBLICAR="127.0.0.1:${UI_PUERTO:-18480}:8080" "$AQUI/scripts/pg-pruebas.sh" arrancar >/dev/null
    docker run -d --name jsr-e2e-motor $RED -e DATABASE_URL="$DSN_MOTOR" -e MOTOR_CLAVE="$MOTOR_CLAVE" -e MOTOR_ADDR=":8090" -v "$RAIZ/analitica:/analitica:ro" "$MOTOR_IMAGEN" >/dev/null
    for i in $(seq 1 40); do docker run --rm $RED curlimages/curl -s -o /dev/null -H "X-Interno-Clave: $MOTOR_CLAVE" http://127.0.0.1:8090/interno/salud && break; sleep 1; done
    docker run --rm --entrypoint /semilla $RED -e DATABASE_URL="$DSN_MOTOR" "$MOTOR_IMAGEN" -limpiar -incidencias "${INCIDENCIAS:-120}" >/dev/null 2>&1
    docker run -d --name jsr-e2e-agente $RED "$AGENTE_IMAGEN" >/dev/null
    for i in $(seq 1 60); do docker run --rm $RED curlimages/curl -s -o /dev/null -f http://127.0.0.1:8000/salud && break; sleep 1; done
    # Usuarios de desarrollo (con la clave de desarrollo; nada de esto es un secreto real).
    TEC_ID="$(docker exec jsr-pasarela-pg psql -U postgres -d jsr_test -t -A -c "SELECT t.id FROM tecnicos t JOIN grupo_miembros m ON m.tecnico_id = t.id JOIN categorias c ON c.grupo_id = m.grupo_id WHERE c.clave = 'correo' AND t.estado = 'activo' ORDER BY t.id LIMIT 1")"
    SUP_ID="$(docker exec jsr-pasarela-pg psql -U postgres -d jsr_test -t -A -c "SELECT id FROM tecnicos WHERE id <> $TEC_ID AND estado = 'activo' ORDER BY id LIMIT 1")"
    docker run -d --name jsr-ui-pasarela $RED -v "$AQUI":/w -v jsr-pasarela-build:/home/opam/_build -w /w \
      -e DATABASE_URL="$DSN" -e MOTOR_CLAVE="$MOTOR_CLAVE" -e JWT_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" -e WEBHOOK_SECRET="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
      -e MOTOR_URL=http://127.0.0.1:8090 -e AGENTE_URL=http://127.0.0.1:8000 -e EVOLUTION_MODO=simulado -e PBKDF2_ITER=100000 \
      -e CORS="http://localhost:5173,http://127.0.0.1:5173" -e BASE_URL_PUBLICA="http://localhost:5173" -e PORT=8080 \
      --entrypoint /home/opam/_build/default/bin/main.exe "$CIMIENTOS" >/dev/null
    for i in $(seq 1 40); do docker run --rm $RED curlimages/curl -s -o /dev/null -f http://127.0.0.1:8080/api/salud && break; sleep 1; done
    for rol in tecnico supervisor gerencia entrenador admin; do
      docker exec -e PBKDF2_ITER=100000 -e PASARELA_ADMIN_CLAVE="$CLAVE_DEV" -e DATABASE_URL="$DSN" jsr-ui-pasarela /home/opam/_build/default/bin/main.exe crear-admin --email "$rol@jsr.test" --nombre "$(printf %s "$rol" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" --rol "$rol" >/dev/null
    done
    docker exec jsr-pasarela-pg psql -U postgres -d jsr_test -q -c "UPDATE usuarios_consola u SET tecnico_id = $TEC_ID, nombre = (SELECT nombre FROM tecnicos WHERE id = $TEC_ID) WHERE email = 'tecnico@jsr.test'; UPDATE usuarios_consola SET tecnico_id = $SUP_ID WHERE email = 'supervisor@jsr.test'" >/dev/null
    echo "pasarela lista en http://127.0.0.1:${UI_PUERTO:-18480}  (usuarios *@jsr.test, clave de desarrollo jsr123jsr123)"
    echo "consola: cd web && BACKEND_URL=http://127.0.0.1:${UI_PUERTO:-18480} npm run dev"
    ;;
  *) echo "uso: $0 arrancar|parar" >&2; exit 2 ;;
esac
