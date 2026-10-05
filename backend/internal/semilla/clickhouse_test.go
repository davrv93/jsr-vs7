package semilla_test

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
	"time"

	"jsrbot/backend/internal/analitica"
	"jsrbot/backend/internal/golden"
	"jsrbot/backend/internal/store"
	"jsrbot/backend/internal/store/storetest"
)

// Entorno de ClickHouse efímero (lo levanta scripts/test-db.sh si la imagen está en local).
func chDelEntorno(t *testing.T) (escritura analitica.Config, lector *golden.CH, dirAnalitica, esquema string) {
	t.Helper()
	url := os.Getenv("JSR_TEST_CH_URL")
	if url == "" {
		t.Skip("JSR_TEST_CH_URL no está definida: se salta la prueba con ClickHouse (scripts/test-db.sh la levanta si la imagen está en local)")
	}
	dirAnalitica = filepath.Join("..", "..", "..", "analitica")
	b, err := os.ReadFile(filepath.Join(dirAnalitica, "esquema.sql"))
	if err != nil {
		t.Skip("no hay analitica/esquema.sql en este repositorio")
	}
	escritura = analitica.Config{URL: url, Usuario: os.Getenv("JSR_TEST_CH_USUARIO"), Clave: os.Getenv("JSR_TEST_CH_CLAVE"), Base: "jsrbot", Lote: 300}
	lector = &golden.CH{URL: url, Usuario: os.Getenv("JSR_TEST_CH_ANALISTA_USUARIO"), Clave: os.Getenv("JSR_TEST_CH_ANALISTA_CLAVE"), Base: "jsrbot"}
	return escritura, lector, dirAnalitica, string(b)
}

type filaTiempos struct {
	version  float64
	creadaEn time.Time
	mttr     *float64
	okResp   *float64
	okResol  *float64
	hayMTTR  bool
}

// ultimosTiempos devuelve, por incidencia, la fila de incidencias_tiempos de mayor versión del outbox.
func ultimosTiempos(t *testing.T, db *store.DB) map[float64]filaTiempos {
	t.Helper()
	rows, err := db.Query(context.Background(), `SELECT payload FROM outbox_analitica WHERE tabla = 'incidencias_tiempos'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[float64]filaTiempos{}
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var p map[string]any
		if err := json.Unmarshal(raw, &p); err != nil {
			t.Fatal(err)
		}
		id, ver := p["incidencia_id"].(float64), p["version"].(float64)
		if prev, ok := out[id]; ok && prev.version >= ver {
			continue
		}
		creada, err := time.Parse(time.RFC3339, p["creada_en"].(string))
		if err != nil {
			t.Fatal(err)
		}
		f := filaTiempos{version: ver, creadaEn: creada}
		num := func(k string) *float64 {
			if v, ok := p[k].(float64); ok {
				return &v
			}
			return nil
		}
		f.mttr, f.okResp, f.okResol = num("mttr_min"), num("sla_respuesta_ok"), num("sla_resolucion_ok")
		out[id] = f
	}
	return out
}

func enRango(f filaTiempos, desde, hasta string) bool {
	d := f.creadaEn.In(lima).Format("2006-01-02")
	return d >= desde && d <= hasta
}

// medianaInclusiva imita quantileExactInclusive(0.5) de ClickHouse.
func medianaInclusiva(xs []float64) float64 {
	sort.Float64s(xs)
	pos := float64(len(xs)-1) * 0.5
	i := int(math.Floor(pos))
	if i+1 >= len(xs) {
		return xs[i]
	}
	return xs[i] + (pos-float64(i))*(xs[i+1]-xs[i])
}

func redondear2(f float64) float64 { return math.Round(f*100) / 100 }

func filaDe(filas []map[string]any, col, valor string) map[string]any {
	for _, f := range filas {
		if f[col] == valor {
			return f
		}
	}
	return nil
}

// El outbox de la semilla se carga en un ClickHouse real con el esquema de analitica/ y las golden
// queries dan lo mismo que una cuenta independiente sobre Postgres: volumen, cumplimiento de SLA y
// MTTR. Después se borra ClickHouse, se reconstruye el outbox desde Postgres y se vuelve a cargar: las
// mismas cifras («borrar ClickHouse y reconstruir»).
func TestOutboxDeLaSemillaEnClickHouseDaLosMismosKPI(t *testing.T) {
	cfgEsc, lector, dirAn, esquema := chDelEntorno(t)
	ctx := context.Background()
	db := storetest.NuevaBDConConfig(t)
	o := opcionesChicas()
	cargar(t, db, o)
	trab := analitica.NuevoTrabajador(db, cfgEsc)
	if err := trab.ReiniciarDestino(ctx, esquema); err != nil {
		t.Fatalf("aplicar el esquema de ClickHouse: %v", err)
	}
	pend := 0
	_ = db.QueryRow(ctx, `SELECT count(*) FROM outbox_analitica WHERE enviado_en IS NULL`).Scan(&pend)
	res, err := trab.Vaciar(ctx)
	if err != nil {
		t.Fatalf("cargar el outbox en ClickHouse: %v", err)
	}
	if res.Total != pend || pend == 0 {
		t.Fatalf("enviadas %d de %d pendientes", res.Total, pend)
	}
	t.Logf("cargadas %d filas en ClickHouse: %v", res.Total, res.Enviadas)

	g := golden.Nuevo(dirAn, lector)
	desde, hasta := "2026-07-01", "2026-08-08"
	ejecutar := func(kpi string) []map[string]any {
		t.Helper()
		r, err := g.Ejecutar(ctx, kpi, golden.Params{Desde: desde, Hasta: hasta})
		if err != nil {
			t.Fatalf("golden %s: %v", kpi, err)
		}
		return r.Filas
	}
	comprobar := func(etapa string) {
		// 1. Volumen: incidencias y casos contra Postgres.
		var incPG, casosPG int
		_ = db.QueryRow(ctx, `SELECT count(*) FROM incidencias WHERE (creada_en AT TIME ZONE 'America/Lima')::date BETWEEN $1::date AND $2::date`, desde, hasta).Scan(&incPG)
		_ = db.QueryRow(ctx, `SELECT count(*) FROM casos WHERE (inicio AT TIME ZONE 'America/Lima')::date BETWEEN $1::date AND $2::date`, desde, hasta).Scan(&casosPG)
		vol := filaDe(ejecutar("volumen"), "dimension", "total")
		if vol == nil || vol["incidencias"] != float64(incPG) || vol["casos"] != float64(casosPG) {
			t.Errorf("%s: volumen en ClickHouse %v, en Postgres %d incidencias y %d casos", etapa, vol, incPG, casosPG)
		}

		// 2. Cumplimiento de SLA contra la última fila de tiempos de cada incidencia.
		var evalR, cumpR, evalS, cumpS int
		var mttrs []float64
		for _, f := range ultimosTiempos(t, db) {
			if !enRango(f, desde, hasta) {
				continue
			}
			if f.okResp != nil {
				evalR++
				if *f.okResp == 1 {
					cumpR++
				}
			}
			if f.okResol != nil {
				evalS++
				if *f.okResol == 1 {
					cumpS++
				}
			}
			if f.mttr != nil {
				mttrs = append(mttrs, *f.mttr)
			}
		}
		sl := ejecutar("sla_cumplimiento")
		for _, c := range []struct {
			metrica    string
			eval, cump int
		}{{"respuesta", evalR, cumpR}, {"resolucion", evalS, cumpS}} {
			f := filaDe(sl, "metrica", c.metrica)
			if f == nil || f["evaluadas"] != float64(c.eval) || f["cumplidas"] != float64(c.cump) {
				t.Errorf("%s: SLA %s en ClickHouse %v, cuenta independiente %d/%d", etapa, c.metrica, f, c.cump, c.eval)
				continue
			}
			if c.eval > 0 {
				quiere := redondear2(100 * float64(c.cump) / float64(c.eval))
				if got, _ := f["porcentaje"].(float64); math.Abs(got-quiere) > 0.006 {
					t.Errorf("%s: porcentaje de SLA %s = %v, quiere %v", etapa, c.metrica, got, quiere)
				}
			}
		}
		if evalR == 0 || evalS == 0 {
			t.Errorf("%s: la semilla debe tener veredictos de SLA (%d y %d)", etapa, evalR, evalS)
		}

		// 3. MTTR: mediana y media.
		m := ejecutar("mttr")
		if len(m) != 1 || m[0]["evaluadas"] != float64(len(mttrs)) {
			t.Errorf("%s: MTTR en ClickHouse %v, evaluadas por Postgres %d", etapa, m, len(mttrs))
		} else if len(mttrs) > 0 {
			var suma float64
			for _, x := range mttrs {
				suma += x
			}
			if got := m[0]["mediana_min"].(float64); math.Abs(got-redondear2(medianaInclusiva(append([]float64(nil), mttrs...)))) > 0.006 {
				t.Errorf("%s: mediana de MTTR = %v, cuenta independiente %v", etapa, got, medianaInclusiva(mttrs))
			}
			if got := m[0]["media_min"].(float64); math.Abs(got-redondear2(suma/float64(len(mttrs)))) > 0.006 {
				t.Errorf("%s: media de MTTR = %v, cuenta independiente %v", etapa, got, suma/float64(len(mttrs)))
			}
		}
		t.Logf("%s: volumen %v · SLA respuesta %d/%d, resolución %d/%d · MTTR sobre %d resueltas", etapa, vol, cumpR, evalR, cumpS, evalS, len(mttrs))
	}
	comprobar("tras cargar")

	// Los KPI completos, para compararlos después de reconstruir.
	kpis := []string{"volumen", "sla_cumplimiento", "mttr", "frt", "fcr", "reaperturas", "tasa_escalamiento", "csat", "contencion_asistente", "pendientes_antiguedad", "productividad_tecnico", "calidad_asistente"}
	antes := map[string][]map[string]any{}
	for _, k := range kpis {
		antes[k] = ejecutar(k)
	}

	// Borrar ClickHouse y reconstruir desde Postgres: mismas cifras.
	if err := trab.ReiniciarDestino(ctx, esquema); err != nil {
		t.Fatal(err)
	}
	if _, err := analitica.Reconstruir(ctx, db); err != nil {
		t.Fatal(err)
	}
	if _, err := trab.Vaciar(ctx); err != nil {
		t.Fatal(err)
	}
	comprobar("tras reconstruir")
	for _, k := range kpis {
		if despues := ejecutar(k); !reflect.DeepEqual(antes[k], despues) {
			t.Errorf("la golden query %s cambió tras reconstruir:\n antes:   %v\n después: %v", k, antes[k], despues)
		}
	}
}
