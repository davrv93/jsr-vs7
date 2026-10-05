(* Agente falso (CONTRATOS §1). `responder` recibe la peticion ya parseada y devuelve (estado HTTP, JSON). Por defecto
   contesta con reglas simples por palabras clave, suficientes para recorrer el flujo completo; una prueba puede
   reemplazar `responder` para guionar una respuesta exacta. Guarda cada peticion para que la prueba verifique el
   contrato. *)

open Pasarela

type t = {
  mutable recibidas : Json.t list; (* la mas reciente primero *)
  mutable responder : Json.t -> int * Json.t;
  mutable demora : float; (* segundos antes de contestar, para probar el plazo *)
  mutable reentrenar : Json.t -> Json.t; (* respuesta de POST /reentrenar *)
  mutable articulos : (int * Json.t) option; (* respuesta de GET /conocimiento/articulos: (estado, cuerpo); None = 404 como un agente viejo *)
  mutable modelos : Json.t list; (* versiones que conoce el agente *)
  mutable actual : string;
  mutable publicar_modelo : string -> int * Json.t; (* respuesta de POST /modelos/{version}/publicar *)
}

let minusculas s = String.lowercase_ascii s

let contiene sub s =
  let s = minusculas s and sub = minusculas sub in
  let n = String.length s and m = String.length sub in
  let rec desde i = i + m <= n && (String.sub s i m = sub || desde (i + 1)) in
  m = 0 || desde 0

let base ?(texto_guardar = "") ~respuesta ~etapa ~memoria ~intencion ~confianza ?(categoria = "otro") ?(accion = `Assoc [ ("tipo", `String "ninguna") ]) ?(articulos = []) () : Json.t =
  `Assoc
    ([ ("respuesta", match respuesta with Some r -> `String r | None -> `Null); ("etapa", `String etapa); ("memoria", memoria);
       ("intencion", `String intencion); ("confianza", `Float confianza); ("categoria", `String categoria); ("categoria_confianza", `Float 0.88);
       ("accion", accion); ("articulos_usados", `List (List.map (fun a -> `String a) articulos));
       ("senales", `Assoc [ ("animo", `String "neutro"); ("queja", `Bool false); ("pide_tecnico", `Bool false); ("contrasena_oculta", `Bool false) ]);
       ("juez", `Assoc [ ("modo", `String "sombra"); ("veredictos", `Assoc [ ("respaldo", `Assoc [ ("veredicto", `String "respaldada"); ("confianza", `Float 0.93) ]) ]) ]);
       ("latencia_ms", `Int 420); ("regenerada", `Bool false); ("frases_quitadas", `Int 0); ("costo_usd", `Float 0.0012) ]
    @ if texto_guardar = "" then [] else [ ("texto_usuario_guardar", `String texto_guardar) ])

let mem_con k v (m : Json.t) = Json.set k v m

(* Reglas por defecto: un asistente de soporte de juguete. *)
let por_defecto (p : Json.t) : int * Json.t =
  let msg = Json.str_d "mensaje" "" p in
  let etapa = Json.str_d "etapa" "recepcion" p in
  let memoria = match Json.get "memoria" p with `Assoc _ as m -> m | _ -> `Assoc [] in
  let pendiente = Json.str_d "pendiente" "" memoria in
  let guardar =
    if contiene "contraseña es" msg || contiene "clave es" msg then Mascara.ocultar_credenciales msg else ""
  in
  let r =
    if guardar <> "" then
      base ~texto_guardar:guardar ~respuesta:(Some "No compartas tu contraseña por aquí; ya la oculté. Cuéntame qué pasó al entrar.") ~etapa:"diagnostico" ~memoria ~intencion:"restablecer_clave" ~confianza:0.9 ~categoria:"cuentas_accesos" ()
    else if contiene "técnico" msg || contiene "tecnico" msg then
      base ~respuesta:(Some "Claro, te paso con una persona.") ~etapa:"incidencia" ~memoria ~intencion:"pedir_tecnico" ~confianza:0.95
        ~accion:(`Assoc [ ("tipo", `String "pedir_tecnico"); ("incidencia", `Assoc [ ("tipo", `String "incidente"); ("categoria", `String "otro"); ("impacto", `String "persona"); ("urgencia", `String "media"); ("titulo", `String "Solicitud de atención por un técnico"); ("resumen", `String "La persona pidió hablar con un técnico."); ("motivo", `String "pidio_tecnico") ]) ]) ()
    else if contiene "estado" msg || contiene "ticket" msg || contiene "cómo va" msg then
      base ~respuesta:None ~etapa:"consulta_estado" ~memoria ~intencion:"consultar_estado" ~confianza:0.9 ~accion:(`Assoc [ ("tipo", `String "consultar_estado") ]) ()
    else if pendiente = "puntaje" && String.length (String.trim msg) = 1 && String.trim msg >= "1" && String.trim msg <= "5" then
      base ~respuesta:None ~etapa:"encuesta" ~memoria:(mem_con "pendiente" `Null memoria) ~intencion:"aportar_dato" ~confianza:0.9
        ~accion:(`Assoc [ ("tipo", `String "encuesta"); ("puntaje", `Int (int_of_string (String.trim msg))) ]) ()
    else if contiene "sigue igual" msg then
      let intentos = Json.int_d "intentos_guia" 0 memoria in
      if intentos >= 1 then
        base ~respuesta:(Some "Entiendo. Voy a registrarlo para que te ayude una persona.") ~etapa:"incidencia" ~memoria:(mem_con "intentos_guia" (`Int (intentos + 1)) memoria) ~intencion:"sigue_igual" ~confianza:0.94
          ~categoria:"correo"
          ~accion:(`Assoc [ ("tipo", `String "crear_incidencia"); ("incidencia", `Assoc [ ("tipo", `String "incidente"); ("categoria", `String "correo"); ("impacto", `String "persona"); ("urgencia", `String "media"); ("titulo", `String "Outlook no recibe correos"); ("resumen", `String "Desde esta mañana Outlook no recibe correos. Probó reiniciar y cerrar sesión."); ("motivo", `String "guia_agotada") ]) ]) ()
      else
        base ~respuesta:(Some "Lamento que siga igual. ¿Abro una incidencia?") ~etapa:"guia" ~memoria:(mem_con "pendiente" (`String "ofrecer_tecnico") (mem_con "intentos_guia" (`Int (intentos + 1)) memoria)) ~intencion:"sigue_igual" ~confianza:0.94 ~categoria:"correo"
          ~accion:(`Assoc [ ("tipo", `String "sigue_igual") ]) ~articulos:[ "KB-031" ] ()
    else if contiene "se resolvió" msg || contiene "ya funcionó" msg || contiene "ya funciono" msg then
      base ~respuesta:(Some "Me alegra. ¿Del 1 al 5, qué nota nos pones?") ~etapa:"encuesta" ~memoria:(mem_con "pendiente" (`String "puntaje") memoria) ~intencion:"confirmar_solucion" ~confianza:0.93
        ~accion:(`Assoc [ ("tipo", `String "confirmar_solucion") ]) ~articulos:[ "KB-031" ] ()
    else if contiene "correo" msg || contiene "outlook" msg then
      if Json.str "sintoma" memoria = None && etapa = "recepcion" then
        base ~respuesta:(Some "Entiendo, vamos a revisarlo. ¿En qué equipo te pasa y desde cuándo?") ~etapa:"diagnostico"
          ~memoria:(mem_con "pendiente" (`String "desde") (mem_con "sintoma" (`String "correo no sincroniza") memoria)) ~intencion:"reportar_falla" ~confianza:0.93 ~categoria:"correo" ()
      else
        base ~respuesta:(Some "Prueba lo siguiente:\n1. Cierra Outlook por completo y ábrelo otra vez.\n2. Cierra sesión y vuelve a entrar.\n\n¿Se resolvió?") ~etapa:"guia"
          ~memoria:(mem_con "pendiente" (`String "resolvio") (mem_con "intentos_guia" (`Int 1) memoria)) ~intencion:"reportar_falla" ~confianza:0.93 ~categoria:"correo" ~articulos:[ "KB-031" ] ()
    else if contiene "hola" msg then
      base ~respuesta:(Some "¡Hola! Soy el asistente de la mesa de ayuda. Cuéntame qué está pasando.") ~etapa:"recepcion" ~memoria ~intencion:"saludo" ~confianza:0.96 ()
    else base ~respuesta:(Some "No estoy seguro de haberte entendido. ¿Puedes contarme con otras palabras qué problema tienes?") ~etapa ~memoria ~intencion:"fuera_de_alcance" ~confianza:0.38 ()
  in
  (200, r)

(* Como el agente real: entrena, mide y publica solo si no empeora. Por defecto, una version peor que la publicada (no se publica). *)
let reentrenar_peor (j : Json.t) : Json.t =
  `Assoc
    [ ("ok", `Bool true); ("modelo", `String "v2"); ("publicado", `Bool false); ("actual", `String "v1");
      ("intencion", `Assoc [ ("exactitud", `Float 0.90); ("f1_macro", `Float 0.89); ("antes", `Float 0.95) ]);
      ("categoria", `Assoc [ ("exactitud", `Float 0.9); ("f1_macro", `Float 0.9); ("antes", `Float 0.9) ]);
      ("ejemplos_extra", `Int (List.length (Json.list "ejemplos" j))); ("motivo", `String "no mejora el conjunto reservado: no se publica") ]

let articulos_de_ejemplo : Json.t =
  `Assoc
    [ ( "articulos",
        `List
          [ `Assoc [ ("clave", `String "KB-001"); ("titulo", `String "Outlook no sincroniza los correos nuevos"); ("categoria", `String "correo"); ("sintomas", `List [ `String "el correo no sincroniza" ]);
                     ("pasos", `List [ `String "Cierra Outlook."; `String "Ábrelo otra vez." ]); ("cuerpo", `String "") ];
            `Assoc [ ("clave", `String "KB-002"); ("titulo", `String "La impresora no imprime"); ("categoria", `String "impresoras"); ("sintomas", `List []); ("pasos", `List [ `String "Reinicia la impresora." ]); ("cuerpo", `String "") ];
            `Assoc [ ("clave", `String "KB-003"); ("titulo", `String "Sin pasos: no se importa"); ("categoria", `String "otro"); ("pasos", `List []) ] ] ) ]

let crear () : t =
  { recibidas = []; responder = por_defecto; demora = 0.; reentrenar = reentrenar_peor; articulos = None;
    modelos = [ `Assoc [ ("version", `String "v1"); ("publicado", `Bool true); ("intencion", `Assoc [ ("exactitud", `Float 0.95); ("f1_macro", `Float 0.94) ]) ] ];
    actual = "v1"; publicar_modelo = (fun _ -> (200, `Assoc [ ("ok", `Bool true); ("publicado", `Bool true) ])) }

let handler (t : t) : Dream.handler =
  Dream.router
    [ Dream.post "/chat" (fun req ->
          let ( let* ) = Lwt.bind in
          let* cuerpo = Dream.body req in
          match Json.parse cuerpo with
          | Error _ -> Servidor.json_lwt ~status:`Bad_Request (`Assoc [ ("error", `String "JSON no valido") ])
          | Ok j ->
              t.recibidas <- j :: t.recibidas;
              let* () = if t.demora > 0. then Lwt_unix.sleep t.demora else Lwt.return () in
              let estado, cuerpo = t.responder j in
              Servidor.json_lwt ~status:(Dream.int_to_status estado) cuerpo);
      Dream.get "/salud" (fun _ -> Servidor.json_lwt (`Assoc [ ("ok", `Bool true); ("modelo", `String "v1"); ("juez", `String "apagado") ]));
      Dream.post "/conocimiento/recargar" (fun req ->
          let ( let* ) = Lwt.bind in
          let* cuerpo = Dream.body req in
          t.recibidas <- (match Json.parse cuerpo with Ok j -> Json.set "_ruta" (`String "/conocimiento/recargar") j | Error _ -> `Null) :: t.recibidas;
          Servidor.json_lwt (`Assoc [ ("ok", `Bool true) ]));
      Dream.post "/reentrenar" (fun req ->
          let ( let* ) = Lwt.bind in
          let* cuerpo = Dream.body req in
          let j = match Json.parse cuerpo with Ok j -> j | Error _ -> `Null in
          t.recibidas <- Json.set "_ruta" (`String "/reentrenar") j :: t.recibidas;
          let r = t.reentrenar j in
          (* Como el agente nuevo: con publicar=false solo mide; el candidato queda en GET /modelos. *)
          (match Json.str "modelo" r with
          | Some v when not (List.exists (fun m -> Json.str "version" m = Some v) t.modelos) ->
              t.modelos <- t.modelos @ [ `Assoc [ ("version", `String v); ("publicado", `Bool (Json.bool_d "publicado" false r)); ("intencion", Json.obj "intencion" r) ] ]
          | _ -> ());
          Servidor.json_lwt r);
      Dream.get "/conocimiento/articulos" (fun _ ->
          match t.articulos with None -> Servidor.json_lwt ~status:`Not_Found (`Assoc [ ("error", `String "no existe") ]) | Some (e, j) -> Servidor.json_lwt ~status:(Dream.int_to_status e) j);
      Dream.get "/modelos" (fun _ ->
          Servidor.json_lwt
            (`Assoc [ ("actual", `String t.actual); ("modelos", `List (List.map (fun m -> Json.set "publicado" (`Bool (Json.str "version" m = Some t.actual)) m) t.modelos)) ]));
      Dream.post "/modelos/:version/publicar" (fun req ->
          let v = Dream.param req "version" in
          t.recibidas <- `Assoc [ ("_ruta", `String "/modelos/publicar"); ("version", `String v) ] :: t.recibidas;
          let e, j = t.publicar_modelo v in
          if e >= 200 && e < 300 && Json.bool_d "publicado" true j then t.actual <- v;
          Servidor.json_lwt ~status:(Dream.int_to_status e) j) ]

let peticiones_chat (t : t) = List.rev (List.filter (fun j -> Json.str "_ruta" j = None) t.recibidas)
