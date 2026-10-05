(* Ayudantes comunes de los endpoints: respuestas, paginacion y validacion de entradas. Los mensajes de error van en español
   y dicen que corregir. *)

let ( let* ) = Lwt.bind

let ok ?estado (j : Json.t) = Seguridad.responder_json ?estado j

let lista (items : Json.t list) (total : int) = ok (`Assoc [ ("items", `List items); ("total", `Int total) ])

(* --- parametros -------------------------------------------------------------------------------------------------------- *)

let consulta (req : Dream.request) (nombre : string) : string option =
  match Dream.query req nombre with Some s when String.trim s <> "" -> Some (String.trim s) | _ -> None

let consulta_int (req : Dream.request) (nombre : string) : int option =
  match consulta req nombre with
  | None -> None
  | Some s -> (
      match int_of_string_opt s with
      | Some n -> Some n
      | None -> Errores.invalido (Printf.sprintf "El filtro «%s» debe ser un número." nombre))

(* ?pagina=1&por_pagina=50 -> (pagina, por_pagina, offset). Tope de 200 por pagina. *)
let paginacion (req : Dream.request) : int * int * int =
  let pagina = Option.value (consulta_int req "pagina") ~default:1 in
  let por = Option.value (consulta_int req "por_pagina") ~default:50 in
  if pagina < 1 || pagina > 100_000 then Errores.invalido "La página debe ser un número entre 1 y 100000.";
  if por < 1 || por > 200 then Errores.invalido "«por_pagina» debe estar entre 1 y 200.";
  (pagina, por, (pagina - 1) * por)

let id_de_ruta ?(que = "elemento") (req : Dream.request) (nombre : string) : int =
  match int_of_string_opt (Dream.param req nombre) with
  | Some n when n > 0 -> n
  | _ -> Errores.no_encontrado (Printf.sprintf "No encontramos ese %s." que)

(* --- campos de un cuerpo JSON -------------------------------------------------------------------------------------------- *)

let cadena_larga s = String.length s > 0 && String.length s <= 100_000

(* Texto obligatorio, recortado, entre min y max caracteres (en bytes: suficiente para acotar). *)
let texto_req ?(min = 1) ~(max : int) ~(nombre : string) (j : Json.t) (k : string) : string =
  match Json.get k j with
  | `String s ->
      let t = String.trim s in
      if String.length t < min then Errores.invalido (Printf.sprintf "Falta %s." nombre)
      else if String.length t > max then Errores.invalido (Printf.sprintf "%s es demasiado largo (máximo %d caracteres)." (String.capitalize_ascii nombre) max)
      else t
  | `Null -> Errores.invalido (Printf.sprintf "Falta %s." nombre)
  | _ -> Errores.invalido (Printf.sprintf "%s debe ser un texto." (String.capitalize_ascii nombre))

(* Texto opcional: None si no viene o viene vacio. *)
let texto_opt ~(max : int) ~(nombre : string) (j : Json.t) (k : string) : string option =
  match Json.get k j with
  | `Null -> None
  | `String s ->
      let t = String.trim s in
      if t = "" then None
      else if String.length t > max then Errores.invalido (Printf.sprintf "%s es demasiado largo (máximo %d caracteres)." (String.capitalize_ascii nombre) max)
      else Some t
  | _ -> Errores.invalido (Printf.sprintf "%s debe ser un texto." (String.capitalize_ascii nombre))

let entero_req ~(nombre : string) ?(min = min_int) ?(max = max_int) (j : Json.t) (k : string) : int =
  match Json.int k j with
  | Some n when n >= min && n <= max -> n
  | Some _ -> Errores.invalido (Printf.sprintf "%s está fuera de rango." (String.capitalize_ascii nombre))
  | None -> Errores.invalido (Printf.sprintf "Falta %s (un número)." nombre)

let entero_opt ~(nombre : string) ?(min = min_int) ?(max = max_int) (j : Json.t) (k : string) : int option =
  match Json.get k j with
  | `Null -> None
  | v -> (
      match Json.int_opt v with
      | Some n when n >= min && n <= max -> Some n
      | _ -> Errores.invalido (Printf.sprintf "%s debe ser un número entre %d y %d." (String.capitalize_ascii nombre) min max))

let bool_opt ~(nombre : string) (j : Json.t) (k : string) : bool option =
  match Json.get k j with
  | `Null -> None
  | `Bool b -> Some b
  | _ -> Errores.invalido (Printf.sprintf "%s debe ser verdadero o falso." (String.capitalize_ascii nombre))

let en_lista ~(nombre : string) (validos : string list) (v : string) : string =
  if List.mem v validos then v else Errores.invalido (Printf.sprintf "%s no es válido; usa uno de: %s." (String.capitalize_ascii nombre) (String.concat ", " validos))

let correo_valido (s : string) : bool =
  let n = String.length s in
  n >= 5 && n <= 200
  && (match String.index_opt s '@' with
     | Some i -> i > 0 && i < n - 3 && (not (String.contains (String.sub s (i + 1) (n - i - 1)) '@')) && String.contains (String.sub s (i + 1) (n - i - 1)) '.' && not (String.contains s ' ')
     | None -> false)

(* Telefono de WhatsApp: se aceptan espacios, guiones y «+»; se guardan solo digitos con prefijo de pais (9 a 15). *)
let telefono_opt ~(nombre : string) (j : Json.t) (k : string) : string option =
  match texto_opt ~max:30 ~nombre j k with
  | None -> None
  | Some t ->
      let d = Webhook.solo_digitos t in
      if String.length d >= 9 && String.length d <= 15 then Some d
      else Errores.invalido (Printf.sprintf "%s va solo con dígitos y el prefijo del país, por ejemplo 51987654321." (String.capitalize_ascii nombre))

let correo_opt ~(nombre : string) (j : Json.t) (k : string) : string option =
  match texto_opt ~max:200 ~nombre j k with
  | None -> None
  | Some c -> if correo_valido c then Some (String.lowercase_ascii c) else Errores.invalido (Printf.sprintf "%s no parece válido." (String.capitalize_ascii nombre))

let hora_valida (s : string) : bool =
  String.length s = 5 && s.[2] = ':'
  && (match (int_of_string_opt (String.sub s 0 2), int_of_string_opt (String.sub s 3 2)) with Some h, Some m -> h >= 0 && h <= 23 && m >= 0 && m <= 59 | _ -> false)

let fecha_valida (s : string) : bool =
  String.length s = 10 && s.[4] = '-' && s.[7] = '-'
  && (match (int_of_string_opt (String.sub s 0 4), int_of_string_opt (String.sub s 5 2), int_of_string_opt (String.sub s 8 2)) with
     | Some a, Some m, Some d -> a >= 2000 && a <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31
     | _ -> false)

let prioridades = [ "P1"; "P2"; "P3"; "P4" ]
let impactos = [ "persona"; "area"; "sede"; "organizacion" ]
let urgencias = [ "baja"; "media"; "alta"; "critica" ]
let niveles = [ "N1"; "N2"; "N3" ]
let intenciones =
  [ "reportar_falla"; "solicitar_acceso"; "solicitar_equipo"; "restablecer_clave"; "consultar_estado"; "aportar_dato"; "confirmar_solucion"; "sigue_igual";
    "pedir_tecnico"; "queja"; "agradecer"; "saludo"; "fuera_de_alcance" ]
