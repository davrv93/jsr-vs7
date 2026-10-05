(* Conversaciones: lista, mensajes, tomar (pausa al asistente), devolver y escribir como tecnico. *)

let ( let* ) = Lwt.bind
open Api_util

let seleccion =
  "SELECT c.id, c.canal, CASE WHEN p.id IS NULL THEN NULL ELSE json_build_object('id', p.id, 'nombre', p.nombre, 'area', a.nombre, 'sede', s.nombre) END AS persona, "
  ^ "c.etapa, c.estado, c.pausado_por_tecnico, " ^ Db.iso "c.inicio" ^ " AS inicio, " ^ Db.iso "c.ultimo_mensaje" ^ " AS ultimo_mensaje, "
  ^ "coalesce((SELECT left(m.texto, 160) FROM mensajes m WHERE m.caso_id = c.id AND m.rol IN ('usuario', 'asistente', 'tecnico') ORDER BY m.id DESC LIMIT 1), '') AS ultimo_texto, "
  ^ "(SELECT i.numero FROM incidencias i WHERE i.caso_id = c.id ORDER BY i.id DESC LIMIT 1) AS incidencia_numero, "
  ^ "(SELECT count(*) FROM mensajes m WHERE m.caso_id = c.id)::int AS mensajes_total, "
  ^ "CASE WHEN c.pausado_por_tecnico THEN (SELECT u.nombre FROM auditoria au JOIN usuarios_consola u ON u.id = au.usuario_id WHERE au.objeto = 'caso:' || c.id AND au.accion = 'caso_tomado' ORDER BY au.id DESC LIMIT 1) END AS tomado_por "
  ^ "FROM casos c LEFT JOIN personas p ON p.id = c.persona_id LEFT JOIN areas a ON a.id = p.area_id LEFT JOIN sedes s ON s.id = p.sede_id "

let caso_por_id (c : Db.conn) (id : int) : Json.t Lwt.t =
  let* f = Db.fila c (seleccion ^ "WHERE c.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  if f = `Null then Errores.no_encontrado "No encontramos esa conversación." else Lwt.return f

let listar (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let _, por, offset = paginacion req in
  let estado = Option.map (en_lista ~nombre:"el estado" [ "abierto"; "resuelto_asistente"; "con_incidencia"; "cerrado" ]) (consulta req "estado") in
  let canal = Option.map (en_lista ~nombre:"el canal" [ "whatsapp"; "web" ]) (consulta req "canal") in
  let pausados = consulta req "pausados" = Some "1" in
  let filtros = "WHERE ($estado IS NULL OR c.estado = $estado) AND ($canal IS NULL OR c.canal = $canal) AND (NOT $b:pausados OR c.pausado_por_tecnico)" in
  let params = `Assoc [ ("estado", Json.opt_string estado); ("canal", Json.opt_string canal); ("pausados", `Bool pausados); ("limite", `Int por); ("offset", `Int offset) ] in
  let* total = Db.fila_p ctx.db ("SELECT count(*) AS n FROM casos c " ^ filtros) params in
  let* filas = Db.lista_p ctx.db (seleccion ^ filtros ^ " ORDER BY c.ultimo_mensaje DESC, c.id DESC LIMIT $i:limite OFFSET $i:offset") params in
  lista filas (Json.int_d "n" 0 total)

let mensajes (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"conversación" req "id" in
  let* caso, items =
    Db.usar ctx.db (fun c ->
        let* caso = caso_por_id c id in
        let* items =
          Db.lista c
            ("SELECT m.id, " ^ Db.iso "m.ts" ^ " AS ts, m.rol, m.meta->>'autor' AS autor, m.texto, "
           ^ "json_build_object('intencion', m.meta->>'intencion', 'confianza', (m.meta->>'confianza')::float8, 'categoria', m.meta->>'categoria', 'latencia_ms', (m.meta->>'latencia_ms')::float8, 'articulos', m.meta->'articulos') AS meta "
           ^ "FROM mensajes m WHERE m.caso_id = $i:id ORDER BY m.id LIMIT 500")
            (`Assoc [ ("id", `Int id) ])
        in
        Lwt.return (caso, List.map (fun m -> Json.sin_nulos (Json.set "meta" (Json.sin_nulos (Json.get "meta" m)) (Json.sin_nulos m))) items))
  in
  ok (`Assoc [ ("caso", caso); ("items", `List items); ("total", `Int (List.length items)) ])

let destino_de_caso (c : Db.conn) (id : int) : Entrega.destino Lwt.t =
  let* f = Db.fila c "SELECT canal, chat_id FROM casos WHERE id = $i:id" (`Assoc [ ("id", `Int id) ]) in
  match (Json.str "canal" f, Json.str "chat_id" f) with
  | Some canal, Some chat_id -> Lwt.return { Entrega.caso_id = id; canal; chat_id }
  | _ -> Errores.no_encontrado "No encontramos esa conversación."

(* Tomar: pausa al asistente. Si ya la tiene otra persona, solo un supervisor la quita. Avisa a la persona. *)
let tomar (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"conversación" req "id" in
  let* caso = Db.usar ctx.db (fun c -> caso_por_id c id) in
  let ya = Json.bool_d "pausado_por_tecnico" false caso in
  let por = Json.str "tomado_por" caso in
  (match por with
  | Some otro when ya && otro <> u.nombre && not (Roles.permite u.rol Roles.R_supervisor) ->
      Errores.conflicto (Printf.sprintf "Esta conversación ya la tomó %s." otro)
  | _ -> ());
  let* destino = Db.usar ctx.db (fun c -> destino_de_caso c id) in
  let* () =
    Db.tx ctx.db (fun c ->
        let* () = Casos.fijar_pausa c ~caso_id:id true in
        Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "caso:%d" id) ~accion:"caso_tomado" ~detalle:(`Assoc [ ("tecnico_id", Json.opt_int u.tecnico_id) ]))
  in
  let* () =
    if ya && por = Some u.nombre then Lwt.return ()
    else
      let* _ = Entrega.enviar ctx ~destino ~rol:"sistema" ~texto:(Textos.tomada_por ~nombre:u.nombre) ~meta:(`Assoc [ ("aviso", `String "caso_tomado") ]) () in
      Lwt.return ()
  in
  let* caso = Db.usar ctx.db (fun c -> caso_por_id c id) in
  ok caso

(* Devolver: el asistente vuelve a atender la conversacion. *)
let devolver (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"conversación" req "id" in
  let* caso = Db.usar ctx.db (fun c -> caso_por_id c id) in
  let* destino = Db.usar ctx.db (fun c -> destino_de_caso c id) in
  let* () =
    Db.tx ctx.db (fun c ->
        let* () = Casos.fijar_pausa c ~caso_id:id false in
        Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "caso:%d" id) ~accion:"caso_devuelto" ~detalle:(`Assoc []))
  in
  let* () =
    if Json.bool_d "pausado_por_tecnico" false caso then
      let* _ = Entrega.enviar ctx ~destino ~rol:"sistema" ~texto:Textos.devuelta_al_asistente ~meta:(`Assoc [ ("aviso", `String "caso_devuelto") ]) () in
      Lwt.return ()
    else Lwt.return ()
  in
  let* caso = Db.usar ctx.db (fun c -> caso_por_id c id) in
  ok caso

(* Escribir en una conversacion tomada. Si el caso tiene una incidencia abierta, cuenta como respuesta del tecnico en ella. *)
let escribir (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"conversación" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let texto = texto_req ~max:4000 ~nombre:"el mensaje" b "texto" in
  let* caso = Db.usar ctx.db (fun c -> caso_por_id c id) in
  if not (Json.bool_d "pausado_por_tecnico" false caso) then Errores.conflicto "Toma la conversación antes de escribir: así el asistente deja de contestar."
  else begin
    let* destino = Db.usar ctx.db (fun c -> destino_de_caso c id) in
    let* inc = Db.usar ctx.db (fun c -> Db.escalar_int c "SELECT id FROM incidencias WHERE caso_id = $i:id AND estado NOT IN ('cerrada', 'resuelta') ORDER BY id DESC LIMIT 1" (`Assoc [ ("id", `Int id) ])) in
    let* () =
      match (inc, u.tecnico_id) with
      | Some inc_id, Some t ->
          let* _ = Motor.exigir_accion ctx.motor ~id:inc_id [ ("accion", `String "responder"); ("texto", `String texto); ("actor", Motor.actor ~id:(string_of_int t) "tecnico") ] in
          Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int inc_id) ]);
          Lwt.return ()
      | _ -> Lwt.return ()
    in
    let* _ =
      Entrega.enviar ctx ~destino ~rol:"tecnico" ~texto ~texto_enviado:(Printf.sprintf "%s (mesa de ayuda): %s" u.nombre texto)
        ~meta:(Json.sin_nulos (`Assoc [ ("autor", `String u.nombre); ("tecnico_id", Json.opt_int u.tecnico_id); ("incidencia_id", Json.opt_int inc) ]))
        ()
    in
    ok (`Assoc [ ("ok", `Bool true) ])
  end
