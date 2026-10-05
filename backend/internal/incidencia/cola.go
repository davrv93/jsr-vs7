package incidencia

import (
	"context"
	"errors"
	"fmt"
	"time"

	"jsrbot/backend/internal/despacho"
	"jsrbot/backend/internal/sla"
)

// elegirSinEscribir corre el despachador sin dejar rastro (para saber si ya hay candidato).
func (o *Operaciones) elegirSinEscribir(ctx context.Context, inc *Incidencia, cal *sla.Calendario) (despacho.Decision, error) {
	return despacho.Elegir(ctx, o.tx, despacho.Entrada{
		GrupoID: *inc.GrupoID, CategoriaID: inc.CategoriaID, Prioridad: inc.Prioridad, Ahora: o.ahora,
		Zona: cal.Zona, FueraDeHorario: !cal.EsLaboral(o.ahora),
	})
}

// DespacharCola reintenta asignar las incidencias que quedaron en la cola de su grupo (estado
// nueva, sin técnico), de la más urgente y antigua a la más nueva, y devuelve los números de
// las que consiguió asignar. Cada una va en su propia transacción. El vigía (o un trabajo
// propio) la llama cada minuto: en cuanto un técnico entra en turno o libera capacidad, la
// cola se vacía sola. Las que siguen sin candidato no generan eventos ni avisos nuevos.
func (s *Servicio) DespacharCola(ctx context.Context) ([]string, error) {
	return s.DespacharColaEn(ctx, s.Ahora())
}

// DespacharColaEn es DespacharCola con un instante dado.
func (s *Servicio) DespacharColaEn(ctx context.Context, ahora time.Time) ([]string, error) {
	rows, err := s.db.Query(ctx, `SELECT id FROM incidencias WHERE estado = 'nueva' AND tecnico_id IS NULL AND creada_en <= $1
		ORDER BY prioridad, creada_en, id`, ahora)
	if err != nil {
		return nil, fmt.Errorf("cola de incidencias: %w", err)
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var asignadas []string
	for _, id := range ids {
		r, err := conOp(ctx, s, func(o *Operaciones) (*Resultado, error) {
			o.ahora = ahora.UTC()
			res, err := o.AsignarDesdeCola(ctx, id)
			return res, err
		})
		if err != nil {
			// Otra transacción la movió mientras tanto: no es un fallo de la cola.
			if isTransicion(err) {
				continue
			}
			return asignadas, fmt.Errorf("despachar la incidencia %d: %w", id, err)
		}
		if r.Despacho != nil && r.Despacho.TecnicoID != nil {
			asignadas = append(asignadas, r.Incidencia.Numero)
		}
	}
	return asignadas, nil
}

func isTransicion(err error) bool { return errors.Is(err, ErrTransicionInvalida) }

// Simulacion es la decisión que tomaría el despachador ahora, sin haber asignado nada.
type Simulacion struct {
	GrupoID  int               `json:"grupo_id"`
	Grupo    string            `json:"grupo"`
	Decision despacho.Decision `json:"decision"`
}

// SimularDespacho corre el despachador para una categoría y una prioridad con la hora actual y
// devuelve la decisión SIN PERSISTIR NADA (la transacción se revierte). Sirve para que la
// consola muestre «si entrara una P2 de correo ahora, iría a Luis».
func (s *Servicio) SimularDespacho(ctx context.Context, categoria, prioridad string) (*Simulacion, error) {
	if !sla.ValidaPrioridad(prioridad) {
		return nil, invalido("prioridad %q desconocida (use P1, P2, P3 o P4)", prioridad)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("simular el despacho: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }() // nunca se confirma
	var catID, grupoID *int
	var grupo string
	err = tx.QueryRow(ctx, `SELECT c.id, g.id, g.nombre FROM categorias c JOIN grupos g ON g.id = c.grupo_id WHERE c.clave = $1 AND c.activa`, categoria).
		Scan(&catID, &grupoID, &grupo)
	if err != nil {
		return nil, invalido("la categoría %q no existe o no tiene grupo", categoria)
	}
	_, cal, err := s.cache.Base(ctx, tx)
	if err != nil {
		return nil, err
	}
	ahora := s.Ahora()
	dec, err := despacho.Elegir(ctx, tx, despacho.Entrada{
		GrupoID: *grupoID, CategoriaID: catID, Prioridad: prioridad, Ahora: ahora, Zona: cal.Zona, FueraDeHorario: !cal.EsLaboral(ahora),
	})
	if err != nil {
		return nil, err
	}
	return &Simulacion{GrupoID: *grupoID, Grupo: grupo, Decision: dec}, nil
}
