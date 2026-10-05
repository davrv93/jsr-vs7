package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Tipos de destinatario de un aviso (columna avisos.destinatario_tipo).
const (
	DestTecnico          = "tecnico"
	DestPersona          = "persona"
	DestGuardia          = "guardia"
	DestSupervisor       = "supervisor"
	DestResponsableGrupo = "responsable_grupo"
)

// NuevoAviso es un aviso por enviar. Los avisos NO se envían desde el dominio: se encolan
// aquí y el servicio de avisos los entrega por WhatsApp o correo.
type NuevoAviso struct {
	IncidenciaID     *int64
	DestinatarioTipo string
	DestinatarioID   *int // personas.id si tipo = persona; tecnicos.id en los demás casos
	Canal            string
	Plantilla        string
	Datos            map[string]any // valores de la plantilla; nunca notas internas
	// Clave de idempotencia: el mismo aviso se encola una sola vez.
	Clave string
}

// Aviso es una fila de la tabla avisos.
type Aviso struct {
	ID               int64
	IncidenciaID     *int64
	DestinatarioTipo string
	DestinatarioID   *int
	Canal            string
	Plantilla        string
	Datos            map[string]any
	Clave            string
	CreadoEn         time.Time
	EnviadoEn        *time.Time
	Error            *string
	Intentos         int
}

// EncolarAviso inserta un aviso. Si la clave ya existe no hace nada y devuelve nuevo=false:
// así un aviso se encola una sola vez aunque el vigía se reinicie o corra dos veces.
func EncolarAviso(ctx context.Context, q Q, a NuevoAviso, ahora time.Time) (id int64, nuevo bool, err error) {
	if a.Clave == "" {
		return 0, false, errors.New("store: un aviso necesita clave de idempotencia")
	}
	if a.Canal == "" {
		a.Canal = "whatsapp"
	}
	datos := a.Datos
	if datos == nil {
		datos = map[string]any{}
	}
	raw, err := json.Marshal(datos)
	if err != nil {
		return 0, false, fmt.Errorf("store: datos del aviso: %w", err)
	}
	err = q.QueryRow(ctx, `INSERT INTO avisos (incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, clave, creado_en)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (clave) DO NOTHING RETURNING id`,
		a.IncidenciaID, a.DestinatarioTipo, a.DestinatarioID, a.Canal, a.Plantilla, raw, a.Clave, ahora).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, fmt.Errorf("store: encolar aviso %q: %w", a.Clave, err)
	}
	return id, true, nil
}

// AvisosPendientes devuelve hasta `limite` avisos sin enviar, del más antiguo al más nuevo.
// Con FOR UPDATE SKIP LOCKED, dos servicios de envío no toman el mismo aviso (llamar dentro
// de una transacción).
func AvisosPendientes(ctx context.Context, q Q, limite int) ([]Aviso, error) {
	rows, err := q.Query(ctx, `SELECT id, incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos,
		clave, creado_en, enviado_en, error, intentos
		FROM avisos WHERE enviado_en IS NULL ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED`, limite)
	if err != nil {
		return nil, fmt.Errorf("store: avisos pendientes: %w", err)
	}
	defer rows.Close()
	var out []Aviso
	for rows.Next() {
		var a Aviso
		var datos []byte
		if err := rows.Scan(&a.ID, &a.IncidenciaID, &a.DestinatarioTipo, &a.DestinatarioID, &a.Canal, &a.Plantilla,
			&datos, &a.Clave, &a.CreadoEn, &a.EnviadoEn, &a.Error, &a.Intentos); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(datos, &a.Datos)
		a.CreadoEn = a.CreadoEn.UTC()
		out = append(out, a)
	}
	return out, rows.Err()
}

// MarcarAvisoEnviado registra la entrega de un aviso.
func MarcarAvisoEnviado(ctx context.Context, q Q, id int64, ahora time.Time) error {
	tag, err := q.Exec(ctx, `UPDATE avisos SET enviado_en = $2, error = NULL, intentos = intentos + 1 WHERE id = $1`, id, ahora)
	if err == nil && tag.RowsAffected() == 0 {
		return fmt.Errorf("store: aviso %d: %w", id, ErrNoEncontrado)
	}
	return err
}

// MarcarAvisoError registra un intento fallido (el aviso sigue pendiente).
func MarcarAvisoError(ctx context.Context, q Q, id int64, msg string) error {
	tag, err := q.Exec(ctx, `UPDATE avisos SET error = $2, intentos = intentos + 1 WHERE id = $1`, id, msg)
	if err == nil && tag.RowsAffected() == 0 {
		return fmt.Errorf("store: aviso %d: %w", id, ErrNoEncontrado)
	}
	return err
}

// CanalTecnico elige el canal de aviso de un técnico: WhatsApp si tiene número; si no,
// correo; si no tiene nada, WhatsApp (el servicio de avisos registrará el error de entrega).
func CanalTecnico(ctx context.Context, q Q, tecnicoID int) string {
	var wa, correo string
	err := q.QueryRow(ctx, `SELECT COALESCE(whatsapp, ''), COALESCE(correo, '') FROM tecnicos WHERE id = $1`, tecnicoID).Scan(&wa, &correo)
	if err != nil || wa != "" || correo == "" {
		return "whatsapp"
	}
	return "correo"
}
