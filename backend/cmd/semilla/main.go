// Command semilla carga datos sintéticos deterministas en Postgres (sedes, personas, técnicos,
// ~600 incidencias de tres meses con casos difíciles, casos del asistente, encuestas...).
//
//	semilla -dsn postgres://... [-limpiar] [-incidencias 600] [-semilla 20261005] [-exportar dir]
//
// El DSN también puede venir de la variable DATABASE_URL (nunca se imprime). Sin -limpiar, si
// la base ya tiene la semilla no hace nada; con -limpiar la borra (solo lo sintético) y la
// vuelve a cargar idéntica. Se niega a trabajar sobre una base con datos que no son de la semilla.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"jsrbot/backend/internal/semilla"
	"jsrbot/backend/internal/store"
)

func main() {
	var (
		dsn         = flag.String("dsn", "", "DSN de Postgres (o variable DATABASE_URL)")
		limpiar     = flag.Bool("limpiar", false, "borra la semilla anterior y la vuelve a cargar")
		incidencias = flag.Int("incidencias", 600, "cuántas incidencias generar")
		personas    = flag.Int("personas", 40, "cuántas personas generar")
		semillaN    = flag.Uint64("semilla", 20261005, "semilla del generador (misma semilla = mismos datos)")
		exportar    = flag.String("exportar", "", "directorio donde escribir las filas de ClickHouse (JSONEachRow, un archivo por tabla)")
		migrar      = flag.Bool("migrar", true, "aplica las migraciones antes de cargar")
		json_       = flag.Bool("json", false, "imprime el resumen como JSON")
	)
	flag.Parse()
	if *dsn == "" {
		*dsn = os.Getenv("DATABASE_URL")
	}
	if *dsn == "" {
		fmt.Fprintln(os.Stderr, "semilla: falta -dsn (o DATABASE_URL)")
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	db, err := store.Abrir(ctx, *dsn)
	if err != nil {
		log.Fatalf("semilla: %v", err)
	}
	defer db.Close()
	if *migrar {
		hechas, err := db.Migrar(ctx)
		if err != nil {
			log.Fatalf("semilla: %v", err)
		}
		for _, h := range hechas {
			log.Printf("migración aplicada: %s", h)
		}
	}

	t0 := time.Now()
	r, err := semilla.Cargar(ctx, db, semilla.Opciones{
		Limpiar: *limpiar, Incidencias: *incidencias, Personas: *personas, Semilla: *semillaN,
		Log: func(f string, a ...any) { log.Printf(f, a...) },
	})
	if errors.Is(err, semilla.ErrDatosReales) {
		log.Fatalf("%v", err)
	}
	if err != nil {
		log.Fatalf("semilla: %v", err)
	}
	if r.Omitida {
		log.Printf("la base ya tiene la semilla; no se cambió nada (use -limpiar para recargarla)")
	}
	if *exportar != "" {
		cuenta, err := semilla.ExportarJSONL(ctx, db, *exportar)
		if err != nil {
			log.Fatalf("semilla: exportar: %v", err)
		}
		log.Printf("exportado a %s: %v", *exportar, cuenta)
	}
	if *json_ {
		b, _ := json.MarshalIndent(r, "", "  ")
		fmt.Println(string(b))
		return
	}
	fmt.Printf("semilla lista en %s: %d incidencias, %d eventos, %d casos, %d mensajes, %d encuestas, %d escalamientos, %d avisos (huella %s)\n",
		time.Since(t0).Round(time.Second), r.Incidencias, r.Eventos, r.Casos, r.Mensajes, r.Encuestas, r.Escalamientos, r.Avisos, r.Huella[:12])
}
