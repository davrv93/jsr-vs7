(* Contexto compartido: configuracion, base de datos, clientes de los otros servicios y el estado en memoria (hub de
   eventos, cola de salida, limitadores). Se construye una vez al arrancar y se pasa a cada modulo. *)

let ( let* ) = Lwt.bind

type limites = {
  login_ip : Limite.t; (* intentos de login por IP *)
  login_email : Limite.t; (* FALLOS de login por correo *)
  chat_ip : Limite.t;
  chat_sesion : Limite.t;
  estado_ip : Limite.t;
  estado_token : Limite.t;
  webhook_ip : Limite.t;
  salud_ip : Limite.t;
}

type t = {
  cfg : Config.t;
  db : Db.t;
  motor : Motor.t;
  agente : Agente.t;
  evolution : Evolution.t;
  hub : Hub.t;
  mutable salida : Cola_salida.t;
  limites : limites;
  candados : (string, Lwt_mutex.t) Hashtbl.t;
  mutable tareas : int;
  tareas_reposo : unit Lwt_condition.t;
  despertar_avisos : unit Lwt_condition.t;
  mutable reloj : unit -> float; (* inyectable en pruebas *)
  mutable modelos_sync : float; (* ultima sincronizacion de `modelos` con el agente *)
}

let crear_limites () =
  { login_ip = Limite.crear ~max:30 ~ventana:900.;
    login_email = Limite.crear ~max:5 ~ventana:900.;
    chat_ip = Limite.crear ~max:30 ~ventana:60.;
    chat_sesion = Limite.crear ~max:12 ~ventana:60.;
    estado_ip = Limite.crear ~max:60 ~ventana:60.;
    estado_token = Limite.crear ~max:20 ~ventana:60.;
    webhook_ip = Limite.crear ~max:600 ~ventana:60.;
    salud_ip = Limite.crear ~max:120 ~ventana:60. }

(* Registra en `decisiones` (solo inserciones) un mensaje que no se pudo entregar. Es lo unico que queda de ello: no se
   guarda el texto ni el numero completo. *)
let registrar_entrega_perdida (db : Db.t) ~destino ~largo ~motivo : unit Lwt.t =
  Db.usar db (fun c ->
      Db.exec c
        "INSERT INTO decisiones (componente, modo, entrada, salida) VALUES ('entrega', 'activo', $j:entrada, $j:salida)"
        (`Assoc
          [ ("entrada", `Assoc [ ("destino", `String (Mascara.chat destino)); ("largo", `Int largo) ]);
            ("salida", `Assoc [ ("ok", `Bool false); ("motivo", `String (String.sub motivo 0 (min 200 (String.length motivo)))) ]) ]))

let crear ~(cfg : Config.t) ~(db : Db.t) : t =
  let motor = Motor.crear ~url:cfg.motor_url ~clave:cfg.motor_clave ~plazo:cfg.motor_timeout_s in
  let agente = Agente.crear ~url:cfg.agente_url ~plazo:cfg.agente_timeout_s in
  let evolution = Evolution.crear cfg in
  let salida =
    Cola_salida.crear ~espaciado_ms:cfg.salida_espaciado_ms
      ~enviar:(fun ~destino ~texto -> Evolution.enviar_texto evolution ~destino ~texto)
      ~sobre_perdido:(registrar_entrega_perdida db)
  in
  { cfg; db; motor; agente; evolution; hub = Hub.crear (); salida; limites = crear_limites (); candados = Hashtbl.create 64;
    tareas = 0; tareas_reposo = Lwt_condition.create (); despertar_avisos = Lwt_condition.create (); reloj = Unix.gettimeofday; modelos_sync = 0. }

let ahora ctx = ctx.reloj ()

(* Serializa el trabajo de una misma clave (un chat): dos mensajes de la misma persona no se mezclan. *)
let con_candado (ctx : t) (clave : string) (f : unit -> 'a Lwt.t) : 'a Lwt.t =
  let m =
    match Hashtbl.find_opt ctx.candados clave with
    | Some m -> m
    | None ->
        let m = Lwt_mutex.create () in
        Hashtbl.add ctx.candados clave m;
        m
  in
  Lwt.finalize
    (fun () -> Lwt_mutex.with_lock m f)
    (fun () ->
      if (not (Lwt_mutex.is_locked m)) && Lwt_mutex.is_empty m then Hashtbl.remove ctx.candados clave;
      Lwt.return ())

(* Lanza trabajo en segundo plano contando las tareas vivas (para esperarlas en pruebas y al apagar). *)
let lanzar (ctx : t) ?(nombre = "tarea") (f : unit -> unit Lwt.t) : unit =
  ctx.tareas <- ctx.tareas + 1;
  Lwt.async (fun () ->
      Lwt.finalize
        (fun () ->
          Lwt.catch f (fun e ->
              Dream.error (fun l -> l "%s fallo: %s" nombre (Printexc.to_string e));
              Lwt.return ()))
        (fun () ->
          ctx.tareas <- ctx.tareas - 1;
          if ctx.tareas <= 0 then Lwt_condition.broadcast ctx.tareas_reposo ();
          Lwt.return ()))

let esperar_tareas ?(plazo = 10.) (ctx : t) : bool Lwt.t =
  if ctx.tareas <= 0 then Lwt.return true
  else
    Lwt.pick
      [ (let rec esperar () = if ctx.tareas <= 0 then Lwt.return true else let* () = Lwt_condition.wait ctx.tareas_reposo in esperar () in esperar ());
        (let* () = Lwt_unix.sleep plazo in Lwt.return (ctx.tareas <= 0)) ]

let publicar ctx nombre datos = Hub.publicar ctx.hub nombre datos

(* Avisa al trabajador de avisos que mire ya la cola del motor (tras una accion que encolo avisos). *)
let despertar ctx = Lwt_condition.broadcast ctx.despertar_avisos ()
