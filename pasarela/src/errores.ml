(* Errores de la API: `{ "error": "texto en español para la persona", "codigo": "..." }` (CONTRATOS §2).
   Los codigos del contrato son no_autorizado | no_encontrado | invalido | conflicto. Se anaden `limite` (429),
   `no_disponible` (502/503, cuando el motor o el agente no responden) e `interno` (500). *)

exception Api of int * string * string (* estado HTTP, codigo, mensaje *)

let no_autorizado ?(estado = 401) msg = raise (Api (estado, "no_autorizado", msg))
let prohibido msg = raise (Api (403, "no_autorizado", msg))
let no_encontrado msg = raise (Api (404, "no_encontrado", msg))
let invalido msg = raise (Api (400, "invalido", msg))
let conflicto msg = raise (Api (409, "conflicto", msg))
let limite ?(msg = "Demasiados intentos seguidos. Espera un momento y vuelve a intentarlo.") () = raise (Api (429, "limite", msg))
let no_disponible msg = raise (Api (503, "no_disponible", msg))
let interno msg = raise (Api (500, "interno", msg))

let cuerpo codigo mensaje = `Assoc [ ("error", `String mensaje); ("codigo", `String codigo) ]
