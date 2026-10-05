package motor_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/escala"
	"jsrbot/backend/internal/golden"
	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/motor"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

const clave = "clave-de-prueba-0123456789"

var lima = func() *time.Location {
	l, _ := time.LoadLocation("America/Lima")
	return l
}()

func L(y int, m time.Month, d, h, mi int) time.Time { return time.Date(y, m, d, h, mi, 0, 0, lima) }

// chFalso es un ClickHouse de mentira: acepta inserciones y responde consultas golden.
type chFalso struct {
	srv         *httptest.Server
	inserciones atomic.Int32
	consultas   atomic.Int32
	ultimaQuery atomic.Value // string
	falla       atomic.Bool
}

func nuevoCH(t *testing.T) *chFalso {
	c := &chFalso{}
	c.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ping" {
			if c.falla.Load() {
				http.Error(w, "caído", 500)
				return
			}
			fmt.Fprint(w, "Ok.\n")
			return
		}
		cuerpo, _ := io.ReadAll(r.Body)
		if c.falla.Load() {
			http.Error(w, "Code: 241. DB::Exception: Memory limit", 500)
			return
		}
		q := r.URL.Query()
		if strings.HasPrefix(q.Get("query"), "INSERT INTO") {
			c.inserciones.Add(int32(strings.Count(string(cuerpo), "\n")))
			return
		}
		if q.Get("wait_end_of_query") != "1" {
			http.Error(w, "falta wait_end_of_query", 400)
		}
		c.consultas.Add(1)
		c.ultimaQuery.Store(r.URL.RawQuery + "|" + r.Header.Get("X-ClickHouse-User") + "|" + string(cuerpo))
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"meta":[{"name":"evaluadas","type":"UInt64"}],"data":[{"evaluadas":624,"mediana_min":41.5}],"rows":1}`)
	}))
	t.Cleanup(c.srv.Close)
	return c
}

type entorno struct {
	t         *testing.T
	db        *store.DB
	svc       *incidencia.Servicio
	reloj     *incidencia.RelojManual
	srv       *httptest.Server
	motor     *motor.Servidor
	ch        *chFalso
	dirAn     string
	ana, beto int
	pepe      int
	mesa      int
}

func nuevoEntorno(t *testing.T) *entorno {
	t.Helper()
	db := storetest.NuevaBDConConfig(t)
	e := &entorno{t: t, db: db, ch: nuevoCH(t)}
	e.reloj = incidencia.NuevoRelojManual(L(2026, 10, 5, 9, 0))
	e.svc = incidencia.Nuevo(db, incidencia.ConReloj(e.reloj.Ahora))

	ctx := context.Background()
	escalar := func(sql string, args ...any) int {
		var v int
		if err := db.QueryRow(ctx, sql, args...).Scan(&v); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return v
	}
	exec := func(sql string, args ...any) {
		if _, err := db.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	e.mesa = escalar(`SELECT id FROM grupos WHERE nombre = 'Mesa N1'`)
	tec := func(nombre string) int {
		id := escalar(`INSERT INTO tecnicos (nombre, whatsapp) VALUES ($1, '5100001' || lpad((random()*9999)::int::text, 4, '0')) RETURNING id`, nombre)
		exec(`INSERT INTO grupo_miembros VALUES ($1, $2)`, e.mesa, id)
		exec(`INSERT INTO habilidades (tecnico_id, categoria_id) SELECT $1, id FROM categorias`, id)
		for d := 1; d <= 5; d++ {
			exec(`INSERT INTO turnos (tecnico_id, dia_semana, desde, hasta) VALUES ($1, $2, '08:30', '18:00')`, id, d)
		}
		return id
	}
	e.ana, e.beto = tec("Ana Técnica"), tec("Beto Técnico")
	exec(`UPDATE grupos SET responsable_tecnico_id = $2 WHERE id = $1`, e.mesa, e.ana)
	sede := escalar(`INSERT INTO sedes (nombre) VALUES ('Sede Central') RETURNING id`)
	area := escalar(`INSERT INTO areas (nombre) VALUES ('Contabilidad') RETURNING id`)
	e.pepe = escalar(`INSERT INTO personas (nombre, whatsapp, correo, sede_id, area_id) VALUES ('Pepe Prueba', '51000000001', 'pepe@empresa.example', $1, $2) RETURNING id`, sede, area)

	// analitica/ de mentira: catálogo y dos versiones de un KPI.
	e.dirAn = t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(e.dirAn, "golden", "mttr"), 0o755))
	must(os.WriteFile(filepath.Join(e.dirAn, "catalogo.json"), []byte(`{"formato":1,"kpis":[{"kpi":"mttr","nombre":"Tiempo de resolución (MTTR)","version":2,"unidad":"minutos laborales","definicion":"Tiempo de creación a resolución.","parametros":["desde","hasta","grupo"]}]}`), 0o644))
	must(os.WriteFile(filepath.Join(e.dirAn, "golden", "mttr", "v1.sql"), []byte("SELECT 1 -- vieja {desde:Date} {hasta:Date} {grupo:String}"), 0o644))
	must(os.WriteFile(filepath.Join(e.dirAn, "golden", "mttr", "v2.sql"), []byte("-- v2\nSELECT count() AS evaluadas FROM jsrbot.v_tiempos WHERE d BETWEEN {desde:Date} AND {hasta:Date} AND ({grupo:String} = '' OR g = {grupo:String})"), 0o644))

	cfgCH := analitica.Config{URL: e.ch.srv.URL, Usuario: "jsr", Clave: "secreta-escritura"}
	trab := analitica.NuevoTrabajador(db, cfgCH)
	lector := &golden.CH{URL: e.ch.srv.URL, Usuario: "analista", Clave: "secreta-lectura"}
	e.motor = motor.Nuevo(motor.Config{
		DB: db, Clave: clave, Version: "prueba", Inc: e.svc, Vigia: escala.Nuevo(e.svc), Analitica: trab,
		Golden: golden.Nuevo(e.dirAn, lector), EsquemaCH: "CREATE DATABASE IF NOT EXISTS jsrbot;", ClickHouseConfigurado: true,
		Reloj: e.reloj.Ahora,
	})
	e.srv = httptest.NewServer(e.motor.Handler())
	t.Cleanup(e.srv.Close)
	return e
}

// llamar hace una petición con la clave y devuelve estado y cuerpo decodificado.
func (e *entorno) llamar(metodo, ruta string, cuerpo any) (int, map[string]any) {
	e.t.Helper()
	est, raw := e.llamarCon(clave, metodo, ruta, cuerpo)
	var m map[string]any
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &m); err != nil {
			// Algunas rutas devuelven un arreglo.
			m = map[string]any{"_crudo": string(raw)}
		}
	}
	return est, m
}

func (e *entorno) llamarCon(k, metodo, ruta string, cuerpo any) (int, []byte) {
	e.t.Helper()
	var rd io.Reader
	switch c := cuerpo.(type) {
	case nil:
	case string:
		rd = strings.NewReader(c)
	default:
		b, _ := json.Marshal(c)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(metodo, e.srv.URL+ruta, rd)
	if k != "" {
		req.Header.Set("X-Interno-Clave", k)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

func actor(tipo, id string) map[string]any { return map[string]any{"tipo": tipo, "id": id} }

func (e *entorno) crear(extra map[string]any) map[string]any {
	e.t.Helper()
	cuerpo := map[string]any{"persona_id": e.pepe, "tipo": "incidente", "categoria": "correo", "impacto": "persona", "urgencia": "media",
		"titulo": "Outlook no abre", "resumen": "No abre desde la mañana", "canal": "whatsapp", "motivo": "sin_articulo", "actor": actor("asistente", "")}
	for k, v := range extra {
		cuerpo[k] = v
	}
	est, r := e.llamar("POST", "/interno/incidencias", cuerpo)
	if est != 200 {
		e.t.Fatalf("crear: HTTP %d %v", est, r)
	}
	return r
}

func idDe(r map[string]any) int {
	return int(r["incidencia"].(map[string]any)["id"].(float64))
}

// ---- seguridad ---------------------------------------------------------------------------------------------

func TestSinClaveOClaveIncorrectaEs401EnTodasLasRutas(t *testing.T) {
	e := nuevoEntorno(t)
	rutas := []struct{ m, r string }{
		{"GET", "/interno/salud"},
		{"POST", "/interno/incidencias"},
		{"GET", "/interno/incidencias/duplicada?persona_id=1&categoria=correo"},
		{"GET", "/interno/incidencias/resuelta?persona_id=1&categoria=correo"},
		{"POST", "/interno/incidencias/1/acciones"},
		{"POST", "/interno/sla/calcular"},
		{"POST", "/interno/vigia/ejecutar"},
		{"POST", "/interno/despacho/simular"},
		{"GET", "/interno/avisos/pendientes"},
		{"POST", "/interno/avisos/1/marcar"},
		{"GET", "/interno/golden"},
		{"GET", "/interno/golden/mttr?desde=2026-07-01&hasta=2026-07-31"},
		{"POST", "/interno/analitica/vaciar"},
		{"POST", "/interno/analitica/reconstruir"},
		{"GET", "/interno/no-existe"},
	}
	for _, rt := range rutas {
		for _, k := range []string{"", "clave-equivocada", clave + "x", strings.ToUpper(clave)} {
			est, raw := e.llamarCon(k, rt.m, rt.r, "{}")
			if est != 401 {
				t.Errorf("%s %s con clave %q: HTTP %d, quiere 401", rt.m, rt.r, k, est)
				continue
			}
			var m map[string]string
			if err := json.Unmarshal(raw, &m); err != nil || m["codigo"] != "no_autorizado" || m["error"] == "" {
				t.Errorf("%s %s: cuerpo del 401 = %s", rt.m, rt.r, raw)
			}
		}
	}
	// Con la clave correcta, una ruta inexistente es 404 JSON (no 401).
	if est, m := e.llamar("GET", "/interno/no-existe", nil); est != 404 || m["codigo"] != "no_encontrado" {
		t.Errorf("ruta inexistente: %d %v", est, m)
	}
	// Un servidor sin clave configurada rechaza todo.
	sinClave := httptest.NewServer(motor.Nuevo(motor.Config{DB: e.db, Inc: e.svc}).Handler())
	defer sinClave.Close()
	req, _ := http.NewRequest("GET", sinClave.URL+"/interno/salud", nil)
	req.Header.Set("X-Interno-Clave", "")
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 401 {
		t.Errorf("sin MOTOR_CLAVE configurada debe rechazar todo: %v %v", resp, err)
	}
}

func TestSalud(t *testing.T) {
	e := nuevoEntorno(t)
	est, m := e.llamar("GET", "/interno/salud", nil)
	if est != 200 || m["ok"] != true || m["db"] != "ok" || m["clickhouse"] != "ok" || m["version"] != "prueba" {
		t.Fatalf("salud: %d %v", est, m)
	}
	// ClickHouse caído no tumba al motor.
	e.ch.falla.Store(true)
	est, m = e.llamar("GET", "/interno/salud", nil)
	if est != 200 || m["ok"] != true || m["clickhouse"] != "error" {
		t.Errorf("con ClickHouse caído: %d %v", est, m)
	}
}

// ---- incidencias ------------------------------------------------------------------------------------------------

func TestCrearIncidenciaDevuelveLoQuePideElContrato(t *testing.T) {
	e := nuevoEntorno(t)
	r := e.crear(nil)
	inc := r["incidencia"].(map[string]any)
	if !strings.HasPrefix(inc["numero"].(string), "INC-") || inc["estado"] != "asignada" || inc["prioridad"] != "P3" ||
		inc["categoria"] != "correo" || inc["grupo"] != "Mesa N1" || inc["tecnico"] != "Ana Técnica" || inc["token_publico"] == "" {
		t.Errorf("incidencia = %v", inc)
	}
	p := inc["persona"].(map[string]any)
	if p["nombre"] != "Pepe Prueba" || p["sede"] != "Sede Central" || p["area"] != "Contabilidad" || p["vip"] != false {
		t.Errorf("persona = %v", p)
	}
	if inc["vence_respuesta_en"] == nil || inc["vence_resolucion_en"] == nil {
		t.Errorf("plazos: %v %v", inc["vence_respuesta_en"], inc["vence_resolucion_en"])
	}
	if _, err := time.Parse(time.RFC3339, inc["vence_respuesta_en"].(string)); err != nil {
		t.Errorf("los plazos deben ser ISO 8601: %v", err)
	}
	a := r["asignacion"].(map[string]any)
	if a["tecnico_id"] != float64(e.ana) || a["grupo_id"] != float64(e.mesa) || a["en_cola"] != false || a["motivo"] == "" {
		t.Errorf("asignacion = %v", a)
	}
	avisos := r["avisos"].([]any)
	if len(avisos) != 1 {
		t.Fatalf("avisos = %v", avisos)
	}
	av := avisos[0].(map[string]any)
	if av["plantilla"] != "incidencia_asignada" || av["destinatario_tipo"] != "tecnico" || av["destinatario_id"] != float64(e.ana) ||
		av["canal"] != "whatsapp" || av["datos"].(map[string]any)["numero"] != inc["numero"] {
		t.Errorf("aviso = %v", av)
	}
	// Y la incidencia quedó de verdad (pero el motor nunca envía: el aviso está pendiente).
	var n int
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM avisos WHERE enviado_en IS NULL`).Scan(&n)
	if n != 1 {
		t.Errorf("avisos pendientes = %d", n)
	}
}

func TestCrearEnColaYValidaciones(t *testing.T) {
	e := nuevoEntorno(t)
	e.reloj.Fijar(L(2026, 10, 10, 10, 0)) // sábado: nadie en turno
	r := e.crear(nil)
	a := r["asignacion"].(map[string]any)
	if a["en_cola"] != true || a["tecnico_id"] != nil || r["incidencia"].(map[string]any)["estado"] != "nueva" || r["incidencia"].(map[string]any)["tecnico"] != nil {
		t.Errorf("debía quedar en cola: %v", r)
	}
	av := r["avisos"].([]any)
	if len(av) != 1 || av[0].(map[string]any)["plantilla"] != "incidencia_sin_asignar" || av[0].(map[string]any)["destinatario_tipo"] != "responsable_grupo" {
		t.Errorf("aviso al responsable: %v", av)
	}

	casos := []struct {
		nombre string
		cuerpo any
		estado int
		codigo string
	}{
		{"JSON roto", `{"titulo":`, 400, "invalido"},
		{"cuerpo vacío", ``, 400, "invalido"},
		{"sin actor", map[string]any{"titulo": "x", "categoria": "correo"}, 422, "invalido"},
		{"sin título", map[string]any{"titulo": " ", "categoria": "correo", "actor": actor("asistente", "")}, 422, "invalido"},
		{"impacto inválido", map[string]any{"titulo": "x", "impacto": "planeta", "actor": actor("asistente", "")}, 422, "invalido"},
		{"urgencia inválida", map[string]any{"titulo": "x", "urgencia": "ya", "actor": actor("asistente", "")}, 422, "invalido"},
		{"actor inválido", map[string]any{"titulo": "x", "actor": actor("alien", "")}, 422, "invalido"},
		{"persona inexistente", map[string]any{"titulo": "x", "persona_id": 99999, "actor": actor("asistente", "")}, 422, "invalido"},
	}
	for _, tc := range casos {
		est, m := e.llamar("POST", "/interno/incidencias", tc.cuerpo)
		if est != tc.estado || m["codigo"] != tc.codigo || m["error"] == nil || m["error"] == "" {
			t.Errorf("%s: HTTP %d %v, quiere %d %s", tc.nombre, est, m, tc.estado, tc.codigo)
		}
	}
	// Los mensajes de error van en español y sin el prefijo técnico.
	_, m := e.llamar("POST", "/interno/incidencias", map[string]any{"titulo": " ", "actor": actor("asistente", "")})
	if !strings.Contains(m["error"].(string), "título") || strings.Contains(m["error"].(string), "datos inválidos") {
		t.Errorf("mensaje: %v", m["error"])
	}
	// La queja y el VIP se respetan.
	e.reloj.Fijar(L(2026, 10, 12, 10, 0))
	rq := e.crear(map[string]any{"queja": true, "titulo": "Con queja"})
	var q int
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'queja'`, idDe(rq)).Scan(&q)
	if q != 1 {
		t.Errorf("queja registrada = %d", q)
	}
}

func TestDuplicadaYResuelta(t *testing.T) {
	e := nuevoEntorno(t)
	est, m := e.llamar("GET", fmt.Sprintf("/interno/incidencias/duplicada?persona_id=%d&categoria=correo", e.pepe), nil)
	if est != 200 || m["incidencia"] != nil {
		t.Fatalf("sin incidencias: %d %v", est, m)
	}
	r := e.crear(nil)
	est, m = e.llamar("GET", fmt.Sprintf("/interno/incidencias/duplicada?persona_id=%d&categoria=correo", e.pepe), nil)
	inc, _ := m["incidencia"].(map[string]any)
	if est != 200 || inc == nil || inc["numero"] != r["incidencia"].(map[string]any)["numero"] || inc["tecnico"] != "Ana Técnica" {
		t.Errorf("duplicada: %d %v", est, m)
	}
	if _, m := e.llamar("GET", fmt.Sprintf("/interno/incidencias/duplicada?persona_id=%d&categoria=vpn", e.pepe), nil); m["incidencia"] != nil {
		t.Error("otra categoría no es duplicada")
	}
	for _, ruta := range []string{"/interno/incidencias/duplicada?categoria=correo", "/interno/incidencias/duplicada?persona_id=x&categoria=correo",
		fmt.Sprintf("/interno/incidencias/duplicada?persona_id=%d", e.pepe), "/interno/incidencias/resuelta?persona_id=1&categoria=correo&desde=ayer"} {
		if est, m := e.llamar("GET", ruta, nil); est != 422 || m["codigo"] != "invalido" {
			t.Errorf("%s: %d %v", ruta, est, m)
		}
	}
	// Resuelta reciente, para el «sigue igual».
	id := idDe(r)
	e.reloj.Avanzar(time.Minute)
	e.llamar("POST", fmt.Sprintf("/interno/incidencias/%d/acciones", id), map[string]any{"accion": "responder", "texto": "ok", "actor": actor("tecnico", fmt.Sprint(e.ana))})
	e.reloj.Avanzar(time.Minute)
	e.llamar("POST", fmt.Sprintf("/interno/incidencias/%d/acciones", id), map[string]any{"accion": "resolver", "solucion": "listo", "actor": actor("tecnico", fmt.Sprint(e.ana))})
	est, m = e.llamar("GET", fmt.Sprintf("/interno/incidencias/resuelta?persona_id=%d&categoria=correo", e.pepe), nil)
	if est != 200 || m["incidencia"] == nil || m["incidencia"].(map[string]any)["estado"] != "resuelta" {
		t.Errorf("resuelta: %d %v", est, m)
	}
	if _, m := e.llamar("GET", fmt.Sprintf("/interno/incidencias/duplicada?persona_id=%d&categoria=correo", e.pepe), nil); m["incidencia"] != nil {
		t.Error("una resuelta ya no es duplicada abierta")
	}
}

func TestAccionesDelCicloDeVida(t *testing.T) {
	e := nuevoEntorno(t)
	r := e.crear(nil)
	id := idDe(r)
	ruta := fmt.Sprintf("/interno/incidencias/%d/acciones", id)
	ana, usuario := actor("tecnico", fmt.Sprint(e.ana)), actor("usuario", fmt.Sprint(e.pepe))
	paso := func(cuerpo map[string]any) map[string]any {
		t.Helper()
		e.reloj.Avanzar(5 * time.Minute)
		est, m := e.llamar("POST", ruta, cuerpo)
		if est != 200 {
			t.Fatalf("%v: HTTP %d %v", cuerpo["accion"], est, m)
		}
		return m
	}
	estado := func(m map[string]any) string { return m["incidencia"].(map[string]any)["estado"].(string) }

	if m := paso(map[string]any{"accion": "responder", "texto": "Voy a revisar", "actor": ana}); estado(m) != "en_curso" {
		t.Errorf("responder: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "comentar", "texto": "Estoy en ello", "actor": ana}); estado(m) != "en_curso" {
		t.Errorf("comentar: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "comentar_interno", "texto": "Nota interna", "actor": ana}); estado(m) != "en_curso" {
		t.Errorf("comentar_interno: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "pausar", "motivo": "espera_usuario", "nota": "¿qué error ves?", "actor": ana}); estado(m) != "espera_usuario" {
		t.Errorf("pausar: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "agregar_dato", "clave": "mensaje_error", "valor": "0x800", "actor": usuario}); estado(m) != "espera_usuario" {
		t.Errorf("agregar_dato: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "reanudar", "actor": usuario}); estado(m) != "en_curso" {
		t.Errorf("reanudar: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "cambiar_prioridad", "prioridad": "P2", "motivo": "afecta al área", "actor": ana}); m["incidencia"].(map[string]any)["prioridad"] != "P2" {
		t.Errorf("cambiar_prioridad: %v", m)
	}
	m := paso(map[string]any{"accion": "queja", "texto": "Esto tarda", "actor": usuario})
	_ = m
	if m := paso(map[string]any{"accion": "asignar", "tecnico_id": e.beto, "motivo": "balanceo", "actor": ana}); m["incidencia"].(map[string]any)["tecnico"] != "Beto Técnico" {
		t.Errorf("asignar: %v", m)
	} else if len(m["avisos"].([]any)) != 1 {
		t.Errorf("asignar debe devolver el aviso al nuevo técnico: %v", m["avisos"])
	}
	beto := actor("tecnico", fmt.Sprint(e.beto))
	if m := paso(map[string]any{"accion": "resolver", "solucion": "Se reconfiguró", "actor": beto}); estado(m) != "resuelta" {
		t.Errorf("resolver: %v", estado(m))
	}
	if m := paso(map[string]any{"accion": "reabrir", "motivo": "sigue igual", "actor": usuario}); estado(m) != "reabierta" || m["incidencia"].(map[string]any)["reaperturas"] != float64(1) {
		t.Errorf("reabrir: %v", m)
	}
	paso(map[string]any{"accion": "responder", "texto": "Otra vez", "actor": beto})
	// Escalar devuelve la asignación del despachador.
	me := paso(map[string]any{"accion": "escalar", "motivo": "manual", "actor": beto})
	_ = me
	// El grupo Mesa N1 escala a Infraestructura, donde no hay nadie: queda en cola.
	if me["incidencia"].(map[string]any)["grupo"] != "Infraestructura" || me["asignacion"] == nil || me["asignacion"].(map[string]any)["en_cola"] != true {
		t.Errorf("escalar: %v", me)
	}
	if estado(me) != "nueva" {
		t.Errorf("sin técnicos en Infraestructura debe quedar en nueva: %v", estado(me))
	}
	// Se asigna a mano y se completa el ciclo: resolver (con responder implícito no existe: debe responder primero).
	paso(map[string]any{"accion": "asignar", "tecnico_id": e.ana, "actor": ana})
	paso(map[string]any{"accion": "responder", "texto": "Lo tomo", "actor": ana})
	paso(map[string]any{"accion": "resolver", "solucion": "ok", "actor": ana})
	if m := paso(map[string]any{"accion": "cerrar", "motivo": "confirmado", "actor": usuario}); estado(m) != "cerrada" {
		t.Errorf("cerrar: %v", estado(m))
	}
}

func TestAccionesInvalidas(t *testing.T) {
	e := nuevoEntorno(t)
	id := idDe(e.crear(nil))
	ruta := fmt.Sprintf("/interno/incidencias/%d/acciones", id)
	ana := actor("tecnico", fmt.Sprint(e.ana))
	antes := func() int {
		var n int
		_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1`, id).Scan(&n)
		return n
	}
	n0 := antes()
	casos := []struct {
		nombre string
		ruta   string
		cuerpo any
		estado int
		codigo string
	}{
		{"resolver sin haber respondido (transición inválida)", ruta, map[string]any{"accion": "resolver", "actor": ana}, 409, "conflicto"},
		{"reabrir una asignada", ruta, map[string]any{"accion": "reabrir", "actor": ana}, 409, "conflicto"},
		{"cerrar una asignada", ruta, map[string]any{"accion": "cerrar", "motivo": "confirmado", "actor": ana}, 409, "conflicto"},
		{"pausar una asignada", ruta, map[string]any{"accion": "pausar", "motivo": "espera_usuario", "actor": ana}, 409, "conflicto"},
		{"reanudar una asignada", ruta, map[string]any{"accion": "reanudar", "actor": ana}, 409, "conflicto"},
		{"acción inexistente", ruta, map[string]any{"accion": "teletransportar", "actor": ana}, 422, "invalido"},
		{"sin acción", ruta, map[string]any{"actor": ana}, 422, "invalido"},
		{"sin actor", ruta, map[string]any{"accion": "responder", "texto": "x"}, 422, "invalido"},
		{"asignar sin técnico", ruta, map[string]any{"accion": "asignar", "actor": ana}, 422, "invalido"},
		{"asignar a un técnico que no existe", ruta, map[string]any{"accion": "asignar", "tecnico_id": 9999, "actor": ana}, 404, "no_encontrado"},
		{"responder con un usuario", ruta, map[string]any{"accion": "responder", "texto": "x", "actor": actor("usuario", "1")}, 422, "invalido"},
		{"prioridad inválida", ruta, map[string]any{"accion": "cambiar_prioridad", "prioridad": "P9", "actor": ana}, 422, "invalido"},
		{"incidencia inexistente", "/interno/incidencias/99999/acciones", map[string]any{"accion": "reanudar", "actor": ana}, 404, "no_encontrado"},
		{"id que no es número", "/interno/incidencias/abc/acciones", map[string]any{"accion": "reanudar", "actor": ana}, 422, "invalido"},
		{"JSON roto", ruta, `{"accion":`, 400, "invalido"},
	}
	for _, tc := range casos {
		est, m := e.llamar("POST", tc.ruta, tc.cuerpo)
		if est != tc.estado || m["codigo"] != tc.codigo {
			t.Errorf("%s: HTTP %d %v, quiere %d %s", tc.nombre, est, m, tc.estado, tc.codigo)
		}
		if msg, _ := m["error"].(string); msg == "" {
			t.Errorf("%s: falta el mensaje en español", tc.nombre)
		}
	}
	if antes() != n0 {
		t.Errorf("las acciones rechazadas dejaron %d eventos", antes()-n0)
	}
}

func TestSLACalcularPorLote(t *testing.T) {
	e := nuevoEntorno(t)
	a := idDe(e.crear(nil)) // P3 lunes 09:00: respuesta 120 min
	e.reloj.Fijar(L(2026, 10, 5, 9, 0))
	b := idDe(e.crear(map[string]any{"titulo": "Otra", "categoria": "equipo"}))
	e.reloj.Fijar(L(2026, 10, 5, 10, 30)) // 90 min: 75 % de la respuesta
	e.llamar("POST", fmt.Sprintf("/interno/incidencias/%d/acciones", b), map[string]any{"accion": "responder", "texto": "ok", "actor": actor("tecnico", fmt.Sprint(e.ana))})
	est, m := e.llamar("POST", "/interno/sla/calcular", map[string]any{"ids": []int{a, b, 99999}})
	if est != 200 || len(m) != 2 || m["99999"] != nil {
		t.Fatalf("sla: %d %v", est, m)
	}
	sa := m[fmt.Sprint(a)].(map[string]any)
	if sa["porcentaje_respuesta"] != 75.0 || sa["proximo"] != "respuesta" || sa["restante_min"] != 30.0 || sa["vencida"] != false || sa["pausada"] != false {
		t.Errorf("sla de a: %v", sa)
	}
	sb := m[fmt.Sprint(b)].(map[string]any)
	if sb["proximo"] != "resolucion" || sb["porcentaje_respuesta"] != 75.0 {
		t.Errorf("sla de b (respondida): %v", sb)
	}
	// Vencida y en pausa.
	e.reloj.Fijar(L(2026, 10, 5, 12, 0))
	est, m = e.llamar("POST", "/interno/sla/calcular", map[string]any{"ids": []int{a}})
	if est != 200 || m[fmt.Sprint(a)].(map[string]any)["vencida"] != true || m[fmt.Sprint(a)].(map[string]any)["restante_min"].(float64) >= 0 {
		t.Errorf("a las 12:00 la respuesta de a está vencida: %v", m)
	}
	e.llamar("POST", fmt.Sprintf("/interno/incidencias/%d/acciones", b), map[string]any{"accion": "pausar", "motivo": "espera_usuario", "actor": actor("tecnico", fmt.Sprint(e.ana))})
	_, m = e.llamar("POST", "/interno/sla/calcular", map[string]any{"ids": []int{b}})
	if m[fmt.Sprint(b)].(map[string]any)["pausada"] != true {
		t.Errorf("b debe figurar en pausa: %v", m)
	}
	// Lista vacía y exceso.
	if est, m := e.llamar("POST", "/interno/sla/calcular", map[string]any{"ids": []int{}}); est != 200 || len(m) != 0 {
		t.Errorf("lista vacía: %d %v", est, m)
	}
	grande := make([]int, 1001)
	if est, m := e.llamar("POST", "/interno/sla/calcular", map[string]any{"ids": grande}); est != 422 || m["codigo"] != "invalido" {
		t.Errorf("1001 ids: %d %v", est, m)
	}
	if est, _ := e.llamar("POST", "/interno/sla/calcular", `{"ids": "no"}`); est != 400 {
		t.Errorf("ids que no es lista: %d", est)
	}
}

func TestVigiaEjecutarYDespachoSimular(t *testing.T) {
	e := nuevoEntorno(t)
	e.db.Exec(context.Background(), `UPDATE escalamiento_reglas SET modo = 'activo'`)
	r := e.crear(nil)
	id := idDe(r)
	// A los 90 min (75 % de la respuesta): aviso al técnico. El cuerpo es opcional.
	est, m := e.llamar("POST", "/interno/vigia/ejecutar", map[string]any{"ahora": L(2026, 10, 5, 10, 30).UTC().Format(time.RFC3339)})
	if est != 200 || m["revisadas"] != 1.0 || len(m["acciones"].([]any)) != 1 {
		t.Fatalf("vigía: %d %v", est, m)
	}
	acc := m["acciones"].([]any)[0].(map[string]any)
	if acc["regla_clave"] != "sla_75_respuesta" || acc["ejecutada"] != true || acc["numero"] != r["incidencia"].(map[string]any)["numero"] {
		t.Errorf("acción = %v", acc)
	}
	// Idempotente.
	if _, m := e.llamar("POST", "/interno/vigia/ejecutar", map[string]any{"ahora": L(2026, 10, 5, 10, 31).UTC().Format(time.RFC3339)}); len(m["acciones"].([]any)) != 0 {
		t.Errorf("la segunda pasada no debe repetir: %v", m)
	}
	// Sin cuerpo usa el reloj del servidor.
	if est, _ := e.llamar("POST", "/interno/vigia/ejecutar", ""); est != 200 {
		t.Errorf("sin cuerpo: %d", est)
	}
	if est, m := e.llamar("POST", "/interno/vigia/ejecutar", map[string]any{"ahora": "mañana"}); est != 422 {
		t.Errorf("ahora inválido: %d %v", est, m)
	}
	_ = id

	// Simular el despacho no persiste nada.
	var evAntes, decAntes int
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM incidencia_eventos`).Scan(&evAntes)
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM decisiones`).Scan(&decAntes)
	var ultAntes any
	_ = e.db.QueryRow(context.Background(), `SELECT max(ultima_asignacion) FROM tecnicos`).Scan(&ultAntes)
	est, m = e.llamar("POST", "/interno/despacho/simular", map[string]any{"categoria": "correo", "prioridad": "P2"})
	if est != 200 || m["grupo"] != "Mesa N1" || m["tecnico"] != "Beto Técnico" || m["en_cola"] != false || m["motivo"] == "" {
		t.Errorf("simular: %d %v (Ana ya tiene una incidencia: debía elegir a Beto)", est, m)
	}
	var evDesp, decDesp int
	var ultDesp any
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM incidencia_eventos`).Scan(&evDesp)
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM decisiones`).Scan(&decDesp)
	_ = e.db.QueryRow(context.Background(), `SELECT max(ultima_asignacion) FROM tecnicos`).Scan(&ultDesp)
	if evDesp != evAntes || decDesp != decAntes || fmt.Sprint(ultAntes) != fmt.Sprint(ultDesp) {
		t.Error("simular no debe persistir nada")
	}
	if est, m := e.llamar("POST", "/interno/despacho/simular", map[string]any{"categoria": "magia", "prioridad": "P2"}); est != 422 {
		t.Errorf("categoría inexistente: %d %v", est, m)
	}
	if est, _ := e.llamar("POST", "/interno/despacho/simular", map[string]any{"prioridad": "P2"}); est != 422 {
		t.Errorf("sin categoría: %d", est)
	}
	if est, _ := e.llamar("POST", "/interno/despacho/simular", map[string]any{"categoria": "correo", "prioridad": "P7"}); est != 422 {
		t.Errorf("prioridad inválida: %d", est)
	}
}

func TestAvisosPendientesYMarcar(t *testing.T) {
	e := nuevoEntorno(t)
	e.crear(nil)
	e.reloj.Avanzar(time.Minute)
	e.crear(map[string]any{"titulo": "Otra"})
	est, m := e.llamar("GET", "/interno/avisos/pendientes?limite=50", nil)
	if est != 200 {
		t.Fatal(est, m)
	}
	var lista []map[string]any
	_, raw := e.llamarCon(clave, "GET", "/interno/avisos/pendientes?limite=50", nil)
	if err := json.Unmarshal(raw, &lista); err != nil || len(lista) != 2 {
		t.Fatalf("pendientes debe ser un arreglo de 2: %s", raw)
	}
	for _, k := range []string{"id", "incidencia_id", "destinatario_tipo", "destinatario_id", "canal", "plantilla", "datos"} {
		if _, ok := lista[0][k]; !ok {
			t.Errorf("falta el campo %s: %v", k, lista[0])
		}
	}
	// limite.
	_, raw = e.llamarCon(clave, "GET", "/interno/avisos/pendientes?limite=1", nil)
	_ = json.Unmarshal(raw, &lista)
	if len(lista) != 1 {
		t.Errorf("limite=1: %d", len(lista))
	}
	for _, l := range []string{"0", "501", "x"} {
		if est, _ := e.llamar("GET", "/interno/avisos/pendientes?limite="+l, nil); est != 422 {
			t.Errorf("limite=%s: %d", l, est)
		}
	}
	id := int(lista[0]["id"].(float64))
	// Enviado.
	if est, m := e.llamar("POST", fmt.Sprintf("/interno/avisos/%d/marcar", id), map[string]any{"enviado": true}); est != 200 || m["ok"] != true {
		t.Errorf("marcar enviado: %d %v", est, m)
	}
	_, raw = e.llamarCon(clave, "GET", "/interno/avisos/pendientes", nil)
	_ = json.Unmarshal(raw, &lista)
	if len(lista) != 1 || int(lista[0]["id"].(float64)) == id {
		t.Errorf("el enviado ya no debe estar pendiente: %v", lista)
	}
	// Error: sigue pendiente, con intentos y el motivo.
	otro := int(lista[0]["id"].(float64))
	if est, m := e.llamar("POST", fmt.Sprintf("/interno/avisos/%d/marcar", otro), map[string]any{"enviado": false, "error": "Evolution respondió 503"}); est != 200 || m["ok"] != true {
		t.Errorf("marcar con error: %d %v", est, m)
	}
	_, raw = e.llamarCon(clave, "GET", "/interno/avisos/pendientes", nil)
	_ = json.Unmarshal(raw, &lista)
	if len(lista) != 1 || lista[0]["error"] != "Evolution respondió 503" || lista[0]["intentos"] != 1.0 {
		t.Errorf("tras el error: %v", lista)
	}
	if est, m := e.llamar("POST", "/interno/avisos/99999/marcar", map[string]any{"enviado": true}); est != 404 || m["codigo"] != "no_encontrado" {
		t.Errorf("aviso inexistente: %d %v", est, m)
	}
	if est, _ := e.llamar("POST", fmt.Sprintf("/interno/avisos/%d/marcar", otro), map[string]any{}); est != 422 {
		t.Errorf("sin «enviado»: %d", est)
	}
	if est, _ := e.llamar("POST", "/interno/avisos/abc/marcar", map[string]any{"enviado": true}); est != 422 {
		t.Errorf("id inválido: %d", est)
	}
	// Vacío => arreglo vacío, nunca null.
	e.llamar("POST", fmt.Sprintf("/interno/avisos/%d/marcar", otro), map[string]any{"enviado": true})
	if _, raw := e.llamarCon(clave, "GET", "/interno/avisos/pendientes", nil); strings.TrimSpace(string(raw)) != "[]" {
		t.Errorf("sin pendientes debe responder []: %s", raw)
	}
}

// ---- golden ----------------------------------------------------------------------------------------------------------

func TestGolden(t *testing.T) {
	e := nuevoEntorno(t)
	est, m := e.llamar("GET", "/interno/golden", nil)
	if est != 200 || m["formato"] != 1.0 || len(m["kpis"].([]any)) != 1 {
		t.Fatalf("catálogo: %d %v", est, m)
	}
	// El catálogo trae el SQL de la ÚLTIMA versión de cada KPI (v2, no v1).
	if sql, _ := m["kpis"].([]any)[0].(map[string]any)["sql"].(string); !strings.Contains(sql, "-- v2") || strings.Contains(sql, "vieja") {
		t.Errorf("sql del catálogo: %q", sql)
	}
	est, m = e.llamar("GET", "/interno/golden/mttr?desde=2026-07-01&hasta=2026-09-30&grupo=Redes", nil)
	if est != 200 || m["kpi"] != "mttr" || m["version"] != 2.0 || m["unidad"] != "minutos laborales" || m["definicion"] == "" {
		t.Fatalf("golden: %d %v", est, m)
	}
	if sql, _ := m["sql"].(string); !strings.Contains(sql, "-- v2") || !strings.Contains(sql, "{desde:Date}") || strings.Contains(sql, "vieja") {
		t.Errorf("sql de la versión ejecutada: %q", sql)
	}
	filas := m["filas"].([]any)
	if len(filas) != 1 || filas[0].(map[string]any)["evaluadas"] != 624.0 {
		t.Errorf("filas = %v", filas)
	}
	// Usó la ÚLTIMA versión (v2), con los parámetros param_*, el usuario analista y el SQL del archivo.
	q := e.ch.ultimaQuery.Load().(string)
	if !strings.Contains(q, "param_desde=2026-07-01") || !strings.Contains(q, "param_hasta=2026-09-30") || !strings.Contains(q, "param_grupo=Redes") ||
		!strings.Contains(q, "|analista|") || !strings.Contains(q, "-- v2") || strings.Contains(q, "vieja") {
		t.Errorf("consulta enviada a ClickHouse: %s", q)
	}
	casos := []struct {
		ruta   string
		estado int
		codigo string
	}{
		{"/interno/golden/no_existe?desde=2026-07-01&hasta=2026-09-30", 404, "no_encontrado"},
		{"/interno/golden/MTTR?desde=2026-07-01&hasta=2026-09-30", 422, "invalido"},
		{"/interno/golden/mttr?hasta=2026-09-30", 422, "invalido"},
		{"/interno/golden/mttr?desde=2026-07-01", 422, "invalido"},
		{"/interno/golden/mttr?desde=julio&hasta=2026-09-30", 422, "invalido"},
		{"/interno/golden/mttr?desde=2026-13-45&hasta=2026-09-30", 422, "invalido"},
		{"/interno/golden/mttr?desde=2026-09-30&hasta=2026-07-01", 422, "invalido"},
	}
	for _, tc := range casos {
		if est, m := e.llamar("GET", tc.ruta, nil); est != tc.estado || m["codigo"] != tc.codigo {
			t.Errorf("%s: %d %v", tc.ruta, est, m)
		}
	}
	// Sin grupo corre con grupo vacío.
	if est, _ := e.llamar("GET", "/interno/golden/mttr?desde=2026-07-01&hasta=2026-09-30", nil); est != 200 || !strings.Contains(e.ch.ultimaQuery.Load().(string), "param_grupo=") {
		t.Errorf("sin grupo: %d", est)
	}
	// ClickHouse rechaza (límite de memoria): 502 sin filtrar el detalle, ni credenciales.
	e.ch.falla.Store(true)
	est, raw := e.llamarCon(clave, "GET", "/interno/golden/mttr?desde=2026-07-01&hasta=2026-09-30", nil)
	if est != 502 || strings.Contains(string(raw), "secreta") || strings.Contains(string(raw), "DB::Exception") {
		t.Errorf("ClickHouse caído: %d %s", est, raw)
	}
}

func TestGoldenSinCatalogoNiClickHouse(t *testing.T) {
	e := nuevoEntorno(t)
	vacio := httptest.NewServer(motor.Nuevo(motor.Config{DB: e.db, Clave: clave, Inc: e.svc,
		Golden: golden.Nuevo(t.TempDir(), nil)}).Handler())
	defer vacio.Close()
	get := func(ruta string) int {
		req, _ := http.NewRequest("GET", vacio.URL+ruta, nil)
		req.Header.Set("X-Interno-Clave", clave)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if est := get("/interno/golden"); est != 404 {
		t.Errorf("sin catálogo: %d", est)
	}
	// Con catálogo pero sin lector de ClickHouse: 409.
	sin := httptest.NewServer(motor.Nuevo(motor.Config{DB: e.db, Clave: clave, Inc: e.svc, Golden: golden.Nuevo(e.dirAn, nil)}).Handler())
	defer sin.Close()
	req, _ := http.NewRequest("GET", sin.URL+"/interno/golden/mttr?desde=2026-07-01&hasta=2026-07-31", nil)
	req.Header.Set("X-Interno-Clave", clave)
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 409 {
		t.Errorf("sin ClickHouse: %v %v", resp, err)
	}
}

// ---- analítica ------------------------------------------------------------------------------------------------------------------

func TestAnaliticaVaciarYReconstruir(t *testing.T) {
	e := nuevoEntorno(t)
	e.crear(nil)
	var pend int
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&pend)
	if pend == 0 {
		t.Fatal("crear debe dejar filas en el outbox")
	}
	est, m := e.llamar("POST", "/interno/analitica/vaciar", nil)
	if est != 200 || int(m["enviadas"].(float64)) != pend || int(e.ch.inserciones.Load()) != pend {
		t.Fatalf("vaciar: %d %v (pendientes %d, recibidas %d)", est, m, pend, e.ch.inserciones.Load())
	}
	// Reconstruir re-encola todo y lo manda.
	e.ch.inserciones.Store(0)
	est, m = e.llamar("POST", "/interno/analitica/reconstruir", nil)
	if est != 200 || m["enviadas"].(float64) == 0 || m["encoladas"].(map[string]any)["incidencias_estado"] != 1.0 {
		t.Fatalf("reconstruir: %d %v", est, m)
	}
	if int(m["enviadas"].(float64)) != int(e.ch.inserciones.Load()) {
		t.Errorf("enviadas %v vs recibidas %d", m["enviadas"], e.ch.inserciones.Load())
	}
	// Con ClickHouse caído: vaciar da 502 y no pierde nada; reconstruir avisa.
	e.crear(map[string]any{"titulo": "Otra"})
	e.ch.falla.Store(true)
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&pend)
	est, _ = e.llamar("POST", "/interno/analitica/vaciar", nil)
	var pend2 int
	_ = e.db.QueryRow(context.Background(), `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&pend2)
	if est != 502 || pend2 != pend {
		t.Errorf("ClickHouse caído: %d, pendientes %d -> %d", est, pend, pend2)
	}
	if est, m := e.llamar("POST", "/interno/analitica/reconstruir", nil); est != 200 || m["aviso"] == nil {
		t.Errorf("reconstruir con ClickHouse caído: %d %v", est, m)
	}
	// Sin trabajador configurado: 409.
	sin := httptest.NewServer(motor.Nuevo(motor.Config{DB: e.db, Clave: clave, Inc: e.svc}).Handler())
	defer sin.Close()
	req, _ := http.NewRequest("POST", sin.URL+"/interno/analitica/vaciar", nil)
	req.Header.Set("X-Interno-Clave", clave)
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 409 {
		t.Errorf("sin ClickHouse: %v %v", resp, err)
	}
}

// El vigía y el outbox corren solos en segundo plano y paran con el contexto.
func TestFondoCorreElVigiaYElOutboxYParaAlCancelar(t *testing.T) {
	e := nuevoEntorno(t)
	// Una incidencia vieja sin atender: el vigía la marcará como vencida con la hora real.
	e.reloj.Fijar(time.Date(2026, 9, 1, 14, 0, 0, 0, time.UTC))
	id := idDe(e.crear(nil))
	ctx, cancel := context.WithCancel(context.Background())
	hecho := make(chan struct{})
	go func() { e.motor.Fondo(ctx, true, true); close(hecho) }()
	limite := time.Now().Add(15 * time.Second)
	var vencidos, pend int
	for time.Now().Before(limite) {
		_ = e.db.QueryRow(ctx, `SELECT count(*) FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo = 'sla_vencido'`, id).Scan(&vencidos)
		_ = e.db.QueryRow(ctx, `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&pend)
		if vencidos > 0 && pend == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if vencidos == 0 {
		t.Error("el vigía de fondo no corrió")
	}
	if pend != 0 || e.ch.inserciones.Load() == 0 {
		t.Errorf("el outbox de fondo no se vació: pendientes %d, recibidas %d", pend, e.ch.inserciones.Load())
	}
	cancel()
	select {
	case <-hecho:
	case <-time.After(10 * time.Second):
		t.Fatal("Fondo no paró al cancelar el contexto")
	}
}
