package store

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/sla"
)

// Esta es la configuración por defecto de jsrbot. Todo lo que la organización no ha
// confirmado lleva el comentario SUPUESTO: y se lista en CONTEXT.md §7.
//
// SembrarConfiguracion es IDEMPOTENTE: usa ON CONFLICT DO NOTHING (o NOT EXISTS), de modo que
// no pisa lo que un administrador haya editado desde la consola.

// NombreCalendarioLaboral y NombreCalendario24x7 son los calendarios sembrados.
const (
	NombreCalendarioLaboral = "laboral_lima"
	NombreCalendario24x7    = "24x7"
)

// HorarioLaboralDefecto es el horario laboral por defecto en el formato de calendarios.horario.
//
// SUPUESTO: lunes a viernes 08:30-13:00 y 14:00-18:00, hora de Lima (CONTEXT.md §7 punto 6).
const HorarioLaboralDefecto = `{"1":[["08:30","13:00"],["14:00","18:00"]],"2":[["08:30","13:00"],["14:00","18:00"]],` +
	`"3":[["08:30","13:00"],["14:00","18:00"]],"4":[["08:30","13:00"],["14:00","18:00"]],` +
	`"5":[["08:30","13:00"],["14:00","18:00"]],"6":[],"7":[]}`

// Feriado es un día no laborable del calendario.
type Feriado struct {
	Fecha  string // AAAA-MM-DD
	Nombre string
}

// FeriadosPeru2026 son los feriados nacionales no laborables de Perú en 2026.
//
// SUPUESTO: lista oficial a la fecha de escribirla; NO incluye los «días no laborables»
// (puentes) que el Gobierno decreta cada año ni los feriados regionales. La organización
// debe revisarla y completarla desde Ajustes → Calendarios.
var FeriadosPeru2026 = []Feriado{
	{"2026-01-01", "Año Nuevo"},
	{"2026-04-02", "Jueves Santo"},
	{"2026-04-03", "Viernes Santo"},
	{"2026-05-01", "Día del Trabajo"},
	{"2026-06-07", "Batalla de Arica y Día de la Bandera"},
	{"2026-06-29", "San Pedro y San Pablo"},
	{"2026-07-23", "Día de la Fuerza Aérea del Perú"},
	{"2026-07-28", "Fiestas Patrias"},
	{"2026-07-29", "Fiestas Patrias"},
	{"2026-08-06", "Batalla de Junín"},
	{"2026-08-30", "Santa Rosa de Lima"},
	{"2026-10-08", "Combate de Angamos"},
	{"2026-11-01", "Día de Todos los Santos"},
	{"2026-12-08", "Inmaculada Concepción"},
	{"2026-12-09", "Batalla de Ayacucho"},
	{"2026-12-25", "Navidad"},
}

// grupoDefecto describe un grupo de ejemplo.
//
// SUPUESTO: cuatro grupos de ejemplo (ARQUITECTURA §3.2). La cadena de escalamiento es
// Mesa N1 -> Infraestructura y Redes/Aplicaciones -> Infraestructura: hasta conocer la
// organización solo hay un grupo de tercer nivel.
type grupoDefecto struct {
	Nombre  string
	Nivel   string
	EscalaA string // nombre del grupo siguiente ("" = ninguno)
}

var gruposDefecto = []grupoDefecto{
	{"Mesa N1", "N1", "Infraestructura"},
	{"Redes", "N2", "Infraestructura"},
	{"Aplicaciones", "N2", "Infraestructura"},
	{"Infraestructura", "N3", ""},
}

// categoriaDefecto: categorías del vocabulario cerrado (docs/CONTRATOS.md §3) con el grupo
// que las atiende. SUPUESTO: reparto de ejemplo.
type categoriaDefecto struct {
	Clave  string
	Nombre string
	Grupo  string
}

var categoriasDefecto = []categoriaDefecto{
	{"correo", "Correo", "Mesa N1"},
	{"cuentas_accesos", "Cuentas y accesos", "Mesa N1"},
	{"red_wifi", "Red y wifi", "Redes"},
	{"vpn", "VPN", "Redes"},
	{"impresoras", "Impresoras", "Mesa N1"},
	{"equipo", "Equipo", "Mesa N1"},
	{"software_oficina", "Software de oficina", "Mesa N1"},
	{"sistema_interno", "Sistema interno", "Aplicaciones"},
	{"telefonia", "Telefonía", "Redes"},
	{"otro", "Otro", "Mesa N1"},
}

// politicaDefecto son los plazos por prioridad, en minutos LABORALES del calendario.
//
// SUPUESTO: plazos de ejemplo tipo ITIL; P1 corre 24x7 (ARQUITECTURA §3.1). La organización
// los fija en Ajustes → SLA.
type politicaDefecto struct {
	Prioridad  string
	Calendario string
	Respuesta  int
	Resolucion int
}

var politicasDefecto = []politicaDefecto{
	{"P1", NombreCalendario24x7, 15, 240},
	{"P2", NombreCalendarioLaboral, 30, 480},
	{"P3", NombreCalendarioLaboral, 120, 1440},
	{"P4", NombreCalendarioLaboral, 240, 2880},
}

// ReglaDefecto es una regla de escalamiento sembrada.
type ReglaDefecto struct {
	Clave     string
	Condicion map[string]any
	Acciones  []map[string]any
}

// ReglasDefecto son las reglas de ARQUITECTURA §3.3. Nacen en modo 'sombra': registran lo
// que harían sin actuar hasta que una cifra justifique pasarlas a 'activo' (AGENTS §1.4
// regla 6). SUPUESTO: acciones por defecto hasta conocer la organización.
//
// El SLA se parte por métrica (respuesta/resolución) en reglas distintas porque la tabla
// escalamientos es única por (incidencia, regla, versión): una sola regla «sla_75» solo
// podría dispararse una vez aunque venzan los dos plazos.
func ReglasDefecto() []ReglaDefecto {
	act := func(tipos ...string) []map[string]any {
		var out []map[string]any
		for _, t := range tipos {
			out = append(out, map[string]any{"tipo": t})
		}
		return out
	}
	condSLA := func(metrica string, pct int) map[string]any {
		return map[string]any{"tipo": "sla", "metrica": metrica, "umbral_pct": pct}
	}
	return []ReglaDefecto{
		{"sla_75_respuesta", condSLA("respuesta", 75), act("avisar_tecnico")},
		{"sla_75_resolucion", condSLA("resolucion", 75), act("avisar_tecnico")},
		{"sla_100_respuesta", condSLA("respuesta", 100), act("escalar_nivel", "avisar_responsable")},
		{"sla_100_resolucion", condSLA("resolucion", 100), act("escalar_nivel", "avisar_responsable")},
		{"p1_creada", map[string]any{"tipo": "prioridad", "valor": "P1"}, act("avisar_guardia", "avisar_supervisor")},
		{"reapertura_2", map[string]any{"tipo": "reaperturas", "min": 2}, act("escalar_nivel", "avisar_supervisor")},
		{"queja", map[string]any{"tipo": "queja"}, act("avisar_supervisor")},
		{"vip", map[string]any{"tipo": "vip"}, act("avisar_supervisor")},
		{"guia_agotada", map[string]any{"tipo": "guia_agotada"},
			[]map[string]any{{"tipo": "nota", "texto": "El asistente agotó la guía (2 intentos) antes de abrir la incidencia."}}},
	}
}

// SembrarConfiguracion deja la base con la configuración por defecto. Idempotente.
func SembrarConfiguracion(ctx context.Context, d *DB) error {
	return d.EnTx(ctx, func(tx pgx.Tx) error { return sembrar(ctx, tx) })
}

func sembrar(ctx context.Context, tx pgx.Tx) error {
	// 1. Claves de configuración (no pisa las existentes).
	config := []struct {
		clave string
		valor any
	}{
		{ConfCalendarioBase, NombreCalendarioLaboral},
		{ConfVIPPrioridadMinima, "P2"},
		{ConfPausaEsperaTercero, true},
		{ConfCierreAutomaticoHoras, 48},
		{ConfPesoCarga, map[string]int{"P1": 4, "P2": 2, "P3": 1, "P4": 1}},
	}
	for _, c := range config {
		raw, _ := json.Marshal(c.valor)
		if _, err := tx.Exec(ctx, `INSERT INTO configuracion (clave, valor) VALUES ($1, $2)
			ON CONFLICT (clave) DO NOTHING`, c.clave, raw); err != nil {
			return fmt.Errorf("sembrar configuración %s: %w", c.clave, err)
		}
	}

	// 2. Calendarios y feriados.
	if _, err := tx.Exec(ctx, `INSERT INTO calendarios (nombre, zona, veinticuatro_siete, horario)
		VALUES ($1, 'America/Lima', false, $2::jsonb) ON CONFLICT (nombre) DO NOTHING`,
		NombreCalendarioLaboral, HorarioLaboralDefecto); err != nil {
		return fmt.Errorf("sembrar calendario laboral: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO calendarios (nombre, zona, veinticuatro_siete, horario)
		VALUES ($1, 'America/Lima', true, '{}'::jsonb) ON CONFLICT (nombre) DO NOTHING`,
		NombreCalendario24x7); err != nil {
		return fmt.Errorf("sembrar calendario 24x7: %w", err)
	}
	for _, f := range FeriadosPeru2026 {
		if _, err := tx.Exec(ctx, `INSERT INTO feriados (calendario_id, fecha, nombre)
			SELECT id, $2::date, $3 FROM calendarios WHERE nombre = $1
			ON CONFLICT (calendario_id, fecha) DO NOTHING`, NombreCalendarioLaboral, f.Fecha, f.Nombre); err != nil {
			return fmt.Errorf("sembrar feriado %s: %w", f.Fecha, err)
		}
	}

	// 3. Matriz de prioridad.
	m := sla.MatrizPorDefecto()
	for _, imp := range sla.Impactos {
		for _, urg := range sla.Urgencias {
			p, _ := m.Prioridad(imp, urg)
			if _, err := tx.Exec(ctx, `INSERT INTO matriz_prioridad (impacto, urgencia, prioridad)
				VALUES ($1, $2, $3) ON CONFLICT (impacto, urgencia) DO NOTHING`, imp, urg, p); err != nil {
				return fmt.Errorf("sembrar matriz %s x %s: %w", imp, urg, err)
			}
		}
	}

	// 4. Grupos, su cadena de escalamiento y las categorías.
	for _, g := range gruposDefecto {
		if _, err := tx.Exec(ctx, `INSERT INTO grupos (nombre, nivel) VALUES ($1, $2)
			ON CONFLICT (nombre) DO NOTHING`, g.Nombre, g.Nivel); err != nil {
			return fmt.Errorf("sembrar grupo %s: %w", g.Nombre, err)
		}
	}
	for _, g := range gruposDefecto {
		if g.EscalaA == "" {
			continue
		}
		if _, err := tx.Exec(ctx, `UPDATE grupos SET escala_a_grupo_id = (SELECT id FROM grupos WHERE nombre = $2)
			WHERE nombre = $1 AND escala_a_grupo_id IS NULL`, g.Nombre, g.EscalaA); err != nil {
			return fmt.Errorf("sembrar escalamiento de %s: %w", g.Nombre, err)
		}
	}
	for _, c := range categoriasDefecto {
		if _, err := tx.Exec(ctx, `INSERT INTO categorias (clave, nombre, grupo_id)
			SELECT $1, $2, id FROM grupos WHERE nombre = $3 ON CONFLICT (clave) DO NOTHING`,
			c.Clave, c.Nombre, c.Grupo); err != nil {
			return fmt.Errorf("sembrar categoría %s: %w", c.Clave, err)
		}
	}

	// 5. Políticas de SLA por prioridad (valen para todas las categorías: categoria_id NULL).
	for _, p := range politicasDefecto {
		if _, err := tx.Exec(ctx, `INSERT INTO sla_politicas (prioridad, categoria_id, calendario_id, respuesta_min, resolucion_min)
			SELECT $1, NULL, c.id, $3, $4 FROM calendarios c WHERE c.nombre = $2
			AND NOT EXISTS (SELECT 1 FROM sla_politicas WHERE prioridad = $1 AND categoria_id IS NULL)`,
			p.Prioridad, p.Calendario, p.Respuesta, p.Resolucion); err != nil {
			return fmt.Errorf("sembrar política %s: %w", p.Prioridad, err)
		}
	}

	// 6. Reglas de escalamiento en modo sombra (versión 1).
	for _, r := range ReglasDefecto() {
		cond, _ := json.Marshal(r.Condicion)
		acc, _ := json.Marshal(r.Acciones)
		if _, err := tx.Exec(ctx, `INSERT INTO escalamiento_reglas (clave, version, activa, modo, condicion, acciones)
			VALUES ($1, 1, true, 'sombra', $2, $3) ON CONFLICT (clave, version) DO NOTHING`,
			r.Clave, cond, acc); err != nil {
			return fmt.Errorf("sembrar regla %s: %w", r.Clave, err)
		}
	}
	return nil
}
