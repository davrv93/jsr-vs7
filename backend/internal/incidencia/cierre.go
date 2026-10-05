package incidencia

import (
	"context"
	"errors"
	"fmt"
	"time"

	"jsrbot/backend/internal/store"
)

// CerrarResueltasSinConfirmar cierra con el motivo «sin_confirmacion» las incidencias que
// llevan en 'resuelta' al menos 48 horas LABORALES (configuracion.cierre_automatico_horas,
// calendario base) sin que la persona confirme ni diga «sigue igual». No cuentan para el FCR.
// Cada cierre va en su propia transacción, con actor «sistema». Devuelve los números cerrados.
//
// Es la función que invoca el vigía cada minuto (y es idempotente: lo ya cerrado no se repite).
func (s *Servicio) CerrarResueltasSinConfirmar(ctx context.Context, ahora time.Time) ([]string, error) {
	ahora = ahora.UTC()
	horas, err := store.ConfigEntero(ctx, s.db, store.ConfCierreAutomaticoHoras, 48)
	if err != nil {
		return nil, err
	}
	_, cal, err := s.cache.Base(ctx, s.db)
	if err != nil {
		return nil, err
	}
	limite := time.Duration(horas) * time.Hour

	rows, err := s.db.Query(ctx, `SELECT id, resuelta_en FROM incidencias
		WHERE estado = 'resuelta' AND resuelta_en IS NOT NULL AND resuelta_en <= $1 ORDER BY resuelta_en, id`, ahora)
	if err != nil {
		return nil, fmt.Errorf("resueltas pendientes de confirmar: %w", err)
	}
	var ids []int64
	for rows.Next() {
		var id int64
		var resuelta time.Time
		if err := rows.Scan(&id, &resuelta); err != nil {
			rows.Close()
			return nil, err
		}
		if cal.Laboral(resuelta.UTC(), ahora) >= limite {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var cerradas []string
	for _, id := range ids {
		inc, err := conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) {
			o.ahora = ahora
			return o.Cerrar(ctx, id, EntradaCerrar{Motivo: CierreSinConfirmacion, Actor: ActorSistema()})
		})
		if err != nil {
			if errors.Is(err, ErrTransicionInvalida) {
				continue // la persona confirmó o reabrió entre la lectura y el cierre
			}
			return cerradas, fmt.Errorf("cerrar la incidencia %d: %w", id, err)
		}
		cerradas = append(cerradas, inc.Numero)
	}
	return cerradas, nil
}
