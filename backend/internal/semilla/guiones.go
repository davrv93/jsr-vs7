package semilla

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"math/rand/v2"
	"sort"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// Tipos de guion: cada uno es un recorrido distinto de una incidencia, y juntos cubren los
// casos difíciles (PLAN F2: viernes 17:55, feriados, pausas, reaperturas, escalamientos, P1
// fuera de horario, nunca resueltas, sin primera respuesta, encuestas...).
const (
	gNormal        = "normal"           // atendida a tiempo, confirmada, con encuesta a veces
	gPausas        = "pausas"           // una o dos esperas del usuario o de un tercero
	gSinConfirmar  = "sin_confirmacion" // resuelta; nadie confirma: se cierra sola a las 48 h laborales
	gReabierta1    = "reabierta_1"
	gReabierta2    = "reabierta_2"      // dos reaperturas: la regla reapertura_2 escala
	gEscalaSLA     = "escala_sla"       // se atiende tarde: el vigía escala por SLA
	gP1Noche       = "p1_fuera_horario" // P1 de noche o fin de semana: va a la guardia
	gViernes1755   = "viernes_1755"
	gFeriado       = "feriado" // creada en un feriado
	gNuncaResuelta = "nunca_resuelta"
	gSinRespuesta  = "sin_respuesta"
	gQueja         = "queja"
	gGuiaAgotada   = "guia_agotada"
	gVIP           = "vip"
)

// cuota es cuántas incidencias de cada tipo, como fracción del total y con un mínimo.
var cuotas = []struct {
	tipo string
	pct  float64
	min  int
}{
	{gPausas, 0.15, 3}, {gSinConfirmar, 0.07, 2}, {gReabierta1, 0.06, 2}, {gReabierta2, 0.02, 2},
	{gEscalaSLA, 0.08, 3}, {gP1Noche, 0.025, 3}, {gViernes1755, 0.015, 2}, {gFeriado, 0.02, 2},
	{gNuncaResuelta, 0.04, 2}, {gSinRespuesta, 0.03, 2}, {gQueja, 0.02, 2}, {gGuiaAgotada, 0.03, 2}, {gVIP, 0.02, 2},
}

type op struct {
	t    time.Time
	tick bool // los tics del vigía van después de las acciones del mismo instante
	seq  int
	f    func() error
}

// incRef lleva la incidencia de un guion de una operación a la siguiente.
type incRef struct {
	id       int64
	caso     int64
	encuesta int64
}

// generador arma y ejecuta los guiones.
type generador struct {
	ctx   context.Context
	db    *store.DB
	svc   *incidencia.Servicio
	vig   *escala.Vigia
	reloj *incidencia.RelojManual
	rng   *rand.Rand
	lima  *time.Location

	calLab, cal24 *sla.Calendario
	m             *maestros
	matriz        sla.Matriz
	desde, hasta  time.Time
	feriados      map[string]bool

	ops      []op
	seq      int
	ticks    map[int64]bool
	saltadas int
	log      func(string, ...any)
}

func (g *generador) add(t time.Time, f func() error) {
	g.seq++
	g.ops = append(g.ops, op{t: t, seq: g.seq, f: f})
}

func (g *generador) tick(t time.Time) {
	t = t.Truncate(time.Minute)
	if g.ticks[t.Unix()] || t.After(g.hasta) || t.Before(g.desde) {
		return
	}
	g.ticks[t.Unix()] = true
	g.seq++
	g.ops = append(g.ops, op{t: t, tick: true, seq: g.seq, f: func() error {
		inf, err := g.vig.Ciclo(g.ctx, t)
		if err != nil {
			return err
		}
		if len(inf.Errores) > 0 {
			return fmt.Errorf("el vigía devolvió errores en %s: %v", t.In(g.lima).Format("02/01 15:04"), inf.Errores)
		}
		return nil
	}})
}

// ---- tiempo -----------------------------------------------------------------------------------------

// avanza suma `min` minutos a t: laborales (calendario lun-vie con feriados) o reales si la
// prioridad es P1 (corre 24x7).
func (g *generador) avanza(prio string, t time.Time, min float64) time.Time {
	d := time.Duration(min * float64(time.Minute))
	if prio == "P1" {
		return t.Add(d)
	}
	r, err := sla.FechaVencimientoDur(g.calLab, t, d, nil)
	if err != nil {
		return t.Add(d)
	}
	return r
}

func (g *generador) real(t time.Time, min float64) time.Time {
	return t.Add(time.Duration(min * float64(time.Minute)))
}

// uni devuelve un número uniforme en [a, b].
func (g *generador) uni(a, b float64) float64 { return a + g.rng.Float64()*(b-a) }

// logn devuelve un tiempo con cola larga entre a y b (más cerca de a que de b).
func (g *generador) logn(a, b float64) float64 {
	u := g.rng.Float64()
	return a * math.Pow(b/a, u*u)
}

// ---- fechas del periodo ---------------------------------------------------------------------------------

type diaSem struct {
	fecha   time.Time // 00:00 Lima
	laboral bool
	feriado bool
}

func (g *generador) dias() []diaSem {
	var out []diaSem
	for d := time.Date(g.desde.In(g.lima).Year(), g.desde.In(g.lima).Month(), g.desde.In(g.lima).Day(), 0, 0, 0, 0, g.lima); d.Before(g.hasta); d = time.Date(d.Year(), d.Month(), d.Day()+1, 0, 0, 0, 0, g.lima) {
		clave := d.Format("2006-01-02")
		wd := d.Weekday()
		fer := g.feriados[clave]
		out = append(out, diaSem{fecha: d, feriado: fer, laboral: wd != time.Saturday && wd != time.Sunday && !fer})
	}
	return out
}

// instanteAleatorio elige un instante del periodo con la distribución de una mesa de ayuda:
// casi todo en horario laboral, con picos a media mañana, y algo de noche y fin de semana.
func (g *generador) instanteAleatorio(dias []diaSem) time.Time {
	for {
		d := dias[g.rng.IntN(len(dias))]
		if !d.laboral && g.rng.Float64() > 0.18 { // los días no laborables tienen poco tráfico
			continue
		}
		var min float64
		switch {
		case !d.laboral:
			min = g.uni(7*60, 20*60)
		case g.rng.Float64() < 0.86:
			if g.rng.Float64() < 0.55 {
				min = g.uni(8*60+30, 13*60)
			} else {
				min = g.uni(14*60, 18*60)
			}
		default:
			if g.rng.Float64() < 0.6 {
				min = g.uni(18*60, 23*60)
			} else {
				min = g.uni(6*60, 8*60+30)
			}
		}
		t := d.fecha.Add(time.Duration(int(min)) * time.Minute)
		if t.Before(g.desde) || t.After(g.hasta.Add(-2*time.Hour)) {
			continue
		}
		return t
	}
}

// ---- elección de datos de la incidencia ---------------------------------------------------------------------------

func (g *generador) categoria() string {
	total := 0
	for _, c := range pesoCategoria {
		total += c.Peso
	}
	x := g.rng.IntN(total)
	for _, c := range pesoCategoria {
		if x < c.Peso {
			return c.Clave
		}
		x -= c.Peso
	}
	return "otro"
}

func (g *generador) impactoUrgencia() (string, string) {
	x := g.rng.Float64()
	impacto := "persona"
	switch {
	case x > 0.98:
		impacto = "organizacion"
	case x > 0.90:
		impacto = "sede"
	case x > 0.65:
		impacto = "area"
	}
	y := g.rng.Float64()
	urgencia := "media"
	switch {
	case y > 0.95:
		urgencia = "critica"
	case y > 0.70:
		urgencia = "alta"
	case y < 0.20:
		urgencia = "baja"
	}
	return impacto, urgencia
}

func (g *generador) prioridad(impacto, urgencia string, vip bool) string {
	p, _ := g.matriz.Prioridad(impacto, urgencia)
	if vip {
		p, _ = sla.AplicarMinimo(p, "P2")
	}
	return p
}

// guion es todo lo que define a una incidencia sintética.
type guion struct {
	tipo      string
	t0        time.Time
	persona   int
	categoria string
	impacto   string
	urgencia  string
	titulo    string
	canal     string
	motivo    string
	queja     bool
	prio      string
}

// planificar reparte las n incidencias en tipos y arma sus operaciones.
func (g *generador) planificar(n int) {
	dias := g.dias()
	var viernes, feriadosLab []time.Time
	for _, d := range dias {
		if d.fecha.Weekday() == time.Friday && !d.feriado {
			viernes = append(viernes, d.fecha)
		}
		if d.feriado && d.fecha.Weekday() != time.Saturday && d.fecha.Weekday() != time.Sunday {
			feriadosLab = append(feriadosLab, d.fecha)
		}
	}

	var tipos []string
	for _, c := range cuotas {
		k := int(math.Round(float64(n) * c.pct))
		if k < c.min {
			k = c.min
		}
		for i := 0; i < k; i++ {
			tipos = append(tipos, c.tipo)
		}
	}
	for len(tipos) < n {
		tipos = append(tipos, gNormal)
	}
	tipos = tipos[:n]
	g.rng.Shuffle(len(tipos), func(i, j int) { tipos[i], tipos[j] = tipos[j], tipos[i] })

	contadores := map[string]int{}
	for _, tipo := range tipos {
		sc := guion{tipo: tipo, categoria: g.categoria(), canal: "whatsapp"}
		sc.impacto, sc.urgencia = g.impactoUrgencia()
		if g.rng.Float64() < 0.3 {
			sc.canal = "web"
		}
		sc.persona = g.rng.IntN(len(g.m.personas))
		switch tipo {
		case gVIP:
			sc.persona = g.m.vips[g.rng.IntN(len(g.m.vips))]
		}
		k := contadores[tipo]
		contadores[tipo]++
		switch tipo {
		case gViernes1755:
			sc.t0 = time.Date(viernes[k%len(viernes)].Year(), viernes[k%len(viernes)].Month(), viernes[k%len(viernes)].Day(), 17, 55, 0, 0, g.lima)
		case gFeriado:
			if len(feriadosLab) == 0 {
				sc.t0 = g.instanteAleatorio(dias)
			} else {
				f := feriadosLab[k%len(feriadosLab)]
				sc.t0 = time.Date(f.Year(), f.Month(), f.Day(), 9+g.rng.IntN(7), g.rng.IntN(60), 0, 0, g.lima)
			}
		case gP1Noche:
			d := dias[g.rng.IntN(len(dias))]
			hora := []int{22, 23, 0, 1, 2, 3, 4}[g.rng.IntN(7)]
			sc.t0 = time.Date(d.fecha.Year(), d.fecha.Month(), d.fecha.Day(), hora, g.rng.IntN(60), 0, 0, g.lima)
			if sc.t0.Before(g.desde) {
				sc.t0 = sc.t0.AddDate(0, 0, 1)
			}
			sc.categoria = []string{"red_wifi", "vpn", "sistema_interno"}[g.rng.IntN(3)]
			sc.impacto, sc.urgencia = []string{"organizacion", "sede"}[g.rng.IntN(2)], "critica"
		case gNuncaResuelta, gSinRespuesta:
			// Las que quedan abiertas son del último mes y medio: una mesa real las limpiaría antes.
			for sc.t0 = g.instanteAleatorio(dias); sc.t0.Before(g.hasta.AddDate(0, 0, -45)) && g.hasta.Sub(g.desde) > 60*24*time.Hour; sc.t0 = g.instanteAleatorio(dias) {
			}
		default:
			sc.t0 = g.instanteAleatorio(dias)
		}
		switch x := g.rng.Float64(); {
		case tipo == gGuiaAgotada:
			sc.motivo = "guia_agotada"
		case x < 0.6:
			sc.motivo = "sin_articulo"
		case x < 0.9:
			sc.motivo = "pidio_tecnico"
		default:
			sc.motivo = "guia_agotada"
		}
		sc.queja = tipo == gQueja && g.rng.Float64() < 0.5
		titulos := titulosPorCategoria[sc.categoria]
		sc.titulo = titulos[g.rng.IntN(len(titulos))]
		sc.prio = g.prioridad(sc.impacto, sc.urgencia, g.m.personas[sc.persona].VIP)
		g.planIncidencia(sc)
	}
}

// receta describe el recorrido de un tipo de guion.
type receta struct {
	respuestaTarde  bool
	sinRespuesta    bool
	pausas          int
	resolver        bool
	resolucionTarde bool
	reaperturas     int
	cierre          string // confirmado | sin
	encuesta        float64
}

func recetaDe(tipo string, rng *rand.Rand) receta {
	r := receta{resolver: true, cierre: "confirmado", encuesta: 0.6}
	if rng.Float64() < 0.07 { // un 7 % de las atenciones llega tarde aunque el guion sea normal
		r.respuestaTarde = true
	}
	if rng.Float64() < 0.06 {
		r.resolucionTarde = true
	}
	switch tipo {
	case gPausas:
		r.pausas = 1 + rng.IntN(2)
	case gSinConfirmar:
		r.cierre = "sin"
	case gReabierta1:
		r.reaperturas = 1
	case gReabierta2:
		r.reaperturas = 2
	case gEscalaSLA:
		r.respuestaTarde, r.resolucionTarde = true, rng.Float64() < 0.6
	case gNuncaResuelta:
		r.resolver, r.cierre = false, ""
	case gSinRespuesta:
		r.sinRespuesta, r.resolver, r.cierre = true, false, ""
	case gQueja:
		r.respuestaTarde = rng.Float64() < 0.5
	}
	if rng.Float64() < 0.12 && r.cierre == "confirmado" && tipo == gNormal {
		r.cierre = "sin"
	}
	return r
}

func (g *generador) durResp(prio string, tarde bool) float64 {
	switch prio {
	case "P1":
		if tarde {
			return g.uni(20, 90)
		}
		return g.uni(3, 14)
	case "P2":
		if tarde {
			return g.uni(35, 180)
		}
		return g.uni(5, 25)
	case "P3":
		if tarde {
			return g.uni(130, 600)
		}
		return g.logn(10, 100)
	}
	if tarde {
		return g.uni(250, 1500)
	}
	return g.logn(20, 200)
}

func (g *generador) durResol(prio string, tarde bool) float64 {
	switch prio {
	case "P1":
		if tarde {
			return g.uni(260, 900)
		}
		return g.uni(40, 200)
	case "P2":
		if tarde {
			return g.uni(500, 1500)
		}
		return g.logn(30, 300)
	case "P3":
		if tarde {
			return g.uni(1500, 4000)
		}
		return g.logn(60, 900)
	}
	if tarde {
		return g.uni(3000, 8000)
	}
	return g.logn(120, 2000)
}

// planIncidencia arma las operaciones de una incidencia según su guion.
func (g *generador) planIncidencia(sc guion) {
	rc := recetaDe(sc.tipo, g.rng)
	ref := &incRef{}
	p := g.m.personas[sc.persona]
	g.add(sc.t0, g.opCrear(sc, ref))
	if sc.prio == "P1" || p.VIP || sc.motivo == "guia_agotada" || sc.queja {
		g.tick(sc.t0.Add(time.Minute)) // las reglas de evento actúan de inmediato
	}
	t := sc.t0
	if g.rng.Float64() < 0.3 {
		g.add(g.real(t, g.uni(10, 60)), g.opDato(ref))
	}
	if sc.tipo == gQueja || sc.queja {
		tq := g.real(t, g.uni(20, 120))
		g.add(tq, g.opQueja(ref))
		g.tick(tq.Add(time.Minute))
	}
	malo := rc.respuestaTarde || rc.resolucionTarde || rc.reaperturas > 0
	if rc.sinRespuesta {
		return
	}
	dr := g.durResp(sc.prio, rc.respuestaTarde)
	if sc.prio != "P1" {
		dr = math.Max(dr, 15) // si nació fuera de turno, el técnico entra a las 08:30 y tarda un poco
	}
	tr := g.avanza(sc.prio, t, dr)
	g.add(tr, g.opResponder(ref))
	t = tr
	if g.rng.Float64() < 0.25 {
		g.add(g.real(t, g.uni(5, 30)), g.opComentarioInterno(ref))
	}
	for i := 0; i < rc.pausas; i++ {
		motivo := "espera_usuario"
		if g.rng.Float64() < 0.35 {
			motivo = "espera_tercero"
		}
		tp := g.avanza(sc.prio, t, g.uni(10, 90))
		g.add(tp, g.opPausar(ref, motivo))
		tw := g.avanza(sc.prio, tp, g.uni(60, 1500))
		g.add(tw, g.opReanudar(ref))
		t = tw
	}
	if !rc.resolver {
		return
	}
	tz := g.avanza(sc.prio, t, g.durResol(sc.prio, rc.resolucionTarde))
	g.add(tz, g.opResolver(ref))
	t = tz
	for i := 0; i < rc.reaperturas; i++ {
		trea := g.real(t, g.uni(60, 2400))
		g.add(trea, g.opReabrir(ref))
		if i == 1 {
			g.tick(trea.Add(time.Minute))
		}
		tr2 := g.avanza(sc.prio, trea, g.uni(10, 120))
		g.add(tr2, g.opResponder(ref))
		tz2 := g.avanza(sc.prio, tr2, g.uni(60, 600))
		g.add(tz2, g.opResolver(ref))
		t = tz2
	}
	if rc.cierre == "confirmado" {
		tc := g.real(t, g.uni(20, 1500))
		g.add(tc, g.opCerrar(ref))
		if g.rng.Float64() < 0.85 { // se envía la encuesta; no todas se responden (tasa de respuesta)
			te := g.real(tc, g.uni(1, 5))
			g.add(te, g.opEncuestaEnviar(ref))
			if g.rng.Float64() < rc.encuesta+0.15 {
				puntaje := 4 + g.rng.IntN(2)
				if malo {
					puntaje = 1 + g.rng.IntN(3)
				} else if g.rng.Float64() < 0.1 {
					puntaje = 3
				}
				g.add(g.real(te, g.uni(5, 600)), g.opEncuestaResponder(ref, puntaje))
			}
		}
	}
}

// planCasosAsistente agrega los casos que el asistente resolvió solo, sin incidencia.
func (g *generador) planCasosAsistente(n int) {
	dias := g.dias()
	for i := 0; i < n; i++ {
		t := g.instanteAleatorio(dias)
		p := g.m.personas[g.rng.IntN(len(g.m.personas))]
		canal := "whatsapp"
		if g.rng.Float64() < 0.4 {
			canal = "web"
		}
		estado := "resuelto_asistente"
		if g.rng.Float64() < 0.22 {
			estado = "cerrado" // la persona se fue sin confirmar: no cuenta como contención
		}
		cat := g.categoria()
		nMsgs := 3 + g.rng.IntN(4)
		textos := make([][2]string, nMsgs)
		metas := make([][]byte, nMsgs)
		for j := range textos {
			if j%2 == 0 {
				textos[j] = [2]string{"usuario", frasesUsuario[g.rng.IntN(len(frasesUsuario))]}
			} else {
				textos[j] = [2]string{"asistente", frasesAsistente[g.rng.IntN(len(frasesAsistente))]}
			}
			metas[j] = g.metaMensaje(cat, textos[j][0])
		}
		feedback := ""
		if estado == "resuelto_asistente" {
			feedback = "se_resolvio"
		}
		pulgar := ""
		if g.rng.Float64() < 0.3 {
			pulgar = []string{"pulgar_arriba", "pulgar_arriba", "pulgar_abajo"}[g.rng.IntN(3)]
		}
		g.add(t, func() error {
			ts := g.reloj.Ahora()
			caso, err := g.insertarCaso(p.ID, canal, ts.Add(-time.Duration(nMsgs)*time.Minute), ts, estado)
			if err != nil {
				return err
			}
			var ultimoAsistente *int64 // el pulgar se refiere a la última respuesta del asistente
			for j, m := range textos {
				id, err := g.insertarMensaje(caso, ts.Add(-time.Duration(nMsgs-j)*time.Minute), m[0], m[1], metas[j])
				if err != nil {
					return err
				}
				if m[0] == "asistente" {
					idc := id
					ultimoAsistente = &idc
				}
			}
			if feedback != "" {
				if err := g.insertarFeedback(caso, nil, feedback, "", nil, ts); err != nil {
					return err
				}
			}
			if pulgar != "" {
				if err := g.insertarFeedback(caso, nil, pulgar, "", ultimoAsistente, ts); err != nil {
					return err
				}
			}
			return analitica.EncolarCaso(g.ctx, g.db, caso)
		})
	}
}

// ---- tics de la rejilla del vigía ----------------------------------------------------------------------------------

// planTics deja la rejilla de pasadas del vigía: cada 30 minutos en horario laboral (a las
// :01 y :31, así a las 08:31 la cola ya se despacha) y cada pocas horas el resto del tiempo.
func (g *generador) planTics() {
	for _, d := range g.dias() {
		y, m, dd := d.fecha.Date()
		at := func(h, mi int) time.Time { return time.Date(y, m, dd, h, mi, 0, 0, g.lima) }
		if d.laboral {
			for t := at(8, 31); !t.After(at(18, 1)); t = t.Add(30 * time.Minute) {
				g.tick(t)
			}
			for _, h := range []int{20, 23} {
				g.tick(at(h, 1))
			}
			for _, h := range []int{3, 6} {
				g.tick(at(h, 1))
			}
		} else {
			for _, h := range []int{3, 7, 10, 13, 16, 19, 22} {
				g.tick(at(h, 1))
			}
		}
	}
}

// ---- operaciones -----------------------------------------------------------------------------------------------------

var errSaltar = fmt.Errorf("se salta: el estado ya no lo permite")

// seguro ejecuta una acción de guion; si el estado de la incidencia ya no la permite (porque
// el vigía la escaló, se cerró sola, nadie la atendió...), la salta sin error: así el guion
// describe la intención y la realidad (reglas y estado) decide.
func (g *generador) seguro(err error) error {
	if err == nil {
		return nil
	}
	if err == errSaltar || isTransicion(err) {
		g.saltadas++
		return nil
	}
	return err
}

func (g *generador) textoRespuesta() string {
	return []string{"Hola, ya estoy revisando tu caso.", "Estoy en ello, te aviso en breve.", "Lo reviso ahora mismo.", "Hecho el cambio, ¿puedes probar?"}[g.rng.IntN(4)]
}

func (g *generador) metaMensaje(categoria, rol string) []byte {
	m := map[string]any{}
	if rol == "usuario" {
		m = map[string]any{"intencion": []string{"reportar_falla", "aportar_dato", "confirmar_solucion", "sigue_igual"}[g.rng.IntN(4)],
			"confianza": math.Round(g.uni(0.6, 0.99)*100) / 100, "categoria": categoria}
	} else {
		m = map[string]any{"latencia_ms": 200 + g.rng.IntN(700), "costo_usd": math.Round(g.uni(0.0002, 0.002)*1e6) / 1e6,
			"regenerada": g.rng.Float64() < 0.05, "frases_quitadas": g.rng.IntN(2), "juez": map[string]any{"modo": "sombra"}}
	}
	b, _ := json.Marshal(m)
	return b
}

func isTransicion(err error) bool {
	return err != nil && (errorsIs(err, incidencia.ErrTransicionInvalida) || errorsIs(err, incidencia.ErrInvalido))
}

func (g *generador) opCrear(sc guion, ref *incRef) func() error {
	p := g.m.personas[sc.persona]
	nPre := 2 + g.rng.IntN(3)
	pre := make([][2]string, nPre)
	metas := make([][]byte, nPre+1)
	for i := range pre {
		if i%2 == 0 {
			pre[i] = [2]string{"usuario", frasesUsuario[g.rng.IntN(4)]}
		} else {
			pre[i] = [2]string{"asistente", frasesAsistente[g.rng.IntN(5)]}
		}
		metas[i] = g.metaMensaje(sc.categoria, pre[i][0])
	}
	metas[nPre] = g.metaMensaje(sc.categoria, "asistente")
	return func() error {
		ts := g.reloj.Ahora()
		caso, err := g.insertarCaso(p.ID, sc.canal, ts.Add(-time.Duration(nPre+1)*time.Minute), ts, "con_incidencia")
		if err != nil {
			return err
		}
		for i, m := range pre {
			if _, err := g.insertarMensaje(caso, ts.Add(-time.Duration(nPre-i)*time.Minute), m[0], m[1], metas[i]); err != nil {
				return err
			}
		}
		if _, err := g.insertarMensaje(caso, ts, "sistema", "Registré tu incidencia.", metas[nPre]); err != nil {
			return err
		}
		pid := p.ID
		r, err := g.svc.Crear(g.ctx, incidencia.EntradaCrear{
			PersonaID: &pid, CasoID: &caso, Categoria: sc.categoria, Impacto: sc.impacto, Urgencia: sc.urgencia,
			Titulo: sc.titulo, Resumen: sc.titulo + " (caso sintético)", Canal: sc.canal, Motivo: sc.motivo, Queja: sc.queja,
		})
		if err != nil {
			return fmt.Errorf("crear la incidencia sintética: %w", err)
		}
		ref.id, ref.caso = r.Incidencia.ID, caso
		return analitica.EncolarCaso(g.ctx, g.db, caso)
	}
}

// tecnicoActual devuelve el actor técnico de la incidencia o errSaltar si no tiene.
func (g *generador) incActual(ref *incRef) (*incidencia.Incidencia, error) {
	if ref.id == 0 {
		return nil, errSaltar
	}
	return g.svc.Obtener(g.ctx, ref.id)
}

func (g *generador) opResponder(ref *incRef) func() error {
	txt := g.textoRespuesta()
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		if inc.TecnicoID == nil {
			return g.seguro(errSaltar)
		}
		_, err = g.svc.Responder(g.ctx, ref.id, incidencia.EntradaResponder{Texto: txt, Actor: incidencia.ActorTecnico(*inc.TecnicoID)})
		return g.seguro(err)
	}
}

func (g *generador) opResolver(ref *incRef) func() error {
	txt := g.textoRespuesta()
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		if inc.TecnicoID == nil {
			return g.seguro(errSaltar)
		}
		tec := incidencia.ActorTecnico(*inc.TecnicoID)
		err = g.svc.EnTx(g.ctx, func(o *incidencia.Operaciones) error {
			switch inc.Estado {
			case incidencia.Asignada, incidencia.Reabierta:
				if _, err := o.Responder(g.ctx, ref.id, incidencia.EntradaResponder{Texto: txt, Actor: tec}); err != nil {
					return err
				}
			case incidencia.EsperaUsuario, incidencia.EsperaTercero:
				if _, err := o.Reanudar(g.ctx, ref.id, incidencia.EntradaReanudar{Actor: tec}); err != nil {
					return err
				}
			}
			_, err := o.Resolver(g.ctx, ref.id, incidencia.EntradaResolver{Solucion: "Solución aplicada (sintético).", Actor: tec})
			return err
		})
		return g.seguro(err)
	}
}

func (g *generador) opPausar(ref *incRef, motivo string) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		if inc.TecnicoID == nil {
			return g.seguro(errSaltar)
		}
		_, err = g.svc.Pausar(g.ctx, ref.id, incidencia.EntradaPausar{Motivo: motivo, Actor: incidencia.ActorTecnico(*inc.TecnicoID)})
		return g.seguro(err)
	}
}

func (g *generador) opReanudar(ref *incRef) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		actor := incidencia.ActorSistema()
		if inc.PersonaID != nil {
			actor = incidencia.ActorUsuario(*inc.PersonaID)
		}
		_, err = g.svc.Reanudar(g.ctx, ref.id, incidencia.EntradaReanudar{Actor: actor})
		return g.seguro(err)
	}
}

func (g *generador) opReabrir(ref *incRef) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		actor := incidencia.ActorAsistente()
		if inc.PersonaID != nil {
			actor = incidencia.ActorUsuario(*inc.PersonaID)
		}
		if _, err := g.svc.Reabrir(g.ctx, ref.id, incidencia.EntradaReabrir{Motivo: "sigue igual", Actor: actor}); err != nil {
			return g.seguro(err)
		}
		return g.insertarFeedback(ref.caso, &ref.id, "sigue_igual", "", nil, g.reloj.Ahora())
	}
}

func (g *generador) opCerrar(ref *incRef) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		actor := incidencia.ActorAsistente()
		if inc.PersonaID != nil {
			actor = incidencia.ActorUsuario(*inc.PersonaID)
		}
		if _, err := g.svc.Cerrar(g.ctx, ref.id, incidencia.EntradaCerrar{Motivo: incidencia.CierreConfirmado, Actor: actor}); err != nil {
			return g.seguro(err)
		}
		return g.insertarFeedback(ref.caso, &ref.id, "se_resolvio", "", nil, g.reloj.Ahora())
	}
}

// opEncuestaEnviar escribe la fila de la encuesta al ENVIARLA (puntaje NULL = sin responder), como
// hace la pasarela, y deja su fila en el outbox.
func (g *generador) opEncuestaEnviar(ref *incRef) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		if inc.Estado != incidencia.Cerrada {
			return g.seguro(errSaltar)
		}
		var caso any
		if inc.CasoID != nil {
			caso = *inc.CasoID
		}
		if err := g.db.QueryRow(g.ctx, `INSERT INTO encuestas (incidencia_id, caso_id, puntaje, ts) VALUES ($1, $2, NULL, $3) RETURNING id`,
			ref.id, caso, g.reloj.Ahora()).Scan(&ref.encuesta); err != nil {
			return fmt.Errorf("enviar la encuesta sintética: %w", err)
		}
		return analitica.EncolarEncuesta(g.ctx, g.db, ref.encuesta)
	}
}

// opEncuestaResponder anota el puntaje y reenvía la MISMA clave enc-<id> al outbox (ts sigue siendo el del envío).
func (g *generador) opEncuestaResponder(ref *incRef, puntaje int) func() error {
	return func() error {
		if ref.encuesta == 0 {
			return g.seguro(errSaltar)
		}
		if _, err := g.db.Exec(g.ctx, `UPDATE encuestas SET puntaje = $2 WHERE id = $1`, ref.encuesta, puntaje); err != nil {
			return fmt.Errorf("responder la encuesta sintética: %w", err)
		}
		return analitica.EncolarEncuesta(g.ctx, g.db, ref.encuesta)
	}
}

func (g *generador) opQueja(ref *incRef) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		actor := incidencia.ActorUsuario(0)
		if inc.PersonaID != nil {
			actor = incidencia.ActorUsuario(*inc.PersonaID)
		}
		_, err = g.svc.RegistrarQueja(g.ctx, ref.id, incidencia.EntradaQueja{Actor: actor})
		return g.seguro(err)
	}
}

func (g *generador) opDato(ref *incRef) func() error {
	clave := []string{"equipo", "mensaje_error", "desde", "sede"}[g.rng.IntN(4)]
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		actor := incidencia.ActorUsuario(0)
		if inc.PersonaID != nil {
			actor = incidencia.ActorUsuario(*inc.PersonaID)
		}
		_, err = g.svc.AgregarDato(g.ctx, ref.id, incidencia.EntradaDato{Clave: clave, Valor: "dato sintético", Actor: actor})
		return g.seguro(err)
	}
}

func (g *generador) opComentarioInterno(ref *incRef) func() error {
	return func() error {
		inc, err := g.incActual(ref)
		if err != nil {
			return g.seguro(err)
		}
		if inc.TecnicoID == nil {
			return g.seguro(errSaltar)
		}
		_, err = g.svc.Comentar(g.ctx, ref.id, incidencia.EntradaComentar{Texto: "Nota interna sintética.", Interno: true, Actor: incidencia.ActorTecnico(*inc.TecnicoID)})
		return g.seguro(err)
	}
}

// ---- inserciones de casos, mensajes y feedback (con su fila de outbox) -------------------------------------------------------

func (g *generador) insertarCaso(personaID int, canal string, inicio, ultimo time.Time, estado string) (int64, error) {
	var id int64
	err := g.db.QueryRow(g.ctx, `INSERT INTO casos (persona_id, canal, chat_id, estado, inicio, ultimo_mensaje)
		VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`, personaID, canal, fmt.Sprintf("sint-%d-%d", personaID, inicio.Unix()), estado, inicio, ultimo).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("insertar caso sintético: %w", err)
	}
	return id, nil
}

func (g *generador) insertarMensaje(caso int64, ts time.Time, rol, texto string, meta []byte) (int64, error) {
	var id int64
	err := g.db.QueryRow(g.ctx, `INSERT INTO mensajes (caso_id, ts, rol, texto, meta) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		caso, ts, rol, texto, meta).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("insertar mensaje sintético: %w", err)
	}
	return id, analitica.EncolarMensaje(g.ctx, g.db, id)
}

func (g *generador) insertarFeedback(caso int64, incID *int64, senal, valor string, mensaje *int64, ts time.Time) error {
	var c any
	if caso != 0 {
		c = caso
	}
	var id int64
	if err := g.db.QueryRow(g.ctx, `INSERT INTO feedback (caso_id, incidencia_id, mensaje_id, senal, valor, ts) VALUES ($1, $2, $3, $4, NULLIF($5, ''), $6) RETURNING id`,
		c, incID, mensaje, senal, valor, ts).Scan(&id); err != nil {
		return fmt.Errorf("insertar feedback sintético: %w", err)
	}
	return analitica.EncolarFeedback(g.ctx, g.db, id)
}

// ejecutar corre todas las operaciones en orden cronológico moviendo el reloj.
func (g *generador) ejecutar() error {
	sort.SliceStable(g.ops, func(i, j int) bool {
		a, b := g.ops[i], g.ops[j]
		if !a.t.Equal(b.t) {
			return a.t.Before(b.t)
		}
		if a.tick != b.tick {
			return !a.tick
		}
		return a.seq < b.seq
	})
	for i, o := range g.ops {
		if o.t.After(g.hasta) {
			continue // lo que habría pasado después del corte no existe todavía
		}
		g.reloj.Fijar(o.t)
		if err := o.f(); err != nil {
			return fmt.Errorf("operación %d (%s): %w", i, o.t.In(g.lima).Format("2006-01-02 15:04"), err)
		}
		if g.log != nil && i%500 == 0 {
			g.log("semilla: %d/%d operaciones (%s)", i, len(g.ops), o.t.In(g.lima).Format("02/01"))
		}
	}
	return nil
}
