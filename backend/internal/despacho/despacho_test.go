package despacho

import (
	"context"
	"testing"
	"time"

	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

func hace(d time.Duration) *time.Time {
	t := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC).Add(-d)
	return &t
}

// ok arma un técnico plenamente disponible.
func ok(id int, nombre string, carga int, ultima *time.Time) Candidato {
	return Candidato{TecnicoID: id, Nombre: nombre, Estado: "activo", EnTurno: true, TieneHabilidad: true,
		Capacidad: 8, Abiertas: carga, Carga: carga, UltimaAsignacion: ultima}
}

func idDe(d Decision) int {
	if d.TecnicoID == nil {
		return 0
	}
	return *d.TecnicoID
}

func TestDecidirCasos(t *testing.T) {
	casos := []struct {
		nombre    string
		p         Peticion
		miembros  []Candidato
		guardias  []Candidato
		quiereID  int // 0 = cola
		motivo    string
		guardia   bool
		avisarRes bool
	}{
		{
			nombre:   "menor carga ponderada gana",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{ok(1, "Ana", 5, nil), ok(2, "Beto", 2, hace(time.Hour)), ok(3, "Carla", 4, nil)},
			quiereID: 2, motivo: MotivoMenorCarga,
		},
		{
			nombre:   "empate de carga: gana el que lleva más tiempo sin recibir",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{ok(1, "Ana", 3, hace(time.Hour)), ok(2, "Beto", 3, hace(5*time.Hour)), ok(3, "Carla", 3, hace(2*time.Hour))},
			quiereID: 2, motivo: MotivoDesempate,
		},
		{
			nombre:   "empate: quien nunca recibió gana a quien recibió hace mucho",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{ok(1, "Ana", 3, hace(48*time.Hour)), ok(2, "Beto", 3, nil)},
			quiereID: 2, motivo: MotivoDesempate,
		},
		{
			nombre:   "empate total: el de menor id (determinista)",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{ok(7, "Gus", 3, nil), ok(4, "Dan", 3, nil), ok(9, "Eli", 3, nil)},
			quiereID: 4, motivo: MotivoDesempate,
		},
		{
			nombre:   "único candidato",
			p:        Peticion{Prioridad: "P2"},
			miembros: []Candidato{ok(1, "Ana", 7, nil)},
			quiereID: 1, motivo: MotivoUnico,
		},
		{
			nombre:   "fuera de turno no recibe aunque tenga menos carga",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.EnTurno = false; return c }(), ok(2, "Beto", 6, nil)},
			quiereID: 2, motivo: MotivoUnico,
		},
		{
			nombre:   "ausente por estado no recibe",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.Estado = "ausente"; return c }(), ok(2, "Beto", 6, nil)},
			quiereID: 2, motivo: MotivoUnico,
		},
		{
			nombre:   "ausente por ausencia vigente (vacaciones) no recibe",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.Ausencia = true; return c }(), ok(2, "Beto", 6, nil)},
			quiereID: 2, motivo: MotivoUnico,
		},
		{
			nombre:   "capacidad llena: no recibe",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 8, nil); c.Capacidad = 8; return c }(), ok(2, "Beto", 7, nil)},
			quiereID: 2, motivo: MotivoUnico,
		},
		{
			nombre:   "sin habilidad: no recibe",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.TieneHabilidad = false; return c }(), ok(2, "Beto", 6, nil)},
			quiereID: 2, motivo: MotivoUnico,
		},
		{
			nombre:   "inactivo no recibe",
			p:        Peticion{Prioridad: "P3"},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.Estado = "inactivo"; return c }(), ok(2, "Beto", 6, nil)},
			quiereID: 2, motivo: MotivoUnico,
		},
		{
			nombre: "sin candidatos: cola y avisar al responsable",
			p:      Peticion{Prioridad: "P3"},
			miembros: []Candidato{
				func() Candidato { c := ok(1, "Ana", 0, nil); c.EnTurno = false; return c }(),
				func() Candidato { c := ok(2, "Beto", 8, nil); return c }(),
			},
			quiereID: 0, motivo: MotivoCola, avisarRes: true,
		},
		{
			nombre: "grupo vacío: cola",
			p:      Peticion{Prioridad: "P2"}, miembros: nil,
			quiereID: 0, motivo: MotivoCola, avisarRes: true,
		},
		{
			nombre:   "P1 fuera de horario: la guardia, aunque haya alguien con turno nocturno",
			p:        Peticion{Prioridad: "P1", FueraDeHorario: true},
			miembros: []Candidato{ok(1, "Ana", 0, nil)},
			guardias: []Candidato{ok(5, "Gabi", 3, nil)},
			quiereID: 5, motivo: MotivoGuardia, guardia: true,
		},
		{
			nombre:   "P1 fuera de horario: la guardia fuera de turno y con capacidad llena igual recibe",
			p:        Peticion{Prioridad: "P1", FueraDeHorario: true},
			miembros: nil,
			guardias: []Candidato{func() Candidato { c := ok(5, "Gabi", 9, nil); c.EnTurno = false; c.TieneHabilidad = false; return c }()},
			quiereID: 5, motivo: MotivoGuardia, guardia: true,
		},
		{
			nombre:   "P1 fuera de horario con dos guardias: la de menor carga",
			p:        Peticion{Prioridad: "P1", FueraDeHorario: true},
			guardias: []Candidato{ok(5, "Gabi", 4, nil), ok(6, "Hugo", 1, nil)},
			quiereID: 6, motivo: MotivoGuardia, guardia: true,
		},
		{
			nombre:   "P1 fuera de horario: guardia ausente se ignora y sin nadie va a la cola",
			p:        Peticion{Prioridad: "P1", FueraDeHorario: true},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.EnTurno = false; return c }()},
			guardias: []Candidato{func() Candidato { c := ok(5, "Gabi", 0, nil); c.Ausencia = true; return c }()},
			quiereID: 0, motivo: MotivoCola, avisarRes: true,
		},
		{
			nombre:   "P1 en horario con técnico disponible: va al técnico, no a la guardia",
			p:        Peticion{Prioridad: "P1"},
			miembros: []Candidato{ok(1, "Ana", 1, nil)},
			guardias: []Candidato{ok(5, "Gabi", 0, nil)},
			quiereID: 1, motivo: MotivoUnico,
		},
		{
			nombre:   "P1 en horario sin nadie disponible: cae en la guardia",
			p:        Peticion{Prioridad: "P1"},
			miembros: []Candidato{ok(1, "Ana", 8, nil)},
			guardias: []Candidato{ok(5, "Gabi", 0, nil)},
			quiereID: 5, motivo: MotivoGuardia, guardia: true,
		},
		{
			nombre:   "P2 fuera de horario NO usa la guardia",
			p:        Peticion{Prioridad: "P2", FueraDeHorario: true},
			miembros: []Candidato{func() Candidato { c := ok(1, "Ana", 0, nil); c.EnTurno = false; return c }()},
			guardias: []Candidato{ok(5, "Gabi", 0, nil)},
			quiereID: 0, motivo: MotivoCola, avisarRes: true,
		},
	}
	for _, tc := range casos {
		t.Run(tc.nombre, func(t *testing.T) {
			d := Decidir(tc.p, tc.miembros, tc.guardias)
			if idDe(d) != tc.quiereID {
				t.Errorf("técnico = %d, quiere %d (%s)", idDe(d), tc.quiereID, d.Explicacion)
			}
			if d.Motivo != tc.motivo {
				t.Errorf("motivo = %s, quiere %s", d.Motivo, tc.motivo)
			}
			if d.PorGuardia != tc.guardia {
				t.Errorf("por_guardia = %v", d.PorGuardia)
			}
			if d.Cola != (tc.quiereID == 0) || d.AvisarResponsable != tc.avisarRes {
				t.Errorf("cola=%v avisar_responsable=%v", d.Cola, d.AvisarResponsable)
			}
			if d.Explicacion == "" {
				t.Error("toda decisión lleva explicación")
			}
		})
	}
}

func TestDecidirDescartaConRazon(t *testing.T) {
	ausente := ok(1, "Ana", 0, nil)
	ausente.Ausencia = true
	fuera := ok(2, "Beto", 0, nil)
	fuera.EnTurno = false
	llena := ok(3, "Carla", 8, nil)
	sinHab := ok(4, "Dan", 0, nil)
	sinHab.TieneHabilidad = false
	d := Decidir(Peticion{Prioridad: "P3"}, []Candidato{ausente, fuera, llena, sinHab, ok(5, "Eli", 1, nil)}, nil)
	razones := map[int]string{}
	for _, e := range d.Evaluados {
		razones[e.TecnicoID] = e.Razon
	}
	quiere := map[int]string{1: RazonAusente, 2: RazonFueraDeTurno, 3: RazonSinCapacidad, 4: RazonSinHabilidad, 5: ""}
	for id, r := range quiere {
		if razones[id] != r {
			t.Errorf("técnico %d: razón %q, quiere %q", id, razones[id], r)
		}
	}
	if idDe(d) != 5 {
		t.Errorf("elegido = %d", idDe(d))
	}
}

func TestDecidirNoModificaLasEntradas(t *testing.T) {
	ms := []Candidato{ok(3, "C", 5, nil), ok(1, "A", 1, nil), ok(2, "B", 3, nil)}
	copia := append([]Candidato(nil), ms...)
	Decidir(Peticion{Prioridad: "P3"}, ms, nil)
	for i := range ms {
		if ms[i].TecnicoID != copia[i].TecnicoID {
			t.Fatal("Decidir reordenó la lista recibida")
		}
	}
}

func TestEnTurno(t *testing.T) {
	lima, _ := time.LoadLocation("America/Lima")
	lun := func(h, m int) time.Time { return time.Date(2026, 10, 5, h, m, 0, 0, lima) }
	diurno := []Turno{{Dia: 1, Desde: 8*60 + 30, Hasta: 13 * 60}, {Dia: 1, Desde: 14 * 60, Hasta: 18 * 60}}
	casos := []struct {
		turnos []Turno
		t      time.Time
		quiere bool
	}{
		{diurno, lun(9, 0), true}, {diurno, lun(13, 30), false}, {diurno, lun(8, 29), false}, {diurno, lun(18, 0), false},
		{diurno, time.Date(2026, 10, 6, 9, 0, 0, 0, lima), false}, // martes: sin turno
		// 22:00-06:00 de lunes: cubre lunes 23:00 y martes 03:00, no martes 07:00.
		{[]Turno{{Dia: 1, Desde: 22 * 60, Hasta: 6 * 60}}, lun(23, 0), true},
		{[]Turno{{Dia: 1, Desde: 22 * 60, Hasta: 6 * 60}}, time.Date(2026, 10, 6, 3, 0, 0, 0, lima), true},
		{[]Turno{{Dia: 1, Desde: 22 * 60, Hasta: 6 * 60}}, time.Date(2026, 10, 6, 7, 0, 0, 0, lima), false},
		{[]Turno{{Dia: 7, Desde: 22 * 60, Hasta: 6 * 60}}, lun(3, 0), true}, // domingo noche -> lunes madrugada
		{nil, lun(9, 0), false},
	}
	for i, tc := range casos {
		if got := EnTurno(tc.turnos, lima, tc.t); got != tc.quiere {
			t.Errorf("caso %d: EnTurno(%s) = %v", i, tc.t.In(lima).Format("Mon 15:04"), got)
		}
	}
	// La zona manda: 14:00Z del lunes es 09:00 en Lima.
	if !EnTurno(diurno, lima, time.Date(2026, 10, 5, 14, 0, 0, 0, time.UTC)) {
		t.Error("14:00Z es 09:00 en Lima: en turno")
	}
}

// ---- capa de base --------------------------------------------------------------------------

type escenario struct {
	db                     *store.DB
	grupoID                int
	catID                  int
	ana, beto, carla, gabi int
}

func montar(t *testing.T) escenario {
	t.Helper()
	db := storetest.NuevaBDConConfig(t)
	ctx := context.Background()
	var e escenario
	e.db = db
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(db.QueryRow(ctx, `SELECT id FROM grupos WHERE nombre = 'Mesa N1'`).Scan(&e.grupoID))
	must(db.QueryRow(ctx, `SELECT id FROM categorias WHERE clave = 'correo'`).Scan(&e.catID))
	nuevo := func(nombre string) int {
		var id int
		must(db.QueryRow(ctx, `INSERT INTO tecnicos (nombre) VALUES ($1) RETURNING id`, nombre).Scan(&id))
		return id
	}
	e.ana, e.beto, e.carla, e.gabi = nuevo("Ana"), nuevo("Beto"), nuevo("Carla"), nuevo("Gabi")
	for _, id := range []int{e.ana, e.beto, e.carla} {
		_, err := db.Exec(ctx, `INSERT INTO grupo_miembros VALUES ($1, $2)`, e.grupoID, id)
		must(err)
		_, err = db.Exec(ctx, `INSERT INTO habilidades VALUES ($1, $2, 2)`, id, e.catID)
		must(err)
		for dia := 1; dia <= 5; dia++ {
			_, err = db.Exec(ctx, `INSERT INTO turnos (tecnico_id, dia_semana, desde, hasta) VALUES ($1, $2, '08:30', '18:00')`, id, dia)
			must(err)
		}
	}
	return e
}

func (e escenario) insertarIncidencia(t *testing.T, tecnico int, prio, estado string) {
	t.Helper()
	_, err := e.db.Exec(context.Background(), `INSERT INTO incidencias (titulo, categoria_id, grupo_id, tecnico_id, prioridad, estado)
		VALUES ('x', $1, $2, $3, $4, $5)`, e.catID, e.grupoID, tecnico, prio, estado)
	if err != nil {
		t.Fatal(err)
	}
}

func TestElegirLeeLaBase(t *testing.T) {
	e := montar(t)
	ctx := context.Background()
	lima, _ := time.LoadLocation("America/Lima")
	lunes10 := time.Date(2026, 10, 5, 10, 0, 0, 0, lima)
	pedir := func(prio string, ahora time.Time, fuera bool) Decision {
		t.Helper()
		var d Decision
		err := e.db.EnTx(ctx, func(tx pgxTx) error {
			var err error
			d, err = Elegir(ctx, tx, Entrada{GrupoID: e.grupoID, CategoriaID: &e.catID, Prioridad: prio, Ahora: ahora, Zona: lima, FueraDeHorario: fuera})
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return d
	}

	// Carga: Ana 1×P1 (4), Beto 3×P3 (3), Carla 1×P2 (2) => gana Carla.
	e.insertarIncidencia(t, e.ana, "P1", "en_curso")
	for i := 0; i < 3; i++ {
		e.insertarIncidencia(t, e.beto, "P3", "asignada")
	}
	e.insertarIncidencia(t, e.carla, "P2", "espera_usuario")
	// Las resueltas y cerradas no pesan.
	e.insertarIncidencia(t, e.carla, "P1", "resuelta")
	e.insertarIncidencia(t, e.carla, "P1", "cerrada")
	if d := pedir("P3", lunes10, false); idDe(d) != e.carla || d.Motivo != MotivoMenorCarga {
		t.Fatalf("carga ponderada: %+v", d)
	}

	// Carla de vacaciones => Beto (3) < Ana (4).
	if _, err := e.db.Exec(ctx, `INSERT INTO ausencias (tecnico_id, desde, hasta, motivo) VALUES ($1, $2, $3, 'vacaciones')`,
		e.carla, lunes10.Add(-24*time.Hour), lunes10.Add(24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if d := pedir("P3", lunes10, false); idDe(d) != e.beto {
		t.Fatalf("con Carla ausente debía ganar Beto: %+v", d)
	}
	// Una ausencia vencida ya no cuenta.
	if d := pedir("P3", lunes10.Add(48*time.Hour), false); idDe(d) == 0 {
		t.Fatalf("la ausencia ya terminó: %+v", d)
	}

	// Fuera de turno (lunes 19:00): todos fuera => cola.
	d := pedir("P3", time.Date(2026, 10, 5, 19, 0, 0, 0, lima), true)
	if !d.Cola || !d.AvisarResponsable {
		t.Fatalf("fuera de turno debía ir a cola: %+v", d)
	}

	// P1 fuera de horario con guardia vigente (Gabi, que ni es del grupo ni tiene turno).
	noche := time.Date(2026, 10, 5, 23, 0, 0, 0, lima)
	if _, err := e.db.Exec(ctx, `INSERT INTO guardias (tecnico_id, desde, hasta) VALUES ($1, $2, $3)`,
		e.gabi, noche.Add(-5*time.Hour), noche.Add(5*time.Hour)); err != nil {
		t.Fatal(err)
	}
	d = pedir("P1", noche, true)
	if idDe(d) != e.gabi || !d.PorGuardia {
		t.Fatalf("P1 de noche debía ir a la guardia: %+v", d)
	}
	// Una P3 de noche no usa la guardia.
	if d = pedir("P3", noche, true); !d.Cola {
		t.Fatalf("P3 de noche va a cola: %+v", d)
	}
	// La guardia terminó.
	if d = pedir("P1", noche.Add(6*time.Hour), true); !d.Cola {
		t.Fatalf("sin guardia vigente, P1 de madrugada va a cola: %+v", d)
	}

	// Capacidad: Ana con capacidad 1 y una abierta no recibe.
	if _, err := e.db.Exec(ctx, `UPDATE tecnicos SET capacidad = 1 WHERE id = $1`, e.ana); err != nil {
		t.Fatal(err)
	}
	if d := pedir("P3", lunes10, false); idDe(d) == e.ana {
		t.Fatalf("Ana está al tope de capacidad: %+v", d)
	}

	// Registrar la asignación actualiza ultima_asignacion.
	if err := RegistrarAsignacion(ctx, e.db, e.beto, lunes10); err != nil {
		t.Fatal(err)
	}
	var ult *time.Time
	_ = e.db.QueryRow(ctx, `SELECT ultima_asignacion FROM tecnicos WHERE id = $1`, e.beto).Scan(&ult)
	if ult == nil || !ult.Equal(lunes10) {
		t.Errorf("ultima_asignacion = %v", ult)
	}
}

func TestElegirSinHabilidadNiMiembros(t *testing.T) {
	e := montar(t)
	ctx := context.Background()
	lima, _ := time.LoadLocation("America/Lima")
	otra := 0
	if err := e.db.QueryRow(ctx, `SELECT id FROM categorias WHERE clave = 'vpn'`).Scan(&otra); err != nil {
		t.Fatal(err)
	}
	var d Decision
	err := e.db.EnTx(ctx, func(tx pgxTx) error {
		var err error
		d, err = Elegir(ctx, tx, Entrada{GrupoID: e.grupoID, CategoriaID: &otra, Prioridad: "P3",
			Ahora: time.Date(2026, 10, 5, 10, 0, 0, 0, lima), Zona: lima})
		return err
	})
	if err != nil || !d.Cola {
		t.Fatalf("nadie del grupo tiene la habilidad de vpn: %+v (%v)", d, err)
	}
	var grupoVacio int
	_ = e.db.QueryRow(ctx, `SELECT id FROM grupos WHERE nombre = 'Redes'`).Scan(&grupoVacio)
	err = e.db.EnTx(ctx, func(tx pgxTx) error {
		var err error
		d, err = Elegir(ctx, tx, Entrada{GrupoID: grupoVacio, Prioridad: "P3", Ahora: time.Now(), Zona: lima})
		return err
	})
	if err != nil || !d.Cola {
		t.Fatalf("grupo sin miembros: %+v (%v)", d, err)
	}
}

// Dos asignaciones simultáneas no pueden sobrepasar la capacidad: Elegir bloquea a los candidatos.
func TestElegirEnParaleloRespetaLaCapacidad(t *testing.T) {
	e := montar(t)
	ctx := context.Background()
	lima, _ := time.LoadLocation("America/Lima")
	ahora := time.Date(2026, 10, 5, 10, 0, 0, 0, lima)
	// Solo Ana queda con turno; capacidad 3.
	if _, err := e.db.Exec(ctx, `DELETE FROM grupo_miembros WHERE tecnico_id <> $1`, e.ana); err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(ctx, `UPDATE tecnicos SET capacidad = 3 WHERE id = $1`, e.ana); err != nil {
		t.Fatal(err)
	}
	const intentos = 10
	res := make(chan error, intentos)
	for i := 0; i < intentos; i++ {
		go func() {
			res <- e.db.EnTx(ctx, func(tx pgxTx) error {
				d, err := Elegir(ctx, tx, Entrada{GrupoID: e.grupoID, CategoriaID: &e.catID, Prioridad: "P3", Ahora: ahora, Zona: lima})
				if err != nil {
					return err
				}
				if d.TecnicoID == nil {
					return nil // cola
				}
				_, err = tx.Exec(ctx, `INSERT INTO incidencias (titulo, categoria_id, grupo_id, tecnico_id, prioridad, estado)
					VALUES ('p', $1, $2, $3, 'P3', 'asignada')`, e.catID, e.grupoID, *d.TecnicoID)
				return err
			})
		}()
	}
	for i := 0; i < intentos; i++ {
		if err := <-res; err != nil {
			t.Fatal(err)
		}
	}
	var n int
	_ = e.db.QueryRow(ctx, `SELECT count(*) FROM incidencias WHERE tecnico_id = $1`, e.ana).Scan(&n)
	if n != 3 {
		t.Errorf("Ana tiene %d incidencias asignadas, capacidad 3", n)
	}
}
