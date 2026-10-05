package semilla

import (
	"errors"

	"github.com/jackc/pgx/v5"
)

func errorsIs(err, target error) bool { return errors.Is(err, target) }

type pgxTx = pgx.Tx
