(* Textos fijos que arma el CODIGO (nunca un LLM): numero de incidencia, tecnico, plazo, estado (AGENTS §3.1, CONTRATOS §1).
   Español de Peru, breve, trato de «tú» (configurable mas adelante en `configuracion`). Los plazos se escriben en hora
   de Lima. Nada de notas internas. *)

let estado_corto = function
  | "nueva" -> "Recibida"
  | "asignada" -> "Asignada"
  | "en_curso" -> "En curso"
  | "espera_usuario" -> "Esperando tu respuesta"
  | "espera_tercero" -> "Esperando a un proveedor"
  | "resuelta" -> "Resuelta, falta tu confirmación"
  | "cerrada" -> "Cerrada"
  | "reabierta" -> "Reabierta"
  | otro -> otro

(* Para la pagina publica de estado (DISENO §16). *)
let estado_publico = function
  | "nueva" -> "Recibimos tu solicitud"
  | "asignada" -> "Ya tiene un técnico asignado"
  | "en_curso" -> "Estamos trabajando en ella"
  | "espera_usuario" -> "Esperamos tu respuesta"
  | "espera_tercero" -> "Esperamos a un proveedor"
  | "resuelta" -> "Resuelta: confírmanos si quedó bien"
  | "cerrada" -> "Cerrada"
  | "reabierta" -> "Reabierta: volvimos a revisarla"
  | otro -> otro

let enlace ~(base_url : string) (token : string option) : string option =
  match (base_url, token) with
  | b, Some t when b <> "" && t <> "" -> Some (Printf.sprintf "%s/estado/%s" b t)
  | _ -> None

let ( ^? ) a = function Some b -> a ^ b | None -> a

(* --- creacion de la incidencia ---------------------------------------------------------------------------------- *)

(* `inc` es la `incidencia` de la respuesta del motor; `asignacion` su decision de despacho. *)
let incidencia_creada ~(ahora : float) ~(base_url : string) ~(inc : Json.t) ~(asignacion : Json.t) : string =
  let numero = Json.str_d "numero" "" inc in
  let prio = Json.str_d "prioridad" "" inc in
  let tecnico = Json.str "tecnico" inc in
  let grupo = Json.str "grupo" inc in
  let en_cola = Json.bool_d "en_cola" false asignacion in
  let resp = Tiempo.plazo_de_iso ~ahora (Json.str "vence_respuesta_en" inc) in
  let reso = Tiempo.plazo_de_iso ~ahora (Json.str "vence_resolucion_en" inc) in
  let cab = Printf.sprintf "Registré tu incidencia %s%s." numero (if prio <> "" then Printf.sprintf " (prioridad %s)" prio else "") in
  let quien =
    match (tecnico, en_cola) with
    | Some t, false -> (
        match resp with
        | Some p -> Printf.sprintf " La atiende %s, que te responderá antes de %s." t p
        | None -> Printf.sprintf " La atiende %s." t)
    | _ -> (
        let g = match grupo with Some g -> " de " ^ g | None -> "" in
        match resp with
        | Some p -> Printf.sprintf " Quedó en la cola%s: un técnico la tomará en cuanto pueda, y te aviso apenas la asignen. La primera respuesta está prevista antes de %s." g p
        | None -> Printf.sprintf " Quedó en la cola%s: un técnico la tomará en cuanto pueda, y te aviso apenas la asignen." g)
  in
  let plazo = match reso with Some p -> Printf.sprintf " Plazo de resolución: %s." p | None -> "" in
  let link = match enlace ~base_url (Json.str "token_publico" inc) with Some l -> "\nPuedes ver el estado aquí: " ^ l | None -> "" in
  cab ^ quien ^ plazo ^ link

let incidencia_duplicada ~(base_url : string) ~(agregado : bool) ~(inc : Json.t) : string =
  let numero = Json.str_d "numero" "" inc in
  let estado = Json.str_d "estado" "" inc in
  let est = if estado = "" then "sin dato" else String.lowercase_ascii (estado_corto estado) in
  let tecnico = match Json.str "tecnico" inc with Some t -> Printf.sprintf " La atiende %s." t | None -> "" in
  let link = match enlace ~base_url (Json.str "token_publico" inc) with Some l -> "\nPuedes ver el estado aquí: " ^ l | None -> "" in
  if agregado then
    Printf.sprintf "Ya tienes abierta la incidencia %s por este tema, así que agregué lo que me contaste en lugar de abrir otra. Estado: %s.%s%s" numero est tecnico link
  else Printf.sprintf "Ya tienes abierta la incidencia %s por este tema. Estado: %s.%s%s" numero est tecnico link

(* --- consulta de estado ------------------------------------------------------------------------------------------- *)

let linea_incidencia ~ahora ~base_url (f : Json.t) : string =
  let numero = Json.str_d "numero" "" f and titulo = Json.str_d "titulo" "" f in
  let estado = Json.str_d "estado" "" f in
  let tec = match Json.str "tecnico" f with Some t -> Printf.sprintf " · La atiende %s" t | None -> " · Sin técnico asignado todavía" in
  let plazo =
    match estado with
    | "resuelta" | "cerrada" -> ""
    | _ -> ( match Tiempo.plazo_de_iso ~ahora (Json.str "vence_resolucion_en" f) with Some p -> " · Plazo de resolución: " ^ p | None -> "")
  in
  let link = match enlace ~base_url (Json.str "token_publico" f) with Some l -> "\n  Detalle: " ^ l | None -> "" in
  Printf.sprintf "• %s · %s\n  %s%s%s%s" numero titulo (estado_corto estado) tec plazo link

let consulta_estado ~ahora ~base_url (filas : Json.t list) : string =
  match filas with
  | [] -> "No veo incidencias abiertas a tu nombre. Si tienes un problema nuevo, cuéntame qué pasa y lo revisamos."
  | [ f ] ->
      let numero = Json.str_d "numero" "" f in
      Printf.sprintf "Esto es lo que tengo de tu incidencia %s:\n%s" numero (linea_incidencia ~ahora ~base_url f)
  | fs -> "Estas son tus incidencias abiertas:\n\n" ^ String.concat "\n\n" (List.map (linea_incidencia ~ahora ~base_url) fs)

let sin_incidencia_para_dato = "Anotado. Cuando abra una incidencia, lo incluiré."

(* --- respaldos y avisos de cortesia ------------------------------------------------------------------------------- *)

let agente_caido_sin_incidencia =
  "Tengo un problema técnico y no pude procesar tu mensaje. Ya avisé a la mesa de ayuda; si es urgente, vuelve a escribirme en unos minutos."

let agente_caido_con_incidencia ~numero =
  Printf.sprintf "Tuve un problema técnico y no pude atender tu mensaje como debía. Dejé registrada la incidencia %s y una persona de la mesa de ayuda te escribirá por aquí." numero

let agente_caido_ya_abierta ~numero =
  Printf.sprintf "Tuve un problema técnico y no pude procesar tu mensaje. Lo agregué a tu incidencia abierta %s para que una persona de la mesa de ayuda lo vea." numero

let no_texto tipo =
  let que = match tipo with "audio" -> "los audios" | "imagen" -> "las imágenes" | "video" -> "los videos" | "documento" -> "los documentos" | "sticker" -> "los stickers" | "ubicacion" -> "las ubicaciones" | "contacto" -> "los contactos" | _ -> "ese tipo de mensajes" in
  Printf.sprintf "Por ahora no puedo leer %s. ¿Me cuentas por escrito qué ocurre? Así te ayudo más rápido." que

let respuesta_vacia = "No estoy seguro de haberte entendido. ¿Puedes contarme con otras palabras qué problema tienes?"

let incidencia_no_registrada =
  "No pude registrar tu incidencia en este momento. Tus datos quedaron guardados en esta conversación; inténtalo de nuevo en unos minutos o escribe «técnico» para que una persona te atienda."

let no_pude_avisar =
  "No pude avisar ahora a quien atiende tu incidencia. Inténtalo de nuevo en unos minutos; tu mensaje quedó guardado en esta conversación."

let encuesta_gracias = "¡Gracias por tu calificación! Nos ayuda a mejorar."

let tomada_por ~(nombre : string) =
  Printf.sprintf "Te escribe %s, de la mesa de ayuda. Desde aquí continúa tu conversación una persona." nombre

let devuelta_al_asistente = "Si necesitas algo más, aquí sigo para ayudarte."

let pide_tecnico_con_incidencia ~numero =
  Printf.sprintf "Entendido. Ya avisé a quien atiende tu incidencia %s que prefieres hablar con una persona; te escribirán por aquí." numero

let reabierta ~numero = Printf.sprintf "Lamento que siga igual. Reabrí tu incidencia %s para que la revisen de nuevo y te aviso de cada cambio." numero

let sigue_igual_con_abierta ~numero = Printf.sprintf "Gracias por avisar. Dejé anotado en tu incidencia %s que el problema sigue igual." numero

let resuelta_confirmada ~numero = Printf.sprintf "Perfecto, cerré tu incidencia %s. ¡Gracias por confirmarlo!" numero

(* --- avisos al tecnico, al responsable, a la guardia, al supervisor y a la persona -------------------------------- *)

(* Valores que una plantilla puede usar. Cualquier otra clave de `datos` (p. ej. una nota interna) se ignora. *)
let claves_plantilla =
  [ "numero"; "prioridad"; "titulo"; "estado"; "estado_texto"; "tecnico"; "grupo"; "categoria"; "plazo"; "plazo_respuesta"; "porcentaje"; "enlace" ]

let plantillas_por_defecto : (string * string) list =
  [ ("incidencia_asignada", "Te asignaron la incidencia {numero} ({prioridad}): {titulo}. Plazo de resolución: {plazo}.");
    ("incidencia_sin_asignar", "La incidencia {numero} ({prioridad}) quedó sin técnico en la cola de {grupo}: {titulo}.");
    ("sla_75", "Aviso: la incidencia {numero} ({prioridad}) va al {porcentaje} % de su plazo. {titulo}");
    ("sla_100", "La incidencia {numero} ({prioridad}) venció su plazo: {titulo}. Se escaló según la matriz.");
    ("p1_creada", "Prioridad 1: incidencia {numero}, {titulo}. Requiere atención inmediata.");
    ("reapertura_2", "La incidencia {numero} se reabrió por segunda vez: {titulo}. Revísala.");
    ("queja", "La persona de la incidencia {numero} expresó una queja: {titulo}. Revísala.");
    ("vip", "Incidencia {numero} de una persona VIP ({prioridad}): {titulo}.");
    ("guia_agotada", "La incidencia {numero} se abrió porque la guía del asistente no resolvió el problema: {titulo}.");
    (* A la persona. *)
    ("persona_asignada", "Tu incidencia {numero} ahora la atiende {tecnico}. Plazo de resolución: {plazo}. {enlace}");
    ("persona_resuelta", "Tu incidencia {numero} está marcada como resuelta. ¿Quedó resuelto? Responde «sí, se resolvió» o «sigue igual». {enlace}");
    ("persona_reabierta", "Reabrimos tu incidencia {numero} para revisarla de nuevo. {enlace}");
    ("recordatorio_cierre", "Hola, ¿pudiste comprobar si tu incidencia {numero} quedó resuelta? Responde «sí, se resolvió» o «sigue igual».");
    ("recordatorio_encuesta", "Cuando puedas, cuéntame del 1 al 5 qué tal te atendimos en tu incidencia {numero}. Nos ayuda a mejorar.");
    (* Cualquier otra. *)
    ("generica_tecnico", "Novedad en la incidencia {numero} ({estado_texto}): {titulo}.");
    ("generica_persona", "Novedad en tu incidencia {numero}: {estado_texto}. {enlace}") ]

let re_hueco = Re.(compile (seq [ char '{'; group (rep1 (alt [ rg 'a' 'z'; char '_' ])); char '}' ]))
let re_espacios = Re.(compile (seq [ rep1 (char ' ') ]))

(* Quita caracteres de control (menos salto de linea) y recorta. *)
let limpiar_valor (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> if c = '\n' || (Char.code c >= 32 && Char.code c <> 127) then Buffer.add_char b c) s;
  let r = String.trim (Buffer.contents b) in
  if String.length r > 300 then String.sub r 0 300 else r

let render (plantilla : string) (valores : (string * string) list) : string =
  let t =
    Re.replace re_hueco plantilla ~f:(fun g ->
        let k = Re.Group.get g 1 in
        if List.mem k claves_plantilla then (match List.assoc_opt k valores with Some v -> limpiar_valor v | None -> "") else Re.Group.get g 0)
  in
  let t = Re.replace_string re_espacios ~by:" " t in
  (* « .» y « ,» que dejo un hueco vacio. *)
  let t = Re.replace_string (Re.compile (Re.str " .")) ~by:"." t in
  let t = Re.replace_string (Re.compile (Re.str "()")) ~by:"" t in
  (* Sin caracteres de control (salvo el salto de linea), venga de la plantilla o de un valor. *)
  let b = Buffer.create (String.length t) in
  String.iter (fun c -> if c = '\n' || (Char.code c >= 32 && Char.code c <> 127) then Buffer.add_char b c) t;
  String.trim (Buffer.contents b)

(* Huecos que una plantilla editada puede usar: valida lo que escribe el administrador. *)
let huecos_invalidos (plantilla : string) : string list =
  Re.all re_hueco plantilla |> List.filter_map (fun g -> let k = Re.Group.get g 1 in if List.mem k claves_plantilla then None else Some k)
