package despacho

import "github.com/jackc/pgx/v5"

// pgxTx abrevia el tipo de la transacción en las pruebas.
type pgxTx = pgx.Tx
