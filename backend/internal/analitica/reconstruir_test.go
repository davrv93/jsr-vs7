package analitica_test

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

// «Borrar ClickHouse y reconstruir»: tras Reconstruir, el outbox contiene exactamente lo mismo que
// habría acumulado el sistema en vivo (la última versión de cada fila), sin versiones intermedias.
func TestReconstruirRepiteLoEmitidoEnVivo(t *testing.T) {
	db := storetest.NuevaBDConConfig(t)
	ctx := context.Background()
	lima, _ := time.LoadLocation("America/Lima")
	reloj := incidencia.NuevoRelojManual(time.Date(2026, 10, 5, 9, 0, 0, 0, lima))
	svc := incidencia.Nuevo(db, incidencia.ConReloj(reloj.Ahora))

	mustScan := func(sql string, args ...any) int {
		t.Helper()
		var v int
		if err := db.QueryRow(ctx, sql, args...).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	mesa := mustScan(`SELECT id FROM grupos WHERE nombre = 'Mesa N1'`)
	ana := mustScan(`INSERT INTO tecnicos (nombre) VALUES ('Ana') RETURNING id`)
	_, _ = db.Exec(ctx, `INSERT INTO grupo_miembros VALUES ($1, $2)`, mesa, ana)
	_, _ = db.Exec(ctx, `INSERT INTO habilidades (tecnico_id, categoria_id) SELECT $1, id FROM categorias`, ana)
	for d := 1; d <= 5; d++ {
		_, _ = db.Exec(ctx, `INSERT INTO turnos (tecnico_id, dia_semana, desde, hasta) VALUES ($1, $2, '08:30', '18:00')`, ana, d)
	}
	sede := mustScan(`INSERT INTO sedes (nombre) VALUES ('Central') RETURNING id`)
	area := mustScan(`INSERT INTO areas (nombre) VALUES ('Contabilidad') RETURNING id`)
	pepe := mustScan(`INSERT INTO personas (nombre, sede_id, area_id) VALUES ('Pepe', $1, $2) RETURNING id`, sede, area)

	// Casos, mensajes, encuesta y feedback, encolados como lo haría la pasarela.
	caso := mustScan(`INSERT INTO casos (persona_id, canal, chat_id, estado) VALUES ($1, 'web', 's1', 'con_incidencia') RETURNING id`, pepe)
	caso2 := mustScan(`INSERT INTO casos (persona_id, canal, chat_id, estado) VALUES ($1, 'whatsapp', 's2', 'resuelto_asistente') RETURNING id`, pepe)
	for _, c := range []int{caso, caso2} {
		if err := analitica.EncolarCaso(ctx, db, int64(c)); err != nil {
			t.Fatal(err)
		}
	}
	msg := mustScan(`INSERT INTO mensajes (caso_id, rol, texto, meta) VALUES ($1, 'usuario', 'no abre el correo', '{"intencion":"reportar_falla","confianza":0.9}') RETURNING id`, caso)
	if err := analitica.EncolarMensaje(ctx, db, int64(msg)); err != nil {
		t.Fatal(err)
	}
	cid := int64(caso)

	r, err := svc.Crear(ctx, incidencia.EntradaCrear{PersonaID: &pepe, CasoID: &cid, Categoria: "correo", Titulo: "Outlook"})
	if err != nil {
		t.Fatal(err)
	}
	inc := r.Incidencia
	// La pasarela vuelve a encolar el caso al abrirse la incidencia (cambia tiene_incidencia).
	if err := analitica.EncolarCaso(ctx, db, cid); err != nil {
		t.Fatal(err)
	}
	tec := incidencia.ActorTecnico(*inc.TecnicoID)
	paso := func(f func() error) {
		t.Helper()
		reloj.Avanzar(20 * time.Minute)
		if err := f(); err != nil {
			t.Fatal(err)
		}
	}
	paso(func() error {
		_, err := svc.Responder(ctx, inc.ID, incidencia.EntradaResponder{Texto: "ok", Actor: tec})
		return err
	})
	paso(func() error {
		_, err := svc.Pausar(ctx, inc.ID, incidencia.EntradaPausar{Motivo: "espera_usuario", Actor: tec})
		return err
	})
	paso(func() error {
		_, err := svc.Reanudar(ctx, inc.ID, incidencia.EntradaReanudar{Actor: incidencia.ActorUsuario(pepe)})
		return err
	})
	paso(func() error {
		_, err := svc.Resolver(ctx, inc.ID, incidencia.EntradaResolver{Solucion: "listo", Actor: tec})
		return err
	})
	paso(func() error {
		_, err := svc.Cerrar(ctx, inc.ID, incidencia.EntradaCerrar{Motivo: incidencia.CierreConfirmado, Actor: incidencia.ActorUsuario(pepe)})
		return err
	})
	encID, err := svc.RegistrarEncuesta(ctx, inc.ID, 4, "bien")
	if err != nil {
		t.Fatal(err)
	}
	_ = encID
	if _, err := db.Exec(ctx, `INSERT INTO feedback (caso_id, incidencia_id, senal, valor) VALUES ($1, $2, 'se_resolvio', 'KB-031')`, caso, inc.ID); err != nil {
		t.Fatal(err)
	}
	var fbID int64
	_ = db.QueryRow(ctx, `SELECT max(id) FROM feedback`).Scan(&fbID)
	if err := analitica.EncolarFeedback(ctx, db, fbID); err != nil {
		t.Fatal(err)
	}

	// El caso se vuelve a encolar al terminar (la pasarela lo hace al cambiar su estado).
	if err := analitica.EncolarCaso(ctx, db, cid); err != nil {
		t.Fatal(err)
	}
	// Foto del outbox «en vivo»: la última versión de cada fila lógica.
	vivo := fotoOutbox(t, db)
	if len(vivo["incidencias_estado"]) != 1 || len(vivo["incidencias_tiempos"]) != 1 {
		t.Fatalf("la foto debe tener 1 fila por incidencia: %v", vivo)
	}
	enOutboxVivo := func() int {
		var n int
		_ = db.QueryRow(ctx, `SELECT count(*) FROM outbox_analitica`).Scan(&n)
		return n
	}()

	// Se envía parte al «ClickHouse» y se reconstruye: todo vuelve a quedar pendiente.
	ch := nuevoCH(t)
	if _, err := analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL}).Vaciar(ctx); err != nil {
		t.Fatal(err)
	}
	conteo, err := analitica.Reconstruir(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	if conteo[analitica.TablaEstado] != 1 || conteo[analitica.TablaTiempos] != 1 || conteo[analitica.TablaCasos] != 2 ||
		conteo[analitica.TablaMensajes] != 1 || conteo[analitica.TablaEncuestas] != 1 || conteo[analitica.TablaFeedback] != 1 {
		t.Errorf("conteo = %v", conteo)
	}
	if conteo[analitica.TablaEventos] != vivo2n(vivo, "eventos_incidencia") {
		t.Errorf("eventos reconstruidos = %d, en vivo %d", conteo[analitica.TablaEventos], vivo2n(vivo, "eventos_incidencia"))
	}
	if pendientes(t, db) == 0 || pendientes(t, db) > enOutboxVivo {
		t.Errorf("tras reconstruir todo debe quedar pendiente y sin versiones intermedias: %d pendientes (en vivo había %d filas)", pendientes(t, db), enOutboxVivo)
	}
	rec := fotoOutbox(t, db)
	for tabla, filas := range vivo {
		if !reflect.DeepEqual(filas, rec[tabla]) {
			t.Errorf("%s: la reconstrucción difiere de lo emitido en vivo\n vivo: %v\n recon: %v", tabla, filas, rec[tabla])
		}
	}
	// Y se puede volver a enviar todo a un ClickHouse vacío.
	ch2 := nuevoCH(t)
	if res, err := analitica.NuevoTrabajador(db, analitica.Config{URL: ch2.srv.URL}).Vaciar(ctx); err != nil || res.Total != pendientes0(conteo) {
		t.Errorf("reenvío: %+v %v", res, err)
	}
	if ch2.total() != pendientes0(conteo) || pendientes(t, db) != 0 {
		t.Errorf("recibidas %d de %d; pendientes %d", ch2.total(), pendientes0(conteo), pendientes(t, db))
	}
	// Reconstruir dos veces da lo mismo (determinista).
	again, err := analitica.Reconstruir(ctx, db)
	if err != nil || !reflect.DeepEqual(again, conteo) {
		t.Errorf("segunda reconstrucción: %v %v", again, err)
	}
	if !reflect.DeepEqual(fotoOutbox(t, db), rec) {
		t.Error("la segunda reconstrucción debe dejar el mismo contenido")
	}
	_ = store.ErrNoEncontrado
}

func pendientes0(c analitica.Conteo) int {
	n := 0
	for _, v := range c {
		n += v
	}
	return n
}

func vivo2n(m map[string]map[string]string, tabla string) int { return len(m[tabla]) }

// fotoOutbox devuelve, por tabla, clave lógica -> payload canónico (última versión).
func fotoOutbox(t *testing.T, db *store.DB) map[string]map[string]string {
	t.Helper()
	rows, err := db.Query(context.Background(), `SELECT tabla, clave, payload FROM outbox_analitica ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]map[string]string{}
	versiones := map[string]float64{}
	for rows.Next() {
		var tabla, clave string
		var raw []byte
		if err := rows.Scan(&tabla, &clave, &raw); err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatal(err)
		}
		// Clave lógica: sin la versión, para quedarse con la última.
		logica := clave
		if v, ok := m["version"].(float64); ok {
			logica = strings.Join([]string{tabla, jsonNum(m["incidencia_id"]), jsonNum(m["caso_id"])}, "|")
			if v < versiones[logica] {
				continue
			}
			versiones[logica] = v
		}
		if out[tabla] == nil {
			out[tabla] = map[string]string{}
		}
		canon, _ := json.Marshal(m) // json.Marshal ordena las claves
		out[tabla][logica] = string(canon)
	}
	return out
}

func jsonNum(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
