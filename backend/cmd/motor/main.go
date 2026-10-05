// Command motor es el motor de jsrbot: la API HTTP INTERNA de incidencias (docs/CONTRATOS.md §5)
// más, en segundo plano, el vigía de SLA (cada minuto), el vaciado del outbox hacia ClickHouse
// (cada 10 s) y el cierre automático de resueltas sin confirmación.
//
// Variables de entorno (nunca se imprimen):
//
//	DATABASE_URL       DSN de Postgres (obligatoria)
//	MOTOR_CLAVE        clave de la cabecera X-Interno-Clave (obligatoria, >= 16 caracteres)
//	MOTOR_ADDR         dónde escuchar (por defecto :8090; solo red del compose, nunca publicado)
//	ANALITICA_DIR      carpeta analitica/ con catalogo.json, golden/ y esquema.sql (por defecto ./analitica o /analitica)
//	JSR_CH_URL, JSR_CH_USUARIO, JSR_CH_CLAVE, JSR_CH_BASE        ClickHouse, escritura (outbox)
//	JSR_CH_ANALISTA_USUARIO, JSR_CH_ANALISTA_CLAVE              ClickHouse, solo lectura (golden queries)
//	MOTOR_VIGIA=0      apaga el vigía de fondo;  MOTOR_OUTBOX=0 apaga el vaciado del outbox
//
// Con -salud hace una comprobación local (para el HEALTHCHECK de la imagen, que no trae shell).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/golden"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/motor"
	"jsrbot/backend/internal/store"
)

// version se fija al compilar: -ldflags "-X main.version=1.2.3".
var version = "dev"

func main() {
	salud := flag.Bool("salud", false, "comprueba el motor local (GET /interno/salud) y sale con 0 si responde")
	ver := flag.Bool("version", false, "imprime la versión")
	flag.Parse()
	if *ver {
		fmt.Println(version)
		return
	}
	addr := envOr("MOTOR_ADDR", ":8090")
	if *salud {
		os.Exit(comprobarSalud(addr))
	}
	if err := ejecutar(addr); err != nil {
		log.Fatalf("motor: %v", err)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func ejecutar(addr string) error {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("falta DATABASE_URL")
	}
	clave := os.Getenv("MOTOR_CLAVE")
	if len(clave) < 16 {
		return errors.New("MOTOR_CLAVE es obligatoria y debe tener al menos 16 caracteres")
	}

	ctx, parar := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer parar()

	// Postgres puede tardar en arrancar en el compose: se reintenta un minuto.
	var db *store.DB
	var err error
	for intento := 1; ; intento++ {
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		db, err = store.Abrir(cctx, dsn)
		cancel()
		if err == nil {
			break
		}
		if intento >= 12 || ctx.Err() != nil {
			return fmt.Errorf("no se pudo abrir Postgres: %w", err)
		}
		log.Printf("motor: Postgres no responde (intento %d): reintento en 5 s", intento)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
	defer db.Close()

	if envOr("MOTOR_MIGRAR", "1") != "0" {
		hechas, err := db.Migrar(ctx)
		if err != nil {
			return err
		}
		for _, h := range hechas {
			log.Printf("motor: migración aplicada: %s", h)
		}
		if err := store.SembrarConfiguracion(ctx, db); err != nil {
			return err
		}
	}

	inc := incidencia.Nuevo(db)
	vig := escala.Nuevo(inc)

	cfgCH := analitica.ConfigDesdeEntorno()
	trab := analitica.NuevoTrabajador(db, cfgCH)
	chOK := cfgCH.URL != ""

	dirAnalitica := carpetaAnalitica()
	var esquema string
	if b, err := os.ReadFile(filepath.Join(dirAnalitica, "esquema.sql")); err == nil {
		esquema = string(b)
	}
	if chOK && esquema != "" {
		// Idempotente. Si ClickHouse aún no arrancó no es fatal: el outbox espera.
		cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		if err := trab.AplicarEsquema(cctx, esquema); err != nil {
			log.Printf("motor: no se pudo aplicar el esquema de ClickHouse (se reintenta al reconstruir): %v", err)
		}
		cancel()
	}
	var gold *golden.Golden
	if lector := golden.LectorDesdeEntorno(); lector != nil {
		gold = golden.Nuevo(dirAnalitica, lector)
	} else {
		gold = golden.Nuevo(dirAnalitica, nil)
	}

	srv := motor.Nuevo(motor.Config{
		DB: db, Clave: clave, Version: version, Inc: inc, Vigia: vig, Analitica: trab, Golden: gold,
		EsquemaCH: esquema, ClickHouseConfigurado: chOK,
	})
	servidor := &http.Server{
		Addr: addr, Handler: srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 60 * time.Second, WriteTimeout: 120 * time.Second, IdleTimeout: 2 * time.Minute,
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	fin := make(chan error, 1)
	go func() { fin <- servidor.Serve(ln) }()
	log.Printf("motor %s escuchando en %s (vigía cada %s, outbox cada %s, ClickHouse %s)", version, addr, motor.IntervaloVigia, motor.IntervaloOutbox, si(chOK, "configurado", "sin configurar"))

	fondoCtx, cancelarFondo := context.WithCancel(ctx)
	hechoFondo := make(chan struct{})
	go func() {
		srv.Fondo(fondoCtx, envOr("MOTOR_VIGIA", "1") != "0", envOr("MOTOR_OUTBOX", "1") != "0")
		close(hechoFondo)
	}()

	select {
	case <-ctx.Done():
	case err := <-fin:
		if !errors.Is(err, http.ErrServerClosed) {
			cancelarFondo()
			return err
		}
	}
	log.Printf("motor: apagando")
	sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = servidor.Shutdown(sctx)
	cancelarFondo()
	<-hechoFondo
	return nil
}

func si(c bool, a, b string) string {
	if c {
		return a
	}
	return b
}

// carpetaAnalitica busca analitica/ : ANALITICA_DIR, ./analitica, ../analitica o /analitica.
func carpetaAnalitica() string {
	for _, c := range []string{os.Getenv("ANALITICA_DIR"), "analitica", "../analitica", "/analitica"} {
		if c == "" {
			continue
		}
		if st, err := os.Stat(filepath.Join(c, "catalogo.json")); err == nil && !st.IsDir() {
			return c
		}
	}
	if d := os.Getenv("ANALITICA_DIR"); d != "" {
		return d
	}
	return "analitica"
}

// comprobarSalud llama a /interno/salud del propio motor con la clave del entorno.
func comprobarSalud(addr string) int {
	host := addr
	if strings.HasPrefix(host, ":") {
		host = "127.0.0.1" + host
	}
	req, err := http.NewRequest(http.MethodGet, "http://"+host+"/interno/salud", nil)
	if err != nil {
		return 1
	}
	req.Header.Set("X-Interno-Clave", os.Getenv("MOTOR_CLAVE"))
	cli := &http.Client{Timeout: 4 * time.Second}
	resp, err := cli.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "motor: sin respuesta")
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "motor: HTTP %d\n", resp.StatusCode)
		return 1
	}
	return 0
}
