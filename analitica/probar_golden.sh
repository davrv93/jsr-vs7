#!/usr/bin/env bash
# analitica/probar_golden.sh · Prueba de las 12 golden queries (AGENTS.md 1.3).
#
#   cd analitica && ./probar_golden.sh
#
# Levanta un ClickHouse EFIMERO con el perfil de poca memoria, aplica esquema.sql, carga la semilla por lotes (como el
# backend), ejecuta cada golden query con el usuario de solo lectura y compara con su esperado*.csv. Ademas:
#   * recalcula cada esperado con un calculo INDEPENDIENTE en Python;
#   * prueba que la prueba detecta (esperados alterados, 26 mutantes de SQL);
#   * comprueba el usuario analista, el perfil de poca memoria, los duplicados y kpi_diario;
#   * vuelve a ejecutar todo tras fusionar las partes (OPTIMIZE FINAL).
# Imprime una tabla OK/FALLA y sale con codigo distinto de cero si algo falla. Apaga el contenedor siempre.
#
# Opciones:
#   --generar-esperados   reescribe los esperado*.csv, pero SOLO si coinciden con el calculo independiente en Python
# Variables: JSR_CH_IMAGEN (imagen de ClickHouse), JSR_CH_PRUEBA_MEMORIA (tope del contenedor, 3g por defecto)
set -u
cd "$(dirname "$0")" || exit 2
# shellcheck source=herramientas/ch.sh
. herramientas/ch.sh
trap 'ch_apagar' EXIT INT TERM

paso() { printf '\n== %s\n' "$1"; }

paso "1/4 La semilla, el catalogo y el calendario son reproducibles y coherentes"
python3 semilla/generar_semilla.py --autoprueba >/dev/null || { echo "FALLA: autoprueba del calendario"; exit 1; }
python3 semilla/generar_semilla.py --verificar || { echo "FALLA: la semilla guardada no coincide con lo que genera el codigo"; exit 1; }
python3 semilla/validar_semilla.py || { echo "FALLA: la semilla es incoherente"; exit 1; }
( cd semilla && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 || sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || { echo "FALLA: SHA256SUMS no coincide"; exit 1; }
GENERANDO=0
[ "${1:-}" = "--generar-esperados" ] && GENERANDO=1
if [ "$GENERANDO" -eq 0 ]; then
  python3 herramientas/generar_catalogo.py --verificar || exit 1
fi

paso "2/4 ClickHouse efimero con el perfil de poca memoria"
ch_levantar || exit 1
echo "ClickHouse $(ch_version) · imagen $CH_IMAGEN · tope del contenedor $CH_MEMORIA"

paso "3/4 Pruebas"
python3 herramientas/ejecutar_pruebas.py "$@"
rc=$?
if [ "$GENERANDO" -eq 1 ]; then
  [ "$rc" -eq 0 ] && python3 herramientas/generar_catalogo.py
  exit "$rc"
fi

paso "4/4 Memoria usada por ClickHouse (tope del contenedor $CH_MEMORIA)"
echo "$(ch_memoria)"
if [ "$rc" -eq 0 ]; then
  printf '\nGOLDEN QUERIES EN VERDE\n'
else
  printf '\nHAY FALLAS (codigo %s)\n' "$rc"
fi
exit "$rc"
