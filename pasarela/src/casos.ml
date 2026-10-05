(* Persistencia de la conversacion: personas, casos (sesion de 6 h), mensajes. Toda funcion recibe una conexion o
   transaccion (`Db.conn`): quien llama decide el limite transaccional. *)

let ( let* ) = Lwt.bind

type caso = { id : int; persona_id : int option; canal : string; etapa : string; memoria : Json.t; estado : string; pausado : bool; nuevo : bool }

let etapas = [ "recepcion"; "diagnostico"; "guia"; "incidencia"; "seguimiento"; "cierre"; "encuesta"; "consulta_estado" ]
let categorias = [ "correo"; "cuentas_accesos"; "red_wifi"; "vpn"; "impresoras"; "equipo"; "software_oficina"; "sistema_interno"; "telefonia"; "otro" ]

let recortar n s = if String.length s <= n then s else String.sub s 0 n

(* --- mensajes ------------------------------------------------------------------------------------------------------ *)

(* ¿Ya se proceso este mensaje de WhatsApp? (indice unico mensajes_wa_id_uq) *)
let existe_wa (c : Db.conn) (wa_id : string) : bool Lwt.t =
  let* f = Db.fila c "SELECT 1 AS x FROM mensajes WHERE meta->>'wa_id' = $wa_id LIMIT 1" (`Assoc [ ("wa_id", `String wa_id) ]) in
  Lwt.return (f <> `Null)

(* Inserta un mensaje (solo insercion), lo encola para analitica y, salvo `tocar=false`, renueva `ultimo_mensaje` del
   caso (la sesion de 6 h cuenta desde el ultimo mensaje). *)
let agregar_mensaje ?(tocar = true) ~(con_texto : bool) (c : Db.conn) ~(caso_id : int) ~(rol : string) ~(texto : string) ~(meta : Json.t) : int Lwt.t =
  let* id =
    Db.insertar c "INSERT INTO mensajes (caso_id, rol, texto, meta) VALUES ($i:caso_id, $rol, $texto, $j:meta)"
      (`Assoc [ ("caso_id", `Int caso_id); ("rol", `String rol); ("texto", `String (recortar 8000 texto)); ("meta", meta) ])
  in
  let* () = Analitica.encolar_mensaje ~con_texto c ~id in
  let* () =
    if tocar then Db.exec c "UPDATE casos SET ultimo_mensaje = now() WHERE id = $i:id" (`Assoc [ ("id", `Int caso_id) ]) else Lwt.return ()
  in
  Lwt.return id

(* --- personas -------------------------------------------------------------------------------------------------------- *)

let ultimos4 (s : string) : string =
  let n = String.length s in
  if n <= 4 then s else String.sub s (n - 4) 4

(* Persona de un entrante de WhatsApp: por telefono (alta si no existe); si no hay telefono (chat @lid), la del caso que ya
   exista para ese chat o una nueva. *)
let persona_whatsapp (c : Db.conn) ~(chat_id : string) ~(telefono : string option) ~(nombre : string) : int Lwt.t =
  match telefono with
  | Some tel ->
      Db.insertar c
        ("INSERT INTO personas (nombre, whatsapp) VALUES ($nombre, $wa) ON CONFLICT (whatsapp) DO UPDATE SET nombre = "
       ^ "CASE WHEN personas.nombre LIKE 'Contacto %' AND $real IS NOT NULL THEN $real ELSE personas.nombre END")
        (`Assoc
          [ ("nombre", `String (if nombre = "" then "Contacto " ^ ultimos4 tel else nombre)); ("wa", `String tel);
            ("real", if nombre = "" then `Null else `String nombre) ])
  | None -> (
      let* previo =
        Db.escalar_int c "SELECT persona_id FROM casos WHERE canal = 'whatsapp' AND chat_id = $chat AND persona_id IS NOT NULL ORDER BY id DESC LIMIT 1"
          (`Assoc [ ("chat", `String chat_id) ])
      in
      match previo with
      | Some id -> Lwt.return id
      | None ->
          Db.insertar c "INSERT INTO personas (nombre) VALUES ($nombre)"
            (`Assoc [ ("nombre", `String (if nombre = "" then "Contacto WhatsApp" else nombre)) ]))

(* Persona de una sesion web: una por sesion (quien escribe en el chat de prueba no es nadie conocido). *)
let persona_web (c : Db.conn) ~(sesion : string) : int Lwt.t =
  let* previo =
    Db.escalar_int c "SELECT persona_id FROM casos WHERE canal = 'web' AND chat_id = $chat AND persona_id IS NOT NULL ORDER BY id DESC LIMIT 1"
      (`Assoc [ ("chat", `String sesion) ])
  in
  match previo with
  | Some id -> Lwt.return id
  | None ->
      Db.insertar c "INSERT INTO personas (nombre, canal_preferido) VALUES ($nombre, 'web')"
        (`Assoc [ ("nombre", `String ("Visitante web " ^ recortar 6 sesion)) ])

(* --- casos ---------------------------------------------------------------------------------------------------------- *)

let caso_de_fila ~nuevo (f : Json.t) : caso =
  { id = Json.int_d "id" 0 f; persona_id = Json.int "persona_id" f; canal = Json.str_d "canal" "" f; etapa = Json.str_d "etapa" "recepcion" f;
    memoria = (match Json.get "memoria" f with `Assoc _ as m -> m | _ -> `Assoc []); estado = Json.str_d "estado" "abierto" f;
    pausado = Json.bool_d "pausado" false f; nuevo }

(* Caso de la conversacion (canal, chat_id). Sigue el mismo si hubo mensajes en las ultimas `sesion_horas` horas; despues
   abre uno nuevo. Excepcion: un caso pausado por un tecnico con una incidencia abierta se mantiene (la pausa humana no
   caduca sola mientras la incidencia siga abierta). *)
let sesion (c : Db.conn) ~(canal : string) ~(chat_id : string) ~(persona_id : int) ~(sesion_horas : float) : caso Lwt.t =
  let* previo =
    Db.fila c
      ("SELECT c.id, c.persona_id, c.canal, c.etapa, c.memoria, c.estado, c.pausado_por_tecnico AS pausado, "
     ^ "(now() - c.ultimo_mensaje) > make_interval(secs => $f:segundos) AS vencida, "
     ^ "EXISTS (SELECT 1 FROM incidencias i WHERE i.caso_id = c.id AND i.estado <> 'cerrada') AS incidencia_abierta "
     ^ "FROM casos c WHERE c.canal = $canal AND c.chat_id = $chat ORDER BY c.ultimo_mensaje DESC, c.id DESC LIMIT 1")
      (`Assoc [ ("segundos", `Float (sesion_horas *. 3600.)); ("canal", `String canal); ("chat", `String chat_id) ])
  in
  let reusar =
    previo <> `Null
    && ((not (Json.bool_d "vencida" false previo)) || (Json.bool_d "pausado" false previo && Json.bool_d "incidencia_abierta" false previo))
  in
  if reusar then Lwt.return (caso_de_fila ~nuevo:false previo)
  else
    let* f =
      Db.devolver c
        "INSERT INTO casos (persona_id, canal, chat_id) VALUES ($i:persona_id, $canal, $chat) RETURNING id, persona_id, canal, etapa, memoria, estado, pausado_por_tecnico AS pausado"
        (`Assoc [ ("persona_id", `Int persona_id); ("canal", `String canal); ("chat", `String chat_id) ])
    in
    let caso = caso_de_fila ~nuevo:true f in
    let* () = Analitica.encolar_caso c ~id:caso.id in
    Lwt.return caso

let cargar (c : Db.conn) (id : int) : caso option Lwt.t =
  let* f =
    Db.fila c "SELECT id, persona_id, canal, etapa, memoria, estado, pausado_por_tecnico AS pausado FROM casos WHERE id = $i:id" (`Assoc [ ("id", `Int id) ])
  in
  Lwt.return (if f = `Null then None else Some (caso_de_fila ~nuevo:false f))

(* Guarda la etapa, la ficha y, si se indica, el estado del caso; encola la foto del caso para analitica. *)
let guardar (c : Db.conn) ~(caso_id : int) ?etapa ?memoria ?estado () : unit Lwt.t =
  let* () =
    Db.exec c
      "UPDATE casos SET etapa = coalesce($etapa, etapa), memoria = coalesce($j:memoria, memoria), estado = coalesce($estado, estado), ultimo_mensaje = GREATEST(now(), ultimo_mensaje + interval '1 millisecond') WHERE id = $i:id"
      (`Assoc [ ("id", `Int caso_id); ("etapa", Json.opt_string etapa); ("memoria", (match memoria with Some m -> m | None -> `Null)); ("estado", Json.opt_string estado) ])
  in
  Analitica.encolar_caso c ~id:caso_id

let fijar_pausa (c : Db.conn) ~(caso_id : int) (pausado : bool) : unit Lwt.t =
  let* () = Db.exec c "UPDATE casos SET pausado_por_tecnico = $b:p, ultimo_mensaje = GREATEST(now(), ultimo_mensaje + interval '1 millisecond') WHERE id = $i:id" (`Assoc [ ("id", `Int caso_id); ("p", `Bool pausado) ]) in
  Analitica.encolar_caso c ~id:caso_id

(* --- lo que se le manda al agente ------------------------------------------------------------------------------------ *)

let historial (c : Db.conn) ~(caso_id : int) ~(limite : int) : Json.t list Lwt.t =
  Db.lista c
    ("SELECT rol, texto FROM (SELECT id, rol, texto FROM mensajes WHERE caso_id = $i:caso_id AND rol IN ('usuario', 'asistente', 'tecnico') "
   ^ "ORDER BY id DESC LIMIT $i:limite) x ORDER BY id")
    (`Assoc [ ("caso_id", `Int caso_id); ("limite", `Int limite) ])

let perfil (c : Db.conn) ~(persona_id : int) : Json.t Lwt.t =
  let* f =
    Db.fila c
      ("SELECT p.nombre, s.nombre AS sede, a.nombre AS area, p.vip, "
     ^ "coalesce((SELECT json_agg(ac.codigo ORDER BY ac.codigo) FROM activos ac WHERE ac.persona_id = p.id), '[]'::json) AS equipos "
     ^ "FROM personas p LEFT JOIN sedes s ON s.id = p.sede_id LEFT JOIN areas a ON a.id = p.area_id WHERE p.id = $i:id")
      (`Assoc [ ("id", `Int persona_id) ])
  in
  Lwt.return (if f = `Null then `Assoc [ ("nombre", `Null); ("sede", `Null); ("area", `Null); ("vip", `Bool false); ("equipos", `List []) ] else f)

let incidencias_abiertas (c : Db.conn) ~(persona_id : int) : Json.t list Lwt.t =
  Db.lista c
    ("SELECT i.numero, i.estado, i.titulo, ca.clave AS categoria, t.nombre AS tecnico, " ^ Db.iso "i.vence_resolucion_en" ^ " AS vence_resolucion_en "
   ^ "FROM incidencias i LEFT JOIN categorias ca ON ca.id = i.categoria_id LEFT JOIN tecnicos t ON t.id = i.tecnico_id "
   ^ "WHERE i.persona_id = $i:persona_id AND i.estado <> 'cerrada' ORDER BY i.creada_en DESC, i.id DESC LIMIT 5")
    (`Assoc [ ("persona_id", `Int persona_id) ])

let seleccion_incidencia =
  "SELECT i.id, i.numero, i.estado, i.titulo, i.prioridad, i.persona_id, i.caso_id, i.token_publico, ca.clave AS categoria, t.nombre AS tecnico, g.nombre AS grupo, "
  ^ Db.iso "i.vence_resolucion_en" ^ " AS vence_resolucion_en, " ^ Db.iso "i.vence_respuesta_en" ^ " AS vence_respuesta_en "
  ^ "FROM incidencias i LEFT JOIN categorias ca ON ca.id = i.categoria_id LEFT JOIN tecnicos t ON t.id = i.tecnico_id LEFT JOIN grupos g ON g.id = i.grupo_id "

(* La incidencia de la persona a la que se refiere el turno: la que dice el agente (solo si es SUYA) o, si no, la abierta
   ligada a este caso y, si no, la abierta mas reciente. None si no hay ninguna. *)
let incidencia_actual (c : Db.conn) ~(caso_id : int) ~(persona_id : int) ?numero () : Json.t option Lwt.t =
  let* f =
    match numero with
    | Some n ->
        Db.fila c (seleccion_incidencia ^ "WHERE i.numero = $numero AND i.persona_id = $i:persona_id LIMIT 1")
          (`Assoc [ ("numero", `String n); ("persona_id", `Int persona_id) ])
    | None ->
        Db.fila c
          (seleccion_incidencia
         ^ "WHERE i.persona_id = $i:persona_id AND i.estado <> 'cerrada' ORDER BY (i.caso_id IS NOT DISTINCT FROM $i:caso_id) DESC, i.creada_en DESC, i.id DESC LIMIT 1")
          (`Assoc [ ("persona_id", `Int persona_id); ("caso_id", `Int caso_id) ])
  in
  Lwt.return (if f = `Null then None else Some f)

let incidencias_abiertas_completas (c : Db.conn) ~(persona_id : int) : Json.t list Lwt.t =
  Db.lista c (seleccion_incidencia ^ "WHERE i.persona_id = $i:persona_id AND i.estado <> 'cerrada' ORDER BY i.creada_en DESC, i.id DESC LIMIT 5")
    (`Assoc [ ("persona_id", `Int persona_id) ])

(* Incidencia (abierta o no) de un id, con lo mismo. *)
let incidencia_por_id (c : Db.conn) (id : int) : Json.t option Lwt.t =
  let* f = Db.fila c (seleccion_incidencia ^ "WHERE i.id = $i:id") (`Assoc [ ("id", `Int id) ]) in
  Lwt.return (if f = `Null then None else Some f)

(* Registra el uso de un articulo (resolvio | sigue_igual | sin_respuesta) por cada clave que uso el agente. *)
let registrar_usos_articulos (c : Db.conn) ~(caso_id : int) ~(claves : string list) ~(resultado : string) : unit Lwt.t =
  Lwt_list.iter_s
    (fun clave ->
      Db.exec c
        (* La categoria del USO es la del caso (su ficha), no la del articulo: el bandido aprende por categoria. *)
        ("INSERT INTO articulo_usos (articulo_id, caso_id, categoria_id, resultado) "
       ^ "SELECT a.id, $i:caso_id, coalesce((SELECT ca.id FROM casos c JOIN categorias ca ON ca.clave = c.memoria->>'categoria' WHERE c.id = $i:caso_id), a.categoria_id), $resultado "
       ^ "FROM articulos a WHERE a.clave = $clave")
        (`Assoc [ ("caso_id", `Int caso_id); ("resultado", `String resultado); ("clave", `String clave) ]))
    claves
