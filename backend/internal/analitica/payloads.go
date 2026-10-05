package analitica

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// ClaveContexto es la clave de incidencia_eventos.datos donde incidencia guarda la foto de
// {prioridad, categoria, grupo, tecnico_id} en el momento del evento. Así eventos_incidencia
// se puede reconstruir tal como se emitió, sin adivinar el estado de entonces.
const ClaveContexto = "contexto"

// textoPermitido dice si el texto libre puede salir hacia ClickHouse (ANALITICA_TEXTO=1).
// Por defecto NO sale: ni comentarios, ni valores de datos, ni mensajes (AGENTS §4).
func textoPermitido() bool { return os.Getenv("ANALITICA_TEXTO") == "1" }

// ---- eventos --------------------------------------------------------------------------------

// EventoIncidencia es una fila de incidencia_eventos más el número de la incidencia.
type EventoIncidencia struct {
	ID           int64
	IncidenciaID int64
	Numero       string
	TS           time.Time
	Tipo         string
	ActorTipo    string
	ActorID      *string
	Datos        map[string]any
}

type contextoEvento struct {
	Prioridad string `json:"prioridad"`
	Categoria string `json:"categoria"`
	Grupo     string `json:"grupo"`
	TecnicoID *int   `json:"tecnico_id"`
}

// claves de datos con texto libre: salen vacías salvo ANALITICA_TEXTO=1.
var clavesTexto = map[string]bool{"texto": true, "comentario": true, "valor": true, "solucion": true, "nota": true, "detalle": true}

// PayloadEvento arma el payload de eventos_incidencia.
func PayloadEvento(e EventoIncidencia) map[string]any {
	var ctxEv contextoEvento
	if raw, ok := e.Datos[ClaveContexto]; ok {
		b, _ := json.Marshal(raw)
		_ = json.Unmarshal(b, &ctxEv)
	}
	datos := map[string]any{}
	permitir := textoPermitido()
	for k, v := range e.Datos {
		if k == ClaveContexto {
			continue
		}
		if clavesTexto[k] && !permitir {
			continue
		}
		datos[k] = v
	}
	rawDatos, _ := json.Marshal(datos)
	actorID := "" // la columna actor_id de ClickHouse es String, no Nullable
	if e.ActorID != nil {
		actorID = *e.ActorID
	}
	return map[string]any{
		"id":            e.ID,
		"incidencia_id": e.IncidenciaID,
		"numero":        e.Numero,
		"ts":            fmtTS(e.TS),
		"tipo":          e.Tipo,
		"actor_tipo":    e.ActorTipo,
		"actor_id":      actorID,
		"prioridad":     ctxEv.Prioridad,
		"categoria":     ctxEv.Categoria,
		"grupo":         ctxEv.Grupo,
		"tecnico_id":    ctxEv.TecnicoID,
		"datos":         string(rawDatos),
	}
}

// EncolarEvento deja en el outbox el evento recién insertado (clave "ev-<id>").
func EncolarEvento(ctx context.Context, q store.Q, e EventoIncidencia) error {
	return Encolar(ctx, q, TablaEventos, fmt.Sprintf("ev-%d", e.ID), PayloadEvento(e))
}

// ---- estado y tiempos de la incidencia -----------------------------------------------------------

// EstadoIncidencia es la foto completa de una incidencia: lo necesario para armar las filas
// de incidencias_estado e incidencias_tiempos.
type EstadoIncidencia struct {
	IncidenciaID       int64
	Numero             string
	PersonaID          *int
	Tipo               string
	Categoria          string // clave de la categoría
	Impacto, Urgencia  string
	Prioridad, Estado  string
	Grupo              string // nombre del grupo
	Nivel              string
	TecnicoID          *int
	Canal              string
	Sede, Area         string // nombres, de la persona
	CreadaEn           time.Time
	PrimeraRespuestaEn *time.Time
	ResueltaEn         *time.Time
	CerradaEn          *time.Time
	Reaperturas        int
	Escalamientos      int
	ActualizadaEn      time.Time
	CasoID             *int64  // caso de origen (opcional en incidencias_estado)
	MotivoCierre       *string // confirmado | sin_confirmacion

	// Para incidencias_tiempos.
	Reasignaciones int
	Cal            *sla.Calendario
	Pol            sla.Politica
	Marcas         []sla.MarcaReloj
	// Ahora cierra las pausas abiertas y decide si un plazo sin cumplir ya venció.
	Ahora time.Time
}

// PayloadEstado arma el payload de incidencias_estado.
func PayloadEstado(e EstadoIncidencia) map[string]any {
	return map[string]any{
		"incidencia_id":        e.IncidenciaID,
		"version":              Version(e.ActualizadaEn),
		"numero":               e.Numero,
		"persona_id":           e.PersonaID,
		"tipo":                 e.Tipo,
		"categoria":            e.Categoria,
		"impacto":              e.Impacto,
		"urgencia":             e.Urgencia,
		"prioridad":            e.Prioridad,
		"estado":               e.Estado,
		"grupo":                e.Grupo,
		"nivel":                e.Nivel,
		"tecnico_id":           e.TecnicoID,
		"canal":                e.Canal,
		"sede":                 e.Sede,
		"area":                 e.Area,
		"creada_en":            fmtTS(e.CreadaEn),
		"primera_respuesta_en": fmtTSPtr(e.PrimeraRespuestaEn),
		"resuelta_en":          fmtTSPtr(e.ResueltaEn),
		"cerrada_en":           fmtTSPtr(e.CerradaEn),
		"reaperturas":          e.Reaperturas,
		"escalamientos":        e.Escalamientos,
		// Opcional (CONTRATOS «Cambios» 5): el esquema actual de ClickHouse aún no tiene esta
		// columna y el trabajador manda input_format_skip_unknown_fields=1.
		"caso_id": e.CasoID,
	}
}

// PayloadTiempos arma el payload de incidencias_tiempos con los minutos LABORALES netos de
// pausas que calcula internal/sla. NULL donde el hito aún no ocurrió.
func PayloadTiempos(e EstadoIncidencia) map[string]any {
	r := sla.Evaluar(sla.Entrada{
		Cal: e.Cal, Pol: e.Pol, Creada: e.CreadaEn,
		PrimeraRespuesta: e.PrimeraRespuestaEn, Resuelta: e.ResueltaEn,
		Pausas: sla.PausasDeEventos(e.Marcas), Ahora: e.Ahora,
	})
	// primer_contacto: NULL si no está resuelta o si se cerró «sin confirmación» (no cuenta para el FCR).
	var primerContacto any
	sinConfirmar := e.MotivoCierre != nil && *e.MotivoCierre == "sin_confirmacion"
	if e.ResueltaEn != nil && !sinConfirmar {
		if e.Reaperturas == 0 && e.Escalamientos == 0 && e.Reasignaciones == 0 {
			primerContacto = 1
		} else {
			primerContacto = 0
		}
	}
	return map[string]any{
		"incidencia_id":     e.IncidenciaID,
		"version":           Version(e.ActualizadaEn),
		"prioridad":         e.Prioridad,
		"categoria":         e.Categoria,
		"grupo":             e.Grupo,
		"tecnico_id":        e.TecnicoID,
		"creada_en":         fmtTS(e.CreadaEn),
		"resuelta_en":       fmtTSPtr(e.ResueltaEn),
		"cerrada_en":        fmtTSPtr(e.CerradaEn),
		"frt_min":           minutos(r.FRTMin),
		"mttr_min":          minutos(r.MTTRMin),
		"pausa_min":         int64(r.PausaMin + 0.5),
		"sla_respuesta_ok":  boolInt(r.RespuestaOK),
		"sla_resolucion_ok": boolInt(r.ResolucionOK),
		"primer_contacto":   primerContacto,
	}
}

// EncolarEstado deja en el outbox las filas incidencias_estado ("inc-<id>-<version>") e
// incidencias_tiempos ("tie-<id>-<version>") de una foto de la incidencia.
func EncolarEstado(ctx context.Context, q store.Q, e EstadoIncidencia) error {
	v := Version(e.ActualizadaEn)
	if err := Encolar(ctx, q, TablaEstado, fmt.Sprintf("inc-%d-%d", e.IncidenciaID, v), PayloadEstado(e)); err != nil {
		return err
	}
	return Encolar(ctx, q, TablaTiempos, fmt.Sprintf("tie-%d-%d", e.IncidenciaID, v), PayloadTiempos(e))
}

// CargarEstado lee de la base la foto completa de una incidencia (con su calendario, sus
// plazos y las marcas del reloj). cache puede ser nil. ahora es el instante de evaluación;
// si es cero se usa actualizada_en (así una reconstrucción repite lo emitido).
func CargarEstado(ctx context.Context, q store.Q, cache *store.CacheSLA, id int64, ahora time.Time) (*EstadoIncidencia, error) {
	if cache == nil {
		cache = store.NuevoCacheSLA(time.Second)
	}
	e := &EstadoIncidencia{}
	var catID *int
	err := q.QueryRow(ctx, `SELECT i.id, i.numero, i.persona_id, i.tipo, COALESCE(c.clave, ''), i.categoria_id,
			i.impacto, i.urgencia, i.prioridad, i.estado, COALESCE(g.nombre, ''), i.nivel, i.tecnico_id, i.canal,
			COALESCE(s.nombre, ''), COALESCE(a.nombre, ''),
			i.creada_en, i.primera_respuesta_en, i.resuelta_en, i.cerrada_en, i.reaperturas, i.escalamientos, i.actualizada_en,
			(SELECT count(*) FROM incidencia_eventos ev WHERE ev.incidencia_id = i.id AND ev.tipo = 'reasignada'),
			i.caso_id, i.motivo_cierre
		FROM incidencias i
		LEFT JOIN categorias c ON c.id = i.categoria_id
		LEFT JOIN grupos g ON g.id = i.grupo_id
		LEFT JOIN personas p ON p.id = i.persona_id
		LEFT JOIN sedes s ON s.id = p.sede_id
		LEFT JOIN areas a ON a.id = p.area_id
		WHERE i.id = $1`, id).Scan(&e.IncidenciaID, &e.Numero, &e.PersonaID, &e.Tipo, &e.Categoria, &catID,
		&e.Impacto, &e.Urgencia, &e.Prioridad, &e.Estado, &e.Grupo, &e.Nivel, &e.TecnicoID, &e.Canal,
		&e.Sede, &e.Area,
		&e.CreadaEn, &e.PrimeraRespuestaEn, &e.ResueltaEn, &e.CerradaEn, &e.Reaperturas, &e.Escalamientos, &e.ActualizadaEn,
		&e.Reasignaciones, &e.CasoID, &e.MotivoCierre)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("analitica: incidencia %d: %w", id, store.ErrNoEncontrado)
	}
	if err != nil {
		return nil, fmt.Errorf("analitica: incidencia %d: %w", id, err)
	}
	e.CreadaEn, e.ActualizadaEn = e.CreadaEn.UTC(), e.ActualizadaEn.UTC()
	e.PrimeraRespuestaEn, e.ResueltaEn, e.CerradaEn = store.UTCPtr(e.PrimeraRespuestaEn), store.UTCPtr(e.ResueltaEn), store.UTCPtr(e.CerradaEn)

	cs, err := cache.Contexto(ctx, q, e.Prioridad, catID)
	if err != nil {
		return nil, err
	}
	e.Cal, e.Pol = cs.Cal, cs.Pol
	marcas, err := store.MarcasReloj(ctx, q, []int64{id})
	if err != nil {
		return nil, err
	}
	e.Marcas = marcas[id]
	e.Ahora = ahora
	if e.Ahora.IsZero() {
		e.Ahora = e.ActualizadaEn
	}
	return e, nil
}

// EncolarIncidencia carga la incidencia y deja en el outbox su estado y sus tiempos.
// Es lo que llama internal/incidencia tras cada cambio, con la misma transacción.
func EncolarIncidencia(ctx context.Context, q store.Q, cache *store.CacheSLA, id int64, ahora time.Time) error {
	e, err := CargarEstado(ctx, q, cache, id, ahora)
	if err != nil {
		return err
	}
	return EncolarEstado(ctx, q, *e)
}

// ---- casos, mensajes, encuestas y feedback ---------------------------------------------------------

// EncolarCaso deja en el outbox casos_estado (clave "caso-<id>-<version>", versión = lo último
// que movió al caso, en ms: su último mensaje o el último cambio de una incidencia suya; quien
// cambie el estado de un caso sin mensaje nuevo debe actualizar casos.ultimo_mensaje para que la
// versión crezca). confirmado_resuelto = 1 cuando el caso terminó como 'resuelto_asistente'.
//
// SUPUESTO: resuelto_asistente implica que la persona confirmó (el asistente solo cierra así
// tras la confirmación; ARQUITECTURA §2.1).
func EncolarCaso(ctx context.Context, q store.Q, casoID int64) error {
	var (
		canal, estado     string
		personaID         *int
		inicio, ultimoMsg time.Time
		version           time.Time
		tiene             bool
	)
	err := q.QueryRow(ctx, `SELECT c.canal, c.persona_id, c.estado, c.inicio, c.ultimo_mensaje,
			GREATEST(c.ultimo_mensaje, COALESCE((SELECT max(i.actualizada_en) FROM incidencias i WHERE i.caso_id = c.id), c.ultimo_mensaje)),
			EXISTS (SELECT 1 FROM incidencias i WHERE i.caso_id = c.id)
		FROM casos c WHERE c.id = $1`, casoID).Scan(&canal, &personaID, &estado, &inicio, &ultimoMsg, &version, &tiene)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("analitica: caso %d: %w", casoID, store.ErrNoEncontrado)
	}
	if err != nil {
		return fmt.Errorf("analitica: caso %d: %w", casoID, err)
	}
	return Encolar(ctx, q, TablaCasos, fmt.Sprintf("caso-%d-%d", casoID, Version(version)),
		PayloadCaso(casoID, version, canal, personaID, estado, inicio, ultimoMsg, tiene))
}

// PayloadCaso arma el payload de casos_estado.
func PayloadCaso(id int64, version time.Time, canal string, personaID *int, estado string, inicio, ultimoMensaje time.Time, tieneIncidencia bool) map[string]any {
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	return map[string]any{
		"caso_id":             id,
		"version":             Version(version),
		"canal":               canal,
		"persona_id":          personaID,
		"estado":              estado,
		"inicio":              fmtTS(inicio),
		"ultimo_mensaje":      fmtTS(ultimoMensaje),
		"tiene_incidencia":    b(tieneIncidencia),
		"confirmado_resuelto": b(estado == "resuelto_asistente"),
	}
}

// EncolarMensaje deja en el outbox la fila mensajes de un mensaje (clave "msg-<id>"). Las
// columnas de análisis salen de mensajes.meta; el texto sale vacío salvo ANALITICA_TEXTO=1.
func EncolarMensaje(ctx context.Context, q store.Q, mensajeID int64) error {
	var (
		casoID    int64
		ts        time.Time
		rol, text string
		meta      []byte
		canal     string
	)
	err := q.QueryRow(ctx, `SELECT m.caso_id, m.ts, m.rol, m.texto, m.meta, c.canal
		FROM mensajes m JOIN casos c ON c.id = m.caso_id WHERE m.id = $1`, mensajeID).
		Scan(&casoID, &ts, &rol, &text, &meta, &canal)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("analitica: mensaje %d: %w", mensajeID, store.ErrNoEncontrado)
	}
	if err != nil {
		return fmt.Errorf("analitica: mensaje %d: %w", mensajeID, err)
	}
	return Encolar(ctx, q, TablaMensajes, fmt.Sprintf("msg-%d", mensajeID), PayloadMensaje(mensajeID, casoID, ts, rol, canal, text, meta))
}

// PayloadMensaje arma el payload de mensajes tolerando metadatos ausentes.
func PayloadMensaje(id, casoID int64, ts time.Time, rol, canal, texto string, meta []byte) map[string]any {
	m := map[string]any{}
	_ = json.Unmarshal(meta, &m)
	str := func(claves ...string) string {
		for _, k := range claves {
			if v, ok := m[k].(string); ok {
				return v
			}
		}
		return ""
	}
	num := func(k string) any {
		if v, ok := m[k].(float64); ok {
			return v
		}
		return nil
	}
	costo := 0.0 // la columna costo_usd de ClickHouse es Float64, no Nullable
	if v, ok := m["costo_usd"].(float64); ok {
		costo = v
	}
	juezModo, juezVeredicto := str("juez_modo"), ""
	if j, ok := m["juez"].(map[string]any); ok {
		if juezModo == "" {
			if s, ok := j["modo"].(string); ok {
				juezModo = s
			}
		}
		if v, ok := j["veredictos"]; ok {
			b, _ := json.Marshal(v)
			juezVeredicto = string(b)
		} else if v, ok := j["veredicto"]; ok {
			b, _ := json.Marshal(v)
			juezVeredicto = string(b)
		}
	}
	if juezVeredicto == "" {
		juezVeredicto = str("juez_veredicto")
	}
	regenerada := 0
	if v, ok := m["regenerada"].(bool); ok && v {
		regenerada = 1
	}
	frases := 0
	if v, ok := m["frases_quitadas"].(float64); ok {
		frases = int(v)
	}
	if !textoPermitido() {
		texto = ""
	}
	return map[string]any{
		"id": id, "caso_id": casoID, "ts": fmtTS(ts), "rol": rol, "canal": canal,
		"intencion": str("intencion"), "confianza": num("confianza"), "categoria": str("categoria"),
		"juez_modo": juezModo, "juez_veredicto": juezVeredicto,
		"latencia_ms": num("latencia_ms"), "regenerada": regenerada, "frases_quitadas": frases,
		"costo_usd": costo, "texto": texto,
	}
}

// EncolarEncuesta deja en el outbox la fila de una encuesta (clave "enc-<id>").
func EncolarEncuesta(ctx context.Context, q store.Q, encuestaID int64) error {
	var inc, caso *int64
	var ts time.Time
	var puntaje *int
	err := q.QueryRow(ctx, `SELECT incidencia_id, caso_id, ts, puntaje FROM encuestas WHERE id = $1`, encuestaID).
		Scan(&inc, &caso, &ts, &puntaje)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("analitica: encuesta %d: %w", encuestaID, store.ErrNoEncontrado)
	}
	if err != nil {
		return fmt.Errorf("analitica: encuesta %d: %w", encuestaID, err)
	}
	return Encolar(ctx, q, TablaEncuestas, fmt.Sprintf("enc-%d", encuestaID), map[string]any{
		"id": encuestaID, "incidencia_id": inc, "caso_id": caso, "ts": fmtTS(ts), "puntaje": puntaje,
	})
}

// EncolarFeedback deja en el outbox la fila de una señal de feedback (clave "fb-<id>"), con el
// mensaje al que se refiere (mensaje_id; CONTRATOS «Cambios» 5).
func EncolarFeedback(ctx context.Context, q store.Q, feedbackID int64) error {
	var caso, inc, mensaje *int64
	var ts time.Time
	var senal string
	var valor *string
	err := q.QueryRow(ctx, `SELECT caso_id, incidencia_id, mensaje_id, ts, senal, valor FROM feedback WHERE id = $1`, feedbackID).
		Scan(&caso, &inc, &mensaje, &ts, &senal, &valor)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("analitica: feedback %d: %w", feedbackID, store.ErrNoEncontrado)
	}
	if err != nil {
		return fmt.Errorf("analitica: feedback %d: %w", feedbackID, err)
	}
	v := ""
	if valor != nil && textoPermitido() {
		v = *valor
	} else if valor != nil && !strings.ContainsAny(*valor, " \t\n") && len(*valor) <= 32 {
		v = *valor // valores cortos y sin espacios (p. ej. el id de un artículo) no son texto libre
	}
	return Encolar(ctx, q, TablaFeedback, fmt.Sprintf("fb-%d", feedbackID), map[string]any{
		"id": feedbackID, "caso_id": caso, "incidencia_id": inc, "mensaje_id": mensaje, "ts": fmtTS(ts), "senal": senal, "valor": v,
	})
}
