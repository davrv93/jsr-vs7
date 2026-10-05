(* Configuracion (administrador): categorias, calendarios, SLA, matriz de prioridad, reglas de escalamiento, usuarios y
   plantillas de avisos. Cada PUT valida todo ANTES de escribir y deja un registro en `auditoria`. El motor lee estas tablas en
   cada calculo: lo que se guarda aqui rige desde la siguiente peticion. *)

let ( let* ) = Lwt.bind
open Api_util

let auditar (ctx : Ctx.t) (u : Auth.usuario) ~accion ?(objeto = "configuracion") detalle = Auditoria.registrar_p ~usuario_id:u.id ~objeto ~detalle ctx.db ~accion

let items_de (b : Json.t) : Json.t list =
  match Json.get "items" b with `List l -> l | `Null -> Errores.invalido "Falta la lista «items»." | _ -> Errores.invalido "«items» debe ser una lista."

(* --- categorias ------------------------------------------------------------------------------------------------------------ *)

let leer_categorias (ctx : Ctx.t) : Json.t list Lwt.t =
  Db.lista_p ctx.db "SELECT id, clave, nombre, grupo_id, activa FROM categorias ORDER BY id" (`Assoc [])

let categorias (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* l = leer_categorias ctx in
  lista l (List.length l)

let guardar_categorias (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let items = items_de b in
  let validos =
    List.map
      (fun i ->
        ( entero_req ~nombre:"el id de la categoría" ~min:1 i "id",
          texto_opt ~max:80 ~nombre:"el nombre de la categoría" i "nombre",
          entero_opt ~nombre:"el grupo" ~min:1 i "grupo_id",
          bool_opt ~nombre:"«activa»" i "activa" ))
      items
  in
  let* () =
    Db.tx ctx.db (fun c ->
        Lwt_list.iter_s
          (fun (id, nombre, grupo, activa) ->
            Lwt.catch
              (fun () ->
                let* n =
                  Db.afectadas c "UPDATE categorias SET nombre = coalesce($nombre, nombre), grupo_id = coalesce($i:grupo, grupo_id), activa = coalesce($b:activa, activa) WHERE id = $i:id"
                    (`Assoc [ ("id", `Int id); ("nombre", Json.opt_string nombre); ("grupo", Json.opt_int grupo); ("activa", Json.opt_bool activa) ])
                in
                if n = 0 then Errores.no_encontrado "Alguna categoría de la lista no existe." else Lwt.return ())
              (fun e -> if Db.es_referencia_violada e then Errores.invalido "El grupo indicado no existe." else Lwt.fail e))
          validos)
  in
  let* () = auditar ctx u ~accion:"categorias_actualizadas" (`Assoc [ ("cantidad", `Int (List.length validos)) ]) in
  let* l = leer_categorias ctx in
  lista l (List.length l)

(* --- calendarios --------------------------------------------------------------------------------------------------------------- *)

let zonas_validas = [ "America/Lima"; "America/Bogota"; "America/Guayaquil"; "America/Mexico_City"; "America/Santiago"; "America/La_Paz"; "America/Argentina/Buenos_Aires"; "America/Sao_Paulo"; "UTC" ]

let leer_calendarios (ctx : Ctx.t) : Json.t list Lwt.t =
  Db.lista_p ctx.db
    "SELECT c.id, c.nombre, c.zona, c.veinticuatro_siete, c.horario, coalesce((SELECT json_agg(json_build_object('fecha', to_char(f.fecha, 'YYYY-MM-DD'), 'nombre', f.nombre) ORDER BY f.fecha) FROM feriados f WHERE f.calendario_id = c.id), '[]'::json) AS feriados FROM calendarios c ORDER BY c.id"
    (`Assoc [])

let calendarios (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* l = leer_calendarios ctx in
  lista l (List.length l)

(* horario: {"1": [["08:30","13:00"], ["14:00","18:00"]], ... "7": []} con tramos ordenados y sin solaparse. *)
let validar_horario (h : Json.t) : Json.t =
  match h with
  | `Assoc dias ->
      List.iter
        (fun (dia, tramos) ->
          if not (List.mem dia [ "1"; "2"; "3"; "4"; "5"; "6"; "7" ]) then Errores.invalido "Los días del horario van del 1 (lunes) al 7 (domingo).";
          match tramos with
          | `List l ->
              let pares =
                List.map
                  (function
                    | `List [ `String d; `String h ] when hora_valida d && hora_valida h ->
                        if d >= h then Errores.invalido "Cada tramo debe terminar después de empezar." else (d, h)
                    | _ -> Errores.invalido "Cada tramo del horario es un par de horas HH:MM, por ejemplo [\"08:30\", \"13:00\"].")
                  l
              in
              let rec sin_solape = function
                | (_, h1) :: ((d2, _) :: _ as resto) -> if h1 > d2 then Errores.invalido "Los tramos de un mismo día no pueden solaparse." else sin_solape resto
                | _ -> ()
              in
              sin_solape pares
          | _ -> Errores.invalido "Cada día del horario es una lista de tramos.")
        dias;
      h
  | _ -> Errores.invalido "El horario debe ser un objeto con los días 1 a 7."

let guardar_calendarios (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let items = items_de b in
  let validos =
    List.map
      (fun i ->
        let id = entero_req ~nombre:"el id del calendario" ~min:1 i "id" in
        let zona = Option.map (en_lista ~nombre:"la zona horaria" zonas_validas) (texto_opt ~max:60 ~nombre:"la zona horaria" i "zona") in
        let horario = match Json.get "horario" i with `Null -> None | h -> Some (validar_horario h) in
        let feriados =
          match Json.get "feriados" i with
          | `Null -> None
          | `List l ->
              Some
                (List.map
                   (fun f ->
                     let fecha = texto_req ~max:10 ~nombre:"la fecha del feriado" f "fecha" in
                     if not (fecha_valida fecha) then Errores.invalido "Las fechas de los feriados van como AAAA-MM-DD." else (fecha, texto_req ~max:80 ~nombre:"el nombre del feriado" f "nombre"))
                   l)
          | _ -> Errores.invalido "Los feriados deben ser una lista."
        in
        (id, texto_opt ~max:80 ~nombre:"el nombre del calendario" i "nombre", zona, bool_opt ~nombre:"«veinticuatro_siete»" i "veinticuatro_siete", horario, feriados))
      items
  in
  let* () =
    Db.tx ctx.db (fun c ->
        Lwt_list.iter_s
          (fun (id, nombre, zona, h24, horario, feriados) ->
            let* n =
              Lwt.catch
                (fun () ->
                  Db.afectadas c
                    "UPDATE calendarios SET nombre = coalesce($nombre, nombre), zona = coalesce($zona, zona), veinticuatro_siete = coalesce($b:h24, veinticuatro_siete), horario = coalesce($j:horario, horario) WHERE id = $i:id"
                    (`Assoc [ ("id", `Int id); ("nombre", Json.opt_string nombre); ("zona", Json.opt_string zona); ("h24", Json.opt_bool h24); ("horario", (match horario with Some h -> h | None -> `Null)) ]))
                (fun e -> if Db.es_unica_violada e then Errores.conflicto "Ya existe un calendario con ese nombre." else Lwt.fail e)
            in
            if n = 0 then Errores.no_encontrado "Algún calendario de la lista no existe."
            else
              match feriados with
              | None -> Lwt.return ()
              | Some fs ->
                  let* () = Db.exec c "DELETE FROM feriados WHERE calendario_id = $i:id" (`Assoc [ ("id", `Int id) ]) in
                  Lwt_list.iter_s
                    (fun (fecha, nombre) ->
                      Db.exec c "INSERT INTO feriados (calendario_id, fecha, nombre) VALUES ($i:id, $fecha::date, $nombre) ON CONFLICT (calendario_id, fecha) DO UPDATE SET nombre = EXCLUDED.nombre"
                        (`Assoc [ ("id", `Int id); ("fecha", `String fecha); ("nombre", `String nombre) ]))
                    fs)
          validos)
  in
  let* () = auditar ctx u ~accion:"calendarios_actualizados" (`Assoc [ ("cantidad", `Int (List.length validos)) ]) in
  let* l = leer_calendarios ctx in
  lista l (List.length l)

(* --- SLA ------------------------------------------------------------------------------------------------------------------------- *)

let leer_sla (ctx : Ctx.t) : Json.t list Lwt.t =
  Db.lista_p ctx.db
    "SELECT s.id, s.prioridad, ca.clave AS categoria, s.calendario_id, s.respuesta_min, s.resolucion_min FROM sla_politicas s LEFT JOIN categorias ca ON ca.id = s.categoria_id ORDER BY s.prioridad, ca.clave NULLS FIRST, s.id"
    (`Assoc [])

let sla (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* l = leer_sla ctx in
  lista l (List.length l)

let guardar_sla (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let items = items_de b in
  let validos =
    List.map
      (fun i ->
        let respuesta = entero_req ~nombre:"el plazo de primera respuesta" ~min:1 ~max:525_600 i "respuesta_min" in
        let resolucion = entero_req ~nombre:"el plazo de resolución" ~min:1 ~max:525_600 i "resolucion_min" in
        let prioridad = en_lista ~nombre:"la prioridad" prioridades (texto_req ~max:2 ~nombre:"la prioridad" i "prioridad") in
        if resolucion < respuesta then Errores.invalido (Printf.sprintf "En %s, la resolución no puede ser más corta que la primera respuesta." prioridad)
        else (Json.int "id" i, prioridad, texto_opt ~max:40 ~nombre:"la categoría" i "categoria", entero_opt ~nombre:"el calendario" ~min:1 i "calendario_id", respuesta, resolucion))
      items
  in
  let* () =
    Db.tx ctx.db (fun c ->
        Lwt_list.iter_s
          (fun (id, prioridad, categoria, calendario, respuesta, resolucion) ->
            Lwt.catch
              (fun () ->
                match id with
                | Some id ->
                    let* n =
                      Db.afectadas c "UPDATE sla_politicas SET calendario_id = coalesce($i:cal, calendario_id), respuesta_min = $i:resp, resolucion_min = $i:reso WHERE id = $i:id"
                        (`Assoc [ ("id", `Int id); ("cal", Json.opt_int calendario); ("resp", `Int respuesta); ("reso", `Int resolucion) ])
                    in
                    if n = 0 then Errores.no_encontrado "Alguna política de SLA de la lista no existe." else Lwt.return ()
                | None ->
                    (* Politica nueva (p. ej. un plazo propio para una categoria). Sin calendario, el de la politica general de esa prioridad. *)
                    let* existe =
                      Db.fila c "SELECT 1 AS x FROM sla_politicas s LEFT JOIN categorias ca ON ca.id = s.categoria_id WHERE s.prioridad = $prio AND ca.clave IS NOT DISTINCT FROM $cat"
                        (`Assoc [ ("prio", `String prioridad); ("cat", Json.opt_string categoria) ])
                    in
                    if existe <> `Null then Errores.conflicto (Printf.sprintf "Ya hay una política para %s con esa categoría." prioridad)
                    else
                      Db.exec c
                        "INSERT INTO sla_politicas (prioridad, categoria_id, calendario_id, respuesta_min, resolucion_min) SELECT $prio, (SELECT id FROM categorias WHERE clave = $cat), coalesce($i:cal, (SELECT calendario_id FROM sla_politicas WHERE prioridad = $prio AND categoria_id IS NULL LIMIT 1)), $i:resp, $i:reso"
                        (`Assoc [ ("prio", `String prioridad); ("cat", Json.opt_string categoria); ("cal", Json.opt_int calendario); ("resp", `Int respuesta); ("reso", `Int resolucion) ]))
              (fun e -> if Db.es_referencia_violada e then Errores.invalido "El calendario indicado no existe." else if Db.es_unica_violada e then Errores.conflicto "Ya existe esa política." else Lwt.fail e))
          validos)
  in
  let* () = auditar ctx u ~accion:"sla_actualizado" (`Assoc [ ("cantidad", `Int (List.length validos)) ]) in
  let* l = leer_sla ctx in
  lista l (List.length l)

(* --- matriz de prioridad -------------------------------------------------------------------------------------------------------- *)

let leer_matriz (ctx : Ctx.t) : Json.t list Lwt.t =
  Db.lista_p ctx.db
    "SELECT impacto, urgencia, prioridad FROM matriz_prioridad ORDER BY array_position(ARRAY['organizacion', 'sede', 'area', 'persona'], impacto), array_position(ARRAY['critica', 'alta', 'media', 'baja'], urgencia)"
    (`Assoc [])

let matriz (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* l = leer_matriz ctx in
  lista l (List.length l)

let guardar_matriz (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let validos =
    List.map
      (fun i ->
        ( en_lista ~nombre:"el impacto" impactos (texto_req ~max:20 ~nombre:"el impacto" i "impacto"),
          en_lista ~nombre:"la urgencia" urgencias (texto_req ~max:20 ~nombre:"la urgencia" i "urgencia"),
          en_lista ~nombre:"la prioridad" prioridades (texto_req ~max:2 ~nombre:"la prioridad" i "prioridad") ))
      (items_de b)
  in
  let* () =
    Db.tx ctx.db (fun c ->
        Lwt_list.iter_s
          (fun (impacto, urgencia, prioridad) ->
            Db.exec c
              "INSERT INTO matriz_prioridad (impacto, urgencia, prioridad) VALUES ($impacto, $urgencia, $prioridad) ON CONFLICT (impacto, urgencia) DO UPDATE SET prioridad = EXCLUDED.prioridad"
              (`Assoc [ ("impacto", `String impacto); ("urgencia", `String urgencia); ("prioridad", `String prioridad) ]))
          validos)
  in
  let* () = auditar ctx u ~accion:"matriz_actualizada" (`Assoc [ ("cantidad", `Int (List.length validos)) ]) in
  let* l = leer_matriz ctx in
  lista l (List.length l)

(* --- reglas de escalamiento ---------------------------------------------------------------------------------------------------------- *)

let descripcion_regla = function
  | "sla_75_respuesta" -> "Aviso al técnico al 75 % del plazo de primera respuesta"
  | "sla_75_resolucion" -> "Aviso al técnico al 75 % del plazo de resolución"
  | "sla_100_respuesta" -> "Escalamiento y aviso al responsable al vencer la primera respuesta"
  | "sla_100_resolucion" -> "Escalamiento y aviso al responsable al vencer la resolución"
  | "p1_creada" -> "Aviso a la guardia y al supervisor cuando se crea una P1"
  | "reapertura_2" -> "Escalamiento y aviso al supervisor a la segunda reapertura"
  | "queja" -> "Aviso al supervisor ante una queja o ánimo muy negativo"
  | "vip" -> "Aviso al supervisor cuando la persona es VIP"
  | "guia_agotada" -> "Nota cuando el asistente agotó la guía antes de abrir la incidencia"
  | otra -> otra

let leer_reglas (ctx : Ctx.t) : Json.t list Lwt.t =
  let* filas =
    Db.lista_p ctx.db
      "SELECT r.id, r.clave, r.version, r.activa, r.modo, r.condicion, r.acciones, (SELECT count(*) FROM escalamientos e WHERE e.regla_clave = r.clave AND e.ts > now() - interval '7 days')::int AS disparos_7d FROM escalamiento_reglas r WHERE r.version = (SELECT max(version) FROM escalamiento_reglas WHERE clave = r.clave) ORDER BY r.id"
      (`Assoc [])
  in
  (* La consola edita el porcentaje del plazo como `condicion.porcentaje`; el motor lo guarda como `umbral_pct`. Se muestra con los dos nombres. *)
  let con_alias f =
    let c = Json.obj "condicion" f in
    match Json.get "umbral_pct" c with `Null -> f | v -> Json.set "condicion" (Json.set "porcentaje" v c) f
  in
  Lwt.return (List.map (fun f -> Json.set "descripcion" (`String (descripcion_regla (Json.str_d "clave" "" f))) (con_alias f)) filas)

let reglas (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* l = leer_reglas ctx in
  lista l (List.length l)

let acciones_de_regla = [ "avisar_tecnico"; "escalar_nivel"; "avisar_responsable"; "avisar_guardia"; "avisar_supervisor"; "nota" ]

(* `activa` y `modo` se cambian en el sitio; cambiar la condicion o las acciones crea una VERSION NUEVA (las anteriores quedan,
   inactivas): `escalamientos` es unico por (incidencia, regla, version), asi que una regla distinta no debe heredar lo que ya disparo
   la anterior. La consola manda SIEMPRE condicion y acciones (y el porcentaje como `porcentaje`): se normalizan (`porcentaje` -> `umbral_pct`,
   acciones por tipo) y solo si de verdad cambian algo se publica una version nueva. *)
let normalizar_condicion (c : Json.t) : Json.t =
  match c with
  | `Assoc l ->
      let pct = match List.assoc_opt "porcentaje" l with Some v -> Some v | None -> None in
      let l = List.remove_assoc "porcentaje" l in
      let l = match pct with Some v -> ("umbral_pct", v) :: List.remove_assoc "umbral_pct" l | None -> l in
      `Assoc (List.sort compare l)
  | otro -> otro

let tipos_de_acciones (a : Json.t) : string list = List.filter_map (Json.str "tipo") (match a with `List l -> l | _ -> [])

let guardar_regla (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"regla" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let modo = Option.map (en_lista ~nombre:"el modo" [ "sombra"; "activo" ]) (texto_opt ~max:10 ~nombre:"el modo" b "modo") in
  let activa = bool_opt ~nombre:"«activa»" b "activa" in
  let condicion = match Json.get "condicion" b with `Null -> None | `Assoc _ as c -> Some (normalizar_condicion c) | _ -> Errores.invalido "La condición debe ser un objeto." in
  (match condicion with
  | Some c -> (
      match Json.get "umbral_pct" c with
      | `Null -> ()
      | v -> ( match Json.int_opt v with Some n when n >= 1 && n <= 200 -> () | _ -> Errores.invalido "El porcentaje del plazo debe estar entre 1 y 200."))
  | None -> ());
  let acciones_pedidas =
    match Json.get "acciones" b with
    | `Null -> None
    | `List l ->
        List.iter (fun a -> ignore (en_lista ~nombre:"el tipo de acción" acciones_de_regla (texto_req ~max:30 ~nombre:"el tipo de acción" a "tipo"))) l;
        Some (`List l)
    | _ -> Errores.invalido "Las acciones deben ser una lista."
  in
  let* actual = Db.fila_p ctx.db "SELECT id, clave, version, activa, modo, condicion, acciones FROM escalamiento_reglas WHERE id = $i:id" (`Assoc [ ("id", `Int id) ]) in
  if actual = `Null then Errores.no_encontrado "No encontramos esa regla."
  else begin
    (* Cambia de verdad la definicion? *)
    let condicion = match condicion with Some c when c <> normalizar_condicion (Json.get "condicion" actual) -> Some c | _ -> None in
    let acciones =
      match acciones_pedidas with
      | Some (`List nuevas as a) when tipos_de_acciones a <> tipos_de_acciones (Json.get "acciones" actual) ->
          (* Se conservan los objetos completos (p. ej. el texto de una nota) de las acciones que siguen. *)
          let previas = match Json.get "acciones" actual with `List l -> l | _ -> [] in
          Some (`List (List.map (fun n -> match List.find_opt (fun p -> Json.str "tipo" p = Json.str "tipo" n) previas with Some p -> p | None -> n) nuevas))
      | _ -> None
    in
    let cambia_definicion = condicion <> None || acciones <> None in
    let* id_final =
      Db.tx ctx.db (fun c ->
          if cambia_definicion then begin
            let clave = Json.str_d "clave" "" actual in
            let* nueva =
              Db.insertar c
                "INSERT INTO escalamiento_reglas (clave, version, activa, modo, condicion, acciones) SELECT clave, (SELECT max(version) + 1 FROM escalamiento_reglas WHERE clave = $clave), coalesce($b:activa, activa), coalesce($modo, modo), coalesce($j:condicion, condicion), coalesce($j:acciones, acciones) FROM escalamiento_reglas WHERE id = $i:id"
                (`Assoc
                  [ ("clave", `String clave); ("id", `Int id); ("activa", Json.opt_bool activa); ("modo", Json.opt_string modo);
                    ("condicion", (match condicion with Some c -> c | None -> `Null)); ("acciones", (match acciones with Some a -> a | None -> `Null)) ])
            in
            let* () = Db.exec c "UPDATE escalamiento_reglas SET activa = false WHERE clave = $clave AND id <> $i:nueva" (`Assoc [ ("clave", `String clave); ("nueva", `Int nueva) ]) in
            Lwt.return nueva
          end
          else
            let* () =
              Db.exec c "UPDATE escalamiento_reglas SET activa = coalesce($b:activa, activa), modo = coalesce($modo, modo) WHERE id = $i:id"
                (`Assoc [ ("id", `Int id); ("activa", Json.opt_bool activa); ("modo", Json.opt_string modo) ])
            in
            Lwt.return id)
    in
    let* () =
      auditar ctx u ~accion:"regla_escalamiento_actualizada" ~objeto:(Printf.sprintf "regla:%d" id_final)
        (`Assoc [ ("clave", Json.get "clave" actual); ("modo", Json.opt_string modo); ("activa", Json.opt_bool activa); ("version_nueva", `Bool cambia_definicion) ])
    in
    let* todas = leer_reglas ctx in
    match List.find_opt (fun r -> Json.int "id" r = Some id_final) todas with Some r -> ok r | None -> ok (`Assoc [ ("id", `Int id_final) ])
  end

(* --- usuarios de la consola --------------------------------------------------------------------------------------------------------- *)

let seleccion_usuario = "SELECT id, email, nombre, rol, tecnico_id, activo FROM usuarios_consola "

let usuarios (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* l = Db.lista_p ctx.db (seleccion_usuario ^ "ORDER BY id") (`Assoc []) in
  lista l (List.length l)

let rol_valido (s : string) : string = en_lista ~nombre:"el rol" (List.map Roles.a_string Roles.todos) s

let clave_valida (s : string) : string =
  if String.length s < 10 then Errores.invalido "La clave debe tener al menos 10 caracteres."
  else if String.length s > 200 then Errores.invalido "La clave es demasiado larga."
  else s

let crear_usuario (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let email = match correo_opt ~nombre:"el correo" b "email" with Some e -> e | None -> Errores.invalido "Falta el correo." in
  let nombre = texto_req ~max:120 ~nombre:"el nombre" b "nombre" in
  let rol = rol_valido (texto_req ~max:20 ~nombre:"el rol" b "rol") in
  let clave = clave_valida (texto_req ~min:1 ~max:200 ~nombre:"la clave" b "clave") in
  let tecnico_id = entero_opt ~nombre:"el técnico" ~min:1 b "tecnico_id" in
  let* hash = Auth.hash_en_hilo ~iteraciones:ctx.cfg.pbkdf2_iter clave in
  let* id =
    Lwt.catch
      (fun () ->
        Db.insertar_p ctx.db "INSERT INTO usuarios_consola (email, nombre, rol, tecnico_id, clave_hash) VALUES ($email, $nombre, $rol, $i:tec, $hash)"
          (`Assoc [ ("email", `String email); ("nombre", `String nombre); ("rol", `String rol); ("tec", Json.opt_int tecnico_id); ("hash", `String hash) ]))
      (fun e ->
        if Db.es_unica_violada e then Errores.conflicto "Ya existe un usuario con ese correo."
        else if Db.es_referencia_violada e then Errores.invalido "El técnico indicado no existe."
        else Lwt.fail e)
  in
  let* () = auditar ctx u ~accion:"usuario_creado" ~objeto:(Printf.sprintf "usuario:%d" id) (`Assoc [ ("rol", `String rol) ]) in
  let* f = Db.fila_p ctx.db (seleccion_usuario ^ "WHERE id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  ok ~estado:201 f

let actualizar_usuario (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let id = id_de_ruta ~que:"usuario" req "id" in
  let* b = Seguridad.cuerpo_json req in
  let rol = Option.map rol_valido (texto_opt ~max:20 ~nombre:"el rol" b "rol") in
  let nombre = texto_opt ~max:120 ~nombre:"el nombre" b "nombre" in
  let activo = bool_opt ~nombre:"«activo»" b "activo" in
  let tecnico_id = entero_opt ~nombre:"el técnico" ~min:1 b "tecnico_id" in
  let clave = match Json.str "clave" b with Some c when c <> "" -> Some (clave_valida c) | _ -> None in
  if id = u.id && ((match rol with Some r -> r <> "admin" | None -> false) || activo = Some false) then
    Errores.conflicto "No puedes quitarte tu propio rol de administrador ni desactivarte."
  else begin
    let* hash = match clave with Some c -> Lwt.map Option.some (Auth.hash_en_hilo ~iteraciones:ctx.cfg.pbkdf2_iter c) | None -> Lwt.return None in
    let* n =
      Lwt.catch
        (fun () ->
          Db.afectadas_p ctx.db
            "UPDATE usuarios_consola SET rol = coalesce($rol, rol), nombre = coalesce($nombre, nombre), activo = coalesce($b:activo, activo), tecnico_id = coalesce($i:tec, tecnico_id), clave_hash = coalesce($hash, clave_hash) WHERE id = $i:id"
            (`Assoc [ ("id", `Int id); ("rol", Json.opt_string rol); ("nombre", Json.opt_string nombre); ("activo", Json.opt_bool activo); ("tec", Json.opt_int tecnico_id); ("hash", Json.opt_string hash) ]))
        (fun e -> if Db.es_referencia_violada e then Errores.invalido "El técnico indicado no existe." else Lwt.fail e)
    in
    if n = 0 then Errores.no_encontrado "No encontramos a ese usuario."
    else begin
      let* () =
        auditar ctx u ~accion:"usuario_actualizado" ~objeto:(Printf.sprintf "usuario:%d" id)
          (`Assoc [ ("rol", Json.opt_string rol); ("activo", Json.opt_bool activo); ("clave_cambiada", `Bool (clave <> None)) ])
      in
      let* f = Db.fila_p ctx.db (seleccion_usuario ^ "WHERE id = $i:id") (`Assoc [ ("id", `Int id) ]) in
      ok f
    end
  end

(* --- plantillas de avisos --------------------------------------------------------------------------------------------------------- *)

let plantillas (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* todas = Avisos_plantillas.cargar ctx.db in
  ok (`Assoc [ ("plantillas", `Assoc (List.map (fun (k, v) -> (k, `String v)) todas)); ("huecos", `List (List.map (fun h -> `String h) Textos.claves_plantilla)) ])

let guardar_plantillas (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json req in
  let nuevas =
    match Json.get "plantillas" b with
    | `Assoc l ->
        List.map
          (fun (k, v) ->
            if not (List.mem_assoc k Textos.plantillas_por_defecto) then Errores.invalido (Printf.sprintf "La plantilla «%s» no existe." k)
            else
              match v with
              | `String s when String.trim s <> "" && String.length s <= 600 -> (
                  match Textos.huecos_invalidos s with
                  | [] -> (k, String.trim s)
                  | malos -> Errores.invalido (Printf.sprintf "La plantilla «%s» usa huecos que no existen: %s." k (String.concat ", " malos)))
              | _ -> Errores.invalido (Printf.sprintf "La plantilla «%s» debe ser un texto de hasta 600 caracteres." k))
          l
    | _ -> Errores.invalido "Falta el objeto «plantillas»."
  in
  let* actuales = Avisos_plantillas.cargar ctx.db in
  let todas = nuevas @ List.filter (fun (k, _) -> not (List.mem_assoc k nuevas)) actuales in
  let* () = Avisos_plantillas.guardar ctx.db todas in
  let* () = auditar ctx u ~accion:"plantillas_avisos_actualizadas" (`Assoc [ ("cambiadas", `List (List.map (fun (k, _) -> `String k) nuevas)) ]) in
  let* todas = Avisos_plantillas.cargar ctx.db in
  ok (`Assoc [ ("plantillas", `Assoc (List.map (fun (k, v) -> (k, `String v)) todas)) ])
