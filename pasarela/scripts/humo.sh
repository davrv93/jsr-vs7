#!/usr/bin/env bash
# Humo de la pasarela: arranca el agente, el motor y evolution-go FALSOS (test/falsos), la pasarela de verdad, y recorre con curl
#   login -> bandeja -> detalle -> accion -> chat web -> estado publico -> webhook -> eventos
# Requisitos: curl, jq, psql, un Postgres con el esquema de backend/migrations, y los dos binarios compilados.
#
#   DATABASE_URL=postgresql://... PASARELA_BIN=... FALSOS_BIN=... scripts/humo.sh
#
# Normalmente lo lanza `make humo` (scripts/humo-docker.sh), que arma todo eso. Nunca imprime un secreto: las claves se generan
# al vuelo y solo se usan por variable de entorno; el token no se muestra.
set -uo pipefail

: "${DATABASE_URL:?falta DATABASE_URL}"
PASARELA_BIN="${PASARELA_BIN:-/home/opam/_build/default/bin/main.exe}"
FALSOS_BIN="${FALSOS_BIN:-/home/opam/_build/default/test/falsos/falsos_main.exe}"
PUERTO="${PUERTO:-18080}"
BASE="http://127.0.0.1:${PUERTO}"

aleatorio() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
export MOTOR_CLAVE="$(aleatorio)"
export JWT_SECRET="$(aleatorio)$(aleatorio)"
export WEBHOOK_SECRET="$(aleatorio)"
CLAVE_ADMIN="$(aleatorio)"
CLAVE_TEC="$(aleatorio)"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

FALLOS=0
paso() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
mal()  { printf '   MAL  %s\n' "$*"; FALLOS=$((FALLOS + 1)); }
afirmar() { # afirmar "descripcion" valor_esperado valor_real
  if [ "$2" = "$3" ]; then ok "$1"; else mal "$1 (esperado: $2; real: $3)"; fi
}
afirmar_no_vacio() { if [ -n "$2" ] && [ "$2" != "null" ]; then ok "$1"; else mal "$1 (vacio)"; fi; }

# curl: deja el codigo en $ESTADO y el cuerpo en $CUERPO
llamar() { # llamar METODO RUTA [cuerpo-json] [token]
  local metodo="$1" ruta="$2" cuerpo="${3:-}" token="${4:-}"
  local args=(-sS -X "$metodo" -H "Content-Type: application/json" -o /tmp/humo_cuerpo -w '%{http_code}')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$cuerpo" ] && args+=(-d "$cuerpo")
  ESTADO="$(curl "${args[@]}" "${BASE}${ruta}")"
  CUERPO="$(cat /tmp/humo_cuerpo)"
}
campo() { printf '%s' "$CUERPO" | jq -r "$1"; }

psql_() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -t -A "$@"; }

# --- 1. datos de partida ------------------------------------------------------------------------------------------------------------
paso "Base de datos: datos de partida (solo en la base de prueba)"
psql_ <<'SQL' >/dev/null
TRUNCATE configuracion, sedes, areas, personas, activos, categorias, grupos, tecnicos, grupo_miembros, habilidades, turnos, ausencias, guardias,
  calendarios, feriados, matriz_prioridad, sla_politicas, incidencias, incidencia_eventos, escalamiento_reglas, escalamientos, casos, mensajes, decisiones,
  articulos, articulo_usos, feedback, encuestas, pares_preferencia, etiquetas_revision, modelos, usuarios_consola, auditoria, outbox_analitica, avisos RESTART IDENTITY CASCADE;
ALTER SEQUENCE incidencia_numero_seq RESTART WITH 1;
INSERT INTO sedes (nombre) VALUES ('Centro');
INSERT INTO areas (nombre) VALUES ('Contabilidad');
INSERT INTO grupos (nombre, nivel) VALUES ('Mesa N1', 'N1');
INSERT INTO tecnicos (nombre, whatsapp, nivel, estado) VALUES ('Luis Paz', '51911111111', 'N1', 'activo');
INSERT INTO grupo_miembros VALUES (1, 1);
INSERT INTO categorias (clave, nombre, grupo_id) VALUES ('correo', 'Correo', 1), ('otro', 'Otro', 1);
INSERT INTO articulos (clave, titulo, categoria_id, pasos) VALUES ('KB-031', 'Outlook no sincroniza', 1, ARRAY['Cerrar Outlook', 'Cerrar sesión']);
INSERT INTO personas (nombre, whatsapp, correo, sede_id, area_id) VALUES ('Ana Ríos', '51987654321', 'ana@ejemplo.test', 1, 1);
SQL
ok "esquema y datos listos"

# --- 2. servicios ------------------------------------------------------------------------------------------------------------------------
paso "Servicios falsos (agente, motor, evolution) y la pasarela"
DATABASE_URL="$DATABASE_URL" "$FALSOS_BIN" >/tmp/humo_falsos.log 2>&1 & PIDS+=($!)
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:18001/salud" && break; sleep 0.25; done

PBKDF2_ITER=100000 PASARELA_ADMIN_CLAVE="$CLAVE_ADMIN" "$PASARELA_BIN" crear-admin --email admin@humo.test --nombre "Administrador" --rol admin
PBKDF2_ITER=100000 PASARELA_ADMIN_CLAVE="$CLAVE_TEC" "$PASARELA_BIN" crear-admin --email tecnico@humo.test --nombre "Luis Paz" --rol tecnico
psql_ -c "UPDATE usuarios_consola SET tecnico_id = 1 WHERE email = 'tecnico@humo.test'" >/dev/null

PORT="$PUERTO" MIGRAR=1 MOTOR_URL="http://127.0.0.1:18002" AGENTE_URL="http://127.0.0.1:18001" \
  EVOLUTION_MODO=simulado SALIDA_ESPACIADO_MS=0 PBKDF2_ITER=100000 BASE_URL_PUBLICA="http://127.0.0.1:${PUERTO}/jsr" \
  "$PASARELA_BIN" >/tmp/humo_pasarela.log 2>&1 & PIDS+=($!)
LISTO=0
for i in $(seq 1 60); do
  if curl -s -o /dev/null "${BASE}/api/salud"; then LISTO=1; break; fi
  sleep 0.5
done
if [ "$LISTO" = 1 ]; then ok "la pasarela responde"; else mal "la pasarela no arranco"; tail -20 /tmp/humo_pasarela.log; exit 1; fi

llamar GET /api/salud
afirmar "salud: ok" true "$(campo .ok)"
afirmar "salud: base" ok "$(campo .db)"
afirmar "salud: agente" ok "$(campo .agente)"
afirmar "salud: motor" ok "$(campo .motor)"
afirmar "salud: evolution simulado (nada sale a WhatsApp)" simulado "$(campo .evolution)"

# --- 3. login --------------------------------------------------------------------------------------------------------------------------------
paso "Login"
llamar POST /api/auth/login '{"email":"tecnico@humo.test","clave":"incorrecta"}'
afirmar "clave mala -> 401" 401 "$ESTADO"
afirmar "codigo" no_autorizado "$(campo .codigo)"
llamar POST /api/auth/login "{\"email\":\"tecnico@humo.test\",\"clave\":\"$CLAVE_TEC\"}"
afirmar "login -> 200" 200 "$ESTADO"
TOKEN="$(campo .token)"
afirmar "rol" tecnico "$(campo .usuario.rol)"
afirmar "tecnico_id" 1 "$(campo .usuario.tecnico_id)"
llamar POST /api/auth/login "{\"email\":\"admin@humo.test\",\"clave\":\"$CLAVE_ADMIN\"}"
TOKEN_ADMIN="$(campo .token)"
llamar GET /api/yo "" "$TOKEN"
afirmar "/api/yo" "Luis Paz" "$(campo .nombre)"
llamar GET /api/bandeja
afirmar "sin token -> 401" 401 "$ESTADO"
llamar GET /api/usuarios "" "$TOKEN"
afirmar "un tecnico no ve usuarios -> 403" 403 "$ESTADO"
llamar GET /api/usuarios "" "$TOKEN_ADMIN"
afirmar "el administrador si -> 200" 200 "$ESTADO"
afirmar "la lista de usuarios no trae hashes" 0 "$(printf '%s' "$CUERPO" | grep -c 'pbkdf2')"

# --- 4. chat web: la persona cuenta su problema -> incidencia ----------------------------------------------------------------
paso "Chat web: caso nuevo -> guia -> incidencia"
llamar POST /api/chat-web '{"sesion":"sesion-humo-0001","mensaje":"no me abre el correo"}'
afirmar "chat web -> 200" 200 "$ESTADO"
afirmar "etapa de diagnostico" diagnostico "$(campo .analisis.etapa)"
llamar POST /api/chat-web '{"sesion":"sesion-humo-0001","mensaje":"mi correo, desde hoy en PC-CONT-07"}'
afirmar "etapa de guia" guia "$(campo .analisis.etapa)"
afirmar "articulo usado, con titulo" "Outlook no sincroniza" "$(campo '.analisis.articulos_usados[0].titulo')"
llamar POST /api/chat-web '{"sesion":"sesion-humo-0001","mensaje":"sigue igual"}'
afirmar "se creo la incidencia" INC-000001 "$(campo .incidencia.numero)"
TEXTO="$(campo .respuesta)"
case "$TEXTO" in *"INC-000001"*"Luis Paz"*"antes de las"*) ok "texto fijo con numero, tecnico y plazo" ;; *) mal "texto fijo incompleto: $TEXTO" ;; esac
llamar POST /api/chat-web '{"sesion":"corta","mensaje":"hola"}'
afirmar "sesion invalida -> 400" 400 "$ESTADO"

# --- 5. consola: bandeja -> detalle -> accion --------------------------------------------------------------------------------------
paso "Consola: bandeja, detalle, accion"
llamar GET /api/bandeja "" "$TOKEN"
afirmar "bandeja -> 200" 200 "$ESTADO"
afirmar "la incidencia esta en «mias»" INC-000001 "$(campo '.mias[0].numero')"
afirmar_no_vacio "con SLA del motor" "$(campo '.mias[0].sla.porcentaje')"
llamar GET "/api/incidencias?q=correo&por_pagina=10" "" "$TOKEN"
afirmar "lista: total" 1 "$(campo .total)"
llamar GET /api/incidencias/1 "" "$TOKEN"
afirmar "detalle -> 200" 200 "$ESTADO"
afirmar "detalle: persona" "Visitante web sesion" "$(campo .persona_detalle.nombre | cut -c1-20)"
afirmar "detalle: memoria del caso" "correo no sincroniza" "$(campo .memoria.sintoma)"
afirmar_no_vacio "detalle: eventos" "$(campo '.eventos[0].tipo')"
afirmar_no_vacio "detalle: hilo de la conversacion" "$(campo '.mensajes.items[0].texto')"
TOKEN_PUBLICO="$(campo .token_publico)"
llamar POST /api/incidencias/1/acciones '{"accion":"comentar_interno","texto":"Parece el perfil de Outlook"}' "$TOKEN"
afirmar "nota interna -> 200" 200 "$ESTADO"
llamar POST /api/incidencias/1/acciones '{"accion":"responder","texto":"Hola, ya lo estoy revisando."}' "$TOKEN"
afirmar "responder -> 200" 200 "$ESTADO"
afirmar "la incidencia pasa a en_curso" en_curso "$(campo .estado)"
llamar POST /api/incidencias/1/acciones '{"accion":"inventada"}' "$TOKEN"
afirmar "accion desconocida -> 400" 400 "$ESTADO"
llamar POST /api/incidencias/1/acciones '{"accion":"cerrar"}' "$TOKEN"
afirmar "cerrar sin resolver -> 409 (lo dice el motor)" 409 "$ESTADO"
llamar GET /api/casos "" "$TOKEN"
afirmar "conversaciones: el caso quedo pausado por el tecnico" true "$(campo '.items[0].pausado_por_tecnico')"

# --- 6. estado publico -------------------------------------------------------------------------------------------------------------------------
paso "Estado publico (sin sesion)"
llamar GET "/api/estado/${TOKEN_PUBLICO}"
afirmar "estado -> 200" 200 "$ESTADO"
afirmar "ultimo mensaje del tecnico" "Hola, ya lo estoy revisando." "$(campo .ultimo_mensaje_tecnico.texto)"
llamar GET "/api/estado/00000000000000000000000000000000"
afirmar "token falso -> 404" 404 "$ESTADO"
llamar POST "/api/estado/${TOKEN_PUBLICO}/responder" '{"texto":"Gracias, espero."}'
afirmar "responder desde la pagina -> 200" 200 "$ESTADO"

# --- 7. webhook de WhatsApp ----------------------------------------------------------------------------------------------------------------------
paso "Webhook de WhatsApp (evolution-go simulado)"
MSG='{"event":"Message","data":{"Info":{"ID":"HUMO1","Chat":"51987654321@s.whatsapp.net","IsFromMe":false,"IsGroup":false,"PushName":"Ana"},"Message":{"conversation":"no me abre el correo"}}}'
llamar POST /webhook/evolution "$MSG"
afirmar "sin secreto -> 403" 403 "$ESTADO"
ESTADO="$(curl -sS -o /tmp/humo_cuerpo -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Webhook-Secret: $WEBHOOK_SECRET" -d "$MSG" "${BASE}/webhook/evolution")"
afirmar "con secreto -> 200" 200 "$ESTADO"
sleep 1.5
afirmar "el mensaje se guardo una vez" 1 "$(psql_ -c "SELECT count(*) FROM mensajes WHERE meta->>'wa_id' = 'HUMO1'")"
afirmar "y el asistente contesto (caso nuevo de WhatsApp)" 1 "$(psql_ -c "SELECT count(*) FROM mensajes m JOIN casos c ON c.id = m.caso_id WHERE c.canal = 'whatsapp' AND m.rol = 'asistente'")"
curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -H "X-Webhook-Secret: $WEBHOOK_SECRET" -d "$MSG" "${BASE}/webhook/evolution"
sleep 0.7
afirmar "el mismo mensaje otra vez no se duplica" 1 "$(psql_ -c "SELECT count(*) FROM mensajes WHERE meta->>'wa_id' = 'HUMO1'")"

# --- 8. analitica y auditoria -------------------------------------------------------------------------------------------------------------------
paso "Analitica y auditoria"
afirmar_no_vacio "outbox_analitica: mensajes" "$(psql_ -c "SELECT count(*) FROM outbox_analitica WHERE tabla = 'mensajes'")"
afirmar "el outbox no lleva el texto de los mensajes (ANALITICA_TEXTO=0)" 0 "$(psql_ -c "SELECT count(*) FROM outbox_analitica WHERE tabla = 'mensajes' AND payload->>'texto' <> ''")"
afirmar_no_vacio "auditoria: login" "$(psql_ -c "SELECT count(*) FROM auditoria WHERE accion = 'login'")"
afirmar_no_vacio "auditoria: login fallido" "$(psql_ -c "SELECT count(*) FROM auditoria WHERE accion = 'login_fallido'")"

# --- 9. eventos en vivo ---------------------------------------------------------------------------------------------------------------------------
paso "Eventos en vivo (SSE)"
( curl -sS -N --max-time 4 -H "Authorization: Bearer $TOKEN" "${BASE}/api/eventos" > /tmp/humo_sse 2>/dev/null ) &
SSE=$!
sleep 1
llamar POST /api/incidencias '{"titulo":"Impresora del 3.er piso","categoria":"otro","persona_id":1}' "$TOKEN"
afirmar "alta manual -> 201" 201 "$ESTADO"
wait "$SSE" 2>/dev/null
if grep -q 'event: incidencia_creada' /tmp/humo_sse; then ok "el panel recibe incidencia_creada"; else mal "no llego incidencia_creada"; fi

# --- 10. nada de secretos en los registros ----------------------------------------------------------------------------------------------------------
paso "Registros sin secretos ni datos personales"
for secreto in "$JWT_SECRET" "$MOTOR_CLAVE" "$WEBHOOK_SECRET" "$CLAVE_ADMIN" "$CLAVE_TEC" "$TOKEN" "$TOKEN_PUBLICO"; do
  if grep -qF -- "$secreto" /tmp/humo_pasarela.log; then mal "un secreto aparece en el registro de la pasarela"; fi
done
if grep -q "51987654321" /tmp/humo_pasarela.log; then mal "un telefono completo aparece en el registro"; else ok "ningun telefono completo en el registro"; fi
if grep -q "no me abre el correo" /tmp/humo_pasarela.log; then mal "texto de una conversacion en el registro"; else ok "ningun texto de conversaciones en el registro"; fi

printf '\n'
if [ "$FALLOS" -eq 0 ]; then printf 'HUMO OK: todo recorrido sin fallos\n'; exit 0; else printf 'HUMO CON %d FALLO(S)\n' "$FALLOS"; tail -20 /tmp/humo_pasarela.log; exit 1; fi
