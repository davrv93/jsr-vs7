(* El SLA de cada fila de una lista viene del motor en UN solo lote (POST /interno/sla/calcular). Si el motor no responde, la
   lista sale igual, con `sla: null`: leer incidencias no depende de que el motor este vivo. *)

let ( let* ) = Lwt.bind

let a_ui (v : Json.t) : Json.t =
  let pct = match Json.float "porcentaje_resolucion" v with Some p -> p | None -> Option.value (Json.float "porcentaje_respuesta" v) ~default:0. in
  `Assoc
    [ ("porcentaje", `Float pct); ("restante_min", `Int (int_of_float (Option.value (Json.float "restante_min" v) ~default:0.)));
      ("vencida", `Bool (Json.bool_d "vencida" false v)); ("pausado", `Bool (Json.bool_d "pausada" false v)) ]

(* id -> sla (formato de la consola). *)
let de_motor (ctx : Ctx.t) (ids : int list) : (int, Json.t) Hashtbl.t Lwt.t =
  let tabla = Hashtbl.create 64 in
  if ids = [] then Lwt.return tabla
  else
    let* r = Motor.sla_calcular ctx.motor ids in
    (match r with
    | Ok (`Assoc l) -> List.iter (fun (k, v) -> match int_of_string_opt k with Some id -> Hashtbl.replace tabla id (a_ui v) | None -> ()) l
    | Ok _ -> ()
    | Error f -> Dream.warning (fun l -> l "sla: el motor no respondio (%s); las listas salen sin SLA" (Motor.describir_fallo f)));
    Lwt.return tabla

let cerrada estado = estado = "resuelta" || estado = "cerrada"

(* Pone `sla` en cada fila (que trae `id` y `estado`). Las resueltas y cerradas no llevan plazo corriendo. *)
let poner (tabla : (int, Json.t) Hashtbl.t) (fila : Json.t) : Json.t =
  let sla =
    if cerrada (Json.str_d "estado" "" fila) then `Null else match Hashtbl.find_opt tabla (Json.int_d "id" 0 fila) with Some s -> s | None -> `Null
  in
  Json.set "sla" sla fila

let con_sla (ctx : Ctx.t) (filas : Json.t list) : Json.t list Lwt.t =
  let ids = List.filter_map (fun f -> if cerrada (Json.str_d "estado" "" f) then None else Json.int "id" f) filas in
  let* tabla = de_motor ctx ids in
  Lwt.return (List.map (poner tabla) filas)
