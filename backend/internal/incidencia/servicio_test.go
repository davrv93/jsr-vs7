package incidencia

import (
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"jsrbot/backend/internal/despacho"
	"jsrbot/backend/internal/store"
)

func iguales(a, b time.Time) bool { return a.Equal(b) }

func TestCrearPrioridadPorMatrizYVIP(t *testing.T) {
	e := nuevoEntorno(t)
	casos := []struct {
		nombre            string
		persona           *int
		impacto, urgencia string
		quiere, base      string
		vipAplicado       bool
	}{
		{"organización crítica", &e.pepe, "organizacion", "critica", "P1", "P1", false},
		{"sede alta", &e.pepe, "sede", "alta", "P2", "P2", false},
		{"área media", &e.pepe, "area", "media", "P3", "P3", false},
		{"persona baja", &e.pepe, "persona", "baja", "P4", "P4", false},
		{"VIP persona baja sube a P2", &e.vera, "persona", "baja", "P2", "P4", true},
		{"VIP área media sube a P2", &e.vera, "area", "media", "P2", "P3", true},
		{"VIP ya en P2 no cambia", &e.vera, "sede", "alta", "P2", "P2", false},
		{"VIP en P1 no baja", &e.vera, "organizacion", "critica", "P1", "P1", false},
	}
	for _, tc := range casos {
		t.Run(tc.nombre, func(t *testing.T) {
			r := e.crear(func(in *EntradaCrear) { in.PersonaID, in.Impacto, in.Urgencia = tc.persona, tc.impacto, tc.urgencia })
			if r.Incidencia.Prioridad != tc.quiere {
				t.Errorf("prioridad = %s, quiere %s", r.Incidencia.Prioridad, tc.quiere)
			}
			evs, _ := e.svc.Eventos(e.ctx, r.Incidencia.ID)
			creada := evs[0]
			if creada.Tipo != EvCreada || creada.Datos["prioridad_base"] != tc.base || creada.Datos["vip_minimo_aplicado"] != tc.vipAplicado {
				t.Errorf("evento creada = %+v", creada.Datos)
			}
		})
	}
}

func TestCrearValidaLaEntrada(t *testing.T) {
	e := nuevoEntorno(t)
	malas := map[string]func(*EntradaCrear){
		"sin título":        func(in *EntradaCrear) { in.Titulo = "  " },
		"tipo inválido":     func(in *EntradaCrear) { in.Tipo = "bicho" },
		"impacto inválido":  func(in *EntradaCrear) { in.Impacto = "planeta" },
		"urgencia inválida": func(in *EntradaCrear) { in.Urgencia = "ya" },
		"canal inválido":    func(in *EntradaCrear) { in.Canal = "paloma" },
		"actor inválido":    func(in *EntradaCrear) { in.Actor = Actor{Tipo: "alien"} },
		"persona fantasma":  func(in *EntradaCrear) { x := 99999; in.PersonaID = &x },
	}
	for nombre, mod := range malas {
		in := EntradaCrear{PersonaID: &e.pepe, Categoria: "correo", Titulo: "x"}
		mod(&in)
		if _, err := e.svc.Crear(e.ctx, in); !errors.Is(err, ErrInvalido) {
			t.Errorf("%s: err = %v, quiere ErrInvalido", nombre, err)
		}
	}
	if n := e.contar(`SELECT count(*) FROM incidencias`); n != 0 {
		t.Errorf("las entradas inválidas no deben dejar filas: %d", n)
	}
	// Una categoría desconocida cae en «otro»; los valores por defecto se aplican.
	r := e.crear(func(in *EntradaCrear) { in.Categoria = "magia"; in.Impacto, in.Urgencia = "", "" })
	if r.Incidencia.Categoria != "otro" || r.Incidencia.Impacto != "persona" || r.Incidencia.Urgencia != "media" || r.Incidencia.Prioridad != "P3" {
		t.Errorf("valores por defecto: %+v", r.Incidencia)
	}
}

func TestCrearAsignaCalculaVencimientosYDejaEventosYOutbox(t *testing.T) {
	e := nuevoEntorno(t)
	r := e.crear(func(in *EntradaCrear) { in.Impacto, in.Urgencia = "sede", "alta" }) // P2, lunes 09:00
	inc := r.Incidencia

	if inc.Prioridad != "P2" || inc.Estado != Asignada || inc.TecnicoID == nil || *inc.TecnicoID != e.ana {
		t.Fatalf("incidencia = %+v (desempate: Ana, id menor)", inc)
	}
	if r.Despacho == nil || r.Despacho.Motivo != despacho.MotivoDesempate {
		t.Errorf("despacho = %+v", r.Despacho)
	}
	if !strings.HasPrefix(inc.Numero, "INC-") || inc.TokenPublico == "" {
		t.Errorf("número/token: %s %s", inc.Numero, inc.TokenPublico)
	}
	// P2: respuesta 30 min y resolución 480 min laborales desde las 09:00.
	if inc.VenceRespuestaEn == nil || !iguales(*inc.VenceRespuestaEn, L(2026, 10, 5, 9, 30)) {
		t.Errorf("vence_respuesta_en = %v", inc.VenceRespuestaEn)
	}
	if inc.VenceResolucionEn == nil || !iguales(*inc.VenceResolucionEn, L(2026, 10, 5, 18, 0)) {
		t.Errorf("vence_resolucion_en = %v", inc.VenceResolucionEn)
	}
	if got := e.tipos(inc.ID); !reflect.DeepEqual(got, []string{EvCreada, EvAsignada, EvEstadoCambiado}) {
		t.Errorf("eventos = %v", got)
	}
	// Aviso al técnico y registro de la decisión.
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'incidencia_asignada' AND destinatario_id = $2`, inc.ID, e.ana); n != 1 {
		t.Errorf("avisos al técnico = %d", n)
	}
	if n := e.contar(`SELECT count(*) FROM decisiones WHERE componente = 'despacho'`); n != 1 {
		t.Errorf("decisiones de despacho = %d", n)
	}
	// ultima_asignacion del técnico.
	var ult *time.Time
	_ = e.db.QueryRow(e.ctx, `SELECT ultima_asignacion FROM tecnicos WHERE id = $1`, e.ana).Scan(&ult)
	if ult == nil || !iguales(*ult, L(2026, 10, 5, 9, 0)) {
		t.Errorf("ultima_asignacion = %v", ult)
	}
	// El siguiente va a Beto: Ana ya tiene carga.
	r2 := e.crear(nil)
	if *r2.Incidencia.TecnicoID != e.beto {
		t.Errorf("la segunda debía ir a Beto, fue a %d", *r2.Incidencia.TecnicoID)
	}
}

// El formato de las filas del outbox es EXACTAMENTE el de docs/CONTRATOS.md §4.
func TestOutboxTieneElFormatoDelContrato(t *testing.T) {
	e := nuevoEntorno(t)
	r := e.crear(nil)
	tec := ActorTecnico(*r.Incidencia.TecnicoID)
	e.en(L(2026, 10, 5, 9, 20))
	if _, err := e.svc.Responder(e.ctx, r.Incidencia.ID, EntradaResponder{Texto: "Texto privado de la respuesta", Actor: tec}); err != nil {
		t.Fatal(err)
	}
	claves := func(m map[string]any) []string {
		var ks []string
		for k := range m {
			if k != "__clave" {
				ks = append(ks, k)
			}
		}
		sort.Strings(ks)
		return ks
	}
	quiere := func(s string) []string {
		ks := strings.Split(s, ", ")
		sort.Strings(ks)
		return ks
	}
	esperadas := map[string]string{
		"eventos_incidencia":  "id, incidencia_id, numero, ts, tipo, actor_tipo, actor_id, prioridad, categoria, grupo, tecnico_id, datos",
		"incidencias_estado":  "incidencia_id, version, numero, persona_id, tipo, categoria, impacto, urgencia, prioridad, estado, grupo, nivel, tecnico_id, canal, sede, area, creada_en, primera_respuesta_en, resuelta_en, cerrada_en, reaperturas, escalamientos, caso_id",
		"incidencias_tiempos": "incidencia_id, version, prioridad, categoria, grupo, tecnico_id, creada_en, resuelta_en, cerrada_en, frt_min, mttr_min, pausa_min, sla_respuesta_ok, sla_resolucion_ok, primer_contacto",
	}
	for tabla, cols := range esperadas {
		filas := e.leerOutbox(tabla)
		if len(filas) == 0 {
			t.Fatalf("%s: el outbox está vacío", tabla)
		}
		for _, f := range filas {
			if got := claves(f); !reflect.DeepEqual(got, quiere(cols)) {
				t.Errorf("%s: columnas %v, quiere %v", tabla, got, quiere(cols))
			}
		}
	}

	// Eventos: uno por evento insertado, con clave ev-<id>, ts ISO UTC y datos como texto JSON.
	nEv := e.contar(`SELECT count(*) FROM incidencia_eventos`)
	evs := e.leerOutbox("eventos_incidencia")
	if len(evs) != nEv {
		t.Errorf("eventos en el outbox = %d, en la tabla = %d", len(evs), nEv)
	}
	for _, f := range evs {
		id := int64(f["id"].(float64))
		if f["__clave"] != fmt.Sprintf("ev-%d", id) {
			t.Errorf("clave del evento %v = %v", id, f["__clave"])
		}
		if _, err := time.Parse(time.RFC3339, f["ts"].(string)); err != nil || !strings.HasSuffix(f["ts"].(string), "Z") {
			t.Errorf("ts no es ISO UTC: %v", f["ts"])
		}
		datos, ok := f["datos"].(string)
		if !ok || !strings.HasPrefix(datos, "{") {
			t.Errorf("datos debe ser JSON como texto: %#v", f["datos"])
		}
		if strings.Contains(datos, "Texto privado") || strings.Contains(datos, "contexto") {
			t.Errorf("el texto libre y el contexto no deben salir en datos: %s", datos)
		}
		if f["prioridad"] != "P3" || f["categoria"] != "correo" || f["grupo"] != "Mesa N1" {
			t.Errorf("contexto del evento: %v %v %v", f["prioridad"], f["categoria"], f["grupo"])
		}
	}

	// Estado: una fila nueva por cada cambio; la versión son ms epoch de actualizada_en y crece.
	est := e.leerOutbox("incidencias_estado")
	var ultimo float64
	for i, f := range est {
		v := f["version"].(float64)
		if i > 0 && v <= ultimo {
			t.Errorf("la versión debe crecer: %v tras %v", v, ultimo)
		}
		ultimo = v
		if f["__clave"] != fmt.Sprintf("inc-%d-%d", int64(f["incidencia_id"].(float64)), int64(v)) {
			t.Errorf("clave de estado: %v", f["__clave"])
		}
	}
	fin := est[len(est)-1]
	inc := e.obtener(r.Incidencia.ID)
	if int64(fin["version"].(float64)) != inc.ActualizadaEn.UnixMilli() {
		t.Errorf("la última versión debe ser actualizada_en en ms: %v vs %d", fin["version"], inc.ActualizadaEn.UnixMilli())
	}
	if fin["estado"] != "en_curso" || fin["sede"] != "" || fin["canal"] != "whatsapp" {
		t.Errorf("fila de estado: %v", fin)
	}
	if fin["primera_respuesta_en"] == nil || fin["resuelta_en"] != nil || fin["cerrada_en"] != nil {
		t.Errorf("marcas de tiempo del estado: %v", fin)
	}

	// Tiempos: FRT = 20 min laborales (09:00 -> 09:20), con el plazo de 120 de P3 cumplido.
	tie := e.leerOutbox("incidencias_tiempos")
	ult := tie[len(tie)-1]
	if ult["frt_min"] != float64(20) || ult["sla_respuesta_ok"] != float64(1) || ult["mttr_min"] != nil || ult["sla_resolucion_ok"] != nil || ult["primer_contacto"] != nil {
		t.Errorf("tiempos: %v", ult)
	}
	if ult["pausa_min"] != float64(0) {
		t.Errorf("pausa_min = %v", ult["pausa_min"])
	}
}

func TestCicloDeVidaCompleto(t *testing.T) {
	e := nuevoEntorno(t)
	r := e.crear(nil) // P3, lunes 09:00, asignada a Ana
	id := r.Incidencia.ID
	ana := ActorTecnico(e.ana)
	usuario := ActorUsuario(e.pepe)

	e.en(L(2026, 10, 5, 9, 30))
	inc, err := e.svc.Responder(e.ctx, id, EntradaResponder{Texto: "Voy a revisarlo", Actor: ana})
	if err != nil || inc.Estado != EnCurso || inc.PrimeraRespuestaEn == nil || !iguales(*inc.PrimeraRespuestaEn, L(2026, 10, 5, 9, 30)) {
		t.Fatalf("responder: %+v %v", inc, err)
	}
	// La segunda respuesta es un comentario público y no mueve la primera respuesta.
	e.en(L(2026, 10, 5, 9, 45))
	inc, err = e.svc.Responder(e.ctx, id, EntradaResponder{Texto: "Sigo en ello", Actor: ana})
	if err != nil || !iguales(*inc.PrimeraRespuestaEn, L(2026, 10, 5, 9, 30)) {
		t.Fatalf("segunda respuesta: %+v %v", inc, err)
	}

	e.en(L(2026, 10, 5, 10, 0))
	if inc, err = e.svc.Pausar(e.ctx, id, EntradaPausar{Motivo: "espera_usuario", Nota: "¿qué mensaje te sale?", Actor: ana}); err != nil || inc.Estado != EsperaUsuario {
		t.Fatalf("pausar: %+v %v", inc, err)
	}
	e.en(L(2026, 10, 5, 11, 0))
	if inc, err = e.svc.Reanudar(e.ctx, id, EntradaReanudar{Actor: usuario}); err != nil || inc.Estado != EnCurso {
		t.Fatalf("reanudar: %+v %v", inc, err)
	}
	e.en(L(2026, 10, 5, 12, 0))
	if inc, err = e.svc.Resolver(e.ctx, id, EntradaResolver{Solucion: "Se reconfiguró el perfil", Actor: ana}); err != nil ||
		inc.Estado != Resuelta || inc.ResueltaEn == nil || !iguales(*inc.ResueltaEn, L(2026, 10, 5, 12, 0)) {
		t.Fatalf("resolver: %+v %v", inc, err)
	}
	// «Sigue igual»: reabre, suma el contador y borra resuelta_en.
	e.en(L(2026, 10, 5, 14, 0))
	if inc, err = e.svc.Reabrir(e.ctx, id, EntradaReabrir{Motivo: "sigue igual", Actor: usuario}); err != nil ||
		inc.Estado != Reabierta || inc.Reaperturas != 1 || inc.ResueltaEn != nil {
		t.Fatalf("reabrir: %+v %v", inc, err)
	}
	e.en(L(2026, 10, 5, 14, 10))
	if inc, err = e.svc.Responder(e.ctx, id, EntradaResponder{Texto: "Lo vuelvo a mirar", Actor: ana}); err != nil || inc.Estado != EnCurso {
		t.Fatalf("responder tras reabrir: %+v %v", inc, err)
	}
	e.en(L(2026, 10, 5, 15, 0))
	if inc, err = e.svc.Resolver(e.ctx, id, EntradaResolver{Solucion: "Ahora sí", Actor: ana}); err != nil || inc.Estado != Resuelta {
		t.Fatalf("segunda resolución: %+v %v", inc, err)
	}
	e.en(L(2026, 10, 5, 15, 30))
	inc, err = e.svc.Cerrar(e.ctx, id, EntradaCerrar{Motivo: CierreConfirmado, Actor: usuario})
	if err != nil || inc.Estado != Cerrada || inc.CerradaEn == nil || inc.MotivoCierre == nil || *inc.MotivoCierre != "confirmado" {
		t.Fatalf("cerrar: %+v %v", inc, err)
	}

	quiere := []string{
		EvCreada, EvAsignada, EvEstadoCambiado, // creación y asignación
		EvPrimeraRespuesta, EvEstadoCambiado, // 09:30 asignada -> en_curso
		EvComentario,                    // 09:45
		EvEstadoCambiado, EvPausaInicio, // 10:00 pausa
		EvPausaFin, EvEstadoCambiado, // 11:00 reanuda
		EvResuelta, EvEstadoCambiado, // 12:00
		EvReabierta, EvEstadoCambiado, // 14:00
		EvComentario, EvEstadoCambiado, // 14:10 responde y vuelve a en_curso
		EvResuelta, EvEstadoCambiado, // 15:00
		EvCerrada, EvEstadoCambiado, // 15:30
	}
	if got := e.tipos(id); !reflect.DeepEqual(got, quiere) {
		t.Errorf("eventos:\n got  %v\n want %v", got, quiere)
	}

	// Tiempos finales, calculados desde los eventos: P3 (respuesta 120, resolución 1440).
	// Laboral 09:00-15:00 = 5 h = 300 min menos el almuerzo (13-14) = 300 - 60 = ... se calcula a mano:
	// 09:00-13:00 = 240; 14:00-15:00 = 60 => 300 min; pausas: 10:00-11:00 (60) y resuelta 12:00-14:00 (13:00-14:00 es
	// almuerzo: laboral 12:00-13:00 = 60) => 120 min. MTTR = 300 - 120 = 180.
	tie := e.leerOutbox("incidencias_tiempos")
	ult := tie[len(tie)-1]
	if ult["frt_min"] != float64(30) || ult["mttr_min"] != float64(180) || ult["pausa_min"] != float64(120) ||
		ult["sla_respuesta_ok"] != float64(1) || ult["sla_resolucion_ok"] != float64(1) || ult["primer_contacto"] != float64(0) {
		t.Errorf("tiempos finales: %v", ult)
	}
}

// Las acciones no permitidas devuelven error, no cambian nada y no dejan eventos ni filas en el outbox.
func TestTransicionesInvalidasNoDejanRastro(t *testing.T) {
	e := nuevoEntorno(t)
	tec := ActorTecnico(e.ana)
	acciones := map[Accion]func(id int64) error{
		AccAsignar: func(id int64) error {
			_, err := e.svc.Asignar(e.ctx, id, EntradaAsignar{TecnicoID: e.beto, Actor: ActorSistema()})
			return err
		},
		AccResponder: func(id int64) error {
			_, err := e.svc.Responder(e.ctx, id, EntradaResponder{Texto: "hola", Actor: tec})
			return err
		},
		AccPausarUsuario: func(id int64) error {
			_, err := e.svc.Pausar(e.ctx, id, EntradaPausar{Motivo: "espera_usuario", Actor: tec})
			return err
		},
		AccPausarTercero: func(id int64) error {
			_, err := e.svc.Pausar(e.ctx, id, EntradaPausar{Motivo: "espera_tercero", Actor: tec})
			return err
		},
		AccReanudar: func(id int64) error { _, err := e.svc.Reanudar(e.ctx, id, EntradaReanudar{Actor: tec}); return err },
		AccResolver: func(id int64) error {
			_, err := e.svc.Resolver(e.ctx, id, EntradaResolver{Solucion: "x", Actor: tec})
			return err
		},
		AccReabrir: func(id int64) error {
			_, err := e.svc.Reabrir(e.ctx, id, EntradaReabrir{Actor: ActorUsuario(e.pepe)})
			return err
		},
		AccCerrar: func(id int64) error {
			_, err := e.svc.Cerrar(e.ctx, id, EntradaCerrar{Motivo: CierreConfirmado, Actor: ActorUsuario(e.pepe)})
			return err
		},
		AccEscalar: func(id int64) error {
			_, err := e.svc.Escalar(e.ctx, id, EntradaEscalar{Motivo: "manual", Actor: ActorSistema()})
			return err
		},
		AccCambiarPrioridad: func(id int64) error {
			_, err := e.svc.CambiarPrioridad(e.ctx, id, EntradaCambiarPrioridad{Prioridad: "P1", Actor: ActorSistema()})
			return err
		},
		AccComentar: func(id int64) error {
			_, err := e.svc.Comentar(e.ctx, id, EntradaComentar{Texto: "nota", Actor: tec})
			return err
		},
		AccAgregarDato: func(id int64) error {
			_, err := e.svc.AgregarDato(e.ctx, id, EntradaDato{Clave: "equipo", Valor: "PC-1", Actor: ActorUsuario(e.pepe)})
			return err
		},
	}
	if len(acciones) != len(Acciones) {
		t.Fatalf("la prueba cubre %d acciones de %d", len(acciones), len(Acciones))
	}
	verificadas := 0
	for _, estado := range Estados {
		inc := e.llevarA(estado)
		for _, a := range Acciones {
			if _, err := Transicion(estado, a); err == nil {
				continue // válida: otra prueba la cubre
			}
			antesEv := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1`, inc.ID)
			antesOut := e.contar(`SELECT count(*) FROM outbox_analitica`)
			antesAv := e.contar(`SELECT count(*) FROM avisos`)
			antes := e.obtener(inc.ID)

			err := acciones[a](inc.ID)
			if !errors.Is(err, ErrTransicionInvalida) {
				t.Errorf("%s desde %s: err = %v, quiere ErrTransicionInvalida", a, estado, err)
				continue
			}
			verificadas++
			if got := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1`, inc.ID); got != antesEv {
				t.Errorf("%s desde %s dejó %d eventos nuevos", a, estado, got-antesEv)
			}
			if got := e.contar(`SELECT count(*) FROM outbox_analitica`); got != antesOut {
				t.Errorf("%s desde %s dejó %d filas en el outbox", a, estado, got-antesOut)
			}
			if got := e.contar(`SELECT count(*) FROM avisos`); got != antesAv {
				t.Errorf("%s desde %s dejó avisos", a, estado)
			}
			if despues := e.obtener(inc.ID); !reflect.DeepEqual(antes, despues) {
				t.Errorf("%s desde %s modificó la incidencia", a, estado)
			}
		}
	}
	if verificadas < 40 {
		t.Errorf("solo se verificaron %d combinaciones inválidas", verificadas)
	}
}

func TestValidacionesDeLasAcciones(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.llevarA(EnCurso)
	tec := ActorTecnico(e.ana)
	casos := map[string]error{}
	_, casos["responder con asistente"] = e.svc.Responder(e.ctx, inc.ID, EntradaResponder{Texto: "x", Actor: ActorAsistente()})
	_, casos["responder vacío"] = e.svc.Responder(e.ctx, inc.ID, EntradaResponder{Texto: " ", Actor: tec})
	_, casos["pausa con motivo raro"] = e.svc.Pausar(e.ctx, inc.ID, EntradaPausar{Motivo: "siesta", Actor: tec})
	_, casos["prioridad inválida"] = e.svc.CambiarPrioridad(e.ctx, inc.ID, EntradaCambiarPrioridad{Prioridad: "P9", Actor: tec})
	_, casos["misma prioridad"] = e.svc.CambiarPrioridad(e.ctx, inc.ID, EntradaCambiarPrioridad{Prioridad: "P3", Actor: tec})
	_, casos["comentario vacío"] = e.svc.Comentar(e.ctx, inc.ID, EntradaComentar{Texto: "", Actor: tec})
	_, casos["dato sin clave"] = e.svc.AgregarDato(e.ctx, inc.ID, EntradaDato{Valor: "x", Actor: tec})
	_, casos["asignar al mismo técnico"] = e.svc.Asignar(e.ctx, inc.ID, EntradaAsignar{TecnicoID: e.ana, Actor: ActorSistema()})
	_, casos["cierre sin_confirmacion por una persona"] = e.svc.Cerrar(e.ctx, inc.ID, EntradaCerrar{Motivo: CierreSinConfirmacion, Actor: ActorUsuario(e.pepe)})
	_, casos["motivo de cierre inventado"] = e.svc.Cerrar(e.ctx, inc.ID, EntradaCerrar{Motivo: "porque sí", Actor: ActorSistema()})
	_, casos["actor inválido"] = e.svc.Comentar(e.ctx, inc.ID, EntradaComentar{Texto: "x", Actor: Actor{Tipo: "alien"}})
	for nombre, err := range casos {
		if !errors.Is(err, ErrInvalido) {
			t.Errorf("%s: err = %v, quiere ErrInvalido", nombre, err)
		}
	}
	if _, err := e.svc.Asignar(e.ctx, inc.ID, EntradaAsignar{TecnicoID: 99999, Actor: ActorSistema()}); !errors.Is(err, ErrNoEncontrado) {
		t.Errorf("técnico inexistente: %v", err)
	}
	if _, err := e.svc.Obtener(e.ctx, 99999); !errors.Is(err, ErrNoEncontrado) {
		t.Errorf("incidencia inexistente: %v", err)
	}
	if _, err := e.svc.Resolver(e.ctx, 99999, EntradaResolver{Actor: tec}); !errors.Is(err, ErrNoEncontrado) {
		t.Errorf("resolver inexistente: %v", err)
	}
	e.exec(`UPDATE tecnicos SET estado = 'inactivo' WHERE id = $1`, e.beto)
	if _, err := e.svc.Asignar(e.ctx, inc.ID, EntradaAsignar{TecnicoID: e.beto, Actor: ActorSistema()}); !errors.Is(err, ErrInvalido) {
		t.Errorf("asignar a un inactivo: %v", err)
	}
}

// Viernes 17:55 y pausas: los vencimientos salen del reloj de SLA y se recalculan en cada cambio.
func TestVencimientosViernesTardeYPausas(t *testing.T) {
	e := nuevoEntorno(t)
	e.en(L(2026, 10, 9, 17, 55)) // viernes
	r := e.crear(nil)            // P3: respuesta 120, resolución 1440
	inc := r.Incidencia
	if inc.Estado != Asignada {
		t.Fatalf("a las 17:55 hay técnicos en turno hasta las 18:00: %+v", inc)
	}
	// 5 min el viernes + 115 el lunes desde las 08:30 = lunes 10:25.
	if !iguales(*inc.VenceRespuestaEn, L(2026, 10, 12, 10, 25)) {
		t.Errorf("vence_respuesta_en = %s", inc.VenceRespuestaEn.In(lima))
	}
	// 5 + 510 + 510 + 415: miércoles 14-oct 16:25.
	if !iguales(*inc.VenceResolucionEn, L(2026, 10, 14, 16, 25)) {
		t.Errorf("vence_resolucion_en = %s", inc.VenceResolucionEn.In(lima))
	}
	ana := ActorTecnico(*inc.TecnicoID)
	e.en(L(2026, 10, 12, 9, 0))
	if _, err := e.svc.Responder(e.ctx, inc.ID, EntradaResponder{Texto: "ok", Actor: ana}); err != nil {
		t.Fatal(err)
	}
	// Primera pausa: lunes 10:00 -> martes 10:00 = 510 min laborales (un día completo).
	e.en(L(2026, 10, 12, 10, 0))
	p, err := e.svc.Pausar(e.ctx, inc.ID, EntradaPausar{Motivo: "espera_usuario", Actor: ana})
	if err != nil || !iguales(*p.VenceResolucionEn, L(2026, 10, 14, 16, 25)) {
		t.Fatalf("al empezar la pausa el vencimiento no cambia: %v %v", p, err)
	}
	e.en(L(2026, 10, 13, 10, 0))
	p, err = e.svc.Reanudar(e.ctx, inc.ID, EntradaReanudar{Actor: ActorUsuario(e.pepe)})
	if err != nil || !iguales(*p.VenceResolucionEn, L(2026, 10, 15, 16, 25)) {
		t.Fatalf("tras la primera pausa debe vencer jueves 16:25: %v %v", p.VenceResolucionEn, err)
	}
	// Segunda pausa (espera_tercero, 120 min laborales): corre el vencimiento a viernes 08:55.
	e.en(L(2026, 10, 14, 9, 0))
	if _, err := e.svc.Pausar(e.ctx, inc.ID, EntradaPausar{Motivo: "espera_tercero", Actor: ana}); err != nil {
		t.Fatal(err)
	}
	e.en(L(2026, 10, 14, 11, 0))
	p, err = e.svc.Reanudar(e.ctx, inc.ID, EntradaReanudar{Actor: ana})
	if err != nil || !iguales(*p.VenceResolucionEn, L(2026, 10, 16, 8, 55)) {
		t.Fatalf("tras dos pausas debe vencer viernes 08:55: %v %v", p.VenceResolucionEn, err)
	}
	// La respuesta ya cumplida no se mueve.
	if !iguales(*p.VenceRespuestaEn, L(2026, 10, 12, 10, 25)) {
		t.Errorf("vence_respuesta_en no debe cambiar tras responder: %s", p.VenceRespuestaEn.In(lima))
	}
	// El SLA, medido desde los eventos, coincide: a las 11:00 del miércoles se llevan 5+510+510...
	sl, err := e.svc.SLA(e.ctx, inc.ID)
	if err != nil || sl.Pausada || sl.Vencida || sl.Resolucion.LimiteMin != 1440 {
		t.Fatalf("SLA = %+v %v", sl, err)
	}
	if sl.Resolucion.TranscurridoMin <= 0 || sl.Resolucion.Porcentaje <= 0 {
		t.Errorf("transcurrido = %v", sl.Resolucion)
	}
}

func TestP1FueraDeHorarioVaALaGuardia(t *testing.T) {
	e := nuevoEntorno(t)
	e.en(L(2026, 10, 10, 3, 0)) // sábado 03:00
	r := e.crear(func(in *EntradaCrear) { in.Categoria = "red_wifi"; in.Impacto, in.Urgencia = "organizacion", "critica" })
	inc := r.Incidencia
	if inc.Prioridad != "P1" || inc.TecnicoID == nil || *inc.TecnicoID != e.gabi || !r.Despacho.PorGuardia {
		t.Fatalf("P1 de madrugada debía ir a la guardia (Gabi, de otro grupo): %+v %+v", inc, r.Despacho)
	}
	if inc.Estado != Asignada || inc.Grupo != "Redes" {
		t.Errorf("estado/grupo: %s %s", inc.Estado, inc.Grupo)
	}
	// P1 corre 24x7: 15 min de respuesta y 240 de resolución, sin saltar la noche.
	if !iguales(*inc.VenceRespuestaEn, L(2026, 10, 10, 3, 15)) || !iguales(*inc.VenceResolucionEn, L(2026, 10, 10, 7, 0)) {
		t.Errorf("vencimientos P1: %s %s", inc.VenceRespuestaEn.In(lima), inc.VenceResolucionEn.In(lima))
	}
	// Una P3 a la misma hora NO usa la guardia: va a la cola.
	r3 := e.crear(func(in *EntradaCrear) { in.Categoria = "red_wifi" })
	if r3.Incidencia.TecnicoID != nil || r3.Incidencia.Estado != Nueva {
		t.Errorf("P3 de madrugada debe ir a la cola: %+v", r3.Incidencia)
	}
}

func TestColaDelGrupoYDespacharCola(t *testing.T) {
	e := nuevoEntorno(t)
	e.en(L(2026, 10, 10, 10, 0)) // sábado: nadie en turno
	r := e.crear(nil)
	inc := r.Incidencia
	if inc.Estado != Nueva || inc.TecnicoID != nil || !r.Despacho.Cola || !r.Despacho.AvisarResponsable {
		t.Fatalf("debía quedar en la cola: %+v %+v", inc, r.Despacho)
	}
	if got := e.tipos(inc.ID); !reflect.DeepEqual(got, []string{EvCreada, EvEnCola}) {
		t.Errorf("eventos = %v", got)
	}
	// Aviso al responsable del grupo (Ana).
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'incidencia_sin_asignar'
		AND destinatario_tipo = 'responsable_grupo' AND destinatario_id = $2`, inc.ID, e.ana); n != 1 {
		t.Errorf("avisos al responsable = %d", n)
	}
	// El lunes antes del turno, sigue sin candidato y no se genera ruido.
	e.en(L(2026, 10, 12, 8, 0))
	antes := e.contar(`SELECT count(*) FROM incidencia_eventos`)
	got, err := e.svc.DespacharCola(e.ctx)
	if err != nil || len(got) != 0 {
		t.Fatalf("antes del turno: %v %v", got, err)
	}
	if e.contar(`SELECT count(*) FROM incidencia_eventos`) != antes || e.contar(`SELECT count(*) FROM avisos`) != 1 {
		t.Error("sin candidato no debe haber eventos ni avisos nuevos")
	}
	// Entra el turno: la cola se vacía.
	e.en(L(2026, 10, 12, 9, 0))
	got, err = e.svc.DespacharCola(e.ctx)
	if err != nil || len(got) != 1 || got[0] != inc.Numero {
		t.Fatalf("a las 09:00 debía asignarse %s: %v %v", inc.Numero, got, err)
	}
	after := e.obtener(inc.ID)
	if after.Estado != Asignada || after.TecnicoID == nil {
		t.Errorf("tras despachar: %+v", after)
	}
	if got, _ := e.svc.DespacharCola(e.ctx); len(got) != 0 {
		t.Errorf("la segunda pasada no debe repetir: %v", got)
	}
}

func TestEscalarFuncional(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.llevarA(EsperaUsuario) // en espera: Escalar cierra la pausa
	e.en(L(2026, 10, 5, 11, 0))
	r, err := e.svc.Escalar(e.ctx, inc.ID, EntradaEscalar{Motivo: "manual", Actor: ActorTecnico(e.ana)})
	if err != nil {
		t.Fatal(err)
	}
	n := r.Incidencia
	if n.Grupo != "Infraestructura" || n.Nivel != "N3" || n.Escalamientos != 1 || n.Estado != Asignada {
		t.Fatalf("tras escalar: %+v", n)
	}
	if n.TecnicoID == nil || (*n.TecnicoID != e.dan && *n.TecnicoID != e.gabi) {
		t.Errorf("debe quedar con alguien de Infraestructura: %v", n.TecnicoID)
	}
	tipos := e.tipos(inc.ID)
	if !contiene(tipos, EvEscalada) || !contiene(tipos, EvPausaFin) || !contiene(tipos, EvReasignada) {
		t.Errorf("eventos de la escalada: %v", tipos)
	}
	// El reloj se reanudó al escalar: no queda pausa abierta.
	if ini, fin := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'pausa_inicio'`, inc.ID),
		e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'pausa_fin'`, inc.ID); ini != fin {
		t.Errorf("pausas sin cerrar tras escalar: %d inicios, %d fines", ini, fin)
	}
	// Desde el último nivel no hay a dónde escalar.
	if _, err := e.svc.Escalar(e.ctx, inc.ID, EntradaEscalar{Actor: ActorSistema()}); !errors.Is(err, ErrSinNivelSuperior) {
		t.Errorf("sin nivel superior: %v", err)
	}
	// Escalar a su propio grupo es inválido.
	if _, err := e.svc.Escalar(e.ctx, inc.ID, EntradaEscalar{GrupoDestinoID: &e.infra, Actor: ActorSistema()}); !errors.Is(err, ErrInvalido) {
		t.Errorf("mismo grupo: %v", err)
	}
	// Si el grupo de destino no tiene a nadie, queda en la cola (nueva) y se avisa al responsable.
	otra := e.llevarA(Asignada)
	e.en(L(2026, 10, 10, 10, 0)) // sábado: nadie en turno
	r2, err := e.svc.Escalar(e.ctx, otra.ID, EntradaEscalar{Motivo: "manual", Actor: ActorSistema()})
	if err != nil || r2.Incidencia.Estado != Nueva || r2.Incidencia.TecnicoID != nil || !r2.Despacho.Cola {
		t.Errorf("escalar sin candidatos: %+v %v", r2, err)
	}
}

func contiene(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func TestReaperturasEscalamientosYContadores(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.llevarA(Reabierta)
	tec := ActorTecnico(*inc.TecnicoID)
	for i := 2; i <= 3; i++ {
		e.reloj.Avanzar(time.Hour)
		if _, err := e.svc.Responder(e.ctx, inc.ID, EntradaResponder{Texto: "otra vez", Actor: tec}); err != nil {
			t.Fatal(err)
		}
		e.reloj.Avanzar(time.Hour)
		if _, err := e.svc.Resolver(e.ctx, inc.ID, EntradaResolver{Actor: tec}); err != nil {
			t.Fatal(err)
		}
		e.reloj.Avanzar(time.Hour)
		got, err := e.svc.Reabrir(e.ctx, inc.ID, EntradaReabrir{Motivo: "no", Actor: ActorUsuario(e.pepe)})
		if err != nil || got.Reaperturas != i {
			t.Fatalf("reapertura %d: %+v %v", i, got, err)
		}
	}
}

func TestComentariosDatosYQueja(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.llevarA(EnCurso)
	tec := ActorTecnico(e.ana)
	if _, err := e.svc.Comentar(e.ctx, inc.ID, EntradaComentar{Texto: "Nota interna: parece el servidor", Interno: true, Actor: tec}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Comentar(e.ctx, inc.ID, EntradaComentar{Texto: "Estamos en ello", Actor: tec}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.AgregarDato(e.ctx, inc.ID, EntradaDato{Clave: "equipo", Valor: "PC-CONT-07", Actor: ActorUsuario(e.pepe)}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.RegistrarQueja(e.ctx, inc.ID, EntradaQueja{Texto: "Llevo tres días así", Actor: ActorUsuario(e.pepe)}); err != nil {
		t.Fatal(err)
	}
	evs, _ := e.svc.Eventos(e.ctx, inc.ID)
	vistos := map[string]map[string]any{}
	for _, ev := range evs {
		vistos[ev.Tipo] = ev.Datos
	}
	if vistos[EvComentarioInt]["visible"] != "interno" || vistos[EvComentario]["visible"] != "publico" ||
		vistos[EvDatoAgregado]["clave"] != "equipo" || vistos[EvQueja] == nil {
		t.Errorf("eventos: %v", vistos)
	}
	// El texto libre NO sale hacia ClickHouse (ANALITICA_TEXTO no está activa).
	for _, f := range e.leerOutbox("eventos_incidencia") {
		d := f["datos"].(string)
		for _, secreto := range []string{"Nota interna", "Estamos en ello", "PC-CONT-07", "tres días"} {
			if strings.Contains(d, secreto) {
				t.Errorf("el outbox filtró texto libre %q: %s", secreto, d)
			}
		}
	}
	// Y los comentarios no cuentan como primera respuesta: ya había una. Una incidencia nueva sin
	// responder sigue sin ella aunque tenga comentarios.
	r := e.crear(nil)
	if _, err := e.svc.Comentar(e.ctx, r.Incidencia.ID, EntradaComentar{Texto: "algo", Actor: ActorTecnico(e.ana)}); err != nil {
		t.Fatal(err)
	}
	if e.obtener(r.Incidencia.ID).PrimeraRespuestaEn != nil {
		t.Error("un comentario no es primera respuesta")
	}
}

func TestCierreAutomaticoTras48HorasLaborales(t *testing.T) {
	e := nuevoEntorno(t)
	e.en(L(2026, 10, 9, 14, 0)) // viernes
	r := e.crear(nil)
	id, tec := r.Incidencia.ID, ActorTecnico(*r.Incidencia.TecnicoID)
	e.en(L(2026, 10, 9, 15, 0))
	if _, err := e.svc.Responder(e.ctx, id, EntradaResponder{Texto: "ok", Actor: tec}); err != nil {
		t.Fatal(err)
	}
	e.en(L(2026, 10, 9, 16, 0))
	if _, err := e.svc.Resolver(e.ctx, id, EntradaResolver{Actor: tec}); err != nil {
		t.Fatal(err)
	}
	// Desde el viernes 16:00: 120 + 5×510... las 48 h laborales (2880 min) se cumplen el lunes 19-oct a las 12:00.
	cerrar := func(t time.Time) []string {
		got, err := e.svc.CerrarResueltasSinConfirmar(e.ctx, t)
		if err != nil {
			e.t.Fatal(err)
		}
		return got
	}
	if got := cerrar(L(2026, 10, 11, 12, 0)); len(got) != 0 { // domingo: 120 min laborales
		t.Errorf("domingo: %v", got)
	}
	if got := cerrar(L(2026, 10, 19, 11, 59)); len(got) != 0 {
		t.Errorf("un minuto antes: %v", got)
	}
	e.en(L(2026, 10, 19, 12, 0))
	got := cerrar(L(2026, 10, 19, 12, 0))
	if len(got) != 1 || got[0] != r.Incidencia.Numero {
		t.Fatalf("a las 12:00 del lunes 19 debía cerrarse: %v", got)
	}
	inc := e.obtener(id)
	if inc.Estado != Cerrada || inc.MotivoCierre == nil || *inc.MotivoCierre != CierreSinConfirmacion || !iguales(*inc.CerradaEn, L(2026, 10, 19, 12, 0)) {
		t.Errorf("incidencia cerrada: %+v", inc)
	}
	if got := cerrar(L(2026, 10, 20, 12, 0)); len(got) != 0 {
		t.Errorf("idempotente: %v", got)
	}
	// El evento lo deja el sistema.
	evs, _ := e.svc.Eventos(e.ctx, id)
	var cerradaEv Evento
	for _, ev := range evs {
		if ev.Tipo == EvCerrada {
			cerradaEv = ev
		}
	}
	if cerradaEv.ActorTipo != "sistema" || cerradaEv.Datos["motivo"] != CierreSinConfirmacion {
		t.Errorf("evento cerrada: %+v", cerradaEv)
	}
	// Una resuelta que la persona reabre a tiempo no se cierra sola.
	e.en(L(2026, 10, 5, 9, 0))
	e2 := e.llevarA(Resuelta)
	e.reloj.Avanzar(time.Minute)
	if _, err := e.svc.Reabrir(e.ctx, e2.ID, EntradaReabrir{Actor: ActorUsuario(e.pepe)}); err != nil {
		t.Fatal(err)
	}
	if got := cerrar(L(2026, 11, 30, 12, 0)); len(got) != 0 {
		t.Errorf("una reabierta no se cierra: %v", got)
	}
}

func TestBuscarAbiertaDuplicada(t *testing.T) {
	e := nuevoEntorno(t)
	if d, err := e.svc.BuscarAbiertaDuplicada(e.ctx, e.pepe, "correo"); err != nil || d != nil {
		t.Fatalf("sin incidencias: %v %v", d, err)
	}
	r := e.crear(nil)
	d, err := e.svc.BuscarAbiertaDuplicada(e.ctx, e.pepe, "correo")
	if err != nil || d == nil || d.ID != r.Incidencia.ID {
		t.Fatalf("debía encontrar la abierta: %v %v", d, err)
	}
	if d, _ := e.svc.BuscarAbiertaDuplicada(e.ctx, e.pepe, "vpn"); d != nil {
		t.Error("otra categoría no es duplicada")
	}
	if d, _ := e.svc.BuscarAbiertaDuplicada(e.ctx, e.vera, "correo"); d != nil {
		t.Error("otra persona no es duplicada")
	}
	// Resuelta ya no es «abierta», pero BuscarResueltaReciente la encuentra para el «sigue igual».
	tec := ActorTecnico(*r.Incidencia.TecnicoID)
	e.reloj.Avanzar(time.Minute)
	_, _ = e.svc.Responder(e.ctx, r.Incidencia.ID, EntradaResponder{Texto: "x", Actor: tec})
	e.reloj.Avanzar(time.Minute)
	_, _ = e.svc.Resolver(e.ctx, r.Incidencia.ID, EntradaResolver{Actor: tec})
	if d, _ := e.svc.BuscarAbiertaDuplicada(e.ctx, e.pepe, "correo"); d != nil {
		t.Error("una resuelta no es abierta")
	}
	if d, _ := e.svc.BuscarResueltaReciente(e.ctx, e.pepe, "correo", e.reloj.Ahora().Add(-time.Hour)); d == nil || d.ID != r.Incidencia.ID {
		t.Errorf("BuscarResueltaReciente = %v", d)
	}
	if d, _ := e.svc.BuscarResueltaReciente(e.ctx, e.pepe, "correo", e.reloj.Ahora().Add(time.Hour)); d != nil {
		t.Error("fuera de la ventana no debe encontrarla")
	}
}

func TestAsignarManualYReasignar(t *testing.T) {
	e := nuevoEntorno(t)
	e.en(L(2026, 10, 10, 10, 0))
	inc := e.crear(nil).Incidencia // cola
	got, err := e.svc.Asignar(e.ctx, inc.ID, EntradaAsignar{TecnicoID: e.beto, Motivo: "supervisor", Actor: ActorTecnico(e.ana)})
	if err != nil || got.Estado != Asignada || *got.TecnicoID != e.beto {
		t.Fatalf("asignar de la cola: %+v %v", got, err)
	}
	got, err = e.svc.Asignar(e.ctx, inc.ID, EntradaAsignar{TecnicoID: e.ana, Actor: ActorTecnico(e.ana)})
	if err != nil || got.Estado != Asignada || *got.TecnicoID != e.ana {
		t.Fatalf("reasignar: %+v %v", got, err)
	}
	tipos := e.tipos(inc.ID)
	if !contiene(tipos, EvAsignada) || !contiene(tipos, EvReasignada) {
		t.Errorf("eventos: %v", tipos)
	}
	// Cada asignación avisa al técnico.
	if n := e.contar(`SELECT count(*) FROM avisos WHERE incidencia_id = $1 AND plantilla = 'incidencia_asignada'`, inc.ID); n != 2 {
		t.Errorf("avisos de asignación = %d", n)
	}
	// Una reasignación en 'en_curso' no cambia el estado.
	en := e.llevarA(EnCurso)
	otro := e.ana
	if *en.TecnicoID == e.ana {
		otro = e.beto
	}
	got, err = e.svc.Asignar(e.ctx, en.ID, EntradaAsignar{TecnicoID: otro, Actor: ActorSistema()})
	if err != nil || got.Estado != EnCurso {
		t.Errorf("reasignar en curso: %+v %v", got, err)
	}
}

func TestCambiarPrioridadRecalculaVencimientos(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.crear(nil).Incidencia // P3 lunes 09:00: resolución 1440
	antes := *inc.VenceResolucionEn
	got, err := e.svc.CambiarPrioridad(e.ctx, inc.ID, EntradaCambiarPrioridad{Prioridad: "P2", Motivo: "afecta a todo el área", Actor: ActorTecnico(e.ana)})
	if err != nil || got.Prioridad != "P2" {
		t.Fatal(got, err)
	}
	if !iguales(*got.VenceResolucionEn, L(2026, 10, 5, 18, 0)) || !got.VenceResolucionEn.Before(antes) {
		t.Errorf("con P2 vence el mismo día 18:00; vencía %s y ahora %s", antes.In(lima), got.VenceResolucionEn.In(lima))
	}
	evs, _ := e.svc.Eventos(e.ctx, inc.ID)
	ev := evs[len(evs)-1]
	if ev.Tipo != EvPrioridad || ev.Datos["de"] != "P3" || ev.Datos["a"] != "P2" {
		t.Errorf("evento: %+v", ev)
	}
}

func TestEventosSonInmutables(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.crear(nil).Incidencia
	if _, err := e.db.Exec(e.ctx, `UPDATE incidencia_eventos SET tipo = 'otro' WHERE incidencia_id = $1`, inc.ID); err == nil {
		t.Error("UPDATE de un evento debe fallar")
	}
	if _, err := e.db.Exec(e.ctx, `DELETE FROM incidencia_eventos WHERE incidencia_id = $1`, inc.ID); err == nil {
		t.Error("DELETE de un evento debe fallar")
	}
	if n := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1`, inc.ID); n < 2 {
		t.Errorf("los eventos deben seguir ahí: %d", n)
	}
}

// Varias acciones en una transacción: si una falla, no queda nada.
func TestEnTxEsAtomica(t *testing.T) {
	e := nuevoEntorno(t)
	boom := errors.New("boom")
	err := e.svc.EnTx(e.ctx, func(o *Operaciones) error {
		if _, err := o.Crear(e.ctx, EntradaCrear{PersonaID: &e.pepe, Categoria: "correo", Titulo: "A"}); err != nil {
			return err
		}
		if _, err := o.Crear(e.ctx, EntradaCrear{PersonaID: &e.pepe, Categoria: "vpn", Titulo: "B"}); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatal(err)
	}
	for _, t2 := range []string{"incidencias", "incidencia_eventos", "outbox_analitica", "avisos", "decisiones"} {
		if n := e.contar(`SELECT count(*) FROM ` + t2); n != 0 {
			t.Errorf("%s quedó con %d filas tras el rollback", t2, n)
		}
	}
	// Y confirmada, deja las dos con numeración consecutiva.
	var a, b *Resultado
	err = e.svc.EnTx(e.ctx, func(o *Operaciones) error {
		var err error
		if a, err = o.Crear(e.ctx, EntradaCrear{PersonaID: &e.pepe, Categoria: "correo", Titulo: "A"}); err != nil {
			return err
		}
		b, err = o.Crear(e.ctx, EntradaCrear{PersonaID: &e.pepe, Categoria: "vpn", Titulo: "B"})
		return err
	})
	if err != nil || a.Incidencia.ID == b.Incidencia.ID {
		t.Fatal(a, b, err)
	}
}

// Dos técnicos responden a la vez: la fila se bloquea y solo una respuesta es la primera.
func TestAccionesConcurrentesSeSerializan(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.crear(nil).Incidencia
	const n = 6
	res := make(chan error, n)
	for i := 0; i < n; i++ {
		go func() {
			_, err := e.svc.Responder(e.ctx, inc.ID, EntradaResponder{Texto: "yo", Actor: ActorTecnico(e.ana)})
			res <- err
		}()
	}
	for i := 0; i < n; i++ {
		if err := <-res; err != nil {
			t.Fatal(err)
		}
	}
	if got := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'primera_respuesta'`, inc.ID); got != 1 {
		t.Errorf("primeras respuestas = %d, quiere exactamente 1", got)
	}
	if got := e.contar(`SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'comentario'`, inc.ID); got != n-1 {
		t.Errorf("comentarios = %d", got)
	}
	// Las versiones de estado en el outbox no se repiten.
	vistas := map[float64]bool{}
	for _, f := range e.leerOutbox("incidencias_estado") {
		v := f["version"].(float64)
		if vistas[v] {
			t.Errorf("versión repetida %v", v)
		}
		vistas[v] = true
	}
}

func TestListarYDetalle(t *testing.T) {
	e := nuevoEntorno(t)
	a := e.crear(func(in *EntradaCrear) { in.Titulo = "Impresora atascada"; in.Categoria = "impresoras" }).Incidencia
	b := e.crear(func(in *EntradaCrear) {
		in.Titulo = "VPN lenta"
		in.Categoria = "vpn"
		in.Impacto, in.Urgencia = "sede", "alta"
	}).Incidencia
	e.en(L(2026, 10, 10, 10, 0))
	c := e.crear(func(in *EntradaCrear) { in.Titulo = "Sin asignar" }).Incidencia

	todas, total, err := e.svc.Listar(e.ctx, Filtro{})
	if err != nil || total != 3 || len(todas) != 3 || todas[0].ID != c.ID {
		t.Fatalf("todas: %d %d %v", total, len(todas), err)
	}
	if got, total, _ := e.svc.Listar(e.ctx, Filtro{Prioridad: "P2"}); total != 1 || got[0].ID != b.ID {
		t.Errorf("filtro prioridad: %v", got)
	}
	if got, _, _ := e.svc.Listar(e.ctx, Filtro{Categoria: "impresoras"}); len(got) != 1 || got[0].ID != a.ID {
		t.Errorf("filtro categoría: %v", got)
	}
	if got, _, _ := e.svc.Listar(e.ctx, Filtro{SinAsignar: true}); len(got) != 1 || got[0].ID != c.ID {
		t.Errorf("sin asignar: %v", got)
	}
	if got, _, _ := e.svc.Listar(e.ctx, Filtro{Q: "vpn"}); len(got) != 1 || got[0].ID != b.ID {
		t.Errorf("búsqueda: %v", got)
	}
	if got, _, _ := e.svc.Listar(e.ctx, Filtro{TecnicoID: a.TecnicoID, Estado: "asignada"}); len(got) == 0 {
		t.Errorf("filtro técnico/estado: %v", got)
	}
	if got, total, _ := e.svc.Listar(e.ctx, Filtro{PorPagina: 2, Pagina: 2}); total != 3 || len(got) != 1 {
		t.Errorf("paginación: %d de %d", len(got), total)
	}
	ven := a.VenceResolucionEn.Add(-time.Minute)
	if got, _, _ := e.svc.Listar(e.ctx, Filtro{VencenAntes: &ven, Orden: "vencimiento"}); len(got) < 1 {
		t.Errorf("vencen antes: %v", got)
	}

	d, err := e.svc.Detalle(e.ctx, a.ID)
	if err != nil || d.Incidencia.ID != a.ID || len(d.Eventos) != 3 || d.SLA == nil || len(d.Acciones) == 0 {
		t.Fatalf("detalle: %+v %v", d, err)
	}
	if byNum, err := e.svc.ObtenerPorNumero(e.ctx, a.Numero); err != nil || byNum.ID != a.ID {
		t.Errorf("por número: %v", err)
	}
	if byTok, err := e.svc.ObtenerPorToken(e.ctx, a.TokenPublico); err != nil || byTok.ID != a.ID {
		t.Errorf("por token: %v", err)
	}
}

func TestRegistrarEncuesta(t *testing.T) {
	e := nuevoEntorno(t)
	inc := e.crear(nil).Incidencia
	id, err := e.svc.RegistrarEncuesta(e.ctx, inc.ID, 5, "Muy bien")
	if err != nil || id == 0 {
		t.Fatal(id, err)
	}
	if _, err := e.svc.RegistrarEncuesta(e.ctx, inc.ID, 6, ""); !errors.Is(err, ErrInvalido) {
		t.Errorf("puntaje fuera de rango: %v", err)
	}
	filas := e.leerOutbox("encuestas")
	if len(filas) != 1 || filas[0]["puntaje"] != float64(5) || filas[0]["__clave"] != fmt.Sprintf("enc-%d", id) || filas[0]["incidencia_id"] != float64(inc.ID) {
		t.Errorf("outbox de encuestas: %v", filas)
	}
}

// Una incidencia creada por un caso comparte la transacción: crear + cerrar el caso en un solo COMMIT.
func TestSobreUnaTransaccionAjena(t *testing.T) {
	e := nuevoEntorno(t)
	var casoID int64
	err := e.db.EnTx(e.ctx, func(tx pgxTx) error {
		if err := tx.QueryRow(e.ctx, `INSERT INTO casos (persona_id, canal, chat_id) VALUES ($1, 'web', 's1') RETURNING id`, e.pepe).Scan(&casoID); err != nil {
			return err
		}
		r, err := e.svc.Sobre(tx).Crear(e.ctx, EntradaCrear{PersonaID: &e.pepe, CasoID: &casoID, Categoria: "correo", Titulo: "Desde el caso"})
		if err != nil {
			return err
		}
		_, err = tx.Exec(e.ctx, `UPDATE casos SET estado = 'con_incidencia' WHERE id = $1`, casoID)
		_ = r
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	var estado string
	var n int
	_ = e.db.QueryRow(e.ctx, `SELECT estado FROM casos WHERE id = $1`, casoID).Scan(&estado)
	_ = e.db.QueryRow(e.ctx, `SELECT count(*) FROM incidencias WHERE caso_id = $1`, casoID).Scan(&n)
	if estado != "con_incidencia" || n != 1 {
		t.Errorf("caso %s con %d incidencias", estado, n)
	}
	_ = store.ErrNoEncontrado
}
