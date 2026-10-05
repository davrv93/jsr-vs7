package escala

import (
	"fmt"
	"time"

	"jsrbot/backend/internal/sla"
)

// Foto es todo lo que las condiciones necesitan saber de una incidencia en un instante.
// La arma el vigía desde la base; las condiciones son funciones puras sobre ella.
type Foto struct {
	ID        int64
	Numero    string
	Titulo    string
	Prioridad string
	Estado    string
	GrupoID   *int
	Grupo     string
	TecnicoID *int
	Categoria string
	// CategoriaID sirve para buscar la política de SLA de la categoría.
	CategoriaID *int

	Reaperturas      int
	Creada           time.Time
	PrimeraRespuesta *time.Time
	Resuelta         *time.Time

	// Señales de los eventos.
	VIP         bool // la persona era VIP al crear
	Queja       bool // hay un evento «queja»
	GuiaAgotada bool // la creó el asistente con motivo guia_agotada

	// Plazos ya marcados como vencidos (evento sla_vencido).
	MarcadoVencidoRespuesta  bool
	MarcadoVencidoResolucion bool

	// SLA medido en el instante de la evaluación.
	Respuesta  sla.Estado
	Resolucion sla.Estado
}

// Evaluar dice si la condición se cumple para la foto, y con qué detalle (porcentaje,
// minutos restantes...). Es pura.
//
// Para el SLA, la métrica «respuesta» solo aplica mientras no haya primera respuesta; la
// «resolucion», mientras la incidencia esté abierta (el vigía solo evalúa abiertas). Se
// cumple al alcanzar el umbral (>=): al 100 % del plazo ya hay que escalar.
func Evaluar(c Condicion, f Foto) (bool, map[string]any) {
	switch c.Tipo {
	case CondSLA:
		var e sla.Estado
		switch c.Metrica {
		case "respuesta":
			if f.PrimeraRespuesta != nil {
				return false, nil
			}
			e = f.Respuesta
		case "resolucion":
			e = f.Resolucion
		default:
			return false, nil
		}
		if e.LimiteMin <= 0 || e.Porcentaje < c.UmbralPct {
			return false, nil
		}
		return true, map[string]any{"metrica": c.Metrica, "umbral_pct": c.UmbralPct,
			"porcentaje": round1(e.Porcentaje), "restante_min": round1(e.RestanteMin)}
	case CondPrioridad:
		if f.Prioridad == c.Valor {
			return true, map[string]any{"prioridad": f.Prioridad}
		}
	case CondReaperturas:
		if f.Reaperturas >= c.Min {
			return true, map[string]any{"reaperturas": f.Reaperturas}
		}
	case CondQueja:
		if f.Queja {
			return true, map[string]any{}
		}
	case CondVIP:
		if f.VIP {
			return true, map[string]any{}
		}
	case CondGuiaAgotada:
		if f.GuiaAgotada {
			return true, map[string]any{}
		}
	}
	return false, nil
}

func round1(f float64) float64 { return float64(int64(f*10+sign(f)*0.5)) / 10 }

func sign(f float64) float64 {
	if f < 0 {
		return -1
	}
	return 1
}

// plantillaAviso da el nombre de la plantilla de un aviso según la regla que lo origina:
// las cuatro reglas de SLA comparten plantilla por umbral (sla_75, sla_100).
func plantillaAviso(r Regla) string {
	if r.Condicion.Tipo == CondSLA {
		return fmt.Sprintf("sla_%d", int(r.Condicion.UmbralPct))
	}
	return r.Clave
}
