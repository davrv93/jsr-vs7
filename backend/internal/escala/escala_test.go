package escala

import (
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

func TestEvaluarCondiciones(t *testing.T) {
	resp := func(pct float64) sla.Estado {
		return sla.Estado{LimiteMin: 100, Porcentaje: pct, RestanteMin: 100 - pct}
	}
	ahora := time.Now()
	casos := []struct {
		nombre string
		c      Condicion
		f      Foto
		quiere bool
	}{
		{"sla 75 respuesta: 74 % no", Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 75}, Foto{Respuesta: resp(74)}, false},
		{"sla 75 respuesta: 75 % sí", Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 75}, Foto{Respuesta: resp(75)}, true},
		{"sla 75 respuesta: ya respondida no aplica", Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 75}, Foto{Respuesta: resp(90), PrimeraRespuesta: &ahora}, false},
		{"sla 100 resolución: 100 % sí", Condicion{Tipo: CondSLA, Metrica: "resolucion", UmbralPct: 100}, Foto{Resolucion: resp(100)}, true},
		{"sla 100 resolución: respondida igual aplica", Condicion{Tipo: CondSLA, Metrica: "resolucion", UmbralPct: 100}, Foto{Resolucion: resp(120), PrimeraRespuesta: &ahora}, true},
		{"sla sin límite no dispara", Condicion{Tipo: CondSLA, Metrica: "resolucion", UmbralPct: 75}, Foto{Resolucion: sla.Estado{Porcentaje: 500}}, false},
		{"sla con métrica desconocida", Condicion{Tipo: CondSLA, Metrica: "rara", UmbralPct: 75}, Foto{Respuesta: resp(99)}, false},
		{"prioridad P1 sí", Condicion{Tipo: CondPrioridad, Valor: "P1"}, Foto{Prioridad: "P1"}, true},
		{"prioridad P1 no", Condicion{Tipo: CondPrioridad, Valor: "P1"}, Foto{Prioridad: "P2"}, false},
		{"reapertura 1 no alcanza", Condicion{Tipo: CondReaperturas, Min: 2}, Foto{Reaperturas: 1}, false},
		{"reapertura 2 sí", Condicion{Tipo: CondReaperturas, Min: 2}, Foto{Reaperturas: 2}, true},
		{"reapertura 3 también", Condicion{Tipo: CondReaperturas, Min: 2}, Foto{Reaperturas: 3}, true},
		{"queja sí", Condicion{Tipo: CondQueja}, Foto{Queja: true}, true},
		{"queja no", Condicion{Tipo: CondQueja}, Foto{}, false},
		{"vip sí", Condicion{Tipo: CondVIP}, Foto{VIP: true}, true},
		{"guía agotada sí", Condicion{Tipo: CondGuiaAgotada}, Foto{GuiaAgotada: true}, true},
		{"guía agotada no", Condicion{Tipo: CondGuiaAgotada}, Foto{}, false},
		{"condición desconocida", Condicion{Tipo: "magia"}, Foto{Queja: true, VIP: true}, false},
	}
	for _, tc := range casos {
		if got, _ := Evaluar(tc.c, tc.f); got != tc.quiere {
			t.Errorf("%s: = %v", tc.nombre, got)
		}
	}
	// El detalle lleva el porcentaje.
	if ok, d := Evaluar(Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 75}, Foto{Respuesta: resp(80.04)}); !ok || d["porcentaje"] != 80.0 {
		t.Errorf("detalle = %v", d)
	}
}

func TestValidarRegla(t *testing.T) {
	buena := Regla{Clave: "x", Modo: ModoSombra, Condicion: Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 75}, Acciones: []Accion{{Tipo: AccAvisarTecnico}}}
	if err := buena.Validar(); err != nil {
		t.Fatal(err)
	}
	malas := []Regla{
		{Clave: "", Modo: ModoSombra},
		{Clave: "x", Modo: "tal vez", Condicion: buena.Condicion},
		{Clave: "x", Modo: ModoActivo, Condicion: Condicion{Tipo: CondSLA, Metrica: "otra", UmbralPct: 75}},
		{Clave: "x", Modo: ModoActivo, Condicion: Condicion{Tipo: CondSLA, Metrica: "respuesta"}},
		{Clave: "x", Modo: ModoActivo, Condicion: Condicion{Tipo: CondPrioridad}},
		{Clave: "x", Modo: ModoActivo, Condicion: Condicion{Tipo: CondReaperturas}},
		{Clave: "x", Modo: ModoActivo, Condicion: Condicion{Tipo: "magia"}},
		{Clave: "x", Modo: ModoActivo, Condicion: buena.Condicion, Acciones: []Accion{{Tipo: "teletransportar"}}},
	}
	for i, r := range malas {
		if err := r.Validar(); err == nil {
			t.Errorf("regla mala %d debería fallar", i)
		}
	}
}

func TestReglasSembradasSonValidasYEstanEnSombra(t *testing.T) {
	e := nuevoEntorno(t)
	reglas, err := ReglasVigentes(e.ctx, e.db)
	if err != nil {
		t.Fatal(err)
	}
	if len(reglas) != len(store.ReglasDefecto()) {
		t.Fatalf("%d reglas vigentes", len(reglas))
	}
	vistas := []string{}
	for _, r := range reglas {
		if err := r.Validar(); err != nil {
			t.Errorf("%s: %v", r.Clave, err)
		}
		if r.Modo != ModoSombra || r.Version != 1 {
			t.Errorf("%s nace en %s v%d", r.Clave, r.Modo, r.Version)
		}
		vistas = append(vistas, r.Clave)
	}
	sort.Strings(vistas)
	want := []string{"guia_agotada", "p1_creada", "queja", "reapertura_2", "sla_100_resolucion", "sla_100_respuesta", "sla_75_resolucion", "sla_75_respuesta", "vip"}
	if !reflect.DeepEqual(vistas, want) {
		t.Errorf("reglas = %v", vistas)
	}
}

// En sombra el vigía solo registra: ni avisos, ni eventos, ni escalamientos reales.
func TestVigiaEnSombraSoloRegistra(t *testing.T) {
	e := nuevoEntorno(t)
	r := e.crear(nil) // P3 lunes 09:00: respuesta 120 min
	inc := r.Incidencia
	antesEventos := e.contar(`SELECT count(*) FROM incidencia_eventos`)

	// A los 89 min no hay nada; a los 90 (75 %) dispara sla_75_respuesta.
	if inf := e.vigilar(L(2026, 10, 5, 10, 29)); len(inf.Disparos) != 0 || inf.Revisadas != 1 {
		t.Fatalf("a los 89 min: %+v", inf)
	}
	inf := e.vigilar(L(2026, 10, 5, 10, 30))
	if got := claves(inf); !reflect.DeepEqual(got, []string{inc.Numero + "/sla_75_respuesta"}) {
		t.Fatalf("disparos = %v", got)
	}
	d := inf.Disparos[0]
	if d.Modo != ModoSombra || d.Ejecutada || len(d.Acciones) != 1 || d.Acciones[0].Resultado != "plan" ||
		d.Acciones[0].DestinatarioTipo != store.DestTecnico || *d.Acciones[0].DestinatarioID != *inc.TecnicoID {
		t.Errorf("disparo en sombra: %+v", d)
	}
	if d.Detalle["porcentaje"] != 75.0 {
		t.Errorf("detalle = %v", d.Detalle)
	}
	// Quedó el registro en escalamientos (modo sombra) y en decisiones, y nada más.
	if n := e.contar(`SELECT count(*) FROM escalamientos WHERE modo = 'sombra' AND regla_clave = 'sla_75_respuesta'`); n != 1 {
		t.Errorf("escalamientos en sombra = %d", n)
	}
	if n := e.contar(`SELECT count(*) FROM decisiones WHERE componente = 'escalamiento' AND modo = 'sombra'`); n != 1 {
		t.Errorf("decisiones en sombra = %d", n)
	}
	if e.contar(`SELECT count(*) FROM incidencia_eventos`) != antesEventos {
		t.Error("en sombra no debe haber eventos nuevos")
	}
	if e.contar(`SELECT count(*) FROM avisos WHERE plantilla LIKE 'sla%'`) != 0 {
		t.Error("en sombra no debe haber avisos")
	}
	// Al 100 % la regla de escalamiento también solo registra: la incidencia no se mueve.
	e.vigilar(L(2026, 10, 5, 11, 0))
	after, _ := e.svc.Obtener(e.ctx, inc.ID)
	if after.Grupo != "Mesa N1" || after.Escalamientos != 0 || after.Estado != incidencia.Asignada {
		t.Errorf("en sombra la incidencia no debe cambiar: %+v", after)
	}
	if n := e.contar(`SELECT count(*) FROM escalamientos WHERE incidencia_id = $1`, inc.ID); n != 2 {
		t.Errorf("escalamientos registrados = %d, quiere 2 (75 y 100)", n)
	}
}

func TestVigiaActivoEjecutaYEsIdempotente(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()
	inc := e.crear(nil).Incidencia // P3 lunes 09:00, asignada a Ana (carga igual, id menor)
	if *inc.TecnicoID != e.ana {
		t.Fatalf("técnico = %d", *inc.TecnicoID)
	}

	// 75 %: aviso al técnico.
	inf := e.vigilar(L(2026, 10, 5, 10, 30))
	if len(inf.Disparos) != 1 || !inf.Disparos[0].Ejecutada || inf.Disparos[0].Acciones[0].Resultado != "aviso_encolado" {
		t.Fatalf("75 %%: %+v", inf.Disparos)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'sla_75' AND destinatario_tipo = 'tecnico' AND destinatario_id = $2`, inc.ID, e.ana); n != 1 {
		t.Errorf("avisos sla_75 = %d", n)
	}
	var tipoAviso string
	_ = e.db.QueryRow(e.ctx, `SELECT tipo FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'aviso_sla'`, inc.ID).Scan(&tipoAviso)
	if tipoAviso != "aviso_sla" {
		t.Error("falta el evento aviso_sla")
	}
	// Idempotente: repetir (o reiniciar con otro vigía) no duplica nada.
	for i := 0; i < 3; i++ {
		if inf := Nuevo(e.svc).vigilarOK(t, e, L(2026, 10, 5, 10, 31+i)); len(inf.Disparos) != 0 {
			t.Fatalf("repetición %d disparó de nuevo: %+v", i, inf.Disparos)
		}
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE plantilla = 'sla_75'`); n != 1 {
		t.Errorf("avisos tras repetir = %d", n)
	}

	// 100 %: escala al siguiente nivel y avisa al responsable del grupo de origen (Ana).
	inf = e.vigilar(L(2026, 10, 5, 11, 0))
	if got := claves(inf); !reflect.DeepEqual(got, []string{inc.Numero + "/sla_100_respuesta"}) {
		t.Fatalf("100 %%: %v", got)
	}
	after, _ := e.svc.Obtener(e.ctx, inc.ID)
	if after.Grupo != "Infraestructura" || after.Escalamientos != 1 || after.Estado != incidencia.Asignada ||
		(*after.TecnicoID != e.dan && *after.TecnicoID != e.gabi) {
		t.Fatalf("tras escalar: %+v", after)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'sla_100' AND destinatario_tipo = 'responsable_grupo' AND destinatario_id = $2`, inc.ID, e.ana); n != 1 {
		t.Errorf("aviso al responsable del grupo de origen = %d", n)
	}
	if n := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'escalada'`, inc.ID); n != 1 {
		t.Errorf("eventos escalada = %d", n)
	}
	// El nuevo técnico recibió su aviso de asignación.
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'incidencia_asignada' AND destinatario_id = $2`, inc.ID, *after.TecnicoID); n != 1 {
		t.Errorf("aviso de asignación al nuevo técnico = %d", n)
	}
	// Repetir no escala dos veces.
	if inf := e.vigilar(L(2026, 10, 5, 11, 1)); len(inf.Disparos) != 0 {
		t.Errorf("repetición: %+v", inf.Disparos)
	}
	again, _ := e.svc.Obtener(e.ctx, inc.ID)
	if again.Escalamientos != 1 {
		t.Errorf("escalamientos = %d", again.Escalamientos)
	}
}

// vigilarOK es un atajo para usar otro Vigia (simula un reinicio del proceso).
func (v *Vigia) vigilarOK(t *testing.T, e *entorno, ahora time.Time) *Informe {
	t.Helper()
	inf, err := v.Vigilar(e.ctx, ahora)
	if err != nil || len(inf.Errores) > 0 {
		t.Fatalf("Vigilar: %v %v", err, inf.Errores)
	}
	return inf
}

// Dos vigías a la vez sobre las mismas incidencias: cada aviso y cada escalamiento sale una sola vez.
func TestDosVigiasSimultaneosNoDuplican(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()
	for i := 0; i < 4; i++ {
		e.crear(func(in *incidencia.EntradaCrear) { in.Titulo = fmt.Sprintf("caso %d", i) })
	}
	ahora := L(2026, 10, 5, 11, 0) // 100 % de la respuesta de las cuatro
	var wg sync.WaitGroup
	errs := make(chan error, 6)
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v := Nuevo(e.svc)
			inf, err := v.Vigilar(e.ctx, ahora)
			if err == nil && len(inf.Errores) > 0 {
				err = errors.New(strings.Join(inf.Errores, "; "))
			}
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	// 4 incidencias × (sla_75_respuesta + sla_100_respuesta) = 8 escalamientos, ni uno más.
	if n := e.contar(`SELECT count(*) FROM escalamientos`); n != 8 {
		t.Errorf("escalamientos = %d, quiere 8", n)
	}
	if n := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE tipo = 'escalada'`); n != 4 {
		t.Errorf("escaladas = %d, quiere 4", n)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE plantilla IN ('sla_75', 'sla_100')`); n != 8 {
		t.Errorf("avisos de SLA = %d, quiere 8 (4 al técnico y 4 al responsable)", n)
	}
	if n := e.contar(`SELECT count(*) FROM (SELECT clave FROM avisos GROUP BY clave HAVING count(*) > 1) x`); n != 0 {
		t.Errorf("hay avisos con clave repetida")
	}
}

func TestP1CreadaAvisaALaGuardiaYAlSupervisor(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()
	e.en(L(2026, 10, 10, 3, 0)) // sábado de madrugada: guardia de Gabi
	inc := e.crear(func(in *incidencia.EntradaCrear) { in.Impacto, in.Urgencia = "organizacion", "critica" }).Incidencia
	if inc.Prioridad != "P1" {
		t.Fatal(inc.Prioridad)
	}
	inf := e.vigilar(L(2026, 10, 10, 3, 1))
	if got := claves(inf); !reflect.DeepEqual(got, []string{inc.Numero + "/p1_creada"}) {
		t.Fatalf("disparos = %v", got)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'p1_creada' AND destinatario_tipo = 'guardia' AND destinatario_id = $2`, inc.ID, e.gabi); n != 1 {
		t.Errorf("aviso a la guardia = %d", n)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'p1_creada' AND destinatario_tipo = 'supervisor' AND destinatario_id = $2`, inc.ID, e.dan); n != 1 {
		t.Errorf("aviso al supervisor = %d", n)
	}
	// Sin guardia vigente, avisar_guardia cae en el supervisor y lo dice.
	e.en(L(2026, 10, 11, 20, 0))
	e.exec(`DELETE FROM guardias`)
	inc2 := e.crear(func(in *incidencia.EntradaCrear) { in.Impacto, in.Urgencia = "organizacion", "critica" }).Incidencia
	inf = e.vigilar(L(2026, 10, 11, 20, 1))
	var d *Disparo
	for i := range inf.Disparos {
		if inf.Disparos[i].Numero == inc2.Numero && inf.Disparos[i].ReglaClave == "p1_creada" {
			d = &inf.Disparos[i]
		}
	}
	if d == nil || d.Acciones[0].Nota != "sin_guardia" || d.Acciones[0].DestinatarioTipo != store.DestSupervisor {
		t.Errorf("sin guardia: %+v", d)
	}
}

func TestReaperturaDosQuejaVIPYGuiaAgotada(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()

	// Reapertura por segunda vez: escala y avisa al supervisor.
	r := e.crear(nil)
	inc, tec := r.Incidencia, incidencia.ActorTecnico(*r.Incidencia.TecnicoID)
	usuario := incidencia.ActorUsuario(e.pepe)
	paso := func(f func() error) {
		t.Helper()
		e.reloj.Avanzar(5 * time.Minute)
		if err := f(); err != nil {
			t.Fatal(err)
		}
	}
	for i := 1; i <= 2; i++ {
		paso(func() error {
			_, err := e.svc.Responder(e.ctx, inc.ID, incidencia.EntradaResponder{Texto: "ok", Actor: tec})
			return err
		})
		paso(func() error {
			_, err := e.svc.Resolver(e.ctx, inc.ID, incidencia.EntradaResolver{Actor: tec})
			return err
		})
		paso(func() error {
			_, err := e.svc.Reabrir(e.ctx, inc.ID, incidencia.EntradaReabrir{Actor: usuario})
			return err
		})
		inf := e.vigilar(e.reloj.Ahora())
		quiere := i == 2
		hay := false
		for _, d := range inf.Disparos {
			if d.ReglaClave == "reapertura_2" {
				hay = true
			}
		}
		if hay != quiere {
			t.Fatalf("tras la reapertura %d: reapertura_2 disparó = %v", i, hay)
		}
	}
	got, _ := e.svc.Obtener(e.ctx, inc.ID)
	if got.Escalamientos != 1 || got.Grupo != "Infraestructura" {
		t.Errorf("la segunda reapertura debía escalar: %+v", got)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'reapertura_2' AND destinatario_tipo = 'supervisor'`, inc.ID); n != 1 {
		t.Errorf("aviso al supervisor por reapertura = %d", n)
	}

	// Queja explícita → aviso al supervisor.
	e.en(L(2026, 10, 6, 10, 0))
	q := e.crear(func(in *incidencia.EntradaCrear) { in.Titulo = "Queja"; in.Queja = true }).Incidencia
	inf := e.vigilar(L(2026, 10, 6, 10, 1))
	if !tiene(inf, q.Numero, "queja") {
		t.Errorf("queja al crear: %v", claves(inf))
	}
	q2 := e.crear(func(in *incidencia.EntradaCrear) { in.Titulo = "Se queja después" }).Incidencia
	e.vigilar(L(2026, 10, 6, 10, 2))
	if _, err := e.svc.RegistrarQueja(e.ctx, q2.ID, incidencia.EntradaQueja{Texto: "Esto es inaceptable", Actor: usuario}); err != nil {
		t.Fatal(err)
	}
	if inf := e.vigilar(L(2026, 10, 6, 10, 3)); !tiene(inf, q2.Numero, "queja") {
		t.Errorf("queja posterior: %v", claves(inf))
	}

	// VIP: prioridad mínima P2 (la pone Crear) y aviso al supervisor.
	v := e.crear(func(in *incidencia.EntradaCrear) { in.PersonaID = &e.vera; in.Impacto, in.Urgencia = "persona", "baja" }).Incidencia
	if v.Prioridad != "P2" {
		t.Errorf("VIP: %s", v.Prioridad)
	}
	if inf := e.vigilar(L(2026, 10, 6, 10, 4)); !tiene(inf, v.Numero, "vip") {
		t.Errorf("vip: %v", claves(inf))
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'vip' AND destinatario_tipo = 'supervisor'`, v.ID); n != 1 {
		t.Errorf("aviso VIP = %d", n)
	}

	// Guía agotada: deja una nota interna, no un aviso.
	g := e.crear(func(in *incidencia.EntradaCrear) { in.Motivo = "guia_agotada" }).Incidencia
	if inf := e.vigilar(L(2026, 10, 6, 10, 5)); !tiene(inf, g.Numero, "guia_agotada") {
		t.Errorf("guia_agotada: %v", claves(inf))
	}
	if n := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'comentario_interno'`, g.ID); n != 1 {
		t.Errorf("nota de guía agotada = %d", n)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'guia_agotada'`, g.ID); n != 0 {
		t.Errorf("guía agotada no avisa: %d", n)
	}
}

func tiene(inf *Informe, numero, regla string) bool {
	for _, d := range inf.Disparos {
		if d.Numero == numero && d.ReglaClave == regla {
			return true
		}
	}
	return false
}

func TestSombraAActivoEjecutaLoPendiente(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.crear(func(in *incidencia.EntradaCrear) { in.Impacto, in.Urgencia = "organizacion", "critica" }).Incidencia // P1 lunes 09:00
	e.vigilar(L(2026, 10, 5, 9, 1))                                                                                      // sombra: registra p1_creada
	if n := e.contar(`SELECT count(*) FROM avisos WHERE plantilla = 'p1_creada'`); n != 0 {
		t.Fatal("en sombra no hay avisos")
	}
	if err := CambiarModo(e.ctx, e.db, "p1_creada", 1, ModoActivo); err != nil {
		t.Fatal(err)
	}
	inf := e.vigilar(L(2026, 10, 5, 9, 2))
	if !tiene(inf, inc.Numero, "p1_creada") || !inf.Disparos[0].Ejecutada {
		t.Fatalf("al activar debe ejecutar lo registrado en sombra: %+v", inf.Disparos)
	}
	if n := e.contar(`SELECT count(*) FROM avisos WHERE plantilla = 'p1_creada'`); n == 0 {
		t.Error("tras activar debe haber avisos")
	}
	if n := e.contar(`SELECT count(*) FROM escalamientos WHERE regla_clave = 'p1_creada' AND modo = 'activo'`); n != 1 {
		t.Errorf("el registro debe quedar en modo activo: %d", n)
	}
	if inf := e.vigilar(L(2026, 10, 5, 9, 3)); tiene(inf, inc.Numero, "p1_creada") {
		t.Error("no debe ejecutarse dos veces")
	}
	if err := CambiarModo(e.ctx, e.db, "no_existe", 1, ModoActivo); !errors.Is(err, store.ErrNoEncontrado) {
		t.Errorf("regla inexistente: %v", err)
	}
	if err := CambiarModo(e.ctx, e.db, "p1_creada", 1, "a medias"); err == nil {
		t.Error("modo inválido debe fallar")
	}
}

func TestReglasVersionadas(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.crear(nil).Incidencia
	e.vigilar(L(2026, 10, 5, 10, 30)) // v1 de sla_75_respuesta (sombra) registra
	// v2 con umbral 50 %: la vigente pasa a ser la v2 y se evalúa aparte.
	v, err := PublicarVersion(e.ctx, e.db, Regla{Clave: "sla_75_respuesta", Modo: ModoActivo,
		Condicion: Condicion{Tipo: CondSLA, Metrica: "respuesta", UmbralPct: 50}, Acciones: []Accion{{Tipo: AccAvisarTecnico}}})
	if err != nil || v != 2 {
		t.Fatalf("PublicarVersion = %d %v", v, err)
	}
	vigentes, _ := ReglasVigentes(e.ctx, e.db)
	for _, r := range vigentes {
		if r.Clave == "sla_75_respuesta" && (r.Version != 2 || r.Modo != ModoActivo) {
			t.Errorf("la vigente debe ser v2 activa: %+v", r)
		}
	}
	inf := e.vigilar(L(2026, 10, 5, 10, 31))
	if !tiene(inf, inc.Numero, "sla_75_respuesta") || inf.Disparos[0].ReglaVersion != 2 || !inf.Disparos[0].Ejecutada {
		t.Fatalf("v2 debe disparar aunque v1 ya lo hizo: %+v", inf.Disparos)
	}
	if n := e.contar(`SELECT count(*) FROM escalamientos WHERE incidencia_id = $1 AND regla_clave = 'sla_75_respuesta'`, inc.ID); n != 2 {
		t.Errorf("v1 y v2 deben quedar registradas: %d", n)
	}
	// Una regla inválida no se publica.
	if _, err := PublicarVersion(e.ctx, e.db, Regla{Clave: "mala", Modo: ModoActivo, Condicion: Condicion{Tipo: "magia"}}); err == nil {
		t.Error("regla inválida")
	}
	// Una regla desactivada no se evalúa.
	e.exec(`UPDATE escalamiento_reglas SET activa = false WHERE clave = 'queja'`)
	vig, _ := ReglasVigentes(e.ctx, e.db)
	for _, r := range vig {
		if r.Clave == "queja" {
			t.Error("una regla inactiva no es vigente")
		}
	}
}

func TestElVigiaIgnoraResueltasPausasYFuturas(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()
	r := e.crear(nil)
	inc, tec := r.Incidencia, incidencia.ActorTecnico(*r.Incidencia.TecnicoID)
	// Futuras: una incidencia creada después de «ahora» no se evalúa.
	if inf := e.vigilar(L(2026, 10, 5, 8, 0)); inf.Revisadas != 0 {
		t.Errorf("revisadas = %d", inf.Revisadas)
	}
	// Se responde a los 10 min; el plazo de respuesta ya no aplica y se pausa antes del 75 % de la resolución.
	e.en(L(2026, 10, 5, 9, 10))
	if _, err := e.svc.Responder(e.ctx, inc.ID, incidencia.EntradaResponder{Texto: "ok", Actor: tec}); err != nil {
		t.Fatal(err)
	}
	if inf := e.vigilar(L(2026, 10, 5, 11, 30)); len(inf.Disparos) != 0 {
		t.Errorf("respondida: no aplica sla de respuesta: %v", claves(inf))
	}
	// En pausa el reloj no avanza: el 75 % de 1440 min (1080 laborales) no llega nunca mientras espera.
	e.en(L(2026, 10, 5, 12, 0))
	if _, err := e.svc.Pausar(e.ctx, inc.ID, incidencia.EntradaPausar{Motivo: "espera_usuario", Actor: tec}); err != nil {
		t.Fatal(err)
	}
	if inf := e.vigilar(L(2026, 10, 9, 17, 0)); len(inf.Disparos) != 0 {
		t.Errorf("en pausa no debe disparar: %v", claves(inf))
	}
	// Resuelta: ya no se vigila.
	e.en(L(2026, 10, 9, 17, 10))
	if _, err := e.svc.Reanudar(e.ctx, inc.ID, incidencia.EntradaReanudar{Actor: incidencia.ActorUsuario(e.pepe)}); err != nil {
		t.Fatal(err)
	}
	e.en(L(2026, 10, 9, 17, 20))
	if _, err := e.svc.Resolver(e.ctx, inc.ID, incidencia.EntradaResolver{Actor: tec}); err != nil {
		t.Fatal(err)
	}
	if inf := e.vigilar(L(2026, 10, 30, 12, 0)); inf.Revisadas != 0 || len(inf.Disparos) != 0 {
		t.Errorf("una resuelta no se vigila: %+v", inf)
	}
}

func TestCicloReunePasosYAguantaErrores(t *testing.T) {
	e := nuevoEntorno(t)
	e.activarReglas()
	// Una incidencia en cola (sábado) que se asigna al llegar el turno, y una resuelta vieja que se cierra.
	e.en(L(2026, 10, 10, 10, 0))
	cola := e.crear(nil).Incidencia
	if cola.Estado != incidencia.Nueva {
		t.Fatal(cola.Estado)
	}
	e.en(L(2026, 10, 12, 9, 0))
	inf, err := e.vig.Ciclo(e.ctx, L(2026, 10, 12, 9, 0))
	if err != nil || len(inf.Errores) > 0 {
		t.Fatal(err, inf.Errores)
	}
	if len(inf.Asignadas) != 1 || inf.Asignadas[0] != cola.Numero {
		t.Errorf("asignadas = %v", inf.Asignadas)
	}
	// Sin cambios, el ciclo no hace nada nuevo (idempotente).
	e.en(L(2026, 10, 12, 9, 1))
	inf, _ = e.vig.Ciclo(e.ctx, L(2026, 10, 12, 9, 1))
	if len(inf.Asignadas) != 0 || len(inf.Cerradas) != 0 || len(inf.Disparos) != 0 {
		t.Errorf("segundo ciclo: %+v", inf)
	}
}

// Un plazo que se pasa deja el evento sla_vencido UNA vez y reescribe incidencias_tiempos con el
// veredicto «incumplida», aunque las reglas estén en sombra y nadie toque la incidencia.
func TestPlazoVencidoLlegaAClickHouseAunqueNadieTocaLaIncidencia(t *testing.T) {
	e := nuevoEntorno(t)                      // reglas en sombra
	inc := e.crear(nil).Incidencia            // P3 lunes 09:00: respuesta 120 min, resolución 1440 min
	filasTiempos := func() []map[string]any { // payloads de incidencias_tiempos de esta incidencia
		rows, err := e.db.Query(e.ctx, `SELECT payload FROM outbox_analitica WHERE tabla = 'incidencias_tiempos' AND (payload->>'incidencia_id')::bigint = $1 ORDER BY id`, inc.ID)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []map[string]any
		for rows.Next() {
			var m map[string]any
			if err := rows.Scan(&m); err != nil {
				t.Fatal(err)
			}
			out = append(out, m)
		}
		return out
	}
	antes := len(filasTiempos())
	if ultimo := filasTiempos()[antes-1]; ultimo["sla_respuesta_ok"] != nil {
		t.Fatalf("al crear el veredicto aún no aplica: %v", ultimo)
	}
	// Justo en el límite (120 min) todavía no es incumplida.
	if inf := e.vigilar(L(2026, 10, 5, 11, 0)); inf.Vencidos != 0 {
		t.Fatalf("en el límite no vence: %+v", inf)
	}
	inf := e.vigilar(L(2026, 10, 5, 11, 1))
	if inf.Vencidos != 1 {
		t.Fatalf("a los 121 min debe marcarse la respuesta vencida: %+v", inf)
	}
	ult := filasTiempos()
	if len(ult) != antes+1 || ult[len(ult)-1]["sla_respuesta_ok"] != float64(0) || ult[len(ult)-1]["sla_resolucion_ok"] != nil {
		t.Errorf("tras vencer la respuesta: %v", ult[len(ult)-1])
	}
	if n := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'sla_vencido' AND datos->>'metrica' = 'respuesta'`, inc.ID); n != 1 {
		t.Errorf("eventos sla_vencido = %d", n)
	}
	// Idempotente: pasadas siguientes no repiten ni reescriben.
	for i := 0; i < 3; i++ {
		if inf := e.vigilar(L(2026, 10, 5, 11, 2+i)); inf.Vencidos != 0 {
			t.Fatalf("repetición %d marcó de nuevo", i)
		}
	}
	if len(filasTiempos()) != antes+1 {
		t.Error("no debe reescribirse tiempos sin cambios")
	}
	// La resolución vence 1440 min laborales después (480 el lunes + 510 el martes + 450 el miércoles = 17:00).
	if inf := e.vigilar(L(2026, 10, 7, 16, 59)); inf.Vencidos != 0 {
		t.Fatalf("antes del límite de resolución: %+v", inf)
	}
	if inf := e.vigilar(L(2026, 10, 7, 17, 1)); inf.Vencidos != 1 {
		t.Fatalf("la resolución debía vencer: %+v", inf)
	}
	ult = filasTiempos()
	if ult[len(ult)-1]["sla_resolucion_ok"] != float64(0) || ult[len(ult)-1]["sla_respuesta_ok"] != float64(0) {
		t.Errorf("veredictos finales: %v", ult[len(ult)-1])
	}
	// Una incidencia respondida a tiempo no marca la respuesta.
	e.en(L(2026, 10, 8+1, 9, 0)) // viernes 9
	b := e.crear(nil).Incidencia
	e.en(L(2026, 10, 9, 9, 10))
	if _, err := e.svc.Responder(e.ctx, b.ID, incidencia.EntradaResponder{Texto: "ok", Actor: incidencia.ActorTecnico(*b.TecnicoID)}); err != nil {
		t.Fatal(err)
	}
	e.vigilar(L(2026, 10, 9, 12, 0))
	if n := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'sla_vencido'`, b.ID); n != 0 {
		t.Errorf("respondida a tiempo: %d marcas", n)
	}
}
