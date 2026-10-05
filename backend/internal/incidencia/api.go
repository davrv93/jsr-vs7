package incidencia

import "context"

// Este archivo expone cada acción como método de Servicio: abre UNA transacción, ejecuta la
// acción de Operaciones y confirma (o revierte si falla). Para varias acciones en una sola
// transacción, use Servicio.EnTx.

// Asignar: ver Operaciones.Asignar.
func (s *Servicio) Asignar(ctx context.Context, id int64, e EntradaAsignar) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Asignar(ctx, id, e) })
}

// Responder: ver Operaciones.Responder.
func (s *Servicio) Responder(ctx context.Context, id int64, e EntradaResponder) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Responder(ctx, id, e) })
}

// Pausar: ver Operaciones.Pausar.
func (s *Servicio) Pausar(ctx context.Context, id int64, e EntradaPausar) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Pausar(ctx, id, e) })
}

// Reanudar: ver Operaciones.Reanudar.
func (s *Servicio) Reanudar(ctx context.Context, id int64, e EntradaReanudar) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Reanudar(ctx, id, e) })
}

// Resolver: ver Operaciones.Resolver.
func (s *Servicio) Resolver(ctx context.Context, id int64, e EntradaResolver) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Resolver(ctx, id, e) })
}

// Reabrir: ver Operaciones.Reabrir.
func (s *Servicio) Reabrir(ctx context.Context, id int64, e EntradaReabrir) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Reabrir(ctx, id, e) })
}

// Cerrar: ver Operaciones.Cerrar.
func (s *Servicio) Cerrar(ctx context.Context, id int64, e EntradaCerrar) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Cerrar(ctx, id, e) })
}

// Escalar: ver Operaciones.Escalar.
func (s *Servicio) Escalar(ctx context.Context, id int64, e EntradaEscalar) (*Resultado, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Resultado, error) { return o.Escalar(ctx, id, e) })
}

// CambiarPrioridad: ver Operaciones.CambiarPrioridad.
func (s *Servicio) CambiarPrioridad(ctx context.Context, id int64, e EntradaCambiarPrioridad) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.CambiarPrioridad(ctx, id, e) })
}

// Comentar: ver Operaciones.Comentar.
func (s *Servicio) Comentar(ctx context.Context, id int64, e EntradaComentar) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.Comentar(ctx, id, e) })
}

// AgregarDato: ver Operaciones.AgregarDato.
func (s *Servicio) AgregarDato(ctx context.Context, id int64, e EntradaDato) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.AgregarDato(ctx, id, e) })
}

// RegistrarQueja: ver Operaciones.RegistrarQueja.
func (s *Servicio) RegistrarQueja(ctx context.Context, id int64, e EntradaQueja) (*Incidencia, error) {
	return conOp(ctx, s, func(o *Operaciones) (*Incidencia, error) { return o.RegistrarQueja(ctx, id, e) })
}
