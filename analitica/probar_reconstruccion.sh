#!/usr/bin/env bash
# analitica/probar_reconstruccion.sh · Vaciar ClickHouse y recargarlo da las mismas cifras (reconstruir.md).
#   ./probar_reconstruccion.sh              compara contra semilla/checksums_clickhouse.txt
#   ./probar_reconstruccion.sh --actualizar reescribe ese archivo (solo si cambio la semilla o el esquema a proposito)
set -u
cd "$(dirname "$0")" || exit 2
. herramientas/ch.sh
trap 'ch_apagar' EXIT INT TERM
ch_levantar || exit 1
echo "ClickHouse $(ch_version) · imagen $CH_IMAGEN"
python3 herramientas/probar_reconstruccion.py "$@"
rc=$?
[ "$rc" -eq 0 ] && printf '\nRECONSTRUCCION IDENTICA\n' || printf '\nLA RECONSTRUCCION DIFIERE (codigo %s)\n' "$rc"
exit "$rc"
