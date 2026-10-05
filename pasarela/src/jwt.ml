(* JWT HS256 escrito a mano (RFC 7519): cabecera y carga en base64url, firma HMAC-SHA256. Solo se acepta alg=HS256: ni
   `none` ni otros algoritmos. La comparacion de la firma es en tiempo constante. *)

type claims = { sub : int; rol : string; tec : int option; iat : int; exp : int }

let cabecera = Cripto.b64u {|{"alg":"HS256","typ":"JWT"}|}

let firmar ~(secreto : string) ?(ahora = Unix.gettimeofday ()) ?(horas = 12) ~(sub : int) ~(rol : string) ~(tec : int option) () : string =
  let iat = int_of_float ahora in
  let carga =
    `Assoc
      [ ("sub", `Int sub); ("rol", `String rol); ("tec", Json.opt_int tec); ("iat", `Int iat); ("exp", `Int (iat + (horas * 3600))) ]
  in
  let cuerpo = Cripto.b64u (Json.to_string carga) in
  let firma = Cripto.b64u (Cripto.hmac_sha256 ~key:secreto (cabecera ^ "." ^ cuerpo)) in
  cabecera ^ "." ^ cuerpo ^ "." ^ firma

type error = Malformado | Firma_invalida | Expirado

let verificar ~(secreto : string) ?(ahora = Unix.gettimeofday ()) (token : string) : (claims, error) result =
  match String.split_on_char '.' token with
  | [ cab; cuerpo; firma ] -> (
      let esperada = Cripto.b64u (Cripto.hmac_sha256 ~key:secreto (cab ^ "." ^ cuerpo)) in
      (* La cabecera tambien se verifica: solo la que emitimos nosotros. Cualquier otra (alg=none incluida) se rechaza. *)
      if not (Cripto.igual_const firma esperada && Cripto.igual_const cab cabecera) then Error Firma_invalida
      else
        match Option.bind (Cripto.b64u_decodificar cuerpo) (fun s -> Result.to_option (Json.parse s)) with
        | None -> Error Malformado
        | Some j -> (
            match (Json.int "sub" j, Json.str "rol" j, Json.int "exp" j) with
            | Some sub, Some rol, Some exp ->
                if float_of_int exp <= ahora then Error Expirado
                else Ok { sub; rol; tec = Json.int "tec" j; iat = Json.int_d "iat" 0 j; exp }
            | _ -> Error Malformado))
  | _ -> Error Malformado
