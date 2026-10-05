(* Ejecucion de la `accion` que propone el agente (CONTRATOS §1). El agente PROPONE; esto DECIDE y ejecuta:
   - lo que cambia una incidencia pasa SIEMPRE por el motor (`Motor`); la pasarela no escribe en `incidencias`;
   - el TEXTO de confirmacion (numero, tecnico, plazo, estado) lo arma el codigo (`Textos`), nunca el LLM;
   - si el motor no responde, no se finge: se le dice a la persona que no se pudo y se deja el rastro. *)

open Turno

let ( let* ) = Lwt.bind

let vocab_tipos = [ "incidente"; "solicitud"; "consulta"; "problema" ]
let vocab_impacto = [ "persona"; "area"; "sede"; "organizacion" ]
let vocab_urgencia = [ "baja"; "media"; "alta"; "critica" ]
let vocab_motivo = [ "guia_agotada"; "p1"; "pidio_tecnico"; "sin_articulo" ]

let elegir lista valor defecto = match valor with Some v when List.mem v lista -> v | _ -> defecto

let actor_usuario persona_id = Motor.actor ~id:(string_of_int persona_id) "usuario"
let actor_asistente = Motor.actor "asistente"

let efecto ?incidencia ?estado_caso ~accion_final textos : efecto = { textos; incidencia; estado_caso; accion_final }

let avisar_fallo_motor contexto (f : Motor.fallo) =
  Dream.warning (fun l -> l "motor: %s fallo (%s)" contexto (Motor.describir_fallo f))

(* Un `avisos` no vacio en la respuesta del motor: hay avisos por enviar, que el trabajador mire ya. *)
let hay_avisos (j : Json.t) = match Json.list "avisos" j with [] -> false | _ -> true

let abierta (inc : Json.t) = Json.str_d "estado" "" inc <> "cerrada"

(* --- propuesta de incidencia ----------------------------------------------------------------------------------- *)

type propuesta = { tipo : string; categoria : string; impacto : string; urgencia : string; titulo : string; resumen : string; motivo : string }

let propuesta_de (r : respuesta_agente) ~(titulo_defecto : string) ~(motivo : string option) ~(motivo_defecto : string) : propuesta =
  let ip = Json.obj "incidencia" r.accion in
  let cat = match Json.str "categoria" ip with Some c -> Some c | None -> r.categoria in
  { tipo = elegir vocab_tipos (Json.str "tipo" ip) "incidente";
    categoria = elegir Casos.categorias cat "otro";
    impacto = elegir vocab_impacto (Json.str "impacto" ip) "persona";
    urgencia = elegir vocab_urgencia (Json.str "urgencia" ip) "media";
    titulo = (match Json.str_ne "titulo" ip with Some t -> Casos.recortar 200 t | None -> titulo_defecto);
    resumen = Casos.recortar 2000 (Json.str_d "resumen" "" ip);
    motivo = (match motivo with Some m -> m | None -> elegir vocab_motivo (Json.str "motivo" ip) motivo_defecto) }

(* --- abrir una incidencia (o agregar a la que ya existe) ------------------------------------------------------------ *)

let abrir_incidencia (ctx : Ctx.t) ~(caso : Casos.caso) ~(persona_id : int) ~(p : propuesta) ~(queja : bool) ~(frase : string option) : efecto Lwt.t =
  let base = ctx.cfg.base_url_publica in
  let ahora = Ctx.ahora ctx in
  let con_frase fijo = match frase with Some f -> [ f; fijo ] | None -> [ fijo ] in
  let* dup = Motor.duplicada ctx.motor ~persona_id ~categoria:p.categoria in
  match dup with
  | Error f ->
      avisar_fallo_motor "duplicada" f;
      Lwt.return (efecto ~accion_final:(`Assoc [ ("tipo", `String "crear_incidencia"); ("error", `String "motor_no_responde") ]) [ Textos.incidencia_no_registrada ])
  | Ok j -> (
      match Json.get "incidencia" j with
      | `Assoc _ as inc ->
          (* Ya hay una abierta del mismo tema: se agrega el dato en vez de abrir otra. *)
          let id = Json.int_d "id" 0 inc and numero = Json.str_d "numero" "" inc in
          let dato = Casos.recortar 500 (if p.resumen = "" then p.titulo else p.titulo ^ ". " ^ p.resumen) in
          let* r =
            Motor.accion ctx.motor ~id
              (`Assoc [ ("accion", `String "agregar_dato"); ("actor", actor_asistente); ("clave", `String "reporte_repetido"); ("valor", `String dato) ])
          in
          let agregado = match r with Ok _ -> true | Error f -> avisar_fallo_motor "agregar_dato" f; false in
          if agregado then Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String numero) ]);
          Lwt.return
            (efecto ~incidencia:numero ~estado_caso:"con_incidencia"
               ~accion_final:(`Assoc [ ("tipo", `String "agregar_dato"); ("numero", `String numero); ("duplicada", `Bool true) ])
               (con_frase (Textos.incidencia_duplicada ~base_url:base ~agregado ~inc)))
      | _ -> (
          let cuerpo =
            `Assoc
              ([ ("persona_id", `Int persona_id); ("caso_id", `Int caso.id); ("tipo", `String p.tipo); ("categoria", `String p.categoria);
                 ("impacto", `String p.impacto); ("urgencia", `String p.urgencia); ("titulo", `String p.titulo); ("resumen", `String p.resumen);
                 ("canal", `String caso.canal); ("motivo", `String p.motivo); ("actor", actor_asistente) ]
              @ if queja then [ ("queja", `Bool true) ] else [])
          in
          let* r = Motor.crear_incidencia ctx.motor cuerpo in
          match r with
          | Error f ->
              avisar_fallo_motor "crear_incidencia" f;
              Lwt.return (efecto ~accion_final:(`Assoc [ ("tipo", `String "crear_incidencia"); ("error", `String "no_se_pudo") ]) [ Textos.incidencia_no_registrada ])
          | Ok j ->
              let inc = Json.obj "incidencia" j and asignacion = Json.obj "asignacion" j in
              let numero = Json.str_d "numero" "" inc and id = Json.int_d "id" 0 inc in
              (* Sin `asignacion` explicita, «en cola» es no tener tecnico. *)
              let asignacion = if Json.get "en_cola" asignacion = `Null then Json.set "en_cola" (`Bool (Json.str "tecnico" inc = None)) asignacion else asignacion in
              Ctx.publicar ctx "incidencia_creada" (`Assoc [ ("id", `Int id); ("numero", `String numero) ]);
              if hay_avisos j then Ctx.despertar ctx;
              Lwt.return
                (efecto ~incidencia:numero ~estado_caso:"con_incidencia"
                   ~accion_final:
                     (`Assoc
                       [ ("tipo", `String "crear_incidencia"); ("numero", `String numero);
                         ("incidencia", `Assoc [ ("motivo", `String p.motivo); ("categoria", `String p.categoria); ("titulo", `String p.titulo) ]) ])
                   (con_frase (Textos.incidencia_creada ~ahora ~base_url:base ~inc ~asignacion)))))

(* --- cada accion --------------------------------------------------------------------------------------------------- *)

let crear (ctx : Ctx.t) ~caso ~persona_id (r : respuesta_agente) ~(texto_guardar : string) : efecto Lwt.t =
  let p = propuesta_de r ~titulo_defecto:(Casos.recortar 80 texto_guardar) ~motivo:None ~motivo_defecto:"sin_articulo" in
  abrir_incidencia ctx ~caso ~persona_id ~p ~queja:(hay_queja r) ~frase:r.respuesta

let pedir_tecnico (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id (r : respuesta_agente) ~texto_guardar : efecto Lwt.t =
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ()) in
  match actual with
  | Some inc when abierta inc -> (
      let id = Json.int_d "id" 0 inc and numero = Json.str_d "numero" "" inc in
      let* res =
        Motor.accion ctx.motor ~id
          (`Assoc
            [ ("accion", `String "agregar_dato"); ("actor", actor_usuario persona_id); ("clave", `String "pide_tecnico");
              ("valor", `String "La persona pide hablar con un técnico.") ])
      in
      match res with
      | Ok j ->
          Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String numero) ]);
          if hay_avisos j then Ctx.despertar ctx;
          Lwt.return
            (efecto ~incidencia:numero ~accion_final:(`Assoc [ ("tipo", `String "pedir_tecnico"); ("numero", `String numero) ])
               [ Textos.pide_tecnico_con_incidencia ~numero ])
      | Error f ->
          avisar_fallo_motor "pedir_tecnico" f;
          Lwt.return (efecto ~accion_final:(`Assoc [ ("tipo", `String "pedir_tecnico"); ("error", `String "motor_no_responde") ]) [ Textos.no_pude_avisar ]))
  | _ ->
      let p = propuesta_de r ~titulo_defecto:"Solicitud de atención por un técnico" ~motivo:(Some "pidio_tecnico") ~motivo_defecto:"pidio_tecnico" in
      let p = if p.titulo = Casos.recortar 80 texto_guardar || p.titulo = "" then { p with titulo = "Solicitud de atención por un técnico" } else p in
      abrir_incidencia ctx ~caso ~persona_id ~p ~queja:(hay_queja r) ~frase:r.respuesta

(* `accion.dato` es el primero y `accion.datos` trae todos los nuevos del mensaje (CONTRATOS «Cambios» del agente, 5): se mandan todos, hasta 6. *)
let datos_de_la_accion (accion : Json.t) : (string * string) list =
  let par d = match (Json.str_ne "clave" d, Json.str_ne "valor" d) with Some k, Some v -> Some (Casos.recortar 80 k, Casos.recortar 500 v) | _ -> None in
  let lista = Option.to_list (par (Json.obj "dato" accion)) @ List.filter_map par (Json.list "datos" accion) in
  let vistos = Hashtbl.create 8 in
  List.filter (fun (k, v) -> if Hashtbl.mem vistos (k, v) then false else (Hashtbl.add vistos (k, v) (); true)) lista |> List.filteri (fun i _ -> i < 6)

let agregar_dato (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id (r : respuesta_agente) : efecto Lwt.t =
  let datos = datos_de_la_accion r.accion in
  let numero = Json.str_ne "numero" r.accion in
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ?numero ()) in
  let texto = match r.respuesta with Some t -> t | None -> "Anotado." in
  match (actual, datos) with
  | Some inc, _ :: _ when abierta inc -> (
      let id = Json.int_d "id" 0 inc and numero = Json.str_d "numero" "" inc in
      let* resultados =
        Lwt_list.map_s
          (fun (clave, valor) ->
            Motor.accion ctx.motor ~id (`Assoc [ ("accion", `String "agregar_dato"); ("actor", actor_asistente); ("clave", `String clave); ("valor", `String valor) ]))
          datos
      in
      let anotados = List.length (List.filter Result.is_ok resultados) in
      List.iter (function Error f -> avisar_fallo_motor "agregar_dato" f | Ok _ -> ()) resultados;
      if anotados > 0 then Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String numero) ]);
      Lwt.return
        (efecto ~incidencia:numero
           ~accion_final:
             (`Assoc
               ([ ("tipo", `String "agregar_dato"); ("numero", `String numero); ("dato", Json.obj "dato" r.accion) ]
               @ if anotados < List.length datos then [ ("error", `String "motor_no_responde") ] else []))
           [ texto ]))
  | _ -> Lwt.return (efecto ~accion_final:(`Assoc [ ("tipo", `String "agregar_dato"); ("aplicada", `Bool false) ]) [ texto ])

let consultar_estado (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id (r : respuesta_agente) : efecto Lwt.t =
  let ahora = Ctx.ahora ctx and base = ctx.cfg.base_url_publica in
  let numero = Json.str_ne "numero" r.accion in
  let* filas =
    Db.usar ctx.db (fun c ->
        match numero with
        | Some _ ->
            let* i = Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ?numero () in
            Lwt.return (Option.to_list i)
        | None -> Casos.incidencias_abiertas_completas c ~persona_id)
  in
  let incidencia = match filas with [ f ] -> Json.str "numero" f | _ -> None in
  let previa = match r.respuesta with Some t when filas <> [] -> [ t ] | _ -> [] in
  Lwt.return
    (efecto ?incidencia
       ~accion_final:(`Assoc (("tipo", `String "consultar_estado") :: (match incidencia with Some n -> [ ("numero", `String n) ] | None -> [])))
       (previa @ [ Textos.consulta_estado ~ahora ~base_url:base filas ]))

let confirmar_solucion (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id ~mensaje_id (r : respuesta_agente) : efecto Lwt.t =
  let numero = Json.str_ne "numero" r.accion in
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ?numero ()) in
  let registrar ?incidencia_id () =
    Db.tx ctx.db (fun c ->
        let* () = Analitica.registrar_feedback c ~caso_id:caso.id ~mensaje_id ?incidencia_id ~senal:"se_resolvio" () in
        Casos.registrar_usos_articulos c ~caso_id:caso.id ~claves:r.articulos ~resultado:"resolvio")
  in
  let fin = Json.str "tipo" r.accion in
  ignore fin;
  match actual with
  | None ->
      (* Sin incidencia: lo resolvio el asistente y la persona lo confirma (contencion). *)
      let* () = registrar () in
      Lwt.return
        (efecto ~estado_caso:"resuelto_asistente" ~accion_final:(`Assoc [ ("tipo", `String "confirmar_solucion") ])
           [ Option.value r.respuesta ~default:"Me alegra que se haya resuelto. Si vuelve a pasar, aquí estoy." ])
  | Some inc when Json.str_d "estado" "" inc = "resuelta" -> (
      let id = Json.int_d "id" 0 inc and num = Json.str_d "numero" "" inc in
      let* res =
        Motor.accion ctx.motor ~id (`Assoc [ ("accion", `String "cerrar"); ("motivo", `String "confirmado"); ("actor", actor_usuario persona_id) ])
      in
      match res with
      | Ok _ ->
          let* () = registrar ~incidencia_id:id () in
          Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String num) ]);
          Lwt.return
            (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "confirmar_solucion"); ("numero", `String num) ])
               ((match r.respuesta with Some t -> [ t ] | None -> []) @ [ Textos.resuelta_confirmada ~numero:num ]))
      | Error f ->
          avisar_fallo_motor "cerrar" f;
          let* () = registrar ~incidencia_id:id () in
          Lwt.return
            (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "confirmar_solucion"); ("numero", `String num); ("error", `String "motor_no_responde") ])
               [ Option.value r.respuesta ~default:"Gracias por confirmarlo. Dejé anotado que ya funciona." ]))
  | Some inc ->
      (* La incidencia sigue abierta (no esta «resuelta»): la persona dice que ya funciona, pero cerrarla es de un tecnico. *)
      let id = Json.int_d "id" 0 inc and num = Json.str_d "numero" "" inc in
      let* res =
        Motor.accion ctx.motor ~id
          (`Assoc
            [ ("accion", `String "agregar_dato"); ("actor", actor_usuario persona_id); ("clave", `String "usuario_reporta_resuelto");
              ("valor", `String "La persona indica que ya funciona; falta que un técnico la resuelva.") ])
      in
      (match res with Error f -> avisar_fallo_motor "agregar_dato" f | Ok _ -> Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String num) ]));
      let* () = registrar ~incidencia_id:id () in
      Lwt.return
        (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "confirmar_solucion"); ("numero", `String num) ])
           [ Option.value r.respuesta ~default:(Printf.sprintf "Qué bueno. Dejé anotado en tu incidencia %s que ya funciona; un técnico confirmará el cierre." num) ])

let sigue_igual (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id ~mensaje_id (r : respuesta_agente) : efecto Lwt.t =
  let numero = Json.str_ne "numero" r.accion in
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ?numero ()) in
  let feedback ?incidencia_id senal =
    Db.tx ctx.db (fun c ->
        let* () = Analitica.registrar_feedback c ~caso_id:caso.id ~mensaje_id ?incidencia_id ~senal () in
        Casos.registrar_usos_articulos c ~caso_id:caso.id ~claves:r.articulos ~resultado:"sigue_igual")
  in
  match actual with
  | Some inc when Json.str_d "estado" "" inc = "resuelta" -> (
      let id = Json.int_d "id" 0 inc and num = Json.str_d "numero" "" inc in
      let* res =
        Motor.accion ctx.motor ~id
          (`Assoc [ ("accion", `String "reabrir"); ("motivo", `String "La persona indica que el problema sigue igual."); ("actor", actor_usuario persona_id) ])
      in
      match res with
      | Ok j ->
          let* () = feedback ~incidencia_id:id "reapertura" in
          Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String num) ]);
          if hay_avisos j then Ctx.despertar ctx;
          Lwt.return (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "sigue_igual"); ("numero", `String num); ("reabierta", `Bool true) ]) [ Textos.reabierta ~numero:num ])
      | Error f ->
          avisar_fallo_motor "reabrir" f;
          Lwt.return (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "sigue_igual"); ("error", `String "motor_no_responde") ]) [ Textos.no_pude_avisar ]))
  | Some inc when abierta inc -> (
      let id = Json.int_d "id" 0 inc and num = Json.str_d "numero" "" inc in
      let* res =
        Motor.accion ctx.motor ~id
          (`Assoc [ ("accion", `String "agregar_dato"); ("actor", actor_usuario persona_id); ("clave", `String "sigue_igual"); ("valor", `String "La persona indica que el problema continúa.") ])
      in
      match res with
      | Ok _ ->
          let* () = feedback ~incidencia_id:id "sigue_igual" in
          Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", `String num) ]);
          Lwt.return (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "sigue_igual"); ("numero", `String num) ]) [ Textos.sigue_igual_con_abierta ~numero:num ])
      | Error f ->
          avisar_fallo_motor "agregar_dato" f;
          Lwt.return (efecto ~incidencia:num ~accion_final:(`Assoc [ ("tipo", `String "sigue_igual"); ("error", `String "motor_no_responde") ]) [ Textos.no_pude_avisar ]))
  | _ ->
      (* Sigue igual tras una guia, sin incidencia: se anota y el asistente decide el siguiente paso (otra guia o abrirla). *)
      let* () = feedback "sigue_igual" in
      Lwt.return (efecto ~accion_final:(`Assoc [ ("tipo", `String "sigue_igual") ]) [ Option.value r.respuesta ~default:Textos.respuesta_vacia ])

let encuesta (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id ~mensaje_id (r : respuesta_agente) : efecto Lwt.t =
  let puntaje = match Json.int "puntaje" r.accion with Some n when n >= 1 && n <= 5 -> Some n | _ -> None in
  match puntaje with
  | None ->
      Dream.warning (fun l -> l "encuesta sin puntaje valido del agente (caso %d)" caso.id);
      Lwt.return (efecto ~accion_final:(`Assoc [ ("tipo", `String "encuesta"); ("aplicada", `Bool false) ]) [ Option.value r.respuesta ~default:Textos.respuesta_vacia ])
  | Some n ->
      let* inc =
        Db.usar ctx.db (fun c ->
            Db.fila c
              "SELECT id, numero FROM incidencias WHERE persona_id = $i:p AND (caso_id = $i:caso OR estado <> 'cerrada' OR cerrada_en > now() - interval '1 day') ORDER BY (caso_id = $i:caso) DESC NULLS LAST, id DESC LIMIT 1"
              (`Assoc [ ("p", `Int persona_id); ("caso", `Int caso.id) ]))
      in
      let incidencia_id = Json.int "id" inc in
      let comentario = Option.map Mascara.ocultar_credenciales (Json.str_ne "comentario" r.accion) in
      let* () =
        Db.tx ctx.db (fun c ->
            let* _ = Analitica.responder_encuesta c ?incidencia_id ~caso_id:caso.id ?comentario ~puntaje:n () in
            Analitica.registrar_feedback c ~caso_id:caso.id ~mensaje_id ?incidencia_id ~senal:"encuesta" ~valor:(string_of_int n) ())
      in
      (* Un caso que el asistente resolvio (contencion) se queda en `resuelto_asistente`; el resto se cierra. *)
      Lwt.return
        (efecto ?incidencia:(Json.str "numero" inc) ?estado_caso:(if caso.estado = "resuelto_asistente" then None else Some "cerrado")
           ~accion_final:(`Assoc [ ("tipo", `String "encuesta"); ("puntaje", `Int n) ])
           [ Option.value r.respuesta ~default:Textos.encuesta_gracias ])

let ninguna (r : respuesta_agente) : efecto =
  efecto ~accion_final:(`Assoc [ ("tipo", `String "ninguna") ]) [ (match r.respuesta with Some t -> t | None -> Textos.respuesta_vacia) ]

(* Una queja explicita (o animo muy negativo) sobre una incidencia abierta: el motor deja el evento `queja`, que la regla del vigia
   convierte en un aviso al supervisor. Si el turno ya abrio la incidencia, la queja viaja en `queja: true` y esto no se llama. *)
let registrar_queja (ctx : Ctx.t) ~(caso : Casos.caso) ~persona_id ~(texto : string) : unit Lwt.t =
  let* actual = Db.usar ctx.db (fun c -> Casos.incidencia_actual c ~caso_id:caso.id ~persona_id ()) in
  match actual with
  | Some inc when abierta inc ->
      let id = Json.int_d "id" 0 inc in
      let* r = Motor.accion ctx.motor ~id (`Assoc [ ("accion", `String "queja"); ("texto", `String (Casos.recortar 500 texto)); ("actor", actor_usuario persona_id) ]) in
      (match r with
      | Ok j ->
          Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", Json.get "numero" inc) ]);
          if hay_avisos j then Ctx.despertar ctx
      | Error f -> avisar_fallo_motor "queja" f);
      Lwt.return ()
  | _ -> Lwt.return ()

let ejecutar (ctx : Ctx.t) ~(caso : Casos.caso) ~(persona_id : int) ~(mensaje_id : int) ~(texto_guardar : string) (r : respuesta_agente) : efecto Lwt.t =
  match r.accion_tipo with
  | "crear_incidencia" -> crear ctx ~caso ~persona_id r ~texto_guardar
  | "pedir_tecnico" -> pedir_tecnico ctx ~caso ~persona_id r ~texto_guardar
  | "agregar_dato" -> agregar_dato ctx ~caso ~persona_id r
  | "consultar_estado" -> consultar_estado ctx ~caso ~persona_id r
  | "confirmar_solucion" -> confirmar_solucion ctx ~caso ~persona_id ~mensaje_id r
  | "sigue_igual" -> sigue_igual ctx ~caso ~persona_id ~mensaje_id r
  | "encuesta" -> encuesta ctx ~caso ~persona_id ~mensaje_id r
  | _ -> Lwt.return (ninguna r)
