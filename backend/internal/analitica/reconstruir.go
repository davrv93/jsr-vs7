package analitica

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/store"
)

// Conteo es lo que Reconstruir encoló, por tabla destino.
type Conteo map[string]int

const tamanoLote = 500

// Reconstruir regenera el outbox completo desde Postgres: es la prueba «borrar ClickHouse y
// reconstruir» (PLAN F7). Procedimiento:
//
//  1. vaciar (TRUNCATE) las tablas de ClickHouse;
//  2. llamar a Reconstruir: borra el outbox y lo vuelve a llenar con el estado actual de la base
//     (todos los eventos, la última versión de cada incidencia y de cada caso, mensajes,
//     encuestas y feedback), todo pendiente;
//  3. dejar correr el Trabajador.
//
// Borrar el outbox primero evita reenviar versiones intermedias o duplicar filas de las
// tablas que no deduplican (mensajes, encuestas, feedback). Es seguro porque el outbox es un
// derivado: la fuente de verdad es Postgres. Cada tabla se encola en transacciones de 500 filas.
func Reconstruir(ctx context.Context, db *store.DB) (Conteo, error) {
	if _, err := db.Exec(ctx, `DELETE FROM outbox_analitica`); err != nil {
		return nil, fmt.Errorf("analitica: limpiar el outbox: %w", err)
	}
	conteo := Conteo{}
	cache := store.NuevoCacheSLA(time.Minute)

	// 1. Eventos de incidencia: tal como se emitieron (el contexto viaja en datos).
	err := porLotes(ctx, db, `SELECT id FROM incidencia_eventos ORDER BY id`, func(tx pgx.Tx, ids []int64) error {
		rows, err := tx.Query(ctx, `SELECT e.id, e.incidencia_id, i.numero, e.ts, e.tipo, e.actor_tipo, e.actor_id, e.datos
			FROM incidencia_eventos e JOIN incidencias i ON i.id = e.incidencia_id WHERE e.id = ANY($1) ORDER BY e.id`, ids)
		if err != nil {
			return err
		}
		var evs []EventoIncidencia
		for rows.Next() {
			var ev EventoIncidencia
			if err := rows.Scan(&ev.ID, &ev.IncidenciaID, &ev.Numero, &ev.TS, &ev.Tipo, &ev.ActorTipo, &ev.ActorID, &ev.Datos); err != nil {
				rows.Close()
				return err
			}
			ev.TS = ev.TS.UTC()
			evs = append(evs, ev)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, ev := range evs {
			if err := EncolarEvento(ctx, tx, ev); err != nil {
				return err
			}
			conteo[TablaEventos]++
		}
		return nil
	})
	if err != nil {
		return conteo, err
	}

	// 2. Estado y tiempos: la última versión de cada incidencia.
	err = porLotes(ctx, db, `SELECT id FROM incidencias ORDER BY id`, func(tx pgx.Tx, ids []int64) error {
		for _, id := range ids {
			if err := EncolarIncidencia(ctx, tx, cache, id, time.Time{}); err != nil {
				return err
			}
			conteo[TablaEstado]++
			conteo[TablaTiempos]++
		}
		return nil
	})
	if err != nil {
		return conteo, err
	}

	// 3. Casos, mensajes, encuestas y feedback.
	simples := []struct {
		tabla string
		ids   string
		f     func(context.Context, store.Q, int64) error
	}{
		{TablaCasos, `SELECT id FROM casos ORDER BY id`, EncolarCaso},
		{TablaMensajes, `SELECT id FROM mensajes ORDER BY id`, EncolarMensaje},
		{TablaEncuestas, `SELECT id FROM encuestas ORDER BY id`, EncolarEncuesta},
		{TablaFeedback, `SELECT id FROM feedback ORDER BY id`, EncolarFeedback},
	}
	for _, s := range simples {
		err := porLotes(ctx, db, s.ids, func(tx pgx.Tx, ids []int64) error {
			for _, id := range ids {
				if err := s.f(ctx, tx, id); err != nil {
					return err
				}
				conteo[s.tabla]++
			}
			return nil
		})
		if err != nil {
			return conteo, err
		}
	}
	return conteo, nil
}

// porLotes lee los ids de la consulta y los procesa de a tamanoLote, cada lote en su transacción.
func porLotes(ctx context.Context, db *store.DB, consultaIDs string, f func(tx pgx.Tx, ids []int64) error) error {
	rows, err := db.Query(ctx, consultaIDs)
	if err != nil {
		return fmt.Errorf("analitica: reconstruir: %w", err)
	}
	var todos []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		todos = append(todos, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for i := 0; i < len(todos); i += tamanoLote {
		fin := min(i+tamanoLote, len(todos))
		lote := todos[i:fin]
		if err := db.EnTx(ctx, func(tx pgx.Tx) error { return f(tx, lote) }); err != nil {
			return fmt.Errorf("analitica: reconstruir: %w", err)
		}
	}
	return nil
}
