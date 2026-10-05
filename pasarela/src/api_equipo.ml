(* Equipo: tecnicos (con carga actual, grupos, habilidades, turnos y ausencia) y grupos. Supervisor o mas. *)

let ( let* ) = Lwt.bind
open Api_util

let auditar (ctx : Ctx.t) (u : Auth.usuario) ~accion ~objeto detalle = Auditoria.registrar_p ~usuario_id:u.id ~objeto ~detalle ctx.db ~accion

(* Traduce una violacion de unicidad o de clave foranea a un error de validacion legible. *)
let con_errores_de_datos ~(unica : string) ~(referencia : string) (f : unit -> 'a Lwt.t) : 'a Lwt.t =
  Lwt.catch f (fun e ->
      if Db.es_unica_violada e then Errores.conflicto unica
      else if Db.es_referencia_violada e then Errores.invalido referencia
      else if Db.es_check_violado e then Errores.invalido "Alguno de los valores no está permitido."
      else Lwt.fail e)

(* --- tecnicos ---------------------------------------------------------------------------------------------------------------- *)

let seleccion_tecnico =
  "SELECT t.id, t.nombre, t.nivel, t.estado, t.capacidad, t.correo, t.whatsapp, NULL::text AS foto, "
  ^ "(SELECT count(*) FROM incidencias i WHERE i.tecnico_id = t.id AND i.estado NOT IN ('resuelta', 'cerrada'))::int AS carga, "
  ^ "coalesce((SELECT json_agg(json_build_object('id', g.id, 'nombre', g.nombre) ORDER BY g.nombre) FROM grupo_miembros m JOIN grupos g ON g.id = m.grupo_id WHERE m.tecnico_id = t.id), '[]'::json) AS grupos, "
  ^ "coalesce((SELECT json_agg(json_build_object('categoria', ca.clave, 'nivel', h.nivel) ORDER BY ca.clave) FROM habilidades h JOIN categorias ca ON ca.id = h.categoria_id WHERE h.tecnico_id = t.id), '[]'::json) AS habilidades, "
  ^ "coalesce((SELECT json_agg(json_build_object('dia_semana', tu.dia_semana, 'desde', to_char(tu.desde, 'HH24:MI'), 'hasta', to_char(tu.hasta, 'HH24:MI')) ORDER BY tu.dia_semana, tu.desde) FROM turnos tu WHERE tu.tecnico_id = t.id), '[]'::json) AS turnos, "
  ^ "(SELECT json_build_object('desde', " ^ Db.iso "a.desde" ^ ", 'hasta', " ^ Db.iso "a.hasta" ^ ", 'motivo', a.motivo) FROM ausencias a WHERE a.tecnico_id = t.id AND a.hasta > now() ORDER BY a.desde LIMIT 1) AS ausencia "
  ^ "FROM tecnicos t "

let listar_tecnicos (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let _, por, offset = paginacion req in
  let grupo = consulta_int req "grupo_id" in
  let filtro = "WHERE ($i:grupo IS NULL OR t.id IN (SELECT tecnico_id FROM grupo_miembros WHERE grupo_id = $i:grupo))" in
  let params = `Assoc [ ("grupo", Json.opt_int grupo); ("limite", `Int por); ("offset", `Int offset) ] in
  let* total = Db.fila_p ctx.db ("SELECT count(*) AS n FROM tecnicos t " ^ filtro) params in
  let* filas = Db.lista_p ctx.db (seleccion_tecnico ^ filtro ^ " ORDER BY t.nombre, t.id LIMIT $i:limite OFFSET $i:offset") params in
  let* rend = Api_reportes.rendimiento_por_tecnico ctx in
  lista (List.map (fun f -> Json.set "rendimiento" (match Hashtbl.find_opt rend (Json.int_d "id" 0 f) with Some r -> r | None -> `Null) f) filas) (Json.int_d "n" 0 total)

let tecnico_por_id (c : Db.conn) (id : int) : Json.t Lwt.t =
  let* f = Db.fila c (seleccion_tecnico ^ "WHERE t.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  if f = `Null then Errores.no_encontrado "No encontramos a esa persona." else Lwt.return f

let obtener_tecnico (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"técnico" req "id" in
  let* f = Db.usar ctx.db (fun c -> tecnico_por_id c id) in
  let* rend = Api_reportes.rendimiento_por_tecnico ctx in
  ok (Json.set "rendimiento" (match Hashtbl.find_opt rend id with Some r -> r | None -> `Null) f)

let validar_habilidades (b : Json.t) : (string * int) list option =
  match Json.get "habilidades" b with
  | `Null -> None
  | `List l ->
      Some
        (List.map
           (fun h ->
             let cat = en_lista ~nombre:"la categoría de la habilidad" Casos.categorias (texto_req ~max:40 ~nombre:"la categoría de la habilidad" h "categoria") in
             (cat, entero_req ~nombre:"el nivel de la habilidad" ~min:0 ~max:3 h "nivel"))
           l
        |> List.filter (fun (_, n) -> n > 0))
  | _ -> Errores.invalido "Las habilidades deben ser una lista."

let validar_turnos (b : Json.t) : (int * string * string) list option =
  match Json.get "turnos" b with
  | `Null -> None
  | `List l ->
      Some
        (List.map
           (fun t ->
             let dia = entero_req ~nombre:"el día del turno" ~min:1 ~max:7 t "dia_semana" in
             let desde = texto_req ~max:5 ~nombre:"la hora de inicio del turno" t "desde" and hasta = texto_req ~max:5 ~nombre:"la hora de fin del turno" t "hasta" in
             if not (hora_valida desde && hora_valida hasta) then Errores.invalido "Las horas del turno van como HH:MM, por ejemplo 08:30."
             else if desde >= hasta then Errores.invalido "Cada turno debe terminar después de empezar."
             else (dia, desde, hasta))
           l)
  | _ -> Errores.invalido "Los turnos deben ser una lista."

let validar_ids ~(nombre : string) (b : Json.t) (k : string) : int list option =
  match Json.get k b with
  | `Null -> None
  | `List l -> Some (List.map (fun v -> match Json.int_opt v with Some n when n > 0 -> n | _ -> Errores.invalido (Printf.sprintf "%s debe ser una lista de números." (String.capitalize_ascii nombre))) l)
  | _ -> Errores.invalido (Printf.sprintf "%s debe ser una lista de números." (String.capitalize_ascii nombre))

let aplicar_relaciones (c : Db.conn) (id : int) ~habilidades ~turnos ~grupos ~(ausencia : Json.t) : unit Lwt.t =
  let p = `Assoc [ ("t", `Int id) ] in
  let* () =
    match habilidades with
    | None -> Lwt.return ()
    | Some hs ->
        let* () = Db.exec c "DELETE FROM habilidades WHERE tecnico_id = $i:t" p in
        Lwt_list.iter_s
          (fun (cat, nivel) ->
            Db.exec c "INSERT INTO habilidades (tecnico_id, categoria_id, nivel) SELECT $i:t, ca.id, $i:nivel FROM categorias ca WHERE ca.clave = $cat"
              (`Assoc [ ("t", `Int id); ("nivel", `Int nivel); ("cat", `String cat) ]))
          hs
  in
  let* () =
    match turnos with
    | None -> Lwt.return ()
    | Some ts ->
        let* () = Db.exec c "DELETE FROM turnos WHERE tecnico_id = $i:t" p in
        Lwt_list.iter_s
          (fun (dia, desde, hasta) ->
            Db.exec c "INSERT INTO turnos (tecnico_id, dia_semana, desde, hasta) VALUES ($i:t, $i:dia, $desde::time, $hasta::time)"
              (`Assoc [ ("t", `Int id); ("dia", `Int dia); ("desde", `String desde); ("hasta", `String hasta) ]))
          ts
  in
  let* () =
    match grupos with
    | None -> Lwt.return ()
    | Some gs ->
        let* () = Db.exec c "DELETE FROM grupo_miembros WHERE tecnico_id = $i:t" p in
        Lwt_list.iter_s (fun g -> Db.exec c "INSERT INTO grupo_miembros (grupo_id, tecnico_id) VALUES ($i:g, $i:t) ON CONFLICT DO NOTHING" (`Assoc [ ("g", `Int g); ("t", `Int id) ])) gs
  in
  match ausencia with
  | `Null -> Lwt.return ()
  | `Assoc [] -> Lwt.return ()
  | `Assoc _ as a ->
      let desde = texto_req ~max:40 ~nombre:"el inicio de la ausencia" a "desde" and hasta = texto_req ~max:40 ~nombre:"el fin de la ausencia" a "hasta" in
      (match (Tiempo.de_iso desde, Tiempo.de_iso hasta) with
      | Some d, Some h when h > d -> ()
      | _ -> Errores.invalido "La ausencia necesita fechas válidas (ISO 8601) y terminar después de empezar.");
      Db.exec c "INSERT INTO ausencias (tecnico_id, desde, hasta, motivo) VALUES ($i:t, $desde::timestamptz, $hasta::timestamptz, $motivo)"
        (`Assoc [ ("t", `Int id); ("desde", `String desde); ("hasta", `String hasta); ("motivo", Json.opt_string (texto_opt ~max:200 ~nombre:"el motivo" a "motivo")) ])
  | _ -> Errores.invalido "La ausencia debe ser un objeto con «desde» y «hasta»."

let nivel_de b = match texto_opt ~max:2 ~nombre:"el nivel" b "nivel" with Some n -> Some (en_lista ~nombre:"el nivel" niveles n) | None -> None
let estado_de b = match texto_opt ~max:20 ~nombre:"el estado" b "estado" with Some e -> Some (en_lista ~nombre:"el estado" [ "activo"; "ausente"; "inactivo" ] e) | None -> None

let crear_tecnico (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let nombre = texto_req ~max:120 ~nombre:"el nombre del técnico" b "nombre" in
  let nivel = Option.value (nivel_de b) ~default:"N1" in
  let capacidad = Option.value (entero_opt ~nombre:"la capacidad" ~min:1 ~max:50 b "capacidad") ~default:8 in
  let correo = correo_opt ~nombre:"el correo" b "correo" and whatsapp = telefono_opt ~nombre:"el WhatsApp" b "whatsapp" in
  let habilidades = validar_habilidades b and turnos = validar_turnos b in
  let grupos = match validar_ids ~nombre:"los grupos" b "grupo_ids" with Some g -> Some g | None -> Option.map (fun g -> [ g ]) (entero_opt ~nombre:"el grupo" ~min:1 b "grupo_id") in
  let* id =
    con_errores_de_datos ~unica:"Ya existe un técnico con esos datos." ~referencia:"Algún grupo indicado no existe." (fun () ->
        Db.tx ctx.db (fun c ->
            let* id =
              Db.insertar c "INSERT INTO tecnicos (nombre, correo, whatsapp, nivel, estado, capacidad) VALUES ($nombre, $correo, $whatsapp, $nivel, $estado, $i:capacidad)"
                (`Assoc
                  [ ("nombre", `String nombre); ("correo", Json.opt_string correo); ("whatsapp", Json.opt_string whatsapp); ("nivel", `String nivel);
                    ("estado", `String (Option.value (estado_de b) ~default:"activo")); ("capacidad", `Int capacidad) ])
            in
            let* () = aplicar_relaciones c id ~habilidades ~turnos ~grupos ~ausencia:(Json.get "ausencia" b) in
            let* () = Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "tecnico:%d" id) ~accion:"tecnico_creado" ~detalle:(`Assoc [ ("nivel", `String nivel) ]) in
            Lwt.return id))
  in
  let* f = Db.usar ctx.db (fun c -> tecnico_por_id c id) in
  ok ~estado:201 f

let actualizar_tecnico (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"técnico" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let nombre = if Json.get "nombre" b = `Null then None else Some (texto_req ~max:120 ~nombre:"el nombre del técnico" b "nombre") in
  let correo = correo_opt ~nombre:"el correo" b "correo" and whatsapp = telefono_opt ~nombre:"el WhatsApp" b "whatsapp" in
  let capacidad = entero_opt ~nombre:"la capacidad" ~min:1 ~max:50 b "capacidad" in
  let habilidades = validar_habilidades b and turnos = validar_turnos b and grupos = validar_ids ~nombre:"los grupos" b "grupo_ids" in
  let* () =
    con_errores_de_datos ~unica:"Ya existe un técnico con esos datos." ~referencia:"Algún grupo indicado no existe." (fun () ->
        Db.tx ctx.db (fun c ->
            let* _ = tecnico_por_id c id in
            let* () =
              Db.exec c
                "UPDATE tecnicos SET nombre = coalesce($nombre, nombre), nivel = coalesce($nivel, nivel), estado = coalesce($estado, estado), capacidad = coalesce($i:capacidad, capacidad), correo = CASE WHEN $b:tiene_correo THEN $correo ELSE correo END, whatsapp = CASE WHEN $b:tiene_wa THEN $whatsapp ELSE whatsapp END WHERE id = $i:id"
                (`Assoc
                  [ ("id", `Int id); ("nombre", Json.opt_string nombre); ("nivel", Json.opt_string (nivel_de b)); ("estado", Json.opt_string (estado_de b)); ("capacidad", Json.opt_int capacidad);
                    ("tiene_correo", `Bool (Json.get "correo" b <> `Null)); ("correo", Json.opt_string correo); ("tiene_wa", `Bool (Json.get "whatsapp" b <> `Null)); ("whatsapp", Json.opt_string whatsapp) ])
            in
            let* () = aplicar_relaciones c id ~habilidades ~turnos ~grupos ~ausencia:(Json.get "ausencia" b) in
            Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "tecnico:%d" id) ~accion:"tecnico_actualizado"
              ~detalle:(`Assoc [ ("campos", `List (List.filter_map (fun (k, _) -> if k = "clave" then None else Some (`String k)) (Option.value (Json.assoc_opt b) ~default:[]))) ])))
  in
  let* f = Db.usar ctx.db (fun c -> tecnico_por_id c id) in
  ok f

(* --- grupos ----------------------------------------------------------------------------------------------------------------- *)

let seleccion_grupo =
  "SELECT g.id, g.nombre, g.nivel, g.escala_a_grupo_id, g.responsable_tecnico_id, coalesce((SELECT json_agg(m.tecnico_id ORDER BY m.tecnico_id) FROM grupo_miembros m WHERE m.grupo_id = g.id), '[]'::json) AS miembros FROM grupos g "

let listar_grupos (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* filas = Db.lista_p ctx.db (seleccion_grupo ^ "ORDER BY g.nivel, g.nombre") (`Assoc []) in
  lista filas (List.length filas)

let grupo_por_id (c : Db.conn) (id : int) : Json.t Lwt.t =
  let* f = Db.fila c (seleccion_grupo ^ "WHERE g.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  if f = `Null then Errores.no_encontrado "No encontramos ese grupo." else Lwt.return f

(* La cadena de escalamiento no puede dar vueltas: seguir `escala_a_grupo_id` desde el destino no debe volver al grupo. *)
let sin_ciclo (c : Db.conn) ~(id : int) ~(destino : int) : bool Lwt.t =
  let rec seguir actual pasos =
    if actual = id then Lwt.return false
    else if pasos > 10 then Lwt.return false
    else
      let* f = Db.fila c "SELECT escala_a_grupo_id FROM grupos WHERE id = $i:id" (`Assoc [ ("id", `Int actual) ]) in
      match Json.int "escala_a_grupo_id" f with None -> Lwt.return true | Some siguiente -> seguir siguiente (pasos + 1)
  in
  seguir destino 0

let escribir_grupo (ctx : Ctx.t) (u : Auth.usuario) ~(id : int option) (b : Json.t) : int Lwt.t =
  let nombre = if id = None || Json.get "nombre" b <> `Null then Some (texto_req ~max:80 ~nombre:"el nombre del grupo" b "nombre") else None in
  let nivel = match texto_opt ~max:2 ~nombre:"el nivel" b "nivel" with Some n -> Some (en_lista ~nombre:"el nivel" niveles n) | None -> None in
  let escala = entero_opt ~nombre:"el grupo siguiente" ~min:1 b "escala_a_grupo_id" in
  let responsable = entero_opt ~nombre:"el responsable" ~min:1 b "responsable_tecnico_id" in
  let miembros = validar_ids ~nombre:"los miembros" b "miembros" in
  con_errores_de_datos ~unica:"Ya existe un grupo con ese nombre." ~referencia:"El grupo siguiente, el responsable o algún miembro no existe." (fun () ->
      Db.tx ctx.db (fun c ->
          let* gid =
            match id with
            | None ->
                Db.insertar c "INSERT INTO grupos (nombre, nivel, escala_a_grupo_id, responsable_tecnico_id) VALUES ($nombre, $nivel, $i:escala, $i:resp)"
                  (`Assoc [ ("nombre", Json.opt_string nombre); ("nivel", `String (Option.value nivel ~default:"N1")); ("escala", Json.opt_int escala); ("resp", Json.opt_int responsable) ])
            | Some gid ->
                let* _ = grupo_por_id c gid in
                let* () =
                  Db.exec c
                    "UPDATE grupos SET nombre = coalesce($nombre, nombre), nivel = coalesce($nivel, nivel), escala_a_grupo_id = CASE WHEN $b:tiene_escala THEN $i:escala ELSE escala_a_grupo_id END, responsable_tecnico_id = CASE WHEN $b:tiene_resp THEN $i:resp ELSE responsable_tecnico_id END WHERE id = $i:id"
                    (`Assoc
                      [ ("id", `Int gid); ("nombre", Json.opt_string nombre); ("nivel", Json.opt_string nivel); ("tiene_escala", `Bool (List.mem_assoc "escala_a_grupo_id" (Option.value (Json.assoc_opt b) ~default:[])));
                        ("escala", Json.opt_int escala); ("tiene_resp", `Bool (List.mem_assoc "responsable_tecnico_id" (Option.value (Json.assoc_opt b) ~default:[]))); ("resp", Json.opt_int responsable) ])
                in
                Lwt.return gid
          in
          let* () =
            match escala with
            | Some dest ->
                let* bien = sin_ciclo c ~id:gid ~destino:dest in
                if bien then Lwt.return () else Errores.invalido "Un grupo no puede escalar a sí mismo ni formar un ciclo con otros."
            | None -> Lwt.return ()
          in
          let* () =
            match miembros with
            | None -> Lwt.return ()
            | Some ms ->
                let* () = Db.exec c "DELETE FROM grupo_miembros WHERE grupo_id = $i:g" (`Assoc [ ("g", `Int gid) ]) in
                Lwt_list.iter_s (fun t -> Db.exec c "INSERT INTO grupo_miembros (grupo_id, tecnico_id) VALUES ($i:g, $i:t) ON CONFLICT DO NOTHING" (`Assoc [ ("g", `Int gid); ("t", `Int t) ])) ms
          in
          let* () = Auditoria.registrar c ~usuario_id:u.id ~objeto:(Printf.sprintf "grupo:%d" gid) ~accion:(if id = None then "grupo_creado" else "grupo_actualizado") ~detalle:(`Assoc []) in
          Lwt.return gid))

let crear_grupo (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let* id = escribir_grupo ctx u ~id:None b in
  let* f = Db.usar ctx.db (fun c -> grupo_por_id c id) in
  ok ~estado:201 f

let actualizar_grupo (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"grupo" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let* _ = escribir_grupo ctx u ~id:(Some id) b in
  let* f = Db.usar ctx.db (fun c -> grupo_por_id c id) in
  ok f
