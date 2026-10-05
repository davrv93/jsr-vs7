package incidencia

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// Obtener lee una incidencia por id (sin transacción ni bloqueo).
func (s *Servicio) Obtener(ctx context.Context, id int64) (*Incidencia, error) {
	inc, err := escanear(s.db.QueryRow(ctx, sqlSeleccionarIncidencia+` WHERE i.id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("incidencia %d: %w", id, ErrNoEncontrado)
	}
	return inc, err
}

// ObtenerPorNumero lee una incidencia por su número (INC-000123).
func (s *Servicio) ObtenerPorNumero(ctx context.Context, numero string) (*Incidencia, error) {
	inc, err := escanear(s.db.QueryRow(ctx, sqlSeleccionarIncidencia+` WHERE i.numero = $1`, numero))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("incidencia %s: %w", numero, ErrNoEncontrado)
	}
	return inc, err
}

// ObtenerPorToken lee una incidencia por su token público (página de estado).
func (s *Servicio) ObtenerPorToken(ctx context.Context, token string) (*Incidencia, error) {
	inc, err := escanear(s.db.QueryRow(ctx, sqlSeleccionarIncidencia+` WHERE i.token_publico = $1`, token))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("incidencia: %w", ErrNoEncontrado)
	}
	return inc, err
}

// Eventos devuelve el historial de la incidencia en orden cronológico. Los datos incluyen la
// clave «contexto» (foto de prioridad, categoría, grupo y técnico en ese momento).
func (s *Servicio) Eventos(ctx context.Context, id int64) ([]Evento, error) {
	rows, err := s.db.Query(ctx, `SELECT id, incidencia_id, ts, tipo, actor_tipo, actor_id, datos
		FROM incidencia_eventos WHERE incidencia_id = $1 ORDER BY ts, id`, id)
	if err != nil {
		return nil, fmt.Errorf("eventos de la incidencia %d: %w", id, err)
	}
	defer rows.Close()
	var out []Evento
	for rows.Next() {
		var e Evento
		var raw []byte
		if err := rows.Scan(&e.ID, &e.IncidenciaID, &e.TS, &e.Tipo, &e.ActorTipo, &e.ActorID, &raw); err != nil {
			return nil, err
		}
		e.TS = e.TS.UTC()
		_ = json.Unmarshal(raw, &e.Datos)
		out = append(out, e)
	}
	return out, rows.Err()
}

// EstadoSLA es la foto de los dos plazos de una incidencia (para la consola).
type EstadoSLA struct {
	Respuesta  sla.Estado `json:"respuesta"`
	Resolucion sla.Estado `json:"resolucion"`
	// RespuestaOK y ResolucionOK: nil si aún no aplica; true/false si ya se cumplió o venció.
	RespuestaOK  *bool `json:"respuesta_ok"`
	ResolucionOK *bool `json:"resolucion_ok"`
	// Pausada: el reloj está detenido (espera_usuario o espera_tercero).
	Pausada           bool       `json:"pausada"`
	VenceRespuestaEn  *time.Time `json:"vence_respuesta_en"`
	VenceResolucionEn *time.Time `json:"vence_resolucion_en"`
	// Vencida resume: algún plazo pendiente ya se pasó.
	Vencida bool `json:"vencida"`
}

// SLA mide los plazos de una incidencia con el reloj del servicio (porcentaje consumido,
// minutos restantes, vencida), calculados desde los eventos.
func (s *Servicio) SLA(ctx context.Context, id int64) (*EstadoSLA, error) {
	inc, err := s.Obtener(ctx, id)
	if err != nil {
		return nil, err
	}
	return s.slaDe(ctx, s.db, inc, s.Ahora())
}

func (s *Servicio) slaDe(ctx context.Context, q store.Q, inc *Incidencia, ahora time.Time) (*EstadoSLA, error) {
	marcas, err := store.MarcasReloj(ctx, q, []int64{inc.ID})
	if err != nil {
		return nil, err
	}
	return s.slaCon(ctx, q, inc, marcas[inc.ID], ahora)
}

func (s *Servicio) slaCon(ctx context.Context, q store.Q, inc *Incidencia, marcas []sla.MarcaReloj, ahora time.Time) (*EstadoSLA, error) {
	cs, err := s.cache.Contexto(ctx, q, inc.Prioridad, inc.CategoriaID)
	if err != nil {
		return nil, err
	}
	r := sla.Evaluar(sla.Entrada{
		Cal: cs.Cal, Pol: cs.Pol, Creada: inc.CreadaEn, PrimeraRespuesta: inc.PrimeraRespuestaEn, Resuelta: inc.ResueltaEn,
		Pausas: sla.PausasDeEventos(marcas), Ahora: ahora,
	})
	out := &EstadoSLA{
		Respuesta: r.Respuesta, Resolucion: r.Resolucion, RespuestaOK: r.RespuestaOK, ResolucionOK: r.ResolucionOK,
		Pausada: inc.Estado.Pausa(), VenceRespuestaEn: inc.VenceRespuestaEn, VenceResolucionEn: inc.VenceResolucionEn,
	}
	out.Vencida = (inc.PrimeraRespuestaEn == nil && r.Respuesta.Vencida) || (inc.Estado.Abierta() && r.Resolucion.Vencida)
	return out, nil
}

// Detalle es lo que muestra la consola en el detalle de una incidencia (GET /api/incidencias/{id}).
type Detalle struct {
	Incidencia *Incidencia `json:"incidencia"`
	SLA        *EstadoSLA  `json:"sla"`
	Eventos    []Evento    `json:"eventos"`
	// Acciones son las acciones válidas desde el estado actual (para ofrecer solo botones que funcionan).
	Acciones []Accion `json:"acciones"`
}

// Detalle reúne la incidencia, su SLA, sus eventos y las acciones permitidas.
func (s *Servicio) Detalle(ctx context.Context, id int64) (*Detalle, error) {
	inc, err := s.Obtener(ctx, id)
	if err != nil {
		return nil, err
	}
	sl, err := s.slaDe(ctx, s.db, inc, s.Ahora())
	if err != nil {
		return nil, err
	}
	evs, err := s.Eventos(ctx, id)
	if err != nil {
		return nil, err
	}
	return &Detalle{Incidencia: inc, SLA: sl, Eventos: evs, Acciones: Permitidas(inc.Estado)}, nil
}

// Filtro de Listar (docs/CONTRATOS.md §2: estado, prioridad, tecnico_id, grupo_id, categoria, q, abiertas).
type Filtro struct {
	Estado     string
	Prioridad  string
	TecnicoID  *int
	GrupoID    *int
	Categoria  string // clave
	PersonaID  *int
	Q          string // busca en número y título
	Abiertas   bool   // solo las que no están resueltas ni cerradas
	SinAsignar bool   // sin técnico
	// VencenAntes: solo las abiertas cuyo vence_resolucion_en (o vence_respuesta_en sin responder) es <= este instante.
	VencenAntes *time.Time
	// Orden: "vencimiento" (lo que vence antes primero), "prioridad" o, por defecto, la más nueva primero.
	Orden     string
	Pagina    int // desde 1
	PorPagina int // por defecto 50, máximo 200
}

// Listar devuelve una página de incidencias y el total que cumple el filtro.
func (s *Servicio) Listar(ctx context.Context, f Filtro) ([]Incidencia, int, error) {
	var cond []string
	var args []any
	add := func(sql string, v any) {
		args = append(args, v)
		cond = append(cond, strings.ReplaceAll(sql, "?", fmt.Sprintf("$%d", len(args))))
	}
	if f.Estado != "" {
		add("i.estado = ?", f.Estado)
	}
	if f.Prioridad != "" {
		add("i.prioridad = ?", f.Prioridad)
	}
	if f.TecnicoID != nil {
		add("i.tecnico_id = ?", *f.TecnicoID)
	}
	if f.GrupoID != nil {
		add("i.grupo_id = ?", *f.GrupoID)
	}
	if f.PersonaID != nil {
		add("i.persona_id = ?", *f.PersonaID)
	}
	if f.Categoria != "" {
		add("c.clave = ?", f.Categoria)
	}
	if f.Q != "" {
		add("(i.numero ILIKE ? OR i.titulo ILIKE ?)", "%"+f.Q+"%")
	}
	if f.Abiertas {
		cond = append(cond, "i.estado NOT IN ('resuelta', 'cerrada')")
	}
	if f.SinAsignar {
		cond = append(cond, "i.tecnico_id IS NULL AND i.estado NOT IN ('resuelta', 'cerrada')")
	}
	if f.VencenAntes != nil {
		add(`i.estado NOT IN ('resuelta', 'cerrada') AND LEAST(i.vence_resolucion_en,
			CASE WHEN i.primera_respuesta_en IS NULL THEN i.vence_respuesta_en END) <= ?`, *f.VencenAntes)
	}
	donde := ""
	if len(cond) > 0 {
		donde = " WHERE " + strings.Join(cond, " AND ")
	}
	var total int
	if err := s.db.QueryRow(ctx, `SELECT count(*) FROM incidencias i LEFT JOIN categorias c ON c.id = i.categoria_id`+donde, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("contar incidencias: %w", err)
	}
	orden := "i.creada_en DESC, i.id DESC"
	switch f.Orden {
	case "vencimiento":
		orden = "LEAST(i.vence_resolucion_en, CASE WHEN i.primera_respuesta_en IS NULL THEN i.vence_respuesta_en END) NULLS LAST, i.id"
	case "prioridad":
		orden = "i.prioridad, i.creada_en, i.id"
	}
	if f.PorPagina <= 0 {
		f.PorPagina = 50
	}
	f.PorPagina = min(f.PorPagina, 200)
	if f.Pagina <= 0 {
		f.Pagina = 1
	}
	args = append(args, f.PorPagina, (f.Pagina-1)*f.PorPagina)
	rows, err := s.db.Query(ctx, sqlSeleccionarIncidencia+donde+" ORDER BY "+orden+
		fmt.Sprintf(" LIMIT $%d OFFSET $%d", len(args)-1, len(args)), args...)
	if err != nil {
		return nil, 0, fmt.Errorf("listar incidencias: %w", err)
	}
	defer rows.Close()
	var out []Incidencia
	for rows.Next() {
		inc, err := escanear(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *inc)
	}
	return out, total, rows.Err()
}

// BuscarAbiertaDuplicada devuelve la incidencia ABIERTA más reciente de esa persona en esa
// categoría, o nil si no hay. Es la regla «una sola incidencia abierta por síntoma»
// (ARQUITECTURA §2.1): si existe, el caso debe llamar a AgregarDato sobre ella en vez de Crear.
// Abierta = nueva, asignada, en_curso, espera_usuario, espera_tercero o reabierta.
func (s *Servicio) BuscarAbiertaDuplicada(ctx context.Context, personaID int, categoria string) (*Incidencia, error) {
	inc, err := escanear(s.db.QueryRow(ctx, sqlSeleccionarIncidencia+` WHERE i.persona_id = $1 AND c.clave = $2
		AND i.estado NOT IN ('resuelta', 'cerrada') ORDER BY i.creada_en DESC, i.id DESC LIMIT 1`, personaID, categoria))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return inc, err
}

// BuscarResueltaReciente devuelve la incidencia en estado 'resuelta' más reciente de esa
// persona y categoría resuelta desde `desde`, o nil. Sirve para el «sigue igual»: el caso la
// reabre con Reabrir en vez de abrir otra.
func (s *Servicio) BuscarResueltaReciente(ctx context.Context, personaID int, categoria string, desde time.Time) (*Incidencia, error) {
	inc, err := escanear(s.db.QueryRow(ctx, sqlSeleccionarIncidencia+` WHERE i.persona_id = $1 AND c.clave = $2
		AND i.estado = 'resuelta' AND i.resuelta_en >= $3 ORDER BY i.resuelta_en DESC, i.id DESC LIMIT 1`, personaID, categoria, desde))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return inc, err
}

// RegistrarEncuesta guarda una encuesta de satisfacción YA RESPONDIDA (1-5) de una incidencia y
// deja la fila «encuestas» en el outbox. Atajo para altas manuales y pruebas: el flujo real lo
// lleva la pasarela, que escribe la fila al ENVIAR la encuesta (puntaje NULL = sin responder) y la
// actualiza al responder (docs/CONTRATOS.md «Cambios» 4).
func (s *Servicio) RegistrarEncuesta(ctx context.Context, incidenciaID int64, puntaje int, comentario string) (int64, error) {
	if puntaje < 1 || puntaje > 5 {
		return 0, invalido("el puntaje de la encuesta va de 1 a 5, no %d", puntaje)
	}
	var id int64
	err := s.EnTx(ctx, func(o *Operaciones) error {
		inc, err := o.cargar(ctx, incidenciaID, false)
		if err != nil {
			return err
		}
		if err := o.tx.QueryRow(ctx, `INSERT INTO encuestas (incidencia_id, caso_id, puntaje, comentario, ts)
			VALUES ($1, $2, $3, NULLIF($4, ''), $5) RETURNING id`, inc.ID, inc.CasoID, puntaje, comentario, o.ahora).Scan(&id); err != nil {
			return fmt.Errorf("registrar la encuesta: %w", err)
		}
		return analitica.EncolarEncuesta(ctx, o.tx, id)
	})
	return id, err
}

// SLALote mide el SLA de varias incidencias con pocas consultas (una por las incidencias, una
// por sus marcas del reloj). Los ids que no existen no aparecen en el resultado. Es lo que usa
// la bandeja para pintar el avance de plazo de cada fila.
func (s *Servicio) SLALote(ctx context.Context, ids []int64) (map[int64]*EstadoSLA, error) {
	out := map[int64]*EstadoSLA{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.db.Query(ctx, sqlSeleccionarIncidencia+` WHERE i.id = ANY($1)`, ids)
	if err != nil {
		return nil, fmt.Errorf("SLA por lote: %w", err)
	}
	var incs []*Incidencia
	for rows.Next() {
		inc, err := escanear(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		incs = append(incs, inc)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	marcas, err := store.MarcasReloj(ctx, s.db, ids)
	if err != nil {
		return nil, err
	}
	ahora := s.Ahora()
	for _, inc := range incs {
		e, err := s.slaCon(ctx, s.db, inc, marcas[inc.ID], ahora)
		if err != nil {
			return nil, err
		}
		out[inc.ID] = e
	}
	return out, nil
}
