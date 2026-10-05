#!/usr/bin/env bash
# Biblioteca (se carga con `source`): levanta y apaga un ClickHouse EFIMERO con el perfil de poca memoria.
# Lo usan probar_golden.sh y probar_reconstruccion.sh. Nunca imprime claves: se generan al azar en cada ejecucion,
# se pasan al contenedor como hash SHA-256 y al cliente por variable de entorno.

AN_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CH_IMAGEN="${JSR_CH_IMAGEN:-clickhouse/clickhouse-server:26.9.10.4-alpine}"
CH_MEMORIA="${JSR_CH_PRUEBA_MEMORIA:-3g}"
CH_NOMBRE=""

_sha256() { printf %s "$1" | openssl dgst -sha256 -r | cut -d' ' -f1; }

ch_levantar() {
  command -v docker >/dev/null 2>&1 || { echo "falta docker" >&2; return 1; }
  command -v openssl >/dev/null 2>&1 || { echo "falta openssl" >&2; return 1; }
  if ! docker image inspect "$CH_IMAGEN" >/dev/null 2>&1; then
    echo "bajando $CH_IMAGEN ..." >&2
    docker pull "$CH_IMAGEN" >&2 || { echo "no se pudo bajar la imagen $CH_IMAGEN" >&2; return 1; }
  fi
  CH_NOMBRE="jsr_ch_prueba_$$_$RANDOM"
  export JSR_CH_CLAVE JSR_CH_ANALISTA_CLAVE JSR_CH_URL
  JSR_CH_CLAVE="$(openssl rand -hex 16)"
  JSR_CH_ANALISTA_CLAVE="$(openssl rand -hex 16)"
  docker run -d --name "$CH_NOMBRE" --memory "$CH_MEMORIA" --ulimit nofile=262144:262144 \
    -e CLICKHOUSE_SKIP_USER_SETUP=1 \
    -e JSR_CH_CLAVE_SHA256="$(_sha256 "$JSR_CH_CLAVE")" \
    -e JSR_CH_ANALISTA_CLAVE_SHA256="$(_sha256 "$JSR_CH_ANALISTA_CLAVE")" \
    -v "$AN_RAIZ/perfil-poca-memoria.xml:/etc/clickhouse-server/config.d/perfil-poca-memoria.xml:ro" \
    -v "$AN_RAIZ/usuarios.xml:/etc/clickhouse-server/users.d/usuarios.xml:ro" \
    -p 127.0.0.1::8123 "$CH_IMAGEN" >/dev/null || { echo "no arranco el contenedor" >&2; return 1; }
  local puerto="" i
  for i in $(seq 1 30); do
    puerto="$(docker port "$CH_NOMBRE" 8123/tcp 2>/dev/null | head -1 | sed 's/.*://')"
    [ -n "$puerto" ] && break
    sleep 1
  done
  [ -n "$puerto" ] || { echo "el contenedor no publico el puerto" >&2; docker logs "$CH_NOMBRE" 2>&1 | tail -5 >&2; return 1; }
  JSR_CH_URL="http://127.0.0.1:$puerto"
  for i in $(seq 1 90); do
    if printf 'user = "jsr:%s"\n' "$JSR_CH_CLAVE" | curl -fsS -K - "$JSR_CH_URL/" --data-binary 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    if [ -z "$(docker ps -q -f "name=$CH_NOMBRE")" ]; then
      echo "ClickHouse se detuvo al arrancar. Ultimas lineas del log:" >&2
      docker logs "$CH_NOMBRE" 2>&1 | grep -E "Error|Exception" | head -3 >&2
      return 1
    fi
    sleep 1
  done
  echo "ClickHouse no respondio en 90 s" >&2
  return 1
}

ch_version() {
  printf 'user = "jsr:%s"\n' "$JSR_CH_CLAVE" | curl -fsS -K - "$JSR_CH_URL/" --data-binary 'SELECT version()'
}

ch_memoria() {
  docker stats --no-stream --format '{{.MemUsage}}' "$CH_NOMBRE" 2>/dev/null
}

ch_apagar() {
  if [ -n "$CH_NOMBRE" ]; then
    docker rm -f "$CH_NOMBRE" >/dev/null 2>&1 || true
    CH_NOMBRE=""
  fi
}
