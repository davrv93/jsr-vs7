#!/usr/bin/env bash
# Crea .env con secretos al azar. NO imprime ningún secreto. No pisa un .env existente.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -e .env ] && { echo ".env ya existe: no lo piso. Bórralo a mano si quieres regenerarlo." >&2; exit 1; }
aleatorio() { openssl rand -hex 24; }
sha256() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
ch_clave="$(aleatorio)"; ch_analista="$(aleatorio)"
umask 077
cat > .env <<ENV
# Generado por despliegue/generar-env.sh. NO se sube a git. Rota una clave cambiándola aquí y recreando el servicio.
JSR_PG_CLAVE=$(aleatorio)
MOTOR_CLAVE=$(aleatorio)
JWT_SECRET=$(aleatorio)
WEBHOOK_SECRET=$(aleatorio)
JSR_CH_USUARIO=jsr
JSR_CH_CLAVE=${ch_clave}
JSR_CH_CLAVE_SHA256=$(sha256 "$ch_clave")
JSR_CH_ANALISTA_USUARIO=analista
JSR_CH_ANALISTA_CLAVE=${ch_analista}
JSR_CH_ANALISTA_CLAVE_SHA256=$(sha256 "$ch_analista")
JSR_URL_PUBLICA=http://localhost:18580
JSR_HTTP_PORT=18580
# WhatsApp: «simulado» no envía nada. Para el modo real hace falta el perfil whatsapp y las tres variables de abajo.
EVOLUTION_MODO=simulado
EVOLUTION_API_KEY=$(aleatorio)
EVOLUTION_INSTANCIA=
EVOLUTION_DB_CLAVE=$(aleatorio)
# Redacción con LLM (opcional; sin clave el asistente responde por plantillas y código).
OPENROUTER_API_KEY=
VERIFICAR_MODO=sombra
ENV
echo ".env creado ($(grep -c '=' .env) variables). Revisa EVOLUTION_* y OPENROUTER_API_KEY si los vas a usar."
