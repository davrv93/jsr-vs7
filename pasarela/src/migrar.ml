(* Cambios de esquema propios de la pasarela. Son SOLO indices (nada de columnas ni tablas): el esquema es del
   Arquitecto (backend/migrations). Todos son idempotentes (IF NOT EXISTS) y se aplican al arrancar, esperando a que el
   motor haya creado las tablas. Se listan en docs/CONTRATOS.md «Cambios». *)

let ( let* ) = Lwt.bind

let sentencias =
  [ (* Deduplicar el webhook: un mensaje de WhatsApp (su ID) se procesa una sola vez, aunque lleguen dos entregas a la vez. *)
    "CREATE UNIQUE INDEX IF NOT EXISTS mensajes_wa_id_uq ON mensajes ((meta->>'wa_id')) WHERE meta->>'wa_id' IS NOT NULL";
    (* Recordatorios idempotentes: cada recordatorio (clave) sale una sola vez. *)
    "CREATE UNIQUE INDEX IF NOT EXISTS mensajes_recordatorio_uq ON mensajes ((meta->>'recordatorio_clave')) WHERE meta->>'recordatorio_clave' IS NOT NULL";
    (* Un aviso del motor no se envia dos veces: se anota en `decisiones` y se consulta por su id. *)
    "CREATE INDEX IF NOT EXISTS decisiones_aviso_idx ON decisiones ((entrada->>'aviso_id')) WHERE componente = 'aviso_enviado'";
    "CREATE INDEX IF NOT EXISTS decisiones_caso_idx ON decisiones (caso_id, ts DESC)";
    "CREATE INDEX IF NOT EXISTS casos_persona_idx ON casos (persona_id)";
    "CREATE INDEX IF NOT EXISTS incidencias_caso_idx ON incidencias (caso_id) WHERE caso_id IS NOT NULL";
    "CREATE INDEX IF NOT EXISTS auditoria_objeto_idx ON auditoria (objeto, ts DESC)";
    "CREATE INDEX IF NOT EXISTS articulo_usos_caso_idx ON articulo_usos (caso_id)" ]

let esquema_listo (db : Db.t) : bool Lwt.t =
  Lwt.catch
    (fun () ->
      Db.usar db (fun c ->
          let* f = Db.fila c "SELECT to_regclass('public.mensajes') IS NOT NULL AND to_regclass('public.incidencias') IS NOT NULL AND to_regclass('public.decisiones') IS NOT NULL AS listo" (`Assoc []) in
          Lwt.return (Json.bool_d "listo" false f)))
    (fun _ -> Lwt.return false)

(* Espera hasta `plazo` segundos a que existan las tablas; luego aplica los indices. *)
let aplicar ?(plazo = 60.) (db : Db.t) : unit Lwt.t =
  let rec esperar restante =
    let* ok = esquema_listo db in
    if ok then Lwt.return true
    else if restante <= 0. then Lwt.return false
    else
      let* () = Lwt_unix.sleep 2. in
      esperar (restante -. 2.)
  in
  let* listo = esperar plazo in
  if not listo then Db.(raise (Db_error "el esquema de la base no esta listo (¿corrio el motor o backend/migrations?)"))
  else
    Db.usar db (fun c ->
        Lwt_list.iter_s (fun sql -> Db.exec c sql (`Assoc [])) sentencias)
