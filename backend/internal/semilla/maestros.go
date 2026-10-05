package semilla

import (
	"context"
	"fmt"
	"math/rand/v2"
	"time"

	"jsrbot/backend/internal/store"
)

// maestros guarda los ids de lo que se insertó, para que los guiones los usen.
type maestros struct {
	personas   []personaSem
	vips       []int // índices en personas
	tecnicos   map[string]int
	grupoIDs   map[string]int
	supervisor int
}

type personaSem struct {
	ID     int
	VIP    bool
	Nombre string
	Sede   int
	Area   int
}

// insertarMaestros crea sedes, áreas, personas, activos, técnicos, habilidades, turnos,
// ausencias y guardias. Todo determinista: depende solo de la semilla y de las fechas.
func insertarMaestros(ctx context.Context, db *store.DB, rng *rand.Rand, lima *time.Location, desde, hasta time.Time, nPersonas int) (*maestros, error) {
	m := &maestros{tecnicos: map[string]int{}, grupoIDs: map[string]int{}}
	exec := func(sql string, args ...any) error {
		_, err := db.Exec(ctx, sql, args...)
		return err
	}
	var sedeIDs, areaIDs []int
	for _, s := range sedesSemilla {
		var id int
		if err := db.QueryRow(ctx, `INSERT INTO sedes (nombre) VALUES ($1) RETURNING id`, s).Scan(&id); err != nil {
			return nil, err
		}
		sedeIDs = append(sedeIDs, id)
	}
	for _, a := range areasSemilla {
		var id int
		if err := db.QueryRow(ctx, `INSERT INTO areas (nombre) VALUES ($1) RETURNING id`, a).Scan(&id); err != nil {
			return nil, err
		}
		areaIDs = append(areaIDs, id)
	}

	// Personas: ~40, con 3 VIP.
	vipIdx := map[int]bool{0: true, nPersonas / 3: true, 2 * nPersonas / 3: true}
	for i := 0; i < nPersonas; i++ {
		nombre := fmt.Sprintf("%s %s", nombresSemilla[i%len(nombresSemilla)], apellidosSemilla[(i*3+i/len(nombresSemilla)*7)%len(apellidosSemilla)])
		whatsapp := fmt.Sprintf("5100000%04d", i+1)
		correo := fmt.Sprintf("usuario%02d@empresa.example", i+1)
		sede, area := sedeIDs[rng.IntN(len(sedeIDs))], areaIDs[rng.IntN(len(areaIDs))]
		canal := "whatsapp"
		if i%9 == 4 {
			canal = "correo"
		}
		var id int
		if err := db.QueryRow(ctx, `INSERT INTO personas (nombre, whatsapp, correo, sede_id, area_id, vip, canal_preferido)
			VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`, nombre, whatsapp, correo, sede, area, vipIdx[i], canal).Scan(&id); err != nil {
			return nil, err
		}
		m.personas = append(m.personas, personaSem{ID: id, VIP: vipIdx[i], Nombre: nombre, Sede: sede, Area: area})
		if vipIdx[i] {
			m.vips = append(m.vips, i)
		}
		if err := exec(`INSERT INTO activos (codigo, tipo, persona_id, sede_id) VALUES ($1, 'pc', $2, $3)`,
			fmt.Sprintf("PC-%s-%02d", areasSemilla[rng.IntN(len(areasSemilla))][:3], i+1), id, sede); err != nil {
			return nil, err
		}
	}

	// Grupos (los sembró store.SembrarConfiguracion).
	rows, err := db.Query(ctx, `SELECT id, nombre FROM grupos`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var id int
		var n string
		if err := rows.Scan(&id, &n); err != nil {
			rows.Close()
			return nil, err
		}
		m.grupoIDs[n] = id
	}
	rows.Close()

	// Técnicos con sus habilidades, turnos y pertenencia a grupo.
	for _, t := range tecnicosSemilla {
		gid, ok := m.grupoIDs[t.Grupo]
		if !ok {
			return nil, fmt.Errorf("semilla: no existe el grupo %q (¿se sembró la configuración?)", t.Grupo)
		}
		var id int
		correo := fmt.Sprintf("tecnico%02d@empresa.example", len(m.tecnicos)+1)
		wa := fmt.Sprintf("5100001%04d", len(m.tecnicos)+1)
		if err := db.QueryRow(ctx, `INSERT INTO tecnicos (nombre, whatsapp, correo, nivel, capacidad) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
			t.Nombre, wa, correo, t.Nivel, t.Capacidad).Scan(&id); err != nil {
			return nil, err
		}
		m.tecnicos[t.Nombre] = id
		if err := exec(`INSERT INTO grupo_miembros (grupo_id, tecnico_id) VALUES ($1, $2)`, gid, id); err != nil {
			return nil, err
		}
		for i, c := range t.Skills {
			nivel := 2
			if i < 2 {
				nivel = 3
			}
			if err := exec(`INSERT INTO habilidades (tecnico_id, categoria_id, nivel) SELECT $1, id, $3 FROM categorias WHERE clave = $2`, id, c, nivel); err != nil {
				return nil, err
			}
		}
		for dia := 1; dia <= 5; dia++ {
			tramos := [][2]string{{"08:30", "13:00"}, {"14:00", "18:00"}}
			if t.TurnoTarde {
				tramos = [][2]string{{"12:00", "18:00"}}
			}
			for _, tr := range tramos {
				if err := exec(`INSERT INTO turnos (tecnico_id, dia_semana, desde, hasta) VALUES ($1, $2, $3, $4)`, id, dia, tr[0], tr[1]); err != nil {
					return nil, err
				}
			}
		}
		if t.Responsable {
			if err := exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, gid, id); err != nil {
				return nil, err
			}
		}
		if t.Supervisor {
			m.supervisor = id
		}
	}
	if err := store.GuardarConfig(ctx, db, store.ConfSupervisorTecnicoID, m.supervisor); err != nil {
		return nil, err
	}

	// Ausencias: vacaciones de Marta Rojas y un permiso de Carlos Vega.
	aus := []struct {
		quien        string
		desde, hasta time.Time
		motivo       string
	}{
		{"Marta Rojas", dia(lima, 2026, 8, 10), dia(lima, 2026, 8, 22), "vacaciones (sintético)"},
		{"Carlos Vega", dia(lima, 2026, 9, 7), dia(lima, 2026, 9, 10), "permiso (sintético)"},
	}
	for _, a := range aus {
		if err := exec(`INSERT INTO ausencias (tecnico_id, desde, hasta, motivo) VALUES ($1, $2, $3, $4)`, m.tecnicos[a.quien], a.desde, a.hasta, a.motivo); err != nil {
			return nil, err
		}
	}

	// Guardias: rotación semanal entre quienes tienen Guardia. Cada guardia va del lunes 18:00
	// al lunes siguiente 08:30 (cubre noches, fines de semana y feriados).
	var guard []int
	for _, t := range tecnicosSemilla {
		if t.Guardia {
			guard = append(guard, m.tecnicos[t.Nombre])
		}
	}
	lunes := lunesAnterior(desde, lima)
	for i := 0; lunes.Before(hasta.AddDate(0, 0, 7)); i++ {
		ini := time.Date(lunes.Year(), lunes.Month(), lunes.Day(), 0, 0, 0, 0, lima)
		if i > 0 {
			ini = time.Date(lunes.Year(), lunes.Month(), lunes.Day(), 18, 0, 0, 0, lima)
		}
		fin := time.Date(lunes.Year(), lunes.Month(), lunes.Day()+7, 8, 30, 0, 0, lima)
		if err := exec(`INSERT INTO guardias (tecnico_id, desde, hasta) VALUES ($1, $2, $3)`, guard[i%len(guard)], ini, fin); err != nil {
			return nil, err
		}
		lunes = lunes.AddDate(0, 0, 7)
	}
	return m, nil
}

func dia(lima *time.Location, y int, mes time.Month, d int) time.Time {
	return time.Date(y, mes, d, 0, 0, 0, 0, lima)
}

// lunesAnterior devuelve el lunes (a las 00:00 de Lima) de la semana de t.
func lunesAnterior(t time.Time, lima *time.Location) time.Time {
	l := t.In(lima)
	atras := (int(l.Weekday()) + 6) % 7
	return time.Date(l.Year(), l.Month(), l.Day()-atras, 0, 0, 0, 0, lima)
}
