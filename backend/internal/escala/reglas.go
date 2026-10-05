// Package escala es el vigía de SLA y el motor de reglas de escalamiento (ARQUITECTURA §3.3,
// AGENTS §3.4).
//
// Las reglas son DATOS (tabla escalamiento_reglas): versionadas, con modo «sombra» (registra
// lo que haría, no actúa) o «activo» (actúa). Vigilar recorre las incidencias abiertas,
// evalúa las reglas y ejecuta o solo registra según el modo. Es idempotente: la tabla
// escalamientos es única por (incidencia, regla, versión), así que una regla dispara una sola
// vez por incidencia aunque el vigía corra dos veces o se reinicie. Los avisos no se envían
// aquí: se encolan en la tabla avisos con una clave de idempotencia.
package escala

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"jsrbot/backend/internal/store"
)

// Modos de una regla.
const (
	ModoSombra = "sombra"
	ModoActivo = "activo"
)

// Tipos de condición.
const (
	CondSLA         = "sla"          // consumo del plazo de respuesta o resolución >= umbral_pct
	CondPrioridad   = "prioridad"    // la incidencia tiene la prioridad `valor`
	CondReaperturas = "reaperturas"  // reaperturas >= min
	CondQueja       = "queja"        // la persona se quejó (evento queja)
	CondVIP         = "vip"          // la persona es VIP
	CondGuiaAgotada = "guia_agotada" // el asistente agotó la guía antes de abrirla
)

// Tipos de acción.
const (
	AccAvisarTecnico     = "avisar_tecnico"
	AccEscalarNivel      = "escalar_nivel"
	AccAvisarResponsable = "avisar_responsable"
	AccAvisarGuardia     = "avisar_guardia"
	AccAvisarSupervisor  = "avisar_supervisor"
	// AccNota deja un comentario interno con `texto` (la regla «guia_agotada»).
	AccNota = "nota"
)

var tiposAccion = map[string]bool{
	AccAvisarTecnico: true, AccEscalarNivel: true, AccAvisarResponsable: true,
	AccAvisarGuardia: true, AccAvisarSupervisor: true, AccNota: true,
}

// Condicion de una regla (escalamiento_reglas.condicion).
type Condicion struct {
	Tipo      string  `json:"tipo"`
	Metrica   string  `json:"metrica,omitempty"`    // sla: respuesta | resolucion
	UmbralPct float64 `json:"umbral_pct,omitempty"` // sla: 75, 100...
	Valor     string  `json:"valor,omitempty"`      // prioridad: P1...
	Min       int     `json:"min,omitempty"`        // reaperturas: 2
}

// Accion de una regla (elemento de escalamiento_reglas.acciones).
type Accion struct {
	Tipo  string `json:"tipo"`
	Texto string `json:"texto,omitempty"`
}

// Regla es una fila de escalamiento_reglas.
type Regla struct {
	ID        int       `json:"id"`
	Clave     string    `json:"clave"`
	Version   int       `json:"version"`
	Activa    bool      `json:"activa"`
	Modo      string    `json:"modo"`
	Condicion Condicion `json:"condicion"`
	Acciones  []Accion  `json:"acciones"`
	CreadaEn  time.Time `json:"creada_en"`
}

// Validar comprueba que la condición y las acciones sean conocidas.
func (r Regla) Validar() error {
	if r.Clave == "" {
		return fmt.Errorf("escala: la regla necesita clave")
	}
	if r.Modo != ModoSombra && r.Modo != ModoActivo {
		return fmt.Errorf("escala: modo %q desconocido (use sombra o activo)", r.Modo)
	}
	switch c := r.Condicion; c.Tipo {
	case CondSLA:
		if c.Metrica != "respuesta" && c.Metrica != "resolucion" {
			return fmt.Errorf("escala: la condición sla pide metrica respuesta o resolucion, no %q", c.Metrica)
		}
		if c.UmbralPct <= 0 {
			return fmt.Errorf("escala: la condición sla pide umbral_pct > 0")
		}
	case CondPrioridad:
		if c.Valor == "" {
			return fmt.Errorf("escala: la condición prioridad pide valor")
		}
	case CondReaperturas:
		if c.Min < 1 {
			return fmt.Errorf("escala: la condición reaperturas pide min >= 1")
		}
	case CondQueja, CondVIP, CondGuiaAgotada:
	default:
		return fmt.Errorf("escala: condición %q desconocida", c.Tipo)
	}
	for _, a := range r.Acciones {
		if !tiposAccion[a.Tipo] {
			return fmt.Errorf("escala: acción %q desconocida", a.Tipo)
		}
	}
	return nil
}

func escanearRegla(row interface{ Scan(...any) error }) (Regla, error) {
	var r Regla
	var cond, acc []byte
	if err := row.Scan(&r.ID, &r.Clave, &r.Version, &r.Activa, &r.Modo, &cond, &acc, &r.CreadaEn); err != nil {
		return r, err
	}
	r.CreadaEn = r.CreadaEn.UTC()
	if err := json.Unmarshal(cond, &r.Condicion); err != nil {
		return r, fmt.Errorf("escala: la condición de %s v%d no es válida: %w", r.Clave, r.Version, err)
	}
	if err := json.Unmarshal(acc, &r.Acciones); err != nil {
		return r, fmt.Errorf("escala: las acciones de %s v%d no son válidas: %w", r.Clave, r.Version, err)
	}
	return r, nil
}

// ReglasVigentes devuelve, por cada clave, la versión más alta que esté activa. Es lo que
// evalúa el vigía: una versión nueva reemplaza a la anterior sin tocar las ya disparadas.
func ReglasVigentes(ctx context.Context, q store.Q) ([]Regla, error) {
	rows, err := q.Query(ctx, `SELECT DISTINCT ON (clave) id, clave, version, activa, modo, condicion, acciones, creada_en
		FROM escalamiento_reglas WHERE activa ORDER BY clave, version DESC`)
	if err != nil {
		return nil, fmt.Errorf("escala: cargar reglas: %w", err)
	}
	defer rows.Close()
	var out []Regla
	for rows.Next() {
		r, err := escanearRegla(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// PublicarVersion crea una versión nueva de una regla (la versión máxima + 1) y devuelve su
// número. Es la forma correcta de cambiar una regla o de pasarla de sombra a activo con una
// cifra que la justifique: las disparadas con la versión anterior quedan como historia.
func PublicarVersion(ctx context.Context, q store.Q, r Regla) (int, error) {
	if err := r.Validar(); err != nil {
		return 0, err
	}
	cond, _ := json.Marshal(r.Condicion)
	acc, _ := json.Marshal(r.Acciones)
	var v int
	err := q.QueryRow(ctx, `INSERT INTO escalamiento_reglas (clave, version, activa, modo, condicion, acciones)
		SELECT $1, COALESCE(max(version), 0) + 1, true, $2, $3, $4 FROM escalamiento_reglas WHERE clave = $1
		RETURNING version`, r.Clave, r.Modo, cond, acc).Scan(&v)
	if err != nil {
		return 0, fmt.Errorf("escala: publicar %s: %w", r.Clave, err)
	}
	return v, nil
}

// CambiarModo pone el modo de una versión concreta (sombra o activo). Ojo: pasar una regla
// de sombra a activo en el mismo lugar hace que el vigía ejecute, en su próxima pasada, lo
// que antes solo registró para las incidencias que aún cumplan la condición. Para una
// activación controlada, publique una versión nueva con PublicarVersion.
func CambiarModo(ctx context.Context, q store.Q, clave string, version int, modo string) error {
	if modo != ModoSombra && modo != ModoActivo {
		return fmt.Errorf("escala: modo %q desconocido", modo)
	}
	tag, err := q.Exec(ctx, `UPDATE escalamiento_reglas SET modo = $3 WHERE clave = $1 AND version = $2`, clave, version, modo)
	if err != nil {
		return fmt.Errorf("escala: cambiar modo de %s v%d: %w", clave, version, err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("escala: la regla %s v%d no existe: %w", clave, version, store.ErrNoEncontrado)
	}
	return nil
}
