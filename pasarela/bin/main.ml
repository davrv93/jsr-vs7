(* Punto de entrada de `pasarela`. Subcomandos: servir (por defecto), crear-admin, salud, version. *)

open Pasarela

let uso =
  "uso:\n  pasarela [servir]\n  pasarela crear-admin --email CORREO --nombre NOMBRE [--rol admin]   (clave en PASARELA_ADMIN_CLAVE o por stdin)\n  pasarela salud\n  pasarela version"

let rec opcion nombre = function
  | k :: v :: _ when k = nombre -> Some v
  | _ :: resto -> opcion nombre resto
  | [] -> None

let servir () =
  match Config.desde_entorno () with
  | Ok cfg -> Arranque.servir cfg
  | Error problemas ->
      prerr_endline "No se puede arrancar: la configuración está incompleta.";
      List.iter (fun p -> prerr_endline ("  - " ^ p)) problemas;
      exit 2

let () =
  Printexc.record_backtrace false;
  match List.tl (Array.to_list Sys.argv) with
  | [] | [ "servir" ] -> servir ()
  | "crear-admin" :: resto -> (
      match (opcion "--email" resto, opcion "--nombre" resto) with
      | Some email, Some nombre -> exit (Arranque.crear_usuario_cli ~email ~nombre ~rol:(Option.value (opcion "--rol" resto) ~default:"admin"))
      | _ ->
          prerr_endline uso;
          exit 2)
  | [ "salud" ] -> exit (Arranque.salud_local (match Option.bind (Sys.getenv_opt "PORT") int_of_string_opt with Some p -> p | None -> 8080))
  | [ "version" ] -> print_endline Api_publico.version
  | _ ->
      prerr_endline uso;
      exit 2
