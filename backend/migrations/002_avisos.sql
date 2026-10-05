-- jsrbot · avisos pendientes (cola de salida hacia WhatsApp y correo).
-- El gestor de incidencias y el vigía NO envían nada: dejan aquí una fila y un evento; el
-- servicio de avisos (agente de API/webhook) las envía y marca enviado_en o error.
-- Dueño: Backend-dominio. Se añadió sobre 001 sin tocarla (ver docs/CONTRATOS.md «Cambios»).

CREATE TABLE avisos (
  id bigserial PRIMARY KEY,
  incidencia_id bigint REFERENCES incidencias(id),
  -- A quién va. 'persona' apunta a personas.id; los demás tipos apuntan a tecnicos.id
  -- (resuelto al encolar: la guardia vigente, el responsable del grupo, el supervisor).
  -- destinatario_id NULL = no se pudo resolver (nadie de guardia, sin supervisor configurado).
  destinatario_tipo text NOT NULL CHECK (destinatario_tipo IN
    ('tecnico','persona','guardia','supervisor','responsable_grupo')),
  destinatario_id int,
  canal text NOT NULL DEFAULT 'whatsapp' CHECK (canal IN ('whatsapp','correo','consola')),
  plantilla text NOT NULL,          -- incidencia_asignada, incidencia_sin_asignar, sla_75, sla_100, p1_creada, ...
  datos jsonb NOT NULL DEFAULT '{}', -- valores para la plantilla (numero, prioridad, titulo, porcentaje...). Nunca notas internas.
  -- Clave de idempotencia: el mismo aviso se encola una sola vez aunque el vigía reinicie o
  -- corra dos veces (INSERT ... ON CONFLICT (clave) DO NOTHING).
  clave text NOT NULL UNIQUE,
  creado_en timestamptz NOT NULL DEFAULT now(),
  enviado_en timestamptz,
  error text,
  intentos int NOT NULL DEFAULT 0
);
CREATE INDEX avisos_pendientes_idx ON avisos (id) WHERE enviado_en IS NULL;
CREATE INDEX avisos_incidencia_idx ON avisos (incidencia_id);
