(* Lo que no pide sesion: salud, chat web de prueba, estado publico por token, webhook de WhatsApp. Todo con limites de
   frecuencia y de tamaño, y sin revelar si algo existe o no mas de lo necesario. *)

let ( let* ) = Lwt.bind
open Api_util

let version = "1.0.0"

(* --- salud ---------------------------------------------------------------------------------------------------------------------- *)

let con_plazo (s : float) (f : unit -> 'a Lwt.t) (defecto : 'a) : 'a Lwt.t =
  Lwt.catch (fun () -> Lwt_unix.with_timeout s f) (fun _ -> Lwt.return defecto)

let salud (ctx : Ctx.t) (req : Dream.request) : Dream.response Lwt.t =
  (* Publica y consulta tres servicios: sin limite seria un amplificador. El HEALTHCHECK de Docker llama una vez por minuto. *)
  (match Limite.intentar ~ahora:(Ctx.ahora ctx) ctx.limites.salud_ip (Seguridad.ip ctx.cfg req) with Error _ -> Errores.limite () | Ok () -> ());
  let* db = con_plazo 3. (fun () -> Lwt.catch (fun () -> let* _ = Db.fila_p ctx.db "SELECT 1 AS ok" (`Assoc []) in Lwt.return "ok") (fun _ -> Lwt.return "caida")) "caida" in
  let* agente = con_plazo 3. (fun () -> Lwt.map (fun b -> if b then "ok" else "caido") (Agente.salud ctx.agente)) "caido" in
  let* motor = con_plazo 3. (fun () -> Lwt.map (function Ok _ -> "ok" | Error _ -> "caido") (Motor.salud ctx.motor)) "caido" in
  let* evolution = con_plazo 5. (fun () -> Evolution.estado ctx.evolution) "caido" in
  let sano = db = "ok" in
  ok ~estado:(if sano then 200 else 503)
    (`Assoc [ ("ok", `Bool sano); ("db", `String db); ("agente", `String agente); ("motor", `String motor); ("evolution", `String evolution); ("version", `String version) ])

(* --- chat web de prueba ---------------------------------------------------------------------------------------------------------- *)

let sesion_valida (s : string) : bool =
  let n = String.length s in
  n >= 8 && n <= 64 && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '-' || c = '_') s

let chat_web (ctx : Ctx.t) (req : Dream.request) : Dream.response Lwt.t =
  if not ctx.cfg.chat_web then Errores.no_encontrado "El chat web de prueba no está disponible.";
  let ip = Seguridad.ip ctx.cfg req in
  (match Limite.intentar ~ahora:(Ctx.ahora ctx) ctx.limites.chat_ip ip with
  | Error s -> Errores.limite ~msg:(Printf.sprintf "Estás escribiendo muy rápido. Espera %d segundo(s) y vuelve a intentarlo." s) ()
  | Ok () -> ());
  let* b = Seguridad.cuerpo_json ~max:8192 req in
  let sesion = match Json.str "sesion" b with Some s when sesion_valida s -> s | _ -> Errores.invalido "La sesión del chat no es válida. Recarga la página." in
  let mensaje = texto_req ~max:1000 ~nombre:"el mensaje" b "mensaje" in
  (match Limite.intentar ~ahora:(Ctx.ahora ctx) ctx.limites.chat_sesion sesion with
  | Error s -> Errores.limite ~msg:(Printf.sprintf "Estás escribiendo muy rápido. Espera %d segundo(s) y vuelve a intentarlo." s) ()
  | Ok () -> ());
  let* r = Flujo.procesar_web ctx ~sesion ~mensaje in
  let mensajes = Flujo.partes r.textos in
  ok
    (`Assoc
      [ ("respuesta", `String (String.concat "\n\n" r.textos)); ("mensajes", `List (List.map (fun s -> `String s) mensajes));
        ("botones", `List (List.map (fun s -> `String s) r.botones)); ("incidencia", (match r.incidencia with Some n -> `Assoc [ ("numero", `String n) ] | None -> `Null));
        ("analisis", r.analisis) ])

(* --- estado publico (DISENO §16) ---------------------------------------------------------------------------------------------------- *)

let token_valido (t : string) : bool =
  let n = String.length t in
  n >= 16 && n <= 64 && String.for_all (fun c -> (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9')) t

let enlace_no_encontrado () = Errores.no_encontrado "No encontramos ese enlace. Puede que haya caducado; pide uno nuevo a la mesa de ayuda."

(* Limita por IP y por token ANTES de tocar la base: adivinar tokens no sale gratis. *)
let limitar_estado (ctx : Ctx.t) (req : Dream.request) (token : string) =
  let ahora = Ctx.ahora ctx in
  (match Limite.intentar ~ahora ctx.limites.estado_ip (Seguridad.ip ctx.cfg req) with Error _ -> Errores.limite () | Ok () -> ());
  match Limite.intentar ~ahora ctx.limites.estado_token token with Error _ -> Errores.limite () | Ok () -> ()

let buscar_por_token (ctx : Ctx.t) (token : string) : Json.t Lwt.t =
  let* f =
    Db.fila_p ctx.db
      ("SELECT i.id, i.numero, i.titulo, i.estado, i.prioridad, i.persona_id, i.caso_id, t.nombre AS tecnico, " ^ Db.iso "i.vence_resolucion_en" ^ " AS vence_resolucion_en, " ^ Db.iso "i.creada_en"
     ^ " AS creada_en, (i.cerrada_en IS NOT NULL AND i.cerrada_en < now() - interval '1 day' * $i:dias) AS caducada FROM incidencias i LEFT JOIN tecnicos t ON t.id = i.tecnico_id WHERE i.token_publico = $token")
      (`Assoc [ ("token", `String token); ("dias", `Int ctx.cfg.estado_caduca_dias) ])
  in
  if f = `Null || Json.bool_d "caducada" false f then enlace_no_encontrado () else Lwt.return f

let estado_publico (ctx : Ctx.t) (req : Dream.request) : Dream.response Lwt.t =
  let token = Dream.param req "token" in
  limitar_estado ctx req token;
  if not (token_valido token) then enlace_no_encontrado ()
  else begin
    let* inc = buscar_por_token ctx token in
    let* ultimo =
      match Json.int "caso_id" inc with
      | None -> Lwt.return `Null
      | Some caso_id ->
          Db.fila_p ctx.db
            ("SELECT " ^ Db.iso "m.ts" ^ " AS ts, m.texto, coalesce(m.meta->>'autor', 'Soporte') AS autor FROM mensajes m WHERE m.caso_id = $i:caso AND m.rol = 'tecnico' ORDER BY m.id DESC LIMIT 1")
            (`Assoc [ ("caso", `Int caso_id) ])
    in
    let estado = Json.str_d "estado" "" inc in
    let plazo = if estado = "resuelta" || estado = "cerrada" then None else Tiempo.plazo_de_iso ~ahora:(Ctx.ahora ctx) (Json.str "vence_resolucion_en" inc) in
    ok
      (Json.sin_nulos
         (`Assoc
           [ ("numero", Json.get "numero" inc); ("titulo", Json.get "titulo" inc); ("estado", `String estado); ("estado_texto", `String (Textos.estado_publico estado));
             ("tecnico", Json.get "tecnico" inc); ("prioridad", Json.get "prioridad" inc); ("vence_resolucion_en", (if plazo = None then `Null else Json.get "vence_resolucion_en" inc));
             ("sla_texto", Json.opt_string (Option.map (fun p -> "Plazo de resolución: " ^ p) plazo)); ("creada_en", Json.get "creada_en" inc);
             ("ultimo_mensaje_tecnico", (if ultimo = `Null then `Null else ultimo)); ("puede_responder", `Bool (estado <> "cerrada")) ]))
  end

let responder_estado (ctx : Ctx.t) (req : Dream.request) : Dream.response Lwt.t =
  let token = Dream.param req "token" in
  limitar_estado ctx req token;
  if not (token_valido token) then enlace_no_encontrado ()
  else begin
    let* b = Seguridad.cuerpo_json ~max:8192 req in
    let texto = texto_req ~max:1000 ~nombre:"tu respuesta" b "texto" in
    let* inc = buscar_por_token ctx token in
    let estado = Json.str_d "estado" "" inc in
    if estado = "cerrada" then Errores.conflicto "Esta incidencia ya está cerrada. Si el problema sigue, escríbenos de nuevo y abriremos otra."
    else begin
      let id = Json.int_d "id" 0 inc and persona_id = Json.int_d "persona_id" 0 inc in
      let texto = Mascara.ocultar_credenciales texto in
      let actor = Motor.actor ~id:(string_of_int persona_id) "usuario" in
      (* Primero el motor (la verdad de la incidencia): si falla, no se guarda nada a medias. *)
      let* () =
        if estado = "espera_usuario" then
          let* _ = Motor.exigir_accion ctx.motor ~id [ ("accion", `String "reanudar"); ("actor", actor) ] in
          Lwt.return ()
        else Lwt.return ()
      in
      let* _ = Motor.exigir_accion ctx.motor ~id [ ("accion", `String "comentar"); ("texto", `String texto); ("interno", `Bool false); ("actor", actor) ] in
      let* destino = Db.usar ctx.db (fun c -> Entrega.destino_de_incidencia c ~incidencia_id:id) in
      let* () =
        match destino with
        | None -> Lwt.return ()
        | Some d ->
            let* _ =
              Db.tx ctx.db (fun c -> Casos.agregar_mensaje ~con_texto:ctx.cfg.analitica_texto c ~caso_id:d.caso_id ~rol:"usuario" ~texto ~meta:(`Assoc [ ("fuente", `String "estado_publico"); ("incidencia_id", `Int id) ]))
            in
            Lwt.return ()
      in
      Ctx.publicar ctx "mensaje" (`Assoc [ ("id", `Int id) ]);
      Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", Json.get "numero" inc) ]);
      ok (`Assoc [ ("ok", `Bool true) ])
    end
  end

(* --- webhook de evolution-go ----------------------------------------------------------------------------------------------------------- *)

(* El secreto puede venir en la ruta (/webhook/evolution/<secreto>, como en kddesign), en `?secreto=` o en la cabecera
   `X-Webhook-Secret`. Se compara en tiempo constante. *)
let webhook (ctx : Ctx.t) (req : Dream.request) : Dream.response Lwt.t =
  let recibido =
    match Dream.header req "X-Webhook-Secret" with
    | Some s -> s
    | None -> ( match Dream.query req "secreto" with Some s -> s | None -> ( match Dream.param req "secreto" with s -> s | exception _ -> ""))
  in
  (match Limite.intentar ~ahora:(Ctx.ahora ctx) ctx.limites.webhook_ip (Seguridad.ip ctx.cfg req) with Error _ -> Errores.limite () | Ok () -> ());
  if not (Cripto.igual_const recibido ctx.cfg.webhook_secret) then Errores.prohibido "Secreto del webhook inválido."
  else begin
    let* cuerpo = Seguridad.leer_cuerpo ~max:10_485_760 req in
    (* Se responde de inmediato: evolution-go reintenta si tardamos, y el agente puede tardar segundos. *)
    match Webhook.parsear cuerpo with
    | Error m ->
        Dream.warning (fun l -> l "webhook: payload no reconocido (%s)" m);
        ok (`Assoc [ ("recibido", `Bool true); ("ignorado", `String "payload no reconocido") ])
    | Ok (Webhook.Ignorar motivo) -> ok (`Assoc [ ("recibido", `Bool true); ("ignorado", `String motivo) ])
    | Ok (Webhook.Procesar e) ->
        Ctx.lanzar ctx ~nombre:"webhook" (fun () ->
            let* _ = Flujo.procesar ctx e in
            Lwt.return ());
        ok (`Assoc [ ("recibido", `Bool true) ])
  end

(* --- eventos en vivo (SSE) ---------------------------------------------------------------------------------------------------------------- *)

let eventos (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let headers = [ ("Content-Type", "text/event-stream"); ("Cache-Control", "no-cache"); ("X-Accel-Buffering", "no"); ("Connection", "keep-alive") ] in
  Dream.stream ~headers (fun flujo ->
      let sub = Hub.suscribir ctx.hub in
      Lwt.finalize
        (fun () ->
          let* () = Dream.write flujo "retry: 3000\n\n: conectado\n\n" in
          let* () = Dream.flush flujo in
          let rec bucle () =
            let* ev = Hub.siguiente sub in
            match ev with
            | None -> Lwt.return ()
            | Some e ->
                let* () = Dream.write flujo (Hub.formatear e) in
                let* () = Dream.flush flujo in
                bucle ()
          in
          bucle ())
        (fun () ->
          Hub.desuscribir ctx.hub sub;
          Lwt.return ()))
