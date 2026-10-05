// Package migraciones embebe los .sql de backend/migrations para que el binario los lleve
// consigo. internal/store los aplica en orden y registra cada uno en schema_migrations.
package migraciones

import "embed"

// Archivos son las migraciones, nombradas NNN_descripcion.sql. Se aplican en orden de
// nombre y nunca se reescriben: un cambio de esquema es una migración nueva.
//
//go:embed *.sql
var Archivos embed.FS
