#!/usr/bin/env bash
# Carga ligera: N conversaciones del chat web EN PARALELO (3 turnos cada una) contra la pasarela con el agente y el motor falsos.
# Mide lo que cuesta la PASARELA (login aparte): el agente real sumaria su propia latencia. Uso: scripts/carga.sh [N]  (por defecto 50).
# Lo lanza `make carga` dentro de la imagen de cimientos.
set -uo pipefail
: "${DATABASE_URL:?falta DATABASE_URL}"
N="${1:-50}"
PASARELA_BIN="${PASARELA_BIN:-/home/opam/_build/default/bin/main.exe}"
FALSOS_BIN="${FALSOS_BIN:-/home/opam/_build/default/test/falsos/falsos_main.exe}"
PUERTO="${PUERTO:-18081}"; BASE="http://127.0.0.1:${PUERTO}"
aleatorio() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
export MOTOR_CLAVE="$(aleatorio)" JWT_SECRET="$(aleatorio)$(aleatorio)" WEBHOOK_SECRET="$(aleatorio)"
PIDS=(); trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null' EXIT
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL' >/dev/null
TRUNCATE configuracion, sedes, areas, personas, activos, categorias, grupos, tecnicos, grupo_miembros, habilidades, turnos, ausencias, guardias,
  calendarios, feriados, matriz_prioridad, sla_politicas, incidencias, incidencia_eventos, escalamiento_reglas, escalamientos, casos, mensajes, decisiones,
  articulos, articulo_usos, feedback, encuestas, pares_preferencia, etiquetas_revision, modelos, usuarios_consola, auditoria, outbox_analitica, avisos RESTART IDENTITY CASCADE;
ALTER SEQUENCE incidencia_numero_seq RESTART WITH 1;
INSERT INTO grupos (nombre, nivel) VALUES ('Mesa N1', 'N1');
INSERT INTO tecnicos (nombre, whatsapp, nivel, estado) SELECT 'Tecnico ' || g, '5191000' || lpad(g::text, 4, '0'), 'N1', 'activo' FROM generate_series(1, 5) g;
INSERT INTO grupo_miembros SELECT 1, id FROM tecnicos;
INSERT INTO categorias (clave, nombre, grupo_id) VALUES ('correo', 'Correo', 1), ('otro', 'Otro', 1);
SQL
DATABASE_URL="$DATABASE_URL" "$FALSOS_BIN" >/tmp/carga_falsos.log 2>&1 & PIDS+=($!)
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:18001/salud && break; sleep 0.25; done
CONFIAR_PROXY=1 PORT="$PUERTO" MIGRAR=1 MOTOR_URL=http://127.0.0.1:18002 AGENTE_URL=http://127.0.0.1:18001 EVOLUTION_MODO=simulado SALIDA_ESPACIADO_MS=0 "$PASARELA_BIN" >/tmp/carga_pasarela.log 2>&1 & PIDS+=($!)
for i in $(seq 1 60); do curl -s -o /dev/null "$BASE/api/salud" && break; sleep 0.5; done

una() { # una N: una conversacion de 3 turnos; imprime «estado tiempo» por turno
  local s="sesion-carga-$(printf '%04d' "$1")"
  for m in "no me abre el correo" "mi correo, desde hoy" "sigue igual"; do
    # Cada conversacion llega desde «su» IP (X-Real-IP, con CONFIAR_PROXY=1): el limite de 30 por minuto es por IP.
    curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' -X POST -H 'Content-Type: application/json' -H "X-Real-IP: 10.1.$(($1 / 250)).$(($1 % 250 + 1))" -d "{\"sesion\":\"$s\",\"mensaje\":\"$m\"}" "$BASE/api/chat-web"
  done
}
export -f una; export BASE
INICIO=$(date +%s.%N)
seq 1 "$N" | xargs -P "$N" -I{} bash -c 'una {}' > /tmp/carga_res.txt
FIN=$(date +%s.%N)
TOTAL=$(wc -l < /tmp/carga_res.txt | tr -d ' ')
OK=$(awk '$1 == 200' /tmp/carga_res.txt | wc -l | tr -d ' ')
P50=$(awk '$1 == 200 {print $2}' /tmp/carga_res.txt | sort -n | awk '{a[NR]=$1} END {print a[int(NR*0.50)+1]}')
P95=$(awk '$1 == 200 {print $2}' /tmp/carga_res.txt | sort -n | awk '{a[NR]=$1} END {print a[int(NR*0.95)+1]}')
MAX=$(awk '$1 == 200 {print $2}' /tmp/carga_res.txt | sort -n | tail -1)
printf '%s conversaciones en paralelo, %s turnos: %s con HTTP 200, %s con error\n' "$N" "$TOTAL" "$OK" "$((TOTAL - OK))"
printf 'latencia por turno (s): p50=%s p95=%s max=%s; total de la corrida: %.1f s\n' "$P50" "$P95" "$MAX" "$(echo "$FIN - $INICIO" | bc)"
printf 'incidencias creadas: %s; mensajes guardados: %s; casos: %s\n' \
  "$(psql "$DATABASE_URL" -t -A -c 'SELECT count(*) FROM incidencias')" "$(psql "$DATABASE_URL" -t -A -c 'SELECT count(*) FROM mensajes')" "$(psql "$DATABASE_URL" -t -A -c 'SELECT count(*) FROM casos')"
[ "$OK" = "$TOTAL" ] && echo "CARGA OK" || { echo "CARGA CON ERRORES"; tail -5 /tmp/carga_pasarela.log; exit 1; }
