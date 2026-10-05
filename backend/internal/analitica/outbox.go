// Package analitica lleva los cambios de Postgres a ClickHouse con el patrón outbox
// (ARQUITECTURA §8.2): cada cambio inserta, EN LA MISMA TRANSACCIÓN, una fila en
// outbox_analitica; un trabajador las manda por lotes al HTTP de ClickHouse y marca
// enviado_en. ClickHouse nunca es fuente de verdad (AGENTS §1.4 regla 8): se puede borrar y
// reconstruir con Reconstruir.
//
// Este paquete solo conoce las tablas de la base y sus columnas (contrato en
// docs/CONTRATOS.md §4: las claves de cada payload son exactamente las columnas de la tabla
// destino). No decide nada de negocio.
package analitica

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"jsrbot/backend/internal/store"
)

// Tablas destino en ClickHouse (docs/CONTRATOS.md §4).
const (
	TablaEventos   = "eventos_incidencia"
	TablaEstado    = "incidencias_estado"
	TablaTiempos   = "incidencias_tiempos"
	TablaCasos     = "casos_estado"
	TablaMensajes  = "mensajes"
	TablaEncuestas = "encuestas"
	TablaFeedback  = "feedback"
)

var tablasValidas = map[string]bool{
	TablaEventos: true, TablaEstado: true, TablaTiempos: true, TablaCasos: true,
	TablaMensajes: true, TablaEncuestas: true, TablaFeedback: true,
}

// Encolar inserta una fila en outbox_analitica. Llámese con la transacción del cambio que
// la origina, para que el cambio y su fila se confirmen o se reviertan juntos.
//
// clave es el id estable que deduplica (p. ej. "ev-123", "inc-7-1759680000000"); payload se
// serializa a JSON y sus claves deben ser las columnas de la tabla destino.
func Encolar(ctx context.Context, q store.Q, tabla, clave string, payload any) error {
	if !tablasValidas[tabla] {
		return fmt.Errorf("analitica: tabla %q desconocida", tabla)
	}
	if clave == "" {
		return fmt.Errorf("analitica: la fila de %s necesita clave", tabla)
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("analitica: payload de %s %s: %w", tabla, clave, err)
	}
	if _, err := q.Exec(ctx, `INSERT INTO outbox_analitica (tabla, clave, payload) VALUES ($1, $2, $3)`, tabla, clave, raw); err != nil {
		return fmt.Errorf("analitica: encolar %s %s: %w", tabla, clave, err)
	}
	return nil
}

// fmtTS da una hora en ISO 8601 UTC: "2026-10-05T14:30:00Z" (con milisegundos solo si los hay).
func fmtTS(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond() == 0 {
		return t.Format("2006-01-02T15:04:05Z")
	}
	return t.Format("2006-01-02T15:04:05.000Z")
}

func fmtTSPtr(t *time.Time) any {
	if t == nil {
		return nil
	}
	return fmtTS(*t)
}

// Version devuelve la versión de una fila para ReplacingMergeTree: milisegundos epoch.
func Version(t time.Time) int64 { return t.UTC().UnixMilli() }

// boolInt convierte un *bool a 0/1/nil (las columnas *_ok son 0/1, NULL si aún no aplica).
func boolInt(b *bool) any {
	if b == nil {
		return nil
	}
	if *b {
		return 1
	}
	return 0
}

// minutos redondea a minutos enteros (compatible con columnas enteras y de coma flotante).
func minutos(f *float64) any {
	if f == nil {
		return nil
	}
	return int64(*f + 0.5)
}
