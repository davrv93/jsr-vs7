// Package incidencia es el gestor de incidencias (ARQUITECTURA §3): ciclo de vida como
// máquina de estados, creación con prioridad por matriz y asignación por el despachador, y
// las acciones de la mesa (asignar, responder, pausar, resolver, reabrir, cerrar, escalar...).
//
// Principios:
//   - Los EVENTOS son la verdad: incidencia_eventos solo recibe inserciones. Las columnas de
//     incidencias son una proyección que se recalcula en cada acción (incluidos los
//     vencimientos vence_*_en, que salen del reloj de internal/sla, nunca de un contador).
//   - Cada acción corre en UNA transacción: bloquea la fila (FOR UPDATE), valida la transición,
//     inserta los eventos, actualiza la proyección y deja en outbox_analitica las filas de
//     ClickHouse (eventos_incidencia, incidencias_estado, incidencias_tiempos), todo junto.
//   - Los avisos no se envían aquí: se encolan en la tabla avisos (store.EncolarAviso).
//   - El tiempo es inyectable (Servicio.Reloj) para probar y para la semilla sintética.
package incidencia

import (
	"errors"
	"fmt"
)

// Estado de una incidencia (docs/CONTRATOS.md §3).
type Estado string

const (
	Nueva         Estado = "nueva"
	Asignada      Estado = "asignada"
	EnCurso       Estado = "en_curso"
	EsperaUsuario Estado = "espera_usuario"
	EsperaTercero Estado = "espera_tercero"
	Resuelta      Estado = "resuelta"
	Cerrada       Estado = "cerrada"
	Reabierta     Estado = "reabierta"
)

// Estados lista los estados en el orden del ciclo de vida.
var Estados = []Estado{Nueva, Asignada, EnCurso, EsperaUsuario, EsperaTercero, Resuelta, Cerrada, Reabierta}

// Abierta dice si la incidencia sigue en manos de la mesa (ni resuelta ni cerrada).
func (e Estado) Abierta() bool { return e != Resuelta && e != Cerrada && e != "" }

// Pausa dice si el estado detiene el reloj de SLA por esperar a alguien.
func (e Estado) Pausa() bool { return e == EsperaUsuario || e == EsperaTercero }

// Valido dice si es un estado conocido.
func (e Estado) Valido() bool {
	for _, x := range Estados {
		if x == e {
			return true
		}
	}
	return false
}

// Accion es algo que se puede hacer a una incidencia.
type Accion string

const (
	AccAsignar          Accion = "asignar"
	AccResponder        Accion = "responder"
	AccPausarUsuario    Accion = "pausar_usuario"
	AccPausarTercero    Accion = "pausar_tercero"
	AccReanudar         Accion = "reanudar"
	AccResolver         Accion = "resolver"
	AccReabrir          Accion = "reabrir"
	AccCerrar           Accion = "cerrar"
	AccEscalar          Accion = "escalar"
	AccCambiarPrioridad Accion = "cambiar_prioridad"
	AccComentar         Accion = "comentar"
	AccAgregarDato      Accion = "agregar_dato"
)

// Acciones lista todas las acciones.
var Acciones = []Accion{AccAsignar, AccResponder, AccPausarUsuario, AccPausarTercero, AccReanudar, AccResolver,
	AccReabrir, AccCerrar, AccEscalar, AccCambiarPrioridad, AccComentar, AccAgregarDato}

// ErrTransicionInvalida es el error base de una acción no permitida en el estado actual.
var ErrTransicionInvalida = errors.New("transición no permitida")

// ErrTransicion detalla qué acción se intentó en qué estado. errors.Is(err, ErrTransicionInvalida) es true.
type ErrTransicion struct {
	Estado Estado
	Accion Accion
}

func (e *ErrTransicion) Error() string {
	return fmt.Sprintf("no se puede %s una incidencia en estado %s", textoAccion(e.Accion), e.Estado)
}

// Is permite errors.Is(err, ErrTransicionInvalida).
func (e *ErrTransicion) Is(target error) bool { return target == ErrTransicionInvalida }

func textoAccion(a Accion) string {
	switch a {
	case AccAsignar:
		return "asignar"
	case AccResponder:
		return "responder"
	case AccPausarUsuario, AccPausarTercero:
		return "pausar"
	case AccReanudar:
		return "reanudar"
	case AccResolver:
		return "resolver"
	case AccReabrir:
		return "reabrir"
	case AccCerrar:
		return "cerrar"
	case AccEscalar:
		return "escalar"
	case AccCambiarPrioridad:
		return "cambiar la prioridad de"
	case AccComentar:
		return "comentar"
	case AccAgregarDato:
		return "agregar un dato a"
	}
	return string(a)
}

// abiertas son los estados en que la incidencia sigue en manos de la mesa.
var abiertas = []Estado{Nueva, Asignada, EnCurso, EsperaUsuario, EsperaTercero, Reabierta}

// transiciones es la máquina de estados de ARQUITECTURA §3.1: para cada acción, desde qué
// estados se permite y a cuál lleva. Todo lo que no está aquí es inválido.
//
//	nueva ──asignar──▶ asignada ──responder──▶ en_curso ──pausar──▶ espera_usuario/espera_tercero ──reanudar──▶ en_curso
//	en_curso ──resolver──▶ resuelta ──cerrar──▶ cerrada          resuelta ──reabrir──▶ reabierta ──responder──▶ en_curso
//
// Escalar lleva a 'asignada' (el nuevo técnico aún no respondió); si el nuevo grupo no tiene
// quién la reciba, Escalar la deja en 'nueva' (cola del grupo): es la única excepción, y la
// decide el despachador, no la tabla.
var transiciones = func() map[Accion]map[Estado]Estado {
	t := map[Accion]map[Estado]Estado{
		AccAsignar:       {Nueva: Asignada, Asignada: Asignada, EnCurso: EnCurso, EsperaUsuario: EsperaUsuario, EsperaTercero: EsperaTercero, Reabierta: Reabierta},
		AccResponder:     {Asignada: EnCurso, Reabierta: EnCurso, EnCurso: EnCurso, EsperaUsuario: EsperaUsuario, EsperaTercero: EsperaTercero},
		AccPausarUsuario: {EnCurso: EsperaUsuario},
		AccPausarTercero: {EnCurso: EsperaTercero},
		AccReanudar:      {EsperaUsuario: EnCurso, EsperaTercero: EnCurso},
		AccResolver:      {EnCurso: Resuelta},
		AccReabrir:       {Resuelta: Reabierta},
		AccCerrar:        {Resuelta: Cerrada},
	}
	// Acciones que no cambian el estado: se permiten en las abiertas (comentar, también en resuelta).
	for _, a := range []Accion{AccCambiarPrioridad, AccAgregarDato} {
		t[a] = map[Estado]Estado{}
		for _, e := range abiertas {
			t[a][e] = e
		}
	}
	t[AccEscalar] = map[Estado]Estado{}
	for _, e := range abiertas {
		t[AccEscalar][e] = Asignada
	}
	t[AccComentar] = map[Estado]Estado{Resuelta: Resuelta}
	for _, e := range abiertas {
		t[AccComentar][e] = e
	}
	return t
}()

// Transicion devuelve el estado al que lleva la acción desde el estado dado, o un
// *ErrTransicion (errors.Is ErrTransicionInvalida) si no está permitida. Es pura.
func Transicion(desde Estado, a Accion) (Estado, error) {
	if hasta, ok := transiciones[a][desde]; ok {
		return hasta, nil
	}
	return desde, &ErrTransicion{Estado: desde, Accion: a}
}

// Permitidas devuelve las acciones válidas desde un estado (para que la consola solo ofrezca
// botones que funcionan).
func Permitidas(desde Estado) []Accion {
	var out []Accion
	for _, a := range Acciones {
		if _, ok := transiciones[a][desde]; ok {
			out = append(out, a)
		}
	}
	return out
}
