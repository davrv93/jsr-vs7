package store

import (
	"context"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	migraciones "jsrbot/backend/migrations"
)

// claveBloqueoMigracion es el id del advisory lock que serializa a dos procesos que migran a la vez.
const claveBloqueoMigracion = 7482001

// Migrar aplica, en orden de nombre, las migraciones embebidas (backend/migrations/*.sql)
// que todavía no estén en schema_migrations. Cada migración corre en su propia
// transacción junto con su registro. Devuelve los nombres aplicados en esta llamada.
// Es seguro llamarla en cada arranque y desde dos procesos a la vez.
func (d *DB) Migrar(ctx context.Context) ([]string, error) {
	return d.MigrarDesde(ctx, migraciones.Archivos)
}

// MigrarDesde es Migrar con un sistema de archivos dado (para pruebas).
func (d *DB) MigrarDesde(ctx context.Context, fsys fs.FS) ([]string, error) {
	conn, err := d.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("store: migrar: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, claveBloqueoMigracion); err != nil {
		return nil, fmt.Errorf("store: migrar: bloqueo: %w", err)
	}
	defer func() { _, _ = conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, claveBloqueoMigracion) }()

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version text PRIMARY KEY,
		aplicada_en timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, fmt.Errorf("store: migrar: tabla de control: %w", err)
	}

	hechas := map[string]bool{}
	rows, err := conn.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("store: migrar: %w", err)
	}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return nil, err
		}
		hechas[v] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	entradas, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return nil, fmt.Errorf("store: migrar: leer migraciones: %w", err)
	}
	var nombres []string
	for _, e := range entradas {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			nombres = append(nombres, e.Name())
		}
	}
	sort.Strings(nombres)

	var aplicadas []string
	for _, n := range nombres {
		if hechas[n] {
			continue
		}
		sqlTxt, err := fs.ReadFile(fsys, n)
		if err != nil {
			return aplicadas, fmt.Errorf("store: migrar %s: %w", n, err)
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			return aplicadas, fmt.Errorf("store: migrar %s: %w", n, err)
		}
		// Sin argumentos pgx usa el protocolo simple: acepta varias sentencias en un archivo.
		if _, err := tx.Exec(ctx, string(sqlTxt)); err != nil {
			_ = tx.Rollback(ctx)
			return aplicadas, fmt.Errorf("store: migrar %s: %w", n, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, n); err != nil {
			_ = tx.Rollback(ctx)
			return aplicadas, fmt.Errorf("store: migrar %s: registro: %w", n, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return aplicadas, fmt.Errorf("store: migrar %s: commit: %w", n, err)
		}
		aplicadas = append(aplicadas, n)
	}
	return aplicadas, nil
}
