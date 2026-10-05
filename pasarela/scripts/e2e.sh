#!/usr/bin/env bash
# Punta a punta con los servicios REALES: motor Go (backend/), agente Python (agente/) y la pasarela, sobre un Postgres con el esquema
# que aplica el propio motor y la semilla sintetica. Evolution va SIMULADO (no se envia nada a WhatsApp).
# Lo lanza scripts/e2e-docker.sh (que levanta los contenedores del motor y del agente); este archivo corre DENTRO de la imagen de
# cimientos, en el mismo espacio de red.
#
# Variables: DATABASE_URL, MOTOR_CLAVE, PASARELA_BIN. El motor escucha en :8090 y el agente en :8000 (mismo localhost).
set -uo pipefail

: "${DATABASE_URL:?falta DATABASE_URL}"
: "${MOTOR_CLAVE:?falta MOTOR_CLAVE}"
PASARELA_BIN="${PASARELA_BIN:-/home/opam/_build/default/bin/main.exe}"
PUERTO="${PUERTO:-18080}"
BASE="http://127.0.0.1:${PUERTO}"

aleatorio() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
export JWT_SECRET="$(aleatorio)$(aleatorio)"
export WEBHOOK_SECRET="$(aleatorio)"
CLAVE_TEC="$(aleatorio)"
CLAVE_ADM="$(aleatorio)"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

FALLOS=0
paso() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
mal()  { printf '   MAL  %s\n' "$*"; FALLOS=$((FALLOS + 1)); }
afirmar() { if [ "$2" = "$3" ]; then ok "$1"; else mal "$1 (esperado: $2; real: $3)"; fi; }
afirmar_no_vacio() { if [ -n "$2" ] && [ "$2" != "null" ]; then ok "$1"; else mal "$1 (vacio)"; fi; }
contiene() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

llamar() { # llamar METODO RUTA [cuerpo-json] [token]
  local metodo="$1" ruta="$2" cuerpo="${3:-}" token="${4:-}"
  local args=(-sS -X "$metodo" -H "Content-Type: application/json" -o /tmp/e2e_cuerpo -w '%{http_code}')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$cuerpo" ] && args+=(-d "$cuerpo")
  ESTADO="$(curl "${args[@]}" "${BASE}${ruta}")"
  CUERPO="$(cat /tmp/e2e_cuerpo)"
}
campo() { printf '%s' "$CUERPO" | jq -r "$1"; }
psql_() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -t -A "$@"; }
chat() { llamar POST /api/chat-web "$(jq -nc --arg s "$1" --arg m "$2" '{sesion:$s,mensaje:$m}')"; }

paso "Servicios reales"
curl -s -H "X-Interno-Clave: $MOTOR_CLAVE" http://127.0.0.1:8090/interno/salud | jq -e '.ok == true' >/dev/null && ok "motor Go: salud" || { mal "el motor no responde"; exit 1; }
curl -s http://127.0.0.1:8000/salud | jq -e '.ok == true' >/dev/null && ok "agente Python: salud" || { mal "el agente no responde"; exit 1; }
afirmar_no_vacio "la semilla cargo tecnicos" "$(psql_ -c "SELECT count(*) FROM tecnicos")"

# Un tecnico de la semilla (el primero activo del grupo de correo) con acceso a la consola.
TEC_ID="$(psql_ -c "SELECT t.id FROM tecnicos t JOIN grupo_miembros m ON m.tecnico_id = t.id JOIN categorias c ON c.grupo_id = m.grupo_id WHERE c.clave = 'correo' AND t.estado = 'activo' ORDER BY t.id LIMIT 1")"
TEC_NOMBRE="$(psql_ -c "SELECT nombre FROM tecnicos WHERE id = $TEC_ID")"
PBKDF2_ITER=100000 PASARELA_ADMIN_CLAVE="$CLAVE_TEC" "$PASARELA_BIN" crear-admin --email tecnico@e2e.test --nombre "$TEC_NOMBRE" --rol tecnico
PBKDF2_ITER=100000 PASARELA_ADMIN_CLAVE="$CLAVE_ADM" "$PASARELA_BIN" crear-admin --email admin@e2e.test --nombre "Administrador" --rol admin
psql_ -c "UPDATE usuarios_consola SET tecnico_id = $TEC_ID WHERE email = 'tecnico@e2e.test'" >/dev/null

PORT="$PUERTO" MIGRAR=1 MOTOR_URL="http://127.0.0.1:8090" AGENTE_URL="http://127.0.0.1:8000" EVOLUTION_MODO=simulado SALIDA_ESPACIADO_MS=0 \
  PBKDF2_ITER=100000 BASE_URL_PUBLICA="http://127.0.0.1:${PUERTO}/jsr" "$PASARELA_BIN" >/tmp/e2e_pasarela.log 2>&1 & PIDS+=($!)
for i in $(seq 1 60); do curl -s -o /dev/null "${BASE}/api/salud" && break; sleep 0.5; done
llamar GET /api/salud
afirmar "pasarela: salud" true "$(campo .ok)"
afirmar "pasarela ve al motor" ok "$(campo .motor)"
afirmar "pasarela ve al agente" ok "$(campo .agente)"

paso "Login"
llamar POST /api/auth/login "{\"email\":\"tecnico@e2e.test\",\"clave\":\"$CLAVE_TEC\"}"
afirmar "login del tecnico" 200 "$ESTADO"
TOKEN="$(campo .token)"
llamar POST /api/auth/login "{\"email\":\"admin@e2e.test\",\"clave\":\"$CLAVE_ADM\"}"
TOKEN_ADM="$(campo .token)"

paso "Chat web con el agente REAL: del problema a la incidencia (el motor la crea y la despacha)"
S="sesion-e2e-$(aleatorio | head -c 8)"
INC=""
for MENSAJE in "no me abre el correo" "uso Outlook en mi laptop" "desde esta mañana" "no me sale ningun mensaje de error" "ya probé reiniciar y sigue igual" "sigue igual" "sigue igual, abre una incidencia"; do
  chat "$S" "$MENSAJE"
  ACCION="$(campo '.analisis.accion.tipo')"
  printf '   .    «%s» -> etapa=%s accion=%s\n' "$MENSAJE" "$(campo .analisis.etapa)" "$ACCION"
  if [ "$ACCION" = "crear_incidencia" ]; then INC="$(campo .incidencia.numero)"; TEXTO="$(campo .respuesta)"; break; fi
done
afirmar_no_vacio "se creo una incidencia" "$INC"
if contiene "$INC" "${TEXTO:-}" && contiene "antes de" "${TEXTO:-}"; then ok "el texto fijo trae el numero y el plazo (lo escribe el codigo)"; else mal "texto fijo incompleto: ${TEXTO:-}"; fi
afirmar "la incidencia existe en Postgres, creada por el motor" 1 "$(psql_ -c "SELECT count(*) FROM incidencias WHERE numero = '$INC'")"
afirmar "con su evento «creada» del motor" 1 "$(psql_ -c "SELECT count(*) FROM incidencia_eventos e JOIN incidencias i ON i.id = e.incidencia_id WHERE i.numero = '$INC' AND e.tipo = 'creada'")"
echo "   .    estado de la incidencia: $(psql_ -c "SELECT estado || ' / ' || prioridad || ' / tecnico ' || coalesce(tecnico_id::text, 'ninguno') FROM incidencias WHERE numero = '$INC'")"

paso "Consola sobre datos reales (motor real: SLA, bandeja, detalle, acciones)"
ID="$(psql_ -c "SELECT id FROM incidencias WHERE numero = '$INC'")"
llamar GET "/api/incidencias/$ID" "" "$TOKEN"
afirmar "detalle -> 200" 200 "$ESTADO"
afirmar "detalle: numero" "$INC" "$(campo .numero)"
afirmar_no_vacio "detalle: sla del motor (porcentaje)" "$(campo .sla.porcentaje)"
afirmar_no_vacio "detalle: restante_min" "$(campo .sla.restante_min)"
afirmar_no_vacio "detalle: hilo con la conversacion" "$(campo '.mensajes.items[0].texto')"
afirmar_no_vacio "detalle: clasificacion del agente" "$(campo .clasificacion.intencion)"
afirmar_no_vacio "detalle: ficha del caso" "$(campo '.memoria.sabemos.sintoma')"
llamar GET "/api/incidencias?por_pagina=5" "" "$TOKEN"
afirmar_no_vacio "lista: total de la semilla + la nueva" "$(campo .total)"
afirmar_no_vacio "lista: sla en las filas" "$(campo '.items[0].sla.porcentaje')"
llamar GET /api/bandeja "" "$TOKEN"
afirmar "bandeja -> 200" 200 "$ESTADO"
echo "   .    bandeja: vencen_pronto=$(campo '.vencen_pronto|length') mias=$(campo '.mias|length') sin_asignar=$(campo '.sin_asignar|length')"

# Fuera de horario laboral (el servidor tiene la hora en UTC) la incidencia queda en la cola del grupo: el tecnico se la asigna.
TOKEN_PUB="$(psql_ -c "SELECT token_publico FROM incidencias WHERE id = $ID")"
llamar POST "/api/incidencias/$ID/acciones" '{"accion":"responder","texto":"Hola"}' "$TOKEN"
afirmar "responder sin asignar -> 409 (el motor exige la transicion valida y lo dice en español)" 409 "$ESTADO"
echo "   .    mensaje del motor: $(campo .error)"
llamar POST "/api/incidencias/$ID/acciones" '{"accion":"asignar"}' "$TOKEN"
afirmar "asignarse la incidencia -> 200" 200 "$ESTADO"
afirmar "queda asignada" asignada "$(campo .estado)"
afirmar "al tecnico de la consola" "$TEC_NOMBRE" "$(campo .tecnico.nombre)"
llamar POST "/api/incidencias/$ID/acciones" '{"accion":"responder","texto":"Hola, ya estoy revisando tu correo. ¿Qué equipo usas?","espera_usuario":true}' "$TOKEN"
afirmar "responder (con espera_usuario) -> 200" 200 "$ESTADO"
afirmar "el motor la dejo en espera_usuario (reloj pausado)" espera_usuario "$(campo .estado)"
afirmar "el reloj de SLA esta pausado" true "$(campo .sla.pausado)"
llamar GET "/api/estado/$TOKEN_PUB"
afirmar "estado publico" 200 "$ESTADO"
afirmar "estado publico: texto" "Esperamos tu respuesta" "$(campo .estado_texto)"
afirmar "estado publico: ultimo mensaje del tecnico" "Hola, ya estoy revisando tu correo. ¿Qué equipo usas?" "$(campo .ultimo_mensaje_tecnico.texto)"
llamar POST "/api/estado/$TOKEN_PUB/responder" '{"texto":"Uso una laptop Dell, Windows 11."}'
afirmar "la persona responde desde la pagina de estado" 200 "$ESTADO"
afirmar "el motor reanudo el reloj (la respuesta de la persona)" en_curso "$(psql_ -c "SELECT estado FROM incidencias WHERE id = $ID")"
afirmar "y dejo el comentario de la persona como evento" 1 "$(psql_ -c "SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $ID AND tipo = 'comentario' AND actor_tipo = 'usuario'")"
echo "   .    avisos de esta incidencia: $(psql_ -c "SELECT coalesce(string_agg(plantilla || ':' || destinatario_tipo || ':' || coalesce(destinatario_id::text, 'sin') || ':' || (CASE WHEN enviado_en IS NOT NULL THEN 'enviado' ELSE 'pendiente(' || coalesce(error, '-') || ')' END), ' | '), 'ninguno') FROM avisos WHERE incidencia_id = $ID")"

paso "Resolver, confirmar y encuesta con el agente real"
llamar POST "/api/incidencias/$ID/acciones" '{"accion":"resolver","solucion":"Se recreo el perfil de Outlook"}' "$TOKEN"
afirmar "resolver -> 200" 200 "$ESTADO"
afirmar "estado resuelta" resuelta "$(campo .estado)"
chat "$S" "sí, ya funciona, gracias"
echo "   .    «sí, ya funciona» -> etapa=$(campo .analisis.etapa) accion=$(campo .analisis.accion.tipo)"
chat "$S" "5"
echo "   .    «5» -> etapa=$(campo .analisis.etapa) accion=$(campo .analisis.accion.tipo)"
echo "   .    estado final de la incidencia: $(psql_ -c "SELECT estado FROM incidencias WHERE id = $ID")"
echo "   .    encuestas del caso: $(psql_ -c "SELECT count(*) || ' (puntajes: ' || coalesce(string_agg(coalesce(puntaje::text, 'NULL'), ','), '-') || ')' FROM encuestas WHERE caso_id = (SELECT caso_id FROM incidencias WHERE id = $ID)")"

ENC_ID="$(psql_ -c "SELECT id FROM encuestas WHERE caso_id = (SELECT caso_id FROM incidencias WHERE id = $ID)")"
afirmar "encuesta: el outbox lleva la misma enc-<id> dos veces (enviada sin puntaje y respondida)" 2 "$(psql_ -c "SELECT count(*) FROM outbox_analitica WHERE tabla = 'encuestas' AND clave = 'enc-$ENC_ID'")"
afirmar "encuesta: la primera con puntaje null" null "$(psql_ -c "SELECT coalesce(payload->>'puntaje', 'null') FROM outbox_analitica WHERE tabla = 'encuestas' AND clave = 'enc-$ENC_ID' ORDER BY id LIMIT 1")"
afirmar "encuesta: la segunda con el puntaje" 5 "$(psql_ -c "SELECT payload->>'puntaje' FROM outbox_analitica WHERE tabla = 'encuestas' AND clave = 'enc-$ENC_ID' ORDER BY id DESC LIMIT 1")"

paso "WhatsApp (webhook de evolution-go simulado) con el agente real"
MSG='{"event":"Message","data":{"Info":{"ID":"E2E1","Chat":"51999000111@s.whatsapp.net","IsFromMe":false,"IsGroup":false,"PushName":"Rosa"},"Message":{"conversation":"la impresora del tercer piso no imprime"}}}'
ESTADO="$(curl -sS -o /tmp/e2e_cuerpo -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "X-Webhook-Secret: $WEBHOOK_SECRET" -d "$MSG" "${BASE}/webhook/evolution")"
afirmar "webhook -> 200" 200 "$ESTADO"
sleep 2
afirmar "mensaje guardado" 1 "$(psql_ -c "SELECT count(*) FROM mensajes WHERE meta->>'wa_id' = 'E2E1'")"
afirmar "el agente contesto" 1 "$(psql_ -c "SELECT count(*) FROM mensajes m JOIN casos c ON c.id = m.caso_id WHERE c.chat_id = '51999000111' AND m.rol = 'asistente'")"
echo "   .    clasificacion del mensaje: $(psql_ -c "SELECT meta->>'intencion' || ' / ' || (meta->>'categoria') || ' / confianza ' || (meta->>'confianza') FROM mensajes m JOIN casos c ON c.id = m.caso_id WHERE c.chat_id = '51999000111' AND m.rol = 'usuario' LIMIT 1")"

paso "Avisos: el motor los encola, la pasarela los envia (simulado) y los marca"
PENDIENTES_ANTES="$(psql_ -c "SELECT count(*) FROM avisos WHERE enviado_en IS NULL AND (error IS NULL OR error NOT LIKE 'semilla_sintetica%')")"
echo "   .    avisos enviables pendientes antes: $PENDIENTES_ANTES"
sleep 7
PENDIENTES_DESPUES="$(psql_ -c "SELECT count(*) FROM avisos WHERE enviado_en IS NULL AND (error IS NULL OR error NOT LIKE 'semilla_sintetica%') AND (intentos < 5)")"
echo "   .    avisos enviables pendientes despues: $PENDIENTES_DESPUES"
afirmar "ninguno quedo sin procesar" 0 "$PENDIENTES_DESPUES"
afirmar "ningun aviso salio a un numero real (modo simulado)" simulado "$(curl -s "${BASE}/api/salud" | jq -r .evolution)"

paso "Analitica: lo que encola la pasarela viaja con el formato del contrato"
afirmar_no_vacio "mensajes en el outbox" "$(psql_ -c "SELECT count(*) FROM outbox_analitica WHERE tabla = 'mensajes' AND enviado_en IS NULL AND payload->>'canal' = 'web'")"
afirmar_no_vacio "casos_estado en el outbox" "$(psql_ -c "SELECT count(*) FROM outbox_analitica WHERE tabla = 'casos_estado' AND enviado_en IS NULL AND payload->>'canal' = 'web'")"
echo "   .    (ClickHouse no esta configurado en esta prueba: el motor acumula el outbox; no se envia nada)"

paso "Indicadores: proxy a las golden queries (sin ClickHouse el motor contesta que no esta configurado)"
llamar GET "/api/indicadores?desde=2026-09-01&hasta=2026-09-30&serie=0" "" "$TOKEN_ADM"
echo "   .    HTTP $ESTADO: $(printf '%s' "$CUERPO" | jq -c '{kpis: (.kpis|length), primer_detalle: .kpis[0].detalle, error: .error}' 2>/dev/null)"

paso "Configuracion contra el esquema real"
llamar GET /api/sla "" "$TOKEN_ADM"
afirmar "SLA -> 200" 200 "$ESTADO"
afirmar_no_vacio "politicas sembradas por el motor" "$(campo .total)"
llamar GET /api/escalamiento/reglas "" "$TOKEN_ADM"
afirmar "reglas -> 200" 200 "$ESTADO"
echo "   .    reglas de escalamiento: $(campo '[.items[].clave] | join(", ")')"
llamar GET /api/tecnicos "" "$TOKEN_ADM"
afirmar "tecnicos -> 200" 200 "$ESTADO"
llamar GET /api/calendarios "" "$TOKEN_ADM"
afirmar "calendarios -> 200" 200 "$ESTADO"
llamar GET /api/matriz "" "$TOKEN_ADM"
afirmar "matriz -> 200 (16 celdas)" 16 "$(campo .total)"

printf '\n'
if [ "$FALLOS" -eq 0 ]; then printf 'E2E OK\n'; exit 0; else printf 'E2E CON %d FALLO(S)\n' "$FALLOS"; tail -25 /tmp/e2e_pasarela.log; exit 1; fi
