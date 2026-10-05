// Package storetest da a las pruebas una base Postgres efímera y aislada.
//
// Las pruebas que usan base se SALTAN (t.Skip) si la variable de entorno JSR_TEST_DB no está
// definida. JSR_TEST_DB es el DSN de un Postgres donde se pueda crear bases, por ejemplo
// postgres://postgres:pw@127.0.0.1:55432/postgres?sslmode=disable. scripts/test-db.sh levanta
// un contenedor y la exporta.
//
// Cada llamada a NuevaBD crea una base propia (jsr_test_<aleatorio>), le aplica las
// migraciones y la borra al terminar la prueba: las pruebas no se pisan aunque corran en
// paralelo o en procesos distintos.
package storetest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/store"
)

// VarEntorno es el nombre de la variable con el DSN administrativo.
const VarEntorno = "JSR_TEST_DB"

// Disponible dice si hay una base de pruebas configurada.
func Disponible() bool { return os.Getenv(VarEntorno) != "" }

// NuevaBD crea una base vacía con las migraciones aplicadas. Salta la prueba si no hay
// JSR_TEST_DB. No siembra configuración: use NuevaBDConConfig para eso.
func NuevaBD(t testing.TB) *store.DB {
	t.Helper()
	db, _ := nueva(t)
	return db
}

// NuevaBDConDSN es NuevaBD y además devuelve el DSN de la base creada (para probar binarios
// o abrir una segunda conexión).
func NuevaBDConDSN(t testing.TB) (*store.DB, string) {
	t.Helper()
	return nueva(t)
}

func nueva(t testing.TB) (*store.DB, string) {
	t.Helper()
	admin := os.Getenv(VarEntorno)
	if admin == "" {
		t.Skip("JSR_TEST_DB no está definida: se salta la prueba con base (use backend/scripts/test-db.sh)")
	}
	ctx := context.Background()

	b := make([]byte, 6)
	_, _ = rand.Read(b)
	nombre := "jsr_test_" + hex.EncodeToString(b)

	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		t.Fatalf("storetest: no conecta a %s: %v", VarEntorno, err)
	}
	if _, err := conn.Exec(ctx, `CREATE DATABASE `+nombre); err != nil {
		_ = conn.Close(ctx)
		t.Fatalf("storetest: crear base de pruebas: %v", err)
	}
	_ = conn.Close(ctx)

	dsn := dsnConBase(t, admin, nombre)
	db, err := store.Abrir(ctx, dsn)
	if err != nil {
		t.Fatalf("storetest: abrir base de pruebas: %v", err)
	}
	t.Cleanup(func() {
		db.Close()
		c, err := pgx.Connect(context.Background(), admin)
		if err != nil {
			return
		}
		defer c.Close(context.Background())
		cctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_, _ = c.Exec(cctx, `DROP DATABASE IF EXISTS `+nombre+` WITH (FORCE)`)
	})
	if _, err := db.Migrar(ctx); err != nil {
		t.Fatalf("storetest: migrar: %v", err)
	}
	return db, dsn
}

// NuevaBDConConfig es NuevaBD más la configuración por defecto (store.SembrarConfiguracion).
func NuevaBDConConfig(t testing.TB) *store.DB {
	t.Helper()
	db := NuevaBD(t)
	if err := store.SembrarConfiguracion(context.Background(), db); err != nil {
		t.Fatalf("storetest: sembrar configuración: %v", err)
	}
	return db
}

func dsnConBase(t testing.TB, dsn, base string) string {
	t.Helper()
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatalf("storetest: %s inválida: %v", VarEntorno, err)
		}
		u.Path = "/" + base
		return u.String()
	}
	return dsn + " dbname=" + base
}
