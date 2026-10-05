package despacho

import (
	"context"
	"fmt"
	"time"

	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// Entrada de Elegir.
type Entrada struct {
	GrupoID     int
	CategoriaID *int // nil = la categoría no exige habilidad
	Prioridad   string
	Ahora       time.Time
	// Zona es la zona del calendario base: los turnos se leen en hora local de ella.
	Zona *time.Location
	// FueraDeHorario: Ahora cae fuera del calendario laboral base (decide la guardia de P1).
	FueraDeHorario bool
}

// estadosAbiertos son los estados en que la incidencia pesa en la carga del técnico.
const estadosAbiertos = `('asignada','en_curso','espera_usuario','espera_tercero','reabierta')`

// Elegir lee de la base lo que el despachador necesita y decide. DEBE llamarse dentro de la
// transacción que va a registrar la asignación: bloquea (FOR UPDATE, en orden de id) a los
// técnicos candidatos, de modo que dos asignaciones simultáneas no sobrepasen la capacidad.
// No escribe nada: quien llama aplica la decisión (e.g. incidencia.Crear).
func Elegir(ctx context.Context, q store.Q, e Entrada) (Decision, error) {
	if e.Zona == nil {
		e.Zona = time.UTC
	}

	// 1. Técnicos involucrados: miembros del grupo y, para P1, quienes tienen guardia vigente.
	idsMiembros, err := columnaInt(ctx, q, `SELECT tecnico_id FROM grupo_miembros WHERE grupo_id = $1`, e.GrupoID)
	if err != nil {
		return Decision{}, fmt.Errorf("despacho: miembros del grupo %d: %w", e.GrupoID, err)
	}
	var idsGuardia []int
	if e.Prioridad == "P1" {
		idsGuardia, err = columnaInt(ctx, q, `SELECT DISTINCT tecnico_id FROM guardias WHERE desde <= $1 AND $1 < hasta`, e.Ahora)
		if err != nil {
			return Decision{}, fmt.Errorf("despacho: guardias: %w", err)
		}
	}
	todos := unir(idsMiembros, idsGuardia)
	if len(todos) == 0 {
		return Decidir(Peticion{Prioridad: e.Prioridad, FueraDeHorario: e.FueraDeHorario}, nil, nil), nil
	}

	// 2. Datos de los técnicos, bloqueados en orden de id (evita deadlocks entre despachos).
	cands := map[int]*Candidato{}
	rows, err := q.Query(ctx, `SELECT id, nombre, estado, capacidad, ultima_asignacion
		FROM tecnicos WHERE id = ANY($1) ORDER BY id FOR UPDATE`, todos)
	if err != nil {
		return Decision{}, fmt.Errorf("despacho: técnicos: %w", err)
	}
	for rows.Next() {
		c := &Candidato{}
		if err := rows.Scan(&c.TecnicoID, &c.Nombre, &c.Estado, &c.Capacidad, &c.UltimaAsignacion); err != nil {
			rows.Close()
			return Decision{}, err
		}
		c.UltimaAsignacion = store.UTCPtr(c.UltimaAsignacion)
		cands[c.TecnicoID] = c
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return Decision{}, err
	}

	// 3. Habilidad en la categoría.
	if e.CategoriaID == nil {
		for _, c := range cands {
			c.TieneHabilidad = true
		}
	} else {
		ids, err := columnaInt(ctx, q, `SELECT tecnico_id FROM habilidades WHERE categoria_id = $1 AND tecnico_id = ANY($2)`, *e.CategoriaID, todos)
		if err != nil {
			return Decision{}, fmt.Errorf("despacho: habilidades: %w", err)
		}
		for _, id := range ids {
			if c := cands[id]; c != nil {
				c.TieneHabilidad = true
			}
		}
	}

	// 4. Ausencias vigentes.
	ausentes, err := columnaInt(ctx, q, `SELECT DISTINCT tecnico_id FROM ausencias
		WHERE tecnico_id = ANY($1) AND desde <= $2 AND $2 < hasta`, todos, e.Ahora)
	if err != nil {
		return Decision{}, fmt.Errorf("despacho: ausencias: %w", err)
	}
	for _, id := range ausentes {
		if c := cands[id]; c != nil {
			c.Ausencia = true
		}
	}

	// 5. Turnos.
	trows, err := q.Query(ctx, `SELECT tecnico_id, dia_semana, desde::text, hasta::text FROM turnos WHERE tecnico_id = ANY($1)`, todos)
	if err != nil {
		return Decision{}, fmt.Errorf("despacho: turnos: %w", err)
	}
	turnos := map[int][]Turno{}
	for trows.Next() {
		var id, dia int
		var d, h string
		if err := trows.Scan(&id, &dia, &d, &h); err != nil {
			trows.Close()
			return Decision{}, err
		}
		md, err1 := sla.ParsearHora(d)
		mh, err2 := sla.ParsearHora(h)
		if err1 != nil || err2 != nil {
			trows.Close()
			return Decision{}, fmt.Errorf("despacho: turno del técnico %d con hora inválida (%q-%q)", id, d, h)
		}
		turnos[id] = append(turnos[id], Turno{Dia: dia, Desde: md, Hasta: mh})
	}
	trows.Close()
	if err := trows.Err(); err != nil {
		return Decision{}, err
	}
	for id, c := range cands {
		c.EnTurno = EnTurno(turnos[id], e.Zona, e.Ahora)
	}

	// 6. Carga actual, ponderada por prioridad.
	pesos, err := store.PesosCarga(ctx, q)
	if err != nil {
		return Decision{}, err
	}
	crows, err := q.Query(ctx, `SELECT tecnico_id, prioridad, count(*) FROM incidencias
		WHERE tecnico_id = ANY($1) AND estado IN `+estadosAbiertos+` GROUP BY tecnico_id, prioridad`, todos)
	if err != nil {
		return Decision{}, fmt.Errorf("despacho: carga: %w", err)
	}
	for crows.Next() {
		var id, n int
		var prio string
		if err := crows.Scan(&id, &prio, &n); err != nil {
			crows.Close()
			return Decision{}, err
		}
		if c := cands[id]; c != nil {
			c.Abiertas += n
			c.Carga += n * pesos[prio]
		}
	}
	crows.Close()
	if err := crows.Err(); err != nil {
		return Decision{}, err
	}

	// 7. Núcleo.
	var miembros, guardias []Candidato
	for _, id := range idsMiembros {
		if c := cands[id]; c != nil {
			miembros = append(miembros, *c)
		}
	}
	for _, id := range idsGuardia {
		if c := cands[id]; c != nil {
			guardias = append(guardias, *c)
		}
	}
	return Decidir(Peticion{Prioridad: e.Prioridad, FueraDeHorario: e.FueraDeHorario}, miembros, guardias), nil
}

// RegistrarAsignacion deja constancia de que el técnico recibió una incidencia (actualiza
// ultima_asignacion, que sirve para el desempate). Va en la misma transacción que Elegir.
func RegistrarAsignacion(ctx context.Context, q store.Q, tecnicoID int, ahora time.Time) error {
	_, err := q.Exec(ctx, `UPDATE tecnicos SET ultima_asignacion = $2 WHERE id = $1`, tecnicoID, ahora)
	if err != nil {
		return fmt.Errorf("despacho: ultima_asignacion del técnico %d: %w", tecnicoID, err)
	}
	return nil
}

func columnaInt(ctx context.Context, q store.Q, sql string, args ...any) ([]int, error) {
	rows, err := q.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func unir(a, b []int) []int {
	vistos := map[int]bool{}
	var out []int
	for _, xs := range [][]int{a, b} {
		for _, x := range xs {
			if !vistos[x] {
				vistos[x] = true
				out = append(out, x)
			}
		}
	}
	return out
}
