package motor

import (
	"context"
	"log"
	"time"
)

// Intervalos de los trabajos en segundo plano.
const (
	// IntervaloVigia: el vigía corre cada minuto y NO se baja a intervalos mayores (un aviso del
	// 75 % llegaría tarde).
	IntervaloVigia = time.Minute
	// IntervaloOutbox: el outbox se vacía hacia ClickHouse cada 10 s (ARQUITECTURA §8.2).
	IntervaloOutbox = 10 * time.Second
)

// Fondo corre en segundo plano, hasta que ctx se cancele:
//
//   - el vigía (cada minuto): reintenta la cola de asignaciones, evalúa las reglas de
//     escalamiento y cierra las resueltas sin confirmación tras 48 h laborales; es idempotente;
//   - el trabajador del outbox (cada 10 s), si hay ClickHouse configurado.
//
// Bloquea hasta que ambos terminan.
func (s *Servidor) Fondo(ctx context.Context, vigia, outbox bool) {
	hecho := make(chan struct{}, 2)
	n := 0
	if vigia && s.cfg.Vigia != nil {
		n++
		go func() {
			s.cfg.Vigia.Correr(ctx, IntervaloVigia)
			hecho <- struct{}{}
		}()
	}
	if outbox && s.cfg.Analitica != nil && s.cfg.ClickHouseConfigurado {
		n++
		go func() {
			s.cfg.Analitica.Correr(ctx, IntervaloOutbox)
			hecho <- struct{}{}
		}()
	} else if outbox {
		log.Printf("motor: sin ClickHouse configurado (JSR_CH_URL): el outbox se acumula en Postgres y no se envía")
	}
	for i := 0; i < n; i++ {
		<-hecho
	}
}
