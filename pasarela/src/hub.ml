(* Hub de eventos en vivo para la consola (SSE, GET /api/eventos). En memoria: cada panel abierto es un suscriptor.
   Eventos: incidencia_creada, incidencia_actualizada, mensaje (CONTRATOS §2). Un suscriptor lento (mas de `tope`
   eventos sin leer) se desconecta: el panel vuelve a conectar y recarga. *)

type evento = Evento of string * Json.t | Ping

type suscriptor = { id : int; stream : evento Lwt_stream.t; push : evento option -> unit; mutable pendientes : int }

type t = { mutable subs : suscriptor list; mutable siguiente : int; tope : int }

let crear ?(tope = 256) () = { subs = []; siguiente = 0; tope }

let suscribir (h : t) : suscriptor =
  let stream, push = Lwt_stream.create () in
  h.siguiente <- h.siguiente + 1;
  let s = { id = h.siguiente; stream; push; pendientes = 0 } in
  h.subs <- s :: h.subs;
  s

let desuscribir (h : t) (s : suscriptor) =
  h.subs <- List.filter (fun x -> x.id <> s.id) h.subs;
  s.push None

let enviar h ev =
  List.iter
    (fun s ->
      if s.pendientes >= h.tope then desuscribir h s
      else begin
        s.pendientes <- s.pendientes + 1;
        s.push (Some ev)
      end)
    h.subs

let publicar (h : t) (nombre : string) (datos : Json.t) = enviar h (Evento (nombre, datos))

let latido (h : t) = enviar h Ping

let suscriptores h = List.length h.subs

(* Siguiente evento, o None si el suscriptor se cerro. *)
let siguiente (s : suscriptor) : evento option Lwt.t =
  let open Lwt.Infix in
  Lwt_stream.get s.stream >|= fun r ->
  (match r with Some _ -> s.pendientes <- max 0 (s.pendientes - 1) | None -> ());
  r

let formatear = function
  | Ping -> ": ping\n\n"
  | Evento (nombre, datos) -> Printf.sprintf "event: %s\ndata: %s\n\n" nombre (Json.to_string datos)
