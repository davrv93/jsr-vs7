(* Autenticacion y roles de la consola: login con clave hasheada (PBKDF2-HMAC-SHA256), JWT HS256 de 12 h, usuario cargado de
   la base en cada peticion (un usuario desactivado o con otro rol surte efecto al instante), limites de intentos y auditoria. *)

let ( let* ) = Lwt.bind

type usuario = { id : int; nombre : string; email : string; rol : Roles.rol; tecnico_id : int option }

let usuario_json (u : usuario) : Json.t =
  `Assoc [ ("id", `Int u.id); ("nombre", `String u.nombre); ("rol", `String (Roles.a_string u.rol)); ("tecnico_id", Json.opt_int u.tecnico_id); ("email", `String u.email) ]

let de_fila (f : Json.t) : usuario option =
  match (Json.int "id" f, Option.bind (Json.str "rol" f) Roles.de_string) with
  | Some id, Some rol -> Some { id; nombre = Json.str_d "nombre" "" f; email = Json.str_d "email" "" f; rol; tecnico_id = Json.int "tecnico_id" f }
  | _ -> None

let sesion_expirada () = Errores.no_autorizado "Tu sesión expiró. Vuelve a entrar."

let bearer (req : Dream.request) : string option =
  match Dream.header req "Authorization" with
  | Some h when String.length h > 7 && String.lowercase_ascii (String.sub h 0 7) = "bearer " -> Some (String.trim (String.sub h 7 (String.length h - 7)))
  | _ -> None

(* El usuario de la peticion, o 401. *)
let autenticar (ctx : Ctx.t) (req : Dream.request) : usuario Lwt.t =
  match bearer req with
  | None -> sesion_expirada ()
  | Some token -> (
      match Jwt.verificar ~secreto:ctx.cfg.jwt_secret ~ahora:(Ctx.ahora ctx) token with
      | Error _ -> sesion_expirada ()
      | Ok claims -> (
          let* f =
            Db.fila_p ctx.db "SELECT id, email, nombre, rol, tecnico_id FROM usuarios_consola WHERE id = $i:id AND activo" (`Assoc [ ("id", `Int claims.sub) ])
          in
          match de_fila f with Some u -> Lwt.return u | None -> sesion_expirada ()))

let exigir (req : Roles.requisito) (u : usuario) : unit =
  if not (Roles.permite u.rol req) then Errores.prohibido "Tu rol no tiene permiso para esto."

(* Envuelve un manejador: autentica, comprueba el rol y se lo pasa al manejador con el usuario. *)
let ruta (ctx : Ctx.t) (req_rol : Roles.requisito) (h : usuario -> Dream.request -> Dream.response Lwt.t) : Dream.handler =
 fun req ->
  let* u = autenticar ctx req in
  exigir req_rol u;
  h u req

(* --- login --------------------------------------------------------------------------------------------------------------------- *)

let normalizar_correo (s : string) = String.lowercase_ascii (String.trim s)

(* PBKDF2 es CPU: se hace en un hilo aparte para no frenar a los demas. *)
let verificar_en_hilo ~clave ~hash : bool Lwt.t = Lwt_preemptive.detach (fun () -> Cripto.verificar_clave clave ~hash) ()

let hash_en_hilo ~iteraciones clave : string Lwt.t = Lwt_preemptive.detach (fun () -> Cripto.hash_clave ~iteraciones clave) ()

let login (ctx : Ctx.t) (req : Dream.request) : Dream.response Lwt.t =
  let ip = Seguridad.ip ctx.cfg req in
  let ahora = Ctx.ahora ctx in
  (match Limite.intentar ~ahora ctx.limites.login_ip ip with
  | Error s -> Errores.limite ~msg:(Printf.sprintf "Demasiados intentos desde tu red. Espera %d minuto(s) y vuelve a intentarlo." ((s + 59) / 60)) ()
  | Ok () -> ());
  let* cuerpo = Seguridad.cuerpo_json ~max:4096 req in
  let email = match Json.str "email" cuerpo with Some e -> normalizar_correo e | None -> "" in
  let clave = Json.str_d "clave" "" cuerpo in
  if email = "" || clave = "" then Errores.invalido "Escribe tu correo y tu clave.";
  if String.length email > 200 || String.length clave > 200 then Errores.invalido "El correo o la clave son demasiado largos.";
  (match Limite.bloqueado ~ahora ctx.limites.login_email email with
  | Error s -> Errores.limite ~msg:(Printf.sprintf "Demasiados intentos con ese correo. Espera %d minuto(s) y vuelve a intentarlo." ((s + 59) / 60)) ()
  | Ok () -> ());
  let* f =
    Db.fila_p ctx.db "SELECT id, email, nombre, rol, tecnico_id, clave_hash, activo FROM usuarios_consola WHERE email = $email" (`Assoc [ ("email", `String email) ])
  in
  let hash = match (Json.str "clave_hash" f, Json.bool_d "activo" false f) with Some h, true -> h | _ -> Lazy.force Cripto.hash_de_relleno in
  let* correcta = verificar_en_hilo ~clave ~hash in
  match (correcta, de_fila f, Json.bool_d "activo" false f) with
  | true, Some u, true ->
      Limite.olvidar ctx.limites.login_email email;
      let token = Jwt.firmar ~secreto:ctx.cfg.jwt_secret ~ahora ~horas:ctx.cfg.jwt_horas ~sub:u.id ~rol:(Roles.a_string u.rol) ~tec:u.tecnico_id () in
      let* () = Auditoria.registrar_p ~usuario_id:u.id ~objeto:(Printf.sprintf "usuario:%d" u.id) ~detalle:(`Assoc [ ("ip", `String ip) ]) ctx.db ~accion:"login" in
      Seguridad.responder_json (`Assoc [ ("token", `String token); ("usuario", usuario_json u) ])
  | _ ->
      Limite.registrar ~ahora ctx.limites.login_email email;
      let* () =
        Auditoria.registrar_p ~detalle:(`Assoc [ ("correo", `String (Mascara.correo email)); ("ip", `String ip) ]) ctx.db ~accion:"login_fallido"
      in
      Dream.warning (fun l -> l "login fallido (%s)" (Mascara.correo email));
      Errores.no_autorizado "El correo o la clave no coinciden. Revísalos e inténtalo de nuevo."

let yo (u : usuario) (_ : Dream.request) : Dream.response Lwt.t = Seguridad.responder_json (usuario_json u)

(* Siembra o actualiza un usuario (subcomando `crear-admin`). *)
let crear_usuario (db : Db.t) ~(iteraciones : int) ~(email : string) ~(nombre : string) ~(rol : string) ~(clave : string) : unit Lwt.t =
  let* hash = hash_en_hilo ~iteraciones clave in
  Db.usar db (fun c ->
      let* () =
        Db.exec c
          "INSERT INTO usuarios_consola (email, nombre, rol, clave_hash) VALUES ($email, $nombre, $rol, $hash) ON CONFLICT (email) DO UPDATE SET nombre = EXCLUDED.nombre, rol = EXCLUDED.rol, clave_hash = EXCLUDED.clave_hash, activo = true"
          (`Assoc [ ("email", `String (normalizar_correo email)); ("nombre", `String nombre); ("rol", `String rol); ("hash", `String hash) ])
      in
      Auditoria.registrar c ~accion:"usuario_sembrado" ~objeto:("usuario:" ^ normalizar_correo email |> fun s -> s) ~detalle:(`Assoc [ ("rol", `String rol) ]))
