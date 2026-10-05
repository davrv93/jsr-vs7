(* Seguridad HTTP: cabeceras, CORS restringido, limite de tamaño de cuerpo, IP del cliente, registro sin datos personales y
   traduccion de errores a la forma {error, codigo} del contrato. *)

let ( let* ) = Lwt.bind

(* --- IP del cliente --------------------------------------------------------------------------------------------------- *)

let sin_puerto (s : string) : string =
  (* «1.2.3.4:5678» -> «1.2.3.4»; «[::1]:80» -> «::1»; sin puerto, igual. *)
  if String.length s > 0 && s.[0] = '[' then (match String.index_opt s ']' with Some i -> String.sub s 1 (i - 1) | None -> s)
  else
    match String.rindex_opt s ':' with
    | Some i when String.contains s '.' -> String.sub s 0 i
    | _ -> s

(* Detras de nginx (CONFIAR_PROXY=1) la IP real es X-Real-IP o la ULTIMA de X-Forwarded-For (la que anadio nuestro proxy;
   las anteriores las puede escribir cualquiera). Sin proxy de confianza, la del socket. *)
let ip (cfg : Config.t) (req : Dream.request) : string =
  let socket = sin_puerto (Dream.client req) in
  if not cfg.confiar_proxy then socket
  else
    match Dream.header req "X-Real-IP" with
    | Some r when String.trim r <> "" -> String.trim r
    | _ -> (
        match Dream.header req "X-Forwarded-For" with
        | Some xff when String.trim xff <> "" ->
            let partes = String.split_on_char ',' xff |> List.map String.trim |> List.filter (fun x -> x <> "") in
            (match List.rev partes with ultima :: _ -> ultima | [] -> socket)
        | _ -> socket)

(* --- cuerpo ------------------------------------------------------------------------------------------------------------------- *)

(* Lee el cuerpo con tope: rechaza por Content-Length y, si el cliente miente o usa chunked, al pasar el tope. *)
let leer_cuerpo ?(max = 262_144) (req : Dream.request) : string Lwt.t =
  (match Option.bind (Dream.header req "Content-Length") int_of_string_opt with
  | Some n when n > max -> raise (Errores.Api (413, "invalido", "El mensaje es demasiado grande."))
  | _ -> ());
  let stream = Dream.body_stream req in
  let buf = Buffer.create 1024 in
  let rec bucle () =
    let* trozo = Dream.read stream in
    match trozo with
    | None -> Lwt.return (Buffer.contents buf)
    | Some t ->
        Buffer.add_string buf t;
        if Buffer.length buf > max then raise (Errores.Api (413, "invalido", "El mensaje es demasiado grande.")) else bucle ()
  in
  bucle ()

(* Cuerpo JSON de un objeto. Vacio = objeto vacio. Lo que no sea un objeto JSON es un error de validacion. *)
let cuerpo_json ?max (req : Dream.request) : Json.t Lwt.t =
  let* s = leer_cuerpo ?max req in
  if String.trim s = "" then Lwt.return (`Assoc [])
  else
    match Json.parse s with
    | Ok (`Assoc _ as j) -> Lwt.return j
    | Ok _ -> Errores.invalido "El cuerpo de la petición debe ser un objeto JSON."
    | Error _ -> Errores.invalido "El cuerpo de la petición no es JSON válido."

(* --- respuestas ------------------------------------------------------------------------------------------------------------------ *)

let responder_json ?(estado = 200) (j : Json.t) : Dream.response Lwt.t =
  Dream.json ~status:(Dream.int_to_status estado) (Json.to_string j)

let respuesta_error estado codigo mensaje : Dream.response Lwt.t = responder_json ~estado (Errores.cuerpo codigo mensaje)

(* --- middlewares ------------------------------------------------------------------------------------------------------------------ *)

let poner_cabeceras (cfg : Config.t) (resp : Dream.response) : unit =
  Dream.set_header resp "X-Content-Type-Options" "nosniff";
  Dream.set_header resp "X-Frame-Options" "DENY";
  Dream.set_header resp "Referrer-Policy" "no-referrer";
  Dream.set_header resp "Content-Security-Policy" "default-src 'none'; frame-ancestors 'none'; base-uri 'none'";
  Dream.set_header resp "Cross-Origin-Resource-Policy" "same-site";
  Dream.set_header resp "Permissions-Policy" "camera=(), microphone=(), geolocation=()";
  if Dream.header resp "Cache-Control" = None then Dream.set_header resp "Cache-Control" "no-store";
  if String.length cfg.base_url_publica >= 8 && String.sub cfg.base_url_publica 0 8 = "https://" then
    Dream.set_header resp "Strict-Transport-Security" "max-age=31536000"

let cabeceras (cfg : Config.t) : Dream.middleware =
 fun handler req ->
  let* resp = handler req in
  poner_cabeceras cfg resp;
  Lwt.return resp

(* CORS: solo los origenes de CORS (coma-separados). `*` solo si se pide explicitamente (desarrollo). Siempre `Vary: Origin`. *)
let origen_permitido (cfg : Config.t) (origen : string option) : string option =
  match origen with
  | Some o when List.mem o cfg.cors_origenes || List.mem "*" cfg.cors_origenes -> Some o
  | _ -> None

let cors (cfg : Config.t) : Dream.middleware =
 fun handler req ->
  let permitido = origen_permitido cfg (Dream.header req "Origin") in
  let con_cors resp =
    Dream.add_header resp "Vary" "Origin";
    (match permitido with
    | Some o ->
        Dream.set_header resp "Access-Control-Allow-Origin" o;
        Dream.set_header resp "Access-Control-Allow-Headers" "Authorization, Content-Type";
        Dream.set_header resp "Access-Control-Allow-Methods" "GET, POST, PUT, DELETE, OPTIONS";
        Dream.set_header resp "Access-Control-Max-Age" "600"
    | None -> ());
    resp
  in
  if Dream.method_ req = `OPTIONS then Lwt.map con_cors (Dream.empty `No_Content) else Lwt.map con_cors (handler req)

(* Errores -> {error, codigo}. Nada de trazas ni de SQL hacia afuera. *)
let errores : Dream.middleware =
 fun handler req ->
  Lwt.catch
    (fun () -> handler req)
    (function
      | Errores.Api (estado, codigo, mensaje) -> respuesta_error estado codigo mensaje
      | Db.Db_error m ->
          Dream.error (fun l -> l "base de datos: %s" m);
          respuesta_error 500 "interno" "Algo falló en el servidor. Lo que hiciste antes está a salvo; inténtalo de nuevo."
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | e ->
          Dream.error (fun l -> l "error no esperado: %s" (Printexc.to_string e));
          respuesta_error 500 "interno" "Algo falló en el servidor. Lo que hiciste antes está a salvo; inténtalo de nuevo.")

(* Registro de accesos: metodo, ruta (con el token del estado publico y los ids de WhatsApp tapados), estado y duracion.
   Sin cuerpo, sin cabeceras y sin parametros de consulta. *)
let re_secreto = Re.(compile (seq [ str "/estado/"; rep1 (compl [ char '/' ]) ]))
let re_webhook = Re.(compile (seq [ str "/webhook/evolution/"; rep1 (compl [ char '/' ]) ]))

let ruta_para_log (target : string) : string =
  let ruta = match String.index_opt target '?' with Some i -> String.sub target 0 i | None -> target in
  let ruta = Re.replace_string re_secreto ~by:"/estado/***" ruta in
  Re.replace_string re_webhook ~by:"/webhook/evolution/***" ruta

let registro : Dream.middleware =
 fun handler req ->
  let t0 = Unix.gettimeofday () in
  let* resp = handler req in
  let ms = int_of_float ((Unix.gettimeofday () -. t0) *. 1000.) in
  Dream.log "%s %s -> %d (%d ms)" (Dream.method_to_string (Dream.method_ req)) (ruta_para_log (Dream.target req)) (Dream.status_to_int (Dream.status resp)) ms;
  Lwt.return resp
