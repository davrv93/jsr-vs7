(* Limitador en memoria de ventana deslizante: a lo mas `max` eventos por `ventana` segundos y por clave. Una sola
   instancia de la pasarela (documentado): si algun dia hay varias, esto pasa a Postgres o a Redis. *)

type t = { max : int; ventana : float; tabla : (string, float list) Hashtbl.t }

let crear ~max ~ventana = { max; ventana; tabla = Hashtbl.create 256 }

let podar t ahora lista = List.filter (fun x -> ahora -. x < t.ventana) lista

(* Cuenta el intento y devuelve Ok () o Error segundos_hasta_poder_reintentar. *)
let intentar ?(ahora = Unix.gettimeofday ()) t clave : (unit, int) result =
  let previos = podar t ahora (try Hashtbl.find t.tabla clave with Not_found -> []) in
  if List.length previos >= t.max then begin
    Hashtbl.replace t.tabla clave previos;
    let mas_viejo = List.fold_left min infinity previos in
    Error (max 1 (int_of_float (ceil (mas_viejo +. t.ventana -. ahora))))
  end
  else begin
    Hashtbl.replace t.tabla clave (ahora :: previos);
    Ok ()
  end

(* Solo mira, sin contar. *)
let bloqueado ?(ahora = Unix.gettimeofday ()) t clave : (unit, int) result =
  let previos = podar t ahora (try Hashtbl.find t.tabla clave with Not_found -> []) in
  if List.length previos >= t.max then
    let mas_viejo = List.fold_left min infinity previos in
    Error (max 1 (int_of_float (ceil (mas_viejo +. t.ventana -. ahora))))
  else Ok ()

(* Cuenta un evento sin comprobar (los intentos de login fallidos). *)
let registrar ?(ahora = Unix.gettimeofday ()) t clave =
  let previos = podar t ahora (try Hashtbl.find t.tabla clave with Not_found -> []) in
  Hashtbl.replace t.tabla clave (ahora :: previos)

let olvidar t clave = Hashtbl.remove t.tabla clave

(* Quita las claves cuya ventana ya vencio, para que la tabla no crezca sin limite. *)
let limpiar ?(ahora = Unix.gettimeofday ()) t =
  let vivas = Hashtbl.fold (fun k v acc -> match podar t ahora v with [] -> acc | l -> (k, l) :: acc) t.tabla [] in
  Hashtbl.reset t.tabla;
  List.iter (fun (k, l) -> Hashtbl.replace t.tabla k l) vivas

let tamano t = Hashtbl.length t.tabla
