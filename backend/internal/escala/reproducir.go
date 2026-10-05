package escala

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// historia es lo que Reproducir sabe de una incidencia: sus campos y sus eventos.
type historia struct {
	id               int64
	numero           string
	prioridad        string // la vigente
	categoriaID      *int
	creada           time.Time
	primeraRespuesta *time.Time
	marcas           []sla.MarcaReloj
	// instantes de los eventos que disparan reglas de evento.
	creadaDatos struct {
		prioridad string
		vip       bool
		motivo    string
	}
	prioridadA  []evPrioridad // prioridad_cambiada: instante y prioridad nueva
	reaperturas []time.Time
	quejas      []time.Time
}

type evPrioridad struct {
	ts time.Time
	a  string
}

// Reproducir repite las reglas vigentes sobre el historial de [desde, hasta] y devuelve QUÉ
// HABRÍAN HECHO, en orden cronológico, sin escribir nada y sin importar el modo de las reglas
// (es la prueba en sombra sobre datos históricos: PLAN F5). Usa las reglas de la base.
func (v *Vigia) Reproducir(ctx context.Context, desde, hasta time.Time) ([]Disparo, error) {
	reglas, err := ReglasVigentes(ctx, v.db)
	if err != nil {
		return nil, err
	}
	return v.ReproducirConReglas(ctx, desde, hasta, reglas)
}

// ReproducirConReglas es Reproducir con un conjunto de reglas dado (para probar una regla
// nueva o un umbral distinto contra el historial antes de publicarla).
//
// Para cada incidencia viva en la ventana calcula el INSTANTE en que cada regla se habría
// cumplido: para el SLA, cuando el reloj (con feriados y pausas) llega al umbral; para las
// reglas de evento, cuando ocurre el evento (creación, segunda reapertura, queja...). Lo
// incluye si ese instante cae en [desde, hasta] y la incidencia seguía abierta.
//
// Límite conocido: el plazo del SLA se toma con la prioridad VIGENTE de la incidencia, no con
// la que tenía en cada momento; si cambió de prioridad antes del umbral, puede diferir de lo
// que habría visto el vigía en vivo.
func (v *Vigia) ReproducirConReglas(ctx context.Context, desde, hasta time.Time, reglas []Regla) ([]Disparo, error) {
	desde, hasta = desde.UTC(), hasta.UTC()
	hs, err := v.cargarHistorias(ctx, desde, hasta)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(hs))
	for i, h := range hs {
		ids[i] = h.id
	}
	existentes, err := v.escalamientosDe(ctx, ids)
	if err != nil {
		return nil, err
	}
	cache := v.inc.Cache()

	var out []Disparo
	for _, h := range hs {
		for _, r := range reglas {
			cuando, detalle, ok, err := v.instante(ctx, cache, r, h)
			if err != nil {
				return nil, err
			}
			if !ok || cuando.Before(desde) || cuando.After(hasta) {
				continue
			}
			d := Disparo{IncidenciaID: h.id, Numero: h.numero, ReglaClave: r.Clave, ReglaVersion: r.Version, Modo: r.Modo,
				Cuando: cuando, Detalle: detalle, Acciones: []ResultadoAccion{}}
			for _, a := range r.Acciones {
				d.Acciones = append(d.Acciones, ResultadoAccion{Tipo: a.Tipo, Resultado: "plan"})
			}
			_, d.YaRegistrada = existentes[claveEsc{h.id, r.Clave, r.Version}]
			out = append(out, d)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if !out[i].Cuando.Equal(out[j].Cuando) {
			return out[i].Cuando.Before(out[j].Cuando)
		}
		if out[i].IncidenciaID != out[j].IncidenciaID {
			return out[i].IncidenciaID < out[j].IncidenciaID
		}
		return out[i].ReglaClave < out[j].ReglaClave
	})
	return out, nil
}

// instante calcula cuándo se cumpliría la regla para la incidencia (ok=false si nunca).
func (v *Vigia) instante(ctx context.Context, cache *store.CacheSLA, r Regla, h historia) (time.Time, map[string]any, bool, error) {
	c := r.Condicion
	switch c.Tipo {
	case CondSLA:
		cs, err := cache.Contexto(ctx, v.db, h.prioridad, h.categoriaID)
		if err != nil {
			return time.Time{}, nil, false, err
		}
		limite := cs.Pol.ResolucionMin
		if c.Metrica == "respuesta" {
			limite = cs.Pol.RespuestaMin
		}
		if limite <= 0 {
			return time.Time{}, nil, false, nil
		}
		dur := time.Duration(float64(limite) * c.UmbralPct / 100 * float64(time.Minute))
		t, err := sla.FechaVencimientoDur(cs.Cal, h.creada, dur, sla.PausasDeEventos(h.marcas))
		if err != nil {
			// Nunca alcanza el umbral: la incidencia quedó resuelta (pausa abierta) o el calendario no alcanza.
			return time.Time{}, nil, false, nil
		}
		if c.Metrica == "respuesta" && h.primeraRespuesta != nil && !t.Before(*h.primeraRespuesta) {
			return time.Time{}, nil, false, nil
		}
		return t, map[string]any{"metrica": c.Metrica, "umbral_pct": c.UmbralPct}, true, nil
	case CondPrioridad:
		if h.creadaDatos.prioridad == c.Valor {
			return h.creada, map[string]any{"prioridad": c.Valor}, true, nil
		}
		for _, p := range h.prioridadA {
			if p.a == c.Valor {
				return p.ts, map[string]any{"prioridad": c.Valor}, true, nil
			}
		}
	case CondReaperturas:
		if len(h.reaperturas) >= c.Min {
			return h.reaperturas[c.Min-1], map[string]any{"reaperturas": c.Min}, true, nil
		}
	case CondQueja:
		if len(h.quejas) > 0 {
			return h.quejas[0], map[string]any{}, true, nil
		}
	case CondVIP:
		if h.creadaDatos.vip {
			return h.creada, map[string]any{}, true, nil
		}
	case CondGuiaAgotada:
		if h.creadaDatos.motivo == "guia_agotada" {
			return h.creada, map[string]any{}, true, nil
		}
	}
	return time.Time{}, nil, false, nil
}

// cargarHistorias lee las incidencias vivas en la ventana (creadas hasta `hasta` y no cerradas
// antes de `desde`) con sus eventos relevantes.
func (v *Vigia) cargarHistorias(ctx context.Context, desde, hasta time.Time) ([]historia, error) {
	rows, err := v.db.Query(ctx, `SELECT id, numero, prioridad, categoria_id, creada_en, primera_respuesta_en
		FROM incidencias WHERE creada_en <= $2 AND (cerrada_en IS NULL OR cerrada_en >= $1) ORDER BY id`, desde, hasta)
	if err != nil {
		return nil, fmt.Errorf("escala: leer historial: %w", err)
	}
	var hs []historia
	for rows.Next() {
		var h historia
		if err := rows.Scan(&h.id, &h.numero, &h.prioridad, &h.categoriaID, &h.creada, &h.primeraRespuesta); err != nil {
			rows.Close()
			return nil, err
		}
		h.creada = h.creada.UTC()
		h.primeraRespuesta = store.UTCPtr(h.primeraRespuesta)
		hs = append(hs, h)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(hs) == 0 {
		return nil, nil
	}
	ids := make([]int64, len(hs))
	idx := map[int64]int{}
	for i, h := range hs {
		ids[i] = h.id
		idx[h.id] = i
	}
	erows, err := v.db.Query(ctx, `SELECT incidencia_id, ts, tipo, datos FROM incidencia_eventos
		WHERE incidencia_id = ANY($1)
		  AND tipo IN ('creada','queja','reabierta','prioridad_cambiada','pausa_inicio','pausa_fin','resuelta')
		ORDER BY incidencia_id, ts, id`, ids)
	if err != nil {
		return nil, fmt.Errorf("escala: leer eventos del historial: %w", err)
	}
	defer erows.Close()
	for erows.Next() {
		var id int64
		var ts time.Time
		var tipo string
		var raw []byte
		if err := erows.Scan(&id, &ts, &tipo, &raw); err != nil {
			return nil, err
		}
		ts = ts.UTC()
		h := &hs[idx[id]]
		switch tipo {
		case "creada":
			var d struct {
				Prioridad string `json:"prioridad"`
				VIP       bool   `json:"vip"`
				Motivo    string `json:"motivo"`
			}
			_ = json.Unmarshal(raw, &d)
			h.creadaDatos.prioridad, h.creadaDatos.vip, h.creadaDatos.motivo = d.Prioridad, d.VIP, d.Motivo
		case "queja":
			h.quejas = append(h.quejas, ts)
		case "reabierta":
			h.reaperturas = append(h.reaperturas, ts)
			h.marcas = append(h.marcas, sla.MarcaReloj{TS: ts, Tipo: tipo})
		case "prioridad_cambiada":
			var d struct {
				A string `json:"a"`
			}
			_ = json.Unmarshal(raw, &d)
			h.prioridadA = append(h.prioridadA, evPrioridad{ts, d.A})
		default: // pausa_inicio, pausa_fin, resuelta
			h.marcas = append(h.marcas, sla.MarcaReloj{TS: ts, Tipo: tipo})
		}
	}
	return hs, erows.Err()
}
