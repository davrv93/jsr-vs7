(* Arranque de un servidor Dream de prueba en 127.0.0.1 y forma de pararlo. *)

type t = { puerto : int; parar : unit -> unit; terminado : unit Lwt.t }

let siguiente_puerto = ref (30000 + (Unix.getpid () mod 2000))

let servir ?puerto (handler : Dream.handler) : t =
  let puerto = match puerto with Some p -> p | None -> incr siguiente_puerto; !siguiente_puerto in
  let stop, despertar = Lwt.wait () in
  let terminado =
    Dream.serve ~interface:"127.0.0.1" ~port:puerto ~stop handler
  in
  { puerto; parar = (fun () -> if Lwt.is_sleeping stop then Lwt.wakeup despertar ()); terminado }

let url (s : t) = Printf.sprintf "http://127.0.0.1:%d" s.puerto

(* Respuesta JSON inmediata (sin Lwt) y su version para devolver desde un manejador. *)
let json_ok ?(status = `OK) (j : Yojson.Safe.t) : Dream.response =
  Dream.response ~status ~headers:[ ("Content-Type", "application/json") ] (Yojson.Safe.to_string j)

let json_lwt ?status j = Lwt.return (json_ok ?status j)
