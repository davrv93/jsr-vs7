(* Tiempo. La base y la API hablan UTC (ISO 8601 con Z); lo que lee una persona (WhatsApp, estado publico) se escribe en
   hora de Lima, que es UTC-5 todo el año (Peru no tiene horario de verano). *)

let ahora () = Unix.gettimeofday ()

let a_iso (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let de_iso (s : string) : float option =
  match Ptime.of_rfc3339 s with Ok (t, _, _) -> Some (Ptime.to_float_s t) | Error _ -> None

let lima_offset = -5. *. 3600.

let dias_corto = [| "dom"; "lun"; "mar"; "mié"; "jue"; "vie"; "sáb" |]

(* Fecha y hora de Lima de un instante. *)
let lima (t : float) : Unix.tm = Unix.gmtime (t +. lima_offset)

let hhmm tm = Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min

(* «11:40 de hoy», «09:15 de mañana», «lun 06/10 a las 09:30». Sirve para plazos que se le dicen a una persona. *)
let texto_plazo ~(ahora : float) (t : float) : string =
  let a = lima ahora and f = lima t in
  let dia_ahora = (a.Unix.tm_year, a.Unix.tm_yday) and dia_f = (f.Unix.tm_year, f.Unix.tm_yday) in
  let manana = lima (ahora +. 86400.) in
  if dia_f = dia_ahora then Printf.sprintf "las %s de hoy" (hhmm f)
  else if dia_f = (manana.Unix.tm_year, manana.Unix.tm_yday) then Printf.sprintf "las %s de mañana" (hhmm f)
  else Printf.sprintf "el %s %02d/%02d a las %s" dias_corto.(f.Unix.tm_wday) f.Unix.tm_mday (f.Unix.tm_mon + 1) (hhmm f)

(* Un plazo en ISO -> texto, o None si no hay plazo o no se entiende. *)
let plazo_de_iso ~ahora (iso : string option) : string option =
  match iso with Some s -> Option.map (texto_plazo ~ahora) (de_iso s) | None -> None
