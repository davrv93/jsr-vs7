package escala

import (
	"context"
	"sort"
	"testing"
	"time"

	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

var lima = func() *time.Location {
	l, err := time.LoadLocation("America/Lima")
	if err != nil {
		panic(err)
	}
	return l
}()

func L(y int, m time.Month, d, h, mi int) time.Time { return time.Date(y, m, d, h, mi, 0, 0, lima) }

type entorno struct {
	t     *testing.T
	ctx   context.Context
	db    *store.DB
	svc   *incidencia.Servicio
	reloj *incidencia.RelojManual
	vig   *Vigia

	mesa, infra          int
	ana, beto, dan, gabi int
	pepe, vera           int
}

func nuevoEntorno(t *testing.T) *entorno {
	t.Helper()
	db := storetest.NuevaBDConConfig(t)
	e := &entorno{t: t, ctx: context.Background(), db: db}
	e.reloj = incidencia.NuevoRelojManual(L(2026, 10, 5, 9, 0))
	e.svc = incidencia.Nuevo(db, incidencia.ConReloj(e.reloj.Ahora))
	e.vig = Nuevo(e.svc)

	e.mesa = e.escalar(`SELECT id FROM grupos WHERE nombre = 'Mesa N1'`)
	e.infra = e.escalar(`SELECT id FROM grupos WHERE nombre = 'Infraestructura'`)
	tecnico := func(nombre string, grupo int) int {
		id := e.escalar(`INSERT INTO tecnicos (nombre, whatsapp) VALUES ($1, '5100000' || lpad((random()*9999)::int::text, 4, '0')) RETURNING id`, nombre)
		e.exec(`INSERT INTO grupo_miembros VALUES ($1, $2)`, grupo, id)
		e.exec(`INSERT INTO habilidades (tecnico_id, categoria_id) SELECT $1, id FROM categorias`, id)
		for dia := 1; dia <= 5; dia++ {
			e.exec(`INSERT INTO turnos (tecnico_id, dia_semana, desde, hasta) VALUES ($1, $2, '08:30', '18:00')`, id, dia)
		}
		return id
	}
	e.ana, e.beto = tecnico("Ana", e.mesa), tecnico("Beto", e.mesa)
	e.dan, e.gabi = tecnico("Dan", e.infra), tecnico("Gabi", e.infra)
	e.exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, e.mesa, e.ana)
	e.exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, e.infra, e.dan)
	if err := store.GuardarConfig(e.ctx, db, store.ConfSupervisorTecnicoID, e.dan); err != nil {
		t.Fatal(err)
	}
	// Guardia de Gabi: del viernes 9-oct 18:00 al lunes 12-oct 08:30.
	e.exec(`INSERT INTO guardias (tecnico_id, desde, hasta) VALUES ($1, $2, $3)`, e.gabi, L(2026, 10, 9, 18, 0), L(2026, 10, 12, 8, 30))
	e.pepe = e.escalar(`INSERT INTO personas (nombre, whatsapp) VALUES ('Pepe Prueba', '51000000001') RETURNING id`)
	e.vera = e.escalar(`INSERT INTO personas (nombre, whatsapp, vip) VALUES ('Vera Vip', '51000000002', true) RETURNING id`)
	return e
}

func (e *entorno) exec(sql string, args ...any) {
	e.t.Helper()
	if _, err := e.db.Exec(e.ctx, sql, args...); err != nil {
		e.t.Fatalf("%s: %v", sql, err)
	}
}

func (e *entorno) escalar(sql string, args ...any) int {
	e.t.Helper()
	var v int
	if err := e.db.QueryRow(e.ctx, sql, args...).Scan(&v); err != nil {
		e.t.Fatalf("%s: %v", sql, err)
	}
	return v
}

func (e *entorno) en(t time.Time) { e.reloj.Fijar(t) }

// activarReglas pone todas las reglas vigentes en modo activo (nacen en sombra).
func (e *entorno) activarReglas() {
	e.t.Helper()
	e.exec(`UPDATE escalamiento_reglas SET modo = 'activo'`)
}

func (e *entorno) crear(mod func(*incidencia.EntradaCrear)) *incidencia.Resultado {
	e.t.Helper()
	in := incidencia.EntradaCrear{PersonaID: &e.pepe, Categoria: "correo", Impacto: "persona", Urgencia: "media", Titulo: "Outlook no abre"}
	if mod != nil {
		mod(&in)
	}
	r, err := e.svc.Crear(e.ctx, in)
	if err != nil {
		e.t.Fatalf("Crear: %v", err)
	}
	return r
}

func (e *entorno) vigilar(t time.Time) *Informe {
	e.t.Helper()
	inf, err := e.vig.Vigilar(e.ctx, t)
	if err != nil {
		e.t.Fatal(err)
	}
	if len(inf.Errores) > 0 {
		e.t.Fatalf("errores del vigía: %v", inf.Errores)
	}
	return inf
}

func (e *entorno) contar(sql string, args ...any) int { return e.escalar(sql, args...) }

// claves devuelve, ordenadas, las claves de las reglas que disparó el informe.
func claves(inf *Informe) []string {
	var out []string
	for _, d := range inf.Disparos {
		out = append(out, d.Numero+"/"+d.ReglaClave)
	}
	sort.Strings(out)
	return out
}
