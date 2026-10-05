(* Acceso a Postgres con Caqti.

   REGLA: ningun valor de usuario toca el texto SQL. Todos los valores viajan en UN parametro (`$1`, un objeto JSON)
   y el SQL los lee con marcadores `$nombre` (texto), `$i:nombre` (bigint), `$f:` (float8), `$b:` (boolean),
   `$t:` (timestamptz) y `$j:` (jsonb). `sustituir` convierte cada marcador en `($1::text::jsonb->>'nombre')` con su
   conversion; el nombre sale del propio SQL fuente, nunca de la entrada. Es la tecnica que permite consultas con
   filtros opcionales (`$estado IS NULL OR estado = $estado`) sin construir SQL por concatenacion.

   Las consultas devuelven JSON hecho por Postgres (una fila, una columna de texto): el codigo OCaml no necesita un
   tipo por cada consulta, y las listas salen ya con la forma que espera la consola. *)

module Pool = Caqti_lwt_unix.Pool

type t = (Caqti_lwt.connection, Caqti_error.t) Pool.t
type conn = Caqti_lwt.connection

exception Db_error of string

let ( let* ) = Lwt.bind

(* El mensaje de PostgreSQL puede traer el valor ofensor tras DETAIL (un telefono, un correo): se corta ahi. *)
let limpiar_mensaje (m : string) : string =
  let m = match Re.exec_opt (Re.compile (Re.str "DETAIL")) m with Some g -> String.sub m 0 (fst (Re.Group.offset g 0)) | None -> m in
  if String.length m > 300 then String.sub m 0 300 else m

let ok = function Ok v -> v | Error e -> raise (Db_error (limpiar_mensaje (Caqti_error.show e)))

let contiene (sub : string) (s : string) = Re.execp (Re.compile (Re.str sub)) s

let es_unica_violada = function Db_error m -> contiene "duplicate key" m || contiene "23505" m | _ -> false
let es_referencia_violada = function Db_error m -> contiene "foreign key" m || contiene "23503" m | _ -> false
let es_check_violado = function Db_error m -> contiene "check constraint" m || contiene "23514" m | _ -> false

(* --- sustitucion de marcadores ------------------------------------------------------------------------------ *)

let re_marcador =
  Re.(compile (seq [ char '$'; opt (seq [ set "ifbtj"; char ':' ]); group (seq [ alt [ rg 'a' 'z'; char '_' ]; rep (alt [ rg 'a' 'z'; rg '0' '9'; char '_' ]) ]) ]))

let sustituir (sql : string) : string =
  Re.replace re_marcador sql ~f:(fun g ->
      let todo = Re.Group.get g 0 and nombre = Re.Group.get g 1 in
      let tipo = if String.length todo > 2 && todo.[2] = ':' then Some todo.[1] else None in
      let base = "($1::text::jsonb" in
      match tipo with
      | None -> Printf.sprintf "%s->>'%s')" base nombre
      | Some 'i' -> Printf.sprintf "(%s->>'%s')::bigint)" base nombre
      | Some 'f' -> Printf.sprintf "(%s->>'%s')::float8)" base nombre
      | Some 'b' -> Printf.sprintf "(%s->>'%s')::boolean)" base nombre
      | Some 't' -> Printf.sprintf "(%s->>'%s')::timestamptz)" base nombre
      (* Un null JSON llega como SQL NULL (sin esto, `coalesce($j:x, columna)` guardaria el literal jsonb null). *)
      | Some 'j' -> Printf.sprintf "NULLIF(%s->'%s'), 'null'::jsonb)" base nombre
      | Some _ -> todo)

(* --- peticiones (con cache: el SQL de la aplicacion es un conjunto finito de literales) ------------------------- *)

let cache_json : (string, (string, string, [ `One ]) Caqti_request.t) Hashtbl.t = Hashtbl.create 128
let cache_unit : (string, (string, unit, [ `Zero ]) Caqti_request.t) Hashtbl.t = Hashtbl.create 64
(* Sentencias que no usan ningun marcador: PostgreSQL no puede tipar un `$1` que nadie usa, asi que van sin parametro. *)
let cache_json0 : (string, (unit, string, [ `One ]) Caqti_request.t) Hashtbl.t = Hashtbl.create 16
let cache_unit0 : (string, (unit, unit, [ `Zero ]) Caqti_request.t) Hashtbl.t = Hashtbl.create 16

let usa_parametro (sql : string) : bool = Re.execp (Re.compile (Re.str "$1")) sql

let req_json0 sql =
  match Hashtbl.find_opt cache_json0 sql with
  | Some r -> r
  | None ->
      let r = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.string) sql in
      Hashtbl.add cache_json0 sql r;
      r

let req_unit0 sql =
  match Hashtbl.find_opt cache_unit0 sql with
  | Some r -> r
  | None ->
      let r = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) sql in
      Hashtbl.add cache_unit0 sql r;
      r

let req_json sql =
  match Hashtbl.find_opt cache_json sql with
  | Some r -> r
  | None ->
      let r = Caqti_request.Infix.(Caqti_type.string ->! Caqti_type.string) sql in
      Hashtbl.add cache_json sql r;
      r

let req_unit sql =
  match Hashtbl.find_opt cache_unit sql with
  | Some r -> r
  | None ->
      let r = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) sql in
      Hashtbl.add cache_unit sql r;
      r

(* --- conexion y pool ------------------------------------------------------------------------------------------- *)

let conectar ?(max = 8) (url : string) : t =
  let uri = Uri.of_string url in
  let pool_config = Caqti_pool_config.create ~max_size:max () in
  let post_connect (module C : Caqti_lwt.CONNECTION) =
    let* r = C.exec (Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) "SET TIME ZONE 'UTC'") () in
    match r with Error e -> Lwt.return (Error (e :> Caqti_error.t)) | Ok () -> Lwt.return (Ok ())
  in
  match Caqti_lwt_unix.connect_pool ~pool_config ~post_connect uri with
  | Ok p -> p
  | Error e -> raise (Db_error ("no se pudo preparar la conexion a la base: " ^ limpiar_mensaje (Caqti_error.show e)))

let usar (pool : t) (f : conn -> 'a Lwt.t) : 'a Lwt.t =
  let* r = Pool.use (fun c -> Lwt.map (fun v -> Ok v) (f c)) pool in
  Lwt.return (ok r)

(* Transaccion: confirma si `f` termina, revierte si lanza (y relanza). *)
let tx (pool : t) (f : conn -> 'a Lwt.t) : 'a Lwt.t =
  usar pool (fun c ->
      let (module C : Caqti_lwt.CONNECTION) = c in
      let* () = Lwt.map ok (C.start ()) in
      Lwt.catch
        (fun () ->
          let* v = f c in
          let* () = Lwt.map ok (C.commit ()) in
          Lwt.return v)
        (fun e ->
          let* _ = C.rollback () in
          Lwt.fail e))

(* --- consultas ---------------------------------------------------------------------------------------------------- *)

let texto (c : conn) (sql : string) (params : Json.t) : string Lwt.t =
  let (module C : Caqti_lwt.CONNECTION) = c in
  let sql = sustituir sql in
  if usa_parametro sql then Lwt.map ok (C.find (req_json sql) (Json.to_string params)) else Lwt.map ok (C.find (req_json0 sql) ())

let parse_resultado s = match Json.parse s with Ok j -> j | Error m -> raise (Db_error ("la base devolvio JSON no valido: " ^ m))

(* `sql` ya devuelve UNA fila con UNA columna json/jsonb/text con JSON. *)
let json (c : conn) sql params : Json.t Lwt.t = Lwt.map parse_resultado (texto c sql params)

(* Envuelve un SELECT cualquiera: lista de objetos (una clave por columna). *)
let lista (c : conn) sql params : Json.t list Lwt.t =
  let* j = json c ("SELECT coalesce(json_agg(t), '[]'::json)::text FROM (" ^ sql ^ ") t") params in
  Lwt.return (match j with `List l -> l | _ -> [])

(* La primera fila como objeto, o `Null si no hay ninguna. *)
let fila (c : conn) sql params : Json.t Lwt.t =
  json c ("SELECT coalesce((SELECT row_to_json(t) FROM (" ^ sql ^ ") t LIMIT 1)::text, 'null')") params

(* Sentencia sin resultado. *)
let exec (c : conn) (sql : string) (params : Json.t) : unit Lwt.t =
  let (module C : Caqti_lwt.CONNECTION) = c in
  let sql = sustituir sql in
  if usa_parametro sql then Lwt.map ok (C.exec (req_unit sql) (Json.to_string params)) else Lwt.map ok (C.exec (req_unit0 sql) ())

(* INSERT/UPDATE/DELETE sin RETURNING: devuelve cuantas filas toco. *)
let afectadas (c : conn) (sql : string) (params : Json.t) : int Lwt.t =
  let* t = texto c ("WITH r AS (" ^ sql ^ " RETURNING 1) SELECT count(*)::text FROM r") params in
  Lwt.return (try int_of_string t with _ -> 0)

(* DML con RETURNING: la primera fila devuelta como objeto (o `Null). El SQL lleva su propio RETURNING. *)
let devolver (c : conn) (sql : string) (params : Json.t) : Json.t Lwt.t =
  json c ("WITH r AS (" ^ sql ^ ") SELECT coalesce((SELECT row_to_json(r) FROM r LIMIT 1)::text, 'null')") params

let devolver_lista (c : conn) (sql : string) (params : Json.t) : Json.t list Lwt.t =
  let* j = json c ("WITH r AS (" ^ sql ^ ") SELECT coalesce((SELECT json_agg(r) FROM r)::text, '[]')") params in
  Lwt.return (match j with `List l -> l | _ -> [])

(* INSERT sin RETURNING -> el id nuevo (la tabla debe tener columna id). *)
let insertar (c : conn) (sql : string) (params : Json.t) : int Lwt.t =
  let* f = devolver c (sql ^ " RETURNING id") params in
  Lwt.return (Json.int_d "id" 0 f)

(* Un escalar bigint de un SELECT de una columna (la primera fila), o None. *)
let escalar_int (c : conn) sql params : int option Lwt.t =
  let* f = fila c sql params in
  Lwt.return (match f with `Assoc ((_, v) :: _) -> Json.int_opt v | _ -> None)

let escalar_str (c : conn) sql params : string option Lwt.t =
  let* f = fila c sql params in
  Lwt.return (match f with `Assoc ((_, `String s) :: _) -> Some s | _ -> None)

(* Atajos con pool para lecturas sueltas. *)
let lista_p pool sql params = usar pool (fun c -> lista c sql params)
let fila_p pool sql params = usar pool (fun c -> fila c sql params)
let json_p pool sql params = usar pool (fun c -> json c sql params)
let exec_p pool sql params = usar pool (fun c -> exec c sql params)
let insertar_p pool sql params = usar pool (fun c -> insertar c sql params)
let afectadas_p pool sql params = usar pool (fun c -> afectadas c sql params)
let escalar_int_p pool sql params = usar pool (fun c -> escalar_int c sql params)

(* --- fragmentos SQL estaticos ------------------------------------------------------------------------------------- *)

(* Marca de tiempo ISO 8601 UTC con milisegundos. */ *)
let iso (col : string) : string = Printf.sprintf "to_char(%s AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')" col

(* Escapa los comodines de LIKE en un texto que escribio una persona, para usarlo con ESCAPE '\\'. *)
let escapar_like (s : string) : string =
  let b = Buffer.create (String.length s + 4) in
  String.iter
    (fun c ->
      if c = '%' || c = '_' || c = '\\' then Buffer.add_char b '\\';
      Buffer.add_char b c)
    s;
  Buffer.contents b
