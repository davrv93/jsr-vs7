(* Cliente de la API interna del motor (Go), CONTRATOS §5. Cabecera `X-Interno-Clave`. El motor es el unico que muta
   `incidencias`: la pasarela lo llama y no toca esas tablas. *)

let ( let* ) = Lwt.bind

type t = { url : string; clave : string; plazo : float }

type fallo =
  | Inalcanzable of string (* sin red, plazo agotado, respuesta ilegible *)
  | Rechazo of int * string * string (* estado HTTP, codigo, mensaje que dio el motor *)

let crear ~(url : string) ~(clave : string) ~(plazo : float) : t = { url; clave; plazo }

let llamar (m : t) ?cuerpo (metodo : Cohttp.Code.meth) (ruta : string) : (Json.t, fallo) result Lwt.t =
  let cabeceras = Http.json_cabeceras [ ("X-Interno-Clave", m.clave) ] in
  let cuerpo = Option.map Json.to_string cuerpo in
  let* r = Http.pedir ~cabeceras ?cuerpo ~plazo:m.plazo metodo (m.url ^ ruta) in
  match r with
  | Error f -> Lwt.return (Error (Inalcanzable (Http.describir f)))
  | Ok (estado, texto) -> (
      let j = match Json.parse texto with Ok j -> Some j | Error _ -> None in
      if estado >= 200 && estado < 300 then
        match j with Some j -> Lwt.return (Ok j) | None -> Lwt.return (Error (Inalcanzable "el motor respondio algo que no es JSON"))
      else
        let codigo = Option.value (Option.bind j (Json.str "codigo")) ~default:"" in
        let msg = Option.value (Option.bind j (Json.str "error")) ~default:"" in
        if estado >= 500 then Lwt.return (Error (Inalcanzable (Printf.sprintf "el motor respondio HTTP %d" estado)))
        else Lwt.return (Error (Rechazo (estado, codigo, msg))))

(* Traduce un fallo del motor a un error de la API de la consola. Los rechazos 400/404/409/422 llevan el mensaje en
   español del motor; una caida del motor es 503 y no inventa nada. *)
let a_error_api = function
  | Inalcanzable _ -> Errores.no_disponible "El motor de incidencias no responde en este momento. No se guardó ningún cambio; inténtalo de nuevo en unos segundos."
  | Rechazo (404, _, msg) -> Errores.no_encontrado (if msg = "" then "No encontramos lo que buscabas." else msg)
  | Rechazo (409, _, msg) -> Errores.conflicto (if msg = "" then "Ese cambio no se puede hacer ahora: el estado de la incidencia no lo permite." else msg)
  | Rechazo (_, _, msg) -> Errores.invalido (if msg = "" then "El motor no aceptó los datos." else msg)

(* Lanza el error de API si el motor fallo. *)
let exigir (r : (Json.t, fallo) result) : Json.t = match r with Ok j -> j | Error f -> a_error_api f

let describir_fallo = function
  | Inalcanzable m -> "inalcanzable: " ^ m
  | Rechazo (e, c, m) -> Printf.sprintf "rechazo %d %s %s" e c m

(* --- rutas del contrato ------------------------------------------------------------------------------------------ *)

let salud m = llamar m `GET "/interno/salud"

let crear_incidencia m (cuerpo : Json.t) = llamar m ~cuerpo `POST "/interno/incidencias"

let duplicada m ~(persona_id : int) ~(categoria : string) =
  llamar m `GET (Printf.sprintf "/interno/incidencias/duplicada?persona_id=%d&categoria=%s" persona_id (Uri.pct_encode categoria))

let accion m ~(id : int) (cuerpo : Json.t) = llamar m ~cuerpo `POST (Printf.sprintf "/interno/incidencias/%d/acciones" id)

let sla_calcular m (ids : int list) = llamar m ~cuerpo:(`Assoc [ ("ids", `List (List.map (fun i -> `Int i) ids)) ]) `POST "/interno/sla/calcular"

let avisos_pendientes m ~(limite : int) = llamar m `GET (Printf.sprintf "/interno/avisos/pendientes?limite=%d" limite)

let marcar_aviso m ~(id : int) ~(enviado : bool) ?error () =
  let cuerpo = `Assoc (("enviado", `Bool enviado) :: (match error with Some e -> [ ("error", `String e) ] | None -> [])) in
  llamar m ~cuerpo `POST (Printf.sprintf "/interno/avisos/%d/marcar" id)

let golden_catalogo m = llamar m `GET "/interno/golden"

let golden m ~(kpi : string) ~(desde : string) ~(hasta : string) ~(grupo : string) =
  llamar m `GET
    (Printf.sprintf "/interno/golden/%s?desde=%s&hasta=%s&grupo=%s" (Uri.pct_encode kpi) (Uri.pct_encode desde) (Uri.pct_encode hasta) (Uri.pct_encode grupo))

(* Actor del contrato. *)
let actor ?id tipo = `Assoc (("tipo", `String tipo) :: (match id with Some i -> [ ("id", `String i) ] | None -> []))

(* Accion sobre una incidencia: devuelve la respuesta del motor o lanza el error de API correspondiente. `campos` ya lleva
   `accion` y `actor`. *)
let exigir_accion (m : t) ~(id : int) (campos : (string * Json.t) list) : Json.t Lwt.t =
  let open Lwt.Infix in
  accion m ~id (`Assoc campos) >|= exigir
