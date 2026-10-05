package golden

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type lectorFalso struct {
	sql    string
	params map[string]string
	filas  []map[string]any
	err    error
}

func (l *lectorFalso) Consultar(_ context.Context, sql string, p map[string]string) ([]map[string]any, error) {
	l.sql, l.params = sql, p
	return l.filas, l.err
}

func carpeta(t *testing.T, catalogo string, versiones map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	if catalogo != "" {
		if err := os.WriteFile(filepath.Join(dir, "catalogo.json"), []byte(catalogo), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for archivo, sql := range versiones {
		ruta := filepath.Join(dir, "golden", "frt", archivo)
		_ = os.MkdirAll(filepath.Dir(ruta), 0o755)
		if err := os.WriteFile(ruta, []byte(sql), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

const catalogoFRT = `{"formato":1,"kpis":[{"kpi":"frt","nombre":"FRT","version":10,"unidad":"minutos","definicion":"Primera respuesta.","parametros":["desde","hasta"]}]}`

func TestEjecutarUsaLaUltimaVersionNumerica(t *testing.T) {
	// v10 es posterior a v9 y a v2 (un orden alfabético elegiría v9).
	dir := carpeta(t, catalogoFRT, map[string]string{
		"v2.sql": "SELECT 2 {desde:Date} {hasta:Date}", "v9.sql": "SELECT 9 {desde:Date} {hasta:Date}", "v10.sql": "SELECT 10 {desde:Date} {hasta:Date}",
		"meta.yaml": "no es sql", "esperado.csv": "x",
	})
	l := &lectorFalso{filas: []map[string]any{{"mediana_min": 12.5}}}
	r, err := Nuevo(dir, l).Ejecutar(context.Background(), "frt", Params{Desde: "2026-07-01", Hasta: "2026-07-31", Grupo: "Redes"})
	if err != nil {
		t.Fatal(err)
	}
	if r.SQL != l.sql || !strings.HasPrefix(r.SQL, "SELECT 10") {
		t.Errorf("Resultado.SQL = %q, el ejecutado fue %q", r.SQL, l.sql)
	}
	if cat, err := Nuevo(dir, l).CatalogoConSQL(context.Background()); err != nil || !strings.Contains(string(cat), `"sql":"SELECT 10 `) || strings.Contains(string(cat), "SELECT 9") {
		t.Errorf("CatalogoConSQL: %s %v", cat, err)
	}
	if r.Version != 10 || !strings.HasPrefix(l.sql, "SELECT 10") || r.KPI != "frt" || r.Unidad != "minutos" || len(r.Filas) != 1 {
		t.Errorf("resultado = %+v, sql = %q", r, l.sql)
	}
	// «grupo» no está declarado en el SQL: no se manda.
	if _, ok := l.params["grupo"]; ok || l.params["desde"] != "2026-07-01" || l.params["hasta"] != "2026-07-31" {
		t.Errorf("parámetros enviados: %v", l.params)
	}
	// Sin filas devuelve [], nunca null.
	l.filas = nil
	if r, _ := Nuevo(dir, l).Ejecutar(context.Background(), "frt", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}); r.Filas == nil {
		t.Error("filas debe ser un arreglo vacío")
	}
}

func TestEjecutarValida(t *testing.T) {
	dir := carpeta(t, catalogoFRT, map[string]string{"v1.sql": "SELECT {desde:Date} {hasta:Date} {grupo:String}"})
	g := Nuevo(dir, &lectorFalso{})
	ctx := context.Background()
	casos := []struct {
		kpi string
		p   Params
		err error
	}{
		{"frt", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}, nil},
		{"../etc/passwd", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}, ErrInvalido},
		{"FRT", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}, ErrInvalido},
		{"frt", Params{Hasta: "2026-07-31"}, ErrInvalido},
		{"frt", Params{Desde: "2026-07-01 00:00", Hasta: "2026-07-31"}, ErrInvalido},
		{"frt", Params{Desde: "2026-02-30", Hasta: "2026-07-31"}, ErrInvalido},
		{"frt", Params{Desde: "2026-08-01", Hasta: "2026-07-31"}, ErrInvalido},
		{"otro", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}, ErrNoEncontrado},
	}
	for _, tc := range casos {
		if _, err := g.Ejecutar(ctx, tc.kpi, tc.p); !errors.Is(err, tc.err) {
			t.Errorf("%s %+v: err = %v, quiere %v", tc.kpi, tc.p, err, tc.err)
		}
	}
	if _, err := Nuevo(t.TempDir(), &lectorFalso{}).Ejecutar(ctx, "frt", Params{}); !errors.Is(err, ErrSinCatalogo) {
		t.Errorf("sin catálogo: %v", err)
	}
	if _, err := Nuevo(dir, nil).Ejecutar(ctx, "frt", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}); !errors.Is(err, ErrSinClickHouse) {
		t.Errorf("sin lector: %v", err)
	}
	// Catálogo con el KPI pero sin su carpeta de SQL.
	if _, err := Nuevo(carpeta(t, catalogoFRT, nil), &lectorFalso{}).Ejecutar(ctx, "frt", Params{Desde: "2026-07-01", Hasta: "2026-07-31"}); !errors.Is(err, ErrNoEncontrado) {
		t.Errorf("sin SQL: %v", err)
	}
	if _, err := Nuevo(carpeta(t, `{no es json`, nil), nil).Catalogo(ctx); err == nil {
		t.Error("un catálogo roto debe fallar")
	}
}

func TestLectorCHEnviaParametrosYCredencialesYLeeJSON(t *testing.T) {
	var q map[string][]string
	var cab http.Header
	var cuerpo string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q, cab = r.URL.Query(), r.Header.Clone()
		b := make([]byte, 1<<16)
		n, _ := r.Body.Read(b)
		cuerpo = string(b[:n])
		fmt.Fprint(w, `{"meta":[],"data":[{"n":5,"x":null,"s":"a"}],"rows":1,"statistics":{}}`)
	}))
	defer srv.Close()
	c := &CH{URL: srv.URL, Usuario: "analista", Clave: "clave-lectura", Base: "jsrbot"}
	filas, err := c.Consultar(context.Background(), "SELECT {desde:Date}", map[string]string{"desde": "2026-07-01", "grupo": "Redes y más"})
	if err != nil {
		t.Fatal(err)
	}
	if len(filas) != 1 || filas[0]["n"] != 5.0 || filas[0]["x"] != nil || filas[0]["s"] != "a" {
		t.Errorf("filas = %v", filas)
	}
	if q["wait_end_of_query"][0] != "1" || q["default_format"][0] != "JSON" || q["param_desde"][0] != "2026-07-01" ||
		q["param_grupo"][0] != "Redes y más" || q["database"][0] != "jsrbot" || q["output_format_json_quote_64bit_integers"][0] != "0" {
		t.Errorf("parámetros: %v", q)
	}
	if cab.Get("X-ClickHouse-User") != "analista" || cab.Get("X-ClickHouse-Key") != "clave-lectura" || cuerpo != "SELECT {desde:Date}" {
		t.Errorf("cabeceras/cuerpo: %v %q", cab, cuerpo)
	}
}

func TestLectorCHErrores(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-ClickHouse-Key") == "mala" {
			http.Error(w, "Code: 516. Authentication failed", 403)
			return
		}
		fmt.Fprint(w, "esto no es JSON")
	}))
	defer srv.Close()
	if _, err := (&CH{URL: srv.URL, Clave: "mala"}).Consultar(context.Background(), "SELECT 1", nil); err == nil || !strings.Contains(err.Error(), "HTTP 403") || strings.Contains(err.Error(), "mala") {
		t.Errorf("rechazo: %v", err)
	}
	if _, err := (&CH{URL: srv.URL}).Consultar(context.Background(), "SELECT 1", nil); err == nil {
		t.Error("una respuesta que no es JSON debe fallar")
	}
	if _, err := (&CH{}).Consultar(context.Background(), "SELECT 1", nil); !errors.Is(err, ErrSinClickHouse) {
		t.Errorf("sin URL: %v", err)
	}
	srv.Close()
	if _, err := (&CH{URL: srv.URL}).Consultar(context.Background(), "SELECT 1", nil); err == nil {
		t.Error("ClickHouse caído debe fallar")
	}
}

func TestLectorDesdeEntorno(t *testing.T) {
	t.Setenv("JSR_CH_URL", "")
	t.Setenv("CLICKHOUSE_URL", "")
	if LectorDesdeEntorno() != nil {
		t.Error("sin URL no hay lector")
	}
	t.Setenv("JSR_CH_URL", "http://jsrbot_clickhouse:8123")
	t.Setenv("JSR_CH_ANALISTA_CLAVE", "x")
	t.Setenv("JSR_CH_BASE", "jsrbot")
	c := LectorDesdeEntorno()
	if c == nil || c.Usuario != "analista" || c.Base != "jsrbot" || c.Clave != "x" {
		t.Errorf("lector = %+v", c)
	}
}

// El catálogo REAL de analitica/ (si está en el repositorio) se puede leer y cada KPI tiene su SQL
// y declara solo parámetros que el ejecutor sabe poner.
func TestCatalogoRealDeAnalitica(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "analitica")
	if _, err := os.Stat(filepath.Join(dir, "catalogo.json")); err != nil {
		t.Skip("no hay analitica/catalogo.json en este repositorio")
	}
	g := Nuevo(dir, &lectorFalso{})
	raw, err := g.Catalogo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var cat struct {
		KPIs []entradaCatalogo `json:"kpis"`
	}
	if err := jsonUnmarshal(raw, &cat); err != nil || len(cat.KPIs) == 0 {
		t.Fatalf("catálogo: %v (%d KPI)", err, len(cat.KPIs))
	}
	for _, k := range cat.KPIs {
		lector := &lectorFalso{}
		r, err := Nuevo(dir, lector).Ejecutar(context.Background(), k.KPI, Params{Desde: "2026-07-01", Hasta: "2026-09-30", Grupo: "Redes"})
		if err != nil {
			t.Errorf("%s: %v", k.KPI, err)
			continue
		}
		if r.Version != k.Version {
			t.Errorf("%s: el catálogo dice v%d y se ejecutó v%d", k.KPI, k.Version, r.Version)
		}
		for p := range lector.params {
			if p != "desde" && p != "hasta" && p != "grupo" {
				t.Errorf("%s: parámetro inesperado %s", k.KPI, p)
			}
		}
		if strings.TrimSpace(lector.sql) == "" {
			t.Errorf("%s: SQL vacío", k.KPI)
		}
	}
}
