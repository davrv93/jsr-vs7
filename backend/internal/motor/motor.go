// Package motor expone el dominio de jsrbot (incidencias, eventos, SLA, despacho, escalamiento,
// avisos, outbox hacia ClickHouse y golden queries) como una API HTTP INTERNA, solo para la red
// del compose: la consume la pasarela OCaml (docs/CONTRATOS.md §5). Aquí no hay API de consola,
// ni autenticación de personas, ni webhook, ni flujo de caso: eso es de la pasarela.
//
// Todas las rutas viven bajo /interno/, hablan JSON y exigen la cabecera X-Interno-Clave con el
// valor de MOTOR_CLAVE. Los errores son {"error": "texto en español", "codigo": "..."} con
// 400/401/404/409/422 (500 si algo falla de verdad; el detalle va al log, nunca al cliente).
package motor

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/despacho"
	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/golden"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/store"
)

// Config del servidor.
type Config struct {
	DB *store.DB
	// Clave es MOTOR_CLAVE. Vacía = el servidor rechaza todo (no existe un modo sin clave).
	Clave   string
	Version string

	Inc       *incidencia.Servicio
	Vigia     *escala.Vigia
	Analitica *analitica.Trabajador // puede ser nil si no hay ClickHouse
	Golden    *golden.Golden        // puede ser nil
	// EsquemaCH es el contenido de analitica/esquema.sql (para reiniciar el destino).
	EsquemaCH string
	// ClickHouseConfigurado indica si hay ClickHouse al que mandar el outbox.
	ClickHouseConfigurado bool
	// Reloj inyectable (pruebas); por defecto la hora del sistema.
	Reloj func() time.Time
}

// Servidor es el manejador HTTP del motor.
type Servidor struct {
	cfg Config
	mux *http.ServeMux
}

// Nuevo arma el servidor.
func Nuevo(cfg Config) *Servidor {
	if cfg.Reloj == nil {
		cfg.Reloj = func() time.Time { return time.Now().UTC() }
	}
	if cfg.Version == "" {
		cfg.Version = "dev"
	}
	s := &Servidor{cfg: cfg, mux: http.NewServeMux()}
	r := s.mux.HandleFunc
	r("GET /interno/salud", s.salud)
	r("POST /interno/incidencias", s.crear)
	r("GET /interno/incidencias/duplicada", s.duplicada)
	r("GET /interno/incidencias/resuelta", s.resuelta)
	r("POST /interno/incidencias/{id}/acciones", s.accion)
	r("POST /interno/sla/calcular", s.slaCalcular)
	r("POST /interno/vigia/ejecutar", s.vigiaEjecutar)
	r("POST /interno/despacho/simular", s.despachoSimular)
	r("GET /interno/avisos/pendientes", s.avisosPendientes)
	r("POST /interno/avisos/{id}/marcar", s.avisoMarcar)
	r("GET /interno/golden", s.goldenCatalogo)
	r("GET /interno/golden/{kpi}", s.goldenEjecutar)
	r("POST /interno/analitica/vaciar", s.analiticaVaciar)
	r("POST /interno/analitica/reconstruir", s.analiticaReconstruir)
	s.mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		escribirError(w, http.StatusNotFound, "no_encontrado", "Esa ruta no existe en el motor.")
	})
	return s
}

// Handler devuelve el http.Handler con la autenticación por clave.
func (s *Servidor) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("X-Interno-Clave")
		if s.cfg.Clave == "" || got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(s.cfg.Clave)) != 1 {
			escribirError(w, http.StatusUnauthorized, "no_autorizado", "Clave interna inválida o ausente.")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		s.mux.ServeHTTP(w, r)
	})
}

// ---- utilidades de respuesta ---------------------------------------------------------------------------

func escribirJSON(w http.ResponseWriter, estado int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(estado)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("motor: escribir la respuesta: %v", err)
	}
}

func escribirError(w http.ResponseWriter, estado int, codigo, msg string) {
	escribirJSON(w, estado, map[string]string{"error": msg, "codigo": codigo})
}

// responderError traduce un error del dominio a la respuesta HTTP. Lo inesperado es 500 con un
// mensaje genérico; el detalle va al log.
func responderError(w http.ResponseWriter, err error) {
	var sinJSON *json.SyntaxError
	var tipoJSON *json.UnmarshalTypeError
	var grande *http.MaxBytesError
	switch {
	case errors.Is(err, errCuerpo) || errors.As(err, &sinJSON) || errors.As(err, &tipoJSON) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF):
		escribirError(w, http.StatusBadRequest, "invalido", "El cuerpo de la petición no es un JSON válido.")
	case errors.As(err, &grande):
		escribirError(w, http.StatusBadRequest, "invalido", "El cuerpo de la petición es demasiado grande.")
	case errors.Is(err, errParametro):
		escribirError(w, http.StatusUnprocessableEntity, "invalido", mensajeLimpio(err))
	case errors.Is(err, incidencia.ErrNoEncontrado), errors.Is(err, golden.ErrNoEncontrado), errors.Is(err, golden.ErrSinCatalogo):
		escribirError(w, http.StatusNotFound, "no_encontrado", mensajeLimpio(err))
	case errors.Is(err, incidencia.ErrTransicionInvalida), errors.Is(err, incidencia.ErrSinNivelSuperior), errors.Is(err, analitica.ErrSinDestino), errors.Is(err, golden.ErrSinClickHouse):
		escribirError(w, http.StatusConflict, "conflicto", mensajeLimpio(err))
	case errors.Is(err, incidencia.ErrInvalido), errors.Is(err, golden.ErrInvalido):
		escribirError(w, http.StatusUnprocessableEntity, "invalido", mensajeLimpio(err))
	default:
		log.Printf("motor: error interno: %v", err)
		escribirError(w, http.StatusInternalServerError, "interno", "El motor no pudo completar la operación.")
	}
}

// mensajeLimpio quita el prefijo técnico «datos inválidos: » para mostrar solo el motivo.
func mensajeLimpio(err error) string {
	m := err.Error()
	m = strings.TrimPrefix(m, incidencia.ErrInvalido.Error()+": ")
	if m == "" {
		return "Petición inválida."
	}
	return strings.ToUpper(m[:1]) + m[1:]
}

var (
	errCuerpo    = errors.New("cuerpo inválido")
	errParametro = errors.New("parámetro inválido")
)

func parametro(formato string, a ...any) error {
	return fmt.Errorf("%w: %s", errParametro, fmt.Sprintf(formato, a...))
}

// leerJSON decodifica el cuerpo en dst (campos desconocidos se ignoran: el cliente puede evolucionar).
func leerJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dst); err != nil {
		if errors.Is(err, io.EOF) {
			return errCuerpo
		}
		return err
	}
	return nil
}

// cuerpoOpcional es como leerJSON pero acepta un cuerpo vacío.
func cuerpoOpcional(r *http.Request, dst any) error {
	b, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}
	if len(strings.TrimSpace(string(b))) == 0 {
		return nil
	}
	return json.Unmarshal(b, dst)
}

func idRuta(r *http.Request, nombre string) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue(nombre), 10, 64)
	if err != nil || id <= 0 {
		return 0, parametro("el id %q no es un número válido", r.PathValue(nombre))
	}
	return id, nil
}

func (s *Servidor) ahora() time.Time { return s.cfg.Reloj().UTC() }

// ---- GET /interno/salud ---------------------------------------------------------------------------------

func (s *Servidor) salud(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	out := map[string]any{"ok": true, "db": "ok", "clickhouse": "sin_configurar", "version": s.cfg.Version}
	estado := http.StatusOK
	if err := s.cfg.DB.Ping(ctx); err != nil {
		out["ok"], out["db"] = false, "error"
		estado = http.StatusServiceUnavailable
	}
	if s.cfg.ClickHouseConfigurado && s.cfg.Analitica != nil {
		// ClickHouse no es fuente de verdad: si cae, el motor sigue sirviendo y el outbox se acumula.
		if err := s.cfg.Analitica.Ping(ctx); err != nil {
			out["clickhouse"] = "error"
		} else {
			out["clickhouse"] = "ok"
		}
	}
	var pend int
	if err := s.cfg.DB.QueryRow(ctx, `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&pend); err == nil {
		out["outbox_pendiente"] = pend
	}
	escribirJSON(w, estado, out)
}

// ---- GET/POST sobre analítica ---------------------------------------------------------------------------

func (s *Servidor) analiticaVaciar(w http.ResponseWriter, r *http.Request) {
	if s.cfg.Analitica == nil {
		responderError(w, analitica.ErrSinDestino)
		return
	}
	res, err := s.cfg.Analitica.Vaciar(r.Context())
	if err != nil {
		if errors.Is(err, analitica.ErrSinDestino) {
			responderError(w, err)
			return
		}
		// ClickHouse caído: no se perdió nada (siguen pendientes). 502 para que el cliente reintente.
		log.Printf("motor: vaciar el outbox: %v", err)
		escribirError(w, http.StatusBadGateway, "no_disponible", "ClickHouse no respondió; el outbox sigue pendiente y se reintentará.")
		return
	}
	escribirJSON(w, http.StatusOK, map[string]any{"enviadas": res.Total, "por_tabla": res.Enviadas})
}

// analiticaReconstruir re-encola todo desde Postgres y, si hay ClickHouse, lo manda. Con
// ?reiniciar_destino=1 antes borra la base de ClickHouse y reaplica el esquema (analitica/reconstruir.md).
func (s *Servidor) analiticaReconstruir(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("reiniciar_destino") == "1" {
		if s.cfg.Analitica == nil {
			responderError(w, analitica.ErrSinDestino)
			return
		}
		if s.cfg.EsquemaCH == "" {
			escribirError(w, http.StatusConflict, "conflicto", "No hay esquema de ClickHouse (analitica/esquema.sql) para reaplicar.")
			return
		}
		if err := s.cfg.Analitica.ReiniciarDestino(r.Context(), s.cfg.EsquemaCH); err != nil {
			log.Printf("motor: reiniciar el destino: %v", err)
			escribirError(w, http.StatusBadGateway, "no_disponible", "No se pudo reiniciar ClickHouse.")
			return
		}
	}
	conteo, err := analitica.Reconstruir(r.Context(), s.cfg.DB)
	if err != nil {
		responderError(w, err)
		return
	}
	out := map[string]any{"encoladas": conteo, "enviadas": 0}
	if s.cfg.Analitica != nil && s.cfg.ClickHouseConfigurado {
		res, err := s.cfg.Analitica.Vaciar(r.Context())
		out["enviadas"] = res.Total
		if err != nil {
			log.Printf("motor: enviar tras reconstruir: %v", err)
			out["aviso"] = "El outbox se reconstruyó pero ClickHouse no respondió; el trabajador lo enviará cuando vuelva."
		}
	} else {
		out["aviso"] = "ClickHouse no está configurado: el outbox quedó reconstruido y pendiente."
	}
	escribirJSON(w, http.StatusOK, out)
}

// ---- golden --------------------------------------------------------------------------------------------

func (s *Servidor) goldenCatalogo(w http.ResponseWriter, r *http.Request) {
	if s.cfg.Golden == nil {
		responderError(w, golden.ErrSinCatalogo)
		return
	}
	cat, err := s.cfg.Golden.CatalogoConSQL(r.Context())
	if err != nil {
		responderError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(cat)
}

func (s *Servidor) goldenEjecutar(w http.ResponseWriter, r *http.Request) {
	if s.cfg.Golden == nil {
		responderError(w, golden.ErrSinCatalogo)
		return
	}
	q := r.URL.Query()
	res, err := s.cfg.Golden.Ejecutar(r.Context(), r.PathValue("kpi"), golden.Params{Desde: q.Get("desde"), Hasta: q.Get("hasta"), Grupo: q.Get("grupo")})
	if err != nil {
		if !errors.Is(err, golden.ErrNoEncontrado) && !errors.Is(err, golden.ErrInvalido) && !errors.Is(err, golden.ErrSinClickHouse) && !errors.Is(err, golden.ErrSinCatalogo) {
			log.Printf("motor: golden %s: %v", r.PathValue("kpi"), err)
			escribirError(w, http.StatusBadGateway, "no_disponible", "No se pudo ejecutar la golden query (ClickHouse no respondió o rechazó la consulta).")
			return
		}
		responderError(w, err)
		return
	}
	escribirJSON(w, http.StatusOK, res)
}

// ---- despacho -----------------------------------------------------------------------------------------

func (s *Servidor) despachoSimular(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Categoria string `json:"categoria"`
		Prioridad string `json:"prioridad"`
	}
	if err := leerJSON(r, &in); err != nil {
		responderError(w, err)
		return
	}
	if in.Categoria == "" {
		responderError(w, parametro("falta la categoría"))
		return
	}
	if in.Prioridad == "" {
		in.Prioridad = "P3"
	}
	sim, err := s.cfg.Inc.SimularDespacho(r.Context(), in.Categoria, in.Prioridad)
	if err != nil {
		responderError(w, err)
		return
	}
	var tecnicoNombre *string
	if sim.Decision.TecnicoID != nil {
		var n string
		if err := s.cfg.DB.QueryRow(r.Context(), `SELECT nombre FROM tecnicos WHERE id = $1`, *sim.Decision.TecnicoID).Scan(&n); err == nil {
			tecnicoNombre = &n
		}
	}
	escribirJSON(w, http.StatusOK, map[string]any{
		"grupo_id": sim.GrupoID, "grupo": sim.Grupo, "tecnico_id": sim.Decision.TecnicoID, "tecnico": tecnicoNombre,
		"motivo": sim.Decision.Motivo, "en_cola": sim.Decision.Cola, "por_guardia": sim.Decision.PorGuardia,
		"explicacion": sim.Decision.Explicacion, "decision": sim.Decision,
	})
}

// asignacionDe arma el objeto «asignacion» de las respuestas.
func asignacionDe(inc *incidencia.Incidencia, d *despacho.Decision) map[string]any {
	a := map[string]any{"tecnico_id": inc.TecnicoID, "grupo_id": inc.GrupoID, "motivo": "", "en_cola": inc.TecnicoID == nil}
	if d != nil {
		a["motivo"], a["en_cola"], a["por_guardia"], a["explicacion"] = d.Motivo, d.Cola, d.PorGuardia, d.Explicacion
	}
	return a
}
