(* Enmascarado de datos personales para registros (logs) y para guardar texto de personas.
   AGENTS §1.4 regla 2 y §4: nada de telefonos, correos ni credenciales en claro fuera de donde hace falta. *)

(* 51987654321 -> 51••••4321. Con menos de 8 digitos se deja solo el final. *)
let telefono (s : string) : string =
  let d = Buffer.create 16 in
  String.iter (fun c -> if c >= '0' && c <= '9' then Buffer.add_char d c) s;
  let d = Buffer.contents d in
  let n = String.length d in
  if n = 0 then "••••"
  else if n >= 8 then String.sub d 0 2 ^ "••••" ^ String.sub d (n - 4) 4
  else "••••" ^ String.sub d (max 0 (n - 2)) (min 2 n)

(* Un identificador de chat de WhatsApp (JID) o un telefono: se enmascara el numero y se conserva el sufijo. *)
let chat (s : string) : string =
  match String.index_opt s '@' with
  | Some i -> telefono (String.sub s 0 i) ^ String.sub s i (String.length s - i)
  | None -> telefono s

let correo (s : string) : string =
  match String.index_opt s '@' with
  | Some i when i > 0 -> String.sub s 0 1 ^ "***" ^ String.sub s i (String.length s - i)
  | _ -> "***"

(* Credenciales que una persona pega por error en el chat. El agente tambien las oculta (CONTRATOS §1,
   `texto_usuario_guardar`); esto es la red de seguridad para cuando el agente no esta (respaldo de cortesia, pausa por
   tecnico, mensajes que van a la incidencia, estado publico). Conservadora: prefiere ocultar de mas. *)
let palabras_clave = Re.[ str "contraseña"; str "contrasena"; str "clave"; str "password"; str "passwd"; str "pwd"; str "token"; str "pin"; str "codigo"; str "código" ]

(* Palabra clave + separador (:, =, es) + valor: se oculta siempre. *)
let re_clave_sep =
  Re.(
    compile
      (seq
         [ bow;
           no_case (alt palabras_clave);
           rep (set " \t");
           alt [ str ":"; str "="; no_case (str "es "); no_case (str "is ") ];
           rep (set " \t");
           group (rep1 (compl [ set " \t\r\n" ])) ]))

(* Palabra clave + valor sin separador («mi clave Abc12345»): solo si el valor parece una clave (lleva digitos o simbolos). *)
let re_clave_sin_sep =
  Re.(
    compile
      (seq
         [ bow;
           no_case (alt [ str "contraseña"; str "contrasena"; str "password"; str "clave"; str "passwd"; str "pwd" ]);
           rep1 (set " \t");
           group (rep1 (compl [ set " \t\r\n" ])) ]))

let parece_clave v =
  String.length v >= 4
  && (let hay = ref false in
      (* Los bytes >= 0x80 son letras acentuadas en UTF-8 (ó, ñ): no cuentan como simbolo. *)
      String.iter (fun c -> if not ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || Char.code c >= 0x80) then hay := true) v;
      !hay)

let re_bearer = Re.(compile (seq [ no_case (str "bearer"); rep1 (set " \t"); group (rep1 (alt [ alnum; set "._-~+/=" ])) ]))

let re_largo = Re.(compile (rep1 (alt [ alnum; set "_-" ])))

let ocultar_credenciales (texto : string) : string =
  let reemplaza re ~cuando t =
    Re.replace re t ~f:(fun g ->
        let todo = Re.Group.get g 0 and valor = Re.Group.get g 1 in
        if cuando valor then
          let n = String.length todo - String.length valor in
          String.sub todo 0 n ^ "[oculto]"
        else todo)
  in
  let t = reemplaza re_clave_sep ~cuando:(fun v -> String.length v >= 2) texto in
  let t = reemplaza re_clave_sin_sep ~cuando:parece_clave t in
  let t = reemplaza re_bearer ~cuando:(fun _ -> true) t in
  (* Cadenas largas con letras y digitos mezclados: parecen un token o una llave. *)
  Re.replace re_largo t ~f:(fun g ->
      let s = Re.Group.get g 0 in
      if String.length s < 32 then s
      else begin
        let letra = ref false and digito = ref false in
        String.iter (fun c -> if c >= '0' && c <= '9' then digito := true else letra := true) s;
        if !letra && !digito then "[oculto]" else s
      end)
