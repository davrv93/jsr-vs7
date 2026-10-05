(* Agente, motor y evolution-go falsos como un solo proceso, para `scripts/humo.sh`. Lee DATABASE_URL y MOTOR_CLAVE.
   Puertos: AGENTE_PUERTO (18001), MOTOR_PUERTO (18002), EVOLUTION_PUERTO (18003). *)

open Pasarela

let entero nombre def = match Option.bind (Sys.getenv_opt nombre) int_of_string_opt with Some n -> n | None -> def

let () =
  Dream.initialize_log ~level:`Info ();
  let url = match Sys.getenv_opt "DATABASE_URL" with Some u -> u | None -> prerr_endline "falta DATABASE_URL"; exit 2 in
  let clave = match Sys.getenv_opt "MOTOR_CLAVE" with Some c -> c | None -> prerr_endline "falta MOTOR_CLAVE"; exit 2 in
  let db = Db.conectar url in
  let agente = Falsos.Agente_falso.crear () in
  let motor = Falsos.Motor_falso.crear ~db ~clave in
  let evo = Falsos.Evolution_falso.crear () in
  let a = Falsos.Servidor.servir ~puerto:(entero "AGENTE_PUERTO" 18001) (Falsos.Agente_falso.handler agente) in
  let m = Falsos.Servidor.servir ~puerto:(entero "MOTOR_PUERTO" 18002) (Falsos.Motor_falso.handler motor) in
  let e = Falsos.Servidor.servir ~puerto:(entero "EVOLUTION_PUERTO" 18003) (Falsos.Evolution_falso.handler evo) in
  Printf.printf "falsos listos: agente=%d motor=%d evolution=%d\n%!" a.puerto m.puerto e.puerto;
  Lwt_main.run (Lwt.join [ a.terminado; m.terminado; e.terminado ])
