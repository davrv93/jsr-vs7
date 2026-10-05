// Package store es la capa de acceso a Postgres de jsrbot: pool de conexiones, ejecutor de
// migraciones, transacciones, configuración por defecto y los lectores comunes de SLA y
// avisos. La fuente de verdad es Postgres (ARQUITECTURA §8).
//
// Convenciones:
//   - todas las marcas de tiempo son timestamptz y se usan en UTC;
//   - el código de dominio recibe un Q (pool o transacción) para poder correr tanto suelto
//     como dentro de una transacción mayor.
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Q es lo que comparten *pgxpool.Pool y pgx.Tx: el código de dominio acepta un Q.
type Q interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ErrNoEncontrado se devuelve cuando una fila pedida por id no existe.
var ErrNoEncontrado = errors.New("no encontrado")

// DB es el pool de conexiones.
type DB struct {
	*pgxpool.Pool
}

// Abrir crea el pool y comprueba la conexión. dsn es una URL postgres:// o un DSN de libpq.
func Abrir(ctx context.Context, dsn string) (*DB, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("store: DSN inválido: %w", err)
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: no se pudo abrir el pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: la base no responde: %w", err)
	}
	return &DB{Pool: pool}, nil
}

// maxReintentosTx son los reintentos ante deadlock o fallo de serialización.
const maxReintentosTx = 3

// EnTx ejecuta f dentro de una transacción: COMMIT si devuelve nil; ROLLBACK si devuelve
// error o entra en pánico. Ante un deadlock (40P01) o un fallo de serialización (40001)
// repite f hasta 3 veces, así que f no debe tener efectos fuera de la base.
func (d *DB) EnTx(ctx context.Context, f func(tx pgx.Tx) error) error {
	var err error
	for intento := 0; intento < maxReintentosTx; intento++ {
		err = d.unaTx(ctx, f)
		if !esReintentable(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(intento+1) * 15 * time.Millisecond):
		}
	}
	return err
}

func (d *DB) unaTx(ctx context.Context, f func(tx pgx.Tx) error) (err error) {
	tx, err := d.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: no se pudo abrir la transacción: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback(context.Background())
			panic(p)
		}
		if err != nil {
			_ = tx.Rollback(context.Background())
		}
	}()
	if err = f(tx); err != nil {
		return err
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit: %w", err)
	}
	return nil
}

func esReintentable(err error) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code == "40001" || pe.Code == "40P01"
	}
	return false
}

// EsViolacionUnica dice si el error es un UNIQUE violado (23505).
func EsViolacionUnica(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

// UTC normaliza una hora al huso UTC (pgx devuelve las horas en el huso local del proceso).
func UTC(t time.Time) time.Time { return t.UTC() }

// UTCPtr normaliza un *time.Time.
func UTCPtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}
