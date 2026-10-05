// Package semilla genera datos sintéticos DETERMINISTAS para jsrbot: sedes, áreas, personas,
// técnicos con turnos y guardias, y unas 600 incidencias de tres meses con los casos difíciles
// (creada un viernes 17:55, feriados, pausas, reaperturas, escalamientos, P1 fuera de horario,
// nunca resueltas, sin primera respuesta, encuestas, casos resueltos solo por el asistente).
//
// Los estados, eventos y filas de outbox NO se insertan a mano: los producen los paquetes
// incidencia, escala y analitica, moviendo un reloj inyectable, de modo que la semilla prueba
// de paso que el código cuadra consigo mismo. Con la misma semilla (Opciones.Semilla) y las
// mismas fechas, dos corridas dejan exactamente los mismos datos (ver Resumen.Huella).
//
// Todo queda marcado como sintético: configuracion.semilla_sintetica, números de WhatsApp
// 5100000xxxx (no válidos), correos @empresa.example y avisos marcados como no enviables.
package semilla

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/store"
)

// ErrDatosReales se devuelve si la base tiene datos que no son de la semilla: nunca se mezcla
// ni se borra lo que no se reconoce como sintético.
var ErrDatosReales = errors.New("semilla: la base ya tiene datos que no son de la semilla; no se mezcla ni se borra")

// Opciones de Cargar.
type Opciones struct {
	// Limpiar borra primero lo que cargó una corrida anterior de la semilla (y solo eso).
	Limpiar bool
	// Semilla del generador pseudoaleatorio (por defecto 20261005).
	Semilla uint64
	// Desde y Hasta acotan el periodo (por defecto 01-jul-2026 00:00 a 30-sep-2026 23:59, hora de Lima).
	Desde, Hasta time.Time
	// Incidencias es el volumen (por defecto 600); Personas, la plantilla de usuarios (40);
	// CasosAsistente, los casos que el asistente resolvió solo (por defecto 40 % de Incidencias).
	Incidencias    int
	Personas       int
	CasosAsistente int
	// Log recibe avisos de progreso (opcional).
	Log func(formato string, args ...any)
}

func (o Opciones) conDefectos() Opciones {
	lima, _ := time.LoadLocation("America/Lima")
	if o.Semilla == 0 {
		o.Semilla = 20261005
	}
	if o.Desde.IsZero() {
		o.Desde = time.Date(2026, 7, 1, 0, 0, 0, 0, lima)
	}
	if o.Hasta.IsZero() {
		o.Hasta = time.Date(2026, 9, 30, 23, 59, 0, 0, lima)
	}
	if o.Incidencias <= 0 {
		o.Incidencias = 600
	}
	if o.Personas <= 0 {
		o.Personas = 40
	}
	if o.CasosAsistente <= 0 {
		o.CasosAsistente = o.Incidencias * 2 / 5
	}
	return o
}

// Resumen de una corrida (o de Contar).
type Resumen struct {
	// Omitida: la base ya tenía la semilla y no se pidió Limpiar; no se cambió nada.
	Omitida bool `json:"omitida"`

	Sedes         int `json:"sedes"`
	Areas         int `json:"areas"`
	Personas      int `json:"personas"`
	Tecnicos      int `json:"tecnicos"`
	Grupos        int `json:"grupos"`
	Incidencias   int `json:"incidencias"`
	Eventos       int `json:"eventos"`
	Escalamientos int `json:"escalamientos"`
	Avisos        int `json:"avisos"`
	Casos         int `json:"casos"`
	Mensajes      int `json:"mensajes"`
	Encuestas     int `json:"encuestas"`
	Feedback      int `json:"feedback"`
	OutboxFilas   int `json:"outbox_filas"`

	PorEstado     map[string]int `json:"por_estado"`
	PorPrioridad  map[string]int `json:"por_prioridad"`
	PorTipoEvento map[string]int `json:"por_tipo_evento"`

	// Saltadas son acciones de guion que el estado ya no permitía (escaladas, cerradas solas...).
	Saltadas int `json:"saltadas"`
	// Huella es el SHA-256 de todo el outbox en orden: dos corridas iguales dan la misma huella.
	Huella string `json:"huella"`
}

// Cargar carga la semilla sintética en la base y devuelve el resumen. Pasos:
//
//  1. aplica la configuración por defecto (idempotente);
//  2. si ya hay semilla y no se pidió Limpiar, no hace nada (Omitida);
//  3. si hay datos que no son de la semilla, se niega (ErrDatosReales);
//  4. con Limpiar, borra lo sintético anterior y reinicia las secuencias (así los ids y los
//     números INC-000001 se repiten idénticos en cada corrida);
//  5. inserta los datos maestros y simula tres meses moviendo un reloj: el servicio de
//     incidencias crea y mueve las incidencias, el vigía (con las reglas en modo ACTIVO durante
//     la carga) escala y deja avisos, y el outbox de ClickHouse se llena solo;
//  6. restaura el modo de las reglas, marca los avisos como no enviables y deja el marcador.
func Cargar(ctx context.Context, db *store.DB, o Opciones) (*Resumen, error) {
	o = o.conDefectos()
	log := o.Log
	if log == nil {
		log = func(string, ...any) {}
	}
	if err := store.SembrarConfiguracion(ctx, db); err != nil {
		return nil, err
	}
	_, existe, err := store.LeerConfig(ctx, db, store.ConfSemillaSintetica)
	if err != nil {
		return nil, err
	}
	if existe && !o.Limpiar {
		r, err := Contar(ctx, db)
		if err != nil {
			return nil, err
		}
		r.Omitida = true
		return r, nil
	}
	if !existe {
		hay, err := hayDatos(ctx, db)
		if err != nil {
			return nil, err
		}
		if hay {
			return nil, ErrDatosReales
		}
	}
	if o.Limpiar {
		log("semilla: borrando la semilla anterior")
		if err := limpiar(ctx, db); err != nil {
			return nil, err
		}
	}

	lima, err := time.LoadLocation("America/Lima")
	if err != nil {
		return nil, err
	}
	rng := rand.New(rand.NewPCG(o.Semilla, o.Semilla^0x9e3779b97f4a7c15))

	m, err := insertarMaestros(ctx, db, rng, lima, o.Desde, o.Hasta, o.Personas)
	if err != nil {
		return nil, fmt.Errorf("semilla: datos maestros: %w", err)
	}

	// Reglas en modo activo durante la simulación; se restauran al terminar.
	modos, err := guardarModos(ctx, db)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(ctx, `UPDATE escalamiento_reglas SET modo = 'activo'`); err != nil {
		return nil, err
	}
	restaurado := false
	restaurar := func() error {
		if restaurado {
			return nil
		}
		restaurado = true
		return restaurarModos(ctx, db, modos)
	}
	defer func() { _ = restaurar() }()

	reloj := incidencia.NuevoRelojManual(o.Desde)
	svc := incidencia.Nuevo(db, incidencia.ConReloj(reloj.Ahora), incidencia.ConCache(store.NuevoCacheSLA(24*time.Hour)))
	_, calLab, err := store.CalendarioPorNombre(ctx, db, store.NombreCalendarioLaboral)
	if err != nil {
		return nil, err
	}
	_, cal24, err := store.CalendarioPorNombre(ctx, db, store.NombreCalendario24x7)
	if err != nil {
		return nil, err
	}
	matriz, err := store.CargarMatriz(ctx, db)
	if err != nil {
		return nil, err
	}
	feriados := map[string]bool{}
	for f := range calLab.Feriados() {
		feriados[f] = true
	}
	g := &generador{
		ctx: ctx, db: db, svc: svc, vig: escala.Nuevo(svc), reloj: reloj, rng: rng, lima: lima,
		calLab: calLab, cal24: cal24, m: m, matriz: matriz, desde: o.Desde, hasta: o.Hasta,
		feriados: feriados, ticks: map[int64]bool{}, log: log,
	}

	log("semilla: planificando %d incidencias y %d casos del asistente", o.Incidencias, o.CasosAsistente)
	g.planificar(o.Incidencias)
	g.planCasosAsistente(o.CasosAsistente)
	g.planTics()
	g.tick(o.Hasta)
	log("semilla: ejecutando %d operaciones", len(g.ops))
	if err := g.ejecutar(); err != nil {
		return nil, err
	}

	if err := restaurar(); err != nil {
		return nil, err
	}
	// Ningún aviso sintético debe enviarse jamás.
	if _, err := db.Exec(ctx, `UPDATE avisos SET enviado_en = creado_en, error = 'semilla_sintetica: no se envía' WHERE enviado_en IS NULL`); err != nil {
		return nil, err
	}
	marcador := map[string]any{
		"version": 1, "semilla": o.Semilla, "desde": o.Desde.UTC().Format(time.RFC3339), "hasta": o.Hasta.UTC().Format(time.RFC3339),
		"incidencias": o.Incidencias, "nota": "datos sintéticos de cmd/semilla; no hay personas reales",
	}
	if err := store.GuardarConfig(ctx, db, store.ConfSemillaSintetica, marcador); err != nil {
		return nil, err
	}
	r, err := Contar(ctx, db)
	if err != nil {
		return nil, err
	}
	r.Saltadas = g.saltadas
	return r, nil
}

// Contar resume lo que hay en la base.
func Contar(ctx context.Context, db *store.DB) (*Resumen, error) {
	r := &Resumen{PorEstado: map[string]int{}, PorPrioridad: map[string]int{}, PorTipoEvento: map[string]int{}}
	cuentas := []struct {
		dst *int
		sql string
	}{
		{&r.Sedes, `SELECT count(*) FROM sedes`}, {&r.Areas, `SELECT count(*) FROM areas`},
		{&r.Personas, `SELECT count(*) FROM personas`}, {&r.Tecnicos, `SELECT count(*) FROM tecnicos`},
		{&r.Grupos, `SELECT count(*) FROM grupos`}, {&r.Incidencias, `SELECT count(*) FROM incidencias`},
		{&r.Eventos, `SELECT count(*) FROM incidencia_eventos`}, {&r.Escalamientos, `SELECT count(*) FROM escalamientos`},
		{&r.Avisos, `SELECT count(*) FROM avisos`}, {&r.Casos, `SELECT count(*) FROM casos`},
		{&r.Mensajes, `SELECT count(*) FROM mensajes`}, {&r.Encuestas, `SELECT count(*) FROM encuestas`},
		{&r.Feedback, `SELECT count(*) FROM feedback`}, {&r.OutboxFilas, `SELECT count(*) FROM outbox_analitica`},
	}
	for _, c := range cuentas {
		if err := db.QueryRow(ctx, c.sql).Scan(c.dst); err != nil {
			return nil, err
		}
	}
	for _, par := range []struct {
		dst map[string]int
		sql string
	}{
		{r.PorEstado, `SELECT estado, count(*) FROM incidencias GROUP BY estado`},
		{r.PorPrioridad, `SELECT prioridad, count(*) FROM incidencias GROUP BY prioridad`},
		{r.PorTipoEvento, `SELECT tipo, count(*) FROM incidencia_eventos GROUP BY tipo`},
	} {
		rows, err := db.Query(ctx, par.sql)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var k string
			var n int
			if err := rows.Scan(&k, &n); err != nil {
				rows.Close()
				return nil, err
			}
			par.dst[k] = n
		}
		rows.Close()
	}
	h := sha256.New()
	rows, err := db.Query(ctx, `SELECT tabla, clave, payload::text FROM outbox_analitica ORDER BY id`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var tabla, clave, payload string
		if err := rows.Scan(&tabla, &clave, &payload); err != nil {
			rows.Close()
			return nil, err
		}
		fmt.Fprintf(h, "%s|%s|%s\n", tabla, clave, payload)
	}
	rows.Close()
	r.Huella = hex.EncodeToString(h.Sum(nil))
	return r, nil
}

func hayDatos(ctx context.Context, db *store.DB) (bool, error) {
	var n int
	err := db.QueryRow(ctx, `SELECT (SELECT count(*) FROM incidencias) + (SELECT count(*) FROM personas)
		+ (SELECT count(*) FROM tecnicos) + (SELECT count(*) FROM casos)`).Scan(&n)
	return n > 0, err
}

// limpiar borra lo que carga la semilla, sin tocar la configuración (calendarios, matriz, SLA,
// categorías, grupos, reglas) y reinicia las secuencias para que los ids se repitan.
func limpiar(ctx context.Context, db *store.DB) error {
	return db.EnTx(ctx, func(tx pgxTx) error {
		sentencias := []string{
			// TRUNCATE no dispara el bloqueo de eventos inmutables; son datos sintéticos.
			`TRUNCATE incidencia_eventos, incidencias, escalamientos, avisos, encuestas, feedback, pares_preferencia,
				mensajes, etiquetas_revision, decisiones, articulo_usos, casos, outbox_analitica RESTART IDENTITY`,
			`ALTER SEQUENCE incidencia_numero_seq RESTART WITH 1`,
			`DELETE FROM guardias`, `DELETE FROM ausencias`, `DELETE FROM turnos`, `DELETE FROM habilidades`,
			`DELETE FROM grupo_miembros`, `DELETE FROM activos`,
			`UPDATE grupos SET responsable_tecnico_id = NULL`,
			`UPDATE usuarios_consola SET tecnico_id = NULL`,
			`DELETE FROM tecnicos`, `DELETE FROM personas`, `DELETE FROM sedes`, `DELETE FROM areas`,
			`SELECT setval(pg_get_serial_sequence('tecnicos', 'id'), 1, false)`,
			`SELECT setval(pg_get_serial_sequence('personas', 'id'), 1, false)`,
			`SELECT setval(pg_get_serial_sequence('sedes', 'id'), 1, false)`,
			`SELECT setval(pg_get_serial_sequence('areas', 'id'), 1, false)`,
			`SELECT setval(pg_get_serial_sequence('activos', 'id'), 1, false)`,
			`DELETE FROM configuracion WHERE clave IN ('semilla_sintetica', 'supervisor_tecnico_id')`,
		}
		for _, s := range sentencias {
			if _, err := tx.Exec(ctx, s); err != nil {
				return fmt.Errorf("semilla: limpiar (%s): %w", s[:min(len(s), 40)], err)
			}
		}
		return nil
	})
}

type modoRegla struct {
	id   int
	modo string
}

func guardarModos(ctx context.Context, db *store.DB) ([]modoRegla, error) {
	rows, err := db.Query(ctx, `SELECT id, modo FROM escalamiento_reglas ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []modoRegla
	for rows.Next() {
		var m modoRegla
		if err := rows.Scan(&m.id, &m.modo); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func restaurarModos(ctx context.Context, db *store.DB, ms []modoRegla) error {
	for _, m := range ms {
		if _, err := db.Exec(ctx, `UPDATE escalamiento_reglas SET modo = $2 WHERE id = $1`, m.id, m.modo); err != nil {
			return err
		}
	}
	return nil
}

// ExportarJSONL reconstruye el outbox desde Postgres (analitica.Reconstruir: un evento por
// fila y la última versión de cada incidencia o caso) y lo escribe en dir como un archivo
// <tabla>.jsonl por tabla de ClickHouse, en formato JSONEachRow con las columnas del contrato.
// Sirve para generar analitica/semilla/ desde la misma semilla. Devuelve las filas por tabla.
func ExportarJSONL(ctx context.Context, db *store.DB, dir string) (map[string]int, error) {
	if _, err := analitica.Reconstruir(ctx, db); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	rows, err := db.Query(ctx, `SELECT tabla, payload::text FROM outbox_analitica ORDER BY tabla, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	archivos := map[string]*os.File{}
	cuenta := map[string]int{}
	defer func() {
		for _, f := range archivos {
			_ = f.Close()
		}
	}()
	for rows.Next() {
		var tabla, payload string
		if err := rows.Scan(&tabla, &payload); err != nil {
			return nil, err
		}
		f := archivos[tabla]
		if f == nil {
			if f, err = os.Create(filepath.Join(dir, tabla+".jsonl")); err != nil {
				return nil, err
			}
			archivos[tabla] = f
		}
		// payload::text de jsonb trae un espacio tras ":" y ","; se recompacta.
		var v any
		if err := json.Unmarshal([]byte(payload), &v); err != nil {
			return nil, err
		}
		b, _ := json.Marshal(v)
		if _, err := f.Write(append(b, '\n')); err != nil {
			return nil, err
		}
		cuenta[tabla]++
	}
	return cuenta, rows.Err()
}
