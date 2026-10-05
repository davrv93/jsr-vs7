package sla

import (
	"math"
	"math/rand/v2"
	"testing"
	"time"
)

const horarioLaboral = `{"1":[["08:30","13:00"],["14:00","18:00"]],"2":[["08:30","13:00"],["14:00","18:00"]],
"3":[["08:30","13:00"],["14:00","18:00"]],"4":[["08:30","13:00"],["14:00","18:00"]],
"5":[["08:30","13:00"],["14:00","18:00"]],"6":[],"7":[]}`

// Feriados de Perú 2026 usados en las pruebas (los mismos que la semilla de configuración).
var feriados2026 = map[string]string{
	"2026-01-01": "Año Nuevo", "2026-04-02": "Jueves Santo", "2026-04-03": "Viernes Santo",
	"2026-05-01": "Día del Trabajo", "2026-06-29": "San Pedro y San Pablo",
	"2026-07-23": "Día de la Fuerza Aérea", "2026-07-28": "Fiestas Patrias", "2026-07-29": "Fiestas Patrias",
	"2026-08-06": "Batalla de Junín", "2026-10-08": "Combate de Angamos", "2026-12-08": "Inmaculada Concepción",
	"2026-12-09": "Batalla de Ayacucho", "2026-12-25": "Navidad",
}

func calLima(t testing.TB) *Calendario {
	t.Helper()
	c, err := NuevoCalendario("laboral_lima", "America/Lima", false, []byte(horarioLaboral))
	if err != nil {
		t.Fatal(err)
	}
	for f, n := range feriados2026 {
		if err := c.AgregarFeriado(f, n); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

func cal247(t testing.TB) *Calendario {
	t.Helper()
	c, err := NuevoCalendario("24x7", "America/Lima", true, nil)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

var lima = func() *time.Location {
	l, err := time.LoadLocation("America/Lima")
	if err != nil {
		panic(err)
	}
	return l
}()

// L arma un instante en hora de Lima.
func L(y int, m time.Month, d, h, mi int) time.Time { return time.Date(y, m, d, h, mi, 0, 0, lima) }

func cercano(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

func TestMinutosLaborales(t *testing.T) {
	c := calLima(t)
	casos := []struct {
		nombre       string
		desde, hasta time.Time
		quiere       float64
	}{
		{"misma hora laboral", L(2026, 10, 5, 9, 0), L(2026, 10, 5, 10, 0), 60},
		{"el almuerzo no cuenta", L(2026, 10, 5, 12, 30), L(2026, 10, 5, 14, 30), 60},
		{"día completo", L(2026, 10, 5, 0, 0), L(2026, 10, 6, 0, 0), 510},
		{"viernes 17:55 a lunes 09:00", L(2026, 10, 9, 17, 55), L(2026, 10, 12, 9, 0), 35},
		{"solo fin de semana", L(2026, 10, 10, 10, 0), L(2026, 10, 11, 20, 0), 0},
		{"feriado en medio (jueves 23-jul)", L(2026, 7, 22, 17, 30), L(2026, 7, 24, 9, 0), 60},
		{"dos feriados seguidos (28 y 29-jul)", L(2026, 7, 27, 17, 0), L(2026, 7, 30, 9, 0), 60 + 30},
		{"feriado entre semana (8-oct)", L(2026, 10, 7, 17, 0), L(2026, 10, 9, 9, 0), 60 + 30},
		{"hasta anterior a desde", L(2026, 10, 5, 12, 0), L(2026, 10, 5, 9, 0), 0},
		{"igual", L(2026, 10, 5, 9, 0), L(2026, 10, 5, 9, 0), 0},
		// Cruce de medianoche UTC: 04:30Z del martes es lunes 23:30 en Lima (fuera de horario).
		{"cruce de medianoche UTC (noche del lunes)",
			time.Date(2026, 10, 6, 4, 30, 0, 0, time.UTC), time.Date(2026, 10, 6, 14, 0, 0, 0, time.UTC), 30},
		// 01:00Z del sábado es viernes 20:00 en Lima; 14:00Z del lunes es lunes 09:00 en Lima.
		{"cruce UTC: sábado en UTC, viernes en Lima",
			time.Date(2026, 10, 10, 1, 0, 0, 0, time.UTC), time.Date(2026, 10, 12, 14, 0, 0, 0, time.UTC), 30},
		// 22:55Z del viernes es viernes 17:55 en Lima.
		{"viernes 17:55 expresado en UTC",
			time.Date(2026, 10, 9, 22, 55, 0, 0, time.UTC), time.Date(2026, 10, 12, 14, 0, 0, 0, time.UTC), 35},
		{"una semana completa sin feriados", L(2026, 10, 12, 0, 0), L(2026, 10, 19, 0, 0), 5 * 510},
	}
	for _, tc := range casos {
		t.Run(tc.nombre, func(t *testing.T) {
			if got := MinutosLaborales(c, tc.desde, tc.hasta); !cercano(got, tc.quiere) {
				t.Errorf("MinutosLaborales = %v, quiere %v", got, tc.quiere)
			}
		})
	}
}

func TestMinutosLaboralesVeinticuatroSiete(t *testing.T) {
	c := cal247(t)
	// Un feriado y un fin de semana cuentan completos.
	if got := MinutosLaborales(c, L(2026, 10, 7, 22, 0), L(2026, 10, 9, 2, 0)); !cercano(got, 28*60) {
		t.Errorf("24x7 con feriado = %v, quiere %v", got, 28*60)
	}
	if got := MinutosLaborales(c, L(2026, 10, 10, 0, 0), L(2026, 10, 12, 0, 0)); !cercano(got, 48*60) {
		t.Errorf("24x7 fin de semana = %v", got)
	}
}

func TestFechaVencimiento(t *testing.T) {
	c := calLima(t)
	casos := []struct {
		nombre string
		desde  time.Time
		min    int
		pausas []Intervalo
		quiere time.Time
	}{
		{"viernes 17:55 + 60 salta al lunes", L(2026, 10, 9, 17, 55), 60, nil, L(2026, 10, 12, 9, 25)},
		{"viernes 17:55 + 5 vence al cierre", L(2026, 10, 9, 17, 55), 5, nil, L(2026, 10, 9, 18, 0)},
		{"viernes 17:55 + 6 pasa al lunes", L(2026, 10, 9, 17, 55), 6, nil, L(2026, 10, 12, 8, 31)},
		{"feriado en medio", L(2026, 7, 22, 17, 30), 120, nil, L(2026, 7, 24, 10, 0)},
		{"fin de semana", L(2026, 10, 10, 10, 0), 30, nil, L(2026, 10, 12, 9, 0)},
		{"almuerzo", L(2026, 10, 5, 12, 30), 60, nil, L(2026, 10, 5, 14, 30)},
		{"un día exacto", L(2026, 10, 5, 8, 30), 510, nil, L(2026, 10, 5, 18, 0)},
		{"un día y un minuto", L(2026, 10, 5, 8, 30), 511, nil, L(2026, 10, 6, 8, 31)},
		{"cero minutos", L(2026, 10, 10, 10, 0), 0, nil, L(2026, 10, 10, 10, 0)},
		// Cruce UTC: 03:30Z del martes = lunes 22:30 Lima; 30 min laborales vencen martes 09:00 Lima (14:00Z).
		{"cruce de medianoche UTC", time.Date(2026, 10, 6, 3, 30, 0, 0, time.UTC), 30, nil,
			time.Date(2026, 10, 6, 14, 0, 0, 0, time.UTC)},
		{"viernes 17:55 Lima en UTC", time.Date(2026, 10, 9, 22, 55, 0, 0, time.UTC), 60, nil,
			time.Date(2026, 10, 12, 14, 25, 0, 0, time.UTC)},
		{"una pausa dentro del plazo", L(2026, 10, 5, 9, 0), 120,
			[]Intervalo{{L(2026, 10, 5, 10, 0), L(2026, 10, 5, 11, 0)}}, L(2026, 10, 5, 12, 0)},
		// 09:00-12:00 son 180 min; la pausa 12:00-15:00 detiene el reloj; los 60 que faltan corren 15:00-16:00.
		{"pausa que cruza el almuerzo", L(2026, 10, 5, 9, 0), 240,
			[]Intervalo{{L(2026, 10, 5, 12, 0), L(2026, 10, 5, 15, 0)}}, L(2026, 10, 5, 16, 0)},
		// Dos pausas: 60 min corridos, pausa 10-11, 90 min más hasta 12:30, pausa hasta mañana 09:00,
		// y los 90 min que faltan terminan mañana a las 10:30.
		{"dos pausas", L(2026, 10, 5, 9, 0), 240,
			[]Intervalo{{L(2026, 10, 5, 10, 0), L(2026, 10, 5, 11, 0)}, {L(2026, 10, 5, 12, 30), L(2026, 10, 6, 9, 0)}},
			L(2026, 10, 6, 10, 30)},
		// Las pausas se unen en 10:00-11:30: corren 09:00-10:00 (60) y 11:30-12:30 (60).
		{"pausas desordenadas y solapadas", L(2026, 10, 5, 9, 0), 120,
			[]Intervalo{{L(2026, 10, 5, 10, 30), L(2026, 10, 5, 11, 30)}, {L(2026, 10, 5, 10, 0), L(2026, 10, 5, 11, 0)}},
			L(2026, 10, 5, 12, 30)},
		{"pausa fuera del horario no descuenta", L(2026, 10, 9, 17, 0), 90,
			[]Intervalo{{L(2026, 10, 9, 19, 0), L(2026, 10, 12, 7, 0)}}, L(2026, 10, 12, 9, 0)},
	}
	for _, tc := range casos {
		t.Run(tc.nombre, func(t *testing.T) {
			got, err := FechaVencimiento(c, tc.desde, tc.min, tc.pausas)
			if err != nil {
				t.Fatal(err)
			}
			if !got.Equal(tc.quiere) {
				t.Errorf("FechaVencimiento = %s, quiere %s", got.In(lima), tc.quiere.In(lima))
			}
			if tc.min > 0 {
				if net := MinutosNetos(c, tc.desde, got, tc.pausas); !cercano(net, float64(tc.min)) {
					t.Errorf("MinutosNetos hasta el vencimiento = %v, quiere %d", net, tc.min)
				}
			}
		})
	}
}

func TestFechaVencimientoP1VeinticuatroSiete(t *testing.T) {
	c := cal247(t)
	casos := []struct {
		nombre string
		desde  time.Time
		min    int
		pausas []Intervalo
		quiere time.Time
	}{
		{"sábado de madrugada", L(2026, 10, 10, 3, 0), 240, nil, L(2026, 10, 10, 7, 0)},
		{"feriado de noche", L(2026, 10, 8, 22, 0), 240, nil, L(2026, 10, 9, 2, 0)},
		{"con una pausa", L(2026, 10, 10, 3, 0), 240, []Intervalo{{L(2026, 10, 10, 4, 0), L(2026, 10, 10, 5, 0)}}, L(2026, 10, 10, 8, 0)},
		{"cruza la medianoche de Lima", L(2026, 10, 11, 22, 0), 240, nil, L(2026, 10, 12, 2, 0)},
	}
	for _, tc := range casos {
		got, err := FechaVencimiento(c, tc.desde, tc.min, tc.pausas)
		if err != nil || !got.Equal(tc.quiere) {
			t.Errorf("%s: = %s (%v), quiere %s", tc.nombre, got.In(lima), err, tc.quiere.In(lima))
		}
	}
}

func TestCalendarioVacioNoCuelga(t *testing.T) {
	c, err := NuevoCalendario("vacio", "America/Lima", false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := FechaVencimiento(c, L(2026, 10, 5, 9, 0), 30, nil); err != ErrSinHorario {
		t.Errorf("err = %v, quiere ErrSinHorario", err)
	}
	// Una pausa abierta que no termina nunca tampoco da fecha.
	cl := calLima(t)
	if _, err := FechaVencimiento(cl, L(2026, 10, 5, 9, 0), 600, []Intervalo{{Desde: L(2026, 10, 5, 10, 0)}}); err != ErrSinHorario {
		t.Errorf("pausa abierta: err = %v, quiere ErrSinHorario", err)
	}
	// Cerrada «ahora», sí hay fecha.
	cerradas := CerrarAbiertas([]Intervalo{{Desde: L(2026, 10, 5, 10, 0)}}, L(2026, 10, 5, 12, 0))
	got, err := FechaVencimiento(cl, L(2026, 10, 5, 9, 0), 120, cerradas)
	if err != nil || !got.Equal(L(2026, 10, 5, 13, 0)) {
		t.Errorf("pausa cerrada: %s %v", got.In(lima), err)
	}
}

// Cambio de horario (zona con horario de verano): el reloj mide tiempo REAL transcurrido
// dentro de los tramos locales, aunque el día tenga 23 o 25 horas.
func TestCambioDeHorario(t *testing.T) {
	ny, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skip("sin base de zonas horarias:", err)
	}
	// Domingo con un tramo 01:30-03:30 local: el 8-mar-2026 a las 02:00 los relojes saltan a 03:00.
	c, err := NuevoCalendario("ny", "America/New_York", false, []byte(`{"7":[["01:30","03:30"]]}`))
	if err != nil {
		t.Fatal(err)
	}
	ini := time.Date(2026, 3, 8, 0, 0, 0, 0, ny)
	fin := time.Date(2026, 3, 9, 0, 0, 0, 0, ny)
	if got := MinutosLaborales(c, ini, fin); !cercano(got, 60) {
		t.Errorf("primavera: = %v, quiere 60 (la hora 02:00-03:00 no existe)", got)
	}
	// Otoño: el 1-nov-2026 a las 02:00 los relojes vuelven a la 01:00 (la hora 01:00 se repite).
	c2, _ := NuevoCalendario("ny2", "America/New_York", false, []byte(`{"7":[["00:30","02:30"]]}`))
	ini = time.Date(2026, 11, 1, 0, 0, 0, 0, ny)
	fin = time.Date(2026, 11, 2, 0, 0, 0, 0, ny)
	if got := MinutosLaborales(c2, ini, fin); !cercano(got, 180) {
		t.Errorf("otoño: = %v, quiere 180 (la hora 01:00 ocurre dos veces)", got)
	}
	// 24x7: el día del cambio dura 23 horas.
	c3, _ := NuevoCalendario("ny24", "America/New_York", true, nil)
	if got := MinutosLaborales(c3, time.Date(2026, 3, 8, 0, 0, 0, 0, ny), time.Date(2026, 3, 9, 0, 0, 0, 0, ny)); !cercano(got, 23*60) {
		t.Errorf("24x7 primavera: = %v, quiere %d", got, 23*60)
	}
	// Un plazo de 90 min que arranca a las 01:30 del cambio vence a las 03:30 locales... menos la hora que no existe.
	v, err := FechaVencimiento(c, time.Date(2026, 3, 8, 1, 30, 0, 0, ny), 60, nil)
	if err != nil || !v.Equal(time.Date(2026, 3, 8, 3, 30, 0, 0, ny)) {
		t.Errorf("vencimiento en primavera = %v %v", v.In(ny), err)
	}
}

func TestEstadoSLA(t *testing.T) {
	c := calLima(t)
	desde := L(2026, 10, 5, 9, 0)
	casos := []struct {
		nombre    string
		corte     time.Time
		pausas    []Intervalo
		pct, rest float64
		venc      bool
	}{
		{"al inicio", L(2026, 10, 5, 9, 0), nil, 0, 60, false},
		{"al 75 %", L(2026, 10, 5, 9, 45), nil, 75, 15, false},
		{"justo en el límite no vence", L(2026, 10, 5, 10, 0), nil, 100, 0, false},
		{"un minuto después vence", L(2026, 10, 5, 10, 1), nil, 100 + 100.0/60, -1, true},
		{"la pausa detiene el reloj", L(2026, 10, 5, 10, 45), []Intervalo{{L(2026, 10, 5, 9, 30), L(2026, 10, 5, 10, 30)}}, 75, 15, false},
		{"pausa abierta: el reloj no avanza", L(2026, 10, 5, 17, 0), []Intervalo{{Desde: L(2026, 10, 5, 9, 30)}}, 50, 30, false},
	}
	for _, tc := range casos {
		e := EstadoSLA(c, desde, tc.corte, 60, tc.pausas)
		if !cercano(e.Porcentaje, tc.pct) || !cercano(e.RestanteMin, tc.rest) || e.Vencida != tc.venc {
			t.Errorf("%s: %+v, quiere pct=%v rest=%v venc=%v", tc.nombre, e, tc.pct, tc.rest, tc.venc)
		}
	}
}

func TestPausasDeEventos(t *testing.T) {
	m := func(h, mi int, tipo string) MarcaReloj { return MarcaReloj{L(2026, 10, 5, h, mi), tipo} }
	marcas := []MarcaReloj{
		m(14, 0, "pausa_inicio"), m(10, 0, "pausa_inicio"), m(11, 0, "pausa_fin"),
		m(12, 0, "comentario"), // se ignora
		m(15, 0, "pausa_fin"),
		m(16, 0, "resuelta"), m(17, 0, "reabierta"),
		m(17, 30, "pausa_inicio"), // queda abierta
	}
	got := PausasDeEventos(marcas)
	quiere := []Intervalo{
		{L(2026, 10, 5, 10, 0), L(2026, 10, 5, 11, 0)},
		{L(2026, 10, 5, 14, 0), L(2026, 10, 5, 15, 0)},
		{L(2026, 10, 5, 16, 0), L(2026, 10, 5, 17, 0)},
		{Desde: L(2026, 10, 5, 17, 30)},
	}
	if len(got) != len(quiere) {
		t.Fatalf("got %d intervalos, quiere %d: %+v", len(got), len(quiere), got)
	}
	for i := range quiere {
		if !got[i].Desde.Equal(quiere[i].Desde) || !got[i].Hasta.Equal(quiere[i].Hasta) {
			t.Errorf("intervalo %d = %+v, quiere %+v", i, got[i], quiere[i])
		}
	}
	// Un pausa_fin suelto no inventa un intervalo.
	if x := PausasDeEventos([]MarcaReloj{m(9, 0, "pausa_fin"), m(10, 0, "reabierta")}); len(x) != 0 {
		t.Errorf("fin suelto = %+v", x)
	}
}

func TestEvaluarIncidenciaCreadaViernesTarde(t *testing.T) {
	c := calLima(t)
	creada := L(2026, 10, 9, 17, 55)
	respuesta := L(2026, 10, 12, 9, 0)
	resuelta := L(2026, 10, 12, 15, 0)
	r := Evaluar(Entrada{
		Cal: c, Pol: Politica{RespuestaMin: 30, ResolucionMin: 480}, Creada: creada,
		PrimeraRespuesta: &respuesta, Resuelta: &resuelta, Ahora: L(2026, 10, 13, 9, 0),
	})
	// 5 min el viernes + 30 el lunes = 35 > 30: respuesta tarde.
	if r.FRTMin == nil || !cercano(*r.FRTMin, 35) || r.RespuestaOK == nil || *r.RespuestaOK {
		t.Errorf("FRT = %v ok=%v", r.FRTMin, r.RespuestaOK)
	}
	// 5 + (08:30-13:00 = 270) + (14:00-15:00 = 60) = 335 <= 480.
	if r.MTTRMin == nil || !cercano(*r.MTTRMin, 335) || r.ResolucionOK == nil || !*r.ResolucionOK {
		t.Errorf("MTTR = %v ok=%v", r.MTTRMin, r.ResolucionOK)
	}
	if !cercano(r.PausaMin, 0) {
		t.Errorf("PausaMin = %v", r.PausaMin)
	}
	if want := L(2026, 10, 12, 8, 30).Add(time.Duration(30-5) * time.Minute); !r.VenceRespuesta.Equal(want) {
		t.Errorf("VenceRespuesta = %s, quiere %s", r.VenceRespuesta.In(lima), want.In(lima))
	}
}

func TestEvaluarSinHitos(t *testing.T) {
	c := calLima(t)
	creada := L(2026, 10, 5, 9, 0)
	// Aún dentro del plazo: nada aplica.
	r := Evaluar(Entrada{Cal: c, Pol: Politica{60, 240}, Creada: creada, Ahora: L(2026, 10, 5, 9, 30)})
	if r.RespuestaOK != nil || r.ResolucionOK != nil || r.FRTMin != nil || r.MTTRMin != nil {
		t.Errorf("no debería aplicar todavía: %+v", r)
	}
	// Pasado el plazo sin respuesta: incumplida sin esperar a la respuesta.
	r = Evaluar(Entrada{Cal: c, Pol: Politica{60, 240}, Creada: creada, Ahora: L(2026, 10, 5, 10, 30)})
	if r.RespuestaOK == nil || *r.RespuestaOK || r.ResolucionOK != nil {
		t.Errorf("respuesta debería estar incumplida y la resolución sin aplicar: %+v", r)
	}
	// Con pausa abierta se cierra en ahora y el vencimiento se corre.
	r = Evaluar(Entrada{Cal: c, Pol: Politica{60, 240}, Creada: creada, Ahora: L(2026, 10, 5, 12, 0),
		Pausas: []Intervalo{{Desde: L(2026, 10, 5, 10, 0)}}})
	if !cercano(r.PausaMin, 120) || !cercano(r.Resolucion.TranscurridoMin, 60) {
		t.Errorf("pausa abierta: pausa=%v transcurrido=%v", r.PausaMin, r.Resolucion.TranscurridoMin)
	}
	// 60 min consumidos antes de las 10:00; faltan 180: desde las 12:00 corren 60 hasta 13:00 y
	// 14:00-16:00 los otros 120 => vence a las 16:00.
	if !r.VenceResolucion.Equal(L(2026, 10, 5, 16, 0)) {
		t.Errorf("VenceResolucion = %s, quiere 16:00", r.VenceResolucion.In(lima))
	}
}

// Propiedad: el reloj hacia delante y el reloj hacia atrás son inversos.
func TestFechaVencimientoEsInversaDeMinutosNetos(t *testing.T) {
	c := calLima(t)
	rng := rand.New(rand.NewPCG(7, 11))
	base := L(2026, 7, 1, 0, 0)
	for i := 0; i < 600; i++ {
		desde := base.Add(time.Duration(rng.IntN(60*24*90)) * time.Minute)
		dur := time.Duration(1+rng.IntN(3000)) * time.Minute
		var pausas []Intervalo
		for j := rng.IntN(4); j > 0; j-- {
			a := desde.Add(time.Duration(rng.IntN(60*24*10)) * time.Minute)
			pausas = append(pausas, Intervalo{a, a.Add(time.Duration(1+rng.IntN(60*30)) * time.Minute)})
		}
		v, err := FechaVencimientoDur(c, desde, dur, pausas)
		if err != nil {
			t.Fatalf("caso %d: %v", i, err)
		}
		if got := DuracionNeta(c, desde, v, pausas); got != dur {
			t.Fatalf("caso %d: neto hasta el vencimiento = %v, quiere %v (desde %s, v %s)", i, got, dur, desde.In(lima), v.In(lima))
		}
		// Un segundo antes todavía no se cumple.
		if got := DuracionNeta(c, desde, v.Add(-time.Second), pausas); got >= dur {
			t.Fatalf("caso %d: un segundo antes ya cumplía (%v)", i, got)
		}
	}
}

func TestParsearHorarioInvalido(t *testing.T) {
	malos := []string{
		`{"8":[["08:00","09:00"]]}`,
		`{"1":[["09:00","08:00"]]}`,
		`{"1":[["08:00","10:00"],["09:00","11:00"]]}`,
		`{"1":[["8h","9h"]]}`,
		`{"1":[["08:00"]]}`,
		`no es json`,
	}
	for _, m := range malos {
		if _, err := ParsearHorario([]byte(m)); err == nil {
			t.Errorf("%s: debería fallar", m)
		}
	}
	if _, err := NuevoCalendario("x", "Mundo/Inventado", false, nil); err == nil {
		t.Error("zona inexistente debería fallar")
	}
	c, _ := NuevoCalendario("x", "America/Lima", false, nil)
	if err := c.AgregarFeriado("2026-13-45", "mal"); err == nil {
		t.Error("feriado inválido debería fallar")
	}
	if h, err := ParsearHorario([]byte(`{"1":[["00:00","24:00"]]}`)); err != nil || h[1][0].Hasta != 1440 {
		t.Errorf("24:00 válido: %v %v", h[1], err)
	}
}

func TestMatrizPorDefecto(t *testing.T) {
	m := MatrizPorDefecto()
	quiere := map[string][4]string{ // crítica, alta, media, baja
		"organizacion": {"P1", "P1", "P2", "P3"},
		"sede":         {"P1", "P2", "P2", "P3"},
		"area":         {"P2", "P2", "P3", "P4"},
		"persona":      {"P2", "P3", "P3", "P4"},
	}
	urg := []string{"critica", "alta", "media", "baja"}
	for imp, fila := range quiere {
		for i, u := range urg {
			if got, err := m.Prioridad(imp, u); err != nil || got != fila[i] {
				t.Errorf("%s x %s = %q (%v), quiere %s", imp, u, got, err, fila[i])
			}
		}
	}
	if _, err := m.Prioridad("planeta", "alta"); err == nil {
		t.Error("impacto inválido debería fallar")
	}
	if _, err := m.Prioridad("sede", "ya"); err == nil {
		t.Error("urgencia inválida debería fallar")
	}
	if _, err := (Matriz{}).Prioridad("sede", "alta"); err == nil {
		t.Error("celda sin configurar debería fallar")
	}
	// La matriz es configurable.
	m.Poner("persona", "baja", "P3")
	if p, _ := m.Prioridad("persona", "baja"); p != "P3" {
		t.Errorf("matriz configurable: %s", p)
	}
}

func TestAplicarMinimoVIP(t *testing.T) {
	casos := []struct {
		p, min, quiere string
		cambia         bool
	}{
		{"P4", "P2", "P2", true}, {"P3", "P2", "P2", true}, {"P2", "P2", "P2", false},
		{"P1", "P2", "P1", false}, {"P9", "P2", "P9", false},
	}
	for _, tc := range casos {
		if got, ch := AplicarMinimo(tc.p, tc.min); got != tc.quiere || ch != tc.cambia {
			t.Errorf("AplicarMinimo(%s,%s) = %s,%v", tc.p, tc.min, got, ch)
		}
	}
}

func TestEsLaboral(t *testing.T) {
	c := calLima(t)
	casos := []struct {
		t      time.Time
		quiere bool
	}{
		{L(2026, 10, 5, 8, 29), false}, {L(2026, 10, 5, 8, 30), true}, {L(2026, 10, 5, 12, 59), true},
		{L(2026, 10, 5, 13, 0), false}, {L(2026, 10, 5, 14, 0), true}, {L(2026, 10, 5, 18, 0), false},
		{L(2026, 10, 10, 10, 0), false}, {L(2026, 10, 8, 10, 0), false},
	}
	for _, tc := range casos {
		if got := c.EsLaboral(tc.t); got != tc.quiere {
			t.Errorf("EsLaboral(%s) = %v", tc.t.In(lima), got)
		}
	}
	if !cal247(t).EsLaboral(L(2026, 10, 10, 3, 0)) {
		t.Error("24x7 siempre es laboral")
	}
	prox, err := c.ProximoLaboral(L(2026, 10, 9, 18, 0))
	if err != nil || !prox.Equal(L(2026, 10, 12, 8, 30)) {
		t.Errorf("ProximoLaboral = %s %v", prox.In(lima), err)
	}
}
