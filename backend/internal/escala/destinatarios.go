package escala

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/store"
)

// destino es a quién va un aviso. id nil = no se pudo resolver (nadie de guardia, sin supervisor).
type destino struct {
	tipo string
	id   *int
}

// destinatarios resuelve a quién avisa una acción de aviso. nota explica un respaldo.
//
//   - avisar_tecnico: el técnico de la incidencia; si no tiene (está en la cola), el
//     responsable del grupo.
//   - avisar_responsable: el responsable del grupo en que estaba la incidencia al dispararse.
//   - avisar_guardia: quienes tienen guardia vigente; si no hay nadie, el supervisor.
//   - avisar_supervisor: configuracion.supervisor_tecnico_id o, si no, un usuario de consola
//     con rol supervisor que sea técnico.
func (v *Vigia) destinatarios(ctx context.Context, q store.Q, accion string, f Foto, grupoOriginal *int, ahora time.Time) ([]destino, string, error) {
	switch accion {
	case AccAvisarTecnico:
		if f.TecnicoID != nil {
			return []destino{{store.DestTecnico, f.TecnicoID}}, "", nil
		}
		resp, err := responsableGrupo(ctx, q, grupoOriginal)
		return []destino{{store.DestResponsableGrupo, resp}}, "sin_tecnico", err
	case AccAvisarResponsable:
		resp, err := responsableGrupo(ctx, q, grupoOriginal)
		return []destino{{store.DestResponsableGrupo, resp}}, "", err
	case AccAvisarGuardia:
		rows, err := q.Query(ctx, `SELECT DISTINCT tecnico_id FROM guardias WHERE desde <= $1 AND $1 < hasta ORDER BY tecnico_id`, ahora)
		if err != nil {
			return nil, "", fmt.Errorf("guardias vigentes: %w", err)
		}
		var out []destino
		for rows.Next() {
			var id int
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, "", err
			}
			out = append(out, destino{store.DestGuardia, &id})
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, "", err
		}
		if len(out) > 0 {
			return out, "", nil
		}
		sup, err := supervisor(ctx, q)
		return []destino{{store.DestSupervisor, sup}}, "sin_guardia", err
	case AccAvisarSupervisor:
		sup, err := supervisor(ctx, q)
		return []destino{{store.DestSupervisor, sup}}, "", err
	}
	return nil, "", fmt.Errorf("acción de aviso %q desconocida", accion)
}

func responsableGrupo(ctx context.Context, q store.Q, grupoID *int) (*int, error) {
	if grupoID == nil {
		return nil, nil
	}
	var resp *int
	if err := q.QueryRow(ctx, `SELECT responsable_tecnico_id FROM grupos WHERE id = $1`, *grupoID).Scan(&resp); err != nil {
		return nil, fmt.Errorf("responsable del grupo %d: %w", *grupoID, err)
	}
	return resp, nil
}

// supervisor devuelve el técnico que recibe los avisos «al supervisor», o nil si no hay.
func supervisor(ctx context.Context, q store.Q) (*int, error) {
	id, err := store.ConfigEntero(ctx, q, store.ConfSupervisorTecnicoID, 0)
	if err != nil {
		return nil, err
	}
	if id > 0 {
		return &id, nil
	}
	err = q.QueryRow(ctx, `SELECT tecnico_id FROM usuarios_consola WHERE rol = 'supervisor' AND activo AND tecnico_id IS NOT NULL
		ORDER BY id LIMIT 1`).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("supervisor: %w", err)
	}
	return &id, nil
}
