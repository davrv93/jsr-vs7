(* El flujo del caso (reemplaza internal/bot de kddesign). Un mensaje de WhatsApp o del chat web recorre el MISMO camino:

     persona -> caso (sesion de 6 h) -> [pausa por tecnico?] -> agente -> guardar -> ejecutar la accion -> responder

   El agente propone; este modulo decide y ejecuta. Lo que cambia una incidencia pasa por el motor; el texto con numero,
   tecnico y plazo lo arma `Textos`. Un mismo chat se procesa de a uno (`Ctx.con_candado`). *)

open Turno

let ( let* ) = Lwt.bind

(* --- piezas -------------------------------------------------------------------------------------------------------- *)

let decision (c : Db.conn) ?caso_id ~(componente : string) ~(modo : string) ~(entrada : Json.t) ~(salida : Json.t) () : unit Lwt.t =
  Db.exec c "INSERT INTO decisiones (caso_id, componente, modo, entrada, salida) VALUES ($i:caso, $componente, $modo, $j:entrada, $j:salida)"
    (`Assoc [ ("caso", Json.opt_int caso_id); ("componente", `String componente); ("modo", `String modo); ("entrada", entrada); ("salida", salida) ])

let modo_juicio (c : Db.conn) : string Lwt.t =
  let* f = Db.fila c "SELECT valor #>> '{}' AS modo FROM configuracion WHERE clave = 'juicio_modo'" (`Assoc []) in
  Lwt.return (match Json.str "modo" f with Some m when Juicio.modo_valido m -> m | _ -> "sombra")

(* Parrafos tal como se mandan por WhatsApp: uno por mensaje, como escribe una persona. Un tope de 6 mensajes. *)
let partes (textos : string list) : string list =
  let todas =
    textos
    |> List.concat_map (fun t -> Re.split (Re.compile (Re.seq [ Re.char '\n'; Re.rep1 (Re.alt [ Re.char '\n'; Re.char ' ' ]) ])) t)
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let n = List.length todas in
  if n <= 6 then todas
  else List.filteri (fun i _ -> i < 5) todas @ [ String.concat "\n\n" (List.filteri (fun i _ -> i >= 5) todas) ]

let botones_de (r : respuesta_agente) (memoria : Json.t) : string list =
  if r.botones <> [] then r.botones
  else
    match Json.str "pendiente" memoria with
    | Some "resolvio" -> [ "Sí, se resolvió"; "Sigue igual" ]
    | Some "puntaje" -> [ "5"; "4"; "3"; "2"; "1" ]
    | Some "ofrecer_tecnico" -> [ "Abrir incidencia"; "Hablar con un técnico" ]
    | _ -> []

let articulos_con_titulo (ctx : Ctx.t) (claves : string list) : Json.t list Lwt.t =
  if claves = [] then Lwt.return []
  else
    Db.usar ctx.db (fun c ->
        let* filas =
          Db.lista c "SELECT clave, titulo FROM articulos WHERE clave IN (SELECT jsonb_array_elements_text($j:claves))"
            (`Assoc [ ("claves", `List (List.map (fun k -> `String k) claves)) ])
        in
        Lwt.return
          (List.map
             (fun k ->
               let titulo = match List.find_opt (fun f -> Json.str "clave" f = Some k) filas with Some f -> Json.str_d "titulo" k f | None -> k in
               `Assoc [ ("clave", `String k); ("titulo", `String titulo); ("fuente", `String "base de conocimiento") ])
             claves))

(* --- lo que se manda al agente ------------------------------------------------------------------------------------------ *)

let peticion (ctx : Ctx.t) ~(caso : Casos.caso) ~(persona_id : int) ~(canal : string) ~(texto : string) : Json.t Lwt.t =
  Db.usar ctx.db (fun c ->
      let* hist = Casos.historial c ~caso_id:caso.id ~limite:ctx.cfg.historial_turnos in
      let* perfil = Casos.perfil c ~persona_id in
      let* abiertas = Casos.incidencias_abiertas c ~persona_id in
      Lwt.return
        (`Assoc
          [ ("caso_id", `Int caso.id); ("canal", `String canal); ("mensaje", `String texto); ("historial", `List hist);
            ("etapa", `String caso.etapa); ("memoria", caso.memoria); ("perfil", perfil); ("incidencias_abiertas", `List abiertas);
            ("ahora", `String (Tiempo.a_iso (Ctx.ahora ctx))) ]))

(* --- metadatos de los mensajes (alimentan la analitica, CONTRATOS §4) ------------------------------------------------------ *)

let meta_usuario ~(wa_id : string option) (r : respuesta_agente) : Json.t =
  Json.sin_nulos
    (`Assoc
      [ ("wa_id", Json.opt_string wa_id); ("intencion", Json.opt_string r.intencion); ("confianza", Json.opt_float r.confianza);
        ("categoria", Json.opt_string r.categoria); ("categoria_confianza", Json.opt_float r.categoria_confianza);
        ("juez_modo", `String (modo_juez r.juez)); ("juez_veredicto", `String (veredicto_texto r.juez)); ("senales", r.senales) ])

let meta_asistente (r : respuesta_agente) (e : efecto) : Json.t =
  Json.sin_nulos
    (`Assoc
      [ ("categoria", Json.opt_string r.categoria); ("latencia_ms", Json.opt_int r.latencia_ms); ("articulos", `List (List.map (fun s -> `String s) r.articulos));
        ("accion", `String r.accion_tipo); ("incidencia", Json.opt_string e.incidencia); ("regenerada", `Bool r.regenerada);
        ("frases_quitadas", `Int r.frases_quitadas); ("costo_usd", `Float r.costo_usd); ("juez_modo", `String (modo_juez r.juez));
        ("juez_veredicto", `String (veredicto_texto r.juez)); ("sugerencia_tecnico", r.sugerencia_tecnico) ])

(* `juez.veredictos` del agente: {tipo: {veredicto, confianza, detalle?}}. Lo que no trae `veredicto` (p. ej. el orden alternativo del
   bandido de articulos, que va en sombra) no es un veredicto del juez: queda como su propio componente en `decisiones`. *)
let veredictos_juez (r : respuesta_agente) : (string * Json.t) list =
  match Json.obj "veredictos" r.juez with
  | `Assoc l -> List.map (fun (k, v) -> (k, match v with `String s -> `Assoc [ ("veredicto", `String s) ] | `Assoc _ -> v | _ -> `Assoc [])) l
  | _ -> []

let es_veredicto (v : Json.t) = Json.str "veredicto" v <> None

(* --- turnos -------------------------------------------------------------------------------------------------------------------- *)

let analisis (ctx : Ctx.t) ~(caso : Casos.caso) (r : respuesta_agente) (e : efecto) : Json.t Lwt.t =
  let* arts = articulos_con_titulo ctx r.articulos in
  let memoria = Option.value r.memoria ~default:caso.memoria in
  let sen = r.senales in
  Lwt.return
    (`Assoc
      [ ("etapa", `String (Option.value r.etapa ~default:caso.etapa)); ("memoria", memoria);
        ("intencion", `String (Option.value r.intencion ~default:"")); ("confianza", `Float (Option.value r.confianza ~default:0.));
        ("categoria", Json.opt_string r.categoria); ("categoria_confianza", Json.opt_float r.categoria_confianza);
        ("accion", e.accion_final); ("articulos_usados", `List arts);
        ( "senales",
          `Assoc
            [ ("animo", `String (Json.str_d "animo" "neutro" sen)); ("queja", `Bool (Json.bool_d "queja" false sen));
              ("pide_tecnico", `Bool (Json.bool_d "pide_tecnico" false sen)); ("contrasena_oculta", `Bool (Json.bool_d "contrasena_oculta" false sen)) ] );
        ("juez", `Assoc [ ("modo", `String (modo_juez r.juez)); ("veredictos", Json.obj "veredictos" r.juez) ]);
        ("latencia_ms", `Int (Option.value r.latencia_ms ~default:0)); ("agente", r.analisis_agente) ])

let aplicar_respuesta (ctx : Ctx.t) (e : Webhook.entrante) ~(caso : Casos.caso) ~(persona_id : int) ~(texto : string) (j : Json.t) : Turno.resultado Lwt.t =
  let r = Turno.leer j ~texto_original:texto in
  let accion_desconocida = (match Json.str "tipo" (Json.obj "accion" j) with Some t -> not (List.mem t Turno.acciones_validas) | None -> false) in
  let* modo = Db.usar ctx.db modo_juicio in
  let juicio = Juicio.evaluar r in
  (* En `activo`, derivar a una persona cambia la accion; en `sombra` solo queda registrado. *)
  let r =
    if modo = "activo" && juicio.decision = Juicio.Derivar && r.accion_tipo = "ninguna" then { r with accion_tipo = "pedir_tecnico"; accion = `Assoc [ ("tipo", `String "pedir_tecnico") ] }
    else r
  in
  let con_texto = ctx.cfg.analitica_texto in
  let etapa_anterior = caso.etapa in
  (* 1. El mensaje de la persona (con `texto_usuario_guardar`), lo que decidio el agente y la ficha nueva: una transaccion. *)
  let* mensaje_id =
    Db.tx ctx.db (fun c ->
        let* mid = Casos.agregar_mensaje ~con_texto c ~caso_id:caso.id ~rol:"usuario" ~texto:r.texto_guardar ~meta:(meta_usuario ~wa_id:e.msg_id r) in
        let* () =
          decision c ~caso_id:caso.id ~componente:"asistente" ~modo:(if modo = "apagado" then "sombra" else modo)
            ~entrada:(`Assoc [ ("mensaje_id", `Int mid); ("etapa_anterior", `String etapa_anterior); ("pendiente", Json.opt_string (Json.str "pendiente" caso.memoria)) ])
            ~salida:
              (Json.sin_nulos
                 (`Assoc
                   [ ("accion", `String r.accion_tipo); ("accion_desconocida", if accion_desconocida then `Bool true else `Null);
                     ("etapa", Json.opt_string r.etapa); ("intencion", Json.opt_string r.intencion); ("confianza", Json.opt_float r.confianza);
                     ("categoria", Json.opt_string r.categoria); ("motivo", Json.opt_string (Json.str "motivo" (Json.obj "incidencia" r.accion)));
                     ("articulos", `List (List.map (fun s -> `String s) r.articulos)); ("senales", r.senales); ("juicio", Juicio.a_json juicio) ]))
            ()
        in
        let* () =
          Lwt_list.iter_s
            (fun (tipo, v) ->
              if es_veredicto v then
                if modo_juez r.juez = "apagado" then Lwt.return ()
                else decision c ~caso_id:caso.id ~componente:"juez" ~modo:(modo_juez r.juez) ~entrada:(`Assoc [ ("mensaje_id", `Int mid); ("tipo", `String tipo) ]) ~salida:v ()
              else decision c ~caso_id:caso.id ~componente:tipo ~modo:"sombra" ~entrada:(`Assoc [ ("mensaje_id", `Int mid) ]) ~salida:v ())
            (veredictos_juez r)
        in
        let* () = Casos.guardar c ~caso_id:caso.id ?etapa:r.etapa ?memoria:r.memoria () in
        Lwt.return mid)
  in
  (* 2. La accion (puede llamar al motor). *)
  let* efecto = Acciones.ejecutar ctx ~caso ~persona_id ~mensaje_id ~texto_guardar:r.texto_guardar r in
  let* () =
    if Turno.hay_queja r && r.accion_tipo <> "crear_incidencia" && r.accion_tipo <> "pedir_tecnico" then Acciones.registrar_queja ctx ~caso ~persona_id ~texto:r.texto_guardar
    else Lwt.return ()
  in
  (* 3. Lo que se le dijo a la persona, y el estado del caso. *)
  let texto_asistente = String.concat "\n\n" efecto.textos in
  let* () =
    Db.tx ctx.db (fun c ->
        let* _ = Casos.agregar_mensaje ~con_texto c ~caso_id:caso.id ~rol:"asistente" ~texto:texto_asistente ~meta:(meta_asistente r efecto) in
        (* Se le pregunta la nota (etapa «encuesta»): la encuesta queda enviada y sin responder (puntaje NULL). *)
        let pide_nota = r.etapa = Some "encuesta" || (match r.memoria with Some m -> Json.str "pendiente" m = Some "puntaje" | None -> false) in
        let* _ = if pide_nota && r.accion_tipo <> "encuesta" then Analitica.abrir_encuesta c ~caso_id:caso.id else Lwt.return None in
        match efecto.estado_caso with Some st -> Casos.guardar c ~caso_id:caso.id ~estado:st () | None -> Lwt.return ())
  in
  Ctx.publicar ctx "mensaje" (`Assoc [ ("caso_id", `Int caso.id) ]);
  let* analisis = analisis ctx ~caso r efecto in
  let memoria = Option.value r.memoria ~default:caso.memoria in
  Lwt.return
    { Turno.textos = efecto.textos; caso_id = Some caso.id; incidencia = efecto.incidencia; analisis; botones = botones_de r memoria; duplicado = false;
      pausado = false; derivado = false }

(* El agente no respondio (dos intentos): mensaje de cortesia y derivacion a una persona (incidencia, o dato a la abierta). *)
let respaldo_agente_caido (ctx : Ctx.t) (e : Webhook.entrante) ~(caso : Casos.caso) ~(persona_id : int) ~(texto : string) ~(motivo : string) : Turno.resultado Lwt.t =
  Dream.error (fun l -> l "el agente no responde (caso %d): %s" caso.id motivo);
  let texto_guardar = Mascara.ocultar_credenciales texto in
  let con_texto = ctx.cfg.analitica_texto in
  let* () =
    Db.tx ctx.db (fun c ->
        let* _ = Casos.agregar_mensaje ~con_texto c ~caso_id:caso.id ~rol:"usuario" ~texto:texto_guardar ~meta:(Json.sin_nulos (`Assoc [ ("wa_id", Json.opt_string e.msg_id); ("agente_caido", `Bool true) ])) in
        decision c ~caso_id:caso.id ~componente:"agente" ~modo:"activo" ~entrada:(`Assoc [ ("etapa", `String caso.etapa) ])
          ~salida:(`Assoc [ ("ok", `Bool false); ("motivo", `String (Casos.recortar 200 motivo)) ]) ())
  in
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ()) in
  let* efecto =
    match actual with
    | Some inc when Acciones.abierta inc -> (
        let id = Json.int_d "id" 0 inc and numero = Json.str_d "numero" "" inc in
        let* res =
          Motor.accion ctx.motor ~id
            (`Assoc
              [ ("accion", `String "agregar_dato"); ("actor", Acciones.actor_usuario persona_id); ("clave", `String "mensaje_sin_atender");
                ("valor", `String (Casos.recortar 500 texto_guardar)) ])
        in
        match res with
        | Ok _ ->
            Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String numero) ]);
            Lwt.return (Acciones.efecto ~incidencia:numero ~accion_final:(`Assoc [ ("tipo", `String "ninguna"); ("derivado", `Bool true) ]) [ Textos.agente_caido_ya_abierta ~numero ])
        | Error _ -> Lwt.return (Acciones.efecto ~accion_final:(`Assoc [ ("tipo", `String "ninguna"); ("derivado", `Bool false) ]) [ Textos.agente_caido_sin_incidencia ]))
    | _ -> (
        let p =
          { Acciones.tipo = "incidente"; categoria = "otro"; impacto = "persona"; urgencia = "media";
            titulo = "Mensaje sin atender: el asistente no estuvo disponible"; resumen = Casos.recortar 500 texto_guardar; motivo = "sin_articulo" }
        in
        let* ef = Acciones.abrir_incidencia ctx ~caso ~persona_id ~p ~queja:false ~frase:None in
        match ef.incidencia with
        | Some numero -> Lwt.return { ef with textos = [ Textos.agente_caido_con_incidencia ~numero ] }
        | None -> Lwt.return { ef with textos = [ Textos.agente_caido_sin_incidencia ] })
  in
  let* () =
    Db.tx ctx.db (fun c ->
        let* _ = Casos.agregar_mensaje ~con_texto c ~caso_id:caso.id ~rol:"sistema" ~texto:(String.concat "\n\n" efecto.textos) ~meta:(`Assoc [ ("respaldo", `String "agente_caido") ]) in
        match efecto.estado_caso with Some st -> Casos.guardar c ~caso_id:caso.id ~estado:st () | None -> Lwt.return ())
  in
  Ctx.publicar ctx "mensaje" (`Assoc [ ("caso_id", `Int caso.id) ]);
  Lwt.return
    { Turno.textos = efecto.textos; caso_id = Some caso.id; incidencia = efecto.incidencia;
      analisis = `Assoc [ ("etapa", `String caso.etapa); ("memoria", caso.memoria); ("intencion", `String ""); ("confianza", `Float 0.); ("categoria", `Null);
                          ("categoria_confianza", `Null); ("accion", efecto.accion_final); ("articulos_usados", `List []);
                          ("senales", `Assoc [ ("animo", `String "neutro"); ("queja", `Bool false); ("pide_tecnico", `Bool false); ("contrasena_oculta", `Bool false) ]);
                          ("juez", `Assoc [ ("modo", `String "apagado"); ("veredictos", `Assoc []) ]); ("latencia_ms", `Int 0); ("agente_caido", `Bool true) ];
      botones = []; duplicado = false; pausado = false; derivado = true }

(* La persona escribe y un tecnico tiene la conversacion: el asistente NO responde; el mensaje queda en el caso y, si hay
   una incidencia abierta, llega a ella. *)
let turno_pausado (ctx : Ctx.t) (e : Webhook.entrante) ~(caso : Casos.caso) ~(persona_id : int) ~(texto : string) : Turno.resultado Lwt.t =
  let texto_guardar = Mascara.ocultar_credenciales texto in
  let* () =
    Db.tx ctx.db (fun c ->
        let* _ =
          Casos.agregar_mensaje ~con_texto:ctx.cfg.analitica_texto c ~caso_id:caso.id ~rol:"usuario" ~texto:texto_guardar
            ~meta:(Json.sin_nulos (`Assoc [ ("wa_id", Json.opt_string e.msg_id); ("pausado", `Bool true) ]))
        in
        Lwt.return ())
  in
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ()) in
  let* numero =
    match actual with
    | Some inc when Acciones.abierta inc ->
        let id = Json.int_d "id" 0 inc and numero = Json.str_d "numero" "" inc in
        (* Si la incidencia esperaba a la persona, su respuesta reanuda el reloj; despues, el mensaje como comentario publico. *)
        let* () =
          if Json.str_d "estado" "" inc = "espera_usuario" then
            let* r = Motor.accion ctx.motor ~id (`Assoc [ ("accion", `String "reanudar"); ("actor", Acciones.actor_usuario persona_id) ]) in
            (match r with Error f -> Acciones.avisar_fallo_motor "reanudar" f | Ok _ -> ());
            Lwt.return ()
          else Lwt.return ()
        in
        let* r =
          Motor.accion ctx.motor ~id
            (`Assoc [ ("accion", `String "comentar"); ("texto", `String (Casos.recortar 2000 texto_guardar)); ("interno", `Bool false); ("actor", Acciones.actor_usuario persona_id) ])
        in
        (match r with
        | Error f -> Acciones.avisar_fallo_motor "comentar" f
        | Ok _ -> Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String numero) ]));
        Lwt.return (Some numero)
    | _ -> Lwt.return None
  in
  Ctx.publicar ctx "mensaje" (`Assoc [ ("caso_id", `Int caso.id) ]);
  Lwt.return { Turno.resultado_vacio with caso_id = Some caso.id; incidencia = numero; pausado = true }

let turno_no_texto (ctx : Ctx.t) (e : Webhook.entrante) ~(caso : Casos.caso) ~(tipo : string) : Turno.resultado Lwt.t =
  let marca = Printf.sprintf "[%s recibido]" tipo in
  let aviso = Textos.no_texto tipo in
  let* () =
    Db.tx ctx.db (fun c ->
        let con_texto = ctx.cfg.analitica_texto in
        let* _ = Casos.agregar_mensaje ~con_texto c ~caso_id:caso.id ~rol:"usuario" ~texto:marca ~meta:(Json.sin_nulos (`Assoc [ ("wa_id", Json.opt_string e.msg_id); ("tipo", `String tipo) ])) in
        if caso.pausado then Lwt.return ()
        else
          let* _ = Casos.agregar_mensaje ~con_texto c ~caso_id:caso.id ~rol:"sistema" ~texto:aviso ~meta:(`Assoc [ ("respaldo", `String "no_texto") ]) in
          Lwt.return ())
  in
  Ctx.publicar ctx "mensaje" (`Assoc [ ("caso_id", `Int caso.id) ]);
  Lwt.return { Turno.resultado_vacio with caso_id = Some caso.id; textos = (if caso.pausado then [] else [ aviso ]); pausado = caso.pausado }

let turno_asistente (ctx : Ctx.t) (e : Webhook.entrante) ~(caso : Casos.caso) ~(persona_id : int) ~(texto : string) : Turno.resultado Lwt.t =
  let* req = peticion ctx ~caso ~persona_id ~canal:e.canal ~texto in
  let* r = Agente.chat ctx.agente req in
  match r with
  | Agente.Respuesta j -> aplicar_respuesta ctx e ~caso ~persona_id ~texto j
  | Agente.Caido motivo -> respaldo_agente_caido ctx e ~caso ~persona_id ~texto ~motivo

(* --- punto de entrada ---------------------------------------------------------------------------------------------------------- *)

let procesar_sin_candado (ctx : Ctx.t) (e : Webhook.entrante) : Turno.resultado Lwt.t =
  let* duplicado = match e.msg_id with None -> Lwt.return false | Some id -> Db.usar ctx.db (fun c -> Casos.existe_wa c id) in
  if duplicado then Lwt.return { Turno.resultado_vacio with duplicado = true }
  else begin
    let* persona_id, caso =
      Db.tx ctx.db (fun c ->
          let* persona_id =
            match e.canal with
            | "web" -> Casos.persona_web c ~sesion:e.chat_id
            | _ -> Casos.persona_whatsapp c ~chat_id:e.chat_id ~telefono:e.telefono ~nombre:e.nombre
          in
          let* caso = Casos.sesion c ~canal:e.canal ~chat_id:e.chat_id ~persona_id ~sesion_horas:ctx.cfg.sesion_horas in
          Lwt.return (persona_id, caso))
    in
    let persona_id = Option.value caso.persona_id ~default:persona_id in
    match e.contenido with
    | Webhook.No_texto tipo -> turno_no_texto ctx e ~caso ~tipo
    | Webhook.Texto texto -> if caso.pausado then turno_pausado ctx e ~caso ~persona_id ~texto else turno_asistente ctx e ~caso ~persona_id ~texto
  end

(* Procesa un entrante y, si es WhatsApp, encola lo que hay que decirle (en orden, con espaciado). *)
let procesar (ctx : Ctx.t) (e : Webhook.entrante) : Turno.resultado Lwt.t =
  let* r = Ctx.con_candado ctx (e.canal ^ ":" ^ e.chat_id) (fun () -> procesar_sin_candado ctx e) in
  if e.canal = "whatsapp" && r.textos <> [] then ignore (Cola_salida.encolar ctx.salida ~destino:e.chat_id (partes r.textos));
  Lwt.return r

let procesar_web (ctx : Ctx.t) ~(sesion : string) ~(mensaje : string) : Turno.resultado Lwt.t =
  procesar ctx { Webhook.canal = "web"; chat_id = sesion; telefono = None; nombre = ""; msg_id = None; contenido = Webhook.Texto mensaje }
