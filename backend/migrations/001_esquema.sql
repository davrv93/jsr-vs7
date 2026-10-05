-- jsrbot · esquema de Postgres (fuente de verdad). UTC en todas las marcas de tiempo.
-- Dueño: Arquitecto. Un cambio de contrato se propone en docs/decisiones/.
-- Los eventos (incidencia_eventos, mensajes, decisiones) solo reciben inserciones.

CREATE TABLE IF NOT EXISTS configuracion (
  clave text PRIMARY KEY,
  valor jsonb NOT NULL,
  actualizado_en timestamptz NOT NULL DEFAULT now()
);

-- Organización ---------------------------------------------------------------
CREATE TABLE sedes (
  id serial PRIMARY KEY,
  nombre text NOT NULL UNIQUE
);
CREATE TABLE areas (
  id serial PRIMARY KEY,
  nombre text NOT NULL UNIQUE
);
CREATE TABLE personas (
  id serial PRIMARY KEY,
  nombre text NOT NULL,
  whatsapp text UNIQUE,             -- solo dígitos con prefijo de país, p. ej. 51987654321
  correo text,
  sede_id int REFERENCES sedes(id),
  area_id int REFERENCES areas(id),
  vip boolean NOT NULL DEFAULT false,
  canal_preferido text NOT NULL DEFAULT 'whatsapp',
  creada_en timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE activos (
  id serial PRIMARY KEY,
  codigo text NOT NULL UNIQUE,      -- PC-CONT-07
  tipo text NOT NULL,
  persona_id int REFERENCES personas(id),
  sede_id int REFERENCES sedes(id)
);

-- Personal técnico -----------------------------------------------------------
CREATE TABLE categorias (
  id serial PRIMARY KEY,
  clave text NOT NULL UNIQUE,       -- correo, cuentas_accesos, red_wifi, vpn, impresoras, equipo, software_oficina, sistema_interno, telefonia, otro
  nombre text NOT NULL,
  grupo_id int,                     -- grupo que atiende la categoría (FK abajo)
  activa boolean NOT NULL DEFAULT true
);
CREATE TABLE grupos (
  id serial PRIMARY KEY,
  nombre text NOT NULL UNIQUE,
  nivel text NOT NULL DEFAULT 'N1' CHECK (nivel IN ('N1','N2','N3')),
  escala_a_grupo_id int REFERENCES grupos(id),   -- siguiente nivel funcional
  responsable_tecnico_id int                     -- FK abajo
);
CREATE TABLE tecnicos (
  id serial PRIMARY KEY,
  nombre text NOT NULL,
  whatsapp text,
  correo text,
  nivel text NOT NULL DEFAULT 'N1' CHECK (nivel IN ('N1','N2','N3')),
  estado text NOT NULL DEFAULT 'activo' CHECK (estado IN ('activo','ausente','inactivo')),
  capacidad int NOT NULL DEFAULT 8,
  ultima_asignacion timestamptz,
  creado_en timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE categorias ADD FOREIGN KEY (grupo_id) REFERENCES grupos(id);
ALTER TABLE grupos ADD FOREIGN KEY (responsable_tecnico_id) REFERENCES tecnicos(id);
CREATE TABLE grupo_miembros (
  grupo_id int NOT NULL REFERENCES grupos(id) ON DELETE CASCADE,
  tecnico_id int NOT NULL REFERENCES tecnicos(id) ON DELETE CASCADE,
  PRIMARY KEY (grupo_id, tecnico_id)
);
CREATE TABLE habilidades (
  tecnico_id int NOT NULL REFERENCES tecnicos(id) ON DELETE CASCADE,
  categoria_id int NOT NULL REFERENCES categorias(id) ON DELETE CASCADE,
  nivel int NOT NULL DEFAULT 2 CHECK (nivel BETWEEN 1 AND 3),
  PRIMARY KEY (tecnico_id, categoria_id)
);
CREATE TABLE turnos (               -- horario de trabajo del técnico, en hora local del calendario
  id serial PRIMARY KEY,
  tecnico_id int NOT NULL REFERENCES tecnicos(id) ON DELETE CASCADE,
  dia_semana int NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),  -- 1 = lunes … 7 = domingo
  desde time NOT NULL,
  hasta time NOT NULL
);
CREATE TABLE ausencias (
  id serial PRIMARY KEY,
  tecnico_id int NOT NULL REFERENCES tecnicos(id) ON DELETE CASCADE,
  desde timestamptz NOT NULL,
  hasta timestamptz NOT NULL,
  motivo text
);
CREATE TABLE guardias (             -- quién responde a P1 fuera de horario
  id serial PRIMARY KEY,
  tecnico_id int NOT NULL REFERENCES tecnicos(id) ON DELETE CASCADE,
  desde timestamptz NOT NULL,
  hasta timestamptz NOT NULL
);

-- SLA y prioridad --------------------------------------------------------------
CREATE TABLE calendarios (
  id serial PRIMARY KEY,
  nombre text NOT NULL UNIQUE,
  zona text NOT NULL DEFAULT 'America/Lima',
  veinticuatro_siete boolean NOT NULL DEFAULT false,
  -- horario laboral: {"1":[["08:30","13:00"],["14:00","18:00"]],"2":[...],...,"7":[]}
  horario jsonb NOT NULL DEFAULT '{}'
);
CREATE TABLE feriados (
  calendario_id int NOT NULL REFERENCES calendarios(id) ON DELETE CASCADE,
  fecha date NOT NULL,
  nombre text NOT NULL,
  PRIMARY KEY (calendario_id, fecha)
);
CREATE TABLE matriz_prioridad (
  impacto text NOT NULL CHECK (impacto IN ('persona','area','sede','organizacion')),
  urgencia text NOT NULL CHECK (urgencia IN ('baja','media','alta','critica')),
  prioridad text NOT NULL CHECK (prioridad IN ('P1','P2','P3','P4')),
  PRIMARY KEY (impacto, urgencia)
);
CREATE TABLE sla_politicas (
  id serial PRIMARY KEY,
  prioridad text NOT NULL CHECK (prioridad IN ('P1','P2','P3','P4')),
  categoria_id int REFERENCES categorias(id),   -- NULL = vale para todas
  calendario_id int NOT NULL REFERENCES calendarios(id),
  respuesta_min int NOT NULL,                    -- minutos laborales hasta la primera respuesta humana
  resolucion_min int NOT NULL,                   -- minutos laborales hasta la resolución
  UNIQUE (prioridad, categoria_id)
);

-- Incidencias -------------------------------------------------------------------
CREATE SEQUENCE incidencia_numero_seq START 1;
CREATE TABLE incidencias (
  id bigserial PRIMARY KEY,
  numero text NOT NULL UNIQUE DEFAULT ('INC-' || lpad(nextval('incidencia_numero_seq')::text, 6, '0')),
  persona_id int REFERENCES personas(id),
  caso_id bigint,                                -- FK abajo
  tipo text NOT NULL DEFAULT 'incidente' CHECK (tipo IN ('incidente','solicitud','consulta','problema')),
  categoria_id int REFERENCES categorias(id),
  impacto text NOT NULL DEFAULT 'persona' CHECK (impacto IN ('persona','area','sede','organizacion')),
  urgencia text NOT NULL DEFAULT 'media' CHECK (urgencia IN ('baja','media','alta','critica')),
  prioridad text NOT NULL DEFAULT 'P3' CHECK (prioridad IN ('P1','P2','P3','P4')),
  estado text NOT NULL DEFAULT 'nueva' CHECK (estado IN
    ('nueva','asignada','en_curso','espera_usuario','espera_tercero','resuelta','cerrada','reabierta')),
  titulo text NOT NULL,
  resumen text NOT NULL DEFAULT '',
  grupo_id int REFERENCES grupos(id),
  tecnico_id int REFERENCES tecnicos(id),
  nivel text NOT NULL DEFAULT 'N1',
  reaperturas int NOT NULL DEFAULT 0,
  escalamientos int NOT NULL DEFAULT 0,
  canal text NOT NULL DEFAULT 'whatsapp',
  token_publico text NOT NULL UNIQUE DEFAULT md5(random()::text || clock_timestamp()::text),
  -- Proyecciones calculadas desde los eventos por el backend (el estado verdadero son los eventos):
  creada_en timestamptz NOT NULL DEFAULT now(),
  primera_respuesta_en timestamptz,
  resuelta_en timestamptz,
  cerrada_en timestamptz,
  vence_respuesta_en timestamptz,
  vence_resolucion_en timestamptz,
  motivo_cierre text,
  actualizada_en timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX incidencias_estado_idx ON incidencias (estado, prioridad);
CREATE INDEX incidencias_tecnico_idx ON incidencias (tecnico_id) WHERE estado NOT IN ('cerrada');
CREATE INDEX incidencias_persona_idx ON incidencias (persona_id);

-- Solo inserción. tipo: creada, asignada, reasignada, primera_respuesta, estado_cambiado, pausa_inicio, pausa_fin,
-- comentario, comentario_interno, escalada, aviso_sla, prioridad_cambiada, resuelta, reabierta, cerrada, dato_agregado
CREATE TABLE incidencia_eventos (
  id bigserial PRIMARY KEY,
  incidencia_id bigint NOT NULL REFERENCES incidencias(id),
  ts timestamptz NOT NULL DEFAULT now(),
  tipo text NOT NULL,
  actor_tipo text NOT NULL CHECK (actor_tipo IN ('usuario','tecnico','asistente','sistema')),
  actor_id text,
  datos jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX incidencia_eventos_inc_idx ON incidencia_eventos (incidencia_id, ts);

CREATE TABLE escalamiento_reglas (
  id serial PRIMARY KEY,
  clave text NOT NULL,              -- sla_75, sla_100, p1_creada, reapertura_2, queja, vip, guia_agotada
  version int NOT NULL DEFAULT 1,
  activa boolean NOT NULL DEFAULT true,
  modo text NOT NULL DEFAULT 'sombra' CHECK (modo IN ('sombra','activo')),
  condicion jsonb NOT NULL DEFAULT '{}',
  acciones jsonb NOT NULL DEFAULT '[]',   -- [{"tipo":"avisar_tecnico"},{"tipo":"escalar_nivel"},{"tipo":"avisar_responsable"}...]
  creada_en timestamptz NOT NULL DEFAULT now(),
  UNIQUE (clave, version)
);
CREATE TABLE escalamientos (        -- lo que una regla hizo (o habría hecho en sombra)
  id bigserial PRIMARY KEY,
  incidencia_id bigint NOT NULL REFERENCES incidencias(id),
  regla_clave text NOT NULL,
  regla_version int NOT NULL,
  modo text NOT NULL,
  accion jsonb NOT NULL,
  ts timestamptz NOT NULL DEFAULT now(),
  UNIQUE (incidencia_id, regla_clave, regla_version)    -- idempotencia: una regla dispara una vez por incidencia
);

-- Conversación ------------------------------------------------------------------
CREATE TABLE casos (
  id bigserial PRIMARY KEY,
  persona_id int REFERENCES personas(id),
  canal text NOT NULL CHECK (canal IN ('whatsapp','web')),
  chat_id text NOT NULL,            -- número de WhatsApp o id de sesión web
  etapa text NOT NULL DEFAULT 'recepcion',
  memoria jsonb NOT NULL DEFAULT '{}',
  estado text NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','resuelto_asistente','con_incidencia','cerrado')),
  pausado_por_tecnico boolean NOT NULL DEFAULT false,
  inicio timestamptz NOT NULL DEFAULT now(),
  ultimo_mensaje timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX casos_chat_idx ON casos (canal, chat_id, ultimo_mensaje DESC);
ALTER TABLE incidencias ADD FOREIGN KEY (caso_id) REFERENCES casos(id);
CREATE TABLE mensajes (
  id bigserial PRIMARY KEY,
  caso_id bigint NOT NULL REFERENCES casos(id),
  ts timestamptz NOT NULL DEFAULT now(),
  rol text NOT NULL CHECK (rol IN ('usuario','asistente','tecnico','sistema')),
  texto text NOT NULL,
  meta jsonb NOT NULL DEFAULT '{}'  -- intencion, confianza, categoria, juez, articulos, latencia_ms…
);
CREATE INDEX mensajes_caso_idx ON mensajes (caso_id, ts);
CREATE TABLE decisiones (
  id bigserial PRIMARY KEY,
  caso_id bigint REFERENCES casos(id),
  ts timestamptz NOT NULL DEFAULT now(),
  componente text NOT NULL,         -- clasificador, etapas, juez, escalamiento, despacho…
  modo text NOT NULL DEFAULT 'activo',
  entrada jsonb NOT NULL DEFAULT '{}',
  salida jsonb NOT NULL DEFAULT '{}'
);

-- Conocimiento --------------------------------------------------------------------
CREATE TABLE articulos (
  id serial PRIMARY KEY,
  clave text NOT NULL UNIQUE,       -- KB-001
  titulo text NOT NULL,
  categoria_id int REFERENCES categorias(id),
  sintomas text[] NOT NULL DEFAULT '{}',
  pasos text[] NOT NULL DEFAULT '{}',
  cuerpo text NOT NULL DEFAULT '',
  estado text NOT NULL DEFAULT 'publicado' CHECK (estado IN ('borrador','publicado','archivado')),
  supuesto boolean NOT NULL DEFAULT true,   -- SUPUESTO: hasta que la organización lo revise
  version int NOT NULL DEFAULT 1,
  actualizado_en timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE articulo_usos (
  id bigserial PRIMARY KEY,
  articulo_id int NOT NULL REFERENCES articulos(id),
  caso_id bigint REFERENCES casos(id),
  categoria_id int REFERENCES categorias(id),
  resultado text CHECK (resultado IN ('resolvio','sigue_igual','sin_respuesta')),
  ts timestamptz NOT NULL DEFAULT now()
);

-- Calidad --------------------------------------------------------------------------
CREATE TABLE feedback (
  id bigserial PRIMARY KEY,
  caso_id bigint REFERENCES casos(id),
  mensaje_id bigint REFERENCES mensajes(id),
  incidencia_id bigint REFERENCES incidencias(id),
  senal text NOT NULL,              -- pulgar_arriba, pulgar_abajo, se_resolvio, sigue_igual, correccion_intencion, correccion_categoria, reapertura
  valor text,
  ts timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE encuestas (
  id bigserial PRIMARY KEY,
  incidencia_id bigint REFERENCES incidencias(id),
  caso_id bigint REFERENCES casos(id),
  puntaje int CHECK (puntaje BETWEEN 1 AND 5),
  comentario text,
  ts timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE pares_preferencia (
  id bigserial PRIMARY KEY,
  incidencia_id bigint REFERENCES incidencias(id),
  propuesta text NOT NULL,
  editada text NOT NULL,
  ts timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE etiquetas_revision (
  id bigserial PRIMARY KEY,
  mensaje_id bigint REFERENCES mensajes(id),
  texto text NOT NULL,
  intencion_modelo text,
  confianza real,
  intencion_correcta text,
  categoria_correcta text,
  estado text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','confirmada','corregida','descartada')),
  revisada_por text,
  ts timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE modelos (
  id serial PRIMARY KEY,
  version text NOT NULL UNIQUE,
  exactitud real,
  macro_f1 real,
  estado text NOT NULL DEFAULT 'candidato' CHECK (estado IN ('candidato','publicado','retirado')),
  detalle jsonb NOT NULL DEFAULT '{}',
  creado_en timestamptz NOT NULL DEFAULT now()
);

-- Plataforma -----------------------------------------------------------------------
CREATE TABLE usuarios_consola (
  id serial PRIMARY KEY,
  email text NOT NULL UNIQUE,
  nombre text NOT NULL,
  rol text NOT NULL CHECK (rol IN ('tecnico','supervisor','gerencia','entrenador','admin')),
  tecnico_id int REFERENCES tecnicos(id),
  clave_hash text NOT NULL,
  activo boolean NOT NULL DEFAULT true,
  creado_en timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE auditoria (
  id bigserial PRIMARY KEY,
  ts timestamptz NOT NULL DEFAULT now(),
  usuario_id int REFERENCES usuarios_consola(id),
  accion text NOT NULL,
  objeto text,
  detalle jsonb NOT NULL DEFAULT '{}'
);
-- Cada cambio relevante inserta aquí en la misma transacción. Un trabajador la vacía hacia ClickHouse por lotes.
CREATE TABLE outbox_analitica (
  id bigserial PRIMARY KEY,
  ts timestamptz NOT NULL DEFAULT now(),
  tabla text NOT NULL,              -- eventos_incidencia, incidencias_estado, mensajes, incidencias_tiempos, encuestas, feedback
  clave text NOT NULL,              -- id estable del evento para deduplicar
  payload jsonb NOT NULL,
  enviado_en timestamptz
);
CREATE INDEX outbox_pendiente_idx ON outbox_analitica (id) WHERE enviado_en IS NULL;
