package golden

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Con 12 consultas a la vez, ClickHouse nunca debe ver más de 3 en vuelo (el límite del usuario analista es 4).
func TestConsultarRespetaElCupo(t *testing.T) {
	var enVuelo, maximo atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := enVuelo.Add(1)
		for {
			m := maximo.Load()
			if n <= m || maximo.CompareAndSwap(m, n) {
				break
			}
		}
		time.Sleep(30 * time.Millisecond)
		enVuelo.Add(-1)
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer srv.Close()
	ch := &CH{URL: srv.URL, Usuario: "analista", Clave: "x", Cliente: srv.Client()}
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := ch.Consultar(context.Background(), "SELECT 1", nil); err != nil {
				t.Errorf("consulta: %v", err)
			}
		}()
	}
	wg.Wait()
	if m := maximo.Load(); m > 3 {
		t.Fatalf("hubo %d consultas simultáneas; el cupo es 3", m)
	}
}

func TestConsultarCanceladaEsperandoCupo(t *testing.T) {
	for i := 0; i < cap(cupoConsultas); i++ {
		cupoConsultas <- struct{}{}
	}
	defer func() {
		for i := 0; i < cap(cupoConsultas); i++ {
			<-cupoConsultas
		}
	}()
	ctx, cancelar := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancelar()
	ch := &CH{URL: "http://127.0.0.1:1"}
	if _, err := ch.Consultar(ctx, "SELECT 1", nil); err == nil {
		t.Fatal("esperaba error por contexto cancelado")
	}
}
