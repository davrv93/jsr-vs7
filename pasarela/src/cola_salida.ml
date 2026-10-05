(* Cola de salida por chat (de outbox.go de kddesign): los mensajes a una misma persona salen EN ORDEN y con un
   espaciado, y un chat lento no frena a los demas. Hay a lo mas un trabajador por destino y solo vive mientras queden
   mensajes. Si el envio falla se reintenta (1 s, 3 s) y despues se da por perdido y se avisa al dueño de la cola. *)

let ( let* ) = Lwt.bind

type trabajo = { texto : string; sobre_resultado : (Evolution.resultado -> unit Lwt.t) option }

type t = {
  espaciado : float;
  enviar : destino:string -> texto:string -> Evolution.resultado Lwt.t;
  sobre_perdido : destino:string -> largo:int -> motivo:string -> unit Lwt.t;
  colas : (string, trabajo Queue.t) Hashtbl.t;
  mutable pendientes : int;
  reposo : unit Lwt_condition.t;
  tope : int;
}

let crear ~(espaciado_ms : int) ~enviar ~sobre_perdido =
  { espaciado = float_of_int espaciado_ms /. 1000.; enviar; sobre_perdido; colas = Hashtbl.create 32; pendientes = 0;
    reposo = Lwt_condition.create (); tope = 64 }

let terminado t =
  t.pendientes <- t.pendientes - 1;
  if t.pendientes <= 0 then Lwt_condition.broadcast t.reposo ()

let enviar_con_reintentos t ~destino (j : trabajo) =
  let rec intento n =
    let* r = Lwt.catch (fun () -> t.enviar ~destino ~texto:j.texto) (fun e -> Lwt.return (Evolution.Fallo (Printexc.to_string e))) in
    match r with
    | Evolution.Enviado _ -> Lwt.return r
    | Evolution.Fallo _ when n < 2 ->
        let* () = Lwt_unix.sleep (if n = 0 then 1.0 else 3.0) in
        intento (n + 1)
    | Evolution.Fallo _ -> Lwt.return r
  in
  let* r = intento 0 in
  let* () =
    match r with
    | Evolution.Fallo m -> Lwt.catch (fun () -> t.sobre_perdido ~destino ~largo:(String.length j.texto) ~motivo:m) (fun _ -> Lwt.return ())
    | _ -> Lwt.return ()
  in
  match j.sobre_resultado with None -> Lwt.return () | Some f -> Lwt.catch (fun () -> f r) (fun _ -> Lwt.return ())

let rec drenar t destino q =
  if Queue.is_empty q then begin
    Hashtbl.remove t.colas destino;
    Lwt.return ()
  end
  else begin
    let j = Queue.pop q in
    let* () = enviar_con_reintentos t ~destino j in
    terminado t;
    let* () = if t.espaciado > 0. && not (Queue.is_empty q) then Lwt_unix.sleep t.espaciado else Lwt.return () in
    drenar t destino q
  end

(* Encola varios textos para un destino; salen en orden. Devuelve cuantos se aceptaron. Los textos se anotan ANTES de
   arrancar el trabajador: `Lwt.async` ejecuta de inmediato hasta el primer bloqueo y, con la cola vacia, el trabajador
   terminaria al instante. *)
let encolar ?sobre_resultado t ~(destino : string) (textos : string list) : int =
  let q, nuevo =
    match Hashtbl.find_opt t.colas destino with
    | Some q -> (q, false)
    | None ->
        let q = Queue.create () in
        Hashtbl.add t.colas destino q;
        (q, true)
  in
  let aceptados =
    List.fold_left
      (fun aceptados texto ->
        if Queue.length q >= t.tope then begin
          Dream.warning (fun l -> l "cola de salida llena para %s; mensaje descartado" (Mascara.chat destino));
          aceptados
        end
        else begin
          t.pendientes <- t.pendientes + 1;
          Queue.add { texto; sobre_resultado } q;
          aceptados + 1
        end)
      0 textos
  in
  if nuevo then Lwt.async (fun () -> drenar t destino q);
  aceptados

let pendientes t = t.pendientes

(* Espera a que se entreguen los pendientes; false si se agota el plazo. *)
let esperar_reposo ?(plazo = 10.) t : bool Lwt.t =
  if t.pendientes <= 0 then Lwt.return true
  else
    Lwt.pick
      [ (let rec esperar () = if t.pendientes <= 0 then Lwt.return true else let* () = Lwt_condition.wait t.reposo in esperar () in esperar ());
        (let* () = Lwt_unix.sleep plazo in Lwt.return (t.pendientes <= 0)) ]
