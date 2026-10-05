#!/usr/bin/env bash
# Crea (o actualiza) un administrador de la consola. La clave se pide sin eco y no pasa por argumentos.
set -euo pipefail
cd "$(dirname "$0")/.."
email="${1:-}"; nombre="${2:-Administrador}"
[ -n "$email" ] || { echo "uso: $0 correo@dominio [nombre]" >&2; exit 2; }
read -r -s -p "Clave (mínimo 12 caracteres): " clave; echo
[ "${#clave}" -ge 12 ] || { echo "la clave es muy corta" >&2; exit 2; }
docker compose exec -T -e PASARELA_ADMIN_CLAVE="$clave" pasarela /usr/local/bin/pasarela crear-admin --email "$email" --nombre "$nombre" --rol admin
