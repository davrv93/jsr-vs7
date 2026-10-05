package analitica_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

// chFalso imita el HTTP de ClickHouse: guarda lo que recibe, por tabla.
type chFalso struct {
	mu       sync.Mutex
	filas    map[string][]map[string]any // tabla -> filas recibidas
	pedidos  int
	cabecera http.Header
	query    map[string]string
	// falla decide si responde con error (se llama con el número de pedido y la tabla).
	falla func(n int, tabla string) bool
	srv   *httptest.Server
}

func nuevoCH(t *testing.T) *chFalso {
	t.Helper()
	c := &chFalso{filas: map[string][]map[string]any{}}
	c.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cuerpo, _ := io.ReadAll(r.Body)
		q := r.URL.Query().Get("query")
		tabla := strings.TrimSuffix(strings.TrimPrefix(q, "INSERT INTO "), " FORMAT JSONEachRow")
		c.mu.Lock()
		c.pedidos++
		n := c.pedidos
		c.cabecera = r.Header.Clone()
		c.query = map[string]string{"date_time_input_format": r.URL.Query().Get("date_time_input_format"), "query": q,
			"database": r.URL.Query().Get("database"), "metodo": r.Method, "wait_end_of_query": r.URL.Query().Get("wait_end_of_query"),
			"skip_unknown": r.URL.Query().Get("input_format_skip_unknown_fields")}
		falla := c.falla != nil && c.falla(n, tabla)
		c.mu.Unlock()
		if falla {
			http.Error(w, "Code: 999. DB::Exception: simulado (clave secreta no debe aparecer)", http.StatusInternalServerError)
			return
		}
		var filas []map[string]any
		for _, linea := range strings.Split(strings.TrimSpace(string(cuerpo)), "\n") {
			if linea == "" {
				continue
			}
			var m map[string]any
			if err := json.Unmarshal([]byte(linea), &m); err != nil {
				http.Error(w, "JSON inválido: "+err.Error(), http.StatusBadRequest)
				return
			}
			filas = append(filas, m)
		}
		c.mu.Lock()
		c.filas[tabla] = append(c.filas[tabla], filas...)
		c.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(c.srv.Close)
	return c
}

func (c *chFalso) total() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, f := range c.filas {
		n += len(f)
	}
	return n
}

func encolar(t *testing.T, db *store.DB, tabla string, n int, desde int) {
	t.Helper()
	for i := desde; i < desde+n; i++ {
		clave := fmt.Sprintf("%s-%d", tabla, i)
		if err := analitica.Encolar(context.Background(), db, tabla, clave, map[string]any{"k": clave, "n": i}); err != nil {
			t.Fatal(err)
		}
	}
}

func pendientes(t *testing.T, db *store.DB) int {
	t.Helper()
	var n int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestVaciarEnviaPorHTTPYMarcaEnviado(t *testing.T) {
	db := storetest.NuevaBD(t)
	ch := nuevoCH(t)
	encolar(t, db, analitica.TablaEventos, 5, 0)
	encolar(t, db, analitica.TablaEstado, 3, 0)
	w := analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL, Usuario: "jsr", Clave: "clave-secreta", Base: "jsrbot"})

	res, err := w.Vaciar(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Total != 8 || res.Enviadas[analitica.TablaEventos] != 5 || res.Enviadas[analitica.TablaEstado] != 3 {
		t.Errorf("resumen = %+v", res)
	}
	if len(ch.filas[analitica.TablaEventos]) != 5 || len(ch.filas[analitica.TablaEstado]) != 3 {
		t.Errorf("filas recibidas: %d y %d", len(ch.filas[analitica.TablaEventos]), len(ch.filas[analitica.TablaEstado]))
	}
	if ch.query["wait_end_of_query"] != "1" {
		t.Errorf("sin wait_end_of_query=1 un error a media respuesta llegaría como 200: %v", ch.query)
	}
	if ch.query["skip_unknown"] != "1" {
		t.Errorf("los campos opcionales del contrato no deben rechazar el lote: %v", ch.query)
	}
	if ch.query["metodo"] != "POST" || ch.query["date_time_input_format"] != "best_effort" || ch.query["database"] != "jsrbot" ||
		!strings.HasSuffix(ch.query["query"], " FORMAT JSONEachRow") {
		t.Errorf("petición: %v", ch.query)
	}
	if ch.cabecera.Get("X-ClickHouse-User") != "jsr" || ch.cabecera.Get("X-ClickHouse-Key") != "clave-secreta" {
		t.Errorf("cabeceras de autenticación: %v", ch.cabecera)
	}
	if pendientes(t, db) != 0 {
		t.Errorf("quedan %d pendientes", pendientes(t, db))
	}
	// Idempotente: sin nada pendiente no hace pedidos.
	antes := ch.pedidos
	if res, err := w.Vaciar(context.Background()); err != nil || res.Total != 0 || ch.pedidos != antes {
		t.Errorf("segunda pasada: %+v %v pedidos %d->%d", res, err, antes, ch.pedidos)
	}
	// El cuerpo es JSONEachRow tal cual el payload: las claves son las columnas.
	if _, ok := ch.filas[analitica.TablaEventos][0]["k"]; !ok {
		t.Errorf("el payload debe viajar íntegro: %v", ch.filas[analitica.TablaEventos][0])
	}
}

func TestSiClickHouseFallaNadaSePierdeYSeReintenta(t *testing.T) {
	db := storetest.NuevaBD(t)
	ch := nuevoCH(t)
	encolar(t, db, analitica.TablaEventos, 10, 0)
	var fallos atomic.Int32
	ch.falla = func(n int, tabla string) bool { return fallos.Add(1) <= 2 } // los dos primeros pedidos fallan
	w := analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL, Clave: "clave-secreta"})

	for i := 0; i < 2; i++ {
		_, err := w.Vaciar(context.Background())
		if err == nil {
			t.Fatalf("intento %d: debía fallar", i)
		}
		if strings.Contains(err.Error(), "clave-secreta") {
			t.Errorf("el error no debe contener credenciales: %v", err)
		}
		if got := pendientes(t, db); got != 10 {
			t.Fatalf("tras el fallo %d deben seguir las 10 pendientes, hay %d", i, got)
		}
		if ch.total() != 0 {
			t.Fatal("un lote rechazado no debe quedar recibido")
		}
	}
	res, err := w.Vaciar(context.Background())
	if err != nil || res.Total != 10 || ch.total() != 10 || pendientes(t, db) != 0 {
		t.Fatalf("al recuperarse: %+v %v recibidas=%d pendientes=%d", res, err, ch.total(), pendientes(t, db))
	}
	// Ni duplicadas ni perdidas.
	vistas := map[any]int{}
	for _, f := range ch.filas[analitica.TablaEventos] {
		vistas[f["k"]]++
	}
	for k, n := range vistas {
		if n != 1 {
			t.Errorf("%v llegó %d veces", k, n)
		}
	}
}

func TestClickHouseCaidoDevuelveErrorSinPerderNada(t *testing.T) {
	db := storetest.NuevaBD(t)
	ch := nuevoCH(t)
	url := ch.srv.URL
	ch.srv.Close() // nadie escucha
	encolar(t, db, analitica.TablaEstado, 4, 0)
	w := analitica.NuevoTrabajador(db, analitica.Config{URL: url, Timeout: 2 * time.Second})
	if _, err := w.Vaciar(context.Background()); err == nil {
		t.Fatal("con ClickHouse caído debe haber error")
	}
	if pendientes(t, db) != 4 {
		t.Errorf("pendientes = %d", pendientes(t, db))
	}
}

// Si una tabla falla a mitad de lote, lo ya confirmado queda marcado (no se reenvía) y el resto sigue pendiente.
func TestFalloParcialPorTabla(t *testing.T) {
	db := storetest.NuevaBD(t)
	ch := nuevoCH(t)
	encolar(t, db, analitica.TablaEventos, 3, 0) // primero en el orden del outbox
	encolar(t, db, analitica.TablaTiempos, 2, 0)
	rotas := true
	ch.falla = func(n int, tabla string) bool { return rotas && tabla == analitica.TablaTiempos }
	w := analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL})
	if _, err := w.Vaciar(context.Background()); err == nil {
		t.Fatal("debía fallar por incidencias_tiempos")
	}
	if len(ch.filas[analitica.TablaEventos]) != 3 || pendientes(t, db) != 2 {
		t.Fatalf("eventos recibidos=%d pendientes=%d (quiere 3 y 2)", len(ch.filas[analitica.TablaEventos]), pendientes(t, db))
	}
	rotas = false
	if res, err := w.Vaciar(context.Background()); err != nil || res.Total != 2 {
		t.Fatalf("recuperación: %+v %v", res, err)
	}
	if len(ch.filas[analitica.TablaEventos]) != 3 {
		t.Errorf("los eventos ya enviados no deben reenviarse: %d", len(ch.filas[analitica.TablaEventos]))
	}
}

func TestLotesYTrabajadoresEnParalelo(t *testing.T) {
	db := storetest.NuevaBD(t)
	ch := nuevoCH(t)
	encolar(t, db, analitica.TablaEventos, 60, 0)
	encolar(t, db, analitica.TablaMensajes, 40, 0)
	var wg sync.WaitGroup
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL, Lote: 7})
			_, err := w.Vaciar(context.Background())
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	// FOR UPDATE SKIP LOCKED: cada fila se envía exactamente una vez, aunque corran cuatro trabajadores.
	if ch.total() != 100 || pendientes(t, db) != 0 {
		t.Fatalf("recibidas=%d pendientes=%d", ch.total(), pendientes(t, db))
	}
	vistas := map[any]int{}
	for _, filas := range ch.filas {
		for _, f := range filas {
			vistas[f["k"]]++
		}
	}
	if len(vistas) != 100 {
		t.Errorf("claves distintas = %d, quiere 100", len(vistas))
	}
	for k, n := range vistas {
		if n != 1 {
			t.Errorf("%v llegó %d veces", k, n)
		}
	}
	if ch.pedidos < 100/7 {
		t.Errorf("con lotes de 7 debían hacerse al menos %d pedidos, hubo %d", 100/7, ch.pedidos)
	}
}

func TestSinDestinoYTablaDesconocida(t *testing.T) {
	db := storetest.NuevaBD(t)
	encolar(t, db, analitica.TablaEventos, 1, 0)
	w := analitica.NuevoTrabajador(db, analitica.Config{})
	if _, err := w.Vaciar(context.Background()); !errors.Is(err, analitica.ErrSinDestino) {
		t.Errorf("sin URL: %v", err)
	}
	if pendientes(t, db) != 1 {
		t.Error("sin destino no se marca nada")
	}
	if err := analitica.Encolar(context.Background(), db, "tabla_inventada", "x", map[string]any{}); err == nil {
		t.Error("tabla desconocida debe fallar")
	}
	if err := analitica.Encolar(context.Background(), db, analitica.TablaEventos, "", map[string]any{}); err == nil {
		t.Error("sin clave debe fallar")
	}
	// Lo que quede en el outbox con una tabla fuera del contrato no se envía a ciegas.
	if _, err := db.Exec(context.Background(), `INSERT INTO outbox_analitica (tabla, clave, payload) VALUES ('x; DROP TABLE y', 'k', '{}')`); err != nil {
		t.Fatal(err)
	}
	ch := nuevoCH(t)
	w = analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL})
	if _, err := w.Vaciar(context.Background()); err == nil {
		t.Error("una tabla fuera del contrato debe rechazarse")
	}
	if ch.pedidos > 1 {
		t.Errorf("no debe enviar la tabla inválida: %d pedidos", ch.pedidos)
	}
}

func TestCorrerVaciaPeriodicamenteYParaConElContexto(t *testing.T) {
	db := storetest.NuevaBD(t)
	ch := nuevoCH(t)
	encolar(t, db, analitica.TablaFeedback, 3, 0)
	w := analitica.NuevoTrabajador(db, analitica.Config{URL: ch.srv.URL})
	ctx, cancel := context.WithCancel(context.Background())
	hecho := make(chan struct{})
	go func() { w.Correr(ctx, 20*time.Millisecond); close(hecho) }()
	deadline := time.Now().Add(5 * time.Second)
	for ch.total() < 3 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if ch.total() != 3 {
		t.Fatalf("Correr no vació el outbox: %d", ch.total())
	}
	// Una fila nueva se recoge en la siguiente vuelta.
	encolar(t, db, analitica.TablaFeedback, 1, 100)
	for ch.total() < 4 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if ch.total() != 4 {
		t.Errorf("la fila nueva no llegó: %d", ch.total())
	}
	cancel()
	select {
	case <-hecho:
	case <-time.After(3 * time.Second):
		t.Fatal("Correr no paró al cancelar el contexto")
	}
}
