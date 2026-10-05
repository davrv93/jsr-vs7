-- jsrbot · encuestas.puntaje admite NULL (docs/CONTRATOS.md «Cambios» 4).
-- NULL = encuesta enviada y todavía sin responder: la tasa de respuesta lo necesita. La pasarela
-- escribe la fila al ENVIAR la encuesta (ts = momento del envío) y la actualiza al responder; la
-- misma clave enc-<id> del outbox se reenvía a ClickHouse con el puntaje (v_encuestas junta por id).
-- 001 ya declaraba la columna sin NOT NULL; esto lo deja explícito e idempotente. El CHECK
-- (1 a 5) se mantiene: no rechaza NULL.
-- Dueño: Backend-dominio.

ALTER TABLE encuestas ALTER COLUMN puntaje DROP NOT NULL;
