(* Bandeja, incidencias y sus acciones (CONTRATOS §2). Las listas y el detalle leen Postgres directo; el SLA sale del motor en
   un solo lote; toda mutacion pasa por el motor. *)

let ( let* ) = Lwt.bind
open Api_util

(* --- fila de lista ------------------------------------------------------------------------------------------------------ *)

let seleccion_resumen =
  "SELECT i.id, i.numero, i.titulo, i.prioridad, i.estado, ca.clave AS categoria, i.canal, "
  ^ "CASE WHEN p.id IS NULL THEN NULL ELSE json_build_object('id', p.id, 'nombre', p.nombre, 'area', a.nombre, 'sede', s.nombre) END AS persona, "
  ^ "CASE WHEN t.id IS NULL THEN NULL ELSE json_build_object('id', t.id, 'nombre', t.nombre) END AS tecnico, g.nombre AS grupo, "
  ^ Db.iso "i.creada_en" ^ " AS creada_en, " ^ Db.iso "i.actualizada_en" ^ " AS actualizada_en, " ^ Db.iso "i.vence_resolucion_en" ^ " AS vence_resolucion_en "
  ^ "FROM incidencias i LEFT JOIN categorias ca ON ca.id = i.categoria_id LEFT JOIN personas p ON p.id = i.persona_id LEFT JOIN areas a ON a.id = p.area_id "
  ^ "LEFT JOIN sedes s ON s.id = p.sede_id LEFT JOIN tecnicos t ON t.id = i.tecnico_id LEFT JOIN grupos g ON g.id = i.grupo_id "

(* --- bandeja (DISENO §02) ----------------------------------------------------------------------------------------------- *)

let bandeja (ctx : Ctx.t) (u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let ver_todo = match u.rol with Roles.Supervisor | Roles.Gerencia | Roles.Admin -> true | _ -> false in
  let* grupos, nivel =
    match u.tecnico_id with
    | None -> Lwt.return ([], None)
    | Some t ->
        Db.usar ctx.db (fun c ->
            let* gs = Db.lista c "SELECT grupo_id FROM grupo_miembros WHERE tecnico_id = $i:t" (`Assoc [ ("t", `Int t) ]) in
            let* tec = Db.fila c "SELECT nivel FROM tecnicos WHERE id = $i:t" (`Assoc [ ("t", `Int t) ]) in
            Lwt.return (List.filter_map (Json.int "grupo_id") gs, Json.str "nivel" tec))
  in
  let ve_sin_asignar = ver_todo || nivel = Some "N1" in
  (* Candidatas: abiertas que le conciernen (las suyas, las de sus grupos, o todas segun el rol), con tope. *)
  let* filas =
    Db.lista_p ctx.db
      (seleccion_resumen
     ^ "WHERE i.estado NOT IN ('resuelta', 'cerrada') AND ($b:ver_todo OR i.tecnico_id = $i:yo OR i.grupo_id IN (SELECT jsonb_array_elements_text($j:grupos)::int) "
     ^ "OR (i.tecnico_id IS NULL AND $b:sin_asignar)) ORDER BY i.vence_resolucion_en NULLS LAST, i.id LIMIT 400")
      (`Assoc
        [ ("ver_todo", `Bool ver_todo); ("yo", Json.opt_int u.tecnico_id); ("grupos", `List (List.map (fun g -> `Int g) grupos)); ("sin_asignar", `Bool ve_sin_asignar) ])
  in
  let* filas = Api_sla.con_sla ctx filas in
  let restante f = match Json.get "sla" f with `Null -> max_int | s -> Json.int_d "restante_min" max_int s in
  let por_plazo = List.sort (fun a b -> compare (restante a) (restante b)) in
  let pausada f = Json.bool_d "pausado" false (Json.get "sla" f) in
  let pct f = Option.value (Json.float "porcentaje" (Json.get "sla" f)) ~default:0. in
  let vencen = List.filter (fun f -> Json.get "sla" f <> `Null && (not (pausada f)) && pct f >= 75.) filas |> por_plazo in
  let ids_vencen = List.filter_map (Json.int "id") vencen in
  let de_yo f = match (u.tecnico_id, Json.int "id" (Json.get "tecnico" f)) with Some y, Some t -> y = t | _ -> false in
  let mias = List.filter (fun f -> de_yo f && not (List.mem (Json.int_d "id" 0 f) ids_vencen)) filas |> por_plazo in
  let sin_asignar = if ve_sin_asignar then List.filter (fun f -> Json.get "tecnico" f = `Null) filas |> por_plazo else [] in
  let en_espera = List.filter (fun f -> Json.str_d "estado" "" f = "espera_usuario" && (ver_todo || de_yo f)) filas in
  let desde = match List.sort compare (List.filter_map (Json.str "actualizada_en") en_espera) with d :: _ -> `String d | [] -> `Null in
  ok
    (`Assoc
      [ ("vencen_pronto", `List vencen); ("mias", `List mias); ("sin_asignar", `List sin_asignar); ("contador", `Int (List.length vencen));
        ("espera_usuario", `Assoc [ ("cantidad", `Int (List.length en_espera)); ("desde", desde) ]) ])

(* --- lista --------------------------------------------------------------------------------------------------------------------- *)

let filtros_sql =
  "WHERE ($estado IS NULL OR i.estado = $estado) AND ($prioridad IS NULL OR i.prioridad = $prioridad) AND ($categoria IS NULL OR ca.clave = $categoria) "
  ^ "AND ($i:grupo_id IS NULL OR i.grupo_id = $i:grupo_id) AND ($tecnico IS NULL OR ($tecnico = 'sin' AND i.tecnico_id IS NULL) OR i.tecnico_id::text = $tecnico) "
  ^ "AND (NOT $b:abiertas OR i.estado NOT IN ('resuelta', 'cerrada')) "
  ^ "AND ($q IS NULL OR i.numero ILIKE '%' || $q || '%' ESCAPE '\\' OR i.titulo ILIKE '%' || $q || '%' ESCAPE '\\' OR p.nombre ILIKE '%' || $q || '%' ESCAPE '\\')"

let listar (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let _, por, offset = paginacion req in
  let estado = Option.map (en_lista ~nombre:"el estado" [ "nueva"; "asignada"; "en_curso"; "espera_usuario"; "espera_tercero"; "resuelta"; "cerrada"; "reabierta" ]) (consulta req "estado") in
  let prioridad = Option.map (en_lista ~nombre:"la prioridad" prioridades) (consulta req "prioridad") in
  let tecnico = consulta req "tecnico_id" in
  (match tecnico with Some t when t <> "sin" && int_of_string_opt t = None -> Errores.invalido "El técnico debe ser un número o «sin»." | _ -> ());
  let categoria = consulta req "categoria" in
  (match categoria with Some c when String.length c > 40 -> Errores.invalido "La categoría no es válida." | _ -> ());
  let grupo_id = consulta_int req "grupo_id" in
  let q = Option.map (fun s -> Db.escapar_like (if String.length s > 100 then String.sub s 0 100 else s)) (consulta req "q") in
  let params limite offset =
    `Assoc
      [ ("estado", Json.opt_string estado); ("prioridad", Json.opt_string prioridad); ("categoria", Json.opt_string categoria); ("grupo_id", Json.opt_int grupo_id);
        ("tecnico", Json.opt_string tecnico); ("abiertas", `Bool (consulta req "abiertas" = Some "1")); ("q", Json.opt_string q); ("limite", `Int limite); ("offset", `Int offset) ]
  in
  let* total =
    Db.usar ctx.db (fun c ->
        let* f =
          Db.fila c
            ("SELECT count(*) AS n FROM incidencias i LEFT JOIN categorias ca ON ca.id = i.categoria_id LEFT JOIN personas p ON p.id = i.persona_id " ^ filtros_sql)
            (params por offset)
        in
        Lwt.return (Json.int_d "n" 0 f))
  in
  let* filas =
    Db.lista_p ctx.db (seleccion_resumen ^ filtros_sql ^ " ORDER BY i.creada_en DESC, i.id DESC LIMIT $i:limite OFFSET $i:offset") (params por offset)
  in
  let* filas = Api_sla.con_sla ctx filas in
  lista filas total

(* --- detalle ------------------------------------------------------------------------------------------------------------------ *)

let seleccion_detalle =
  "SELECT i.id, i.numero, i.titulo, i.prioridad, i.estado, ca.clave AS categoria, i.canal, i.caso_id, i.resumen, i.tipo, i.impacto, i.urgencia, i.nivel, i.reaperturas, i.escalamientos, i.token_publico, "
  ^ "CASE WHEN p.id IS NULL THEN NULL ELSE json_build_object('id', p.id, 'nombre', p.nombre, 'area', a.nombre, 'sede', s.nombre) END AS persona, "
  ^ "CASE WHEN t.id IS NULL THEN NULL ELSE json_build_object('id', t.id, 'nombre', t.nombre) END AS tecnico, g.nombre AS grupo, "
  ^ Db.iso "i.creada_en" ^ " AS creada_en, " ^ Db.iso "i.actualizada_en" ^ " AS actualizada_en, " ^ Db.iso "i.vence_resolucion_en" ^ " AS vence_resolucion_en, "
  ^ Db.iso "i.vence_respuesta_en" ^ " AS vence_respuesta_en, " ^ Db.iso "i.primera_respuesta_en" ^ " AS primera_respuesta_en, " ^ Db.iso "i.resuelta_en" ^ " AS resuelta_en, "
  ^ Db.iso "i.cerrada_en" ^ " AS cerrada_en, i.persona_id "
  ^ "FROM incidencias i LEFT JOIN categorias ca ON ca.id = i.categoria_id LEFT JOIN personas p ON p.id = i.persona_id LEFT JOIN areas a ON a.id = p.area_id "
  ^ "LEFT JOIN sedes s ON s.id = p.sede_id LEFT JOIN tecnicos t ON t.id = i.tecnico_id LEFT JOIN grupos g ON g.id = i.grupo_id "

let detalle_de (ctx : Ctx.t) (id : int) : Json.t Lwt.t =
  let* base =
    Db.usar ctx.db (fun c ->
        let* inc = Db.fila c (seleccion_detalle ^ "WHERE i.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
        if inc = `Null then Errores.no_encontrado "No encontramos esa incidencia. Puede que ya no exista."
        else begin
          let caso_id = Json.int "caso_id" inc in
          let p = `Assoc [ ("id", `Int id); ("caso", Json.opt_int caso_id); ("persona", Json.get "persona_id" inc) ] in
          let* persona =
            Db.fila c
              "SELECT p.id, p.nombre, a.nombre AS area, s.nombre AS sede, p.correo, p.whatsapp, p.vip, coalesce((SELECT json_agg(ac.codigo ORDER BY ac.codigo) FROM activos ac WHERE ac.persona_id = p.id), '[]'::json) AS equipos FROM personas p LEFT JOIN areas a ON a.id = p.area_id LEFT JOIN sedes s ON s.id = p.sede_id WHERE p.id = $i:persona"
              p
          in
          let* eventos =
            Db.lista c
              ("SELECT e.id, " ^ Db.iso "e.ts" ^ " AS ts, e.tipo, e.actor_tipo, "
             ^ "CASE e.actor_tipo WHEN 'tecnico' THEN (SELECT t.nombre FROM tecnicos t WHERE t.id::text = e.actor_id) WHEN 'usuario' THEN (SELECT pe.nombre FROM personas pe WHERE pe.id::text = e.actor_id) END AS actor_nombre, e.datos "
             ^ "FROM incidencia_eventos e WHERE e.incidencia_id = $i:id ORDER BY e.ts, e.id")
              p
          in
          let* mensajes =
            match caso_id with
            | None -> Lwt.return []
            | Some _ ->
                Db.lista c
                  ("SELECT m.id, " ^ Db.iso "m.ts" ^ " AS ts, m.rol, m.texto, m.meta->>'autor' AS autor, "
                 ^ "json_build_object('intencion', m.meta->>'intencion', 'confianza', (m.meta->>'confianza')::float8, 'categoria', m.meta->>'categoria', 'latencia_ms', (m.meta->>'latencia_ms')::float8, 'articulos', m.meta->'articulos') AS meta "
                 ^ "FROM mensajes m WHERE m.caso_id = $i:caso ORDER BY m.id LIMIT 300")
                  p
          in
          let* memoria = match caso_id with None -> Lwt.return `Null | Some _ -> Db.fila c "SELECT memoria FROM casos WHERE id = $i:caso" p in
          let* clasif =
            match caso_id with
            | None -> Lwt.return `Null
            | Some _ ->
                Db.fila c
                  "SELECT m.meta->>'intencion' AS intencion, (m.meta->>'confianza')::float8 AS confianza, m.meta->>'categoria' AS categoria, (m.meta->>'categoria_confianza')::float8 AS categoria_confianza FROM mensajes m WHERE m.caso_id = $i:caso AND m.rol = 'usuario' AND m.meta->>'intencion' IS NOT NULL ORDER BY m.id DESC LIMIT 1"
                  p
          in
          let* vered =
            match caso_id with
            | None -> Lwt.return []
            | Some _ ->
                Db.lista c
                  ("SELECT " ^ Db.iso "d.ts" ^ " AS ts, d.modo, d.entrada->>'tipo' AS tipo, d.salida->>'veredicto' AS veredicto, (d.salida->>'confianza')::float8 AS confianza, d.salida->>'detalle' AS detalle FROM decisiones d WHERE d.caso_id = $i:caso AND d.componente = 'juez' ORDER BY d.id DESC LIMIT 6")
                  p
          in
          let* arts =
            match caso_id with
            | None -> Lwt.return []
            | Some _ ->
                Db.lista c
                  "SELECT a.clave, a.titulo, (SELECT u2.resultado FROM articulo_usos u2 WHERE u2.articulo_id = a.id AND u2.caso_id = $i:caso ORDER BY u2.id DESC LIMIT 1) AS resultado FROM articulos a WHERE a.id IN (SELECT articulo_id FROM articulo_usos WHERE caso_id = $i:caso) ORDER BY a.clave"
                  p
          in
          (* La sugerencia del asistente para el tecnico: la del ULTIMO mensaje del caso que la traiga (`meta.sugerencia_tecnico`), mientras ningun
             tecnico haya contestado despues (si ya contesto, la sugerencia caduco). *)
          let* sugerencia =
            match caso_id with
            | None -> Lwt.return `Null
            | Some _ ->
                Db.fila c
                  ("SELECT m.meta->'sugerencia_tecnico'->>'texto' AS texto, (m.meta->'sugerencia_tecnico'->>'confianza')::float8 AS confianza, m.meta->'sugerencia_tecnico'->>'articulo' AS articulo "
                 ^ "FROM mensajes m WHERE m.caso_id = $i:caso AND jsonb_typeof(m.meta->'sugerencia_tecnico') = 'object' "
                 ^ "AND NOT EXISTS (SELECT 1 FROM mensajes t WHERE t.caso_id = m.caso_id AND t.rol = 'tecnico' AND t.id > m.id) ORDER BY m.id DESC LIMIT 1")
                  p
          in
          Lwt.return (inc, persona, eventos, mensajes, memoria, clasif, vered, arts, sugerencia)
        end)
  in
  let inc, persona, eventos, mensajes, memoria, clasif, vered, arts, sugerencia = base in
  let* sla = Api_sla.de_motor ctx [ id ] in
  let inc = Api_sla.poner sla inc in
  (* Notas internas (eventos «comentario_interno») dentro del hilo, marcadas, para que el tecnico vea toda la conversacion. *)
  let internas =
    List.filter_map
      (fun e ->
        if Json.str_d "tipo" "" e = "comentario_interno" then
          Some
            (`Assoc
              [ ("id", `Int (- Json.int_d "id" 0 e)); ("ts", Json.get "ts" e); ("rol", `String "tecnico"); ("autor", Json.opt_string (Json.str "actor_nombre" e));
                ("texto", Json.get "texto" (Json.get "datos" e)); ("interno", `Bool true) ])
        else None)
      eventos
  in
  let del_caso =
    List.map
      (fun m ->
        let meta = Json.get "meta" m in
        Json.sin_nulos (`Assoc [ ("id", Json.get "id" m); ("ts", Json.get "ts" m); ("rol", Json.get "rol" m); ("autor", Json.get "autor" m); ("texto", Json.get "texto" m); ("meta", Json.sin_nulos meta) ]))
      mensajes
  in
  let hilo = List.sort (fun a b -> compare (Json.str_d "ts" "" a) (Json.str_d "ts" "" b)) (del_caso @ internas) in
  let persona_detalle = if persona = `Null then `Null else persona in
  let extras =
    `Assoc
      [ ("persona_detalle", persona_detalle); ("eventos", `List eventos); ("mensajes", `Assoc [ ("items", `List hilo); ("total", `Int (List.length hilo)) ]);
        ("memoria", (match Json.get "memoria" memoria with `Assoc _ as m -> m | _ -> `Assoc []));
        ("clasificacion", (if clasif = `Null then `Null else clasif));
        ("veredictos", `List (List.map (fun v -> Json.sin_nulos (match Json.get "modo" v with `String ("sombra" | "activo") -> v | _ -> Json.set "modo" (`String "sombra") v)) vered));
        ("articulos", `List arts); ("sugerencia", sugerencia) ]
  in
  Lwt.return (Json.merge inc extras)

let detalle (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"incidencia" req "id" in
  let* d = detalle_de ctx id in
  ok d

(* --- alta manual -------------------------------------------------------------------------------------------------------------------- *)

let actor_de (u : Auth.usuario) : Json.t =
  match u.tecnico_id with Some t -> Motor.actor ~id:(string_of_int t) "tecnico" | None -> Motor.actor ~id:(Printf.sprintf "consola:%d" u.id) "sistema"

(* `persona_texto`: lo que escribio quien da el alta (nombre, correo o WhatsApp). Se resuelve contra `personas`; un correo o un
   WhatsApp que no existen dan de alta a la persona; un nombre solo se acepta si identifica a UNA. *)
let resolver_persona (ctx : Ctx.t) (texto : string) : int Lwt.t =
  let digitos = Webhook.solo_digitos texto in
  let es_correo = String.contains texto '@' in
  let es_telefono = (not es_correo) && String.length digitos >= 9 && String.length digitos <= 15 && String.length digitos * 2 >= String.length texto in
  Db.usar ctx.db (fun c ->
      if es_correo then begin
        let correo = String.lowercase_ascii texto in
        if not (correo_valido correo) then Errores.invalido "Ese correo no parece válido."
        else
          let* hay = Db.lista c "SELECT id FROM personas WHERE lower(correo) = $correo ORDER BY id LIMIT 2" (`Assoc [ ("correo", `String correo) ]) in
          match hay with
          | [ f ] -> Lwt.return (Json.int_d "id" 0 f)
          | [] ->
              let nombre = Casos.recortar 80 (String.sub correo 0 (String.index correo '@')) in
              Db.insertar c "INSERT INTO personas (nombre, correo) VALUES ($nombre, $correo)" (`Assoc [ ("nombre", `String nombre); ("correo", `String correo) ])
          | _ -> Errores.invalido "Hay varias personas con ese correo; indica a quién te refieres con su WhatsApp."
      end
      else if es_telefono then begin
        let* hay = Db.lista c "SELECT id FROM personas WHERE whatsapp = $wa LIMIT 1" (`Assoc [ ("wa", `String digitos) ]) in
        match hay with
        | [ f ] -> Lwt.return (Json.int_d "id" 0 f)
        | _ -> Db.insertar c "INSERT INTO personas (nombre, whatsapp) VALUES ($nombre, $wa)" (`Assoc [ ("nombre", `String ("Contacto " ^ Casos.ultimos4 digitos)); ("wa", `String digitos) ])
      end
      else begin
        let* exactas = Db.lista c "SELECT id FROM personas WHERE lower(nombre) = lower($n) ORDER BY id LIMIT 2" (`Assoc [ ("n", `String texto) ]) in
        let* candidatas =
          if List.length exactas = 1 then Lwt.return exactas
          else Db.lista c "SELECT id FROM personas WHERE nombre ILIKE '%' || $n || '%' ESCAPE '\\' ORDER BY id LIMIT 3" (`Assoc [ ("n", `String (Db.escapar_like texto)) ])
        in
        match candidatas with
        | [ f ] -> Lwt.return (Json.int_d "id" 0 f)
        | [] -> Errores.invalido "No encontré a nadie con ese nombre. Escribe su correo o su WhatsApp para darla de alta."
        | _ -> Errores.invalido "Hay varias personas con ese nombre; escribe su correo o su WhatsApp."
      end)

let crear (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let titulo = texto_req ~max:200 ~nombre:"el asunto de la incidencia" b "titulo" in
  let resumen = Option.value (texto_opt ~max:2000 ~nombre:"el resumen" b "resumen") ~default:"" in
  let categoria = match texto_opt ~max:40 ~nombre:"la categoría" b "categoria" with Some c -> en_lista ~nombre:"la categoría" Casos.categorias c | None -> "otro" in
  let tipo = match texto_opt ~max:20 ~nombre:"el tipo" b "tipo" with Some t -> en_lista ~nombre:"el tipo" [ "incidente"; "solicitud"; "consulta"; "problema" ] t | None -> "incidente" in
  let impacto = match texto_opt ~max:20 ~nombre:"el impacto" b "impacto" with Some t -> en_lista ~nombre:"el impacto" impactos t | None -> "persona" in
  let urgencia = match texto_opt ~max:20 ~nombre:"la urgencia" b "urgencia" with Some t -> en_lista ~nombre:"la urgencia" urgencias t | None -> "media" in
  let prioridad = Option.map (en_lista ~nombre:"la prioridad" prioridades) (texto_opt ~max:2 ~nombre:"la prioridad" b "prioridad") in
  let persona_id = entero_opt ~nombre:"la persona" ~min:1 b "persona_id" in
  let persona_texto = texto_opt ~max:120 ~nombre:"la persona" b "persona_texto" in
  let* persona_id =
    match (persona_id, persona_texto) with
    | Some p, _ ->
        let* f = Db.fila_p ctx.db "SELECT id FROM personas WHERE id = $i:id" (`Assoc [ ("id", `Int p) ]) in
        if f = `Null then Errores.invalido "No existe la persona indicada." else Lwt.return (Some p)
    | None, Some t -> Lwt.map Option.some (resolver_persona ctx t)
    | None, None -> Lwt.return None
  in
  let cuerpo =
    `Assoc
      [ ("persona_id", Json.opt_int persona_id); ("tipo", `String tipo); ("categoria", `String categoria); ("impacto", `String impacto); ("urgencia", `String urgencia);
        ("titulo", `String titulo); ("resumen", `String resumen); ("canal", `String "consola"); ("motivo", `String "manual"); ("actor", actor_de u) ]
  in
  let* r = Motor.crear_incidencia ctx.motor cuerpo in
  let j = Motor.exigir r in
  let inc = Json.obj "incidencia" j in
  let id = Json.int_d "id" 0 inc in
  (* La prioridad la calcula el motor con la matriz; una persona de la mesa puede fijar otra al darla de alta. *)
  let* () =
    match prioridad with
    | Some p when p <> Json.str_d "prioridad" "" inc ->
        let* r = Motor.accion ctx.motor ~id (`Assoc [ ("accion", `String "cambiar_prioridad"); ("prioridad", `String p); ("motivo", `String "alta manual"); ("actor", actor_de u) ]) in
        (match r with Error f -> Dream.warning (fun l -> l "alta manual: no se pudo fijar la prioridad (%s)" (Motor.describir_fallo f)) | Ok _ -> ());
        Lwt.return ()
    | _ -> Lwt.return ()
  in
  let* () = Auditoria.registrar_p ~usuario_id:u.id ~objeto:(Printf.sprintf "incidencia:%d" id) ~detalle:(`Assoc [ ("origen", `String "alta_manual") ]) ctx.db ~accion:"incidencia_creada" in
  Ctx.publicar ctx "incidencia_creada" (`Assoc [ ("id", `Int id); ("numero", Json.get "numero" inc) ]);
  if Acciones.hay_avisos j then Ctx.despertar ctx;
  let* d = detalle_de ctx id in
  ok ~estado:201 d

(* --- acciones ----------------------------------------------------------------------------------------------------------------------- *)

let acciones_validas = [ "asignar"; "responder"; "comentar_interno"; "pausar"; "reanudar"; "resolver"; "reabrir"; "cerrar"; "escalar"; "cambiar_prioridad" ]

(* Normaliza texto de una persona para comparar una edicion con la sugerencia: sin espacios de mas ni mayusculas. *)
let normalizar_para_comparar (s : string) =
  let b = Buffer.create (String.length s) in
  let espacio = ref true in
  String.iter (fun c -> if c = ' ' || c = '\n' || c = '\t' || c = '\r' then (if not !espacio then Buffer.add_char b ' '; espacio := true) else (Buffer.add_char b (Char.lowercase_ascii c); espacio := false)) s;
  String.trim (Buffer.contents b)

let acciones (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"incidencia" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let accion = match Json.str "accion" b with Some a -> en_lista ~nombre:"la acción" acciones_validas a | None -> Errores.invalido "Falta la acción." in
  let actor = actor_de u in
  let motor campos = Motor.exigir_accion ctx.motor ~id campos in
  let objeto = Printf.sprintf "incidencia:%d" id in
  let auditar detalle = Auditoria.registrar_p ~usuario_id:u.id ~objeto ~detalle ctx.db ~accion:("incidencia_" ^ accion) in
  let* resultado =
    match accion with
    | "asignar" ->
        let tecnico_id = match entero_opt ~nombre:"el técnico" ~min:1 b "tecnico_id" with Some t -> t | None -> (match u.tecnico_id with Some t -> t | None -> Errores.invalido "Elige a quién asignar la incidencia.") in
        let motivo = Option.value (texto_opt ~max:200 ~nombre:"el motivo" b "motivo") ~default:"" in
        let* j = motor [ ("accion", `String "asignar"); ("tecnico_id", `Int tecnico_id); ("motivo", `String motivo); ("actor", actor) ] in
        let* () = auditar (`Assoc [ ("tecnico_id", `Int tecnico_id) ]) in
        Ctx.lanzar ctx ~nombre:"aviso asignacion" (fun () -> Entrega.avisar_persona ctx ~incidencia_id:id ~plantilla:"persona_asignada");
        Lwt.return j
    | "responder" when Json.bool_d "interno" false b ->
        let texto = texto_req ~max:4000 ~nombre:"la nota" b "texto" in
        motor [ ("accion", `String "comentar_interno"); ("texto", `String texto); ("actor", actor) ]
    | "comentar_interno" ->
        let texto = texto_req ~max:4000 ~nombre:"la nota" b "texto" in
        motor [ ("accion", `String "comentar_interno"); ("texto", `String texto); ("actor", actor) ]
    | "responder" ->
        let texto = texto_req ~max:4000 ~nombre:"el mensaje" b "texto" in
        let espera = Option.value (bool_opt ~nombre:"«espera_usuario»" b "espera_usuario") ~default:false in
        let sugerencia = texto_opt ~max:4000 ~nombre:"la sugerencia" b "sugerencia" in
        (match u.tecnico_id with
        | None -> Errores.invalido "Tu usuario no está vinculado a un técnico; pídele al administrador que lo vincule para poder responder."
        | Some _ -> ());
        let* j = motor [ ("accion", `String "responder"); ("texto", `String texto); ("espera_usuario", `Bool espera); ("actor", actor) ] in
        (* El motor ya lo registro: ahora se guarda en la conversacion y se le manda a la persona por su canal. *)
        let* destino = Db.usar ctx.db (fun c -> Entrega.destino_de_incidencia c ~incidencia_id:id) in
        let* () =
          match destino with
          | None -> Lwt.return ()
          | Some d ->
              let* _ =
                Entrega.enviar ctx ~destino:d ~rol:"tecnico" ~texto ~texto_enviado:(Printf.sprintf "%s (mesa de ayuda): %s" u.nombre texto)
                  ~meta:(Json.sin_nulos (`Assoc [ ("autor", `String u.nombre); ("tecnico_id", Json.opt_int u.tecnico_id); ("incidencia_id", `Int id); ("sugerida", Json.opt_bool (Option.map (fun _ -> true) sugerencia)) ]))
                  ()
              in
              (* Quien responde desde la consola toma la conversacion: el asistente deja de contestar para no hablar a la vez. *)
              Db.tx ctx.db (fun c -> Casos.fijar_pausa c ~caso_id:d.caso_id true)
        in
        (* Si edito la sugerencia del asistente, la diferencia es un par de preferencia (refuerzo, ARQUITECTURA §7). *)
        let* () =
          match sugerencia with
          | Some s when normalizar_para_comparar s <> normalizar_para_comparar texto ->
              Db.exec_p ctx.db "INSERT INTO pares_preferencia (incidencia_id, propuesta, editada) VALUES ($i:id, $propuesta, $editada)"
                (`Assoc [ ("id", `Int id); ("propuesta", `String s); ("editada", `String texto) ])
          | _ -> Lwt.return ()
        in
        Lwt.return j
    | "pausar" ->
        let motivo = en_lista ~nombre:"el motivo de la pausa" [ "espera_usuario"; "espera_tercero" ] (texto_req ~max:20 ~nombre:"el motivo de la pausa" b "motivo") in
        let nota = Option.value (texto_opt ~max:1000 ~nombre:"la nota" b "nota") ~default:"" in
        motor [ ("accion", `String "pausar"); ("motivo", `String motivo); ("nota", `String nota); ("actor", actor) ]
    | "reanudar" -> motor [ ("accion", `String "reanudar"); ("actor", actor) ]
    | "resolver" ->
        let solucion = match texto_opt ~max:2000 ~nombre:"la solución" b "solucion" with Some s -> s | None -> Option.value (texto_opt ~max:2000 ~nombre:"la nota" b "nota") ~default:"" in
        let* j = motor [ ("accion", `String "resolver"); ("solucion", `String solucion); ("actor", actor) ] in
        let* () = auditar `Null in
        (* La persona confirma o dice «sigue igual»: el asistente vuelve a atenderla, con la pregunta de cierre abierta. *)
        let* () =
          let* destino = Db.usar ctx.db (fun c -> Entrega.destino_de_incidencia c ~incidencia_id:id) in
          match destino with
          | None -> Lwt.return ()
          | Some d ->
              Db.tx ctx.db (fun c ->
                  let* () = Casos.fijar_pausa c ~caso_id:d.caso_id false in
                  Db.exec c "UPDATE casos SET etapa = 'cierre', memoria = jsonb_set(memoria, '{pendiente}', '\"resolvio\"'::jsonb) WHERE id = $i:id" (`Assoc [ ("id", `Int d.caso_id) ]))
        in
        Ctx.lanzar ctx ~nombre:"aviso resolucion" (fun () -> Entrega.avisar_persona ctx ~incidencia_id:id ~plantilla:"persona_resuelta");
        Lwt.return j
    | "reabrir" ->
        let motivo = Option.value (texto_opt ~max:500 ~nombre:"el motivo" b "motivo") ~default:"Reabierta por la mesa de ayuda." in
        let* j = motor [ ("accion", `String "reabrir"); ("motivo", `String motivo); ("actor", actor) ] in
        let* () = auditar `Null in
        Ctx.lanzar ctx ~nombre:"aviso reapertura" (fun () -> Entrega.avisar_persona ctx ~incidencia_id:id ~plantilla:"persona_reabierta");
        Lwt.return j
    | "cerrar" ->
        let* j = motor [ ("accion", `String "cerrar"); ("motivo", `String "confirmado"); ("actor", actor) ] in
        let* () = auditar `Null in
        Lwt.return j
    | "escalar" ->
        let grupo = entero_opt ~nombre:"el grupo" ~min:1 b "grupo_id" in
        let motivo = Option.value (texto_opt ~max:200 ~nombre:"el motivo" b "motivo") ~default:"manual" in
        let* j = motor ([ ("accion", `String "escalar"); ("motivo", `String motivo); ("actor", actor) ] @ (match grupo with Some g -> [ ("grupo_destino_id", `Int g) ] | None -> [])) in
        let* () = auditar (`Assoc [ ("grupo_id", Json.opt_int grupo); ("motivo", `String motivo) ]) in
        Lwt.return j
    | _ ->
        let p = en_lista ~nombre:"la prioridad" prioridades (texto_req ~max:2 ~nombre:"la prioridad" b "prioridad") in
        let motivo = Option.value (texto_opt ~max:200 ~nombre:"el motivo" b "motivo") ~default:"" in
        let* j = motor [ ("accion", `String "cambiar_prioridad"); ("prioridad", `String p); ("motivo", `String motivo); ("actor", actor) ] in
        let* () = auditar (`Assoc [ ("prioridad", `String p) ]) in
        Lwt.return j
  in
  Ctx.publicar ctx "incidencia_actualizada" (`Assoc [ ("id", `Int id); ("numero", Json.get "numero" (Json.obj "incidencia" resultado)) ]);
  if Acciones.hay_avisos resultado then Ctx.despertar ctx;
  let* d = detalle_de ctx id in
  ok d
