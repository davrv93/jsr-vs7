(* Cliente HTTP minimo sobre cohttp-lwt-unix, con plazo duro. Lo usan el motor, el agente y evolution-go. *)

let ( let* ) = Lwt.bind

type fallo = Plazo | Red of string

(* Como `pedir`, pero devuelve tambien las cabeceras de la respuesta (las pruebas comprueban las de seguridad). *)
let pedir_completo ?(cabeceras = []) ?cuerpo ~(plazo : float) (metodo : Cohttp.Code.meth) (url : string) : (int * (string * string) list * string, fallo) result Lwt.t =
  let uri = Uri.of_string url in
  let headers = Cohttp.Header.of_list cabeceras in
  let body = Option.map Cohttp_lwt.Body.of_string cuerpo in
  let llamada () =
    let* resp, body = Cohttp_lwt_unix.Client.call ~headers ?body metodo uri in
    let* s = Cohttp_lwt.Body.to_string body in
    Lwt.return (Ok (Cohttp.Code.code_of_status (Cohttp.Response.status resp), Cohttp.Header.to_list (Cohttp.Response.headers resp), s))
  in
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout plazo llamada)
    (function
      | Lwt_unix.Timeout -> Lwt.return (Error Plazo)
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | e -> Lwt.return (Error (Red (Printexc.to_string e))))

let pedir ?cabeceras ?cuerpo ~(plazo : float) (metodo : Cohttp.Code.meth) (url : string) : (int * string, fallo) result Lwt.t =
  let* r = pedir_completo ?cabeceras ?cuerpo ~plazo metodo url in
  Lwt.return (match r with Ok (e, _, s) -> Ok (e, s) | Error f -> Error f)

let describir = function Plazo -> "se agoto el plazo" | Red m -> m

let json_cabeceras extra = ("Content-Type", "application/json") :: ("Accept", "application/json") :: extra
