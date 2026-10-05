// Package sla calcula la prioridad (matriz impacto x urgencia) y el reloj de SLA en
// horario laboral. Es un paquete PURO: no toca la base ni el reloj del sistema, así que
// todo se prueba con tablas.
//
// Reglas (ARQUITECTURA §3.1):
//   - los plazos se cuentan en minutos LABORALES de un calendario (zona, tramos por día
//     de la semana y feriados); un calendario 24x7 cuenta cada minuto;
//   - las pausas (espera_usuario, espera_tercero) detienen el reloj;
//   - el reloj se calcula desde los eventos, nunca guardando un contador: las funciones de
//     aquí reciben instantes e intervalos y devuelven cifras.
package sla

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
	// La base de zonas horarias va dentro del binario: la imagen distroless/alpine puede no
	// traer /usr/share/zoneinfo y el reloj de SLA necesita America/Lima.
	_ "time/tzdata"
)

// Tramo es un tramo laboral del día en minutos desde la medianoche LOCAL del calendario.
// Hasta puede valer 1440 (24:00).
type Tramo struct {
	Desde int
	Hasta int
}

// Calendario define cuándo corre el reloj de SLA.
type Calendario struct {
	Nombre string
	// Zona horaria del calendario (America/Lima). Los tramos y los feriados se leen en ella.
	Zona *time.Location
	// VeinticuatroSiete: cada minuto cuenta; ignora tramos y feriados.
	VeinticuatroSiete bool
	// Horario[d] son los tramos del día d (1 = lunes ... 7 = domingo).
	Horario [8][]Tramo

	feriados map[string]string // "2006-01-02" (fecha local) -> nombre
}

// horizonteDias limita la búsqueda hacia delante de FechaVencimiento: un calendario sin
// ningún tramo laboral nunca cumple un plazo y no debe colgar al llamador.
const horizonteDias = 1500

// ErrSinHorario se devuelve cuando el calendario no tiene tiempo laboral suficiente en el
// horizonte (calendario vacío, o una pausa abierta que nunca termina).
var ErrSinHorario = errors.New("sla: el calendario no tiene tiempo laboral suficiente para cumplir el plazo")

// NuevoCalendario arma un calendario. zona es un nombre IANA ("America/Lima"); horario es
// el JSON de la tabla calendarios: {"1":[["08:30","13:00"],["14:00","18:00"]],...,"7":[]}.
func NuevoCalendario(nombre, zona string, veinticuatroSiete bool, horario []byte) (*Calendario, error) {
	if zona == "" {
		zona = "America/Lima"
	}
	loc, err := time.LoadLocation(zona)
	if err != nil {
		return nil, fmt.Errorf("sla: zona horaria %q: %w", zona, err)
	}
	c := &Calendario{Nombre: nombre, Zona: loc, VeinticuatroSiete: veinticuatroSiete, feriados: map[string]string{}}
	if len(horario) > 0 {
		h, err := ParsearHorario(horario)
		if err != nil {
			return nil, err
		}
		c.Horario = h
	}
	return c, nil
}

// ParsearHorario lee el JSON de horario ({"1":[["08:30","13:00"],...]}) y valida los tramos:
// desde < hasta, ordenados y sin solaparse.
func ParsearHorario(raw []byte) ([8][]Tramo, error) {
	var h [8][]Tramo
	var m map[string][][]string
	if err := json.Unmarshal(raw, &m); err != nil {
		return h, fmt.Errorf("sla: horario no es un JSON válido: %w", err)
	}
	for k, tramos := range m {
		d, err := strconv.Atoi(k)
		if err != nil || d < 1 || d > 7 {
			return h, fmt.Errorf("sla: día de la semana %q inválido (1 = lunes ... 7 = domingo)", k)
		}
		var out []Tramo
		for _, par := range tramos {
			if len(par) != 2 {
				return h, fmt.Errorf("sla: el tramo del día %d debe ser [desde, hasta]", d)
			}
			ini, err := ParsearHora(par[0])
			if err != nil {
				return h, err
			}
			fin, err := ParsearHora(par[1])
			if err != nil {
				return h, err
			}
			if fin <= ini {
				return h, fmt.Errorf("sla: tramo %s-%s del día %d: hasta debe ser mayor que desde", par[0], par[1], d)
			}
			out = append(out, Tramo{ini, fin})
		}
		sort.Slice(out, func(i, j int) bool { return out[i].Desde < out[j].Desde })
		for i := 1; i < len(out); i++ {
			if out[i].Desde < out[i-1].Hasta {
				return h, fmt.Errorf("sla: los tramos del día %d se solapan", d)
			}
		}
		h[d] = out
	}
	return h, nil
}

// ParsearHora convierte "08:30" (o "24:00") en minutos desde la medianoche.
func ParsearHora(s string) (int, error) {
	s = strings.TrimSpace(s)
	partes := strings.Split(s, ":")
	if len(partes) < 2 || len(partes) > 3 {
		return 0, fmt.Errorf("sla: hora %q inválida (use HH:MM)", s)
	}
	h, err1 := strconv.Atoi(partes[0])
	m, err2 := strconv.Atoi(partes[1])
	if err1 != nil || err2 != nil || h < 0 || h > 24 || m < 0 || m > 59 || (h == 24 && m != 0) {
		return 0, fmt.Errorf("sla: hora %q inválida (use HH:MM)", s)
	}
	return h*60 + m, nil
}

// AgregarFeriado marca un día (fecha local del calendario, "2006-01-02") como no laborable.
func (c *Calendario) AgregarFeriado(fecha, nombre string) error {
	if _, err := time.Parse("2006-01-02", fecha); err != nil {
		return fmt.Errorf("sla: feriado %q inválido (use AAAA-MM-DD): %w", fecha, err)
	}
	if c.feriados == nil {
		c.feriados = map[string]string{}
	}
	c.feriados[fecha] = nombre
	return nil
}

// Feriados devuelve una copia de los feriados (fecha -> nombre).
func (c *Calendario) Feriados() map[string]string {
	out := make(map[string]string, len(c.feriados))
	for k, v := range c.feriados {
		out[k] = v
	}
	return out
}

func claveFecha(y int, m time.Month, d int) string {
	return fmt.Sprintf("%04d-%02d-%02d", y, int(m), d)
}

// EsFeriado dice si el día LOCAL de t es feriado del calendario.
func (c *Calendario) EsFeriado(t time.Time) bool {
	y, m, d := t.In(c.Zona).Date()
	_, ok := c.feriados[claveFecha(y, m, d)]
	return ok
}

// EsLaboral dice si en el instante t el calendario cuenta tiempo.
func (c *Calendario) EsLaboral(t time.Time) bool {
	if c.VeinticuatroSiete {
		return true
	}
	if c.EsFeriado(t) {
		return false
	}
	l := t.In(c.Zona)
	min := l.Hour()*60 + l.Minute()
	for _, tr := range c.Horario[isoDia(l.Weekday())] {
		if min >= tr.Desde && min < tr.Hasta {
			return true
		}
	}
	return false
}

// isoDia convierte time.Weekday (domingo = 0) a ISO (lunes = 1 ... domingo = 7).
func isoDia(w time.Weekday) int {
	if w == time.Sunday {
		return 7
	}
	return int(w)
}

type segmento struct{ ini, fin time.Time }

// segmentos recorre, en orden cronológico, los tramos laborales que caen dentro de
// [desde, hasta) y llama a f con cada uno (ya recortado). f devuelve false para parar.
func (c *Calendario) segmentos(desde, hasta time.Time, f func(a, b time.Time) bool) {
	if !hasta.After(desde) {
		return
	}
	loc := c.Zona
	y0, m0, d0 := desde.In(loc).Date()
	for i := 0; ; i++ {
		// El mediodía siempre existe: normaliza la fecha aunque el día tenga un salto de horario.
		ref := time.Date(y0, m0, d0+i, 12, 0, 0, 0, loc)
		y, m, d := ref.Date()
		inicioDia := time.Date(y, m, d, 0, 0, 0, 0, loc)
		if !inicioDia.Before(hasta) {
			return
		}
		finDia := time.Date(y, m, d+1, 0, 0, 0, 0, loc)
		var tramos []segmento
		if c.VeinticuatroSiete {
			tramos = []segmento{{inicioDia, finDia}}
		} else if _, feriado := c.feriados[claveFecha(y, m, d)]; !feriado {
			for _, tr := range c.Horario[isoDia(ref.Weekday())] {
				ini := time.Date(y, m, d, 0, tr.Desde, 0, 0, loc)
				var fin time.Time
				if tr.Hasta >= 1440 {
					fin = finDia
				} else {
					fin = time.Date(y, m, d, 0, tr.Hasta, 0, 0, loc)
				}
				tramos = append(tramos, segmento{ini, fin})
			}
		}
		for _, s := range tramos {
			a, b := s.ini, s.fin
			if a.Before(desde) {
				a = desde
			}
			if b.After(hasta) {
				b = hasta
			}
			if b.After(a) && !f(a, b) {
				return
			}
		}
	}
}

// Laboral devuelve la duración laboral (sin descontar pausas) entre dos instantes.
func (c *Calendario) Laboral(desde, hasta time.Time) time.Duration {
	var total time.Duration
	c.segmentos(desde, hasta, func(a, b time.Time) bool {
		total += b.Sub(a)
		return true
	})
	return total
}

// ProximoLaboral devuelve el primer instante >= t en que el calendario cuenta tiempo.
func (c *Calendario) ProximoLaboral(t time.Time) (time.Time, error) {
	var out time.Time
	c.segmentos(t, t.AddDate(0, 0, horizonteDias), func(a, _ time.Time) bool {
		out = a
		return false
	})
	if out.IsZero() {
		return out, ErrSinHorario
	}
	return out, nil
}

// MinutosLaborales devuelve los minutos laborales entre dos instantes, sin descontar
// pausas. Si hasta <= desde devuelve 0.
func MinutosLaborales(c *Calendario, desde, hasta time.Time) float64 {
	return c.Laboral(desde, hasta).Minutes()
}
