package semilla_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/semilla"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

var lima = func() *time.Location {
	l, _ := time.LoadLocation("America/Lima")
	return l
}()

// opcionesChicas: un mes y ~90 incidencias, suficiente para cubrir todos los guiones y rápido.
func opcionesChicas() semilla.Opciones {
	return semilla.Opciones{
		Incidencias: 90, Personas: 40,
		Desde: time.Date(2026, 7, 1, 0, 0, 0, 0, lima), Hasta: time.Date(2026, 8, 8, 23, 59, 0, 0, lima),
	}
}

func cargar(t *testing.T, db *store.DB, o semilla.Opciones) *semilla.Resumen {
	t.Helper()
	r, err := semilla.Cargar(context.Background(), db, o)
	if err != nil {
		t.Fatalf("Cargar: %v", err)
	}
	return r
}

// La semilla carga sin errores, se puede cargar dos veces y deja exactamente lo mismo.
func TestCargaYEsReproducible(t *testing.T) {
	db := storetest.NuevaBDConConfig(t)
	r1 := cargar(t, db, opcionesChicas())
	if r1.Omitida || r1.Incidencias != 90 || r1.Personas != 40 || r1.Tecnicos != 11 || r1.Grupos != 4 {
		t.Fatalf("primera carga: %+v", r1)
	}
	if r1.Eventos < 90*3 || r1.Casos < 90+36 || r1.Mensajes == 0 || r1.OutboxFilas == 0 || r1.Escalamientos == 0 || r1.Avisos == 0 {
		t.Errorf("la carga parece incompleta: %+v", r1)
	}
	// Segunda corrida SIN limpiar: reconoce la semilla y no cambia nada.
	r2 := cargar(t, db, opcionesChicas())
	if !r2.Omitida {
		t.Error("sin -limpiar debe omitirse")
	}
	r2.Omitida, r2.Saltadas = false, r1.Saltadas
	if !reflect.DeepEqual(r1, r2) {
		t.Errorf("omitida cambió los totales:\n%+v\n%+v", r1, r2)
	}
	// Tercera con -limpiar: borra y recarga con los mismos totales y la MISMA huella del outbox.
	o := opcionesChicas()
	o.Limpiar = true
	r3 := cargar(t, db, o)
	if r3.Omitida {
		t.Error("con limpiar no se omite")
	}
	if !reflect.DeepEqual(r1, r3) {
		t.Errorf("dos corridas deben dar lo mismo:\n%+v\n%+v", r1, r3)
	}
	if r1.Huella == "" || r1.Huella != r3.Huella {
		t.Errorf("huella distinta: %s vs %s", r1.Huella, r3.Huella)
	}
	// Otra semilla da otros datos.
	o.Semilla, o.Incidencias = 7, 20
	if r4 := cargar(t, db, o); r4.Huella == r1.Huella || r4.Incidencias != 20 {
		t.Error("otra semilla debe producir otros datos")
	}
}

func TestNoToqueDatosQueNoSonDeLaSemilla(t *testing.T) {
	db := storetest.NuevaBDConConfig(t)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `INSERT INTO personas (nombre) VALUES ('Persona real')`); err != nil {
		t.Fatal(err)
	}
	for _, limpiar := range []bool{false, true} {
		o := opcionesChicas()
		o.Limpiar = limpiar
		if _, err := semilla.Cargar(ctx, db, o); !errors.Is(err, semilla.ErrDatosReales) {
			t.Errorf("limpiar=%v: err = %v, quiere ErrDatosReales", limpiar, err)
		}
	}
	var n int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM personas`).Scan(&n)
	if n != 1 {
		t.Errorf("no debía tocar nada: %d personas", n)
	}
}

// La semilla está marcada como sintética y no deja nada que se pueda enviar a una persona real.
func comprobarMarcaSintetica(t *testing.T, db *store.DB, r *semilla.Resumen) {
	ctx := context.Background()
	var marca string
	if err := db.QueryRow(ctx, `SELECT valor::text FROM configuracion WHERE clave = 'semilla_sintetica'`).Scan(&marca); err != nil || marca == "" {
		t.Errorf("falta el marcador semilla_sintetica: %v", err)
	}
	// Ningún aviso queda por enviar.
	var pend, ajenos int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM avisos WHERE enviado_en IS NULL`).Scan(&pend)
	if pend != 0 {
		t.Errorf("hay %d avisos sintéticos por enviar", pend)
	}
	_ = db.QueryRow(ctx, `SELECT count(*) FROM avisos WHERE error NOT LIKE 'semilla_sintetica%'`).Scan(&ajenos)
	if ajenos != 0 {
		t.Errorf("avisos sin marcar: %d", ajenos)
	}
	// Teléfonos y correos imposibles.
	var malos int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM personas WHERE whatsapp NOT LIKE '5100000%' OR correo NOT LIKE '%@empresa.example'`).Scan(&malos)
	_ = db.QueryRow(ctx, `SELECT count(*) + $1 FROM tecnicos WHERE whatsapp NOT LIKE '5100001%' OR correo NOT LIKE '%@empresa.example'`, malos).Scan(&malos)
	if malos != 0 {
		t.Errorf("%d contactos que no son claramente sintéticos", malos)
	}
	// Las reglas vuelven a su modo original (sombra) aunque la carga las use en activo.
	var activas int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM escalamiento_reglas WHERE modo <> 'sombra'`).Scan(&activas)
	if activas != 0 {
		t.Errorf("%d reglas quedaron en modo activo", activas)
	}
}

// Los estados salen de los eventos: cada cadena de estado_cambiado es coherente y termina en el
// estado actual de la incidencia.
func comprobarEventosCoherentes(t *testing.T, db *store.DB, r *semilla.Resumen) {
	ctx := context.Background()

	rows, err := db.Query(ctx, `SELECT i.id, i.numero, i.estado, i.reaperturas, i.escalamientos, i.resuelta_en IS NOT NULL, i.cerrada_en IS NOT NULL
		FROM incidencias i ORDER BY i.id`)
	if err != nil {
		t.Fatal(err)
	}
	type inc struct {
		id                int64
		numero, estado    string
		reab, esc         int
		resuelta, cerrada bool
	}
	var incs []inc
	for rows.Next() {
		var x inc
		if err := rows.Scan(&x.id, &x.numero, &x.estado, &x.reab, &x.esc, &x.resuelta, &x.cerrada); err != nil {
			t.Fatal(err)
		}
		incs = append(incs, x)
	}
	rows.Close()
	if len(incs) != 90 {
		t.Fatalf("incidencias = %d", len(incs))
	}
	svc := incidencia.Nuevo(db)
	for _, x := range incs {
		evs, err := svc.Eventos(ctx, x.id)
		if err != nil {
			t.Fatal(err)
		}
		if evs[0].Tipo != incidencia.EvCreada {
			t.Errorf("%s: el primer evento es %s", x.numero, evs[0].Tipo)
		}
		actual := incidencia.Nueva
		reab, esc, resuelta, primera := 0, 0, 0, 0
		for i, ev := range evs {
			if i > 0 && ev.TS.Before(evs[i-1].TS) {
				t.Errorf("%s: eventos fuera de orden", x.numero)
			}
			switch ev.Tipo {
			case incidencia.EvEstadoCambiado:
				de, a := incidencia.Estado(ev.Datos["de"].(string)), incidencia.Estado(ev.Datos["a"].(string))
				if de != actual {
					t.Errorf("%s: estado_cambiado de %s pero la incidencia estaba en %s", x.numero, de, actual)
				}
				actual = a
			case incidencia.EvReabierta:
				reab++
			case incidencia.EvEscalada:
				esc++
			case incidencia.EvResuelta:
				resuelta++
			case incidencia.EvPrimeraRespuesta:
				primera++
			}
		}
		if string(actual) != x.estado {
			t.Errorf("%s: los eventos terminan en %s y la fila dice %s", x.numero, actual, x.estado)
		}
		if reab != x.reab || esc != x.esc {
			t.Errorf("%s: contadores %d/%d vs eventos %d/%d", x.numero, x.reab, x.esc, reab, esc)
		}
		if primera > 1 {
			t.Errorf("%s: %d primeras respuestas", x.numero, primera)
		}
		if enResuelta := x.estado == "resuelta" || x.estado == "cerrada"; x.resuelta != enResuelta && x.estado != "cerrada" {
			t.Errorf("%s: resuelta_en=%v con estado %s", x.numero, x.resuelta, x.estado)
		}
		if x.cerrada != (x.estado == "cerrada") {
			t.Errorf("%s: cerrada_en=%v con estado %s", x.numero, x.cerrada, x.estado)
		}
	}
}

// El conjunto trae los casos difíciles que piden el plan y las golden queries.
func comprobarCasosDificiles(t *testing.T, db *store.DB, r *semilla.Resumen) {
	ctx := context.Background()
	cuenta := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := db.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	casos := map[string]string{
		"creada un viernes a las 17:55 (Lima)":        `SELECT count(*) FROM incidencias WHERE (creada_en AT TIME ZONE 'America/Lima')::time = '17:55' AND extract(isodow FROM creada_en AT TIME ZONE 'America/Lima') = 5`,
		"creada en un feriado":                        `SELECT count(*) FROM incidencias i JOIN feriados f ON f.fecha = (i.creada_en AT TIME ZONE 'America/Lima')::date`,
		"con una pausa":                               `SELECT count(DISTINCT incidencia_id) FROM incidencia_eventos WHERE tipo = 'pausa_inicio'`,
		"con espera_tercero":                          `SELECT count(DISTINCT incidencia_id) FROM incidencia_eventos WHERE tipo = 'pausa_inicio' AND datos->>'motivo' = 'espera_tercero'`,
		"reabierta una vez":                           `SELECT count(*) FROM incidencias WHERE reaperturas >= 1`,
		"reabierta dos veces":                         `SELECT count(*) FROM incidencias WHERE reaperturas >= 2`,
		"escalada":                                    `SELECT count(*) FROM incidencias WHERE escalamientos >= 1`,
		"escalada por el vigía":                       `SELECT count(*) FROM escalamientos WHERE modo = 'activo' AND accion::text LIKE '%"escalada"%'`,
		"P1 fuera de horario atendida por la guardia": `SELECT count(*) FROM incidencia_eventos WHERE tipo = 'asignada' AND datos->>'por_guardia' = 'true'`,
		"nunca resuelta":                              `SELECT count(*) FROM incidencias WHERE estado IN ('asignada', 'en_curso', 'espera_usuario', 'espera_tercero', 'nueva', 'reabierta')`,
		"sin primera respuesta":                       `SELECT count(*) FROM incidencias WHERE primera_respuesta_en IS NULL`,
		"con queja":                                   `SELECT count(DISTINCT incidencia_id) FROM incidencia_eventos WHERE tipo = 'queja'`,
		"de una persona VIP":                          `SELECT count(*) FROM incidencia_eventos WHERE tipo = 'creada' AND datos->>'vip' = 'true'`,
		"cerrada sin confirmación":                    `SELECT count(*) FROM incidencias WHERE motivo_cierre = 'sin_confirmacion'`,
		"cerrada confirmada":                          `SELECT count(*) FROM incidencias WHERE motivo_cierre = 'confirmado'`,
		"con encuesta":                                `SELECT count(*) FROM encuestas`,
		"caso resuelto solo por el asistente":         `SELECT count(*) FROM casos c WHERE estado = 'resuelto_asistente' AND NOT EXISTS (SELECT 1 FROM incidencias i WHERE i.caso_id = c.id)`,
		"caso abandonado sin incidencia":              `SELECT count(*) FROM casos c WHERE estado = 'cerrado' AND NOT EXISTS (SELECT 1 FROM incidencias i WHERE i.caso_id = c.id)`,
		"que quedó en la cola de un grupo":            `SELECT count(*) FROM incidencia_eventos WHERE tipo = 'en_cola'`,
		"con aviso al supervisor":                     `SELECT count(*) FROM avisos WHERE destinatario_tipo = 'supervisor'`,
		"con comentario interno":                      `SELECT count(*) FROM incidencia_eventos WHERE tipo = 'comentario_interno'`,
		"con dato agregado":                           `SELECT count(*) FROM incidencia_eventos WHERE tipo = 'dato_agregado'`,
	}
	for nombre, sql := range casos {
		if cuenta(sql) == 0 {
			t.Errorf("falta el caso difícil «%s»", nombre)
		}
	}
	// Cubre las cuatro prioridades y varios estados.
	for _, p := range []string{"P1", "P2", "P3", "P4"} {
		if r.PorPrioridad[p] == 0 {
			t.Errorf("no hay incidencias %s", p)
		}
	}
	for _, e := range []string{"cerrada", "resuelta", "en_curso", "asignada"} {
		if r.PorEstado[e] == 0 {
			t.Errorf("no hay incidencias en estado %s", e)
		}
	}
	t.Logf("resumen: %d incidencias, %d eventos, %d escalamientos, %d avisos, %d casos, %d acciones saltadas; estados %v; prioridades %v",
		r.Incidencias, r.Eventos, r.Escalamientos, r.Avisos, r.Casos, r.Saltadas, r.PorEstado, r.PorPrioridad)
}

// Lo que el vigía hizo de verdad durante la carga también lo predice la reproducción histórica.
func comprobarReproduccion(t *testing.T, db *store.DB, r *semilla.Resumen) {
	ctx := context.Background()
	o := opcionesChicas()
	svc := incidencia.Nuevo(db)
	vig := escala.Nuevo(svc)
	ds, err := vig.Reproducir(ctx, o.Desde, o.Hasta)
	if err != nil {
		t.Fatal(err)
	}
	repro := map[string]bool{}
	for _, d := range ds {
		repro[d.Numero+"/"+d.ReglaClave] = true
	}
	rows, err := db.Query(ctx, `SELECT i.numero, e.regla_clave FROM escalamientos e JOIN incidencias i ON i.id = e.incidencia_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	vivo, ausentes := 0, 0
	for rows.Next() {
		var n, r string
		if err := rows.Scan(&n, &r); err != nil {
			t.Fatal(err)
		}
		vivo++
		if !repro[n+"/"+r] {
			ausentes++
			t.Errorf("el vigía disparó %s/%s y la reproducción no lo predijo", n, r)
		}
	}
	if vivo == 0 || len(ds) < vivo {
		t.Errorf("vivo=%d reproducción=%d", vivo, len(ds))
	}
	t.Logf("el vigía registró %d disparos; la reproducción histórica lista %d (los de más son lo que la rejilla de 30 min no alcanzó a ver)", vivo, len(ds))
	_ = ausentes
}

func comprobarExportacion(t *testing.T, db *store.DB, r *semilla.Resumen) {
	ctx := context.Background()
	dir := t.TempDir()
	cuenta, err := semilla.ExportarJSONL(ctx, db, dir)
	if err != nil {
		t.Fatal(err)
	}
	if cuenta["incidencias_estado"] != 90 || cuenta["incidencias_tiempos"] != 90 {
		t.Errorf("exportado: %v", cuenta)
	}
	for _, tabla := range []string{"eventos_incidencia", "incidencias_estado", "incidencias_tiempos", "casos_estado", "mensajes", "encuestas", "feedback"} {
		st, err := os.Stat(filepath.Join(dir, tabla+".jsonl"))
		if err != nil || st.Size() == 0 {
			t.Errorf("falta %s.jsonl: %v", tabla, err)
		}
	}
}

// Una sola carga alimenta todas las comprobaciones de solo lectura (cada carga tarda unos segundos).
// La última exporta, y exportar reconstruye el outbox, así que va al final.
func TestSemillaChica(t *testing.T) {
	db := storetest.NuevaBDConConfig(t)
	r := cargar(t, db, opcionesChicas())
	for _, c := range []struct {
		nombre string
		f      func(*testing.T, *store.DB, *semilla.Resumen)
	}{
		{"marcada_como_sintetica", comprobarMarcaSintetica},
		{"eventos_coherentes", comprobarEventosCoherentes},
		{"casos_dificiles", comprobarCasosDificiles},
		{"reproduccion_predice_al_vigia", comprobarReproduccion},
		{"reconstruir_y_exportar", comprobarExportacion},
	} {
		t.Run(c.nombre, func(t *testing.T) { c.f(t, db, r) })
	}
}
