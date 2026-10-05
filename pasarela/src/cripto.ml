(* Primitivas de criptografia. Solo digestif (SHA-256 y HMAC) y /dev/urandom. *)

(* Comparacion en tiempo constante: no se detiene en la primera diferencia. La longitud si se compara antes, y la
   longitud de un secreto no es secreta aqui (todos los secretos comparados tienen longitud fija o publica). *)
let igual_const (a : string) (b : string) : bool =
  let la = String.length a and lb = String.length b in
  let acc = ref (la lxor lb) in
  let n = max la lb in
  for i = 0 to n - 1 do
    let ca = if i < la then Char.code (String.unsafe_get a i) else 0 in
    let cb = if i < lb then Char.code (String.unsafe_get b i) else 0 in
    acc := !acc lor (ca lxor cb)
  done;
  !acc = 0

let hmac_sha256 ~(key : string) (msg : string) : string =
  Digestif.SHA256.(to_raw_string (hmac_string ~key msg))

let sha256_hex (s : string) : string = Digestif.SHA256.(to_hex (digest_string s))

let hex_de_bytes (s : string) : string =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents b

(* Bytes aleatorios del sistema. Falla fuerte si /dev/urandom no existe: sin entropia no se firma ni se hashea. *)
let aleatorio (n : int) : string =
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> really_input_string ic n)

let b64u (s : string) : string = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64u_decodificar (s : string) : string option =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with Ok v -> Some v | Error _ -> None

(* PBKDF2-HMAC-SHA256 (RFC 8018), un bloque de 32 bytes: basta para una clave derivada de 256 bits. *)
let pbkdf2_sha256 ~(clave : string) ~(sal : string) ~(iteraciones : int) : string =
  let u1 = hmac_sha256 ~key:clave (sal ^ "\000\000\000\001") in
  let acc = Bytes.of_string u1 in
  let u = ref u1 in
  for _ = 2 to iteraciones do
    u := hmac_sha256 ~key:clave !u;
    for i = 0 to 31 do
      Bytes.unsafe_set acc i (Char.unsafe_chr (Char.code (Bytes.unsafe_get acc i) lxor Char.code (String.unsafe_get !u i)))
    done
  done;
  Bytes.to_string acc

(* Formato guardado en usuarios_consola.clave_hash: pbkdf2-sha256$<iteraciones>$<sal>$<hash>. Las iteraciones van
   dentro: subirlas mas adelante no invalida las claves ya guardadas. *)
(* OWASP 2023 pide 600000 iteraciones de PBKDF2-HMAC-SHA256. Medido: ~0,5 s por hash, en un hilo aparte (Auth.hash_en_hilo). *)
let iteraciones_por_defecto = 600_000

let hash_clave ?(iteraciones = iteraciones_por_defecto) (clave : string) : string =
  let sal = aleatorio 16 in
  let h = pbkdf2_sha256 ~clave ~sal ~iteraciones in
  Printf.sprintf "pbkdf2-sha256$%d$%s$%s" iteraciones (b64u sal) (b64u h)

let verificar_clave (clave : string) ~(hash : string) : bool =
  match String.split_on_char '$' hash with
  | [ "pbkdf2-sha256"; it; sal; esperado ] -> (
      match (int_of_string_opt it, b64u_decodificar sal, b64u_decodificar esperado) with
      | Some iteraciones, Some sal, Some esperado when iteraciones >= 1 && iteraciones <= 10_000_000 ->
          igual_const (pbkdf2_sha256 ~clave ~sal ~iteraciones) esperado
      | _ -> false)
  | _ -> false

(* Hash de relleno para equilibrar el tiempo cuando el correo no existe (no revela si el usuario existe). *)
let hash_de_relleno = lazy (hash_clave "relleno-no-es-una-clave")
