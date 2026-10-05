(* Seccion «Asistente» de la consola: conocimiento (articulos), entrenamiento (cola de revision, reentrenar, publicar),
   comportamiento y calidad. Rol entrenador (y administrador). *)

let ( let* ) = Lwt.bind
open Api_util

let auditar (ctx : Ctx.t) (u : Auth.usuario) ~accion ~objeto detalle = Auditoria.registrar_p ~usuario_id:u.id ~objeto ~detalle ctx.db ~accion

(* --- conocimiento: articulos ---------------------------------------------------------------------------------------------- *)

let seleccion_articulo =
  "SELECT a.id, a.clave, a.titulo, ca.clave AS categoria, to_json(a.sintomas) AS sintomas, to_json(a.pasos) AS pasos, a.cuerpo, a.estado, a.supuesto, a.version, "
  ^ Db.iso "a.actualizado_en" ^ " AS actualizado_en, (SELECT count(*) FROM articulo_usos u WHERE u.articulo_id = a.id)::int AS usos, "
  ^ "(SELECT round(100.0 * count(*) FILTER (WHERE u.resultado = 'resolvio') / nullif(count(*) FILTER (WHERE u.resultado IN ('resolvio', 'sigue_igual')), 0), 1) FROM articulo_usos u WHERE u.articulo_id = a.id)::float8 AS resolvio_pct "
  ^ "FROM articulos a LEFT JOIN categorias ca ON ca.id = a.categoria_id "

(* El agente carga los articulos PUBLICADOS por POST /conocimiento/recargar (CONTRATOS §1). Se llama tras cada cambio, en segundo plano. *)
let recargar_agente (ctx : Ctx.t) : unit Lwt.t =
  (* `usos` por articulo y categoria ({"correo": {"exitos": 12, "fracasos": 3}}) alimenta el bandido de Thompson del agente (CONTRATOS «Cambios»
     del agente, 10): la fuente de verdad es `articulo_usos`. *)
  let* filas =
    Db.lista_p ctx.db
      ("SELECT a.clave, a.titulo, ca.clave AS categoria, to_json(a.sintomas) AS sintomas, to_json(a.pasos) AS pasos, a.cuerpo, "
     ^ "coalesce((SELECT json_object_agg(x.cat, json_build_object('exitos', x.exitos, 'fracasos', x.fracasos)) FROM "
     ^ "(SELECT uc.clave AS cat, count(*) FILTER (WHERE u.resultado = 'resolvio')::int AS exitos, count(*) FILTER (WHERE u.resultado = 'sigue_igual')::int AS fracasos "
     ^ "FROM articulo_usos u JOIN categorias uc ON uc.id = u.categoria_id WHERE u.articulo_id = a.id GROUP BY uc.clave) x), '{}'::json) AS usos "
     ^ "FROM articulos a LEFT JOIN categorias ca ON ca.id = a.categoria_id WHERE a.estado = 'publicado' ORDER BY a.clave")
      (`Assoc [])
  in
  let* r = Agente.recargar_conocimiento ctx.agente filas in
  (match r with
  | Ok () -> Dream.log "conocimiento recargado en el agente (%d articulos publicados)" (List.length filas)
  | Error m -> Dream.warning (fun l -> l "no se pudo recargar el conocimiento del agente: %s" m));
  Lwt.return ()

let listar_articulos (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let _, por, offset = paginacion req in
  let estado = Option.map (en_lista ~nombre:"el estado" [ "borrador"; "publicado"; "archivado" ]) (consulta req "estado") in
  let q = Option.map (fun s -> Db.escapar_like (if String.length s > 100 then String.sub s 0 100 else s)) (consulta req "q") in
  let filtro =
    "WHERE ($estado IS NULL OR a.estado = $estado) AND ($q IS NULL OR a.titulo ILIKE '%' || $q || '%' ESCAPE '\\' OR a.clave ILIKE '%' || $q || '%' ESCAPE '\\' OR array_to_string(a.sintomas, ' ') ILIKE '%' || $q || '%' ESCAPE '\\')"
  in
  let params = `Assoc [ ("estado", Json.opt_string estado); ("q", Json.opt_string q); ("limite", `Int por); ("offset", `Int offset) ] in
  let* total = Db.fila_p ctx.db ("SELECT count(*) AS n FROM articulos a " ^ filtro) params in
  let* filas = Db.lista_p ctx.db (seleccion_articulo ^ filtro ^ " ORDER BY a.actualizado_en DESC, a.id DESC LIMIT $i:limite OFFSET $i:offset") params in
  lista filas (Json.int_d "n" 0 total)

let lista_de_textos ~(nombre : string) ~(max_items : int) ~(max_largo : int) ~(minimo : int) (b : Json.t) (k : string) : string list option =
  match Json.get k b with
  | `Null -> None
  | `List l ->
      let ts =
        List.filter_map
          (function
            | `String s when String.trim s <> "" ->
                if String.length s > max_largo then Errores.invalido (Printf.sprintf "Cada elemento de %s admite hasta %d caracteres." nombre max_largo) else Some (String.trim s)
            | `String _ -> None
            | _ -> Errores.invalido (Printf.sprintf "%s debe ser una lista de textos." (String.capitalize_ascii nombre)))
          l
      in
      if List.length ts > max_items then Errores.invalido (Printf.sprintf "%s admite hasta %d elementos." (String.capitalize_ascii nombre) max_items)
      else if List.length ts < minimo then Errores.invalido (Printf.sprintf "Un artículo necesita al menos un paso.")
      else Some ts
  | _ -> Errores.invalido (Printf.sprintf "%s debe ser una lista de textos." (String.capitalize_ascii nombre))

let json_de_textos l = `List (List.map (fun s -> `String s) l)

let categoria_de (b : Json.t) : string option =
  match texto_opt ~max:40 ~nombre:"la categoría" b "categoria" with Some c -> Some (en_lista ~nombre:"la categoría" Casos.categorias c) | None -> None

let crear_articulo (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json ~max:200_000 req in
  let titulo = texto_req ~max:200 ~nombre:"el título del artículo" b "titulo" in
  let pasos = match lista_de_textos ~nombre:"los pasos" ~max_items:30 ~max_largo:600 ~minimo:1 b "pasos" with Some p -> p | None -> Errores.invalido "Un artículo necesita al menos un paso." in
  let sintomas = Option.value (lista_de_textos ~nombre:"los síntomas" ~max_items:30 ~max_largo:300 ~minimo:0 b "sintomas") ~default:[] in
  let cuerpo = Option.value (texto_opt ~max:20_000 ~nombre:"el cuerpo" b "cuerpo") ~default:"" in
  let estado = match texto_opt ~max:12 ~nombre:"el estado" b "estado" with Some e -> en_lista ~nombre:"el estado" [ "borrador"; "publicado"; "archivado" ] e | None -> "borrador" in
  let* id =
    Db.tx ctx.db (fun c ->
        let* n = Db.escalar_int c "SELECT nextval(pg_get_serial_sequence('articulos', 'id')) AS n" (`Assoc []) in
        let n = Option.value n ~default:0 in
        let* id =
          Db.insertar c
            "INSERT INTO articulos (id, clave, titulo, categoria_id, sintomas, pasos, cuerpo, estado, supuesto) VALUES ($i:n, 'KB-' || lpad(greatest($i:n, (SELECT coalesce(max(substring(clave from '[0-9]+$')::int), 0) + 1 FROM articulos WHERE clave ~ '^KB-[0-9]+$'))::text, 3, '0'), $titulo, (SELECT id FROM categorias WHERE clave = $cat), ARRAY(SELECT jsonb_array_elements_text($j:sintomas)), ARRAY(SELECT jsonb_array_elements_text($j:pasos)), $cuerpo, $estado, true)"
            (`Assoc
              [ ("n", `Int n); ("titulo", `String titulo); ("cat", Json.opt_string (categoria_de b)); ("sintomas", json_de_textos sintomas); ("pasos", json_de_textos pasos);
                ("cuerpo", `String cuerpo); ("estado", `String estado) ])
        in
        let* () = Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "articulo:%d" id) ~accion:"articulo_creado" ~detalle:(`Assoc [ ("estado", `String estado) ]) in
        Lwt.return id)
  in
  Ctx.lanzar ctx ~nombre:"recargar conocimiento" (fun () -> recargar_agente ctx);
  let* f = Db.fila_p ctx.db (seleccion_articulo ^ "WHERE a.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  ok ~estado:201 f

let actualizar_articulo (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"artículo" req "id" in
  let* b = Seguridad.cuerpo_json ~max:200_000 req in
  let titulo = if Json.get "titulo" b = `Null then None else Some (texto_req ~max:200 ~nombre:"el título del artículo" b "titulo") in
  let pasos = lista_de_textos ~nombre:"los pasos" ~max_items:30 ~max_largo:600 ~minimo:1 b "pasos" in
  let sintomas = lista_de_textos ~nombre:"los síntomas" ~max_items:30 ~max_largo:300 ~minimo:0 b "sintomas" in
  let cuerpo = match Json.get "cuerpo" b with `Null -> None | `String s when String.length s <= 20_000 -> Some s | _ -> Errores.invalido "El cuerpo del artículo es demasiado largo." in
  let estado = Option.map (en_lista ~nombre:"el estado" [ "borrador"; "publicado"; "archivado" ]) (texto_opt ~max:12 ~nombre:"el estado" b "estado") in
  let categoria = categoria_de b in
  let supuesto = bool_opt ~nombre:"«supuesto»" b "supuesto" in
  let solo_estado = estado <> None && titulo = None && pasos = None && sintomas = None && cuerpo = None && categoria = None in
  let* n =
    Db.afectadas_p ctx.db
      ("UPDATE articulos SET titulo = coalesce($titulo, titulo), categoria_id = coalesce((SELECT id FROM categorias WHERE clave = $cat), categoria_id), "
     ^ "sintomas = CASE WHEN $b:con_sintomas THEN ARRAY(SELECT jsonb_array_elements_text($j:sintomas)) ELSE sintomas END, "
     ^ "pasos = CASE WHEN $b:con_pasos THEN ARRAY(SELECT jsonb_array_elements_text($j:pasos)) ELSE pasos END, cuerpo = coalesce($cuerpo, cuerpo), estado = coalesce($estado, estado), "
     ^ "supuesto = coalesce($b:supuesto, CASE WHEN $b:solo_estado THEN supuesto ELSE false END), version = version + 1, actualizado_en = now() WHERE id = $i:id")
      (`Assoc
        [ ("id", `Int id); ("titulo", Json.opt_string titulo); ("cat", Json.opt_string categoria); ("con_sintomas", `Bool (sintomas <> None));
          ("sintomas", (match sintomas with Some s -> json_de_textos s | None -> `List [])); ("con_pasos", `Bool (pasos <> None));
          ("pasos", (match pasos with Some p -> json_de_textos p | None -> `List [])); ("cuerpo", Json.opt_string cuerpo); ("estado", Json.opt_string estado);
          ("supuesto", Json.opt_bool supuesto); ("solo_estado", `Bool solo_estado) ])
  in
  if n = 0 then Errores.no_encontrado "No encontramos ese artículo."
  else begin
    let* () = auditar ctx u ~accion:"articulo_actualizado" ~objeto:(Printf.sprintf "articulo:%d" id) (`Assoc [ ("estado", Json.opt_string estado) ]) in
    Ctx.lanzar ctx ~nombre:"recargar conocimiento" (fun () -> recargar_agente ctx);
    let* f = Db.fila_p ctx.db (seleccion_articulo ^ "WHERE a.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
    ok f
  end

(* --- comportamiento del asistente ----------------------------------------------------------------------------------------------- *)

let config_por_defecto : Json.t =
  `Assoc
    [ ("nombre", `String "Asistente de la mesa de ayuda"); ("trato", `String "tu");
      ("saludo", `String "¡Hola! Soy el asistente de la mesa de ayuda. Cuéntame qué está pasando y lo revisamos juntos.");
      ("umbral_confianza", `Float 0.6); ("maximo_pasos_guia", `Int 2); ("juez_modo", `String "sombra");
      ("puede", `Assoc [ ("crear_incidencias", `Bool true); ("consultar_estado", `Bool true); ("pedir_encuesta", `Bool true); ("resolver_clave", `Bool false) ]) ]

let leer_config (ctx : Ctx.t) : Json.t Lwt.t =
  let* f = Db.fila_p ctx.db "SELECT valor FROM configuracion WHERE clave = 'asistente'" (`Assoc []) in
  let guardada = match Json.get "valor" f with `Assoc _ as v -> v | _ -> `Assoc [] in
  let puede = Json.merge (Json.obj "puede" config_por_defecto) (Json.obj "puede" guardada) in
  Lwt.return (Json.set "puede" puede (Json.merge config_por_defecto guardada))

let config (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* c = leer_config ctx in
  ok c

let guardar_config (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let campos = ref [] in
  let poner k v = campos := (k, v) :: !campos in
  (match Json.get "nombre" b with `Null -> () | _ -> poner "nombre" (`String (texto_req ~max:80 ~nombre:"el nombre del asistente" b "nombre")));
  (match texto_opt ~max:10 ~nombre:"el trato" b "trato" with Some t -> poner "trato" (`String (en_lista ~nombre:"el trato" [ "tu"; "usted" ] t)) | None -> ());
  (match Json.get "saludo" b with `Null -> () | _ -> poner "saludo" (`String (texto_req ~max:600 ~nombre:"el saludo" b "saludo")));
  (match Json.get "umbral_confianza" b with
  | `Null -> ()
  | v -> ( match Json.float_opt v with Some f when f >= 0.3 && f <= 0.95 -> poner "umbral_confianza" (`Float f) | _ -> Errores.invalido "El umbral de confianza va entre 0,30 y 0,95."));
  (match entero_opt ~nombre:"los pasos de guía" ~min:1 ~max:8 b "maximo_pasos_guia" with Some n -> poner "maximo_pasos_guia" (`Int n) | None -> ());
  (match texto_opt ~max:10 ~nombre:"el modo de Jev local" b "juez_modo" with Some m -> poner "juez_modo" (`String (en_lista ~nombre:"el modo de Jev local" [ "apagado"; "sombra"; "activo" ] m)) | None -> ());
  (match Json.get "puede" b with
  | `Null -> ()
  | `Assoc l ->
      let claves = [ "crear_incidencias"; "consultar_estado"; "pedir_encuesta"; "resolver_clave" ] in
      List.iter (fun (k, _) -> if not (List.mem k claves) then Errores.invalido (Printf.sprintf "«%s» no es una capacidad del asistente." k)) l;
      poner "puede" (`Assoc (List.map (fun (k, _) -> (k, `Bool (Option.value (bool_opt ~nombre:k (Json.get "puede" b) k) ~default:false))) l))
  | _ -> Errores.invalido "«puede» debe ser un objeto.");
  let* actual = leer_config ctx in
  let nueva = List.fold_left (fun acc (k, v) -> if k = "puede" then Json.set "puede" (Json.merge (Json.obj "puede" acc) v) acc else Json.set k v acc) actual !campos in
  let* () =
    Db.exec_p ctx.db "INSERT INTO configuracion (clave, valor, actualizado_en) VALUES ('asistente', $j:valor, now()) ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado_en = now()"
      (`Assoc [ ("valor", nueva) ])
  in
  let* () = auditar ctx u ~accion:"asistente_configurado" ~objeto:"configuracion:asistente" (`Assoc [ ("campos", `List (List.map (fun (k, _) -> `String k) !campos)) ]) in
  ok nueva

(* --- entrenamiento ---------------------------------------------------------------------------------------------------------------- *)

(* Lleva a la cola de revision los mensajes dudosos: baja confianza, 👎 y correcciones de un tecnico. Idempotente: un mensaje
   entra una sola vez. Se llama al abrir la cola. *)
let poblar_cola (ctx : Ctx.t) : unit Lwt.t =
  let* cfg = leer_config ctx in
  let umbral = Option.value (Json.float "umbral_confianza" cfg) ~default:0.6 in
  Db.usar ctx.db (fun c ->
      let base =
        "INSERT INTO etiquetas_revision (mensaje_id, texto, intencion_modelo, confianza) SELECT m.id, m.texto, m.meta->>'intencion', (m.meta->>'confianza')::real FROM mensajes m WHERE m.rol = 'usuario' AND NOT EXISTS (SELECT 1 FROM etiquetas_revision er WHERE er.mensaje_id = m.id) AND "
      in
      let* () =
        Db.exec c (base ^ "m.meta->>'intencion' IS NOT NULL AND (m.meta->>'confianza')::float8 < $f:umbral ORDER BY m.id DESC LIMIT 200") (`Assoc [ ("umbral", `Float umbral) ])
      in
      Db.exec c
        (base ^ "m.id IN (SELECT mensaje_id FROM feedback WHERE mensaje_id IS NOT NULL AND senal IN ('pulgar_abajo', 'correccion_intencion', 'correccion_categoria')) ORDER BY m.id DESC LIMIT 200")
        (`Assoc []))

let seleccion_cola =
  "SELECT er.id, er.mensaje_id, er.texto, coalesce(er.intencion_modelo, '') AS intencion_modelo, coalesce(er.confianza, 0)::float8 AS confianza, "
  ^ "CASE WHEN EXISTS (SELECT 1 FROM feedback f WHERE f.mensaje_id = er.mensaje_id AND f.senal = 'pulgar_abajo') THEN 'pulgar_abajo' "
  ^ "WHEN EXISTS (SELECT 1 FROM feedback f WHERE f.mensaje_id = er.mensaje_id AND f.senal IN ('correccion_intencion', 'correccion_categoria')) THEN 'correccion_tecnico' "
  ^ "WHEN EXISTS (SELECT 1 FROM feedback f WHERE f.caso_id = m.caso_id AND f.senal = 'reapertura') THEN 'reapertura' ELSE 'baja_confianza' END AS motivo, "
  ^ "er.estado, " ^ Db.iso "er.ts" ^ " AS ts, m.caso_id, er.intencion_correcta, er.categoria_correcta FROM etiquetas_revision er LEFT JOIN mensajes m ON m.id = er.mensaje_id "

let cola (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let _, por, offset = paginacion req in
  let estado = match consulta req "estado" with None -> "pendiente" | Some e -> en_lista ~nombre:"el estado" [ "pendiente"; "confirmada"; "corregida"; "descartada"; "todas" ] e in
  let* () = poblar_cola ctx in
  let filtro = "WHERE ($estado = 'todas' OR er.estado = $estado)" in
  let params = `Assoc [ ("estado", `String estado); ("limite", `Int por); ("offset", `Int offset) ] in
  let* total = Db.fila_p ctx.db ("SELECT count(*) AS n FROM etiquetas_revision er " ^ filtro) params in
  let* filas = Db.lista_p ctx.db (seleccion_cola ^ filtro ^ " ORDER BY er.id DESC LIMIT $i:limite OFFSET $i:offset") params in
  lista filas (Json.int_d "n" 0 total)

let revisar (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"mensaje de la cola" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let decision = en_lista ~nombre:"la decisión" [ "confirmar"; "corregir"; "descartar" ] (texto_req ~max:12 ~nombre:"la decisión" b "decision") in
  let intencion = Option.map (en_lista ~nombre:"la intención" intenciones) (texto_opt ~max:30 ~nombre:"la intención" b "intencion") in
  let categoria = Option.map (en_lista ~nombre:"la categoría" Casos.categorias) (texto_opt ~max:30 ~nombre:"la categoría" b "categoria") in
  if decision = "corregir" && intencion = None && categoria = None then Errores.invalido "Elige la intención o la categoría correcta de la lista.";
  let* () =
    Db.tx ctx.db (fun c ->
        let* actual = Db.fila c "SELECT er.id, er.mensaje_id, er.intencion_modelo, m.caso_id FROM etiquetas_revision er LEFT JOIN mensajes m ON m.id = er.mensaje_id WHERE er.id = $i:id" (`Assoc [ ("id", `Int id) ]) in
        if actual = `Null then Errores.no_encontrado "No encontramos ese mensaje en la cola."
        else begin
          let estado = match decision with "confirmar" -> "confirmada" | "corregir" -> "corregida" | _ -> "descartada" in
          let correcta = match decision with "confirmar" -> Json.str "intencion_modelo" actual | "corregir" -> intencion | _ -> None in
          let* () =
            Db.exec c "UPDATE etiquetas_revision SET estado = $estado, intencion_correcta = $correcta, categoria_correcta = $cat, revisada_por = $por WHERE id = $i:id"
              (`Assoc [ ("id", `Int id); ("estado", `String estado); ("correcta", Json.opt_string correcta); ("cat", Json.opt_string (if decision = "corregir" then categoria else None)); ("por", `String u.email) ])
          in
          (* Una correccion es una senal de calidad: alimenta la exactitud frente a correcciones (golden calidad_asistente). *)
          let* () =
            if decision <> "corregir" then Lwt.return ()
            else
              let mensaje_id = Json.int "mensaje_id" actual and caso_id = Json.int "caso_id" actual in
              let* () = match intencion with Some i -> Analitica.registrar_feedback c ?caso_id ?mensaje_id ~valor:i ~senal:"correccion_intencion" () | None -> Lwt.return () in
              match categoria with Some k -> Analitica.registrar_feedback c ?caso_id ?mensaje_id ~valor:k ~senal:"correccion_categoria" () | None -> Lwt.return ()
          in
          Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "etiqueta:%d" id) ~accion:("entrenamiento_" ^ decision) ~detalle:(`Assoc [ ("intencion", Json.opt_string intencion) ])
        end)
  in
  let* f = Db.fila_p ctx.db (seleccion_cola ^ "WHERE er.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  ok f

(* --- modelos: el AGENTE entrena, mide y publica; la pasarela guia el proceso y refleja el resultado en `modelos` --------------------- *)

let entrenando = ref false

let modelo_json (f : Json.t) : Json.t =
  `Assoc
    [ ("version", Json.get "version" f); ("exactitud", Json.get "exactitud" f); ("macro_f1", Json.get "macro_f1" f); ("estado", Json.get "estado" f);
      ("creado_en", Json.get "creado_en" f); ("ejemplos", Json.get "ejemplos" f) ]

let seleccion_modelo =
  "SELECT version, round(coalesce(exactitud, 0)::numeric, 4)::float8 AS exactitud, round(coalesce(macro_f1, 0)::numeric, 4)::float8 AS macro_f1, estado, " ^ Db.iso "creado_en"
  ^ " AS creado_en, coalesce(detalle->>'ejemplos', detalle->>'ejemplos_extra')::int AS ejemplos FROM modelos "

(* Exactitud y macro-F1 de una version, vengan planas o dentro de `intencion` (como las da `POST /reentrenar`). *)
let cifras (j : Json.t) : float option * float option =
  let i = Json.obj "intencion" j in
  ( (match Json.float "exactitud" j with Some x -> Some x | None -> Json.float "exactitud" i),
    match Json.float "macro_f1" j with Some x -> Some x | None -> ( match Json.float "f1_macro" j with Some x -> Some x | None -> Json.float "f1_macro" i) )

let registrar_modelo (c : Db.conn) ~(version : string) ~(estado : string) (j : Json.t) : unit Lwt.t =
  let exactitud, macro_f1 = cifras j in
  Db.exec c
    "INSERT INTO modelos (version, exactitud, macro_f1, estado, detalle) VALUES ($version, $f:exactitud, $f:macro_f1, $estado, $j:detalle) ON CONFLICT (version) DO UPDATE SET estado = (CASE WHEN EXCLUDED.estado = 'publicado' THEN 'publicado' WHEN modelos.estado = 'retirado' THEN 'retirado' ELSE EXCLUDED.estado END), exactitud = coalesce(EXCLUDED.exactitud, modelos.exactitud), macro_f1 = coalesce(EXCLUDED.macro_f1, modelos.macro_f1)"
    (`Assoc [ ("version", `String version); ("exactitud", Json.opt_float exactitud); ("macro_f1", Json.opt_float macro_f1); ("estado", `String estado); ("detalle", j) ])

(* Trae las versiones que conoce el agente (`GET /modelos`) y las refleja en `modelos` (no se pisa un candidato local con un estado mas viejo).
   Mejor esfuerzo, como mucho cada 30 s: si el agente no responde o no tiene la ruta, no pasa nada. *)
let sincronizar_modelos (ctx : Ctx.t) : unit Lwt.t =
  let ahora = Ctx.ahora ctx in
  if ahora -. ctx.modelos_sync < 30. then Lwt.return ()
  else begin
    ctx.modelos_sync <- ahora;
    let* r = Agente.modelos ctx.agente in
    match r with
    | Error _ -> Lwt.return ()
    | Ok j ->
        let lista = match j with `List l -> l | _ -> Json.list "modelos" j in
        let actual = Json.str_ne "actual" j in
        Lwt.catch
          (fun () ->
            Db.tx ctx.db (fun c ->
                let* () =
                  Lwt_list.iter_s
                    (fun m ->
                      match (match Json.str_ne "version" m with Some v -> Some v | None -> Json.str_ne "modelo" m) with
                      | None -> Lwt.return ()
                      | Some version ->
                          let publicado = Json.bool_d "publicado" false m || Json.str "estado" m = Some "publicado" || actual = Some version in
                          registrar_modelo c ~version ~estado:(if publicado then "publicado" else "candidato") m)
                    lista
                in
                (* Una sola version publicada: la que dice el agente; el resto de «publicado» pasa a «retirado». *)
                match actual with
                | Some v -> Db.exec c "UPDATE modelos SET estado = 'retirado' WHERE estado = 'publicado' AND version <> $v" (`Assoc [ ("v", `String v) ])
                | None -> Lwt.return ()))
          (fun e -> Dream.warning (fun l -> l "modelos: no se pudo sincronizar (%s)" (Printexc.to_string e)); Lwt.return ())
  end

let estado_entrenamiento (ctx : Ctx.t) : Json.t Lwt.t =
  let* () = sincronizar_modelos ctx in
  let* pub = Db.fila_p ctx.db (seleccion_modelo ^ "WHERE estado = 'publicado' ORDER BY id DESC LIMIT 1") (`Assoc []) in
  let* cand = Db.fila_p ctx.db (seleccion_modelo ^ "WHERE estado = 'candidato' ORDER BY id DESC LIMIT 1") (`Assoc []) in
  let* pend =
    Db.fila_p ctx.db
      "SELECT count(*) AS n FROM etiquetas_revision WHERE estado IN ('confirmada', 'corregida') AND id > coalesce((SELECT (valor #>> '{}')::bigint FROM configuracion WHERE clave = 'entrenamiento_ultima_etiqueta'), 0)"
      (`Assoc [])
  in
  let publicado = if pub = `Null then `Assoc [ ("version", `String "sin registrar"); ("exactitud", `Float 0.); ("macro_f1", `Float 0.); ("estado", `String "publicado"); ("creado_en", `String (Tiempo.a_iso 0.)) ] else modelo_json pub in
  let fase = if !entrenando then "entrenando" else if cand <> `Null then "listo" else "ninguno" in
  Lwt.return
    (Json.sin_nulos
       (`Assoc [ ("publicado", publicado); ("candidato", (if cand = `Null then `Null else modelo_json cand)); ("fase", `String fase); ("cambios_pendientes", `Int (Json.int_d "n" 0 pend)) ]))

let estado (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* e = estado_entrenamiento ctx in
  ok e

(* Reentrenar: el agente entrena con los ejemplos REVISADOS y MIDE sobre el reservado SIN publicar (`publicar: false`). El resultado queda como
   candidato en `modelos`, para compararlo con el publicado en pantalla; publicar es una decision aparte (`publicar`). *)
let reentrenar (ctx : Ctx.t) (u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* e = estado_entrenamiento ctx in
  if !entrenando then Errores.conflicto "Ya hay un entrenamiento en curso."
  else if Json.int_d "cambios_pendientes" 0 e <= 0 then Errores.invalido "Revisa al menos un mensaje antes de reentrenar."
  else begin
    entrenando := true;
    let* () = auditar ctx u ~accion:"reentrenamiento_iniciado" ~objeto:"modelo" (`Assoc []) in
    Ctx.lanzar ctx ~nombre:"reentrenar" (fun () ->
        Lwt.finalize
          (fun () ->
            let* ejemplos =
              Db.lista_p ctx.db
                "SELECT texto AS mensaje, intencion_correcta AS intencion, categoria_correcta AS categoria FROM etiquetas_revision WHERE estado IN ('confirmada', 'corregida') AND id > coalesce((SELECT (valor #>> '{}')::bigint FROM configuracion WHERE clave = 'entrenamiento_ultima_etiqueta'), 0) ORDER BY id LIMIT 5000"
                (`Assoc [])
            in
            let* r = Agente.reentrenar ctx.agente ~ejemplos ~publicar:false in
            match r with
            | Error m ->
                Dream.error (fun l -> l "reentrenar: el agente fallo (%s)" m);
                Lwt.return ()
            | Ok j ->
                let version = match Json.str_ne "modelo" j with Some v -> v | None -> (match Json.str_ne "version" j with Some v -> v | None -> Printf.sprintf "cand-%.0f" (Tiempo.ahora ())) in
                (* Un agente viejo publica por su cuenta (`publicado: true`): se refleja tal cual. Con `publicar: false`, queda como candidato. *)
                let publicado = Json.bool_d "publicado" false j in
                Db.tx ctx.db (fun c ->
                    let* () = if publicado then Db.exec c "UPDATE modelos SET estado = 'retirado' WHERE estado = 'publicado'" (`Assoc []) else Lwt.return () in
                    let* () = registrar_modelo c ~version ~estado:(if publicado then "publicado" else "candidato") j in
                    Db.exec c
                      "INSERT INTO configuracion (clave, valor, actualizado_en) SELECT 'entrenamiento_ultima_etiqueta', to_jsonb(coalesce(max(id), 0)), now() FROM etiquetas_revision WHERE estado IN ('confirmada', 'corregida') ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado_en = now()"
                      (`Assoc [])))
          (fun () ->
            entrenando := false;
            Lwt.return ()));
    let* e = estado_entrenamiento ctx in
    ok e
  end

(* Publicar: dos llaves. (1) La pasarela rechaza un candidato que empeora al publicado (409). (2) El AGENTE tiene la ultima palabra
   (`POST /modelos/{version}/publicar`): solo si lo acepta se refleja en `modelos`. *)
let publicar (ctx : Ctx.t) (u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* pub = Db.fila_p ctx.db (seleccion_modelo ^ "WHERE estado = 'publicado' ORDER BY id DESC LIMIT 1") (`Assoc []) in
  let* cand = Db.fila_p ctx.db (seleccion_modelo ^ "WHERE estado = 'candidato' ORDER BY id DESC LIMIT 1") (`Assoc []) in
  if cand = `Null then Errores.invalido "No hay una versión nueva para publicar."
  else if pub <> `Null && Option.value (Json.float "exactitud" cand) ~default:0. < Option.value (Json.float "exactitud" pub) ~default:0. then
    Errores.conflicto "La versión nueva es peor que la publicada. No se publica."
  else begin
    let version = Json.str_d "version" "" cand in
    let* r = Agente.publicar_modelo ctx.agente ~version in
    match r with
    | Agente.Rechazado (404, _) -> Errores.no_encontrado "El agente no conoce esa versión del modelo."
    | Agente.Rechazado (_, msg) -> Errores.conflicto msg
    | Agente.Sin_respuesta m ->
        Dream.warning (fun l -> l "publicar modelo: el agente no respondio (%s)" m);
        Errores.no_disponible "El asistente no responde en este momento; no se publicó nada. Inténtalo de nuevo en unos segundos."
    | Agente.Publicado _ ->
        let* () =
          Db.tx ctx.db (fun c ->
              let* () = Db.exec c "UPDATE modelos SET estado = 'retirado' WHERE estado = 'publicado'" (`Assoc []) in
              let* () = Db.exec c "UPDATE modelos SET estado = 'publicado' WHERE version = $version" (`Assoc [ ("version", `String version) ]) in
              Auditoria.registrar c ~usuario_id:u.id ~objeto:("modelo:" ^ version) ~accion:"modelo_publicado" ~detalle:(`Assoc [ ("exactitud", Json.get "exactitud" cand) ]))
        in
        let* e = estado_entrenamiento ctx in
        ok e
  end

let descartar (ctx : Ctx.t) (u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* () = Db.exec_p ctx.db "UPDATE modelos SET estado = 'retirado' WHERE estado = 'candidato'" (`Assoc []) in
  let* () = auditar ctx u ~accion:"modelo_candidato_descartado" ~objeto:"modelo" (`Assoc []) in
  let* e = estado_entrenamiento ctx in
  ok e

(* --- calidad ------------------------------------------------------------------------------------------------------------------------------- *)

(* Las 12 semanas (lunes de Lima, de la mas vieja a la mas nueva) con lo que hay en Postgres. SON CIFRAS OPERATIVAS, no los KPI oficiales
   (AGENTS §1.4 regla 7): cuando ClickHouse responde, las series de frases quitadas, regeneradas, costo y contencion salen de las golden queries
   `calidad_asistente` y `contencion_asistente`; esto solo las rellena si no hay respuesta, y `fuente` lo dice por serie. *)
let series_postgres (ctx : Ctx.t) : Json.t list Lwt.t =
  let semana col = Printf.sprintf "(%s AT TIME ZONE 'America/Lima')::date >= s.ini AND (%s AT TIME ZONE 'America/Lima')::date < s.ini + 7" col col in
  Db.lista_p ctx.db
    ("WITH s AS (SELECT (date_trunc('week', now() AT TIME ZONE 'America/Lima') - interval '1 week' * g)::date AS ini FROM generate_series(11, 0, -1) g) "
   ^ "SELECT to_char(s.ini, 'YYYY-MM-DD') AS semana, "
   ^ "(SELECT round(avg((m.meta->>'confianza')::float8)::numeric, 3)::float8 FROM mensajes m WHERE m.rol = 'usuario' AND m.meta->>'confianza' IS NOT NULL AND " ^ semana "m.ts" ^ ") AS confianza_media, "
   ^ "(SELECT round((100.0 * count(*) FILTER (WHERE f.senal = 'pulgar_abajo') / nullif(count(*) FILTER (WHERE f.senal IN ('pulgar_arriba', 'pulgar_abajo')), 0))::numeric, 1)::float8 FROM feedback f WHERE " ^ semana "f.ts" ^ ") AS pulgar_abajo_pct, "
   ^ "(SELECT round((100.0 * count(*) FILTER (WHERE c.estado = 'resuelto_asistente' AND EXISTS (SELECT 1 FROM feedback f WHERE f.caso_id = c.id AND f.senal = 'se_resolvio') AND NOT EXISTS (SELECT 1 FROM incidencias i WHERE i.caso_id = c.id)) / nullif(count(*) FILTER (WHERE c.estado <> 'abierto'), 0))::numeric, 1)::float8 FROM casos c WHERE " ^ semana "c.inicio" ^ ") AS contencion_pct, "
   ^ "(SELECT round((100.0 * count(*) FILTER (WHERE coalesce((m.meta->>'frases_quitadas')::int, 0) > 0) / nullif(count(*), 0))::numeric, 1)::float8 FROM mensajes m WHERE m.rol = 'asistente' AND " ^ semana "m.ts" ^ ") AS frases_quitadas_pct, "
   ^ "(SELECT round((100.0 * count(*) FILTER (WHERE (m.meta->>'regenerada') = 'true') / nullif(count(*), 0))::numeric, 1)::float8 FROM mensajes m WHERE m.rol = 'asistente' AND " ^ semana "m.ts" ^ ") AS regeneradas_pct, "
   ^ "(SELECT round((sum(coalesce((m.meta->>'costo_usd')::float8, 0)) / nullif(count(DISTINCT m.caso_id), 0))::numeric, 5)::float8 FROM mensajes m WHERE m.rol = 'asistente' AND " ^ semana "m.ts" ^ ") AS costo_usd_por_caso "
   ^ "FROM s ORDER BY s.ini")
    (`Assoc [])

(* Una semana de la golden query `kpi` y un valor de su primera fila (None si ClickHouse no responde o la columna es NULL). *)
let golden_semana (ctx : Ctx.t) ~(kpi : string) ~(columna : string) ~(ini : string) ~(fin : string) : float option Lwt.t =
  let* r = Lwt.catch (fun () -> Lwt_unix.with_timeout 5. (fun () -> Api_reportes.golden_con_cache ctx ~kpi ~desde:ini ~hasta:fin)) (fun _ -> Lwt.return (Error (Motor.Inalcanzable "plazo"))) in
  Lwt.return (match r with Ok j -> (match Json.list "filas" j with f :: _ -> Json.float columna f | [] -> None) | Error _ -> None)

let calidad (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* () = sincronizar_modelos ctx in
  let* modelos = Db.lista_p ctx.db (seleccion_modelo ^ "ORDER BY id DESC LIMIT 20") (`Assoc []) in
  let* semanas = series_postgres ctx in
  (* Golden primero (cifra oficial); Postgres solo rellena lo que ClickHouse no dio. *)
  let* oficiales =
    Lwt_list.map_p
      (fun f ->
        let ini = Json.str_d "semana" "" f in
        let fin = Api_reportes.suma_dias ini 6 in
        let* q = golden_semana ctx ~kpi:"calidad_asistente" ~columna:"pct_con_frases_quitadas" ~ini ~fin in
        let* g = golden_semana ctx ~kpi:"calidad_asistente" ~columna:"pct_regeneradas" ~ini ~fin in
        let* c = golden_semana ctx ~kpi:"calidad_asistente" ~columna:"costo_usd_por_1000_casos" ~ini ~fin in
        let* ct = golden_semana ctx ~kpi:"contencion_asistente" ~columna:"porcentaje" ~ini ~fin in
        Lwt.return (q, g, c, ct))
      semanas
  in
  let combinar propio oficial = match oficial with Some v -> `Float v | None -> propio in
  let serie nombre extraer = `List (List.map2 (fun f o -> extraer f o) semanas oficiales) |> fun l -> (nombre, l) in
  let hay_oficial = List.exists (fun (q, g, c, ct) -> q <> None || g <> None || c <> None || ct <> None) oficiales in
  ok
    (`Assoc
      [ ("semanas", `List (List.map (fun f -> Json.get "semana" f) semanas));
        ("confianza_media", `List (List.map (fun f -> Json.get "confianza_media" f) semanas));
        ("pulgar_abajo_pct", `List (List.map (fun f -> Json.get "pulgar_abajo_pct" f) semanas));
        serie "contencion_pct" (fun f (_, _, _, ct) -> combinar (Json.get "contencion_pct" f) ct);
        serie "frases_quitadas_pct" (fun f (q, _, _, _) -> combinar (Json.get "frases_quitadas_pct" f) q);
        serie "regeneradas_pct" (fun f (_, g, _, _) -> combinar (Json.get "regeneradas_pct" f) g);
        (* El costo oficial es por 1000 casos; aqui por caso. *)
        serie "costo_usd_por_caso" (fun f (_, _, c, _) -> match c with Some v -> `Float (v /. 1000.) | None -> Json.get "costo_usd_por_caso" f);
        ("modelos", `List (List.map modelo_json modelos));
        ( "exactitud_por_version",
          `List (List.rev_map (fun m -> `Assoc [ ("version", Json.get "version" m); ("exactitud", Json.get "exactitud" m); ("macro_f1", Json.get "macro_f1" m); ("estado", Json.get "estado" m) ]) modelos) );
        ("fuente", `Assoc [ ("oficial", `Bool hay_oficial); ("detalle", `String (if hay_oficial then "Golden queries calidad_asistente y contencion_asistente; lo que ClickHouse no dio, de Postgres (operativo)." else "Postgres (cifras operativas, no oficiales): ClickHouse no respondió.")) ]) ])
