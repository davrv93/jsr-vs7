package analitica

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"jsrbot/backend/internal/store"
)

// ErrSinDestino se devuelve cuando no hay URL de ClickHouse configurada.
var ErrSinDestino = errors.New("analitica: no hay URL de ClickHouse configurada (JSR_CH_URL)")

// Config del trabajador. Las credenciales vienen del entorno y nunca se imprimen.
type Config struct {
	// URL base del HTTP de ClickHouse, p. ej. http://clickhouse:8123.
	URL string
	// Usuario y Clave van en las cabeceras X-ClickHouse-User y X-ClickHouse-Key.
	Usuario string
	Clave   string
	// Base de datos destino (opcional).
	Base string
	// Lote es cuántas filas del outbox se toman por vuelta (por defecto 500).
	Lote int
	// Timeout de cada POST (por defecto 30 s).
	Timeout time.Duration
	// Cliente HTTP (opcional; las pruebas inyectan el de httptest).
	Cliente *http.Client
}

// primerEntorno devuelve el primer valor no vacío de las variables dadas.
func primerEntorno(nombres ...string) string {
	for _, n := range nombres {
		if v := os.Getenv(n); v != "" {
			return v
		}
	}
	return ""
}

// ConfigDesdeEntorno lee la conexión de ESCRITURA a ClickHouse: JSR_CH_URL, JSR_CH_USUARIO,
// JSR_CH_CLAVE y JSR_CH_BASE (las de analitica/.env.ejemplo), con CLICKHOUSE_URL,
// CLICKHOUSE_USER, CLICKHOUSE_PASSWORD y CLICKHOUSE_DB como alternativa, y ANALITICA_LOTE.
func ConfigDesdeEntorno() Config {
	lote, _ := strconv.Atoi(os.Getenv("ANALITICA_LOTE"))
	return Config{
		URL:     primerEntorno("JSR_CH_URL", "CLICKHOUSE_URL"),
		Usuario: primerEntorno("JSR_CH_USUARIO", "CLICKHOUSE_USER"),
		Clave:   primerEntorno("JSR_CH_CLAVE", "CLICKHOUSE_PASSWORD"),
		Base:    primerEntorno("JSR_CH_BASE", "CLICKHOUSE_DB"),
		Lote:    lote,
	}
}

// Trabajador vacía outbox_analitica hacia ClickHouse por lotes.
type Trabajador struct {
	db  *store.DB
	cfg Config
	cli *http.Client
}

// NuevoTrabajador crea el trabajador.
func NuevoTrabajador(db *store.DB, cfg Config) *Trabajador {
	if cfg.Lote <= 0 {
		cfg.Lote = 500
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}
	cli := cfg.Cliente
	if cli == nil {
		cli = &http.Client{Timeout: cfg.Timeout}
	}
	return &Trabajador{db: db, cfg: cfg, cli: cli}
}

// Resumen de una corrida de Vaciar.
type Resumen struct {
	// Enviadas cuenta las filas enviadas y marcadas, por tabla destino.
	Enviadas map[string]int
	Total    int
}

// Vaciar manda a ClickHouse TODO lo pendiente del outbox, en lotes, y marca enviado_en.
//
// Garantías:
//   - cada lote se toma con FOR UPDATE SKIP LOCKED: dos trabajadores (o dos instancias del
//     backend) nunca toman la misma fila;
//   - se marca enviado_en solo después de que ClickHouse respondió 200 para esa tabla;
//   - si ClickHouse falla o no responde, lo ya confirmado queda marcado, lo demás sigue
//     pendiente y Vaciar devuelve el error: nada se pierde y el próximo intento reenvía;
//   - es «al menos una vez»: un corte justo entre el 200 y el commit reenvía ese tramo; las
//     tablas ReplacingMergeTree lo deduplican por id/versión.
func (t *Trabajador) Vaciar(ctx context.Context) (Resumen, error) {
	res := Resumen{Enviadas: map[string]int{}}
	if t.cfg.URL == "" {
		return res, ErrSinDestino
	}
	for {
		n, err := t.unLote(ctx, &res)
		if err != nil {
			return res, err
		}
		if n == 0 {
			return res, nil
		}
	}
}

type filaOutbox struct {
	id      int64
	payload []byte
}

// unLote procesa un lote; devuelve cuántas filas tomó (0 = no había nada).
func (t *Trabajador) unLote(ctx context.Context, res *Resumen) (int, error) {
	tx, err := t.db.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("analitica: abrir transacción: %w", err)
	}
	commit := func() error { return tx.Commit(ctx) }
	rows, err := tx.Query(ctx, `SELECT id, tabla, payload FROM outbox_analitica
		WHERE enviado_en IS NULL ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED`, t.cfg.Lote)
	if err != nil {
		_ = tx.Rollback(ctx)
		return 0, fmt.Errorf("analitica: leer el outbox: %w", err)
	}
	var orden []string
	porTabla := map[string][]filaOutbox{}
	total := 0
	for rows.Next() {
		var f filaOutbox
		var tabla string
		if err := rows.Scan(&f.id, &tabla, &f.payload); err != nil {
			rows.Close()
			_ = tx.Rollback(ctx)
			return 0, err
		}
		if _, ok := porTabla[tabla]; !ok {
			orden = append(orden, tabla)
		}
		porTabla[tabla] = append(porTabla[tabla], f)
		total++
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		_ = tx.Rollback(ctx)
		return 0, err
	}
	if total == 0 {
		_ = tx.Rollback(ctx)
		return 0, nil
	}

	for _, tabla := range orden {
		filas := porTabla[tabla]
		if err := t.enviar(ctx, tabla, filas); err != nil {
			// Conserva lo ya confirmado de este lote y deja el resto pendiente.
			if cerr := commit(); cerr != nil {
				return 0, fmt.Errorf("%w (y al confirmar lo ya enviado: %v)", err, cerr)
			}
			return 0, err
		}
		ids := make([]int64, len(filas))
		for i, f := range filas {
			ids[i] = f.id
		}
		if _, err := tx.Exec(ctx, `UPDATE outbox_analitica SET enviado_en = now() WHERE id = ANY($1)`, ids); err != nil {
			_ = tx.Rollback(ctx)
			return 0, fmt.Errorf("analitica: marcar enviadas: %w", err)
		}
		res.Enviadas[tabla] += len(filas)
		res.Total += len(filas)
	}
	if err := commit(); err != nil {
		return 0, fmt.Errorf("analitica: confirmar el lote: %w", err)
	}
	return total, nil
}

// enviar hace un POST de una tabla: INSERT INTO <tabla> FORMAT JSONEachRow con una fila por línea.
func (t *Trabajador) enviar(ctx context.Context, tabla string, filas []filaOutbox) error {
	if !tablasValidas[tabla] {
		return fmt.Errorf("analitica: el outbox trae la tabla %q, que no existe en el contrato", tabla)
	}
	var cuerpo bytes.Buffer
	for _, f := range filas {
		cuerpo.Write(compactar(f.payload))
		cuerpo.WriteByte('\n')
	}
	q := url.Values{}
	q.Set("query", "INSERT INTO "+tabla+" FORMAT JSONEachRow")
	q.Set("date_time_input_format", "best_effort")
	// Sin wait_end_of_query un error a media respuesta llegaría como HTTP 200 con el cuerpo
	// cortado y el lote se marcaría como enviado sin estarlo (analitica/reconstruir.md).
	q.Set("wait_end_of_query", "1")
	// El contrato (CONTRATOS «Cambios») añade campos opcionales (feedback.mensaje_id,
	// incidencias_estado.caso_id) que el esquema de ClickHouse puede no tener todavía: se ignoran
	// en vez de rechazar el lote.
	q.Set("input_format_skip_unknown_fields", "1")
	if t.cfg.Base != "" {
		q.Set("database", t.cfg.Base)
	}
	destino := strings.TrimRight(t.cfg.URL, "/") + "/?" + q.Encode()

	cctx, cancel := context.WithTimeout(ctx, t.cfg.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodPost, destino, &cuerpo)
	if err != nil {
		return fmt.Errorf("analitica: armar la petición a ClickHouse: %w", err)
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	if t.cfg.Usuario != "" {
		req.Header.Set("X-ClickHouse-User", t.cfg.Usuario)
	}
	if t.cfg.Clave != "" {
		req.Header.Set("X-ClickHouse-Key", t.cfg.Clave)
	}
	resp, err := t.cli.Do(req)
	if err != nil {
		// url.Error puede traer la URL; no lleva credenciales (van en cabeceras).
		return fmt.Errorf("analitica: ClickHouse no responde (%s): %w", tabla, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		cuerpoErr, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("analitica: ClickHouse rechazó el lote de %s (HTTP %d): %s",
			tabla, resp.StatusCode, strings.TrimSpace(string(cuerpoErr)))
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

// compactar quita saltos de línea del JSON (JSONEachRow es una fila por línea). jsonb de
// Postgres ya sale en una línea; esto es un seguro.
func compactar(b []byte) []byte {
	if !bytes.ContainsAny(b, "\n\r") {
		return b
	}
	var out bytes.Buffer
	for _, c := range b {
		if c != '\n' && c != '\r' {
			out.WriteByte(c)
		}
	}
	return out.Bytes()
}

// Correr vacía el outbox cada `cada` (por defecto 10 s, ARQUITECTURA §8.2) hasta que ctx se
// cancele. Si ClickHouse falla, registra el error (sin credenciales) y reintenta con espera
// creciente (hasta 2 min); nada se pierde porque las filas siguen pendientes.
func (t *Trabajador) Correr(ctx context.Context, cada time.Duration) {
	if cada <= 0 {
		cada = 10 * time.Second
	}
	if t.cfg.URL == "" {
		log.Printf("analitica: CLICKHOUSE_URL vacía; el outbox se acumula sin enviarse")
		return
	}
	espera := cada
	for {
		res, err := t.Vaciar(ctx)
		switch {
		case err != nil && ctx.Err() == nil:
			log.Printf("analitica: no se pudo vaciar el outbox: %v (reintento en %s)", err, espera)
			espera = min(espera*2, 2*time.Minute)
		default:
			if res.Total > 0 {
				log.Printf("analitica: %d filas enviadas a ClickHouse", res.Total)
			}
			espera = cada
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(espera):
		}
	}
}

// Ping comprueba que ClickHouse responde (GET /ping). Devuelve ErrSinDestino si no hay URL.
func (t *Trabajador) Ping(ctx context.Context) error {
	if t.cfg.URL == "" {
		return ErrSinDestino
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, strings.TrimRight(t.cfg.URL, "/")+"/ping", nil)
	if err != nil {
		return err
	}
	resp, err := t.cli.Do(req)
	if err != nil {
		return fmt.Errorf("analitica: ClickHouse no responde: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("analitica: ClickHouse respondió HTTP %d", resp.StatusCode)
	}
	return nil
}

// ejecutarSQL manda una sentencia suelta (DDL) a ClickHouse.
func (t *Trabajador) ejecutarSQL(ctx context.Context, sql string, sinBase bool) error {
	q := url.Values{}
	q.Set("wait_end_of_query", "1")
	if t.cfg.Base != "" && !sinBase {
		q.Set("database", t.cfg.Base)
	}
	cctx, cancel := context.WithTimeout(ctx, t.cfg.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodPost, strings.TrimRight(t.cfg.URL, "/")+"/?"+q.Encode(), strings.NewReader(sql))
	if err != nil {
		return err
	}
	if t.cfg.Usuario != "" {
		req.Header.Set("X-ClickHouse-User", t.cfg.Usuario)
	}
	if t.cfg.Clave != "" {
		req.Header.Set("X-ClickHouse-Key", t.cfg.Clave)
	}
	resp, err := t.cli.Do(req)
	if err != nil {
		return fmt.Errorf("analitica: ClickHouse no responde: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		cuerpo, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("analitica: ClickHouse rechazó la sentencia (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(cuerpo)))
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

// PartirSentencias parte un archivo .sql en sentencias: ignora las líneas de comentario («--»)
// y separa por «;» (como analitica/herramientas/ch_http.py).
func PartirSentencias(texto string) []string {
	var lineas []string
	for _, l := range strings.Split(texto, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "--") {
			lineas = append(lineas, l)
		}
	}
	var out []string
	for _, s := range strings.Split(strings.Join(lineas, "\n"), ";") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

// AplicarEsquema aplica analitica/esquema.sql sentencia por sentencia (es idempotente: IF NOT
// EXISTS y nombres completos). Se llama al arrancar el motor.
func (t *Trabajador) AplicarEsquema(ctx context.Context, esquemaSQL string) error {
	if t.cfg.URL == "" {
		return ErrSinDestino
	}
	for _, s := range PartirSentencias(esquemaSQL) {
		if err := t.ejecutarSQL(ctx, s, true); err != nil {
			return err
		}
	}
	return nil
}

// ReiniciarDestino borra la base de ClickHouse (DROP DATABASE) y vuelve a aplicar el esquema:
// es el paso 3 y 4 de analitica/reconstruir.md. DESTRUCTIVO para ClickHouse (no para Postgres,
// que es la fuente de verdad): el motor solo lo hace a petición expresa.
func (t *Trabajador) ReiniciarDestino(ctx context.Context, esquemaSQL string) error {
	if t.cfg.URL == "" {
		return ErrSinDestino
	}
	if t.cfg.Base == "" {
		return fmt.Errorf("analitica: no se reinicia el destino sin saber su base (JSR_CH_BASE)")
	}
	if !regexpNombre.MatchString(t.cfg.Base) {
		return fmt.Errorf("analitica: nombre de base inválido")
	}
	if err := t.ejecutarSQL(ctx, "DROP DATABASE IF EXISTS "+t.cfg.Base, true); err != nil {
		return err
	}
	return t.AplicarEsquema(ctx, esquemaSQL)
}

var regexpNombre = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
