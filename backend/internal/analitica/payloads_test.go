package analitica

import (
	"encoding/json"
	"testing"
	"time"

	"jsrbot/backend/internal/sla"
)

func TestFormatoDeHorasYVersion(t *testing.T) {
	t0 := time.Date(2026, 10, 5, 14, 30, 0, 0, time.UTC)
	if got := fmtTS(t0); got != "2026-10-05T14:30:00Z" {
		t.Errorf("fmtTS = %s", got)
	}
	if got := fmtTS(t0.Add(123 * time.Millisecond)); got != "2026-10-05T14:30:00.123Z" {
		t.Errorf("fmtTS con ms = %s", got)
	}
	// Una hora con otro huso sale en UTC.
	lima, _ := time.LoadLocation("America/Lima")
	if got := fmtTS(time.Date(2026, 10, 5, 9, 30, 0, 0, lima)); got != "2026-10-05T14:30:00Z" {
		t.Errorf("fmtTS en Lima = %s", got)
	}
	if Version(t0) != t0.UnixMilli() {
		t.Error("la versión son milisegundos epoch")
	}
}

func TestPayloadMensajeTolerante(t *testing.T) {
	ts := time.Date(2026, 10, 5, 14, 30, 0, 0, time.UTC)
	meta := []byte(`{"intencion":"reportar_falla","confianza":0.93,"categoria":"correo","latencia_ms":420,
		"regenerada":true,"frases_quitadas":2,"costo_usd":0.0012,"juez":{"modo":"sombra","veredictos":{"ok":true}}}`)
	p := PayloadMensaje(7, 3, ts, "asistente", "web", "Hola, soy tu asistente", meta)
	if p["intencion"] != "reportar_falla" || p["confianza"] != 0.93 || p["juez_modo"] != "sombra" || p["regenerada"] != 1 ||
		p["frases_quitadas"] != 2 || p["costo_usd"] != 0.0012 || p["canal"] != "web" {
		t.Errorf("payload = %v", p)
	}
	if v, _ := p["juez_veredicto"].(string); v != `{"ok":true}` {
		t.Errorf("juez_veredicto = %v", p["juez_veredicto"])
	}
	if p["texto"] != "" {
		t.Error("el texto no debe salir sin ANALITICA_TEXTO=1")
	}
	t.Setenv("ANALITICA_TEXTO", "1")
	if PayloadMensaje(7, 3, ts, "usuario", "web", "mi mensaje", nil)["texto"] != "mi mensaje" {
		t.Error("con ANALITICA_TEXTO=1 el texto sale")
	}
	// Meta vacía o rota no revienta y deja los campos en su neutro.
	for _, m := range [][]byte{nil, []byte(`no es json`), []byte(`{}`)} {
		q := PayloadMensaje(1, 1, ts, "usuario", "web", "x", m)
		if q["intencion"] != "" || q["confianza"] != nil || q["regenerada"] != 0 || q["frases_quitadas"] != 0 {
			t.Errorf("meta %q: %v", m, q)
		}
	}
}

func TestPayloadEventoLimpiaTextoYContexto(t *testing.T) {
	actor := "12"
	ev := EventoIncidencia{ID: 5, IncidenciaID: 2, Numero: "INC-000002", TS: time.Date(2026, 10, 5, 14, 0, 0, 0, time.UTC),
		Tipo: "comentario", ActorTipo: "tecnico", ActorID: &actor,
		Datos: map[string]any{"texto": "privado", "visible": "interno", "valor": "PC-1", "motivo": "x",
			ClaveContexto: map[string]any{"prioridad": "P2", "categoria": "correo", "grupo": "Mesa N1", "tecnico_id": 4}}}
	p := PayloadEvento(ev)
	if p["prioridad"] != "P2" || p["categoria"] != "correo" || p["grupo"] != "Mesa N1" || p["actor_id"] != "12" {
		t.Errorf("contexto: %v", p)
	}
	var datos map[string]any
	if err := json.Unmarshal([]byte(p["datos"].(string)), &datos); err != nil {
		t.Fatal(err)
	}
	if _, ok := datos["texto"]; ok {
		t.Error("el texto libre no debe salir")
	}
	if _, ok := datos["valor"]; ok {
		t.Error("el valor libre no debe salir")
	}
	if _, ok := datos[ClaveContexto]; ok {
		t.Error("el contexto va en columnas, no en datos")
	}
	if datos["visible"] != "interno" || datos["motivo"] != "x" {
		t.Errorf("los códigos sí salen: %v", datos)
	}
	// Sin actor, actor_id sale vacío (la columna es String, no Nullable).
	ev.ActorID = nil
	if PayloadEvento(ev)["actor_id"] != "" {
		t.Error("actor_id debe ser cadena vacía")
	}
}

func TestPayloadTiemposNullHastaQueAplique(t *testing.T) {
	cal, _ := sla.NuevoCalendario("l", "America/Lima", false, []byte(`{"1":[["08:30","18:00"]]}`))
	lima, _ := time.LoadLocation("America/Lima")
	creada := time.Date(2026, 10, 5, 9, 0, 0, 0, lima)
	base := EstadoIncidencia{IncidenciaID: 1, Prioridad: "P3", Categoria: "correo", Grupo: "Mesa N1", CreadaEn: creada,
		ActualizadaEn: creada, Cal: cal, Pol: sla.Politica{RespuestaMin: 60, ResolucionMin: 480}, Ahora: creada.Add(10 * time.Minute)}
	p := PayloadTiempos(base)
	for _, k := range []string{"frt_min", "mttr_min", "sla_respuesta_ok", "sla_resolucion_ok", "primer_contacto", "resuelta_en", "cerrada_en"} {
		if p[k] != nil {
			t.Errorf("%s debe ser NULL hasta que aplique: %v", k, p[k])
		}
	}
	// Respuesta tardía y resolución a tiempo; primer contacto 0 si hubo reapertura.
	resp, res := creada.Add(90*time.Minute), creada.Add(120*time.Minute)
	base.PrimeraRespuestaEn, base.ResueltaEn, base.Ahora = &resp, &res, res.Add(time.Hour)
	base.Reaperturas = 1
	p = PayloadTiempos(base)
	if p["frt_min"] != int64(90) || p["sla_respuesta_ok"] != 0 || p["mttr_min"] != int64(120) || p["sla_resolucion_ok"] != 1 || p["primer_contacto"] != 0 {
		t.Errorf("tiempos = %v", p)
	}
	base.Reaperturas = 0
	if PayloadTiempos(base)["primer_contacto"] != 1 {
		t.Error("sin reaperturas ni escalamientos es de primer contacto")
	}
	// Un cierre «sin confirmación» no cuenta para el FCR: primer_contacto NULL.
	sin := "sin_confirmacion"
	base.MotivoCierre = &sin
	if PayloadTiempos(base)["primer_contacto"] != nil {
		t.Error("cierre sin confirmación: primer_contacto debe ser NULL")
	}
	ok := "confirmado"
	base.MotivoCierre = &ok
	if PayloadTiempos(base)["primer_contacto"] != 1 {
		t.Error("cierre confirmado: primer_contacto sigue siendo 1")
	}
	// Reabierta: resuelta_en NULL => mttr, frt de resolución y primer_contacto NULL.
	base.ResueltaEn, base.MotivoCierre, base.Reaperturas = nil, nil, 1
	p = PayloadTiempos(base)
	if p["resuelta_en"] != nil || p["mttr_min"] != nil || p["primer_contacto"] != nil {
		t.Errorf("reabierta: %v", p)
	}
}
