package incidencia

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"jsrbot/backend/internal/sla"
	"jsrbot/backend/internal/store"
)

// preparar carga la incidencia con FOR UPDATE y valida que la acción sea posible en su
// estado. Devuelve la incidencia y el estado destino de la tabla de transiciones.
func (o *Operaciones) preparar(ctx context.Context, id int64, a Accion, actor Actor) (*Incidencia, Estado, error) {
	if err := actor.validar(); err != nil {
		return nil, "", err
	}
	inc, err := o.cargar(ctx, id, true)
	if err != nil {
		return nil, "", err
	}
	destino, err := Transicion(inc.Estado, a)
	if err != nil {
		return nil, "", err
	}
	return inc, destino, nil
}

// pausaAbierta dice si hay un pausa_inicio sin su pausa_fin.
func (o *Operaciones) pausaAbierta(ctx context.Context, id int64) (bool, error) {
	var saldo int
	err := o.tx.QueryRow(ctx, `SELECT COALESCE(sum(CASE tipo WHEN 'pausa_inicio' THEN 1 ELSE -1 END), 0)::int
		FROM incidencia_eventos WHERE incidencia_id = $1 AND tipo IN ('pausa_inicio', 'pausa_fin')`, id).Scan(&saldo)
	if err != nil {
		return false, fmt.Errorf("pausas de la incidencia %d: %w", id, err)
	}
	return saldo > 0, nil
}

// cerrarPausaSiAbierta deja el evento pausa_fin si el reloj estaba detenido.
func (o *Operaciones) cerrarPausaSiAbierta(ctx context.Context, inc *Incidencia, actor Actor, motivo string) error {
	abierta, err := o.pausaAbierta(ctx, inc.ID)
	if err != nil || !abierta {
		return err
	}
	_, err = o.emitir(ctx, inc, actor, EvPausaFin, map[string]any{"motivo": motivo})
	return err
}

// ---- asignar ------------------------------------------------------------------------------------

// EntradaAsignar asigna (o reasigna) a mano a un técnico.
type EntradaAsignar struct {
	TecnicoID int
	Motivo    string // texto corto opcional (p. ej. «balanceo de carga»)
	Actor     Actor  // normalmente el supervisor (tecnico) o el sistema
}

// Asignar pone a un técnico concreto como responsable. Evento «asignada» (primera vez) o
// «reasignada» (si ya tenía técnico); de nueva pasa a asignada y en los demás estados
// abiertos el estado no cambia. Encola el aviso «incidencia_asignada» al técnico. No exige
// turno, capacidad ni habilidad: una asignación manual es una decisión de la persona; sí
// exige que el técnico exista y no esté inactivo.
func (o *Operaciones) Asignar(ctx context.Context, id int64, e EntradaAsignar) (*Incidencia, error) {
	inc, destino, err := o.preparar(ctx, id, AccAsignar, e.Actor)
	if err != nil {
		return nil, err
	}
	var estadoTec string
	err = o.tx.QueryRow(ctx, `SELECT estado FROM tecnicos WHERE id = $1 FOR UPDATE`, e.TecnicoID).Scan(&estadoTec)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("técnico %d: %w", e.TecnicoID, ErrNoEncontrado)
	}
	if err != nil {
		return nil, fmt.Errorf("técnico %d: %w", e.TecnicoID, err)
	}
	if estadoTec == "inactivo" {
		return nil, invalido("el técnico %d está inactivo", e.TecnicoID)
	}
	if inc.TecnicoID != nil && *inc.TecnicoID == e.TecnicoID {
		return nil, invalido("la incidencia %s ya está asignada a ese técnico", inc.Numero)
	}
	tipoEv, anterior := EvAsignada, inc.TecnicoID
	if anterior != nil {
		tipoEv = EvReasignada
	}
	tid := e.TecnicoID
	inc.TecnicoID = &tid
	if err := o.registrarUltimaAsignacion(ctx, tid); err != nil {
		return nil, err
	}
	evID, err := o.emitir(ctx, inc, e.Actor, tipoEv, map[string]any{
		"tecnico_id": tid, "de_tecnico_id": anterior, "grupo_id": inc.GrupoID, "manual": true, "motivo": e.Motivo,
	})
	if err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, destino, e.Actor, "asignacion"); err != nil {
		return nil, err
	}
	if err := o.avisarAsignacion(ctx, inc, tid, evID); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

func (o *Operaciones) registrarUltimaAsignacion(ctx context.Context, tecnicoID int) error {
	_, err := o.tx.Exec(ctx, `UPDATE tecnicos SET ultima_asignacion = $2 WHERE id = $1`, tecnicoID, o.ahora)
	return err
}

// ---- responder ----------------------------------------------------------------------------------

// EntradaResponder es la respuesta de un técnico a la persona.
type EntradaResponder struct {
	Texto string
	Actor Actor // debe ser un técnico
	// EsperaUsuario: la respuesta es una pregunta; pasa a espera_usuario (pausa el SLA) de una vez.
	EsperaUsuario bool
}

// Responder registra la respuesta de un técnico. La PRIMERA deja el evento «primera_respuesta»
// (fija primera_respuesta_en, que corta el plazo de respuesta); las siguientes, un
// «comentario» público. Desde asignada o reabierta la incidencia pasa a en_curso. Con
// EsperaUsuario además pausa el reloj. Enviar el texto a la persona por su canal es trabajo
// de quien llama (la API); aquí solo queda el registro. Solo un técnico puede responder: el
// asistente no cuenta como primera respuesta humana.
func (o *Operaciones) Responder(ctx context.Context, id int64, e EntradaResponder) (*Incidencia, error) {
	if e.Actor.Tipo != "tecnico" {
		return nil, invalido("solo un técnico puede responder (actor %q)", e.Actor.Tipo)
	}
	texto, err := textoLimpio("el texto de la respuesta", e.Texto)
	if err != nil {
		return nil, err
	}
	inc, destino, err := o.preparar(ctx, id, AccResponder, e.Actor)
	if err != nil {
		return nil, err
	}
	if inc.PrimeraRespuestaEn == nil {
		inc.PrimeraRespuestaEn = ptrHora(o.ahora)
		_, err = o.emitir(ctx, inc, e.Actor, EvPrimeraRespuesta, map[string]any{"texto": texto})
	} else {
		_, err = o.emitir(ctx, inc, e.Actor, EvComentario, map[string]any{"texto": texto, "visible": "publico"})
	}
	if err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, destino, e.Actor, "respuesta"); err != nil {
		return nil, err
	}
	if e.EsperaUsuario {
		if err := o.pausar(ctx, inc, EsperaUsuario, e.Actor, ""); err != nil {
			return nil, err
		}
	}
	return inc, o.finalizar(ctx, inc)
}

// ---- pausar y reanudar -------------------------------------------------------------------------------

// EntradaPausar pone la incidencia a esperar algo.
type EntradaPausar struct {
	// Motivo: «espera_usuario» (se le pide algo a la persona) o «espera_tercero» (proveedor, compra).
	Motivo string
	Nota   string // texto libre opcional (queda en el evento; no sale a ClickHouse)
	Actor  Actor
}

// Pausar pasa de en_curso a espera_usuario o espera_tercero. Deja «estado_cambiado» y, si el
// estado detiene el reloj, «pausa_inicio». espera_usuario siempre pausa el SLA; espera_tercero
// lo pausa según configuracion.pausa_espera_tercero (por defecto sí).
func (o *Operaciones) Pausar(ctx context.Context, id int64, e EntradaPausar) (*Incidencia, error) {
	var accion Accion
	var estado Estado
	switch e.Motivo {
	case string(EsperaUsuario):
		accion, estado = AccPausarUsuario, EsperaUsuario
	case string(EsperaTercero):
		accion, estado = AccPausarTercero, EsperaTercero
	default:
		return nil, invalido("motivo de pausa %q desconocido (use espera_usuario o espera_tercero)", e.Motivo)
	}
	inc, _, err := o.preparar(ctx, id, accion, e.Actor)
	if err != nil {
		return nil, err
	}
	if err := o.pausar(ctx, inc, estado, e.Actor, e.Nota); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// pausar aplica el cambio de estado y el evento pausa_inicio según la configuración.
func (o *Operaciones) pausar(ctx context.Context, inc *Incidencia, estado Estado, actor Actor, nota string) error {
	if _, err := Transicion(inc.Estado, map[Estado]Accion{EsperaUsuario: AccPausarUsuario, EsperaTercero: AccPausarTercero}[estado]); err != nil {
		return err
	}
	if err := o.cambiarEstado(ctx, inc, estado, actor, string(estado)); err != nil {
		return err
	}
	detiene := true
	if estado == EsperaTercero {
		var err error
		if detiene, err = store.ConfigBool(ctx, o.tx, store.ConfPausaEsperaTercero, true); err != nil {
			return err
		}
	}
	if !detiene {
		return nil
	}
	datos := map[string]any{"motivo": string(estado)}
	if nota != "" {
		datos["nota"] = nota
	}
	_, err := o.emitir(ctx, inc, actor, EvPausaInicio, datos)
	return err
}

// EntradaReanudar saca a la incidencia de una espera.
type EntradaReanudar struct{ Actor Actor }

// Reanudar pasa de espera_usuario o espera_tercero a en_curso. Deja «pausa_fin» si el reloj
// estaba detenido y «estado_cambiado». Es lo que dispara la respuesta de la persona (actor
// usuario) o el regreso del tercero (actor técnico).
func (o *Operaciones) Reanudar(ctx context.Context, id int64, e EntradaReanudar) (*Incidencia, error) {
	inc, destino, err := o.preparar(ctx, id, AccReanudar, e.Actor)
	if err != nil {
		return nil, err
	}
	if err := o.cerrarPausaSiAbierta(ctx, inc, e.Actor, "reanudada"); err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, destino, e.Actor, "reanudada"); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// ---- resolver, reabrir, cerrar ----------------------------------------------------------------------------

// EntradaResolver marca la incidencia como resuelta.
type EntradaResolver struct {
	Solucion string // texto de la solución (queda en el evento; alimenta el RAG, no sale a ClickHouse)
	Actor    Actor  // el técnico
}

// Resolver pasa de en_curso a resuelta. Fija resuelta_en (corta el plazo de resolución), deja
// «resuelta» y «estado_cambiado». Desde ahí el reloj de SLA queda detenido a la espera de la
// confirmación de la persona (o de las 48 h laborales).
func (o *Operaciones) Resolver(ctx context.Context, id int64, e EntradaResolver) (*Incidencia, error) {
	inc, destino, err := o.preparar(ctx, id, AccResolver, e.Actor)
	if err != nil {
		return nil, err
	}
	inc.ResueltaEn = ptrHora(o.ahora)
	if _, err := o.emitir(ctx, inc, e.Actor, EvResuelta, map[string]any{"solucion": e.Solucion}); err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, destino, e.Actor, "resuelta"); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// EntradaReabrir es el «sigue igual» de la persona.
type EntradaReabrir struct {
	Motivo string
	Actor  Actor // normalmente la persona (usuario) o el asistente
}

// Reabrir pasa de resuelta a reabierta. Suma 1 a reaperturas, borra resuelta_en (ya no está
// resuelta), deja «reabierta» (con el número de reapertura) y «estado_cambiado». El tiempo
// que estuvo resuelta no cuenta para el SLA. A la segunda reapertura la regla reapertura_2 del
// vigía escala.
func (o *Operaciones) Reabrir(ctx context.Context, id int64, e EntradaReabrir) (*Incidencia, error) {
	inc, destino, err := o.preparar(ctx, id, AccReabrir, e.Actor)
	if err != nil {
		return nil, err
	}
	inc.Reaperturas++
	inc.ResueltaEn = nil
	if _, err := o.emitir(ctx, inc, e.Actor, EvReabierta, map[string]any{"reapertura": inc.Reaperturas, "motivo": e.Motivo}); err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, destino, e.Actor, "reabierta"); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// Motivos de cierre.
const (
	CierreConfirmado      = "confirmado"
	CierreSinConfirmacion = "sin_confirmacion"
)

// EntradaCerrar cierra una incidencia resuelta.
type EntradaCerrar struct {
	// Motivo: «confirmado» (la persona o un técnico confirma) o «sin_confirmacion» (cierre
	// automático tras 48 h laborales; solo el sistema puede usarlo y no cuenta para el FCR).
	Motivo string
	Actor  Actor
}

// Cerrar pasa de resuelta a cerrada. Fija cerrada_en y motivo_cierre; deja «cerrada» y
// «estado_cambiado». Una incidencia solo se cierra tras resolverse: el asistente no cierra
// sin confirmación (AGENTS §3.1).
func (o *Operaciones) Cerrar(ctx context.Context, id int64, e EntradaCerrar) (*Incidencia, error) {
	switch e.Motivo {
	case CierreConfirmado:
	case CierreSinConfirmacion:
		if e.Actor.Tipo != "sistema" {
			return nil, invalido("el cierre sin confirmación solo lo hace el sistema")
		}
	default:
		return nil, invalido("motivo de cierre %q desconocido (use confirmado o sin_confirmacion)", e.Motivo)
	}
	inc, destino, err := o.preparar(ctx, id, AccCerrar, e.Actor)
	if err != nil {
		return nil, err
	}
	inc.CerradaEn = ptrHora(o.ahora)
	motivo := e.Motivo
	inc.MotivoCierre = &motivo
	if _, err := o.emitir(ctx, inc, e.Actor, EvCerrada, map[string]any{"motivo": e.Motivo}); err != nil {
		return nil, err
	}
	if err := o.cambiarEstado(ctx, inc, destino, e.Actor, "cerrada"); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// ---- escalar ----------------------------------------------------------------------------------------

// EntradaEscalar pasa la incidencia a otro nivel.
type EntradaEscalar struct {
	// GrupoDestinoID: a qué grupo; nil = el escala_a_grupo_id del grupo actual.
	GrupoDestinoID *int
	// Motivo: código de la causa (sla_100_respuesta, reapertura_2, manual...).
	Motivo string
	Actor  Actor
}

// Escalar es el escalamiento FUNCIONAL: cambia el grupo al siguiente nivel (o al indicado),
// sube escalamientos, quita al técnico y vuelve a despachar en el grupo nuevo. Deja
// «escalada», si estaba en espera «pausa_fin», «asignada»/«reasignada» o «en_cola», y
// «estado_cambiado» (queda en asignada, o en nueva si el nuevo grupo no tiene quién la reciba).
// Falla con ErrSinNivelSuperior si no hay a dónde escalar.
func (o *Operaciones) Escalar(ctx context.Context, id int64, e EntradaEscalar) (*Resultado, error) {
	inc, _, err := o.preparar(ctx, id, AccEscalar, e.Actor)
	if err != nil {
		return nil, err
	}
	destino := e.GrupoDestinoID
	if destino == nil {
		if inc.GrupoID == nil {
			return nil, ErrSinNivelSuperior
		}
		err := o.tx.QueryRow(ctx, `SELECT escala_a_grupo_id FROM grupos WHERE id = $1`, *inc.GrupoID).Scan(&destino)
		if err != nil {
			return nil, fmt.Errorf("grupo %d: %w", *inc.GrupoID, err)
		}
		if destino == nil {
			return nil, fmt.Errorf("%w (%s)", ErrSinNivelSuperior, inc.Grupo)
		}
	}
	if inc.GrupoID != nil && *inc.GrupoID == *destino {
		return nil, invalido("la incidencia %s ya está en ese grupo", inc.Numero)
	}
	var nombre, nivel string
	err = o.tx.QueryRow(ctx, `SELECT nombre, nivel FROM grupos WHERE id = $1`, *destino).Scan(&nombre, &nivel)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("grupo %d: %w", *destino, ErrNoEncontrado)
	}
	if err != nil {
		return nil, err
	}

	if err := o.cerrarPausaSiAbierta(ctx, inc, e.Actor, "escalada"); err != nil {
		return nil, err
	}
	deGrupo, deTecnico, tipoAsig := inc.GrupoID, inc.TecnicoID, EvAsignada
	if deTecnico != nil {
		tipoAsig = EvReasignada
	}
	gid := *destino
	inc.GrupoID, inc.Grupo, inc.Nivel = &gid, nombre, nivel
	inc.Escalamientos++
	inc.TecnicoID = nil
	if _, err := o.emitir(ctx, inc, e.Actor, EvEscalada, map[string]any{
		"de_grupo_id": deGrupo, "a_grupo_id": gid, "de_tecnico_id": deTecnico, "nivel": nivel,
		"escalamiento": inc.Escalamientos, "motivo": e.Motivo,
	}); err != nil {
		return nil, err
	}
	dec, err := o.despachar(ctx, inc, e.Actor, tipoAsig, "escalamiento")
	if err != nil {
		return nil, err
	}
	if err := o.finalizar(ctx, inc); err != nil {
		return nil, err
	}
	return &Resultado{Incidencia: inc, Despacho: dec}, nil
}

// ---- prioridad, comentarios y datos ------------------------------------------------------------------------

// EntradaCambiarPrioridad cambia la prioridad a mano (supervisor).
type EntradaCambiarPrioridad struct {
	Prioridad string // P1..P4
	Motivo    string
	Actor     Actor
}

// CambiarPrioridad fija otra prioridad. Deja «prioridad_cambiada» (de, a, motivo) y recalcula
// los vencimientos con la política de la prioridad nueva. No re-despacha: reasignar es una
// decisión aparte.
func (o *Operaciones) CambiarPrioridad(ctx context.Context, id int64, e EntradaCambiarPrioridad) (*Incidencia, error) {
	if !sla.ValidaPrioridad(e.Prioridad) {
		return nil, invalido("prioridad %q desconocida (use P1, P2, P3 o P4)", e.Prioridad)
	}
	inc, _, err := o.preparar(ctx, id, AccCambiarPrioridad, e.Actor)
	if err != nil {
		return nil, err
	}
	if inc.Prioridad == e.Prioridad {
		return nil, invalido("la incidencia %s ya tiene prioridad %s", inc.Numero, e.Prioridad)
	}
	de := inc.Prioridad
	inc.Prioridad = e.Prioridad
	if _, err := o.emitir(ctx, inc, e.Actor, EvPrioridad, map[string]any{"de": de, "a": e.Prioridad, "motivo": e.Motivo}); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// EntradaComentar agrega una nota al hilo.
type EntradaComentar struct {
	Texto string
	// Interno: nota solo para la mesa (comentario_interno). Si es false, es visible para la persona.
	Interno bool
	Actor   Actor
}

// Comentar deja un «comentario» (público) o un «comentario_interno». No cambia el estado, no
// cuenta como primera respuesta (para eso está Responder) y se permite también en 'resuelta'.
// El texto queda en el evento pero no sale hacia ClickHouse.
func (o *Operaciones) Comentar(ctx context.Context, id int64, e EntradaComentar) (*Incidencia, error) {
	texto, err := textoLimpio("el comentario", e.Texto)
	if err != nil {
		return nil, err
	}
	inc, _, err := o.preparar(ctx, id, AccComentar, e.Actor)
	if err != nil {
		return nil, err
	}
	tipo, visible := EvComentario, "publico"
	if e.Interno {
		tipo, visible = EvComentarioInt, "interno"
	}
	if _, err := o.emitir(ctx, inc, e.Actor, tipo, map[string]any{"texto": texto, "visible": visible}); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// EntradaDato agrega un dato a una incidencia abierta (la persona aporta información).
type EntradaDato struct {
	Clave string // equipo, sede, mensaje_error, desde...
	Valor string
	Actor Actor
}

// AgregarDato deja un «dato_agregado» {clave, valor}: es lo que hace el asistente cuando la
// persona aporta información sobre una incidencia que ya existe, en vez de abrir otra. No
// cambia el estado. El valor queda en el evento pero no sale hacia ClickHouse.
func (o *Operaciones) AgregarDato(ctx context.Context, id int64, e EntradaDato) (*Incidencia, error) {
	clave, err := textoLimpio("la clave del dato", e.Clave)
	if err != nil {
		return nil, err
	}
	inc, _, err := o.preparar(ctx, id, AccAgregarDato, e.Actor)
	if err != nil {
		return nil, err
	}
	if _, err := o.emitir(ctx, inc, e.Actor, EvDatoAgregado, map[string]any{"clave": clave, "valor": e.Valor}); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// EntradaQueja registra una queja explícita o un ánimo muy negativo durante la atención.
type EntradaQueja struct {
	Texto string
	Actor Actor
}

// RegistrarQueja deja el evento «queja», que la regla «queja» del vigía convierte en un aviso
// al supervisor. Se permite en incidencias abiertas.
func (o *Operaciones) RegistrarQueja(ctx context.Context, id int64, e EntradaQueja) (*Incidencia, error) {
	inc, _, err := o.preparar(ctx, id, AccAgregarDato, e.Actor)
	if err != nil {
		return nil, err
	}
	datos := map[string]any{"origen": "atencion"}
	if e.Texto != "" {
		datos["texto"] = e.Texto
	}
	if _, err := o.emitir(ctx, inc, e.Actor, EvQueja, datos); err != nil {
		return nil, err
	}
	return inc, o.finalizar(ctx, inc)
}

// ---- cola del grupo ---------------------------------------------------------------------------------------

// AsignarDesdeCola intenta despachar una incidencia que quedó en la cola (estado nueva, sin
// técnico). Devuelve la decisión; si sigue sin candidato no escribe nada (ni eventos ni
// avisos). Si hay técnico: evento «asignada», estado «asignada» y aviso al técnico.
func (o *Operaciones) AsignarDesdeCola(ctx context.Context, id int64) (*Resultado, error) {
	inc, err := o.cargar(ctx, id, true)
	if err != nil {
		return nil, err
	}
	if inc.Estado != Nueva || inc.TecnicoID != nil {
		return nil, &ErrTransicion{Estado: inc.Estado, Accion: AccAsignar}
	}
	// Se evalúa primero sin escribir: si no hay candidato, no se deja rastro.
	_, calBase, err := o.s.cache.Base(ctx, o.tx)
	if err != nil {
		return nil, err
	}
	if inc.GrupoID == nil {
		return nil, invalido("la incidencia %s no tiene grupo", inc.Numero)
	}
	dec, err := o.elegirSinEscribir(ctx, inc, calBase)
	if err != nil {
		return nil, err
	}
	if dec.TecnicoID == nil {
		return &Resultado{Incidencia: inc, Despacho: &dec}, nil
	}
	d, err := o.despachar(ctx, inc, ActorSistema(), EvAsignada, "cola")
	if err != nil {
		return nil, err
	}
	if err := o.finalizar(ctx, inc); err != nil {
		return nil, err
	}
	return &Resultado{Incidencia: inc, Despacho: d}, nil
}
