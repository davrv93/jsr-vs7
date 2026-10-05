package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Claves de la tabla configuracion que usa el dominio. Todas tienen un valor por defecto
// sembrado por SembrarConfiguracion (SUPUESTO: hasta que la organización confirme).
const (
	// ConfCalendarioBase: nombre del calendario del horario laboral de la mesa. Decide qué es
	// «fuera de horario» (guardia para P1) y cuenta las 48 h laborales del cierre automático.
	ConfCalendarioBase = "calendario_base"
	// ConfVIPPrioridadMinima: prioridad mínima de una incidencia de una persona VIP.
	ConfVIPPrioridadMinima = "vip_prioridad_minima"
	// ConfPausaEsperaTercero: si espera_tercero detiene el reloj de SLA (configurable).
	ConfPausaEsperaTercero = "pausa_espera_tercero"
	// ConfCierreAutomaticoHoras: horas LABORALES en 'resuelta' sin confirmación antes de cerrar.
	ConfCierreAutomaticoHoras = "cierre_automatico_horas"
	// ConfPesoCarga: peso de cada prioridad en la carga del técnico {"P1":4,"P2":2,"P3":1,"P4":1}.
	ConfPesoCarga = "peso_carga"
	// ConfSupervisorTecnicoID: técnico que recibe los avisos «al supervisor».
	ConfSupervisorTecnicoID = "supervisor_tecnico_id"
	// ConfSemillaSintetica: marca de que la base lleva datos sintéticos de cmd/semilla.
	ConfSemillaSintetica = "semilla_sintetica"
)

// LeerConfig devuelve el JSON crudo de una clave. ok=false si no existe.
func LeerConfig(ctx context.Context, q Q, clave string) (raw []byte, ok bool, err error) {
	err = q.QueryRow(ctx, `SELECT valor FROM configuracion WHERE clave = $1`, clave).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("store: leer configuración %q: %w", clave, err)
	}
	return raw, true, nil
}

// GuardarConfig escribe (o reemplaza) una clave de configuración.
func GuardarConfig(ctx context.Context, q Q, clave string, valor any) error {
	raw, err := json.Marshal(valor)
	if err != nil {
		return fmt.Errorf("store: configuración %q: %w", clave, err)
	}
	_, err = q.Exec(ctx, `INSERT INTO configuracion (clave, valor, actualizado_en) VALUES ($1, $2, now())
		ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado_en = now()`, clave, raw)
	if err != nil {
		return fmt.Errorf("store: guardar configuración %q: %w", clave, err)
	}
	return nil
}

// ConfigTexto lee una clave de texto, o defecto si no existe o no es texto.
func ConfigTexto(ctx context.Context, q Q, clave, defecto string) (string, error) {
	raw, ok, err := LeerConfig(ctx, q, clave)
	if err != nil || !ok {
		return defecto, err
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return defecto, nil
	}
	return s, nil
}

// ConfigEntero lee una clave numérica, o defecto si no existe o no es un número.
func ConfigEntero(ctx context.Context, q Q, clave string, defecto int) (int, error) {
	raw, ok, err := LeerConfig(ctx, q, clave)
	if err != nil || !ok {
		return defecto, err
	}
	var f float64
	if json.Unmarshal(raw, &f) != nil {
		return defecto, nil
	}
	return int(f), nil
}

// ConfigBool lee una clave booleana, o defecto si no existe o no es booleana.
func ConfigBool(ctx context.Context, q Q, clave string, defecto bool) (bool, error) {
	raw, ok, err := LeerConfig(ctx, q, clave)
	if err != nil || !ok {
		return defecto, err
	}
	var b bool
	if json.Unmarshal(raw, &b) != nil {
		return defecto, nil
	}
	return b, nil
}

// PesosCarga devuelve el peso de cada prioridad para la carga ponderada del despachador.
func PesosCarga(ctx context.Context, q Q) (map[string]int, error) {
	pesos := map[string]int{"P1": 4, "P2": 2, "P3": 1, "P4": 1}
	raw, ok, err := LeerConfig(ctx, q, ConfPesoCarga)
	if err != nil || !ok {
		return pesos, err
	}
	var m map[string]int
	if json.Unmarshal(raw, &m) == nil {
		for k, v := range m {
			pesos[k] = v
		}
	}
	return pesos, nil
}
