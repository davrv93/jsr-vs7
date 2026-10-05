package sla

import "fmt"

// Valores cerrados del vocabulario (docs/CONTRATOS.md §3).
var (
	Impactos    = []string{"persona", "area", "sede", "organizacion"}
	Urgencias   = []string{"baja", "media", "alta", "critica"}
	Prioridades = []string{"P1", "P2", "P3", "P4"}
)

// Matriz es la matriz impacto x urgencia -> prioridad. Es configurable: se carga de la
// tabla matriz_prioridad. Nunca la calcula un LLM (AGENTS §1.4 regla 5).
type Matriz map[string]string

func claveMatriz(impacto, urgencia string) string { return impacto + "|" + urgencia }

// Poner fija una celda de la matriz.
func (m Matriz) Poner(impacto, urgencia, prioridad string) {
	m[claveMatriz(impacto, urgencia)] = prioridad
}

// Prioridad devuelve la prioridad de una celda. Error si el vocabulario no existe o la
// celda no está configurada.
func (m Matriz) Prioridad(impacto, urgencia string) (string, error) {
	if !contiene(Impactos, impacto) {
		return "", fmt.Errorf("sla: impacto %q inválido (use %v)", impacto, Impactos)
	}
	if !contiene(Urgencias, urgencia) {
		return "", fmt.Errorf("sla: urgencia %q inválida (use %v)", urgencia, Urgencias)
	}
	p, ok := m[claveMatriz(impacto, urgencia)]
	if !ok {
		return "", fmt.Errorf("sla: la matriz no define %s x %s", impacto, urgencia)
	}
	return p, nil
}

// MatrizPorDefecto es la de ARQUITECTURA §3.1.
//
// SUPUESTO: valores por defecto mientras la organización no confirme su matriz
// (CONTEXT.md §7 punto 6).
func MatrizPorDefecto() Matriz {
	m := Matriz{}
	filas := []struct {
		impacto string
		p       [4]string // crítica, alta, media, baja
	}{
		{"organizacion", [4]string{"P1", "P1", "P2", "P3"}},
		{"sede", [4]string{"P1", "P2", "P2", "P3"}},
		{"area", [4]string{"P2", "P2", "P3", "P4"}},
		{"persona", [4]string{"P2", "P3", "P3", "P4"}},
	}
	orden := []string{"critica", "alta", "media", "baja"}
	for _, f := range filas {
		for i, u := range orden {
			m.Poner(f.impacto, u, f.p[i])
		}
	}
	return m
}

// RangoPrioridad devuelve 1..4 (P1 = 1, la más urgente). 0 si no es válida.
func RangoPrioridad(p string) int {
	switch p {
	case "P1":
		return 1
	case "P2":
		return 2
	case "P3":
		return 3
	case "P4":
		return 4
	}
	return 0
}

// AplicarMinimo sube la prioridad hasta el mínimo dado: nunca la baja. Con minimo "P2",
// P3 y P4 pasan a P2 y P1 y P2 se quedan. Sirve para el usuario VIP (mínimo P2).
// Devuelve la prioridad resultante y si cambió.
func AplicarMinimo(prioridad, minimo string) (string, bool) {
	rp, rm := RangoPrioridad(prioridad), RangoPrioridad(minimo)
	if rp == 0 || rm == 0 || rp <= rm {
		return prioridad, false
	}
	return minimo, true
}

func contiene(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

// ValidoImpacto, ValidoUrgencia y ValidaPrioridad validan el vocabulario cerrado.
func ValidoImpacto(s string) bool   { return contiene(Impactos, s) }
func ValidaUrgencia(s string) bool  { return contiene(Urgencias, s) }
func ValidaPrioridad(s string) bool { return contiene(Prioridades, s) }
