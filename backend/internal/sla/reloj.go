package sla

import (
	"sort"
	"time"
)

// Intervalo es un tramo de tiempo en que el reloj está detenido (pausa). Hasta en cero
// significa «sigue abierta».
type Intervalo struct {
	Desde time.Time
	Hasta time.Time
}

// Abierto dice si el intervalo sigue corriendo.
func (i Intervalo) Abierto() bool { return i.Hasta.IsZero() }

// CerrarAbiertas devuelve una copia donde los intervalos abiertos terminan en `ahora`.
func CerrarAbiertas(pausas []Intervalo, ahora time.Time) []Intervalo {
	out := make([]Intervalo, len(pausas))
	for i, p := range pausas {
		if p.Abierto() {
			p.Hasta = ahora
		}
		out[i] = p
	}
	return out
}

// normalizar recorta las pausas a [desde, hasta], descarta las vacías y une las que se
// solapan. Una pausa abierta se extiende hasta `hasta`.
func normalizar(pausas []Intervalo, desde, hasta time.Time) []Intervalo {
	var xs []Intervalo
	for _, p := range pausas {
		a, b := p.Desde, p.Hasta
		if p.Abierto() {
			b = hasta
		}
		if a.Before(desde) {
			a = desde
		}
		if b.After(hasta) {
			b = hasta
		}
		if b.After(a) {
			xs = append(xs, Intervalo{a, b})
		}
	}
	sort.Slice(xs, func(i, j int) bool { return xs[i].Desde.Before(xs[j].Desde) })
	var out []Intervalo
	for _, x := range xs {
		if n := len(out); n > 0 && !x.Desde.After(out[n-1].Hasta) {
			if x.Hasta.After(out[n-1].Hasta) {
				out[n-1].Hasta = x.Hasta
			}
			continue
		}
		out = append(out, x)
	}
	return out
}

// DuracionNeta devuelve el tiempo laboral entre desde y hasta DESCONTANDO las pausas.
// Las pausas abiertas se toman hasta `hasta`.
func DuracionNeta(c *Calendario, desde, hasta time.Time, pausas []Intervalo) time.Duration {
	total := c.Laboral(desde, hasta)
	for _, p := range normalizar(pausas, desde, hasta) {
		total -= c.Laboral(p.Desde, p.Hasta)
	}
	if total < 0 {
		total = 0
	}
	return total
}

// MinutosNetos es DuracionNeta en minutos.
func MinutosNetos(c *Calendario, desde, hasta time.Time, pausas []Intervalo) float64 {
	return DuracionNeta(c, desde, hasta, pausas).Minutes()
}

// restar devuelve [a, b) menos las pausas (ya normalizadas y ordenadas).
func restar(a, b time.Time, pausas []Intervalo) []segmento {
	out := []segmento{}
	cursor := a
	for _, p := range pausas {
		if !p.Hasta.After(cursor) {
			continue
		}
		if !p.Desde.Before(b) {
			break
		}
		if p.Desde.After(cursor) {
			out = append(out, segmento{cursor, p.Desde})
		}
		cursor = p.Hasta
		if !cursor.Before(b) {
			return out
		}
	}
	if b.After(cursor) {
		out = append(out, segmento{cursor, b})
	}
	return out
}

// FechaVencimiento devuelve el instante en que se cumplen `minutos` minutos laborales
// contados desde `desde`, sin contar las pausas. Si el plazo termina justo al cierre de un
// tramo, devuelve ese cierre (18:00), no el inicio del siguiente día.
//
// Una pausa abierta se toma como que nunca termina: úsese CerrarAbiertas antes si se quiere
// «el vencimiento si se reanudara ahora».
func FechaVencimiento(c *Calendario, desde time.Time, minutos int, pausas []Intervalo) (time.Time, error) {
	return FechaVencimientoDur(c, desde, time.Duration(minutos)*time.Minute, pausas)
}

// FechaVencimientoDur es FechaVencimiento con una duración exacta (precisión de segundos).
func FechaVencimientoDur(c *Calendario, desde time.Time, dur time.Duration, pausas []Intervalo) (time.Time, error) {
	if dur <= 0 {
		return desde, nil
	}
	limite := desde.AddDate(0, 0, horizonteDias)
	ps := normalizar(pausas, desde, limite)
	restante := dur
	var res time.Time
	c.segmentos(desde, limite, func(a, b time.Time) bool {
		for _, s := range restar(a, b, ps) {
			largo := s.fin.Sub(s.ini)
			if largo >= restante {
				res = s.ini.Add(restante)
				return false
			}
			restante -= largo
		}
		return true
	})
	if res.IsZero() {
		return time.Time{}, ErrSinHorario
	}
	return res, nil
}

// Estado es la foto de un plazo de SLA en un instante.
type Estado struct {
	LimiteMin       float64 `json:"limite_min"`
	TranscurridoMin float64 `json:"transcurrido_min"`
	RestanteMin     float64 `json:"restante_min"` // negativo si ya venció
	Porcentaje      float64 `json:"porcentaje"`   // 0..100+ del plazo consumido
	Vencida         bool    `json:"vencida"`
}

// EstadoSLA mide cuánto del plazo se consumió entre `desde` y `corte` (el momento en que se
// cumplió el hito, o «ahora» si sigue pendiente), en minutos laborales netos de pausas.
// Vencida = se pasó del límite (cumplir justo en el límite no es vencer).
func EstadoSLA(c *Calendario, desde, corte time.Time, limiteMin int, pausas []Intervalo) Estado {
	t := MinutosNetos(c, desde, corte, pausas)
	e := Estado{LimiteMin: float64(limiteMin), TranscurridoMin: t, RestanteMin: float64(limiteMin) - t}
	if limiteMin > 0 {
		e.Porcentaje = t / float64(limiteMin) * 100
	}
	e.Vencida = t > float64(limiteMin)
	return e
}

// MarcaReloj es un evento de la incidencia que afecta al reloj.
type MarcaReloj struct {
	TS   time.Time
	Tipo string // pausa_inicio, pausa_fin, resuelta, reabierta (los demás se ignoran)
}

// PausasDeEventos reconstruye los intervalos en que el reloj estuvo detenido a partir de
// los eventos (en orden cronológico):
//   - pausa_inicio ... pausa_fin   (espera_usuario / espera_tercero);
//   - resuelta ... reabierta       (mientras espera la confirmación no corre el SLA; si se
//     reabre, ese tiempo no cuenta).
//
// Los intervalos que no se cerraron quedan abiertos (Hasta en cero).
func PausasDeEventos(marcas []MarcaReloj) []Intervalo {
	ms := append([]MarcaReloj(nil), marcas...)
	sort.SliceStable(ms, func(i, j int) bool { return ms[i].TS.Before(ms[j].TS) })
	var out []Intervalo
	abiertaPausa, abiertaResuelta := -1, -1
	for _, m := range ms {
		switch m.Tipo {
		case "pausa_inicio":
			if abiertaPausa < 0 {
				out = append(out, Intervalo{Desde: m.TS})
				abiertaPausa = len(out) - 1
			}
		case "pausa_fin":
			if abiertaPausa >= 0 {
				out[abiertaPausa].Hasta = m.TS
				abiertaPausa = -1
			}
		case "resuelta":
			if abiertaResuelta < 0 {
				out = append(out, Intervalo{Desde: m.TS})
				abiertaResuelta = len(out) - 1
			}
		case "reabierta":
			if abiertaResuelta >= 0 {
				out[abiertaResuelta].Hasta = m.TS
				abiertaResuelta = -1
			}
		}
	}
	return out
}

// Politica son los plazos de una prioridad (en minutos laborales del calendario).
type Politica struct {
	RespuestaMin  int
	ResolucionMin int
}

// Entrada de Evaluar: todo lo que hace falta para medir una incidencia.
type Entrada struct {
	Cal              *Calendario
	Pol              Politica
	Creada           time.Time
	PrimeraRespuesta *time.Time
	Resuelta         *time.Time
	Pausas           []Intervalo // las abiertas se cierran en Ahora
	Ahora            time.Time
}

// Resultado de Evaluar.
type Resultado struct {
	// Respuesta y Resolucion miden el plazo hasta el hito (o hasta ahora si sigue pendiente).
	Respuesta  Estado
	Resolucion Estado

	// Vencimientos con el plazo completo y las pausas conocidas (las abiertas, hasta Ahora).
	// Cero si el calendario no alcanza.
	VenceRespuesta  time.Time
	VenceResolucion time.Time

	// Tiempos laborales netos (nil si el hito aún no ocurrió).
	FRTMin  *float64
	MTTRMin *float64
	// PausaMin: minutos laborales detenidos entre la creación y el cierre de la medición.
	PausaMin float64

	// Cumplimiento: nil si todavía no aplica (ni se cumplió ni venció).
	RespuestaOK  *bool
	ResolucionOK *bool
}

func ptrB(b bool) *bool       { return &b }
func ptrF(f float64) *float64 { return &f }

// Evaluar mide una incidencia con su calendario, su política y sus pausas.
func Evaluar(e Entrada) Resultado {
	pausas := CerrarAbiertas(e.Pausas, e.Ahora)
	var r Resultado

	corteResp := e.Ahora
	if e.PrimeraRespuesta != nil {
		corteResp = *e.PrimeraRespuesta
	}
	r.Respuesta = EstadoSLA(e.Cal, e.Creada, corteResp, e.Pol.RespuestaMin, pausas)
	if e.PrimeraRespuesta != nil {
		r.FRTMin = ptrF(r.Respuesta.TranscurridoMin)
		r.RespuestaOK = ptrB(!r.Respuesta.Vencida)
	} else if r.Respuesta.Vencida {
		r.RespuestaOK = ptrB(false)
	}

	corteRes := e.Ahora
	if e.Resuelta != nil {
		corteRes = *e.Resuelta
	}
	r.Resolucion = EstadoSLA(e.Cal, e.Creada, corteRes, e.Pol.ResolucionMin, pausas)
	if e.Resuelta != nil {
		r.MTTRMin = ptrF(r.Resolucion.TranscurridoMin)
		r.ResolucionOK = ptrB(!r.Resolucion.Vencida)
	} else if r.Resolucion.Vencida {
		r.ResolucionOK = ptrB(false)
	}

	// Pausa laboral acumulada hasta el cierre de la medición.
	fin := corteRes
	r.PausaMin = (e.Cal.Laboral(e.Creada, fin) - DuracionNeta(e.Cal, e.Creada, fin, pausas)).Minutes()

	if v, err := FechaVencimiento(e.Cal, e.Creada, e.Pol.RespuestaMin, pausas); err == nil {
		r.VenceRespuesta = v
	}
	if v, err := FechaVencimiento(e.Cal, e.Creada, e.Pol.ResolucionMin, pausas); err == nil {
		r.VenceResolucion = v
	}
	return r
}
