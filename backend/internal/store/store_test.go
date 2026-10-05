package store_test

import (
	"context"
	"errors"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5"

	migraciones "jsrbot/backend/migrations"

	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

func TestMigrarEsIdempotente(t *testing.T) {
	db := storetest.NuevaBD(t) // ya aplicó las migraciones una vez
	ctx := context.Background()
	hechas, err := db.Migrar(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(hechas) != 0 {
		t.Errorf("la segunda migración no debería aplicar nada: %v", hechas)
	}
	var n int
	if err := db.QueryRow(ctx, `SELECT count(*) FROM schema_migrations`).Scan(&n); err != nil || n < 2 {
		t.Errorf("schema_migrations = %d (%v), quiere >= 2 (001 y 002)", n, err)
	}
	// 003 y 004 se pueden reaplicar sin error (una base que ya las llevaba con otro nombre no falla).
	for _, n := range []string{"003_encuestas_puntaje_null.sql", "004_eventos_inmutables.sql"} {
		b, err := migraciones.Archivos.ReadFile(n)
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 2; i++ {
			if _, err := db.Exec(ctx, string(b)); err != nil {
				t.Errorf("%s (pasada %d): %v", n, i+1, err)
			}
		}
	}
	// Una encuesta enviada y sin responder (puntaje NULL) es válida; fuera de 1-5 no.
	if _, err := db.Exec(ctx, `INSERT INTO encuestas (puntaje) VALUES (NULL)`); err != nil {
		t.Errorf("encuestas.puntaje debe admitir NULL: %v", err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO encuestas (puntaje) VALUES (9)`); err == nil {
		t.Error("el puntaje 9 debe rechazarse")
	}
	// Las tablas de 001 y de 002 existen.
	for _, tabla := range []string{"incidencias", "incidencia_eventos", "outbox_analitica", "avisos", "escalamientos"} {
		var ok bool
		if err := db.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, tabla).Scan(&ok); err != nil || !ok {
			t.Errorf("falta la tabla %s", tabla)
		}
	}
}

func TestMigrarAplicaSoloLasNuevasYRevierteLasRotas(t *testing.T) {
	db := storetest.NuevaBD(t)
	ctx := context.Background()
	fsys := fstest.MapFS{
		"001_esquema.sql": {Data: []byte(`CREATE TABLE nunca (id int);`)}, // ya registrada: se salta
		"002_avisos.sql":  {Data: []byte(`CREATE TABLE nunca2 (id int);`)},
		"003_nueva.sql":   {Data: []byte(`CREATE TABLE prueba_a (id int); CREATE TABLE prueba_b (id int);`)},
		"004_rota.sql":    {Data: []byte(`CREATE TABLE prueba_c (id int); SELECT algo_que_no_existe();`)},
		"005_despues.sql": {Data: []byte(`CREATE TABLE prueba_d (id int);`)},
	}
	hechas, err := db.MigrarDesde(ctx, fsys)
	if err == nil {
		t.Fatal("la migración rota debería fallar")
	}
	if len(hechas) != 1 || hechas[0] != "003_nueva.sql" {
		t.Errorf("aplicadas = %v, quiere solo 003_nueva.sql", hechas)
	}
	existe := func(tabla string) bool {
		var ok bool
		_ = db.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, tabla).Scan(&ok)
		return ok
	}
	if !existe("prueba_a") || !existe("prueba_b") {
		t.Error("003 (varias sentencias) debería haberse aplicado completa")
	}
	if existe("prueba_c") {
		t.Error("004 falló a medias: su transacción debía revertirse")
	}
	if existe("prueba_d") || existe("nunca") || existe("nunca2") {
		t.Error("no debía aplicar 005 tras el fallo ni reaplicar 001/002")
	}
}

func TestSembrarConfiguracionEsIdempotenteYNoPisaEdiciones(t *testing.T) {
	db := storetest.NuevaBD(t)
	ctx := context.Background()
	if err := store.SembrarConfiguracion(ctx, db); err != nil {
		t.Fatal(err)
	}
	contar := func() map[string]int {
		out := map[string]int{}
		for _, tabla := range []string{"configuracion", "calendarios", "feriados", "matriz_prioridad", "grupos", "categorias",
			"sla_politicas", "escalamiento_reglas"} {
			var n int
			if err := db.QueryRow(ctx, `SELECT count(*) FROM `+tabla).Scan(&n); err != nil {
				t.Fatal(err)
			}
			out[tabla] = n
		}
		return out
	}
	antes := contar()

	// Un administrador edita una política y el calendario base.
	if _, err := db.Exec(ctx, `UPDATE sla_politicas SET respuesta_min = 7 WHERE prioridad = 'P2'`); err != nil {
		t.Fatal(err)
	}
	if err := store.GuardarConfig(ctx, db, store.ConfVIPPrioridadMinima, "P1"); err != nil {
		t.Fatal(err)
	}

	if err := store.SembrarConfiguracion(ctx, db); err != nil {
		t.Fatal(err)
	}
	despues := contar()
	for k, v := range antes {
		if despues[k] != v {
			t.Errorf("%s: %d filas antes y %d después de sembrar otra vez", k, v, despues[k])
		}
	}
	var resp int
	_ = db.QueryRow(ctx, `SELECT respuesta_min FROM sla_politicas WHERE prioridad = 'P2'`).Scan(&resp)
	if resp != 7 {
		t.Errorf("sembrar pisó la edición del administrador: respuesta_min = %d", resp)
	}
	if v, _ := store.ConfigTexto(ctx, db, store.ConfVIPPrioridadMinima, "?"); v != "P1" {
		t.Errorf("sembrar pisó la configuración editada: %q", v)
	}

	// Contenido esperado.
	if antes["matriz_prioridad"] != 16 || antes["categorias"] != 10 || antes["grupos"] != 4 || antes["sla_politicas"] != 4 {
		t.Errorf("conteos inesperados: %v", antes)
	}
	if antes["escalamiento_reglas"] != len(store.ReglasDefecto()) {
		t.Errorf("reglas = %d", antes["escalamiento_reglas"])
	}
	var noSombra int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM escalamiento_reglas WHERE modo <> 'sombra'`).Scan(&noSombra)
	if noSombra != 0 {
		t.Errorf("las reglas sembradas deben nacer en sombra; %d no", noSombra)
	}
}

func TestCargadoresDeSLA(t *testing.T) {
	db := storetest.NuevaBDConConfig(t)
	ctx := context.Background()
	id, cal, err := store.CalendarioPorNombre(ctx, db, store.NombreCalendarioLaboral)
	if err != nil || id == 0 {
		t.Fatal(id, err)
	}
	lima, _ := time.LoadLocation("America/Lima")
	// Jueves 23-jul-2026 es feriado; sábado no es laboral; lunes a las 9 sí.
	if !cal.EsFeriado(time.Date(2026, 7, 23, 10, 0, 0, 0, lima)) {
		t.Error("23-jul-2026 debería ser feriado")
	}
	if !cal.EsLaboral(time.Date(2026, 10, 5, 9, 0, 0, 0, lima)) || cal.EsLaboral(time.Date(2026, 10, 10, 9, 0, 0, 0, lima)) {
		t.Error("horario laboral mal cargado")
	}
	m, err := store.CargarMatriz(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if p, _ := m.Prioridad("sede", "alta"); p != "P2" {
		t.Errorf("matriz sede x alta = %s", p)
	}
	cache := store.NuevoCacheSLA(time.Minute)
	c1, err := cache.Contexto(ctx, db, "P1", nil)
	if err != nil || !c1.Cal.VeinticuatroSiete || c1.Pol.RespuestaMin != 15 || c1.Pol.ResolucionMin != 240 {
		t.Errorf("P1 = %+v (%v)", c1, err)
	}
	c3, err := cache.Contexto(ctx, db, "P3", nil)
	if err != nil || c3.Cal.VeinticuatroSiete || c3.Pol.ResolucionMin != 1440 {
		t.Errorf("P3 = %+v (%v)", c3, err)
	}
	if _, cal2, err := cache.Base(ctx, db); err != nil || cal2.Nombre != store.NombreCalendarioLaboral {
		t.Errorf("Base = %v (%v)", cal2, err)
	}
	if _, err := store.BuscarPolitica(ctx, db, "P9", nil); !errors.Is(err, store.ErrNoEncontrado) {
		t.Errorf("política inexistente: %v", err)
	}
	var _ sla.Matriz = m
}

func TestEnTxRevierteAnteErrorYPanico(t *testing.T) {
	db := storetest.NuevaBD(t)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `CREATE TABLE t_tx (n int)`); err != nil {
		t.Fatal(err)
	}
	cuenta := func() int {
		var n int
		_ = db.QueryRow(ctx, `SELECT count(*) FROM t_tx`).Scan(&n)
		return n
	}
	// Commit.
	if err := db.EnTx(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO t_tx VALUES (1)`)
		return err
	}); err != nil || cuenta() != 1 {
		t.Fatalf("commit: %v, filas %d", err, cuenta())
	}
	// Error devuelto: rollback.
	boom := errors.New("boom")
	if err := db.EnTx(ctx, func(tx pgx.Tx) error {
		_, _ = tx.Exec(ctx, `INSERT INTO t_tx VALUES (2)`)
		return boom
	}); !errors.Is(err, boom) || cuenta() != 1 {
		t.Fatalf("rollback por error: %v, filas %d", err, cuenta())
	}
	// Pánico: rollback y el pánico sigue su camino.
	func() {
		defer func() {
			if recover() == nil {
				t.Error("el pánico debía propagarse")
			}
		}()
		_ = db.EnTx(ctx, func(tx pgx.Tx) error {
			_, _ = tx.Exec(ctx, `INSERT INTO t_tx VALUES (3)`)
			panic("pánico")
		})
	}()
	if cuenta() != 1 {
		t.Errorf("el pánico no revirtió: %d filas", cuenta())
	}
}

func TestAvisosSeEncolanUnaSolaVez(t *testing.T) {
	db := storetest.NuevaBDConConfig(t)
	ctx := context.Background()
	ahora := time.Date(2026, 10, 5, 14, 0, 0, 0, time.UTC)
	a := store.NuevoAviso{DestinatarioTipo: store.DestSupervisor, Plantilla: "p1_creada", Clave: "k1",
		Datos: map[string]any{"numero": "INC-000001"}}
	id1, nuevo1, err := store.EncolarAviso(ctx, db, a, ahora)
	if err != nil || !nuevo1 || id1 == 0 {
		t.Fatal(id1, nuevo1, err)
	}
	_, nuevo2, err := store.EncolarAviso(ctx, db, a, ahora)
	if err != nil || nuevo2 {
		t.Errorf("el mismo aviso no debe encolarse dos veces: nuevo=%v err=%v", nuevo2, err)
	}
	if _, _, err := store.EncolarAviso(ctx, db, store.NuevoAviso{DestinatarioTipo: "tecnico", Plantilla: "x"}, ahora); err == nil {
		t.Error("sin clave debe fallar")
	}
	pend, err := store.AvisosPendientes(ctx, db, 10)
	if err != nil || len(pend) != 1 || pend[0].Datos["numero"] != "INC-000001" || pend[0].Canal != "whatsapp" {
		t.Fatalf("pendientes = %+v (%v)", pend, err)
	}
	if err := store.MarcarAvisoEnviado(ctx, db, id1, ahora); err != nil {
		t.Fatal(err)
	}
	if pend, _ := store.AvisosPendientes(ctx, db, 10); len(pend) != 0 {
		t.Errorf("tras enviar no debe quedar pendiente: %+v", pend)
	}
}
