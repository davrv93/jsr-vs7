(* evolution-go falso: registra los POST /send/text y comprueba la cabecera apikey. *)

open Pasarela

type t = { mutable enviados : (string * Json.t) list; (* (apikey recibida, cuerpo), el mas reciente primero *) mutable fallar : bool }

let crear () = { enviados = []; fallar = false }

let handler (t : t) : Dream.handler =
  Dream.router
    [ Dream.post "/send/text" (fun req ->
          let ( let* ) = Lwt.bind in
          let* cuerpo = Dream.body req in
          let key = Option.value (Dream.header req "apikey") ~default:"" in
          (match Json.parse cuerpo with Ok j -> t.enviados <- (key, j) :: t.enviados | Error _ -> ());
          if t.fallar then Servidor.json_lwt ~status:`Internal_Server_Error (`Assoc [ ("error", `String "falla simulada") ])
          else Servidor.json_lwt (`Assoc [ ("data", `Assoc [ ("Info", `Assoc [ ("ID", `String "3EB0FALSO") ]) ]) ]));
      Dream.get "/instance/status" (fun _ -> Servidor.json_lwt (`Assoc [ ("data", `Assoc [ ("Connected", `Bool true) ]) ])) ]
