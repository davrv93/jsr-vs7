// Package golden ejecuta las golden queries (AGENTS §1.4 regla 7: un KPI, una golden query).
//
// El catálogo (analitica/catalogo.json) lo genera analitica/herramientas/generar_catalogo.py
// desde analitica/golden/<kpi>/meta.yaml; el SQL de cada KPI está en analitica/golden/<kpi>/vN.sql
// y se ejecuta SIEMPRE con la última versión, con los parámetros {desde:Date}, {hasta:Date} y
// {grupo:String}, contra ClickHouse con el usuario de SOLO LECTURA (analista). Nadie más
// calcula un KPI con SQL propio: ni este paquete ni el tablero.
//
// La ejecución va detrás de la interfaz Lector, así que las pruebas usan un ClickHouse falso.
package golden

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Errores públicos (errors.Is).
var (
	// ErrSinCatalogo: no existe analitica/catalogo.json.
	ErrSinCatalogo = errors.New("el catálogo de golden queries no está disponible")
	// ErrNoEncontrado: el KPI no está en el catálogo.
	ErrNoEncontrado = errors.New("no existe esa golden query")
	// ErrInvalido: parámetros mal formados (fecha, kpi).
	ErrInvalido = errors.New("parámetros inválidos")
	// ErrSinClickHouse: no hay lector configurado.
	ErrSinClickHouse = errors.New("ClickHouse no está configurado")
)

// Lector ejecuta una consulta de solo lectura y devuelve las filas.
type Lector interface {
	Consultar(ctx context.Context, sql string, parametros map[string]string) ([]map[string]any, error)
}

// Params son los parámetros de una golden query.
type Params struct {
	Desde string // AAAA-MM-DD
	Hasta string // AAAA-MM-DD
	Grupo string // nombre del grupo de origen; vacío = todos
}

// Resultado es lo que devuelve una golden query: {kpi, version, definicion, unidad, filas}.
type Resultado struct {
	KPI        string            `json:"kpi"`
	Nombre     string            `json:"nombre,omitempty"`
	Version    int               `json:"version"`
	Definicion string            `json:"definicion"`
	Unidad     string            `json:"unidad"`
	Parametros map[string]string `json:"parametros"`
	// SQL es el texto de la vN.sql ejecutada (solo lectura del archivo; los parámetros van aparte
	// y no hay nada secreto en él). La consola lo muestra en «Definición ▸ SQL».
	SQL   string           `json:"sql"`
	Filas []map[string]any `json:"filas"`
}

// Golden lee el catálogo y el SQL de analitica/ y los ejecuta con un Lector.
type Golden struct {
	dir    string
	lector Lector
}

// Nuevo crea el ejecutor. dir es la carpeta analitica/ (con catalogo.json y golden/).
func Nuevo(dir string, lector Lector) *Golden { return &Golden{dir: dir, lector: lector} }

// Catalogo devuelve el JSON del catálogo tal cual está en disco.
func (g *Golden) Catalogo(ctx context.Context) (json.RawMessage, error) {
	b, err := os.ReadFile(filepath.Join(g.dir, "catalogo.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrSinCatalogo
	}
	if err != nil {
		return nil, fmt.Errorf("golden: leer el catálogo: %w", err)
	}
	if !json.Valid(b) {
		return nil, fmt.Errorf("golden: catalogo.json no es JSON válido")
	}
	return json.RawMessage(b), nil
}

// CatalogoConSQL es el catálogo con una clave extra `sql` en cada KPI: el texto de su ÚLTIMA
// versión (vN.sql). Un KPI cuyo archivo no se puede leer sale con `sql` vacío.
func (g *Golden) CatalogoConSQL(ctx context.Context) (json.RawMessage, error) {
	raw, err := g.Catalogo(ctx)
	if err != nil {
		return nil, err
	}
	var cat map[string]any
	if err := json.Unmarshal(raw, &cat); err != nil {
		return nil, fmt.Errorf("golden: catalogo.json: %w", err)
	}
	kpis, _ := cat["kpis"].([]any)
	for _, k := range kpis {
		m, ok := k.(map[string]any)
		if !ok {
			continue
		}
		nombre, _ := m["kpi"].(string)
		m["sql"] = ""
		if !reKPI.MatchString(nombre) {
			continue
		}
		if _, sql, err := g.ultimaVersion(nombre); err == nil {
			m["sql"] = sql
		}
	}
	out, err := json.Marshal(cat)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(out), nil
}

type entradaCatalogo struct {
	KPI        string   `json:"kpi"`
	Nombre     string   `json:"nombre"`
	Version    int      `json:"version"`
	Unidad     string   `json:"unidad"`
	Definicion string   `json:"definicion"`
	Parametros []string `json:"parametros"`
}

var (
	reKPI   = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	reFecha = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	reSQLV  = regexp.MustCompile(`^v(\d+)\.sql$`)
)

func (g *Golden) entrada(ctx context.Context, kpi string) (*entradaCatalogo, error) {
	raw, err := g.Catalogo(ctx)
	if err != nil {
		return nil, err
	}
	var cat struct {
		KPIs []entradaCatalogo `json:"kpis"`
	}
	if err := json.Unmarshal(raw, &cat); err != nil {
		return nil, fmt.Errorf("golden: catalogo.json: %w", err)
	}
	for i := range cat.KPIs {
		if cat.KPIs[i].KPI == kpi {
			return &cat.KPIs[i], nil
		}
	}
	return nil, fmt.Errorf("%w: %q", ErrNoEncontrado, kpi)
}

// ultimaVersion busca el vN.sql más alto de analitica/golden/<kpi>/.
func (g *Golden) ultimaVersion(kpi string) (int, string, error) {
	carpeta := filepath.Join(g.dir, "golden", kpi)
	ents, err := os.ReadDir(carpeta)
	if err != nil {
		return 0, "", fmt.Errorf("%w: %q (sin carpeta golden/%s)", ErrNoEncontrado, kpi, kpi)
	}
	var versiones []int
	for _, e := range ents {
		if m := reSQLV.FindStringSubmatch(e.Name()); m != nil {
			n, _ := strconv.Atoi(m[1])
			versiones = append(versiones, n)
		}
	}
	if len(versiones) == 0 {
		return 0, "", fmt.Errorf("%w: %q no tiene ningún vN.sql", ErrNoEncontrado, kpi)
	}
	sort.Ints(versiones)
	v := versiones[len(versiones)-1]
	b, err := os.ReadFile(filepath.Join(carpeta, fmt.Sprintf("v%d.sql", v)))
	if err != nil {
		return 0, "", fmt.Errorf("golden: leer v%d.sql de %s: %w", v, kpi, err)
	}
	return v, string(b), nil
}

// Ejecutar corre la última versión de la golden query del KPI con los parámetros dados.
// desde y hasta son obligatorios cuando la consulta los declara (AAAA-MM-DD, día de Lima);
// grupo, por defecto vacío (todos). Los parámetros que la consulta no declara se ignoran.
func (g *Golden) Ejecutar(ctx context.Context, kpi string, p Params) (*Resultado, error) {
	if !reKPI.MatchString(kpi) {
		return nil, fmt.Errorf("%w: kpi %q", ErrInvalido, kpi)
	}
	if g.lector == nil {
		return nil, ErrSinClickHouse
	}
	ent, err := g.entrada(ctx, kpi)
	if err != nil {
		return nil, err
	}
	version, sql, err := g.ultimaVersion(kpi)
	if err != nil {
		return nil, err
	}
	declarados := map[string]bool{}
	for _, m := range regexp.MustCompile(`\{(\w+):`).FindAllStringSubmatch(sql, -1) {
		declarados[m[1]] = true
	}
	params := map[string]string{}
	for nombre, valor := range map[string]string{"desde": p.Desde, "hasta": p.Hasta} {
		if !declarados[nombre] {
			continue
		}
		if !reFecha.MatchString(valor) {
			return nil, fmt.Errorf("%w: %s debe ser una fecha AAAA-MM-DD (llegó %q)", ErrInvalido, nombre, valor)
		}
		if _, err := time.Parse("2006-01-02", valor); err != nil {
			return nil, fmt.Errorf("%w: %s no es una fecha real (%q)", ErrInvalido, nombre, valor)
		}
		params[nombre] = valor
	}
	if declarados["desde"] && declarados["hasta"] && params["desde"] > params["hasta"] {
		return nil, fmt.Errorf("%w: desde (%s) es posterior a hasta (%s)", ErrInvalido, params["desde"], params["hasta"])
	}
	if declarados["grupo"] {
		params["grupo"] = p.Grupo
	}
	filas, err := g.lector.Consultar(ctx, sql, params)
	if err != nil {
		return nil, err
	}
	if filas == nil {
		filas = []map[string]any{}
	}
	return &Resultado{KPI: kpi, Nombre: ent.Nombre, Version: version, Definicion: ent.Definicion, Unidad: ent.Unidad, Parametros: params, SQL: sql, Filas: filas}, nil
}

// ---- lector HTTP de ClickHouse ------------------------------------------------------------------------------

// CH es un Lector por el HTTP de ClickHouse con las credenciales del usuario de solo lectura.
type CH struct {
	URL     string
	Usuario string
	Clave   string
	Base    string
	Cliente *http.Client
}

// cupoConsultas limita las consultas simultáneas a ClickHouse. El usuario `analista` admite 4
// (max_concurrent_queries_for_user en analitica/usuarios.xml) y el tablero lanza los 12 KPI a la vez:
// sin este cupo, ClickHouse contesta TOO_MANY_SIMULTANEOUS_QUERIES y la consola muestra KPI sin cifra.
// Se deja uno libre para consultas sueltas (el analista, la exportación).
var cupoConsultas = make(chan struct{}, 3)

// Consultar ejecuta el SQL con parámetros param_<nombre> y formato JSON.
//
// Manda wait_end_of_query=1: sin él, un límite excedido a mitad de consulta llegaría como un
// HTTP 200 con el cuerpo cortado (analitica/herramientas/ch_http.py). Los enteros de 64 bits
// salen como números, no como texto.
func (c *CH) Consultar(ctx context.Context, sql string, parametros map[string]string) ([]map[string]any, error) {
	if c.URL == "" {
		return nil, ErrSinClickHouse
	}
	select {
	case cupoConsultas <- struct{}{}:
		defer func() { <-cupoConsultas }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	q := url.Values{}
	q.Set("default_format", "JSON")
	q.Set("wait_end_of_query", "1")
	q.Set("output_format_json_quote_64bit_integers", "0")
	if c.Base != "" {
		q.Set("database", c.Base)
	}
	for k, v := range parametros {
		q.Set("param_"+k, v)
	}
	cli := c.Cliente
	if cli == nil {
		cli = &http.Client{Timeout: 30 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.URL, "/")+"/?"+q.Encode(), strings.NewReader(sql))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	if c.Usuario != "" {
		req.Header.Set("X-ClickHouse-User", c.Usuario)
	}
	if c.Clave != "" {
		req.Header.Set("X-ClickHouse-Key", c.Clave)
	}
	resp, err := cli.Do(req)
	if err != nil {
		return nil, fmt.Errorf("golden: ClickHouse no responde: %w", err)
	}
	defer resp.Body.Close()
	cuerpo, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, fmt.Errorf("golden: leer la respuesta de ClickHouse: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		corto := bytes.TrimSpace(cuerpo)
		if len(corto) > 300 {
			corto = corto[:300]
		}
		return nil, fmt.Errorf("golden: ClickHouse rechazó la consulta (HTTP %d): %s", resp.StatusCode, corto)
	}
	var salida struct {
		Data []map[string]any `json:"data"`
	}
	dec := json.NewDecoder(bytes.NewReader(cuerpo))
	if err := dec.Decode(&salida); err != nil {
		return nil, fmt.Errorf("golden: la respuesta de ClickHouse no es JSON: %w", err)
	}
	return salida.Data, nil
}

// LectorDesdeEntorno arma el lector con JSR_CH_URL, JSR_CH_ANALISTA_USUARIO, JSR_CH_ANALISTA_CLAVE
// y JSR_CH_BASE (analitica/.env.ejemplo). Devuelve nil si no hay URL.
func LectorDesdeEntorno() *CH {
	url := os.Getenv("JSR_CH_URL")
	if url == "" {
		url = os.Getenv("CLICKHOUSE_URL")
	}
	if url == "" {
		return nil
	}
	base := os.Getenv("JSR_CH_BASE")
	if base == "" {
		base = os.Getenv("CLICKHOUSE_DB")
	}
	usuario := os.Getenv("JSR_CH_ANALISTA_USUARIO")
	if usuario == "" {
		usuario = "analista"
	}
	return &CH{URL: url, Usuario: usuario, Clave: os.Getenv("JSR_CH_ANALISTA_CLAVE"), Base: base}
}
