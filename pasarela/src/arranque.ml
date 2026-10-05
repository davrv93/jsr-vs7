(* Arranque del servicio: configuracion, base, migraciones, trabajadores y servidor HTTP con parada ordenada. *)

let ( let* ) = Lwt.bind

(* Espera el cierre ordenado: que terminen las tareas en curso y salgan los mensajes ya encolados. *)
let drenar (ctx : Ctx.t) : unit Lwt.t =
  let* _ = Ctx.esperar_tareas ~plazo:10. ctx in
  let* _ = Cola_salida.esperar_reposo ~plazo:10. ctx.salida in
  Lwt.return ()

let servir (cfg : Config.t) : unit =
  Dream.initialize_log ~level:`Info ();
  List.iter (fun (k, v) -> Dream.log "config %s: %s" k v) (Config.resumen cfg);
  Lwt_main.run
    (let db = Db.conectar ~max:cfg.pool_conexiones cfg.database_url in
     let* () = if cfg.migrar then Migrar.aplicar db else Lwt.return () in
     let ctx = Ctx.crear ~cfg ~db in
     if cfg.trabajadores then Trabajadores.iniciar ctx;
     let parar, despertar = Lwt.wait () in
     let detener _ = if Lwt.is_sleeping parar then Lwt.wakeup despertar () in
     ignore (Lwt_unix.on_signal Sys.sigterm detener);
     ignore (Lwt_unix.on_signal Sys.sigint detener);
     Dream.log "pasarela escuchando en el puerto %d" cfg.puerto;
     let* () = Dream.serve ~interface:"0.0.0.0" ~port:cfg.puerto ~stop:parar (Rutas.aplicacion ctx) in
     Dream.log "apagando: se esperan las tareas en curso";
     drenar ctx)

(* `pasarela salud`: para el HEALTHCHECK de Docker (la imagen no lleva curl). Sale 0 si /api/salud responde 200. *)
let salud_local (puerto : int) : int =
  Lwt_main.run
    (let* r = Http.pedir ~plazo:4. `GET (Printf.sprintf "http://127.0.0.1:%d/api/salud" puerto) in
     Lwt.return (match r with Ok (200, _) -> 0 | _ -> 1))

(* `pasarela crear-admin`: la clave NO se pasa por argumento (se veria en `ps`): variable PASARELA_ADMIN_CLAVE o primera linea de stdin. *)
let crear_usuario_cli ~(email : string) ~(nombre : string) ~(rol : string) : int =
  match Sys.getenv_opt "DATABASE_URL" with
  | None | Some "" ->
      prerr_endline "falta la variable de entorno DATABASE_URL";
      2
  | Some url ->
      if Roles.de_string rol = None then begin
        prerr_endline "el rol debe ser: tecnico, supervisor, gerencia, entrenador o admin";
        2
      end
      else begin
        let clave =
          match Sys.getenv_opt "PASARELA_ADMIN_CLAVE" with
          | Some c when c <> "" -> c
          | _ -> ( try input_line stdin with End_of_file -> "")
        in
        if String.length clave < 10 then begin
          prerr_endline "la clave debe tener al menos 10 caracteres (variable PASARELA_ADMIN_CLAVE o primera linea de stdin)";
          2
        end
        else begin
          let iteraciones = match Option.bind (Sys.getenv_opt "PBKDF2_ITER") int_of_string_opt with Some n when n >= 1000 -> n | _ -> Cripto.iteraciones_por_defecto in
          Lwt_main.run
            (Lwt.catch
               (fun () ->
                 let db = Db.conectar ~max:1 url in
                 let* () = Auth.crear_usuario db ~iteraciones ~email ~nombre ~rol ~clave in
                 Printf.printf "usuario %s listo (rol %s)\n%!" (Mascara.correo email) rol;
                 Lwt.return 0)
               (fun e ->
                 prerr_endline ("no se pudo crear el usuario: " ^ (match e with Db.Db_error m -> m | e -> Printexc.to_string e));
                 Lwt.return 1))
        end
      end
