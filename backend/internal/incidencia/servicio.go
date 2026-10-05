package incidencia

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// Errores públicos. Úselos con errors.Is.
var (
	// ErrNoEncontrado: la incidencia (o el técnico, grupo...) no existe.
	ErrNoEncontrado = store.ErrNoEncontrado
	// ErrInvalido: los datos de la acción no son válidos (vocabulario, campos vacíos...).
	ErrInvalido = errors.New("datos inválidos")
	// ErrSinNivelSuperior: se pidió escalar desde un grupo sin escala_a_grupo_id.
	ErrSinNivelSuperior = errors.New("el grupo no tiene un nivel superior al que escalar")
)

func invalido(formato string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalido, fmt.Sprintf(formato, a...))
}

// Actor es quien hace una acción (queda en el evento).
type Actor struct {
	Tipo string `json:"tipo"` // usuario | tecnico | asistente | sistema
	ID   string `json:"id,omitempty"`
}

// ActorSistema es el vigía, los trabajos automáticos y el despachador.
func ActorSistema() Actor { return Actor{Tipo: "sistema"} }

// ActorAsistente es el asistente conversacional.
func ActorAsistente() Actor { return Actor{Tipo: "asistente"} }

// ActorTecnico es un técnico (id de tecnicos).
func ActorTecnico(id int) Actor { return Actor{Tipo: "tecnico", ID: strconv.Itoa(id)} }

// ActorUsuario es la persona que reportó (id de personas).
func ActorUsuario(personaID int) Actor { return Actor{Tipo: "usuario", ID: strconv.Itoa(personaID)} }

func (a Actor) validar() error {
	switch a.Tipo {
	case "usuario", "tecnico", "asistente", "sistema":
		return nil
	}
	return invalido("actor %q desconocido (use usuario, tecnico, asistente o sistema)", a.Tipo)
}

// Incidencia es la proyección de la fila de incidencias, con la clave de la categoría y el
// nombre del grupo ya resueltos.
type Incidencia struct {
	ID                 int64      `json:"id"`
	Numero             string     `json:"numero"`
	PersonaID          *int       `json:"persona_id"`
	CasoID             *int64     `json:"caso_id"`
	Tipo               string     `json:"tipo"`
	CategoriaID        *int       `json:"categoria_id"`
	Categoria          string     `json:"categoria"` // clave
	Impacto            string     `json:"impacto"`
	Urgencia           string     `json:"urgencia"`
	Prioridad          string     `json:"prioridad"`
	Estado             Estado     `json:"estado"`
	Titulo             string     `json:"titulo"`
	Resumen            string     `json:"resumen"`
	GrupoID            *int       `json:"grupo_id"`
	Grupo              string     `json:"grupo"`
	TecnicoID          *int       `json:"tecnico_id"`
	Nivel              string     `json:"nivel"`
	Reaperturas        int        `json:"reaperturas"`
	Escalamientos      int        `json:"escalamientos"`
	Canal              string     `json:"canal"`
	TokenPublico       string     `json:"token_publico"`
	CreadaEn           time.Time  `json:"creada_en"`
	PrimeraRespuestaEn *time.Time `json:"primera_respuesta_en"`
	ResueltaEn         *time.Time `json:"resuelta_en"`
	CerradaEn          *time.Time `json:"cerrada_en"`
	VenceRespuestaEn   *time.Time `json:"vence_respuesta_en"`
	VenceResolucionEn  *time.Time `json:"vence_resolucion_en"`
	MotivoCierre       *string    `json:"motivo_cierre"`
	ActualizadaEn      time.Time  `json:"actualizada_en"`
}

// Evento es una fila de incidencia_eventos (inmutable).
type Evento struct {
	ID           int64          `json:"id"`
	IncidenciaID int64          `json:"incidencia_id"`
	TS           time.Time      `json:"ts"`
	Tipo         string         `json:"tipo"`
	ActorTipo    string         `json:"actor_tipo"`
	ActorID      *string        `json:"actor_id"`
	Datos        map[string]any `json:"datos"`
}

// Tipos de evento que escribe este paquete (columna incidencia_eventos.tipo).
const (
	EvCreada           = "creada"
	EvAsignada         = "asignada"
	EvReasignada       = "reasignada"
	EvEnCola           = "en_cola"
	EvPrimeraRespuesta = "primera_respuesta"
	EvEstadoCambiado   = "estado_cambiado"
	EvPausaInicio      = "pausa_inicio"
	EvPausaFin         = "pausa_fin"
	EvComentario       = "comentario"
	EvComentarioInt    = "comentario_interno"
	EvEscalada         = "escalada"
	EvAvisoSLA         = "aviso_sla"
	EvPrioridad        = "prioridad_cambiada"
	EvResuelta         = "resuelta"
	EvReabierta        = "reabierta"
	EvCerrada          = "cerrada"
	EvDatoAgregado     = "dato_agregado"
	EvQueja            = "queja"
	// EvSLAVencido lo deja el vigía una sola vez por plazo (metrica respuesta o resolucion) cuando
	// el plazo se pasa; vuelve a escribir las filas de estado y tiempos con el veredicto «incumplida».
	EvSLAVencido = "sla_vencido"
)

// Servicio es el punto de entrada del gestor de incidencias. Cada método público abre su
// propia transacción; para componer varias acciones (o acciones más escrituras propias) en
// una sola transacción use Servicio.EnTx / Servicio.Sobre y la API de Operaciones.
type Servicio struct {
	db    *store.DB
	reloj func() time.Time
	cache *store.CacheSLA
}

// Opcion configura el Servicio.
type Opcion func(*Servicio)

// ConReloj inyecta el reloj (pruebas y semilla sintética). Por defecto time.Now().UTC().
func ConReloj(f func() time.Time) Opcion { return func(s *Servicio) { s.reloj = f } }

// ConCache comparte un caché de calendarios y políticas entre servicios.
func ConCache(c *store.CacheSLA) Opcion { return func(s *Servicio) { s.cache = c } }

// Nuevo crea el servicio.
func Nuevo(db *store.DB, opts ...Opcion) *Servicio {
	s := &Servicio{db: db, reloj: func() time.Time { return time.Now().UTC() }}
	for _, o := range opts {
		o(s)
	}
	if s.cache == nil {
		s.cache = store.NuevoCacheSLA(30 * time.Second)
	}
	return s
}

// DB devuelve el pool.
func (s *Servicio) DB() *store.DB { return s.db }

// Cache devuelve el caché de SLA (calendarios, políticas, matriz) para compartirlo.
func (s *Servicio) Cache() *store.CacheSLA { return s.cache }

// Ahora devuelve la hora según el reloj del servicio.
func (s *Servicio) Ahora() time.Time { return s.reloj().UTC() }

// RelojManual es un reloj que se mueve a mano: sirve para pruebas y para la semilla.
type RelojManual struct {
	mu sync.Mutex
	t  time.Time
}

// NuevoRelojManual crea un reloj fijo en t.
func NuevoRelojManual(t time.Time) *RelojManual { return &RelojManual{t: t.UTC()} }

// Ahora es la hora actual del reloj (úsese como ConReloj(r.Ahora)).
func (r *RelojManual) Ahora() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.t
}

// Fijar pone el reloj en t.
func (r *RelojManual) Fijar(t time.Time) {
	r.mu.Lock()
	r.t = t.UTC()
	r.mu.Unlock()
}

// Avanzar mueve el reloj d hacia delante.
func (r *RelojManual) Avanzar(d time.Duration) {
	r.mu.Lock()
	r.t = r.t.Add(d)
	r.mu.Unlock()
}

// Operaciones es la API del gestor ligada a UNA transacción abierta y a UN instante.
type Operaciones struct {
	s     *Servicio
	tx    pgx.Tx
	ahora time.Time
	pend  []analitica.EventoIncidencia
}

// EnTx abre una transacción, ejecuta f con las Operaciones ligadas a ella y confirma si f
// devuelve nil (revierte si devuelve error). Todas las acciones de f comparten el mismo
// instante (el del reloj al empezar) y la misma transacción.
func (s *Servicio) EnTx(ctx context.Context, f func(o *Operaciones) error) error {
	return s.db.EnTx(ctx, func(tx pgx.Tx) error { return f(s.Sobre(tx)) })
}

// Sobre liga el servicio a una transacción abierta por el llamador (por ejemplo la del caso,
// para crear la incidencia y actualizar casos en el mismo COMMIT). El instante es el del reloj.
func (s *Servicio) Sobre(tx pgx.Tx) *Operaciones {
	return &Operaciones{s: s, tx: tx, ahora: s.Ahora().Truncate(time.Microsecond)}
}

// SobreEn es Sobre con un instante dado (el vigía usa el suyo).
func (s *Servicio) SobreEn(tx pgx.Tx, ahora time.Time) *Operaciones {
	return &Operaciones{s: s, tx: tx, ahora: ahora.UTC().Truncate(time.Microsecond)}
}

// Tx devuelve la transacción subyacente, para que el llamador haga sus propias escrituras.
func (o *Operaciones) Tx() pgx.Tx { return o.tx }

// Ahora es el instante de esta operación.
func (o *Operaciones) Ahora() time.Time { return o.ahora }

func conOp[T any](ctx context.Context, s *Servicio, f func(o *Operaciones) (T, error)) (T, error) {
	var out T
	err := s.EnTx(ctx, func(o *Operaciones) error {
		var err error
		out, err = f(o)
		return err
	})
	return out, err
}

// ---- lectura ----------------------------------------------------------------------------------

const sqlSeleccionarIncidencia = `SELECT i.id, i.numero, i.persona_id, i.caso_id, i.tipo, i.categoria_id, COALESCE(c.clave, ''),
	i.impacto, i.urgencia, i.prioridad, i.estado, i.titulo, i.resumen, i.grupo_id, COALESCE(g.nombre, ''), i.tecnico_id,
	i.nivel, i.reaperturas, i.escalamientos, i.canal, i.token_publico, i.creada_en, i.primera_respuesta_en, i.resuelta_en,
	i.cerrada_en, i.vence_respuesta_en, i.vence_resolucion_en, i.motivo_cierre, i.actualizada_en
	FROM incidencias i
	LEFT JOIN categorias c ON c.id = i.categoria_id
	LEFT JOIN grupos g ON g.id = i.grupo_id`

func escanear(row pgx.Row) (*Incidencia, error) {
	var i Incidencia
	var estado string
	err := row.Scan(&i.ID, &i.Numero, &i.PersonaID, &i.CasoID, &i.Tipo, &i.CategoriaID, &i.Categoria,
		&i.Impacto, &i.Urgencia, &i.Prioridad, &estado, &i.Titulo, &i.Resumen, &i.GrupoID, &i.Grupo, &i.TecnicoID,
		&i.Nivel, &i.Reaperturas, &i.Escalamientos, &i.Canal, &i.TokenPublico, &i.CreadaEn, &i.PrimeraRespuestaEn, &i.ResueltaEn,
		&i.CerradaEn, &i.VenceRespuestaEn, &i.VenceResolucionEn, &i.MotivoCierre, &i.ActualizadaEn)
	if err != nil {
		return nil, err
	}
	i.Estado = Estado(estado)
	i.CreadaEn, i.ActualizadaEn = i.CreadaEn.UTC(), i.ActualizadaEn.UTC()
	i.PrimeraRespuestaEn, i.ResueltaEn, i.CerradaEn = store.UTCPtr(i.PrimeraRespuestaEn), store.UTCPtr(i.ResueltaEn), store.UTCPtr(i.CerradaEn)
	i.VenceRespuestaEn, i.VenceResolucionEn = store.UTCPtr(i.VenceRespuestaEn), store.UTCPtr(i.VenceResolucionEn)
	return &i, nil
}

// cargar lee una incidencia; con bloquear=true toma FOR UPDATE de la fila.
func (o *Operaciones) cargar(ctx context.Context, id int64, bloquear bool) (*Incidencia, error) {
	sql := sqlSeleccionarIncidencia + ` WHERE i.id = $1`
	if bloquear {
		sql += ` FOR UPDATE OF i`
	}
	inc, err := escanear(o.tx.QueryRow(ctx, sql, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("incidencia %d: %w", id, ErrNoEncontrado)
	}
	if err != nil {
		return nil, fmt.Errorf("incidencia %d: %w", id, err)
	}
	return inc, nil
}

// Obtener lee una incidencia (sin bloquearla).
func (o *Operaciones) Obtener(ctx context.Context, id int64) (*Incidencia, error) {
	return o.cargar(ctx, id, false)
}

// ---- escritura común ----------------------------------------------------------------------------

// emitir inserta un evento. datos lleva solo códigos y valores de negocio; la foto del
// contexto (prioridad, categoría, grupo, técnico) se añade sola. Texto libre solo en las
// claves texto, valor, nota, solucion, comentario o detalle (no salen a ClickHouse salvo
// ANALITICA_TEXTO=1).
func (o *Operaciones) emitir(ctx context.Context, inc *Incidencia, actor Actor, tipo string, datos map[string]any) (int64, error) {
	d := make(map[string]any, len(datos)+1)
	for k, v := range datos {
		d[k] = v
	}
	d[analitica.ClaveContexto] = map[string]any{
		"prioridad": inc.Prioridad, "categoria": inc.Categoria, "grupo": inc.Grupo, "tecnico_id": inc.TecnicoID,
	}
	raw, err := json.Marshal(d)
	if err != nil {
		return 0, fmt.Errorf("evento %s: %w", tipo, err)
	}
	var actorID *string
	if actor.ID != "" {
		a := actor.ID
		actorID = &a
	}
	var id int64
	err = o.tx.QueryRow(ctx, `INSERT INTO incidencia_eventos (incidencia_id, ts, tipo, actor_tipo, actor_id, datos)
		VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`, inc.ID, o.ahora, tipo, actor.Tipo, actorID, raw).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("evento %s de %s: %w", tipo, inc.Numero, err)
	}
	o.pend = append(o.pend, analitica.EventoIncidencia{
		ID: id, IncidenciaID: inc.ID, Numero: inc.Numero, TS: o.ahora, Tipo: tipo, ActorTipo: actor.Tipo, ActorID: actorID, Datos: d,
	})
	return id, nil
}

// cambiarEstado fija el nuevo estado y, si cambió, deja el evento estado_cambiado.
func (o *Operaciones) cambiarEstado(ctx context.Context, inc *Incidencia, nuevo Estado, actor Actor, motivo string) error {
	if nuevo == inc.Estado {
		return nil
	}
	de := inc.Estado
	inc.Estado = nuevo
	_, err := o.emitir(ctx, inc, actor, EvEstadoCambiado, map[string]any{"de": string(de), "a": string(nuevo), "motivo": motivo})
	return err
}

// marca devuelve un instante estrictamente posterior a prev (a nivel de milisegundo), para
// que la versión (ms) de cada fila de incidencias_estado crezca siempre.
func marca(prev, ahora time.Time) time.Time {
	a, p := ahora.Truncate(time.Millisecond), prev.Truncate(time.Millisecond)
	if !a.After(p) {
		a = p.Add(time.Millisecond)
	}
	return a
}

func ptrHora(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	u := t.UTC()
	return &u
}

// finalizar recalcula los vencimientos desde los eventos, guarda la proyección y deja en el
// outbox los eventos pendientes y las filas de estado y tiempos. Cierra toda acción.
func (o *Operaciones) finalizar(ctx context.Context, inc *Incidencia) error {
	if inc.Estado.Abierta() {
		cs, err := o.s.cache.Contexto(ctx, o.tx, inc.Prioridad, inc.CategoriaID)
		if err != nil {
			return err
		}
		marcas, err := store.MarcasReloj(ctx, o.tx, []int64{inc.ID})
		if err != nil {
			return err
		}
		r := sla.Evaluar(sla.Entrada{
			Cal: cs.Cal, Pol: cs.Pol, Creada: inc.CreadaEn, PrimeraRespuesta: inc.PrimeraRespuestaEn,
			Pausas: sla.PausasDeEventos(marcas[inc.ID]), Ahora: o.ahora,
		})
		// La respuesta ya cumplida no se mueve; la resolución se recalcula tras pausas y cambios.
		if inc.PrimeraRespuestaEn == nil {
			inc.VenceRespuestaEn = ptrHora(r.VenceRespuesta)
		}
		inc.VenceResolucionEn = ptrHora(r.VenceResolucion)
	}
	inc.ActualizadaEn = marca(inc.ActualizadaEn, o.ahora)
	_, err := o.tx.Exec(ctx, `UPDATE incidencias SET tipo = $2, impacto = $3, urgencia = $4, prioridad = $5, estado = $6,
		resumen = $7, grupo_id = $8, tecnico_id = $9, nivel = $10, reaperturas = $11, escalamientos = $12,
		primera_respuesta_en = $13, resuelta_en = $14, cerrada_en = $15, vence_respuesta_en = $16,
		vence_resolucion_en = $17, motivo_cierre = $18, actualizada_en = $19 WHERE id = $1`,
		inc.ID, inc.Tipo, inc.Impacto, inc.Urgencia, inc.Prioridad, string(inc.Estado), inc.Resumen, inc.GrupoID, inc.TecnicoID,
		inc.Nivel, inc.Reaperturas, inc.Escalamientos, inc.PrimeraRespuestaEn, inc.ResueltaEn, inc.CerradaEn,
		inc.VenceRespuestaEn, inc.VenceResolucionEn, inc.MotivoCierre, inc.ActualizadaEn)
	if err != nil {
		return fmt.Errorf("guardar %s: %w", inc.Numero, err)
	}
	for _, ev := range o.pend {
		if err := analitica.EncolarEvento(ctx, o.tx, ev); err != nil {
			return err
		}
	}
	o.pend = nil
	// Se mide hasta actualizada_en: así Reconstruir (que no conoce el instante de la operación)
	// reproduce exactamente las mismas cifras.
	return analitica.EncolarIncidencia(ctx, o.tx, o.s.cache, inc.ID, inc.ActualizadaEn)
}

// DatosAviso arma los valores estándar de una plantilla de aviso para una incidencia:
// solo número, prioridad, categoría, estado, grupo, título y plazos; nunca notas internas.
func DatosAviso(inc *Incidencia) map[string]any {
	d := map[string]any{
		"numero": inc.Numero, "prioridad": inc.Prioridad, "categoria": inc.Categoria,
		"estado": string(inc.Estado), "grupo": inc.Grupo, "titulo": inc.Titulo,
	}
	if inc.VenceRespuestaEn != nil {
		d["vence_respuesta_en"] = inc.VenceRespuestaEn.UTC().Format(time.RFC3339)
	}
	if inc.VenceResolucionEn != nil {
		d["vence_resolucion_en"] = inc.VenceResolucionEn.UTC().Format(time.RFC3339)
	}
	return d
}

// avisarTecnico encola el aviso de «te asignaron una incidencia».
func (o *Operaciones) avisarAsignacion(ctx context.Context, inc *Incidencia, tecnicoID int, eventoID int64) error {
	incID := inc.ID
	tid := tecnicoID
	_, _, err := store.EncolarAviso(ctx, o.tx, store.NuevoAviso{
		IncidenciaID: &incID, DestinatarioTipo: store.DestTecnico, DestinatarioID: &tid,
		Canal: store.CanalTecnico(ctx, o.tx, tecnicoID), Plantilla: "incidencia_asignada",
		Datos: DatosAviso(inc), Clave: fmt.Sprintf("asig:%d:%d", inc.ID, eventoID),
	}, o.ahora)
	return err
}

// avisarSinAsignar encola el aviso al responsable del grupo: la incidencia quedó en la cola.
func (o *Operaciones) avisarSinAsignar(ctx context.Context, inc *Incidencia, eventoID int64) error {
	if inc.GrupoID == nil {
		return nil
	}
	var resp *int
	if err := o.tx.QueryRow(ctx, `SELECT responsable_tecnico_id FROM grupos WHERE id = $1`, *inc.GrupoID).Scan(&resp); err != nil {
		return fmt.Errorf("responsable del grupo %d: %w", *inc.GrupoID, err)
	}
	incID := inc.ID
	a := store.NuevoAviso{
		IncidenciaID: &incID, DestinatarioTipo: store.DestResponsableGrupo, DestinatarioID: resp,
		Canal: "whatsapp", Plantilla: "incidencia_sin_asignar", Datos: DatosAviso(inc),
		Clave: fmt.Sprintf("cola:%d:%d", inc.ID, eventoID),
	}
	if resp != nil {
		a.Canal = store.CanalTecnico(ctx, o.tx, *resp)
	}
	_, _, err := store.EncolarAviso(ctx, o.tx, a, o.ahora)
	return err
}

// textoLimpio recorta espacios y valida que no esté vacío.
func textoLimpio(campo, v string) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		return "", invalido("%s es obligatorio", campo)
	}
	return v, nil
}

// eventosLibres son los tipos de evento que se pueden registrar sin cambiar la proyección.
var eventosLibres = map[string]bool{EvAvisoSLA: true, EvComentarioInt: true}

// RegistrarEvento deja en el historial un evento que NO cambia la incidencia (un aviso del
// vigía, una nota del sistema): inserta la fila en incidencia_eventos y en el outbox
// (eventos_incidencia), sin tocar la proyección ni dejar filas de estado. Solo acepta los
// tipos «aviso_sla» y «comentario_interno». Devuelve el id del evento.
func (o *Operaciones) RegistrarEvento(ctx context.Context, id int64, actor Actor, tipo string, datos map[string]any) (int64, error) {
	if !eventosLibres[tipo] {
		return 0, invalido("el tipo de evento %q no se puede registrar suelto", tipo)
	}
	if err := actor.validar(); err != nil {
		return 0, err
	}
	inc, err := o.cargar(ctx, id, false)
	if err != nil {
		return 0, err
	}
	evID, err := o.emitir(ctx, inc, actor, tipo, datos)
	if err != nil {
		return 0, err
	}
	for _, ev := range o.pend {
		if err := analitica.EncolarEvento(ctx, o.tx, ev); err != nil {
			return 0, err
		}
	}
	o.pend = nil
	return evID, nil
}

// RegistrarSLAVencido deja el evento «sla_vencido» (una sola vez por incidencia y métrica) y
// vuelve a escribir las filas incidencias_estado e incidencias_tiempos, para que el veredicto
// «incumplida» (sla_respuesta_ok / sla_resolucion_ok = 0) llegue a ClickHouse aunque nadie
// toque la incidencia (una incidencia que nadie atiende no genera otros eventos). metrica es
// «respuesta» o «resolucion». Devuelve false si no aplica (ya cerrada, ya respondida, ya
// registrado). Lo llama el vigía; no depende de que ninguna regla de escalamiento esté activa.
func (o *Operaciones) RegistrarSLAVencido(ctx context.Context, id int64, metrica string) (bool, error) {
	if metrica != "respuesta" && metrica != "resolucion" {
		return false, invalido("métrica %q desconocida (use respuesta o resolucion)", metrica)
	}
	inc, err := o.cargar(ctx, id, true)
	if err != nil {
		return false, err
	}
	if !inc.Estado.Abierta() || (metrica == "respuesta" && inc.PrimeraRespuestaEn != nil) {
		return false, nil
	}
	var ya bool
	if err := o.tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM incidencia_eventos
		WHERE incidencia_id = $1 AND tipo = 'sla_vencido' AND datos->>'metrica' = $2)`, id, metrica).Scan(&ya); err != nil {
		return false, fmt.Errorf("sla_vencido de %s: %w", inc.Numero, err)
	}
	if ya {
		return false, nil
	}
	if _, err := o.emitir(ctx, inc, ActorSistema(), EvSLAVencido, map[string]any{"metrica": metrica}); err != nil {
		return false, err
	}
	return true, o.finalizar(ctx, inc)
}
