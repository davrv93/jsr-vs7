package escala

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/incidencia"
	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// Vigia es el vigía de SLA: evalúa las reglas de escalamiento sobre las incidencias abiertas.
type Vigia struct {
	db  *store.DB
	inc *incidencia.Servicio
}

// Nuevo crea el vigía sobre el servicio de incidencias (del que toma la base, el caché de SLA
// y la acción Escalar).
func Nuevo(inc *incidencia.Servicio) *Vigia { return &Vigia{db: inc.DB(), inc: inc} }

// ResultadoAccion es lo que pasó (o pasaría, en sombra) con una acción de una regla.
type ResultadoAccion struct {
	Tipo             string `json:"tipo"`
	DestinatarioTipo string `json:"destinatario_tipo,omitempty"`
	DestinatarioID   *int   `json:"destinatario_id,omitempty"`
	// Resultado: plan (sombra) | aviso_encolado | aviso_ya_encolado | sin_destinatario |
	// escalada | sin_nivel_superior | no_aplicable | nota.
	Resultado string `json:"resultado"`
	AvisoID   *int64 `json:"aviso_id,omitempty"`
	Nota      string `json:"nota,omitempty"`
}

// Disparo es una regla que se cumplió para una incidencia.
type Disparo struct {
	IncidenciaID int64             `json:"incidencia_id"`
	Numero       string            `json:"numero"`
	ReglaClave   string            `json:"regla_clave"`
	ReglaVersion int               `json:"regla_version"`
	Modo         string            `json:"modo"`
	Ejecutada    bool              `json:"ejecutada"` // false en sombra
	Cuando       time.Time         `json:"cuando"`
	Detalle      map[string]any    `json:"detalle,omitempty"`
	Acciones     []ResultadoAccion `json:"acciones"`
	// YaRegistrada (solo Reproducir): la base ya tiene un escalamiento de esta regla para la incidencia.
	YaRegistrada bool `json:"ya_registrada,omitempty"`
}

// Informe de una pasada del vigía.
type Informe struct {
	Ahora     time.Time `json:"ahora"`
	Revisadas int       `json:"revisadas"` // incidencias abiertas evaluadas
	Reglas    int       `json:"reglas"`    // reglas vigentes
	Disparos  []Disparo `json:"acciones"`
	// Vencidos cuenta los plazos que esta pasada marcó como vencidos (evento sla_vencido).
	Vencidos int `json:"vencidos,omitempty"`
	// Solo en Ciclo: incidencias de la cola asignadas y resueltas cerradas sin confirmación.
	Asignadas []string `json:"asignadas,omitempty"`
	Cerradas  []string `json:"cerradas,omitempty"`
	Errores   []string `json:"errores,omitempty"`
}

type claveEsc struct {
	inc     int64
	regla   string
	version int
}

// Vigilar evalúa las reglas vigentes sobre todas las incidencias abiertas (no resueltas ni
// cerradas, creadas hasta `ahora`) y, para cada par (incidencia, regla) que se cumple y aún
// no se registró, deja el escalamiento:
//
//   - modo ACTIVO: ejecuta las acciones (avisos encolados, escalamiento funcional, notas),
//     deja eventos (aviso_sla, escalada...) y la fila en escalamientos;
//   - modo SOMBRA: solo deja la fila en escalamientos y en decisiones con lo que HABRÍA hecho.
//
// Es idempotente: UNIQUE (incidencia, regla, versión) en escalamientos y la clave de cada
// aviso garantizan que una pasada repetida, un reinicio o dos vigías a la vez no repitan nada.
// Una regla pasada de sombra a activo sí ejecuta lo que en sombra solo se había registrado.
// Cada disparo va en su propia transacción: si uno falla, queda en Informe.Errores y los demás siguen.
func (v *Vigia) Vigilar(ctx context.Context, ahora time.Time) (*Informe, error) {
	ahora = ahora.UTC()
	inf := &Informe{Ahora: ahora}
	reglas, err := ReglasVigentes(ctx, v.db)
	if err != nil {
		return nil, err
	}
	inf.Reglas = len(reglas)
	fotos, err := v.cargarFotos(ctx, ahora)
	if err != nil {
		return nil, err
	}
	inf.Revisadas = len(fotos)
	if len(fotos) == 0 {
		return inf, nil
	}
	// Con o sin reglas, y en sombra o activo: un plazo que se pasó es un hecho que ClickHouse
	// necesita (veredicto «incumplida»), no una acción del vigía.
	v.marcarVencidos(ctx, fotos, ahora, inf)
	if len(reglas) == 0 {
		return inf, nil
	}

	ids := make([]int64, len(fotos))
	for i, f := range fotos {
		ids[i] = f.ID
	}
	existentes, err := v.escalamientosDe(ctx, ids)
	if err != nil {
		return nil, err
	}

	for _, f := range fotos {
		for _, r := range reglas {
			cumple, detalle := Evaluar(r.Condicion, f)
			if !cumple {
				continue
			}
			if modo, hecho := existentes[claveEsc{f.ID, r.Clave, r.Version}]; hecho && !(modo == ModoSombra && r.Modo == ModoActivo) {
				continue // ya registrada con este modo
			}
			d, err := v.disparar(ctx, r, f, detalle, ahora)
			if err != nil {
				inf.Errores = append(inf.Errores, fmt.Sprintf("%s / %s: %v", f.Numero, r.Clave, err))
				continue
			}
			if d != nil {
				inf.Disparos = append(inf.Disparos, *d)
			}
		}
	}
	return inf, nil
}

// Ciclo es lo que corre cada minuto: reintenta la cola de asignaciones, vigila las reglas y
// cierra las resueltas sin confirmación tras 48 h laborales. Cada paso es independiente: si
// uno falla, los demás se ejecutan y el error queda en Informe.Errores.
func (v *Vigia) Ciclo(ctx context.Context, ahora time.Time) (*Informe, error) {
	ahora = ahora.UTC()
	var errs []string
	asignadas, err := v.inc.DespacharColaEn(ctx, ahora)
	if err != nil {
		errs = append(errs, "cola: "+err.Error())
	}
	inf, err := v.Vigilar(ctx, ahora)
	if err != nil {
		inf = &Informe{Ahora: ahora}
		errs = append(errs, "vigía: "+err.Error())
	}
	cerradas, err := v.inc.CerrarResueltasSinConfirmar(ctx, ahora)
	if err != nil {
		errs = append(errs, "cierre automático: "+err.Error())
	}
	inf.Asignadas, inf.Cerradas = asignadas, cerradas
	inf.Errores = append(inf.Errores, errs...)
	return inf, nil
}

// Correr ejecuta Ciclo cada `cada` (por defecto 1 minuto; no se baja a intervalos mayores:
// un aviso del 75 % llegaría tarde) hasta que ctx se cancele.
func (v *Vigia) Correr(ctx context.Context, cada time.Duration) {
	if cada <= 0 {
		cada = time.Minute
	}
	t := time.NewTicker(cada)
	defer t.Stop()
	for {
		inf, err := v.Ciclo(ctx, time.Now())
		switch {
		case err != nil:
			log.Printf("vigía: %v", err)
		case len(inf.Errores) > 0:
			log.Printf("vigía: %d incidencias revisadas, %d disparos, errores: %s", inf.Revisadas, len(inf.Disparos), strings.Join(inf.Errores, "; "))
		case len(inf.Disparos)+len(inf.Cerradas)+len(inf.Asignadas) > 0:
			log.Printf("vigía: %d incidencias revisadas, %d disparos, %d asignadas de la cola, %d cerradas sin confirmar",
				inf.Revisadas, len(inf.Disparos), len(inf.Asignadas), len(inf.Cerradas))
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// marcarVencidos deja el evento sla_vencido de cada plazo recién pasado (una vez por plazo).
func (v *Vigia) marcarVencidos(ctx context.Context, fotos []Foto, ahora time.Time, inf *Informe) {
	for _, f := range fotos {
		pendientes := []string{}
		if f.PrimeraRespuesta == nil && f.Respuesta.Vencida && !f.MarcadoVencidoRespuesta {
			pendientes = append(pendientes, "respuesta")
		}
		if f.Resolucion.Vencida && !f.MarcadoVencidoResolucion {
			pendientes = append(pendientes, "resolucion")
		}
		for _, metrica := range pendientes {
			var hecho bool
			err := v.db.EnTx(ctx, func(tx pgx.Tx) error {
				var err error
				hecho, err = v.inc.SobreEn(tx, ahora).RegistrarSLAVencido(ctx, f.ID, metrica)
				return err
			})
			if err != nil {
				inf.Errores = append(inf.Errores, fmt.Sprintf("%s / sla_vencido %s: %v", f.Numero, metrica, err))
				continue
			}
			if hecho {
				inf.Vencidos++
			}
		}
	}
}

// ---- lectura ------------------------------------------------------------------------------------

func (v *Vigia) escalamientosDe(ctx context.Context, ids []int64) (map[claveEsc]string, error) {
	rows, err := v.db.Query(ctx, `SELECT incidencia_id, regla_clave, regla_version, modo FROM escalamientos WHERE incidencia_id = ANY($1)`, ids)
	if err != nil {
		return nil, fmt.Errorf("escala: leer escalamientos: %w", err)
	}
	defer rows.Close()
	out := map[claveEsc]string{}
	for rows.Next() {
		var k claveEsc
		var modo string
		if err := rows.Scan(&k.inc, &k.regla, &k.version, &modo); err != nil {
			return nil, err
		}
		out[k] = modo
	}
	return out, rows.Err()
}

// cargarFotos arma la foto de cada incidencia abierta: campos, señales de los eventos y SLA medido.
func (v *Vigia) cargarFotos(ctx context.Context, ahora time.Time) ([]Foto, error) {
	rows, err := v.db.Query(ctx, `SELECT i.id, i.numero, i.titulo, i.prioridad, i.estado, i.grupo_id, COALESCE(g.nombre, ''),
			i.tecnico_id, i.categoria_id, COALESCE(c.clave, ''), i.reaperturas, i.creada_en, i.primera_respuesta_en, i.resuelta_en
		FROM incidencias i
		LEFT JOIN grupos g ON g.id = i.grupo_id
		LEFT JOIN categorias c ON c.id = i.categoria_id
		WHERE i.estado NOT IN ('resuelta', 'cerrada') AND i.creada_en <= $1 ORDER BY i.id`, ahora)
	if err != nil {
		return nil, fmt.Errorf("escala: leer incidencias abiertas: %w", err)
	}
	var fotos []Foto
	for rows.Next() {
		var f Foto
		if err := rows.Scan(&f.ID, &f.Numero, &f.Titulo, &f.Prioridad, &f.Estado, &f.GrupoID, &f.Grupo, &f.TecnicoID,
			&f.CategoriaID, &f.Categoria, &f.Reaperturas, &f.Creada, &f.PrimeraRespuesta, &f.Resuelta); err != nil {
			rows.Close()
			return nil, err
		}
		f.Creada = f.Creada.UTC()
		f.PrimeraRespuesta, f.Resuelta = store.UTCPtr(f.PrimeraRespuesta), store.UTCPtr(f.Resuelta)
		fotos = append(fotos, f)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(fotos) == 0 {
		return nil, nil
	}
	ids := make([]int64, len(fotos))
	idx := map[int64]int{}
	for i, f := range fotos {
		ids[i] = f.ID
		idx[f.ID] = i
	}

	// Señales de los eventos: vip y motivo (de «creada») y queja.
	erows, err := v.db.Query(ctx, `SELECT incidencia_id, tipo, datos FROM incidencia_eventos
		WHERE incidencia_id = ANY($1) AND tipo IN ('creada', 'queja', 'sla_vencido')`, ids)
	if err != nil {
		return nil, fmt.Errorf("escala: leer señales: %w", err)
	}
	for erows.Next() {
		var id int64
		var tipo string
		var raw []byte
		if err := erows.Scan(&id, &tipo, &raw); err != nil {
			erows.Close()
			return nil, err
		}
		f := &fotos[idx[id]]
		switch tipo {
		case "queja":
			f.Queja = true
		case "sla_vencido":
			var d struct {
				Metrica string `json:"metrica"`
			}
			_ = json.Unmarshal(raw, &d)
			f.MarcadoVencidoRespuesta = f.MarcadoVencidoRespuesta || d.Metrica == "respuesta"
			f.MarcadoVencidoResolucion = f.MarcadoVencidoResolucion || d.Metrica == "resolucion"
		case "creada":
			var d struct {
				VIP    bool   `json:"vip"`
				Motivo string `json:"motivo"`
			}
			_ = json.Unmarshal(raw, &d)
			f.VIP = d.VIP
			f.GuiaAgotada = d.Motivo == "guia_agotada"
		}
	}
	erows.Close()
	if err := erows.Err(); err != nil {
		return nil, err
	}

	// SLA medido ahora, desde los eventos.
	marcas, err := store.MarcasReloj(ctx, v.db, ids)
	if err != nil {
		return nil, err
	}
	cache := v.inc.Cache()
	for i := range fotos {
		f := &fotos[i]
		cs, err := cache.Contexto(ctx, v.db, f.Prioridad, f.CategoriaID)
		if err != nil {
			return nil, err
		}
		r := sla.Evaluar(sla.Entrada{
			Cal: cs.Cal, Pol: cs.Pol, Creada: f.Creada, PrimeraRespuesta: f.PrimeraRespuesta, Resuelta: f.Resuelta,
			Pausas: sla.PausasDeEventos(marcas[f.ID]), Ahora: ahora,
		})
		f.Respuesta, f.Resolucion = r.Respuesta, r.Resolucion
	}
	return fotos, nil
}

// ---- disparo --------------------------------------------------------------------------------------

// disparar registra (y, en modo activo, ejecuta) una regla cumplida para una incidencia, en
// una transacción. Devuelve nil si otra pasada ya la había registrado.
func (v *Vigia) disparar(ctx context.Context, r Regla, f Foto, detalle map[string]any, ahora time.Time) (*Disparo, error) {
	var out *Disparo
	err := v.db.EnTx(ctx, func(tx pgx.Tx) error {
		out = nil
		// Bloquea la incidencia: si cambió de estado desde la lectura, ya no se vigila.
		var estado string
		var grupoID *int
		var tecnicoID *int
		if err := tx.QueryRow(ctx, `SELECT estado, grupo_id, tecnico_id FROM incidencias WHERE id = $1 FOR UPDATE`, f.ID).
			Scan(&estado, &grupoID, &tecnicoID); err != nil {
			return fmt.Errorf("incidencia %s: %w", f.Numero, err)
		}
		if estado == "resuelta" || estado == "cerrada" {
			return nil
		}
		f.GrupoID, f.TecnicoID = grupoID, tecnicoID

		// Registro idempotente: solo el que lo inserta (o sube de sombra a activo) ejecuta.
		var escID int64
		err := tx.QueryRow(ctx, `INSERT INTO escalamientos (incidencia_id, regla_clave, regla_version, modo, accion, ts)
			VALUES ($1, $2, $3, $4, '{}'::jsonb, $5)
			ON CONFLICT (incidencia_id, regla_clave, regla_version) DO UPDATE
			   SET modo = EXCLUDED.modo, ts = EXCLUDED.ts
			   WHERE escalamientos.modo = 'sombra' AND EXCLUDED.modo = 'activo'
			RETURNING id`, f.ID, r.Clave, r.Version, r.Modo, ahora).Scan(&escID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // otra pasada se adelantó
		}
		if err != nil {
			return fmt.Errorf("registrar el escalamiento: %w", err)
		}

		d := Disparo{
			IncidenciaID: f.ID, Numero: f.Numero, ReglaClave: r.Clave, ReglaVersion: r.Version, Modo: r.Modo,
			Ejecutada: r.Modo == ModoActivo, Cuando: ahora, Detalle: detalle, Acciones: []ResultadoAccion{},
		}
		op := v.inc.SobreEn(tx, ahora)
		grupoOriginal := f.GrupoID
		for _, a := range r.Acciones {
			res, err := v.accion(ctx, op, tx, r, a, f, grupoOriginal, detalle, ahora)
			if err != nil {
				return err
			}
			d.Acciones = append(d.Acciones, res...)
		}

		raw, _ := json.Marshal(map[string]any{"acciones": d.Acciones, "ejecutada": d.Ejecutada, "detalle": detalle})
		if _, err := tx.Exec(ctx, `UPDATE escalamientos SET accion = $2 WHERE id = $1`, escID, raw); err != nil {
			return fmt.Errorf("guardar el resultado del escalamiento: %w", err)
		}
		entrada, _ := json.Marshal(map[string]any{"incidencia_id": f.ID, "numero": f.Numero, "regla": r.Clave, "version": r.Version, "detalle": detalle})
		if _, err := tx.Exec(ctx, `INSERT INTO decisiones (caso_id, ts, componente, modo, entrada, salida)
			VALUES (NULL, $1, 'escalamiento', $2, $3, $4)`, ahora, r.Modo, entrada, raw); err != nil {
			return fmt.Errorf("registrar la decisión: %w", err)
		}
		out = &d
		return nil
	})
	return out, err
}

// accion ejecuta (activo) o planea (sombra) una acción de la regla.
func (v *Vigia) accion(ctx context.Context, op *incidencia.Operaciones, tx pgx.Tx, r Regla, a Accion, f Foto,
	grupoOriginal *int, detalle map[string]any, ahora time.Time) ([]ResultadoAccion, error) {

	activo := r.Modo == ModoActivo
	switch a.Tipo {
	case AccEscalarNivel:
		if !activo {
			return []ResultadoAccion{{Tipo: a.Tipo, Resultado: "plan"}}, nil
		}
		res, err := op.Escalar(ctx, f.ID, incidencia.EntradaEscalar{Motivo: r.Clave, Actor: incidencia.ActorSistema()})
		switch {
		case errors.Is(err, incidencia.ErrSinNivelSuperior):
			return []ResultadoAccion{{Tipo: a.Tipo, Resultado: "sin_nivel_superior"}}, nil
		case errors.Is(err, incidencia.ErrTransicionInvalida), errors.Is(err, incidencia.ErrInvalido):
			return []ResultadoAccion{{Tipo: a.Tipo, Resultado: "no_aplicable", Nota: err.Error()}}, nil
		case err != nil:
			return nil, err
		}
		out := ResultadoAccion{Tipo: a.Tipo, Resultado: "escalada"}
		if res.Incidencia.TecnicoID != nil {
			out.DestinatarioTipo, out.DestinatarioID = store.DestTecnico, res.Incidencia.TecnicoID
		}
		return []ResultadoAccion{out}, nil

	case AccNota:
		if !activo {
			return []ResultadoAccion{{Tipo: a.Tipo, Resultado: "plan"}}, nil
		}
		if _, err := op.RegistrarEvento(ctx, f.ID, incidencia.ActorSistema(), incidencia.EvComentarioInt,
			map[string]any{"texto": a.Texto, "visible": "interno", "origen": r.Clave}); err != nil {
			return nil, err
		}
		return []ResultadoAccion{{Tipo: a.Tipo, Resultado: "nota"}}, nil

	case AccAvisarTecnico, AccAvisarResponsable, AccAvisarGuardia, AccAvisarSupervisor:
		destinos, nota, err := v.destinatarios(ctx, tx, a.Tipo, f, grupoOriginal, ahora)
		if err != nil {
			return nil, err
		}
		var out []ResultadoAccion
		for _, d := range destinos {
			res := ResultadoAccion{Tipo: a.Tipo, DestinatarioTipo: d.tipo, DestinatarioID: d.id, Nota: nota}
			switch {
			case d.id == nil:
				res.Resultado = "sin_destinatario"
			case !activo:
				res.Resultado = "plan"
			default:
				if err := v.encolarAviso(ctx, op, tx, r, a, d, f, detalle, ahora, &res); err != nil {
					return nil, err
				}
			}
			out = append(out, res)
			if activo && d.id == nil {
				if _, err := op.RegistrarEvento(ctx, f.ID, incidencia.ActorSistema(), incidencia.EvAvisoSLA, map[string]any{
					"regla": r.Clave, "version": r.Version, "accion": a.Tipo, "destinatario_tipo": d.tipo, "sin_destinatario": true,
				}); err != nil {
					return nil, err
				}
			}
		}
		return out, nil
	}
	return nil, fmt.Errorf("acción %q desconocida", a.Tipo)
}

// encolarAviso deja el aviso en la tabla avisos (una sola vez por clave) y el evento aviso_sla.
func (v *Vigia) encolarAviso(ctx context.Context, op *incidencia.Operaciones, tx pgx.Tx, r Regla, a Accion, d destino,
	f Foto, detalle map[string]any, ahora time.Time, res *ResultadoAccion) error {

	inc, err := op.Obtener(ctx, f.ID) // el estado actual (puede haber cambiado si antes hubo un escalamiento)
	if err != nil {
		return err
	}
	datos := incidencia.DatosAviso(inc)
	datos["regla"] = r.Clave
	for k, val := range detalle {
		datos[k] = val
	}
	incID := f.ID
	canal := "whatsapp"
	if d.tipo != store.DestPersona {
		canal = store.CanalTecnico(ctx, tx, *d.id)
	}
	plantilla := plantillaAviso(r)
	id, nuevo, err := store.EncolarAviso(ctx, tx, store.NuevoAviso{
		IncidenciaID: &incID, DestinatarioTipo: d.tipo, DestinatarioID: d.id, Canal: canal, Plantilla: plantilla, Datos: datos,
		Clave: fmt.Sprintf("esc:%d:%s:%d:%s:%s:%d", f.ID, r.Clave, r.Version, a.Tipo, d.tipo, *d.id),
	}, ahora)
	if err != nil {
		return err
	}
	if !nuevo {
		res.Resultado = "aviso_ya_encolado"
		return nil
	}
	res.Resultado, res.AvisoID = "aviso_encolado", &id
	_, err = op.RegistrarEvento(ctx, f.ID, incidencia.ActorSistema(), incidencia.EvAvisoSLA, map[string]any{
		"regla": r.Clave, "version": r.Version, "accion": a.Tipo, "destinatario_tipo": d.tipo, "destinatario_id": *d.id,
		"plantilla": plantilla, "aviso_id": id,
	})
	return err
}
