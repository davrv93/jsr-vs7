(* Configuracion por entorno. NUNCA se imprime un valor secreto: `resumen` solo dice si esta presente. *)

type modo_evolution = Simulado | Real

type t = {
  puerto : int;
  database_url : string;
  jwt_secret : string;
  motor_url : string;
  motor_clave : string;
  agente_url : string;
  evolution_modo : modo_evolution;
  evolution_url : string;
  evolution_api_key : string;
  evolution_instancia : string;
  webhook_secret : string;
  analitica_texto : bool;
  base_url_publica : string;
  cors_origenes : string list;
  confiar_proxy : bool;
  (* Afinacion. Los valores por defecto son los del contrato y de kddesign. *)
  jwt_horas : int;
  pbkdf2_iter : int;
  sesion_horas : float; (* silencio a partir del cual el mensaje abre un caso nuevo: 6 h *)
  agente_timeout_s : float;
  motor_timeout_s : float;
  evolution_timeout_s : float;
  salida_espaciado_ms : int;
  historial_turnos : int;
  recordatorio_cierre_horas : float;
  recordatorio_encuesta_horas : float;
  estado_caduca_dias : int;
  pool_conexiones : int;
  migrar : bool;
  trabajadores : bool; (* avisos, recordatorios y sondeo de eventos *)
  chat_web : bool; (* POST /api/chat-web (publico por contrato): CHAT_WEB=0 lo apaga en produccion *)
}

let nunca_vacio = function Some s when String.trim s <> "" -> Some (String.trim s) | _ -> None

let sin_barra_final s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '/' then String.sub s 0 (n - 1) else s

let es_si = function Some ("1" | "true" | "si" | "sí" | "yes" | "on") -> true | _ -> false

(* `cargar ~getenv` devuelve la configuracion o la lista de problemas, TODOS a la vez: asi el arranque dice de una vez
   que falta, no una variable por intento. *)
let cargar ~(getenv : string -> string option) : (t, string list) result =
  let errores = ref [] in
  let falta nombre = errores := Printf.sprintf "falta la variable de entorno %s" nombre :: !errores in
  let obligatoria nombre =
    match nunca_vacio (getenv nombre) with
    | Some v -> v
    | None ->
        falta nombre;
        ""
  in
  let entero nombre def minimo maximo =
    match nunca_vacio (getenv nombre) with
    | None -> def
    | Some s -> (
        match int_of_string_opt s with
        | Some n when n >= minimo && n <= maximo -> n
        | _ ->
            errores := Printf.sprintf "%s debe ser un entero entre %d y %d" nombre minimo maximo :: !errores;
            def)
  in
  let decimal nombre def minimo maximo =
    match nunca_vacio (getenv nombre) with
    | None -> def
    | Some s -> (
        match float_of_string_opt s with
        | Some n when n >= minimo && n <= maximo -> n
        | _ ->
            errores := Printf.sprintf "%s debe ser un numero entre %g y %g" nombre minimo maximo :: !errores;
            def)
  in
  let database_url = obligatoria "DATABASE_URL" in
  let jwt_secret = obligatoria "JWT_SECRET" in
  if jwt_secret <> "" && String.length jwt_secret < 16 then
    errores := "JWT_SECRET es demasiado corto (minimo 16 caracteres; usa 32 o mas)" :: !errores;
  let motor_url = sin_barra_final (obligatoria "MOTOR_URL") in
  let motor_clave = obligatoria "MOTOR_CLAVE" in
  if motor_clave <> "" && String.length motor_clave < 16 then errores := "MOTOR_CLAVE es demasiado corta (el motor exige al menos 16 caracteres)" :: !errores;
  let agente_url = sin_barra_final (obligatoria "AGENTE_URL") in
  let webhook_secret = obligatoria "WEBHOOK_SECRET" in
  let modo =
    match nunca_vacio (getenv "EVOLUTION_MODO") with
    | None | Some "simulado" -> Simulado
    | Some "real" -> Real
    | Some otro ->
        errores := Printf.sprintf "EVOLUTION_MODO debe ser «simulado» o «real» (llego %S)" otro :: !errores;
        Simulado
  in
  let evolution_url, evolution_api_key, evolution_instancia =
    match modo with
    | Simulado ->
        ( sin_barra_final (Option.value (nunca_vacio (getenv "EVOLUTION_URL")) ~default:""),
          Option.value (nunca_vacio (getenv "EVOLUTION_API_KEY")) ~default:"",
          Option.value (nunca_vacio (getenv "EVOLUTION_INSTANCIA")) ~default:"" )
    | Real ->
        (* El modo real exige todo explicito: un envio a un numero real no puede salir de un valor por defecto. *)
        (sin_barra_final (obligatoria "EVOLUTION_URL"), obligatoria "EVOLUTION_API_KEY", obligatoria "EVOLUTION_INSTANCIA")
  in
  let cors_origenes =
    match nunca_vacio (getenv "CORS") with
    | None -> []
    | Some s -> s |> String.split_on_char ',' |> List.map String.trim |> List.filter (fun x -> x <> "") |> List.map sin_barra_final
  in
  let cfg =
    {
      puerto = entero "PORT" 8080 1 65535;
      database_url;
      jwt_secret;
      motor_url;
      motor_clave;
      agente_url;
      evolution_modo = modo;
      evolution_url;
      evolution_api_key;
      evolution_instancia;
      webhook_secret;
      analitica_texto = es_si (getenv "ANALITICA_TEXTO");
      base_url_publica = sin_barra_final (Option.value (nunca_vacio (getenv "BASE_URL_PUBLICA")) ~default:"");
      cors_origenes;
      confiar_proxy = es_si (getenv "CONFIAR_PROXY");
      jwt_horas = entero "JWT_HORAS" 12 1 168;
      pbkdf2_iter = entero "PBKDF2_ITER" Cripto.iteraciones_por_defecto 1_000 5_000_000;
      sesion_horas = decimal "SESION_HORAS" 6.0 0.01 720.0;
      agente_timeout_s = decimal "AGENTE_TIMEOUT_S" 30.0 0.1 300.0;
      motor_timeout_s = decimal "MOTOR_TIMEOUT_S" 15.0 0.1 120.0;
      evolution_timeout_s = decimal "EVOLUTION_TIMEOUT_S" 30.0 0.1 300.0;
      salida_espaciado_ms = entero "SALIDA_ESPACIADO_MS" 900 0 30_000;
      historial_turnos = entero "HISTORIAL_TURNOS" 10 1 50;
      recordatorio_cierre_horas = decimal "RECORDATORIO_CIERRE_HORAS" 24.0 0.001 720.0;
      recordatorio_encuesta_horas = decimal "RECORDATORIO_ENCUESTA_HORAS" 12.0 0.001 720.0;
      estado_caduca_dias = entero "ESTADO_CADUCA_DIAS" 30 1 3650;
      pool_conexiones = entero "POOL_CONEXIONES" 8 1 100;
      migrar = (match nunca_vacio (getenv "MIGRAR") with Some "0" -> false | _ -> true);
      trabajadores = (match nunca_vacio (getenv "TRABAJADORES") with Some "0" -> false | _ -> true);
      chat_web = (match nunca_vacio (getenv "CHAT_WEB") with Some "0" -> false | _ -> true);
    }
  in
  match !errores with [] -> Ok cfg | es -> Error (List.rev es)

let desde_entorno () = cargar ~getenv:Sys.getenv_opt

(* Para el registro de arranque: presencia, nunca valores. *)
let resumen (c : t) : (string * string) list =
  let presente s = if s <> "" then "definida" else "VACIA" in
  [ ("puerto", string_of_int c.puerto);
    ("DATABASE_URL", presente c.database_url);
    ("JWT_SECRET", presente c.jwt_secret);
    ("MOTOR_URL", presente c.motor_url);
    ("MOTOR_CLAVE", presente c.motor_clave);
    ("AGENTE_URL", presente c.agente_url);
    ("WEBHOOK_SECRET", presente c.webhook_secret);
    ("EVOLUTION_MODO", (match c.evolution_modo with Simulado -> "simulado (no se envia nada)" | Real -> "REAL (envia a WhatsApp)"));
    ("EVOLUTION_API_KEY", presente c.evolution_api_key);
    ("ANALITICA_TEXTO", if c.analitica_texto then "1 (el texto de los mensajes va a ClickHouse)" else "0");
    ("CORS", if c.cors_origenes = [] then "sin origenes cruzados" else string_of_int (List.length c.cors_origenes) ^ " origen(es)");
    ("CONFIAR_PROXY", if c.confiar_proxy then "si" else "no");
    ("CHAT_WEB", if c.chat_web then "abierto (publico, con limites)" else "apagado") ]
