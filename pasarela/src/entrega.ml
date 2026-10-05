(* Hablarle a la persona desde la consola (respuesta de un tecnico, avisos de estado): el mensaje queda en `mensajes` del caso
   y, si el caso es de WhatsApp, sale por la cola de salida de ese chat. Un caso web no tiene a donde empujar: el mensaje queda
   guardado y se ve en la pagina de estado. *)

let ( let* ) = Lwt.bind

type destino = { caso_id : int; canal : string; chat_id : string }

(* El caso por el que se le habla a la persona de una incidencia. Si la incidencia no nacio de una conversacion (alta manual) y la
   persona tiene WhatsApp, se usa su ultimo caso de WhatsApp o se abre uno. None si no hay por donde. *)
let destino_de_incidencia (c : Db.conn) ~(incidencia_id : int) : destino option Lwt.t =
  let* f =
    Db.fila c
      "SELECT i.caso_id, i.persona_id, p.whatsapp, ca.canal, ca.chat_id FROM incidencias i LEFT JOIN personas p ON p.id = i.persona_id LEFT JOIN casos ca ON ca.id = i.caso_id WHERE i.id = $i:id"
      (`Assoc [ ("id", `Int incidencia_id) ])
  in
  match (Json.int "caso_id" f, Json.str "canal" f, Json.str "chat_id" f) with
  | Some caso_id, Some canal, Some chat_id -> Lwt.return (Some { caso_id; canal; chat_id })
  | _ -> (
      match Json.str "whatsapp" f with
      | None -> Lwt.return None
      | Some wa -> (
          let* previo = Db.escalar_int c "SELECT id FROM casos WHERE canal = 'whatsapp' AND chat_id = $wa ORDER BY ultimo_mensaje DESC, id DESC LIMIT 1" (`Assoc [ ("wa", `String wa) ]) in
          match previo with
          | Some caso_id -> Lwt.return (Some { caso_id; canal = "whatsapp"; chat_id = wa })
          | None ->
              let* caso_id =
                Db.insertar c "INSERT INTO casos (persona_id, canal, chat_id) VALUES ($i:p, 'whatsapp', $wa)" (`Assoc [ ("p", Json.get "persona_id" f); ("wa", `String wa) ])
              in
              let* () = Analitica.encolar_caso c ~id:caso_id in
              Lwt.return (Some { caso_id; canal = "whatsapp"; chat_id = wa })))

(* Guarda el mensaje en el caso y lo envia por su canal. `texto` es lo que se guarda; `texto_enviado`, lo que sale (puede llevar
   el nombre de quien habla). Devuelve «whatsapp» o «web». *)
let enviar (ctx : Ctx.t) ?(tocar = true) ~(destino : destino) ~(rol : string) ~(texto : string) ?texto_enviado ~(meta : Json.t) () : string Lwt.t =
  let* _ =
    Db.tx ctx.db (fun c -> Casos.agregar_mensaje ~tocar ~con_texto:ctx.cfg.analitica_texto c ~caso_id:destino.caso_id ~rol ~texto ~meta)
  in
  if destino.canal = "whatsapp" then ignore (Cola_salida.encolar ctx.salida ~destino:destino.chat_id (Flujo.partes [ Option.value texto_enviado ~default:texto ]));
  Ctx.publicar ctx "mensaje" (`Assoc [ ("caso_id", `Int destino.caso_id) ]);
  Lwt.return destino.canal

(* Aviso de estado a la persona de una incidencia (asignada, resuelta, reabierta). Silencioso si no hay canal. *)
let avisar_persona (ctx : Ctx.t) ~(incidencia_id : int) ~(plantilla : string) : unit Lwt.t =
  Lwt.catch
    (fun () ->
      let* destino = Db.usar ctx.db (fun c -> destino_de_incidencia c ~incidencia_id) in
      match destino with
      | None -> Lwt.return ()
      | Some d ->
          let* inc = Db.usar ctx.db (fun c -> Casos.incidencia_por_id c incidencia_id) in
          (match inc with
          | None -> Lwt.return ()
          | Some inc ->
              let* plantillas = Avisos_plantillas.cargar ctx.db in
              let texto = Avisos_plantillas.texto_para_persona ctx plantillas ~plantilla ~inc in
              let* _ = enviar ctx ~tocar:false ~destino:d ~rol:"sistema" ~texto ~meta:(`Assoc [ ("aviso", `String plantilla); ("incidencia_id", `Int incidencia_id) ]) () in
              Lwt.return ()))
    (fun e ->
      Dream.warning (fun l -> l "no se pudo avisar a la persona de la incidencia %d: %s" incidencia_id (Printexc.to_string e));
      Lwt.return ())
