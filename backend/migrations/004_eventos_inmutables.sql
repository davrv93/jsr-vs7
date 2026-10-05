-- jsrbot · los eventos de incidencia son inmutables (AGENTS §1.4 regla 9).
-- incidencia_eventos solo recibe INSERT: una corrección es un evento nuevo. Este disparador
-- convierte la regla en una garantía de la base y no solo en una costumbre del código.
-- (TRUNCATE no pasa por aquí: lo usa cmd/semilla -limpiar sobre datos sintéticos.)
-- Idempotente: esta migración se llamó 003_eventos_inmutables.sql antes de que 003 pasara a ser
-- «encuestas.puntaje admite NULL»; una base que ya la aplicó con el nombre viejo no falla.
-- Dueño: Backend-dominio.

CREATE OR REPLACE FUNCTION incidencia_eventos_inmutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'incidencia_eventos es de solo inserción: una corrección es un evento nuevo'
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

DROP TRIGGER IF EXISTS incidencia_eventos_sin_cambios ON incidencia_eventos;
CREATE TRIGGER incidencia_eventos_sin_cambios
  BEFORE UPDATE OR DELETE ON incidencia_eventos
  FOR EACH ROW EXECUTE FUNCTION incidencia_eventos_inmutable();
