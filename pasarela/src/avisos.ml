(* Envio de avisos: lee `GET /interno/avisos/pendientes` del motor, resuelve a quien va y por que canal, rinde la plantilla
   (sin notas internas) y la manda por evolution-go (o simulada). Despues marca el aviso en el motor.

   Garantias:
   - un aviso no se envia dos veces: se anota en `decisiones` (componente `aviso_enviado`) antes de marcarlo, y un aviso que
     ya esta en vuelo no se vuelve a encolar;
   - reintentos acotados: tras `max_intentos` fallos (cuenta del propio motor, `avisos.intentos`) se deja de intentar;
   - nunca se manda a un numero real si el modo de evolution es simulado (lo decide Evolution, no este modulo). *)

let ( let* ) = Lwt.bind

let max_intentos = 5

let en_vuelo : (int, unit) Hashtbl.t = Hashtbl.create 16

(* Destinatario: (nombre, whatsapp). Las personas viven en `personas`; todos los demas tipos, en `tecnicos`. *)
let destinatario (c : Db.conn) ~(tipo : string) ~(id : int option) : (string * string option) option Lwt.t =
  match id with
  | None -> Lwt.return None
  | Some id ->
      let* f =
        Db.fila c (if tipo = "persona" then "SELECT nombre, whatsapp FROM personas WHERE id = $i:id" else "SELECT nombre, whatsapp FROM tecnicos WHERE id = $i:id") (`Assoc [ ("id", `Int id) ])
      in
      Lwt.return (if f = `Null then None else Some (Json.str_d "nombre" "" f, Json.str "whatsapp" f))

let marcar (ctx : Ctx.t) ~(id : int) ~(enviado : bool) ?error () : unit Lwt.t =
  let* r = Motor.marcar_aviso ctx.motor ~id ~enviado ?error () in
  (match r with Error f -> Dream.warning (fun l -> l "avisos: no se pudo marcar el aviso %d en el motor (%s)" id (Motor.describir_fallo f)) | Ok _ -> ());
  Lwt.return ()

let fallo (ctx : Ctx.t) ~(id : int) (motivo : string) : unit Lwt.t =
  Dream.warning (fun l -> l "aviso %d no enviado: %s" id motivo);
  marcar ctx ~id ~enviado:false ~error:motivo ()

(* Texto del aviso. `datos` lo escribe el motor y puede traer de todo: solo pasan los huecos de la lista blanca. *)
let rendir (ctx : Ctx.t) (plantillas : (string * string) list) ~(tipo : string) ~(plantilla : string) ~(inc : Json.t option) ~(datos : Json.t) : string =
  let base =
    match inc with
    | Some inc -> Avisos_plantillas.valores ctx ~inc ()
    | None ->
        let s k = Json.str_d k "" datos in
        [ ("numero", s "numero"); ("prioridad", s "prioridad"); ("titulo", s "titulo"); ("estado", s "estado"); ("estado_texto", String.lowercase_ascii (Textos.estado_corto (s "estado")));
          ("grupo", s "grupo"); ("categoria", s "categoria");
          ("plazo", Option.value (Tiempo.plazo_de_iso ~ahora:(Ctx.ahora ctx) (Json.str "vence_resolucion_en" datos)) ~default:"sin definir") ]
  in
  let extra = (match Json.get "porcentaje" datos with `Null -> [] | v -> [ ("porcentaje", (match Json.float_opt v with Some f -> Printf.sprintf "%.0f" f | None -> "")) ]) in
  (* El plazo del propio aviso (el de ese momento) manda sobre el actual de la incidencia. *)
  let extra = match Json.str "vence_resolucion_en" datos with Some iso -> (match Tiempo.plazo_de_iso ~ahora:(Ctx.ahora ctx) (Some iso) with Some p -> ("plazo", p) :: extra | None -> extra) | None -> extra in
  let generica = if tipo = "persona" then "generica_persona" else "generica_tecnico" in
  Textos.render (Avisos_plantillas.plantilla plantillas ~nombre:plantilla ~generica) (extra @ base)

let procesar_uno (ctx : Ctx.t) (plantillas : (string * string) list) (a : Json.t) : unit Lwt.t =
  let id = Json.int_d "id" 0 a in
  (* Los avisos de la semilla sintetica vienen marcados como no enviables (`error` = «semilla_sintetica…», numeros 5100000xxxx). *)
  let de_semilla = (match Json.str "error" a with Some e -> String.length e >= 16 && String.sub e 0 16 = "semilla_sintetic" | None -> false) in
  if id = 0 || de_semilla || Hashtbl.mem en_vuelo id then Lwt.return ()
  else begin
    let tipo = Json.str_d "destinatario_tipo" "" a and plantilla = Json.str_d "plantilla" "" a in
    let canal = Json.str_d "canal" "whatsapp" a and datos = Json.obj "datos" a in
    let incidencia_id = Json.int "incidencia_id" a in
    (* Idempotencia y tope de intentos, desde la base. *)
    let* previo =
      Db.usar ctx.db (fun c ->
          let* ya = Db.fila c "SELECT 1 AS x FROM decisiones WHERE componente = 'aviso_enviado' AND entrada->>'aviso_id' = $id LIMIT 1" (`Assoc [ ("id", `String (string_of_int id)) ]) in
          Lwt.return (ya <> `Null, Json.int_d "intentos" 0 a))
    in
    match previo with
    | true, _ -> marcar ctx ~id ~enviado:true ()
    | _, intentos when intentos >= max_intentos -> Lwt.return ()
    | _ ->
        let* dest, inc, destino_persona =
          Db.usar ctx.db (fun c ->
              let* dest = destinatario c ~tipo ~id:(Json.int "destinatario_id" a) in
              let* inc = match incidencia_id with Some i -> Casos.incidencia_por_id c i | None -> Lwt.return None in
              let* destino = if tipo = "persona" then (match incidencia_id with Some i -> Entrega.destino_de_incidencia c ~incidencia_id:i | None -> Lwt.return None) else Lwt.return None in
              Lwt.return (dest, inc, destino))
        in
        let registrar_envio () =
          Db.exec_p ctx.db "INSERT INTO decisiones (componente, modo, entrada, salida) VALUES ('aviso_enviado', 'activo', $j:entrada, $j:salida)"
            (`Assoc [ ("entrada", `Assoc [ ("aviso_id", `String (string_of_int id)); ("plantilla", `String plantilla) ]); ("salida", `Assoc [ ("ok", `Bool true) ]) ])
        in
        match dest with
        | None -> fallo ctx ~id "sin_destinatario"
        | Some (_nombre, whatsapp) ->
            if canal = "consola" then begin
              Ctx.publicar ctx "aviso" (`Assoc [ ("plantilla", `String plantilla); ("incidencia_id", Json.opt_int incidencia_id); ("destinatario_id", Json.get "destinatario_id" a) ]);
              let* () = registrar_envio () in
              marcar ctx ~id ~enviado:true ()
            end
            else
              let texto = rendir ctx plantillas ~tipo ~plantilla ~inc ~datos in
              (* Un aviso a una persona de un caso web no tiene a donde ir: queda guardado en la conversacion. *)
              let solo_guardar = (match destino_persona with Some d -> d.Entrega.canal = "web" | None -> false) in
              (match (whatsapp, solo_guardar) with
              | None, false -> fallo ctx ~id (if canal = "correo" then "canal_correo_no_disponible" else "sin_whatsapp")
              | _ ->
                  (* Para una persona, el aviso tambien queda en su conversacion. *)
                  let* () =
                    match destino_persona with
                    | Some d ->
                        let* _ = Db.tx ctx.db (fun c -> Casos.agregar_mensaje ~tocar:false ~con_texto:ctx.cfg.analitica_texto c ~caso_id:d.caso_id ~rol:"sistema" ~texto ~meta:(`Assoc [ ("aviso", `String plantilla); ("aviso_id", `Int id) ])) in
                        Lwt.return ()
                    | None -> Lwt.return ()
                  in
                  if solo_guardar then
                    let* () = registrar_envio () in
                    marcar ctx ~id ~enviado:true ()
                  else begin
                    Hashtbl.replace en_vuelo id ();
                    let destino = match destino_persona with Some d when d.Entrega.canal = "whatsapp" -> d.Entrega.chat_id | _ -> Option.get whatsapp in
                    ignore
                      (Cola_salida.encolar ctx.salida ~destino
                         ~sobre_resultado:(fun r ->
                           Hashtbl.remove en_vuelo id;
                           match r with
                           | Evolution.Enviado _ ->
                               let* () = registrar_envio () in
                               marcar ctx ~id ~enviado:true ()
                           | Evolution.Fallo m -> fallo ctx ~id ("envio: " ^ Casos.recortar 150 m))
                         [ texto ]);
                    Lwt.return ()
                  end)
  end

(* Una pasada: trae los pendientes del motor y los procesa. Devuelve cuantos habia. *)
let procesar_pendientes (ctx : Ctx.t) : int Lwt.t =
  let* r = Motor.avisos_pendientes ctx.motor ~limite:50 in
  match r with
  | Error f ->
      Dream.warning (fun l -> l "avisos: el motor no respondio (%s)" (Motor.describir_fallo f));
      Lwt.return 0
  | Ok (`List l) ->
      let* plantillas = Avisos_plantillas.cargar ctx.db in
      let* () = Lwt_list.iter_s (fun a -> Lwt.catch (fun () -> procesar_uno ctx plantillas a) (fun e -> Dream.error (fun l -> l "avisos: %s" (Printexc.to_string e)); Lwt.return ())) l in
      Lwt.return (List.length l)
  | Ok _ -> Lwt.return 0

let bucle (ctx : Ctx.t) : unit Lwt.t =
  let rec vuelta () =
    let* _ = Lwt.catch (fun () -> procesar_pendientes ctx) (fun e -> Dream.error (fun l -> l "avisos: %s" (Printexc.to_string e)); Lwt.return 0) in
    let* () = Lwt.pick [ Lwt_unix.sleep 5.; Lwt_condition.wait ctx.despertar_avisos ] in
    vuelta ()
  in
  vuelta ()
