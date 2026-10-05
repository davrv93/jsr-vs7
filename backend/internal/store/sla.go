package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/sla"
)

// CargarCalendario lee un calendario con sus feriados.
func CargarCalendario(ctx context.Context, q Q, id int) (*sla.Calendario, error) {
	var nombre, zona string
	var v247 bool
	var horario []byte
	err := q.QueryRow(ctx, `SELECT nombre, zona, veinticuatro_siete, horario FROM calendarios WHERE id = $1`, id).
		Scan(&nombre, &zona, &v247, &horario)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("store: calendario %d: %w", id, ErrNoEncontrado)
	}
	if err != nil {
		return nil, fmt.Errorf("store: calendario %d: %w", id, err)
	}
	cal, err := sla.NuevoCalendario(nombre, zona, v247, horario)
	if err != nil {
		return nil, fmt.Errorf("store: calendario %q: %w", nombre, err)
	}
	rows, err := q.Query(ctx, `SELECT fecha::text, nombre FROM feriados WHERE calendario_id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("store: feriados de %q: %w", nombre, err)
	}
	defer rows.Close()
	for rows.Next() {
		var f, n string
		if err := rows.Scan(&f, &n); err != nil {
			return nil, err
		}
		if err := cal.AgregarFeriado(f, n); err != nil {
			return nil, err
		}
	}
	return cal, rows.Err()
}

// CalendarioPorNombre devuelve el id y el calendario de ese nombre.
func CalendarioPorNombre(ctx context.Context, q Q, nombre string) (int, *sla.Calendario, error) {
	var id int
	err := q.QueryRow(ctx, `SELECT id FROM calendarios WHERE nombre = $1`, nombre).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil, fmt.Errorf("store: calendario %q: %w", nombre, ErrNoEncontrado)
	}
	if err != nil {
		return 0, nil, err
	}
	cal, err := CargarCalendario(ctx, q, id)
	return id, cal, err
}

// CargarMatriz lee la matriz impacto x urgencia -> prioridad.
func CargarMatriz(ctx context.Context, q Q) (sla.Matriz, error) {
	rows, err := q.Query(ctx, `SELECT impacto, urgencia, prioridad FROM matriz_prioridad`)
	if err != nil {
		return nil, fmt.Errorf("store: matriz de prioridad: %w", err)
	}
	defer rows.Close()
	m := sla.Matriz{}
	for rows.Next() {
		var i, u, p string
		if err := rows.Scan(&i, &u, &p); err != nil {
			return nil, err
		}
		m.Poner(i, u, p)
	}
	return m, rows.Err()
}

// PoliticaSLA es una fila de sla_politicas.
type PoliticaSLA struct {
	ID            int
	Prioridad     string
	CategoriaID   *int
	CalendarioID  int
	RespuestaMin  int
	ResolucionMin int
}

// BuscarPolitica devuelve la política de una prioridad: la específica de la categoría si
// existe y, si no, la general (categoria_id NULL).
func BuscarPolitica(ctx context.Context, q Q, prioridad string, categoriaID *int) (*PoliticaSLA, error) {
	p := &PoliticaSLA{}
	err := q.QueryRow(ctx, `SELECT id, prioridad, categoria_id, calendario_id, respuesta_min, resolucion_min
		FROM sla_politicas
		WHERE prioridad = $1 AND (categoria_id IS NULL OR categoria_id = $2)
		ORDER BY (categoria_id IS NULL) LIMIT 1`, prioridad, categoriaID).
		Scan(&p.ID, &p.Prioridad, &p.CategoriaID, &p.CalendarioID, &p.RespuestaMin, &p.ResolucionMin)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("store: no hay política de SLA para %s: %w", prioridad, ErrNoEncontrado)
	}
	if err != nil {
		return nil, fmt.Errorf("store: política de SLA %s: %w", prioridad, err)
	}
	return p, nil
}

// MarcasReloj devuelve, por incidencia, los eventos que mueven el reloj de SLA (pausas,
// resuelta, reabierta) en orden cronológico.
func MarcasReloj(ctx context.Context, q Q, ids []int64) (map[int64][]sla.MarcaReloj, error) {
	out := map[int64][]sla.MarcaReloj{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := q.Query(ctx, `SELECT incidencia_id, ts, tipo FROM incidencia_eventos
		WHERE incidencia_id = ANY($1) AND tipo IN ('pausa_inicio','pausa_fin','resuelta','reabierta')
		ORDER BY incidencia_id, ts, id`, ids)
	if err != nil {
		return nil, fmt.Errorf("store: marcas del reloj: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var m sla.MarcaReloj
		if err := rows.Scan(&id, &m.TS, &m.Tipo); err != nil {
			return nil, err
		}
		m.TS = m.TS.UTC()
		out[id] = append(out[id], m)
	}
	return out, rows.Err()
}

// ContextoSLA es lo que hace falta para medir una incidencia: su calendario y sus plazos.
type ContextoSLA struct {
	CalendarioID int
	Cal          *sla.Calendario
	Pol          sla.Politica
}

// CacheSLA evita releer calendarios, políticas y matriz en cada operación. Es seguro entre
// goroutines. Expira cada TTL para que un cambio de configuración se note.
type CacheSLA struct {
	ttl time.Duration

	mu       sync.Mutex
	cargado  time.Time
	cals     map[int]*sla.Calendario
	pols     map[string]*PoliticaSLA
	matriz   sla.Matriz
	baseID   int
	baseCal  *sla.Calendario
	baseTodo bool
}

// NuevoCacheSLA crea un caché; ttl <= 0 usa 30 s.
func NuevoCacheSLA(ttl time.Duration) *CacheSLA {
	if ttl <= 0 {
		ttl = 30 * time.Second
	}
	return &CacheSLA{ttl: ttl}
}

// Invalidar fuerza la relectura en la próxima consulta.
func (c *CacheSLA) Invalidar() {
	c.mu.Lock()
	c.cargado = time.Time{}
	c.mu.Unlock()
}

func (c *CacheSLA) vigente() {
	if c.cals == nil || time.Since(c.cargado) > c.ttl {
		c.cals = map[int]*sla.Calendario{}
		c.pols = map[string]*PoliticaSLA{}
		c.matriz = nil
		c.baseCal = nil
		c.baseTodo = false
		c.cargado = time.Now()
	}
}

// Calendario devuelve el calendario con ese id.
func (c *CacheSLA) Calendario(ctx context.Context, q Q, id int) (*sla.Calendario, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.vigente()
	if cal, ok := c.cals[id]; ok {
		return cal, nil
	}
	cal, err := CargarCalendario(ctx, q, id)
	if err != nil {
		return nil, err
	}
	c.cals[id] = cal
	return cal, nil
}

// Contexto devuelve el calendario y los plazos de una prioridad (y categoría).
func (c *CacheSLA) Contexto(ctx context.Context, q Q, prioridad string, categoriaID *int) (ContextoSLA, error) {
	clave := prioridad + "|"
	if categoriaID != nil {
		clave += fmt.Sprint(*categoriaID)
	}
	c.mu.Lock()
	c.vigente()
	pol, ok := c.pols[clave]
	c.mu.Unlock()
	if !ok {
		var err error
		pol, err = BuscarPolitica(ctx, q, prioridad, categoriaID)
		if err != nil {
			return ContextoSLA{}, err
		}
		c.mu.Lock()
		c.pols[clave] = pol
		c.mu.Unlock()
	}
	cal, err := c.Calendario(ctx, q, pol.CalendarioID)
	if err != nil {
		return ContextoSLA{}, err
	}
	return ContextoSLA{CalendarioID: pol.CalendarioID, Cal: cal,
		Pol: sla.Politica{RespuestaMin: pol.RespuestaMin, ResolucionMin: pol.ResolucionMin}}, nil
}

// Base devuelve el calendario base (configuracion.calendario_base): el horario laboral de
// la mesa, que decide qué es «fuera de horario».
func (c *CacheSLA) Base(ctx context.Context, q Q) (int, *sla.Calendario, error) {
	c.mu.Lock()
	c.vigente()
	if c.baseTodo {
		id, cal := c.baseID, c.baseCal
		c.mu.Unlock()
		return id, cal, nil
	}
	c.mu.Unlock()
	nombre, err := ConfigTexto(ctx, q, ConfCalendarioBase, NombreCalendarioLaboral)
	if err != nil {
		return 0, nil, err
	}
	id, cal, err := CalendarioPorNombre(ctx, q, nombre)
	if err != nil {
		return 0, nil, err
	}
	c.mu.Lock()
	c.baseID, c.baseCal, c.baseTodo = id, cal, true
	c.cals[id] = cal
	c.mu.Unlock()
	return id, cal, nil
}

// Matriz devuelve la matriz de prioridad.
func (c *CacheSLA) Matriz(ctx context.Context, q Q) (sla.Matriz, error) {
	c.mu.Lock()
	c.vigente()
	if c.matriz != nil {
		m := c.matriz
		c.mu.Unlock()
		return m, nil
	}
	c.mu.Unlock()
	m, err := CargarMatriz(ctx, q)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.matriz = m
	c.mu.Unlock()
	return m, nil
}
