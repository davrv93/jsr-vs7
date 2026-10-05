(* Recordatorios con temporizador idempotente: (1) confirmacion de cierre, para una incidencia resuelta que la persona no confirma;
   (2) encuesta, para una encuesta enviada y sin responder. Cada recordatorio sale UNA vez: se reclama insertando un mensaje de
   sistema con `recordatorio_clave` (indice unico mensajes_recordatorio_uq) ANTES de enviar, asi dos pasadas o dos instancias no
   lo duplican. No se manda de noche (hora de Lima): la condicion sigue vigente y sale por la mañana. *)

let ( let* ) = Lwt.bind

let hora_permitida (ahora : float) : bool =
  let h = (Tiempo.lima ahora).Unix.tm_hour in
  h >= 8 && h < 21

(* Reclama la clave: true si este proceso es quien debe enviar. *)
let reclamar (ctx : Ctx.t) ~(destino : Entrega.destino) ~(clave : string) ~(texto : string) : bool Lwt.t =
  Lwt.catch
    (fun () ->
      let* _ =
        Db.tx ctx.db (fun c ->
            Casos.agregar_mensaje ~tocar:false ~con_texto:ctx.cfg.analitica_texto c ~caso_id:destino.caso_id ~rol:"sistema" ~texto
              ~meta:(`Assoc [ ("recordatorio_clave", `String clave) ]))
      in
      Lwt.return true)
    (fun e -> if Db.es_unica_violada e then Lwt.return false else Lwt.fail e)

let enviar (ctx : Ctx.t) ~(destino : Entrega.destino) ~(clave : string) ~(texto : string) : bool Lwt.t =
  let* nuevo = reclamar ctx ~destino ~clave ~texto in
  if nuevo && destino.canal = "whatsapp" then ignore (Cola_salida.encolar ctx.salida ~destino:destino.chat_id [ texto ]);
  if nuevo then Ctx.publicar ctx "mensaje" (`Assoc [ ("caso_id", `Int destino.caso_id) ]);
  Lwt.return nuevo

(* Devuelve cuantos recordatorios salieron. *)
let ejecutar (ctx : Ctx.t) : int Lwt.t =
  if not (hora_permitida (Ctx.ahora ctx)) then Lwt.return 0
  else begin
    let* plantillas = Avisos_plantillas.cargar ctx.db in
    (* 1. Cierre: resuelta hace tiempo, sin respuesta de la persona despues de la resolucion. *)
    let* resueltas =
      Db.lista_p ctx.db
        "SELECT i.id FROM incidencias i WHERE i.estado = 'resuelta' AND i.resuelta_en < now() - make_interval(secs => $f:s) \
         AND NOT EXISTS (SELECT 1 FROM mensajes m WHERE m.meta->>'recordatorio_clave' = 'cierre:' || i.id) \
         AND (i.caso_id IS NULL OR NOT EXISTS (SELECT 1 FROM mensajes m WHERE m.caso_id = i.caso_id AND m.rol = 'usuario' AND m.ts > i.resuelta_en)) ORDER BY i.id LIMIT 50"
        (`Assoc [ ("s", `Float (ctx.cfg.recordatorio_cierre_horas *. 3600.)) ])
    in
    let* n1 =
      Lwt_list.fold_left_s
        (fun acc f ->
          let id = Json.int_d "id" 0 f in
          let* destino = Db.usar ctx.db (fun c -> Entrega.destino_de_incidencia c ~incidencia_id:id) in
          match destino with
          | None -> Lwt.return acc
          | Some d ->
              let* inc = Db.usar ctx.db (fun c -> Casos.incidencia_por_id c id) in
              let texto = Textos.render (Avisos_plantillas.plantilla plantillas ~nombre:"recordatorio_cierre" ~generica:"generica_persona") (match inc with Some i -> Avisos_plantillas.valores ctx ~inc:i () | None -> []) in
              let* nuevo = enviar ctx ~destino:d ~clave:(Printf.sprintf "cierre:%d" id) ~texto in
              Lwt.return (if nuevo then acc + 1 else acc))
        0 resueltas
    in
    (* 2. Encuesta enviada y sin responder. *)
    let* pendientes =
      Db.lista_p ctx.db
        "SELECT e.id, e.caso_id, e.incidencia_id FROM encuestas e WHERE e.puntaje IS NULL AND e.caso_id IS NOT NULL AND e.ts < now() - make_interval(secs => $f:s) \
         AND NOT EXISTS (SELECT 1 FROM mensajes m WHERE m.meta->>'recordatorio_clave' = 'encuesta:' || e.id) ORDER BY e.id LIMIT 50"
        (`Assoc [ ("s", `Float (ctx.cfg.recordatorio_encuesta_horas *. 3600.)) ])
    in
    let* n2 =
      Lwt_list.fold_left_s
        (fun acc f ->
          let id = Json.int_d "id" 0 f in
          let caso_id = Json.int_d "caso_id" 0 f in
          let* destino = Db.usar ctx.db (fun c -> let* r = Db.fila c "SELECT canal, chat_id FROM casos WHERE id = $i:id" (`Assoc [ ("id", `Int caso_id) ]) in Lwt.return (match (Json.str "canal" r, Json.str "chat_id" r) with Some canal, Some chat_id -> Some { Entrega.caso_id; canal; chat_id } | _ -> None)) in
          match destino with
          | None -> Lwt.return acc
          | Some d ->
              let* inc = match Json.int "incidencia_id" f with Some i -> Db.usar ctx.db (fun c -> Casos.incidencia_por_id c i) | None -> Lwt.return None in
              let texto =
                match inc with
                | Some i -> Textos.render (Avisos_plantillas.plantilla plantillas ~nombre:"recordatorio_encuesta" ~generica:"generica_persona") (Avisos_plantillas.valores ctx ~inc:i ())
                | None -> "Cuando puedas, cuéntame del 1 al 5 qué tal te atendimos. Nos ayuda a mejorar."
              in
              let* nuevo = enviar ctx ~destino:d ~clave:(Printf.sprintf "encuesta:%d" id) ~texto in
              Lwt.return (if nuevo then acc + 1 else acc))
        0 pendientes
    in
    Lwt.return (n1 + n2)
  end
