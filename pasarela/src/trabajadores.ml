(* Trabajadores de fondo: avisos, recordatorios, sondeo de eventos del motor para el panel, latido del SSE y limpieza de los
   limitadores en memoria. Se arrancan una vez (Config.trabajadores = false los apaga, para las pruebas). *)

let ( let* ) = Lwt.bind

let cada (segundos : float) (nombre : string) (f : unit -> unit Lwt.t) : unit =
  Lwt.async (fun () ->
      let rec vuelta () =
        let* () = Lwt_unix.sleep segundos in
        let* () = Lwt.catch f (fun e -> Dream.error (fun l -> l "%s: %s" nombre (Printexc.to_string e)); Lwt.return ()) in
        vuelta ()
      in
      vuelta ())

(* Eventos de incidencia nuevos desde la ultima vuelta (los escribe el motor: vigia, escalamiento, otras instancias) -> panel. *)
let sondear_eventos (ctx : Ctx.t) (ultimo : int ref) : unit Lwt.t =
  if Hub.suscriptores ctx.hub = 0 then Lwt.return ()
  else begin
    let* nuevos =
      Db.lista_p ctx.db
        "SELECT e.id, e.incidencia_id, e.tipo, i.numero FROM incidencia_eventos e JOIN incidencias i ON i.id = e.incidencia_id WHERE e.id > $i:ultimo ORDER BY e.id LIMIT 500"
        (`Assoc [ ("ultimo", `Int !ultimo) ])
    in
    List.iter
      (fun e ->
        ultimo := max !ultimo (Json.int_d "id" 0 e);
        Hub.publicar ctx.hub (if Json.str_d "tipo" "" e = "creada" then "incidencia_creada" else "incidencia_actualizada")
          (`Assoc [ ("id", Json.get "incidencia_id" e); ("numero", Json.get "numero" e) ]))
      nuevos;
    Lwt.return ()
  end

let iniciar (ctx : Ctx.t) : unit =
  Lwt.async (fun () -> Avisos.bucle ctx);
  cada 60. "recordatorios" (fun () -> let* _ = Recordatorios.ejecutar ctx in Lwt.return ());
  (* Conocimiento inicial: una vez al arrancar y, si el agente aun no puede darlo, cada minuto (solo mira si `articulos` esta vacia). *)
  Lwt.async (fun () ->
      let* _ = Lwt.catch (fun () -> Semilla_conocimiento.ejecutar ctx) (fun _ -> Lwt.return 0) in
      Lwt.return ());
  cada 60. "conocimiento inicial" (fun () -> let* _ = Semilla_conocimiento.ejecutar ctx in Lwt.return ());
  cada 20. "latido" (fun () -> Hub.latido ctx.hub; Lwt.return ());
  cada 600. "limpieza" (fun () ->
      let l = ctx.limites in
      List.iter (fun x -> Limite.limpiar x) [ l.login_ip; l.login_email; l.chat_ip; l.chat_sesion; l.estado_ip; l.estado_token; l.webhook_ip; l.salud_ip ];
      Lwt.return ());
  Lwt.async (fun () ->
      let* base = Lwt.catch (fun () -> Db.escalar_int_p ctx.db "SELECT coalesce(max(id), 0) AS n FROM incidencia_eventos" (`Assoc [])) (fun _ -> Lwt.return None) in
      let ultimo = ref (Option.value base ~default:0) in
      cada 3. "sondeo de eventos" (fun () -> sondear_eventos ctx ultimo);
      Lwt.return ())
