package incidencia

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/despacho"
	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// EntradaCrear son los datos para abrir una incidencia. El asistente PROPONE tipo, categoría,
// impacto y urgencia; la prioridad la calcula el código con la matriz (nunca viene de fuera).
type EntradaCrear struct {
	PersonaID *int   // quien reporta (personas.id); nil si se desconoce
	CasoID    *int64 // conversación de origen
	Tipo      string // incidente (por defecto) | solicitud | consulta | problema
	// Categoria es la clave (correo, vpn...). Vacía o desconocida => "otro".
	Categoria string
	Impacto   string // persona (por defecto) | area | sede | organizacion
	Urgencia  string // media (por defecto) | baja | alta | critica
	Titulo    string // obligatorio
	Resumen   string
	Canal     string // whatsapp (por defecto) | web | consola
	Actor     Actor  // quien la abre; por defecto el asistente
	// Motivo: guia_agotada | p1 | pidio_tecnico | sin_articulo | manual (por defecto).
	Motivo string
	// Queja: la persona se quejó explícitamente o su ánimo es muy negativo (deja un evento 'queja').
	Queja bool
}

// Resultado de las acciones que pueden asignar: la incidencia como quedó y la decisión del despachador.
type Resultado struct {
	Incidencia *Incidencia
	// Despacho es la decisión del despachador (nil si la acción no despachó).
	Despacho *despacho.Decision
}

func (e *EntradaCrear) normalizar() error {
	e.Titulo = strings.TrimSpace(e.Titulo)
	if e.Titulo == "" {
		return invalido("el título es obligatorio")
	}
	if e.Tipo == "" {
		e.Tipo = "incidente"
	}
	switch e.Tipo {
	case "incidente", "solicitud", "consulta", "problema":
	default:
		return invalido("tipo %q desconocido", e.Tipo)
	}
	if e.Impacto == "" {
		e.Impacto = "persona"
	}
	if !sla.ValidoImpacto(e.Impacto) {
		return invalido("impacto %q desconocido (use %v)", e.Impacto, sla.Impactos)
	}
	if e.Urgencia == "" {
		e.Urgencia = "media"
	}
	if !sla.ValidaUrgencia(e.Urgencia) {
		return invalido("urgencia %q desconocida (use %v)", e.Urgencia, sla.Urgencias)
	}
	if e.Canal == "" {
		e.Canal = "whatsapp"
	}
	switch e.Canal {
	case "whatsapp", "web", "consola":
	default:
		return invalido("canal %q desconocido (use whatsapp, web o consola)", e.Canal)
	}
	if e.Actor.Tipo == "" {
		e.Actor = ActorAsistente()
	}
	if err := e.Actor.validar(); err != nil {
		return err
	}
	if e.Motivo == "" {
		e.Motivo = "manual"
	}
	return nil
}

// Crear abre una incidencia:
//
//  1. valida la entrada y resuelve la categoría (desconocida => "otro");
//  2. calcula la prioridad con la matriz impacto x urgencia y sube a P2 si la persona es VIP;
//  3. inserta la fila y el evento «creada» (con prioridad_base, vip y motivo en su detalle);
//  4. llama al despachador: técnico (evento «asignada», estado «asignada» y aviso al técnico)
//     o cola del grupo (evento «en_cola», estado «nueva» y aviso al responsable del grupo);
//  5. calcula vence_respuesta_en y vence_resolucion_en con el reloj de SLA.
//
// Deja en outbox_analitica los eventos, incidencias_estado e incidencias_tiempos, y una fila
// en decisiones (componente despacho). Todo en la misma transacción.
func (o *Operaciones) Crear(ctx context.Context, e EntradaCrear) (*Resultado, error) {
	if err := e.normalizar(); err != nil {
		return nil, err
	}

	// Categoría y grupo.
	var catID, grupoCat *int
	var catClave string
	err := o.tx.QueryRow(ctx, `SELECT id, clave, grupo_id FROM categorias WHERE clave = $1 AND activa`, e.Categoria).Scan(&catID, &catClave, &grupoCat)
	if errors.Is(err, pgx.ErrNoRows) {
		err = o.tx.QueryRow(ctx, `SELECT id, clave, grupo_id FROM categorias WHERE clave = 'otro'`).Scan(&catID, &catClave, &grupoCat)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, invalido("no existe la categoría %q ni la categoría «otro»", e.Categoria)
	}
	if err != nil {
		return nil, fmt.Errorf("categoría %q: %w", e.Categoria, err)
	}
	grupoID := grupoCat
	if grupoID == nil {
		var g int
		if err := o.tx.QueryRow(ctx, `SELECT id FROM grupos WHERE nivel = 'N1' ORDER BY id LIMIT 1`).Scan(&g); err != nil {
			return nil, invalido("la categoría %q no tiene grupo y no hay ningún grupo N1", catClave)
		}
		grupoID = &g
	}
	var grupoNombre, grupoNivel string
	if err := o.tx.QueryRow(ctx, `SELECT nombre, nivel FROM grupos WHERE id = $1`, *grupoID).Scan(&grupoNombre, &grupoNivel); err != nil {
		return nil, fmt.Errorf("grupo %d: %w", *grupoID, err)
	}

	// Prioridad por matriz y mínimo VIP.
	matriz, err := o.s.cache.Matriz(ctx, o.tx)
	if err != nil {
		return nil, err
	}
	base, err := matriz.Prioridad(e.Impacto, e.Urgencia)
	if err != nil {
		return nil, invalido("%v", err)
	}
	prioridad, vip, vipAplicado := base, false, false
	if e.PersonaID != nil {
		err := o.tx.QueryRow(ctx, `SELECT vip FROM personas WHERE id = $1`, *e.PersonaID).Scan(&vip)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, invalido("la persona %d no existe", *e.PersonaID)
		}
		if err != nil {
			return nil, fmt.Errorf("persona %d: %w", *e.PersonaID, err)
		}
	}
	if vip {
		minimo, err := store.ConfigTexto(ctx, o.tx, store.ConfVIPPrioridadMinima, "P2")
		if err != nil {
			return nil, err
		}
		prioridad, vipAplicado = sla.AplicarMinimo(prioridad, minimo)
	}

	// Inserción.
	inc := &Incidencia{
		PersonaID: e.PersonaID, CasoID: e.CasoID, Tipo: e.Tipo, CategoriaID: catID, Categoria: catClave,
		Impacto: e.Impacto, Urgencia: e.Urgencia, Prioridad: prioridad, Estado: Nueva, Titulo: e.Titulo,
		Resumen: e.Resumen, GrupoID: grupoID, Grupo: grupoNombre, Nivel: grupoNivel, Canal: e.Canal,
		CreadaEn: o.ahora, ActualizadaEn: o.ahora,
	}
	err = o.tx.QueryRow(ctx, `INSERT INTO incidencias (persona_id, caso_id, tipo, categoria_id, impacto, urgencia, prioridad,
			estado, titulo, resumen, grupo_id, nivel, canal, creada_en, actualizada_en)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'nueva', $8, $9, $10, $11, $12, $13, $13) RETURNING id, numero, token_publico`,
		inc.PersonaID, inc.CasoID, inc.Tipo, inc.CategoriaID, inc.Impacto, inc.Urgencia, inc.Prioridad, inc.Titulo,
		inc.Resumen, inc.GrupoID, inc.Nivel, inc.Canal, o.ahora).Scan(&inc.ID, &inc.Numero, &inc.TokenPublico)
	if err != nil {
		return nil, fmt.Errorf("crear incidencia: %w", err)
	}

	if _, err := o.emitir(ctx, inc, e.Actor, EvCreada, map[string]any{
		"tipo": inc.Tipo, "impacto": inc.Impacto, "urgencia": inc.Urgencia, "prioridad": inc.Prioridad,
		"prioridad_base": base, "vip": vip, "vip_minimo_aplicado": vipAplicado, "motivo": e.Motivo,
		"canal": inc.Canal, "grupo_id": inc.GrupoID, "persona_id": inc.PersonaID, "caso_id": inc.CasoID,
	}); err != nil {
		return nil, err
	}
	if e.Queja {
		if _, err := o.emitir(ctx, inc, e.Actor, EvQueja, map[string]any{"origen": "creacion"}); err != nil {
			return nil, err
		}
	}

	dec, err := o.despachar(ctx, inc, ActorSistema(), EvAsignada, "creacion")
	if err != nil {
		return nil, err
	}
	if err := o.finalizar(ctx, inc); err != nil {
		return nil, err
	}
	return &Resultado{Incidencia: inc, Despacho: dec}, nil
}

// despachar corre el despachador para la incidencia y aplica su decisión: asigna (evento
// tipoEvento, estado «asignada» y aviso al técnico) o la manda a la cola del grupo (evento
// «en_cola», estado «nueva» y aviso al responsable). Deja el registro en decisiones.
// Quien llama debe invocar finalizar después.
func (o *Operaciones) despachar(ctx context.Context, inc *Incidencia, actor Actor, tipoEvento, origen string) (*despacho.Decision, error) {
	if inc.GrupoID == nil {
		return nil, invalido("la incidencia %s no tiene grupo", inc.Numero)
	}
	_, calBase, err := o.s.cache.Base(ctx, o.tx)
	if err != nil {
		return nil, err
	}
	dec, err := despacho.Elegir(ctx, o.tx, despacho.Entrada{
		GrupoID: *inc.GrupoID, CategoriaID: inc.CategoriaID, Prioridad: inc.Prioridad, Ahora: o.ahora,
		Zona: calBase.Zona, FueraDeHorario: !calBase.EsLaboral(o.ahora),
	})
	if err != nil {
		return nil, err
	}
	if err := o.registrarDecision(ctx, inc, calBase, dec, origen); err != nil {
		return nil, err
	}

	if dec.TecnicoID != nil {
		tid := *dec.TecnicoID
		if err := despacho.RegistrarAsignacion(ctx, o.tx, tid, o.ahora); err != nil {
			return nil, err
		}
		inc.TecnicoID = &tid
		evID, err := o.emitir(ctx, inc, actor, tipoEvento, map[string]any{
			"tecnico_id": tid, "grupo_id": inc.GrupoID, "por_guardia": dec.PorGuardia, "motivo_despacho": dec.Motivo, "origen": origen,
		})
		if err != nil {
			return nil, err
		}
		if err := o.cambiarEstado(ctx, inc, Asignada, actor, "asignacion"); err != nil {
			return nil, err
		}
		if err := o.avisarAsignacion(ctx, inc, tid, evID); err != nil {
			return nil, err
		}
		return &dec, nil
	}

	inc.TecnicoID = nil
	evID, err := o.emitir(ctx, inc, actor, EvEnCola, map[string]any{
		"grupo_id": inc.GrupoID, "motivo_despacho": dec.Motivo, "origen": origen, "avisar_responsable": dec.AvisarResponsable,
	})
	if err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, Nueva, actor, "cola_del_grupo"); err != nil {
		return nil, err
	}
	if err := o.avisarSinAsignar(ctx, inc, evID); err != nil {
		return nil, err
	}
	return &dec, nil
}

func (o *Operaciones) registrarDecision(ctx context.Context, inc *Incidencia, cal *sla.Calendario, dec despacho.Decision, origen string) error {
	entrada, _ := json.Marshal(map[string]any{
		"incidencia_id": inc.ID, "numero": inc.Numero, "grupo_id": inc.GrupoID, "categoria": inc.Categoria,
		"prioridad": inc.Prioridad, "fuera_de_horario": !cal.EsLaboral(o.ahora), "origen": origen,
	})
	salida, _ := json.Marshal(dec)
	_, err := o.tx.Exec(ctx, `INSERT INTO decisiones (caso_id, ts, componente, modo, entrada, salida)
		VALUES ($1, $2, 'despacho', 'activo', $3, $4)`, inc.CasoID, o.ahora, entrada, salida)
	if err != nil {
		return fmt.Errorf("registrar la decisión de despacho: %w", err)
	}
	return nil
}

// Crear abre una incidencia en su propia transacción. Ver Operaciones.Crear.
func (s *Servicio) Crear(ctx context.Context, e EntradaCrear) (*Resultado, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Resultado, error) { return o.Crear(ctx, e) })
}
