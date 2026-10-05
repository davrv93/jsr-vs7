package escala

import (
	"sort"
	"testing"
	"time"

	"jsrbot/backend/internal/incidencia"
)

type paso struct {
	t time.Time
	f func()
}

// El vigía en vivo (un tic cada 5 minutos) y la reproducción histórica deben ver lo mismo:
// los mismos pares (incidencia, regla). Es la prueba de que Reproducir sirve para medir una
// regla nueva contra el pasado.
func TestReproducirCoincideConElVigiaEnVivo(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()
	var pasos []paso
	en := func(t time.Time, f func()) { pasos = append(pasos, paso{t, f}) }
	check := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	// Cada escenario guarda su id para actuar después.
	ids := map[string]*incidencia.Incidencia{}
	tecnicoDe := func(clave string) incidencia.Actor {
		got, err := e.svc.Obtener(e.ctx, ids[clave].ID)
		check(err)
		return incidencia.ActorTecnico(*got.TecnicoID)
	}
	crear := func(clave string, mod func(*incidencia.EntradaCrear)) func() {
		return func() { ids[clave] = e.crear(mod).Incidencia }
	}
	responder := func(clave string) func() {
		return func() {
			_, err := e.svc.Responder(e.ctx, ids[clave].ID, incidencia.EntradaResponder{Texto: "ok", Actor: tecnicoDe(clave)})
			check(err)
		}
	}
	resolver := func(clave string) func() {
		return func() {
			_, err := e.svc.Resolver(e.ctx, ids[clave].ID, incidencia.EntradaResolver{Actor: tecnicoDe(clave)})
			check(err)
		}
	}
	reabrir := func(clave string) func() {
		return func() {
			_, err := e.svc.Reabrir(e.ctx, ids[clave].ID, incidencia.EntradaReabrir{Actor: incidencia.ActorUsuario(e.pepe)})
			check(err)
		}
	}
	pausar := func(clave string) func() {
		return func() {
			_, err := e.svc.Pausar(e.ctx, ids[clave].ID, incidencia.EntradaPausar{Motivo: "espera_usuario", Actor: tecnicoDe(clave)})
			check(err)
		}
	}
	reanudar := func(clave string) func() {
		return func() {
			_, err := e.svc.Reanudar(e.ctx, ids[clave].ID, incidencia.EntradaReanudar{Actor: incidencia.ActorUsuario(e.pepe)})
			check(err)
		}
	}

	// A: P3 que nadie atiende (lunes 09:00): 75 y 100 % de la respuesta y 75 % de la resolución el miércoles.
	en(L(2026, 10, 5, 9, 0), crear("A", nil))
	// B: P2 respondida a tiempo y resuelta: no dispara nada de SLA.
	en(L(2026, 10, 5, 9, 5), crear("B", func(in *incidencia.EntradaCrear) { in.Impacto, in.Urgencia = "sede", "alta" }))
	en(L(2026, 10, 5, 9, 20), responder("B"))
	en(L(2026, 10, 5, 10, 0), resolver("B"))
	// C: creada el lunes a las 17:55, sin responder: los plazos corren el martes.
	en(L(2026, 10, 5, 17, 55), crear("C", nil))
	// D: P1 de noche, sin responder.
	en(L(2026, 10, 5, 20, 0), crear("D", func(in *incidencia.EntradaCrear) { in.Impacto, in.Urgencia = "organizacion", "critica" }))
	// E: queja después de abrir.
	en(L(2026, 10, 5, 9, 10), crear("E", nil))
	en(L(2026, 10, 5, 9, 40), func() {
		_, err := e.svc.RegistrarQueja(e.ctx, ids["E"].ID, incidencia.EntradaQueja{Actor: incidencia.ActorUsuario(e.pepe)})
		check(err)
	})
	en(L(2026, 10, 5, 9, 45), responder("E"))
	// F: VIP.
	en(L(2026, 10, 5, 10, 0), crear("F", func(in *incidencia.EntradaCrear) { in.PersonaID = &e.vera }))
	en(L(2026, 10, 5, 10, 10), responder("F"))
	// G: dos reaperturas.
	en(L(2026, 10, 5, 9, 15), crear("G", nil))
	en(L(2026, 10, 5, 9, 20), responder("G"))
	en(L(2026, 10, 5, 9, 30), resolver("G"))
	en(L(2026, 10, 5, 9, 40), reabrir("G"))
	en(L(2026, 10, 5, 9, 45), responder("G"))
	en(L(2026, 10, 5, 9, 50), resolver("G"))
	en(L(2026, 10, 5, 10, 5), reabrir("G"))
	en(L(2026, 10, 5, 10, 10), responder("G"))
	en(L(2026, 10, 5, 10, 20), resolver("G"))
	// H: guía agotada.
	en(L(2026, 10, 5, 11, 0), crear("H", func(in *incidencia.EntradaCrear) { in.Motivo = "guia_agotada" }))
	en(L(2026, 10, 5, 11, 10), responder("H"))
	// I: con pausa larga (lunes 10:00 a martes 09:00): corre el 75 % de la resolución.
	en(L(2026, 10, 5, 9, 30), crear("I", nil))
	en(L(2026, 10, 5, 9, 35), responder("I"))
	en(L(2026, 10, 5, 10, 0), pausar("I"))
	en(L(2026, 10, 6, 9, 0), reanudar("I"))
	// J: P4 que se resuelve rápido.
	en(L(2026, 10, 5, 14, 0), crear("J", func(in *incidencia.EntradaCrear) { in.Impacto, in.Urgencia = "persona", "baja" }))
	en(L(2026, 10, 5, 14, 10), responder("J"))
	en(L(2026, 10, 5, 14, 30), resolver("J"))

	inicio, fin := L(2026, 10, 5, 8, 0), L(2026, 10, 7, 12, 0)
	sort.SliceStable(pasos, func(i, j int) bool { return pasos[i].t.Before(pasos[j].t) })

	// Mezcla pasos y tics cada 5 minutos; en un mismo instante, primero los pasos.
	i := 0
	for tic := inicio; !tic.After(fin); tic = tic.Add(5 * time.Minute) {
		for i < len(pasos) && !pasos[i].t.After(tic) {
			e.en(pasos[i].t)
			pasos[i].f()
			i++
		}
		e.en(tic)
		e.vigilar(tic)
	}
	if i != len(pasos) {
		t.Fatalf("quedaron %d pasos sin ejecutar", len(pasos)-i)
	}

	// Lo que registró el vigía en vivo.
	rows, err := e.db.Query(e.ctx, `SELECT i.numero, esc.regla_clave FROM escalamientos esc JOIN incidencias i ON i.id = esc.incidencia_id`)
	check(err)
	vivo := map[string]bool{}
	for rows.Next() {
		var n, r string
		check(rows.Scan(&n, &r))
		vivo[n+"/"+r] = true
	}
	rows.Close()

	// Lo que dice la reproducción sobre la misma ventana.
	ds, err := e.vig.Reproducir(e.ctx, inicio, fin)
	check(err)
	repro := map[string]bool{}
	for _, d := range ds {
		repro[d.Numero+"/"+d.ReglaClave] = true
		if !d.YaRegistrada {
			t.Errorf("%s/%s: la reproducción dice que dispara pero el vigía no lo registró", d.Numero, d.ReglaClave)
		}
		if len(d.Acciones) == 0 || d.Acciones[0].Resultado != "plan" {
			t.Errorf("la reproducción solo planea: %+v", d)
		}
	}
	if len(vivo) < 12 {
		t.Fatalf("el escenario debía producir muchos disparos y produjo %d: %v", len(vivo), vivo)
	}
	for k := range vivo {
		if !repro[k] {
			t.Errorf("el vigía en vivo disparó %s y la reproducción no", k)
		}
	}
	for k := range repro {
		if !vivo[k] {
			t.Errorf("la reproducción dice %s y el vigía en vivo no lo disparó", k)
		}
	}
	// Orden cronológico.
	for j := 1; j < len(ds); j++ {
		if ds[j].Cuando.Before(ds[j-1].Cuando) {
			t.Fatal("la reproducción debe salir en orden cronológico")
		}
	}
	// Una ventana más corta recorta la lista; fuera de rango, vacía; y no escribe nada.
	antes := e.contar(`SELECT count(*) FROM escalamientos`)
	cortos, err := e.vig.Reproducir(e.ctx, L(2026, 10, 5, 9, 0), L(2026, 10, 5, 9, 59))
	check(err)
	if len(cortos) == 0 || len(cortos) >= len(ds) {
		t.Errorf("ventana corta: %d de %d", len(cortos), len(ds))
	}
	if vacios, _ := e.vig.Reproducir(e.ctx, L(2026, 1, 1, 0, 0), L(2026, 1, 2, 0, 0)); len(vacios) != 0 {
		t.Errorf("antes de todo no hay nada: %v", vacios)
	}
	if e.contar(`SELECT count(*) FROM escalamientos`) != antes {
		t.Error("Reproducir no debe escribir")
	}

	// Qué pasaría con otra regla: umbral del 50 % de la respuesta.
	nuevas := []Regla{{Clave: "sla_50_respuesta", Version: 1, Modo: ModoSombra,
		Condicion: Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 50}, Acciones: []Accion{{Tipo: AccAvisarTecnico}}}}
	hip, err := e.vig.ReproducirConReglas(e.ctx, inicio, fin, nuevas)
	check(err)
	if len(hip) == 0 {
		t.Error("la regla hipotética debía disparar para A, C y D como mínimo")
	}
	for _, d := range hip {
		if d.YaRegistrada {
			t.Error("una regla hipotética no está registrada")
		}
	}
}
