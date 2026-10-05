(* Encolado analitico (CONTRATOS §4): cada INSERT de la pasarela en mensajes, casos, encuestas o feedback deja una fila
   en `outbox_analitica` EN LA MISMA TRANSACCION. Las claves del payload son exactamente las columnas de la tabla
   destino de ClickHouse; las marcas de tiempo, ISO UTC. El motor es el unico que vacia el outbox hacia ClickHouse.
   El SQL lee la fila ya insertada, asi el payload nunca se desvia de lo que quedo guardado. *)

let iso = Db.iso

let encolar_mensaje ~(con_texto : bool) (c : Db.conn) ~(id : int) : unit Lwt.t =
  Db.exec c
    ("INSERT INTO outbox_analitica (tabla, clave, payload) "
   ^ "SELECT 'mensajes', 'msg-' || m.id, jsonb_build_object("
   ^ "'id', m.id, 'caso_id', m.caso_id, 'ts', " ^ iso "m.ts" ^ ", 'rol', m.rol, 'canal', ca.canal, "
   ^ "'intencion', m.meta->>'intencion', 'confianza', (m.meta->>'confianza')::float8, 'categoria', m.meta->>'categoria', "
   ^ "'juez_modo', coalesce(m.meta->>'juez_modo', 'apagado'), 'juez_veredicto', coalesce(m.meta->>'juez_veredicto', ''), "
   ^ "'latencia_ms', round((m.meta->>'latencia_ms')::float8)::bigint, "
   ^ "'regenerada', CASE WHEN (m.meta->>'regenerada') = 'true' THEN 1 ELSE 0 END, "
   ^ "'frases_quitadas', coalesce((m.meta->>'frases_quitadas')::int, 0), "
   ^ "'costo_usd', coalesce((m.meta->>'costo_usd')::float8, 0), "
   ^ "'texto', CASE WHEN $b:con_texto THEN m.texto ELSE '' END) "
   ^ "FROM mensajes m JOIN casos ca ON ca.id = m.caso_id WHERE m.id = $i:id")
    (`Assoc [ ("id", `Int id); ("con_texto", `Bool con_texto) ])

(* `version` = lo ultimo que movio al caso: GREATEST(su ultimo mensaje, el ultimo cambio de una incidencia suya), igual que
   `Reconstruir` del motor. Quien cambie el estado de un caso sin mensaje nuevo actualiza `ultimo_mensaje` (Casos.guardar). *)
let encolar_caso (c : Db.conn) ~(id : int) : unit Lwt.t =
  Db.exec c
    ("INSERT INTO outbox_analitica (tabla, clave, payload) "
   ^ "SELECT 'casos_estado', 'caso-' || ca.id || '-' || v.version, jsonb_build_object("
   ^ "'caso_id', ca.id, 'version', v.version, 'canal', ca.canal, 'persona_id', ca.persona_id, 'estado', ca.estado, "
   ^ "'inicio', " ^ iso "ca.inicio" ^ ", 'ultimo_mensaje', " ^ iso "ca.ultimo_mensaje" ^ ", "
   ^ "'tiene_incidencia', CASE WHEN EXISTS (SELECT 1 FROM incidencias i WHERE i.caso_id = ca.id) THEN 1 ELSE 0 END, "
   ^ "'confirmado_resuelto', CASE WHEN EXISTS (SELECT 1 FROM feedback f WHERE f.caso_id = ca.id AND f.senal = 'se_resolvio') THEN 1 ELSE 0 END) "
   ^ "FROM casos ca, LATERAL (SELECT (extract(epoch from GREATEST(ca.ultimo_mensaje, coalesce((SELECT max(i.actualizada_en) FROM incidencias i WHERE i.caso_id = ca.id), ca.ultimo_mensaje))) * 1000)::bigint AS version) v WHERE ca.id = $i:id")
    (`Assoc [ ("id", `Int id) ])

let encolar_encuesta (c : Db.conn) ~(id : int) : unit Lwt.t =
  Db.exec c
    ("INSERT INTO outbox_analitica (tabla, clave, payload) "
   ^ "SELECT 'encuestas', 'enc-' || e.id, jsonb_build_object('id', e.id, 'incidencia_id', e.incidencia_id, 'caso_id', e.caso_id, "
   ^ "'ts', " ^ iso "e.ts" ^ ", 'puntaje', e.puntaje) FROM encuestas e WHERE e.id = $i:id")
    (`Assoc [ ("id", `Int id) ])

let encolar_feedback (c : Db.conn) ~(id : int) : unit Lwt.t =
  Db.exec c
    ("INSERT INTO outbox_analitica (tabla, clave, payload) "
   ^ "SELECT 'feedback', 'fb-' || f.id, jsonb_build_object('id', f.id, 'caso_id', f.caso_id, 'mensaje_id', f.mensaje_id, 'incidencia_id', f.incidencia_id, "
   ^ "'ts', " ^ iso "f.ts" ^ ", 'senal', f.senal, 'valor', f.valor) FROM feedback f WHERE f.id = $i:id")
    (`Assoc [ ("id", `Int id) ])

(* Inserta un feedback y lo encola. `senal`: pulgar_arriba, pulgar_abajo, se_resolvio, sigue_igual, correccion_intencion,
   correccion_categoria, reapertura. *)
let registrar_feedback (c : Db.conn) ?caso_id ?mensaje_id ?incidencia_id ?valor ~(senal : string) () : unit Lwt.t =
  let ( let* ) = Lwt.bind in
  let* id =
    Db.insertar c
      "INSERT INTO feedback (caso_id, mensaje_id, incidencia_id, senal, valor) VALUES ($i:caso_id, $i:mensaje_id, $i:incidencia_id, $senal, $valor)"
      (`Assoc
        [ ("caso_id", Json.opt_int caso_id); ("mensaje_id", Json.opt_int mensaje_id); ("incidencia_id", Json.opt_int incidencia_id);
          ("senal", `String senal); ("valor", Json.opt_string valor) ])
  in
  encolar_feedback c ~id

(* Encuesta (CONTRATOS «Cambios» 4): al ENVIARLA se inserta la fila con puntaje NULL y se encola `enc-<id>` con puntaje null
   (ts = momento del envio); al recibir la respuesta se ACTUALIZA el puntaje y se reencola la misma `enc-<id>`. NULL =
   enviada y sin responder (tasa de respuesta). Una sola pendiente por caso. *)
let abrir_encuesta (c : Db.conn) ~(caso_id : int) : int option Lwt.t =
  let ( let* ) = Lwt.bind in
  let* pendiente = Db.escalar_int c "SELECT id FROM encuestas WHERE caso_id = $i:caso AND puntaje IS NULL ORDER BY id DESC LIMIT 1" (`Assoc [ ("caso", `Int caso_id) ]) in
  match pendiente with
  | Some _ -> Lwt.return None
  | None ->
      let* id =
        Db.insertar c
          "INSERT INTO encuestas (incidencia_id, caso_id) SELECT (SELECT i.id FROM incidencias i WHERE i.caso_id = $i:caso ORDER BY i.id DESC LIMIT 1), $i:caso"
          (`Assoc [ ("caso", `Int caso_id) ])
      in
      let* () = encolar_encuesta c ~id in
      Lwt.return (Some id)

(* Registra la respuesta: actualiza la encuesta pendiente del caso o, si no habia (la persona responde en otra sesion), inserta
   una con el puntaje. Devuelve el id de la encuesta. *)
let responder_encuesta (c : Db.conn) ?incidencia_id ~(caso_id : int) ?comentario ~(puntaje : int) () : int Lwt.t =
  let ( let* ) = Lwt.bind in
  let* actualizada =
    Db.devolver c
      "UPDATE encuestas SET puntaje = $i:puntaje, comentario = $comentario, incidencia_id = coalesce(incidencia_id, $i:inc) WHERE id = (SELECT id FROM encuestas WHERE caso_id = $i:caso AND puntaje IS NULL ORDER BY id DESC LIMIT 1) RETURNING id"
      (`Assoc [ ("puntaje", `Int puntaje); ("comentario", Json.opt_string comentario); ("inc", Json.opt_int incidencia_id); ("caso", `Int caso_id) ])
  in
  match Json.int "id" actualizada with
  | Some id ->
      let* () = encolar_encuesta c ~id in
      Lwt.return id
  | None ->
      let* id =
        Db.insertar c "INSERT INTO encuestas (incidencia_id, caso_id, puntaje, comentario) VALUES ($i:inc, $i:caso, $i:puntaje, $comentario)"
          (`Assoc [ ("inc", Json.opt_int incidencia_id); ("caso", `Int caso_id); ("puntaje", `Int puntaje); ("comentario", Json.opt_string comentario) ])
      in
      let* () = encolar_encuesta c ~id in
      Lwt.return id
