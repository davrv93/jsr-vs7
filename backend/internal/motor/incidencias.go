package motor

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/store"
)

// personaOut es la persona ya resuelta dentro de una incidencia.
type personaOut struct {
	ID             int     `json:"id"`
	Nombre         string  `json:"nombre"`
	WhatsApp       *string `json:"whatsapp"`
	Correo         *string `json:"correo"`
	VIP            bool    `json:"vip"`
	Sede           *string `json:"sede"`
	Area           *string `json:"area"`
	CanalPreferido string  `json:"canal_preferido"`
}

// incidenciaOut es una fila de incidencias más la persona y el técnico ya resueltos
// (categoria = clave, grupo = nombre, tecnico = nombre del técnico).
type incidenciaOut struct {
	*incidencia.Incidencia
	Persona *personaOut `json:"persona"`
	Tecnico *string     `json:"tecnico"`
}

// avisoOut es una fila de avisos.
type avisoOut struct {
	ID               int64          `json:"id"`
	IncidenciaID     *int64         `json:"incidencia_id"`
	DestinatarioTipo string         `json:"destinatario_tipo"`
	DestinatarioID   *int           `json:"destinatario_id"`
	Canal            string         `json:"canal"`
	Plantilla        string         `json:"plantilla"`
	Datos            map[string]any `json:"datos"`
	Intentos         int            `json:"intentos"`
	Error            *string        `json:"error"`
	CreadoEn         time.Time      `json:"creado_en"`
}

// enriquecer resuelve la persona y el técnico de una incidencia.
func enriquecer(ctx context.Context, q store.Q, inc *incidencia.Incidencia) (*incidenciaOut, error) {
	out := &incidenciaOut{Incidencia: inc}
	if inc.PersonaID != nil {
		var p personaOut
		err := q.QueryRow(ctx, `SELECT p.id, p.nombre, p.whatsapp, p.correo, p.vip, s.nombre, a.nombre, p.canal_preferido
			FROM personas p LEFT JOIN sedes s ON s.id = p.sede_id LEFT JOIN areas a ON a.id = p.area_id WHERE p.id = $1`, *inc.PersonaID).
			Scan(&p.ID, &p.Nombre, &p.WhatsApp, &p.Correo, &p.VIP, &p.Sede, &p.Area, &p.CanalPreferido)
		if err == nil {
			out.Persona = &p
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	if inc.TecnicoID != nil {
		var n string
		err := q.QueryRow(ctx, `SELECT nombre FROM tecnicos WHERE id = $1`, *inc.TecnicoID).Scan(&n)
		if err == nil {
			out.Tecnico = &n
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	return out, nil
}

// avisosNuevos devuelve los avisos encolados para la incidencia con id mayor que `desde`.
func avisosNuevos(ctx context.Context, q store.Q, incID, desde int64) ([]avisoOut, error) {
	rows, err := q.Query(ctx, `SELECT id, incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, intentos, error, creado_en
		FROM avisos WHERE incidencia_id = $1 AND id > $2 ORDER BY id`, incID, desde)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []avisoOut{}
	for rows.Next() {
		var a avisoOut
		if err := rows.Scan(&a.ID, &a.IncidenciaID, &a.DestinatarioTipo, &a.DestinatarioID, &a.Canal, &a.Plantilla, &a.Datos, &a.Intentos, &a.Error, &a.CreadoEn); err != nil {
			return nil, err
		}
		a.CreadoEn = a.CreadoEn.UTC()
		out = append(out, a)
	}
	return out, rows.Err()
}

func maxAviso(ctx context.Context, q store.Q) (int64, error) {
	var n int64
	err := q.QueryRow(ctx, `SELECT COALESCE(max(id), 0) FROM avisos`).Scan(&n)
	return n, err
}

// ---- POST /interno/incidencias ----------------------------------------------------------------------------

type crearIn struct {
	PersonaID *int              `json:"persona_id"`
	CasoID    *int64            `json:"caso_id"`
	Tipo      string            `json:"tipo"`
	Categoria string            `json:"categoria"`
	Impacto   string            `json:"impacto"`
	Urgencia  string            `json:"urgencia"`
	Titulo    string            `json:"titulo"`
	Resumen   string            `json:"resumen"`
	Canal     string            `json:"canal"`
	Motivo    string            `json:"motivo"`
	Queja     bool              `json:"queja"`
	Actor     *incidencia.Actor `json:"actor"`
}

func (s *Servidor) crear(w http.ResponseWriter, r *http.Request) {
	var in crearIn
	if err := leerJSON(r, &in); err != nil {
		responderError(w, err)
		return
	}
	if in.Actor == nil {
		responderError(w, parametro("falta el actor"))
		return
	}
	if in.PersonaID != nil && *in.PersonaID <= 0 {
		in.PersonaID = nil
	}
	if in.CasoID != nil && *in.CasoID <= 0 {
		in.CasoID = nil
	}
	var res *incidencia.Resultado
	var avisos []avisoOut
	var out *incidenciaOut
	err := s.cfg.Inc.EnTx(r.Context(), func(o *incidencia.Operaciones) error {
		antes, err := maxAviso(r.Context(), o.Tx())
		if err != nil {
			return err
		}
		res, err = o.Crear(r.Context(), incidencia.EntradaCrear{
			PersonaID: in.PersonaID, CasoID: in.CasoID, Tipo: in.Tipo, Categoria: in.Categoria, Impacto: in.Impacto, Urgencia: in.Urgencia,
			Titulo: in.Titulo, Resumen: in.Resumen, Canal: in.Canal, Actor: *in.Actor, Motivo: in.Motivo, Queja: in.Queja,
		})
		if err != nil {
			return err
		}
		if avisos, err = avisosNuevos(r.Context(), o.Tx(), res.Incidencia.ID, antes); err != nil {
			return err
		}
		out, err = enriquecer(r.Context(), o.Tx(), res.Incidencia)
		return err
	})
	if err != nil {
		responderError(w, err)
		return
	}
	escribirJSON(w, http.StatusOK, map[string]any{"incidencia": out, "asignacion": asignacionDe(res.Incidencia, res.Despacho), "avisos": avisos})
}

// ---- GET /interno/incidencias/duplicada y /resuelta -------------------------------------------------------------

func (s *Servidor) duplicada(w http.ResponseWriter, r *http.Request) {
	persona, categoria, err := personaYCategoria(r)
	if err != nil {
		responderError(w, err)
		return
	}
	inc, err := s.cfg.Inc.BuscarAbiertaDuplicada(r.Context(), persona, categoria)
	if err != nil {
		responderError(w, err)
		return
	}
	s.responderIncidenciaOpcional(w, r, inc)
}

// resuelta devuelve la incidencia 'resuelta' más reciente de la persona y categoría (para el
// «sigue igual»: se reabre en vez de abrir otra). ?desde=<ISO> acota (por defecto, 7 días).
func (s *Servidor) resuelta(w http.ResponseWriter, r *http.Request) {
	persona, categoria, err := personaYCategoria(r)
	if err != nil {
		responderError(w, err)
		return
	}
	desde := s.ahora().AddDate(0, 0, -7)
	if v := r.URL.Query().Get("desde"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			responderError(w, parametro("desde debe ser una fecha ISO 8601 (llegó %q)", v))
			return
		}
		desde = t
	}
	inc, err := s.cfg.Inc.BuscarResueltaReciente(r.Context(), persona, categoria, desde)
	if err != nil {
		responderError(w, err)
		return
	}
	s.responderIncidenciaOpcional(w, r, inc)
}

func personaYCategoria(r *http.Request) (int, string, error) {
	p, err := strconv.Atoi(r.URL.Query().Get("persona_id"))
	if err != nil || p <= 0 {
		return 0, "", parametro("persona_id debe ser un número positivo")
	}
	c := r.URL.Query().Get("categoria")
	if c == "" {
		return 0, "", parametro("falta la categoría")
	}
	return p, c, nil
}

func (s *Servidor) responderIncidenciaOpcional(w http.ResponseWriter, r *http.Request, inc *incidencia.Incidencia) {
	if inc == nil {
		escribirJSON(w, http.StatusOK, map[string]any{"incidencia": nil})
		return
	}
	out, err := enriquecer(r.Context(), s.cfg.DB, inc)
	if err != nil {
		responderError(w, err)
		return
	}
	escribirJSON(w, http.StatusOK, map[string]any{"incidencia": out})
}

// ---- POST /interno/incidencias/{id}/acciones ------------------------------------------------------------------------

type accionIn struct {
	Accion string            `json:"accion"`
	Actor  *incidencia.Actor `json:"actor"`
	// Campos según la acción.
	TecnicoID      *int   `json:"tecnico_id"`
	Texto          string `json:"texto"`
	EsperaUsuario  bool   `json:"espera_usuario"`
	Motivo         string `json:"motivo"`
	Nota           string `json:"nota"`
	Solucion       string `json:"solucion"`
	GrupoDestinoID *int   `json:"grupo_destino_id"`
	Prioridad      string `json:"prioridad"`
	Clave          string `json:"clave"`
	Valor          string `json:"valor"`
}

func (s *Servidor) accion(w http.ResponseWriter, r *http.Request) {
	id, err := idRuta(r, "id")
	if err != nil {
		responderError(w, err)
		return
	}
	var in accionIn
	if err := leerJSON(r, &in); err != nil {
		responderError(w, err)
		return
	}
	if in.Actor == nil {
		responderError(w, parametro("falta el actor"))
		return
	}
	actor := *in.Actor
	ctx := r.Context()

	var res *incidencia.Resultado
	var avisos []avisoOut
	var out *incidenciaOut
	err = s.cfg.Inc.EnTx(ctx, func(o *incidencia.Operaciones) error {
		res = nil
		antes, err := maxAviso(ctx, o.Tx())
		if err != nil {
			return err
		}
		var inc *incidencia.Incidencia
		switch in.Accion {
		case "asignar":
			if in.TecnicoID == nil {
				return parametro("asignar necesita tecnico_id")
			}
			inc, err = o.Asignar(ctx, id, incidencia.EntradaAsignar{TecnicoID: *in.TecnicoID, Motivo: in.Motivo, Actor: actor})
		case "responder":
			inc, err = o.Responder(ctx, id, incidencia.EntradaResponder{Texto: in.Texto, Actor: actor, EsperaUsuario: in.EsperaUsuario})
		case "comentar", "comentar_interno":
			inc, err = o.Comentar(ctx, id, incidencia.EntradaComentar{Texto: in.Texto, Interno: in.Accion == "comentar_interno", Actor: actor})
		case "pausar":
			inc, err = o.Pausar(ctx, id, incidencia.EntradaPausar{Motivo: in.Motivo, Nota: in.Nota, Actor: actor})
		case "reanudar":
			inc, err = o.Reanudar(ctx, id, incidencia.EntradaReanudar{Actor: actor})
		case "resolver":
			inc, err = o.Resolver(ctx, id, incidencia.EntradaResolver{Solucion: in.Solucion, Actor: actor})
		case "reabrir":
			inc, err = o.Reabrir(ctx, id, incidencia.EntradaReabrir{Motivo: in.Motivo, Actor: actor})
		case "cerrar":
			inc, err = o.Cerrar(ctx, id, incidencia.EntradaCerrar{Motivo: in.Motivo, Actor: actor})
		case "escalar":
			res, err = o.Escalar(ctx, id, incidencia.EntradaEscalar{GrupoDestinoID: in.GrupoDestinoID, Motivo: in.Motivo, Actor: actor})
			if err == nil {
				inc = res.Incidencia
			}
		case "cambiar_prioridad":
			inc, err = o.CambiarPrioridad(ctx, id, incidencia.EntradaCambiarPrioridad{Prioridad: in.Prioridad, Motivo: in.Motivo, Actor: actor})
		case "agregar_dato":
			inc, err = o.AgregarDato(ctx, id, incidencia.EntradaDato{Clave: in.Clave, Valor: in.Valor, Actor: actor})
		case "queja":
			inc, err = o.RegistrarQueja(ctx, id, incidencia.EntradaQueja{Texto: in.Texto, Actor: actor})
		default:
			return parametro("la acción %q no existe", in.Accion)
		}
		if err != nil {
			return err
		}
		if avisos, err = avisosNuevos(ctx, o.Tx(), inc.ID, antes); err != nil {
			return err
		}
		out, err = enriquecer(ctx, o.Tx(), inc)
		return err
	})
	if err != nil {
		responderError(w, err)
		return
	}
	resp := map[string]any{"incidencia": out, "avisos": avisos}
	if res != nil {
		resp["asignacion"] = asignacionDe(res.Incidencia, res.Despacho)
	}
	escribirJSON(w, http.StatusOK, resp)
}

// ---- POST /interno/sla/calcular ------------------------------------------------------------------------------------------

type slaOut struct {
	PorcentajeRespuesta  float64 `json:"porcentaje_respuesta"`
	PorcentajeResolucion float64 `json:"porcentaje_resolucion"`
	// RestanteMin son los minutos laborales que faltan del plazo que toca: el de respuesta si aún
	// no hubo primera respuesta; si no, el de resolución. Negativo si ya venció.
	RestanteMin           float64    `json:"restante_min"`
	Vencida               bool       `json:"vencida"`
	Pausada               bool       `json:"pausada"`
	Proximo               string     `json:"proximo"` // respuesta | resolucion
	RestanteRespuestaMin  float64    `json:"restante_respuesta_min"`
	RestanteResolucionMin float64    `json:"restante_resolucion_min"`
	VenceRespuestaEn      *time.Time `json:"vence_respuesta_en"`
	VenceResolucionEn     *time.Time `json:"vence_resolucion_en"`
}

func (s *Servidor) slaCalcular(w http.ResponseWriter, r *http.Request) {
	var in struct {
		IDs []int64 `json:"ids"`
	}
	if err := leerJSON(r, &in); err != nil {
		responderError(w, err)
		return
	}
	if len(in.IDs) > 1000 {
		responderError(w, parametro("como máximo 1000 ids por llamada (llegaron %d)", len(in.IDs)))
		return
	}
	mapa, err := s.cfg.Inc.SLALote(r.Context(), in.IDs)
	if err != nil {
		responderError(w, err)
		return
	}
	// El estado de cada incidencia decide cuál plazo es el «próximo».
	respondidas := map[int64]bool{}
	if len(mapa) > 0 {
		rows, err := s.cfg.DB.Query(r.Context(), `SELECT id FROM incidencias WHERE id = ANY($1) AND primera_respuesta_en IS NOT NULL`, in.IDs)
		if err != nil {
			responderError(w, err)
			return
		}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				responderError(w, err)
				return
			}
			respondidas[id] = true
		}
		rows.Close()
	}
	out := map[string]slaOut{}
	for id, e := range mapa {
		o := slaOut{
			PorcentajeRespuesta: round2(e.Respuesta.Porcentaje), PorcentajeResolucion: round2(e.Resolucion.Porcentaje),
			Vencida: e.Vencida, Pausada: e.Pausada, VenceRespuestaEn: e.VenceRespuestaEn, VenceResolucionEn: e.VenceResolucionEn,
			RestanteRespuestaMin: round2(e.Respuesta.RestanteMin), RestanteResolucionMin: round2(e.Resolucion.RestanteMin),
		}
		if respondidas[id] {
			o.Proximo, o.RestanteMin = "resolucion", o.RestanteResolucionMin
		} else {
			o.Proximo, o.RestanteMin = "respuesta", o.RestanteRespuestaMin
		}
		out[strconv.FormatInt(id, 10)] = o
	}
	escribirJSON(w, http.StatusOK, out)
}

func round2(f float64) float64 {
	if f < 0 {
		return -float64(int64(-f*100+0.5)) / 100
	}
	return float64(int64(f*100+0.5)) / 100
}

// ---- POST /interno/vigia/ejecutar ---------------------------------------------------------------------------------------------

func (s *Servidor) vigiaEjecutar(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Ahora string `json:"ahora"`
	}
	if err := cuerpoOpcional(r, &in); err != nil {
		responderError(w, err)
		return
	}
	ahora := s.ahora()
	if in.Ahora != "" {
		t, err := time.Parse(time.RFC3339, in.Ahora)
		if err != nil {
			responderError(w, parametro("ahora debe ser una fecha ISO 8601 (llegó %q)", in.Ahora))
			return
		}
		ahora = t.UTC()
	}
	inf, err := s.cfg.Vigia.Ciclo(r.Context(), ahora)
	if err != nil {
		responderError(w, err)
		return
	}
	if inf.Disparos == nil {
		inf.Disparos = []escala.Disparo{}
	}
	escribirJSON(w, http.StatusOK, inf)
}

// ---- avisos --------------------------------------------------------------------------------------------------------------------------

func (s *Servidor) avisosPendientes(w http.ResponseWriter, r *http.Request) {
	limite := 50
	if v := r.URL.Query().Get("limite"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 500 {
			responderError(w, parametro("limite debe estar entre 1 y 500"))
			return
		}
		limite = n
	}
	rows, err := s.cfg.DB.Query(r.Context(), `SELECT id, incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, intentos, error, creado_en
		FROM avisos WHERE enviado_en IS NULL ORDER BY id LIMIT $1`, limite)
	if err != nil {
		responderError(w, err)
		return
	}
	defer rows.Close()
	out := []avisoOut{}
	for rows.Next() {
		var a avisoOut
		if err := rows.Scan(&a.ID, &a.IncidenciaID, &a.DestinatarioTipo, &a.DestinatarioID, &a.Canal, &a.Plantilla, &a.Datos, &a.Intentos, &a.Error, &a.CreadoEn); err != nil {
			responderError(w, err)
			return
		}
		a.CreadoEn = a.CreadoEn.UTC()
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		responderError(w, err)
		return
	}
	escribirJSON(w, http.StatusOK, out)
}

func (s *Servidor) avisoMarcar(w http.ResponseWriter, r *http.Request) {
	id, err := idRuta(r, "id")
	if err != nil {
		responderError(w, err)
		return
	}
	var in struct {
		Enviado *bool  `json:"enviado"`
		Error   string `json:"error"`
	}
	if err := leerJSON(r, &in); err != nil {
		responderError(w, err)
		return
	}
	if in.Enviado == nil {
		responderError(w, parametro("falta «enviado» (true o false)"))
		return
	}
	if *in.Enviado {
		err = store.MarcarAvisoEnviado(r.Context(), s.cfg.DB, id, s.ahora())
	} else {
		msg := in.Error
		if msg == "" {
			msg = "sin detalle"
		}
		if len(msg) > 500 {
			msg = msg[:500]
		}
		err = store.MarcarAvisoError(r.Context(), s.cfg.DB, id, msg)
	}
	if err != nil {
		responderError(w, err)
		return
	}
	escribirJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
