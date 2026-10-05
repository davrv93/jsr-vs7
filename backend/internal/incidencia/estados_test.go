package incidencia

import (
	"errors"
	"sort"
	"strings"
	"testing"
)

// Matriz completa estado x acción: lo que NO está en la lista es inválido.
func TestTransicionesTabla(t *testing.T) {
	// acción -> "desde:hasta" separados por espacio. Cualquier otro par debe fallar.
	validas := map[Accion]string{
		AccAsignar:          "nueva:asignada asignada:asignada en_curso:en_curso espera_usuario:espera_usuario espera_tercero:espera_tercero reabierta:reabierta",
		AccResponder:        "asignada:en_curso reabierta:en_curso en_curso:en_curso espera_usuario:espera_usuario espera_tercero:espera_tercero",
		AccPausarUsuario:    "en_curso:espera_usuario",
		AccPausarTercero:    "en_curso:espera_tercero",
		AccReanudar:         "espera_usuario:en_curso espera_tercero:en_curso",
		AccResolver:         "en_curso:resuelta",
		AccReabrir:          "resuelta:reabierta",
		AccCerrar:           "resuelta:cerrada",
		AccEscalar:          "nueva:asignada asignada:asignada en_curso:asignada espera_usuario:asignada espera_tercero:asignada reabierta:asignada",
		AccCambiarPrioridad: "nueva:nueva asignada:asignada en_curso:en_curso espera_usuario:espera_usuario espera_tercero:espera_tercero reabierta:reabierta",
		AccComentar:         "nueva:nueva asignada:asignada en_curso:en_curso espera_usuario:espera_usuario espera_tercero:espera_tercero reabierta:reabierta resuelta:resuelta",
		AccAgregarDato:      "nueva:nueva asignada:asignada en_curso:en_curso espera_usuario:espera_usuario espera_tercero:espera_tercero reabierta:reabierta",
	}
	if len(validas) != len(Acciones) {
		t.Fatalf("la tabla de la prueba cubre %d acciones y hay %d", len(validas), len(Acciones))
	}
	nValidas, nInvalidas := 0, 0
	for _, a := range Acciones {
		esperadas := map[Estado]Estado{}
		for _, par := range strings.Fields(validas[a]) {
			p := strings.Split(par, ":")
			esperadas[Estado(p[0])] = Estado(p[1])
		}
		for _, e := range Estados {
			hasta, err := Transicion(e, a)
			if quiere, ok := esperadas[e]; ok {
				nValidas++
				if err != nil || hasta != quiere {
					t.Errorf("%s desde %s: %s (%v), quiere %s", a, e, hasta, err, quiere)
				}
				continue
			}
			nInvalidas++
			if err == nil {
				t.Errorf("%s desde %s debería ser inválida y llevó a %s", a, e, hasta)
				continue
			}
			if !errors.Is(err, ErrTransicionInvalida) {
				t.Errorf("%s desde %s: el error no es ErrTransicionInvalida: %v", a, e, err)
			}
			var et *ErrTransicion
			if !errors.As(err, &et) || et.Estado != e || et.Accion != a {
				t.Errorf("%s desde %s: ErrTransicion mal armado: %+v", a, e, err)
			}
			if hasta != e {
				t.Errorf("%s desde %s inválida: debe devolver el estado de origen, no %s", a, e, hasta)
			}
		}
	}
	if nValidas+nInvalidas != len(Acciones)*len(Estados) {
		t.Errorf("no se recorrieron todos los pares")
	}
}

func TestCerradaEsTerminal(t *testing.T) {
	for _, a := range Acciones {
		if _, err := Transicion(Cerrada, a); err == nil {
			t.Errorf("desde cerrada no debe permitirse %s", a)
		}
	}
	if len(Permitidas(Cerrada)) != 0 {
		t.Errorf("cerrada no ofrece acciones: %v", Permitidas(Cerrada))
	}
}

func TestPermitidasPorEstado(t *testing.T) {
	quiere := map[Estado][]string{
		Nueva:         {"asignar", "escalar", "cambiar_prioridad", "comentar", "agregar_dato"},
		EnCurso:       {"asignar", "responder", "pausar_usuario", "pausar_tercero", "resolver", "escalar", "cambiar_prioridad", "comentar", "agregar_dato"},
		EsperaUsuario: {"asignar", "responder", "reanudar", "escalar", "cambiar_prioridad", "comentar", "agregar_dato"},
		Resuelta:      {"reabrir", "cerrar", "comentar"},
	}
	for e, q := range quiere {
		var got []string
		for _, a := range Permitidas(e) {
			got = append(got, string(a))
		}
		sort.Strings(got)
		sort.Strings(q)
		if strings.Join(got, ",") != strings.Join(q, ",") {
			t.Errorf("%s: %v, quiere %v", e, got, q)
		}
	}
}

func TestPredicadosDeEstado(t *testing.T) {
	for _, e := range Estados {
		if !e.Valido() {
			t.Errorf("%s debe ser válido", e)
		}
	}
	if Estado("fantasma").Valido() {
		t.Error("estado inventado no es válido")
	}
	abiertas := map[Estado]bool{Nueva: true, Asignada: true, EnCurso: true, EsperaUsuario: true, EsperaTercero: true, Reabierta: true, Resuelta: false, Cerrada: false}
	for e, q := range abiertas {
		if e.Abierta() != q {
			t.Errorf("%s.Abierta() = %v", e, e.Abierta())
		}
	}
	if !EsperaUsuario.Pausa() || !EsperaTercero.Pausa() || EnCurso.Pausa() {
		t.Error("solo espera_usuario y espera_tercero pausan")
	}
}
