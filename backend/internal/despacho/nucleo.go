// Package despacho es el despachador de ARQUITECTURA §3.2: elige técnico o cola para cada
// incidencia con reglas configurables. «Los modelos proponen; el código decide»: aquí no hay
// ningún modelo.
//
// Tiene dos capas:
//   - el núcleo PURO (Decidir): recibe candidatos ya cargados y devuelve una decisión con el
//     motivo; se prueba con tablas;
//   - la capa de base (Elegir): lee turnos, ausencias, habilidades, carga y guardias de
//     Postgres, bloquea a los técnicos involucrados y llama al núcleo.
//
// Regla: no se asigna a nadie fuera de turno, salvo P1 con guardia vigente (AGENTS §3.3).
package despacho

import (
	"fmt"
	"sort"
	"time"
)

// Motivos de la decisión (códigos estables; Explicacion lleva el texto en español).
const (
	MotivoUnico      = "unico_candidato"
	MotivoMenorCarga = "menor_carga"
	MotivoDesempate  = "desempate_ultima_asignacion"
	MotivoGuardia    = "guardia_p1"
	MotivoCola       = "cola_sin_candidatos"
)

// Razones por las que un técnico queda descartado.
const (
	RazonInactivo     = "inactivo"
	RazonAusente      = "ausente"
	RazonSinHabilidad = "sin_habilidad"
	RazonFueraDeTurno = "fuera_de_turno"
	RazonSinCapacidad = "sin_capacidad"
)

// Candidato es un técnico con todo lo que el despachador necesita saber de él.
type Candidato struct {
	TecnicoID int
	Nombre    string
	// Estado es tecnicos.estado: activo, ausente o inactivo.
	Estado string
	// Ausencia: tiene una ausencia (vacaciones, permiso) vigente ahora.
	Ausencia bool
	// EnTurno: su turno incluye el momento actual.
	EnTurno bool
	// TieneHabilidad: tiene la habilidad de la categoría (o la categoría no exige ninguna).
	TieneHabilidad bool
	// Capacidad es el máximo de incidencias abiertas que puede llevar.
	Capacidad int
	// Abiertas es cuántas lleva ahora; Carga es la suma ponderada por prioridad (P1=4, P2=2, P3/P4=1).
	Abiertas int
	Carga    int
	// UltimaAsignacion: cuándo recibió su última incidencia (nil = nunca).
	UltimaAsignacion *time.Time
}

// Peticion es lo que se despacha.
type Peticion struct {
	Prioridad string
	// FueraDeHorario: el momento actual cae fuera del calendario laboral base (noche,
	// fin de semana o feriado). Con P1 manda la guardia.
	FueraDeHorario bool
}

// Evaluado explica qué pasó con cada candidato (para el registro de decisiones).
type Evaluado struct {
	TecnicoID int    `json:"tecnico_id"`
	Nombre    string `json:"nombre"`
	Elegible  bool   `json:"elegible"`
	Razon     string `json:"razon,omitempty"` // por qué se descartó
	Carga     int    `json:"carga"`
	Abiertas  int    `json:"abiertas"`
	Guardia   bool   `json:"guardia,omitempty"`
}

// Decision es el resultado del despachador.
type Decision struct {
	// TecnicoID es el elegido; nil si la incidencia va a la cola del grupo.
	TecnicoID *int `json:"tecnico_id"`
	// PorGuardia: se asignó a quien está de guardia (P1).
	PorGuardia bool `json:"por_guardia"`
	// Cola: nadie pudo recibirla; queda sin técnico en 'nueva' y hay que avisar al responsable.
	Cola              bool `json:"cola"`
	AvisarResponsable bool `json:"avisar_responsable"`
	// Motivo es un código estable (Motivo*); Explicacion es el texto para la bitácora.
	Motivo      string     `json:"motivo"`
	Explicacion string     `json:"explicacion"`
	Evaluados   []Evaluado `json:"evaluados"`
}

// Decidir aplica la regla de asignación:
//
//  1. Elegibles = miembros del grupo con estado activo, sin ausencia vigente, con la
//     habilidad, EN TURNO y con capacidad libre (Abiertas < Capacidad).
//  2. Entre ellos, el de menor Carga ponderada; si empatan, el que lleva MÁS tiempo sin
//     recibir una asignación (nunca = el más antiguo); si aún empatan, el de menor id.
//  3. P1 fuera de horario: va a la guardia vigente (aunque esté fuera de turno o sin
//     capacidad). P1 en horario sin elegibles: también cae en la guardia.
//  4. Sin candidato: cola del grupo (sin técnico, estado 'nueva') y se marca para avisar al
//     responsable.
//
// miembros son los técnicos del grupo; guardias, quienes tienen guardia vigente (pueden ser
// de otro grupo). No modifica las listas recibidas.
func Decidir(p Peticion, miembros []Candidato, guardias []Candidato) Decision {
	d := Decision{Evaluados: []Evaluado{}}

	// Evaluación de los miembros del grupo.
	var elegibles []Candidato
	for _, c := range miembros {
		ev := Evaluado{TecnicoID: c.TecnicoID, Nombre: c.Nombre, Carga: c.Carga, Abiertas: c.Abiertas}
		switch {
		case c.Estado == "inactivo":
			ev.Razon = RazonInactivo
		case c.Estado == "ausente" || c.Ausencia:
			ev.Razon = RazonAusente
		case !c.TieneHabilidad:
			ev.Razon = RazonSinHabilidad
		case !c.EnTurno:
			ev.Razon = RazonFueraDeTurno
		case c.Abiertas >= c.Capacidad:
			ev.Razon = RazonSinCapacidad
		default:
			ev.Elegible = true
			elegibles = append(elegibles, c)
		}
		d.Evaluados = append(d.Evaluados, ev)
	}

	// Guardias elegibles: activas y sin ausencia (no se les exige turno, habilidad ni capacidad).
	var guardiasOK []Candidato
	if p.Prioridad == "P1" {
		for _, g := range guardias {
			ev := Evaluado{TecnicoID: g.TecnicoID, Nombre: g.Nombre, Carga: g.Carga, Abiertas: g.Abiertas, Guardia: true}
			switch {
			case g.Estado == "inactivo":
				ev.Razon = RazonInactivo
			case g.Estado == "ausente" || g.Ausencia:
				ev.Razon = RazonAusente
			default:
				ev.Elegible = true
				guardiasOK = append(guardiasOK, g)
			}
			d.Evaluados = append(d.Evaluados, ev)
		}
	}

	asignarGuardia := func() bool {
		if len(guardiasOK) == 0 {
			return false
		}
		g, _ := elegirMenorCarga(guardiasOK)
		d.TecnicoID = &g.TecnicoID
		d.PorGuardia = true
		d.Motivo = MotivoGuardia
		if p.FueraDeHorario {
			d.Explicacion = fmt.Sprintf("P1 fuera de horario: se asigna a %s, de guardia.", g.Nombre)
		} else {
			d.Explicacion = fmt.Sprintf("P1 sin técnico disponible en turno: se asigna a %s, de guardia.", g.Nombre)
		}
		return true
	}

	if p.Prioridad == "P1" && p.FueraDeHorario && asignarGuardia() {
		return d
	}
	if len(elegibles) > 0 {
		c, empate := elegirMenorCarga(elegibles)
		d.TecnicoID = &c.TecnicoID
		switch {
		case len(elegibles) == 1:
			d.Motivo = MotivoUnico
			d.Explicacion = fmt.Sprintf("%s es el único técnico disponible del grupo.", c.Nombre)
		case empate:
			d.Motivo = MotivoDesempate
			d.Explicacion = fmt.Sprintf("%s: empate de carga (%d); gana quien lleva más tiempo sin recibir una incidencia.", c.Nombre, c.Carga)
		default:
			d.Motivo = MotivoMenorCarga
			d.Explicacion = fmt.Sprintf("%s tiene la menor carga ponderada (%d).", c.Nombre, c.Carga)
		}
		return d
	}
	if p.Prioridad == "P1" && !p.FueraDeHorario && asignarGuardia() {
		return d
	}

	d.Cola = true
	d.AvisarResponsable = true
	d.Motivo = MotivoCola
	d.Explicacion = "Ningún técnico del grupo puede recibirla ahora (turno, ausencia, habilidad o capacidad): queda en la cola del grupo y se avisa al responsable."
	if len(miembros) == 0 {
		d.Explicacion = "El grupo no tiene técnicos: queda en su cola y se avisa al responsable."
	}
	return d
}

// elegirMenorCarga devuelve el candidato con menor carga; empate => más tiempo sin recibir
// una asignación (nil es el más antiguo); empate => menor id. El segundo valor dice si hubo
// empate de carga con otro candidato.
func elegirMenorCarga(cs []Candidato) (Candidato, bool) {
	ordenados := append([]Candidato(nil), cs...)
	sort.SliceStable(ordenados, func(i, j int) bool {
		a, b := ordenados[i], ordenados[j]
		if a.Carga != b.Carga {
			return a.Carga < b.Carga
		}
		if (a.UltimaAsignacion == nil) != (b.UltimaAsignacion == nil) {
			return a.UltimaAsignacion == nil
		}
		if a.UltimaAsignacion != nil && !a.UltimaAsignacion.Equal(*b.UltimaAsignacion) {
			return a.UltimaAsignacion.Before(*b.UltimaAsignacion)
		}
		return a.TecnicoID < b.TecnicoID
	})
	empate := len(ordenados) > 1 && ordenados[0].Carga == ordenados[1].Carga
	return ordenados[0], empate
}

// Turno es un tramo del turno semanal de un técnico, en minutos desde la medianoche local.
// Si Hasta <= Desde, el turno cruza la medianoche (p. ej. 22:00-06:00).
type Turno struct {
	Dia   int // 1 = lunes ... 7 = domingo
	Desde int
	Hasta int
}

// EnTurno dice si en el instante t el técnico está en turno, según su horario semanal y la
// zona del calendario. Contempla turnos que cruzan la medianoche.
func EnTurno(turnos []Turno, zona *time.Location, t time.Time) bool {
	l := t.In(zona)
	dia := isoDia(l.Weekday())
	diaAnterior := dia - 1
	if diaAnterior == 0 {
		diaAnterior = 7
	}
	min := l.Hour()*60 + l.Minute()
	for _, tr := range turnos {
		cruza := tr.Hasta <= tr.Desde
		if tr.Dia == dia {
			if !cruza && min >= tr.Desde && min < tr.Hasta {
				return true
			}
			if cruza && min >= tr.Desde { // la parte de la tarde/noche del mismo día
				return true
			}
		}
		if cruza && tr.Dia == diaAnterior && min < tr.Hasta { // la madrugada del turno de ayer
			return true
		}
	}
	return false
}

func isoDia(w time.Weekday) int {
	if w == time.Sunday {
		return 7
	}
	return int(w)
}
