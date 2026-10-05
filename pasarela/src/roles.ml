(* Roles de la consola (CONTRATOS §2): tecnico < supervisor < gerencia; `entrenador` aparte; `admin` puede todo. *)

type rol = Tecnico | Supervisor | Gerencia | Entrenador | Admin

type requisito =
  | R_publico
  | R_tecnico (* tecnico, supervisor, gerencia (y admin) *)
  | R_supervisor (* supervisor, gerencia (y admin) *)
  | R_gerencia
  | R_entrenador (* solo entrenador (y admin) *)
  | R_admin
  | R_conversaciones (* lo anterior a tecnico, o el entrenador: revisa conversaciones para entrenar *)

let de_string = function
  | "tecnico" -> Some Tecnico
  | "supervisor" -> Some Supervisor
  | "gerencia" -> Some Gerencia
  | "entrenador" -> Some Entrenador
  | "admin" -> Some Admin
  | _ -> None

let a_string = function Tecnico -> "tecnico" | Supervisor -> "supervisor" | Gerencia -> "gerencia" | Entrenador -> "entrenador" | Admin -> "admin"

let todos = [ Tecnico; Supervisor; Gerencia; Entrenador; Admin ]

(* Peldano en la escalera tecnico < supervisor < gerencia. El entrenador no esta en ella. *)
let peldano = function Tecnico -> Some 1 | Supervisor -> Some 2 | Gerencia -> Some 3 | Entrenador -> None | Admin -> Some 99

let permite (r : rol) (req : requisito) : bool =
  match (r, req) with
  | _, R_publico -> true
  | Admin, _ -> true
  | Entrenador, (R_entrenador | R_conversaciones) -> true
  | Entrenador, _ -> false
  | _, R_admin -> false
  | _, R_entrenador -> false
  | r, R_conversaciones -> peldano r >= Some 1
  | r, R_tecnico -> peldano r >= Some 1
  | r, R_supervisor -> peldano r >= Some 2
  | r, R_gerencia -> peldano r >= Some 3
