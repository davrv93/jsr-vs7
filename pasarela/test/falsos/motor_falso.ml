(* Motor falso (CONTRATOS §5): una maquina de estados minima sobre las MISMAS tablas que lee la pasarela
   (incidencias, incidencia_eventos, avisos). No calcula SLA reales: devuelve porcentajes a partir de las fechas de
   vencimiento que el mismo escribe. Sirve para probar a la pasarela de punta a punta sin el motor Go. *)

open Pasarela

let ( let* ) = Lwt.bind

type t = {
  db : Db.t;
  clave : string;
  mutable llamadas : (string * string * Json.t) list; (* (metodo, ruta, cuerpo), la mas reciente primero *)
  mutable caido : bool; (* responde 503 a todo *)
  mutable sin_tecnicos : bool; (* toda incidencia nueva queda en cola *)
  mutable golden_calidad : bool; (* las golden de calidad y contencion traen cifras *)
  mutable sql_en_golden : bool; (* el resultado de la golden de mttr trae `sql` *)
}

let crear ~(db : Db.t) ~(clave : string) : t = { db; clave; llamadas = []; caido = false; sin_tecnicos = false; golden_calidad = false; sql_en_golden = false }

let error ?(status = 400) codigo msg = Servidor.json_ok ~status:(Dream.int_to_status status) (`Assoc [ ("error", `String msg); ("codigo", `String codigo) ])
let invalido msg = error ~status:422 "invalido" msg
let no_encontrado msg = error ~status:404 "no_encontrado" msg
let conflicto msg = error ~status:409 "conflicto" msg

let seleccion =
  "SELECT i.id, i.numero, i.persona_id, i.caso_id, i.tipo, i.impacto, i.urgencia, i.prioridad, i.estado, i.titulo, i.resumen, i.grupo_id, g.nombre AS grupo, "
  ^ "i.tecnico_id, t.nombre AS tecnico, i.nivel, i.reaperturas, i.escalamientos, i.canal, i.token_publico, ca.id AS categoria_id, ca.clave AS categoria, "
  ^ Db.iso "i.creada_en" ^ " AS creada_en, " ^ Db.iso "i.primera_respuesta_en" ^ " AS primera_respuesta_en, " ^ Db.iso "i.resuelta_en" ^ " AS resuelta_en, "
  ^ Db.iso "i.cerrada_en" ^ " AS cerrada_en, " ^ Db.iso "i.vence_respuesta_en" ^ " AS vence_respuesta_en, " ^ Db.iso "i.vence_resolucion_en" ^ " AS vence_resolucion_en, "
  ^ "i.motivo_cierre, " ^ Db.iso "i.actualizada_en" ^ " AS actualizada_en "
  ^ "FROM incidencias i LEFT JOIN categorias ca ON ca.id = i.categoria_id LEFT JOIN grupos g ON g.id = i.grupo_id LEFT JOIN tecnicos t ON t.id = i.tecnico_id "

let incidencia c id = Db.fila c (seleccion ^ "WHERE i.id = $i:id") (`Assoc [ ("id", `Int id) ])

let evento c ~id ~tipo ~(actor : Json.t) ?(datos = `Assoc []) () =
  Db.exec c "INSERT INTO incidencia_eventos (incidencia_id, tipo, actor_tipo, actor_id, datos) VALUES ($i:id, $tipo, $at, $ai, $j:datos)"
    (`Assoc [ ("id", `Int id); ("tipo", `String tipo); ("at", `String (Json.str_d "tipo" "sistema" actor)); ("ai", Json.opt_string (Json.str "id" actor)); ("datos", datos) ])

let prioridad_de ~impacto ~urgencia =
  match (impacto, urgencia) with
  | ("organizacion" | "sede"), "critica" -> "P1"
  | _, "critica" | "organizacion", "alta" -> "P2"
  | _, "baja" -> "P4"
  | _ -> "P3"

let aviso c ~id ~tipo ~dest_id ~plantilla ~clave_aviso =
  let* inc = incidencia c id in
  Db.exec c
    "INSERT INTO avisos (incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, clave) VALUES ($i:id, $tipo, $i:dest, 'whatsapp', $plantilla, $j:datos, $clave) ON CONFLICT (clave) DO NOTHING"
    (`Assoc
      [ ("id", `Int id); ("tipo", `String tipo); ("dest", Json.opt_int dest_id); ("plantilla", `String plantilla); ("clave", `String clave_aviso);
        ( "datos",
          `Assoc
            [ ("numero", Json.get "numero" inc); ("prioridad", Json.get "prioridad" inc); ("titulo", Json.get "titulo" inc);
              ("estado", Json.get "estado" inc); ("categoria", Json.get "categoria" inc); ("grupo", Json.get "grupo" inc);
              ("vence_resolucion_en", Json.get "vence_resolucion_en" inc); ("nota_interna", `String "ESTO NO DEBE SALIR NUNCA") ] ) ])

let crear_incidencia (t : t) (b : Json.t) : Dream.response Lwt.t =
  match Json.str_ne "titulo" b with
  | None -> Lwt.return (invalido "el título es obligatorio")
  | Some titulo ->
      Db.tx t.db (fun c ->
          let categoria = Json.str_d "categoria" "otro" b in
          let impacto = Json.str_d "impacto" "persona" b and urgencia = Json.str_d "urgencia" "media" b in
          let* cat = Db.fila c "SELECT id, grupo_id FROM categorias WHERE clave = $c" (`Assoc [ ("c", `String categoria) ]) in
          let* cat = if cat = `Null then Db.fila c "SELECT id, grupo_id FROM categorias WHERE clave = 'otro'" (`Assoc []) else Lwt.return cat in
          let grupo_id = Json.int "grupo_id" cat in
          let* tecnico =
            if t.sin_tecnicos then Lwt.return `Null
            else
              Db.fila c
                "SELECT t.id FROM tecnicos t JOIN grupo_miembros m ON m.tecnico_id = t.id WHERE m.grupo_id = $i:g AND t.estado = 'activo' ORDER BY t.id LIMIT 1"
                (`Assoc [ ("g", Json.opt_int grupo_id) ])
          in
          let tecnico_id = Json.int "id" tecnico in
          let prio = prioridad_de ~impacto ~urgencia in
          let id =
            Db.insertar c
              ("INSERT INTO incidencias (persona_id, caso_id, tipo, categoria_id, impacto, urgencia, prioridad, estado, titulo, resumen, grupo_id, tecnico_id, canal, "
             ^ "vence_respuesta_en, vence_resolucion_en) VALUES ($i:persona, $i:caso, $tipo, $i:cat, $impacto, $urgencia, $prio, $estado, $titulo, $resumen, $i:grupo, $i:tec, $canal, "
             ^ "now() + interval '30 minutes', now() + interval '8 hours')")
              (`Assoc
                [ ("persona", Json.opt_int (Json.int "persona_id" b)); ("caso", Json.opt_int (Json.int "caso_id" b)); ("tipo", `String (Json.str_d "tipo" "incidente" b));
                  ("cat", Json.get "id" cat); ("impacto", `String impacto); ("urgencia", `String urgencia); ("prio", `String prio);
                  ("estado", `String (if tecnico_id = None then "nueva" else "asignada")); ("titulo", `String titulo); ("resumen", `String (Json.str_d "resumen" "" b));
                  ("grupo", Json.opt_int grupo_id); ("tec", Json.opt_int tecnico_id); ("canal", `String (Json.str_d "canal" "whatsapp" b)) ])
          in
          let* id = id in
          let actor = Json.obj "actor" b in
          let* () = evento c ~id ~tipo:"creada" ~actor ~datos:(`Assoc [ ("motivo", `String (Json.str_d "motivo" "manual" b)) ]) () in
          let* () =
            match tecnico_id with
            | Some tid ->
                let* () = evento c ~id ~tipo:"asignada" ~actor:(`Assoc [ ("tipo", `String "sistema") ]) ~datos:(`Assoc [ ("tecnico_id", `Int tid) ]) () in
                aviso c ~id ~tipo:"tecnico" ~dest_id:(Some tid) ~plantilla:"incidencia_asignada" ~clave_aviso:(Printf.sprintf "asig:%d:0" id)
            | None -> Lwt.return ()
          in
          let* inc = incidencia c id in
          Lwt.return
            (Servidor.json_ok ~status:`Created
               (`Assoc
                 [ ("incidencia", inc);
                   ("asignacion", `Assoc [ ("tecnico_id", Json.opt_int tecnico_id); ("grupo_id", Json.opt_int grupo_id); ("motivo", `String "menor_carga"); ("en_cola", `Bool (tecnico_id = None)) ]);
                   ("avisos", `List (if tecnico_id = None then [] else [ `Assoc [ ("plantilla", `String "incidencia_asignada") ] ])) ])))

let aplicar_accion (t : t) (id : int) (b : Json.t) : Dream.response Lwt.t =
  let accion = Json.str_d "accion" "" b in
  let actor = Json.obj "actor" b in
  Db.tx t.db (fun c ->
      let* inc = incidencia c id in
      if inc = `Null then Lwt.return (no_encontrado "No existe esa incidencia.")
      else begin
        let estado = Json.str_d "estado" "" inc in
        let abierta = not (List.mem estado [ "resuelta"; "cerrada" ]) in
        let cambiar ?(extra = "") nuevo ~ev ?(datos = `Assoc []) () =
          let* () =
            Db.exec c ("UPDATE incidencias SET estado = $nuevo, actualizada_en = now()" ^ extra ^ " WHERE id = $i:id") (`Assoc [ ("nuevo", `String nuevo); ("id", `Int id) ])
          in
          evento c ~id ~tipo:ev ~actor ~datos ()
        in
        let ok () =
          let* inc = incidencia c id in
          Lwt.return (Servidor.json_ok (`Assoc [ ("incidencia", inc); ("avisos", `List []) ]))
        in
        match accion with
        | "asignar" -> (
            match Json.int "tecnico_id" b with
            | None -> Lwt.return (invalido "falta tecnico_id")
            | Some tid ->
                let* tec = Db.fila c "SELECT id, estado FROM tecnicos WHERE id = $i:id" (`Assoc [ ("id", `Int tid) ]) in
                if tec = `Null || Json.str_d "estado" "" tec = "inactivo" then Lwt.return (invalido "el técnico no existe o está inactivo")
                else
                  let* () = Db.exec c "UPDATE incidencias SET tecnico_id = $i:t, estado = CASE WHEN estado = 'nueva' THEN 'asignada' ELSE estado END, actualizada_en = now() WHERE id = $i:id" (`Assoc [ ("t", `Int tid); ("id", `Int id) ]) in
                  let* () = evento c ~id ~tipo:(if Json.int "tecnico_id" inc = None then "asignada" else "reasignada") ~actor ~datos:(`Assoc [ ("tecnico_id", `Int tid) ]) () in
                  let* () = aviso c ~id ~tipo:"tecnico" ~dest_id:(Some tid) ~plantilla:"incidencia_asignada" ~clave_aviso:(Printf.sprintf "asig:%d:%d" id (Random.bits ())) in
                  ok ())
        | "responder" ->
            if Json.str_d "tipo" "" actor <> "tecnico" then Lwt.return (invalido "solo un técnico puede responder")
            else if not abierta then Lwt.return (conflicto "la incidencia no admite respuestas en ese estado")
            else
              let* () =
                Db.exec c
                  "UPDATE incidencias SET primera_respuesta_en = coalesce(primera_respuesta_en, now()), estado = CASE WHEN $b:espera THEN 'espera_usuario' WHEN estado IN ('asignada', 'nueva', 'reabierta') THEN 'en_curso' ELSE estado END, actualizada_en = now() WHERE id = $i:id"
                  (`Assoc [ ("espera", `Bool (Json.bool_d "espera_usuario" false b)); ("id", `Int id) ])
              in
              let* () = evento c ~id ~tipo:(if Json.get "primera_respuesta_en" inc = `Null then "primera_respuesta" else "comentario") ~actor ~datos:(`Assoc [ ("texto", Json.get "texto" b) ]) () in
              ok ()
        | "comentar" | "comentar_interno" ->
            if Json.str_ne "texto" b = None then Lwt.return (invalido "el comentario no puede estar vacío")
            else
              let interno = accion = "comentar_interno" || Json.bool_d "interno" false b in
              let* () = evento c ~id ~tipo:(if interno then "comentario_interno" else "comentario") ~actor ~datos:(`Assoc [ ("texto", Json.get "texto" b) ]) () in
              ok ()
        | "pausar" ->
            let motivo = Json.str_d "motivo" "" b in
            if not (List.mem motivo [ "espera_usuario"; "espera_tercero" ]) then Lwt.return (invalido "motivo de pausa desconocido")
            else if not (List.mem estado [ "en_curso"; "asignada" ]) then Lwt.return (conflicto "solo se pausa una incidencia en curso")
            else let* () = cambiar motivo ~ev:"pausa_inicio" ~datos:(`Assoc [ ("motivo", `String motivo) ]) () in ok ()
        | "reanudar" ->
            if not (List.mem estado [ "espera_usuario"; "espera_tercero" ]) then Lwt.return (conflicto "la incidencia no está en pausa")
            else let* () = cambiar "en_curso" ~ev:"pausa_fin" () in ok ()
        | "resolver" ->
            if not (List.mem estado [ "en_curso"; "asignada"; "reabierta"; "nueva" ]) then Lwt.return (conflicto "no se puede resolver desde ese estado")
            else let* () = cambiar "resuelta" ~extra:", resuelta_en = now()" ~ev:"resuelta" ~datos:(`Assoc [ ("solucion", Json.get "solucion" b) ]) () in ok ()
        | "reabrir" ->
            if estado <> "resuelta" then Lwt.return (conflicto "solo se reabre una incidencia resuelta")
            else let* () = cambiar "reabierta" ~extra:", reaperturas = reaperturas + 1, resuelta_en = NULL" ~ev:"reabierta" () in ok ()
        | "cerrar" ->
            if estado <> "resuelta" then Lwt.return (conflicto "solo se cierra una incidencia resuelta")
            else let* () = cambiar "cerrada" ~extra:", cerrada_en = now(), motivo_cierre = 'confirmado'" ~ev:"cerrada" () in ok ()
        | "escalar" ->
            let* () = Db.exec c "UPDATE incidencias SET escalamientos = escalamientos + 1, actualizada_en = now() WHERE id = $i:id" (`Assoc [ ("id", `Int id) ]) in
            let* () = evento c ~id ~tipo:"escalada" ~actor ~datos:(`Assoc [ ("motivo", Json.get "motivo" b) ]) () in
            ok ()
        | "cambiar_prioridad" ->
            let p = Json.str_d "prioridad" "" b in
            if not (List.mem p [ "P1"; "P2"; "P3"; "P4" ]) then Lwt.return (invalido "prioridad desconocida (use P1, P2, P3 o P4)")
            else
              let* () = Db.exec c "UPDATE incidencias SET prioridad = $p, actualizada_en = now() WHERE id = $i:id" (`Assoc [ ("p", `String p); ("id", `Int id) ]) in
              let* () = evento c ~id ~tipo:"prioridad_cambiada" ~actor ~datos:(`Assoc [ ("de", Json.get "prioridad" inc); ("a", `String p) ]) () in
              ok ()
        | "queja" ->
            let* () = evento c ~id ~tipo:"queja" ~actor ~datos:(`Assoc [ ("texto", Json.get "texto" b) ]) () in
            ok ()
        | "agregar_dato" ->
            if Json.str_ne "clave" b = None then Lwt.return (invalido "la clave del dato es obligatoria")
            else
              let* () = evento c ~id ~tipo:"dato_agregado" ~actor ~datos:(`Assoc [ ("clave", Json.get "clave" b); ("valor", Json.get "valor" b) ]) () in
              ok ()
        | otra -> Lwt.return (invalido ("acción desconocida: " ^ otra))
      end)

let sla_calcular (t : t) (ids : int list) : Dream.response Lwt.t =
  Db.usar t.db (fun c ->
      let* filas =
        Db.lista c
          "SELECT id, estado, extract(epoch FROM (vence_resolucion_en - creada_en)) AS total_s, extract(epoch FROM (now() - creada_en)) AS usado_s, extract(epoch FROM (vence_resolucion_en - now())) AS resto_s FROM incidencias WHERE id IN (SELECT jsonb_array_elements_text($j:ids)::bigint)"
          (`Assoc [ ("ids", `List (List.map (fun i -> `Int i) ids)) ])
      in
      let por_id =
        List.map
          (fun f ->
            let total = Option.value (Json.float "total_s" f) ~default:1. and usado = Option.value (Json.float "usado_s" f) ~default:0. in
            let resto = Option.value (Json.float "resto_s" f) ~default:0. in
            let pct = Float.round (usado /. Float.max total 1. *. 1000.) /. 10. in
            ( string_of_int (Json.int_d "id" 0 f),
              `Assoc
                [ ("porcentaje_respuesta", `Float pct); ("porcentaje_resolucion", `Float pct); ("restante_min", `Int (int_of_float (resto /. 60.)));
                  ("vencida", `Bool (resto < 0.)); ("pausada", `Bool (List.mem (Json.str_d "estado" "" f) [ "espera_usuario"; "espera_tercero" ])) ] ))
          filas
      in
      Lwt.return (Servidor.json_ok (`Assoc por_id)))

let handler (t : t) : Dream.handler =
  let registrar req cuerpo = t.llamadas <- (Dream.method_to_string (Dream.method_ req), Dream.target req, cuerpo) :: t.llamadas in
  let protegido (f : Dream.request -> Dream.response Lwt.t) : Dream.handler =
   fun req ->
    if t.caido then Lwt.return (error ~status:503 "interno" "motor caido (simulado)")
    else
      match Dream.header req "X-Interno-Clave" with
      | Some k when Cripto.igual_const k t.clave -> f req
      | _ -> Lwt.return (error ~status:401 "no_autorizado" "clave interna inválida")
  in
  let con_cuerpo f =
    protegido (fun req ->
        let* s = Dream.body req in
        let j = match Json.parse s with Ok j -> j | Error _ -> `Assoc [] in
        registrar req j;
        f req j)
  in
  Dream.router
    [ Dream.get "/interno/salud" (protegido (fun _ -> Lwt.return (Servidor.json_ok (`Assoc [ ("ok", `Bool true); ("db", `String "ok"); ("clickhouse", `String "apagado"); ("version", `String "falso") ]))));
      Dream.post "/interno/incidencias" (con_cuerpo (fun _ j -> crear_incidencia t j));
      Dream.get "/interno/incidencias/duplicada"
        (protegido (fun req ->
             registrar req `Null;
             match (Option.bind (Dream.query req "persona_id") int_of_string_opt, Dream.query req "categoria") with
             | Some pid, Some cat ->
                 Db.usar t.db (fun c ->
                     let* f =
                       Db.fila c (seleccion ^ "WHERE i.persona_id = $i:p AND ca.clave = $cat AND i.estado NOT IN ('resuelta', 'cerrada') ORDER BY i.id DESC LIMIT 1")
                         (`Assoc [ ("p", `Int pid); ("cat", `String cat) ])
                     in
                     Lwt.return (Servidor.json_ok (`Assoc [ ("incidencia", f) ])))
             | _ -> Lwt.return (invalido "faltan persona_id y categoria")));
      Dream.post "/interno/incidencias/:id/acciones"
        (con_cuerpo (fun req j -> match int_of_string_opt (Dream.param req "id") with Some id -> aplicar_accion t id j | None -> Lwt.return (invalido "id no válido")));
      Dream.post "/interno/sla/calcular"
        (con_cuerpo (fun _ j -> sla_calcular t (List.filter_map Json.int_opt (Json.list "ids" j))));
      Dream.get "/interno/avisos/pendientes"
        (protegido (fun req ->
             registrar req `Null;
             let limite = Option.value (Option.bind (Dream.query req "limite") int_of_string_opt) ~default:50 in
             Db.usar t.db (fun c ->
                 let* filas =
                   Db.lista c ("SELECT id, incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, intentos, error, " ^ Db.iso "creado_en" ^ " AS creado_en FROM avisos WHERE enviado_en IS NULL ORDER BY id LIMIT $i:limite")
                     (`Assoc [ ("limite", `Int limite) ])
                 in
                 Lwt.return (Servidor.json_ok (`List filas)))));
      Dream.post "/interno/avisos/:id/marcar"
        (con_cuerpo (fun req j ->
             match int_of_string_opt (Dream.param req "id") with
             | None -> Lwt.return (invalido "id no válido")
             | Some id ->
                 Db.usar t.db (fun c ->
                     let* () =
                       if Json.bool_d "enviado" false j then Db.exec c "UPDATE avisos SET enviado_en = now(), error = NULL, intentos = intentos + 1 WHERE id = $i:id" (`Assoc [ ("id", `Int id) ])
                       else Db.exec c "UPDATE avisos SET error = $e, intentos = intentos + 1 WHERE id = $i:id" (`Assoc [ ("id", `Int id); ("e", Json.opt_string (Json.str "error" j)) ])
                     in
                     Lwt.return (Servidor.json_ok (`Assoc [ ("ok", `Bool true) ])))));
      Dream.get "/interno/golden"
        (protegido (fun req ->
             registrar req `Null;
             Lwt.return
               (Servidor.json_ok
                  (`List
                    [ `Assoc
                        [ ("kpi", `String "mttr"); ("nombre", `String "Tiempo de resolución (MTTR)"); ("version", `Int 1); ("unidad", `String "minutos laborales");
                          ("definicion", `String "Tiempo desde que se crea la incidencia hasta su resolución."); ("parametros", `List [ `String "desde"; `String "hasta"; `String "grupo" ]);
                          ( "preguntas_equivalentes",
                            `List [ `String "¿Cuál fue el MTTR de septiembre?"; `String "¿Cuánto demoramos en resolver una incidencia?"; `String "Tiempo medio de resolución" ] ) ];
                      `Assoc
                        [ ("kpi", `String "sla_cumplimiento"); ("nombre", `String "Cumplimiento de SLA"); ("version", `Int 1); ("unidad", `String "%");
                          ("definicion", `String "% de incidencias resueltas dentro de plazo."); ("parametros", `List [ `String "desde"; `String "hasta"; `String "grupo" ]);
                          ("preguntas_equivalentes", `List [ `String "¿Cumplimos el SLA este mes?"; `String "Cumplimiento de SLA"; `String "¿Qué porcentaje de incidencias cumplió el plazo?" ]) ] ]))));
      Dream.get "/interno/golden/:kpi"
        (protegido (fun req ->
             registrar req `Null;
             let kpi = Dream.param req "kpi" in
             let filas =
               if kpi = "calidad_asistente" && t.golden_calidad then
                 [ `Assoc [ ("pct_con_frases_quitadas", `Float 12.5); ("pct_regeneradas", `Float 3.0); ("costo_usd_por_1000_casos", `Float 42.0); ("exactitud_frente_a_correcciones_pct", `Float 97.0) ] ]
               else if kpi = "contencion_asistente" && t.golden_calidad then [ `Assoc [ ("porcentaje", `Float 55.0) ] ]
               else if kpi = "productividad_tecnico" then
                 [ `Assoc [ ("tecnico_id", `Int 1); ("resueltas", `Int 12); ("frt_mediana_min", `Float 18.5); ("mttr_mediana_min", `Int 200); ("encuestas_respondidas", `Int 3); ("csat_media", `Float 4.5) ] ]
               else [ `Assoc [ ("evaluadas", `Int 10); ("mediana_min", `Float 55.0); ("media_min", `Float 61.5) ] ]
             in
             Lwt.return
               (Servidor.json_ok
                  (`Assoc
                    ([ ("kpi", `String kpi); ("version", `Int 1); ("definicion", `String "definición de prueba"); ("unidad", `String "minutos"); ("filas", `List filas) ]
                    @ if t.sql_en_golden && kpi = "mttr" then [ ("sql", `String "SELECT 1 FROM jsrbot.v_incidencias") ] else []))))) ]
