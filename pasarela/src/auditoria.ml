(* Auditoria de acciones sensibles en `auditoria` (CONTRATOS §5: la pasarela la escribe). Solo inserciones. El detalle
   nunca lleva contraseñas, tokens ni textos de conversaciones. *)

let registrar ?usuario_id ?objeto ?(detalle = `Assoc []) (c : Db.conn) ~(accion : string) : unit Lwt.t =
  let detalle = match detalle with `Null -> `Assoc [] | d -> d in
  Db.exec c "INSERT INTO auditoria (usuario_id, accion, objeto, detalle) VALUES ($i:uid, $accion, $objeto, $j:detalle)"
    (`Assoc [ ("uid", Json.opt_int usuario_id); ("accion", `String accion); ("objeto", Json.opt_string objeto); ("detalle", detalle) ])

let registrar_p ?usuario_id ?objeto ?detalle (db : Db.t) ~accion : unit Lwt.t =
  Db.usar db (fun c -> registrar ?usuario_id ?objeto ?detalle c ~accion)
