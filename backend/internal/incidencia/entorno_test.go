package incidencia

import (
	"context"
	"encoding/json"
	"testing"
	"time"

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

// L arma un instante en hora de Lima.
func L(y int, m time.Month, d, h, mi int) time.Time { return time.Date(y, m, d, h, mi, 0, 0, lima) }

// entorno es una base con configuración por defecto, técnicos, personas y un reloj manual.
type entorno struct {
	t     *testing.T
	ctx   context.Context
	db    *store.DB
	svc   *Servicio
	reloj *RelojManual

	mesa, redes, infra int // grupos
	ana, beto          int // Mesa N1 (en turno lun-vie 08:30-18:00)
	dan                int // Infraestructura
	eli                int // Redes
	gabi               int // Infraestructura; guardia el fin de semana
	pepe, vera         int // personas (vera es VIP)
}

func nuevoEntorno(t *testing.T) *entorno {
	t.Helper()
	db := storetest.NuevaBDConConfig(t)
	e := &entorno{t: t, ctx: context.Background(), db: db}
	e.reloj = NuevoRelojManual(L(2026, 10, 5, 9, 0)) // lunes 09:00 en Lima
	e.svc = Nuevo(db, ConReloj(e.reloj.Ahora))

	e.mesa = e.escalar(`SELECT id FROM grupos WHERE nombre = 'Mesa N1'`)
	e.redes = e.escalar(`SELECT id FROM grupos WHERE nombre = 'Redes'`)
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
	e.dan, e.eli, e.gabi = tecnico("Dan", e.infra), tecnico("Eli", e.redes), tecnico("Gabi", e.infra)
	e.exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, e.mesa, e.ana)
	e.exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, e.infra, e.dan)
	e.exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, e.redes, e.eli)
	// Guardia de Gabi: desde el viernes 9-oct 18:00 hasta el lunes 12-oct 08:30.
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

// crear abre una incidencia con valores por defecto razonables.
func (e *entorno) crear(mod func(*EntradaCrear)) *Resultado {
	e.t.Helper()
	in := EntradaCrear{PersonaID: &e.pepe, Categoria: "correo", Impacto: "persona", Urgencia: "media", Titulo: "Outlook no abre"}
	if mod != nil {
		mod(&in)
	}
	r, err := e.svc.Crear(e.ctx, in)
	if err != nil {
		e.t.Fatalf("Crear: %v", err)
	}
	return r
}

func (e *entorno) obtener(id int64) *Incidencia {
	e.t.Helper()
	inc, err := e.svc.Obtener(e.ctx, id)
	if err != nil {
		e.t.Fatal(err)
	}
	return inc
}

func (e *entorno) tipos(id int64) []string {
	e.t.Helper()
	evs, err := e.svc.Eventos(e.ctx, id)
	if err != nil {
		e.t.Fatal(err)
	}
	var out []string
	for _, ev := range evs {
		out = append(out, ev.Tipo)
	}
	return out
}

func (e *entorno) contar(sql string, args ...any) int { return e.escalar(sql, args...) }

// leerOutbox devuelve los payloads de una tabla del outbox, en orden de inserción.
func (e *entorno) leerOutbox(tabla string) []map[string]any {
	e.t.Helper()
	rows, err := e.db.Query(e.ctx, `SELECT clave, payload FROM outbox_analitica WHERE tabla = $1 ORDER BY id`, tabla)
	if err != nil {
		e.t.Fatal(err)
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var clave string
		var raw []byte
		if err := rows.Scan(&clave, &raw); err != nil {
			e.t.Fatal(err)
		}
		m := map[string]any{}
		if err := json.Unmarshal(raw, &m); err != nil {
			e.t.Fatal(err)
		}
		m["__clave"] = clave
		out = append(out, m)
	}
	return out
}

// llevarA deja una incidencia nueva en el estado pedido por el camino válido. La incidencia se
// crea con un técnico en turno (lunes 09:00).
func (e *entorno) llevarA(estado Estado) *Incidencia {
	e.t.Helper()
	e.en(L(2026, 10, 5, 9, 0))
	r := e.crear(nil)
	id := r.Incidencia.ID
	tec := ActorTecnico(*r.Incidencia.TecnicoID)
	paso := func(f func() error) {
		e.t.Helper()
		e.reloj.Avanzar(time.Minute)
		if err := f(); err != nil {
			e.t.Fatalf("llevarA(%s): %v", estado, err)
		}
	}
	switch estado {
	case Nueva:
		// Una incidencia sin técnico: se crea fuera de turno.
		e.en(L(2026, 10, 10, 10, 0))
		return e.crear(nil).Incidencia
	case Asignada:
	case EnCurso, EsperaUsuario, EsperaTercero, Resuelta, Cerrada, Reabierta:
		paso(func() error {
			_, err := e.svc.Responder(e.ctx, id, EntradaResponder{Texto: "Lo reviso", Actor: tec})
			return err
		})
	}
	switch estado {
	case EsperaUsuario:
		paso(func() error {
			_, err := e.svc.Pausar(e.ctx, id, EntradaPausar{Motivo: "espera_usuario", Actor: tec})
			return err
		})
	case EsperaTercero:
		paso(func() error {
			_, err := e.svc.Pausar(e.ctx, id, EntradaPausar{Motivo: "espera_tercero", Actor: tec})
			return err
		})
	case Resuelta, Cerrada, Reabierta:
		paso(func() error {
			_, err := e.svc.Resolver(e.ctx, id, EntradaResolver{Solucion: "Listo", Actor: tec})
			return err
		})
		switch estado {
		case Cerrada:
			paso(func() error {
				_, err := e.svc.Cerrar(e.ctx, id, EntradaCerrar{Motivo: CierreConfirmado, Actor: ActorUsuario(e.pepe)})
				return err
			})
		case Reabierta:
			paso(func() error {
				_, err := e.svc.Reabrir(e.ctx, id, EntradaReabrir{Motivo: "sigue igual", Actor: ActorUsuario(e.pepe)})
				return err
			})
		}
	}
	inc := e.obtener(id)
	if inc.Estado != estado {
		e.t.Fatalf("llevarA(%s) terminó en %s", estado, inc.Estado)
	}
	return inc
}
