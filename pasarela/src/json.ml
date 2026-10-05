(* Ayudantes de JSON sobre Yojson.Safe.t. Todo lo que entra por HTTP se lee con estas funciones: devuelven
   `None`/valor por defecto en vez de lanzar, y la validacion de cada endpoint decide que hacer. *)

type t = Yojson.Safe.t

(* Yojson acepta extensiones que no son JSON (variantes `<"A">`, tuplas `(1,2)`, NaN, Infinity). Aqui solo entra JSON de verdad. *)
let rec es_json_estricto : t -> bool = function
  | `Tuple _ | `Variant _ -> false
  | `Float f -> Float.is_finite f
  | `List l -> List.for_all es_json_estricto l
  | `Assoc l -> List.for_all (fun (_, v) -> es_json_estricto v) l
  | _ -> true

let parse (s : string) : (t, string) result =
  match Yojson.Safe.from_string s with
  | j -> if es_json_estricto j then Ok j else Error "no es JSON estandar"
  | exception Yojson.Json_error m -> Error m
  | exception _ -> Error "JSON no valido"

let to_string (j : t) = Yojson.Safe.to_string j

let get k (j : t) : t = match j with `Assoc l -> (try List.assoc k l with Not_found -> `Null) | _ -> `Null

let rec path ks j = match ks with [] -> j | k :: r -> path r (get k j)

let string_opt = function `String s -> Some s | _ -> None
let int_opt = function
  | `Int i -> Some i
  | `Intlit s -> int_of_string_opt s
  | `Float f when Float.is_integer f -> Some (int_of_float f)
  | _ -> None
let float_opt = function `Float f -> Some f | `Int i -> Some (float_of_int i) | `Intlit s -> float_of_string_opt s | _ -> None
let bool_opt = function `Bool b -> Some b | _ -> None
let list_opt = function `List l -> Some l | _ -> None
let assoc_opt = function `Assoc l -> Some l | _ -> None

let str k j = string_opt (get k j)
let int k j = int_opt (get k j)
let float k j = float_opt (get k j)
let bool k j = bool_opt (get k j)
let list k j = match get k j with `List l -> l | _ -> []
let obj k j = match get k j with `Assoc _ as o -> o | _ -> `Assoc []

let str_d k d j = match str k j with Some s -> s | None -> d
let int_d k d j = match int k j with Some i -> i | None -> d
let bool_d k d j = match bool k j with Some b -> b | None -> d

(* Cadena no vacia tras recortar. *)
let str_ne k j = match str k j with Some s when String.trim s <> "" -> Some (String.trim s) | _ -> None

let opt_string = function Some s -> `String s | None -> `Null
let opt_int = function Some i -> `Int i | None -> `Null
let opt_float = function Some f -> `Float f | None -> `Null
let opt_bool = function Some b -> `Bool b | None -> `Null

(* Quita las claves con valor nulo. *)
let sin_nulos = function `Assoc l -> `Assoc (List.filter (fun (_, v) -> v <> `Null) l) | j -> j

(* Une dos objetos; los de `b` ganan. *)
let merge a b =
  match (a, b) with
  | `Assoc la, `Assoc lb ->
      let la = List.filter (fun (k, _) -> not (List.mem_assoc k lb)) la in
      `Assoc (la @ lb)
  | _, b -> b

let set k v = function
  | `Assoc l -> `Assoc ((k, v) :: List.remove_assoc k l)
  | _ -> `Assoc [ (k, v) ]
