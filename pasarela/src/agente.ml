(* Cliente del agente (Python), CONTRATOS §1: `POST /chat`. El agente no guarda estado; la pasarela le manda el turno
   completo y guarda lo que devuelve. Plazo duro, UN reintento y, si el agente cae, el flujo responde con el respaldo de
   cortesia (ver Flujo). *)

let ( let* ) = Lwt.bind

type t = { url : string; plazo : float }

let crear ~url ~plazo = { url; plazo }

type resultado = Respuesta of Json.t | Caido of string

let una_vez (a : t) (peticion : Json.t) : (Json.t, bool * string) result Lwt.t =
  (* En el error, el booleano dice si vale la pena reintentar (red, plazo, 5xx) o no (4xx: la peticion esta mal). *)
  let* r = Http.pedir ~cabeceras:(Http.json_cabeceras []) ~cuerpo:(Json.to_string peticion) ~plazo:a.plazo `POST (a.url ^ "/chat") in
  match r with
  | Error f -> Lwt.return (Error (true, Http.describir f))
  | Ok (200, texto) -> (
      match Json.parse texto with
      | Ok (`Assoc _ as j) -> Lwt.return (Ok j)
      | _ -> Lwt.return (Error (true, "el agente respondio algo que no es un objeto JSON")))
  | Ok (e, _) -> Lwt.return (Error (e >= 500, Printf.sprintf "el agente respondio HTTP %d" e))

let chat ?(espera_reintento = 0.4) (a : t) (peticion : Json.t) : resultado Lwt.t =
  let* r = una_vez a peticion in
  match r with
  | Ok j -> Lwt.return (Respuesta j)
  | Error (false, m) -> Lwt.return (Caido m)
  | Error (true, _) -> (
      let* () = Lwt_unix.sleep espera_reintento in
      let* r2 = una_vez a peticion in
      match r2 with Ok j -> Lwt.return (Respuesta j) | Error (_, m) -> Lwt.return (Caido m))

let salud (a : t) : bool Lwt.t =
  let* r = Http.pedir ~plazo:3.0 `GET (a.url ^ "/salud") in
  Lwt.return (match r with Ok (200, _) -> true | _ -> false)

let recargar_conocimiento (a : t) (articulos : Json.t list) : (unit, string) result Lwt.t =
  let cuerpo = Json.to_string (`Assoc [ ("articulos", `List articulos) ]) in
  let* r = Http.pedir ~cabeceras:(Http.json_cabeceras []) ~cuerpo ~plazo:20.0 `POST (a.url ^ "/conocimiento/recargar") in
  match r with Ok (e, _) when e >= 200 && e < 300 -> Lwt.return (Ok ()) | Ok (e, _) -> Lwt.return (Error (Printf.sprintf "HTTP %d" e)) | Error f -> Lwt.return (Error (Http.describir f))

(* `ejemplos`: [{mensaje, intencion, categoria}] revisados por una persona. `publicar` (por defecto false): el agente entrena una version
   nueva y la MIDE sobre el reservado sin publicarla; publicar es un paso aparte (`publicar_modelo`). Entrenar tarda: plazo largo. *)
let reentrenar ?(ejemplos = []) ?(publicar = false) (a : t) : (Json.t, string) result Lwt.t =
  let cuerpo = Json.to_string (`Assoc [ ("ejemplos", `List ejemplos); ("publicar", `Bool publicar); ("forzar", `Bool false) ]) in
  let* r = Http.pedir ~cabeceras:(Http.json_cabeceras []) ~cuerpo ~plazo:300.0 `POST (a.url ^ "/reentrenar") in
  match r with
  | Ok (e, texto) when e >= 200 && e < 300 -> Lwt.return (Ok (match Json.parse texto with Ok j -> j | Error _ -> `Assoc []))
  | Ok (e, _) -> Lwt.return (Error (Printf.sprintf "HTTP %d" e))
  | Error f -> Lwt.return (Error (Http.describir f))

(* Los articulos de ejemplo que trae el agente (semilla de la base de conocimiento). Acepta `{"articulos": [...]}` o la lista sola. *)
let articulos_iniciales (a : t) : (Json.t list, string) result Lwt.t =
  let* r = Http.pedir ~cabeceras:(Http.json_cabeceras []) ~plazo:10.0 `GET (a.url ^ "/conocimiento/articulos") in
  match r with
  | Ok (200, texto) -> (
      match Json.parse texto with
      | Ok (`List l) -> Lwt.return (Ok l)
      | Ok (`Assoc _ as j) -> Lwt.return (Ok (Json.list "articulos" j))
      | _ -> Lwt.return (Error "respuesta ilegible"))
  | Ok (e, _) -> Lwt.return (Error (Printf.sprintf "HTTP %d" e))
  | Error f -> Lwt.return (Error (Http.describir f))

(* Versiones del modelo que conoce el agente: `{actual?, modelos: [...]}` o la lista sola. *)
let modelos (a : t) : (Json.t, string) result Lwt.t =
  let* r = Http.pedir ~cabeceras:(Http.json_cabeceras []) ~plazo:8.0 `GET (a.url ^ "/modelos") in
  match r with
  | Ok (200, texto) -> Lwt.return (match Json.parse texto with Ok j -> Ok j | Error _ -> Error "respuesta ilegible")
  | Ok (e, _) -> Lwt.return (Error (Printf.sprintf "HTTP %d" e))
  | Error f -> Lwt.return (Error (Http.describir f))

type publicacion = Publicado of Json.t | Rechazado of int * string | Sin_respuesta of string

(* El agente decide si acepta publicar una version (no si empeora el conjunto reservado). *)
let publicar_modelo (a : t) ~(version : string) : publicacion Lwt.t =
  let* r = Http.pedir ~cabeceras:(Http.json_cabeceras []) ~cuerpo:"{}" ~plazo:60.0 `POST (a.url ^ "/modelos/" ^ Uri.pct_encode version ^ "/publicar") in
  match r with
  | Error f -> Lwt.return (Sin_respuesta (Http.describir f))
  | Ok (e, texto) when e >= 200 && e < 300 ->
      let j = match Json.parse texto with Ok j -> j | Error _ -> `Assoc [] in
      (* Un 200 con `publicado: false` tambien es un rechazo. *)
      if Json.bool "publicado" j = Some false then Lwt.return (Rechazado (409, Option.value (Json.str_ne "motivo" j) ~default:"El agente no aceptó publicar esa versión."))
      else Lwt.return (Publicado j)
  | Ok (e, texto) ->
      let j = match Json.parse texto with Ok j -> j | Error _ -> `Assoc [] in
      let msg = match Json.str_ne "error" j with Some m -> m | None -> (match Json.str_ne "motivo" j with Some m -> m | None -> "El agente no aceptó publicar esa versión.") in
      Lwt.return (if e >= 500 then Sin_respuesta (Printf.sprintf "HTTP %d" e) else Rechazado (e, msg))
