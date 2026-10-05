(* Ayudas comunes de las pruebas: configuracion, base de datos de prueba, servicios falsos y datos semilla. *)

open Pasarela

let ( let* ) = Lwt.bind

let url_db = Sys.getenv_opt "JSR_TEST_DB"

(* Las pruebas de integracion se SALTAN si no hay base de prueba. *)
let requiere_db () = url_db <> None

let config ?(extra = []) ~agente_url ~motor_url () : Config.t =
  let base =
    [ ("DATABASE_URL", Option.value url_db ~default:"postgresql://x@localhost/x"); ("JWT_SECRET", "secreto-de-prueba-0123456789abcdef"); ("MOTOR_URL", motor_url);
      ("MOTOR_CLAVE", "clave-motor-prueba"); ("AGENTE_URL", agente_url); ("WEBHOOK_SECRET", "secreto-webhook-prueba"); ("EVOLUTION_MODO", "simulado");
      ("SALIDA_ESPACIADO_MS", "0"); ("PBKDF2_ITER", "1000"); ("MIGRAR", "0"); ("TRABAJADORES", "0"); ("BASE_URL_PUBLICA", "https://soporte.ejemplo.test/jsr");
      ("AGENTE_TIMEOUT_S", "5"); ("MOTOR_TIMEOUT_S", "5") ]
  in
  let todo = extra @ base in
  match Config.cargar ~getenv:(fun k -> List.assoc_opt k todo) with Ok c -> c | Error es -> failwith (String.concat "; " es)

(* Vacia todas las tablas de la base de PRUEBA. Se niega si el nombre de la base no termina en «test». *)
let limpiar (db : Db.t) : unit Lwt.t =
  (match url_db with
  | Some u when (let n = String.length u in n >= 4 && String.sub u (n - 4) 4 = "test") -> ()
  | _ -> failwith "limpiar: la base de prueba debe llamarse *test; no se toca otra");
  Db.usar db (fun c ->
      let* () =
        Db.exec c
          ("TRUNCATE configuracion, sedes, areas, personas, activos, categorias, grupos, tecnicos, grupo_miembros, habilidades, turnos, ausencias, guardias, "
         ^ "calendarios, feriados, matriz_prioridad, sla_politicas, incidencias, incidencia_eventos, escalamiento_reglas, escalamientos, casos, mensajes, decisiones, "
         ^ "articulos, articulo_usos, feedback, encuestas, pares_preferencia, etiquetas_revision, modelos, usuarios_consola, auditoria, outbox_analitica, avisos RESTART IDENTITY CASCADE")
          (`Assoc [])
      in
      Db.exec c "ALTER SEQUENCE incidencia_numero_seq RESTART WITH 1" (`Assoc []))

let sql c s = Db.exec c s (`Assoc [])

(* Datos de partida: tres tecnicos (Luis Paz y Marta Rojas activos, Sofia ausente), tres grupos, las diez categorias, un
   usuario de cada rol (clave «clave-de-prueba») y una persona. *)
let sembrar (db : Db.t) : unit Lwt.t =
  let hash = Cripto.hash_clave ~iteraciones:1000 "clave-de-prueba" in
  Db.usar db (fun c ->
      let* () = sql c "INSERT INTO sedes (nombre) VALUES ('Centro'), ('Norte')" in
      let* () = sql c "INSERT INTO areas (nombre) VALUES ('Contabilidad'), ('Ventas')" in
      let* () = sql c "INSERT INTO grupos (nombre, nivel) VALUES ('Mesa N1', 'N1'), ('Redes', 'N2'), ('Infraestructura', 'N3')" in
      let* () = sql c "UPDATE grupos SET escala_a_grupo_id = 3 WHERE id IN (1, 2)" in
      let* () =
        sql c
          "INSERT INTO tecnicos (nombre, whatsapp, correo, nivel, estado) VALUES ('Luis Paz', '51911111111', 'luis@ejemplo.test', 'N1', 'activo'), ('Marta Rojas', '51922222222', 'marta@ejemplo.test', 'N2', 'activo'), ('Sofía Díaz', NULL, 'sofia@ejemplo.test', 'N3', 'ausente')"
      in
      let* () = sql c "INSERT INTO grupo_miembros (grupo_id, tecnico_id) VALUES (1, 1), (2, 2), (3, 3)" in
      let* () = sql c "UPDATE grupos SET responsable_tecnico_id = 1 WHERE id = 1" in
      let* () =
        sql c
          "INSERT INTO categorias (clave, nombre, grupo_id) VALUES ('correo', 'Correo', 1), ('cuentas_accesos', 'Cuentas y accesos', 1), ('red_wifi', 'Red y wifi', 2), ('vpn', 'VPN', 2), ('impresoras', 'Impresoras', 1), ('equipo', 'Equipo', 1), ('software_oficina', 'Software de oficina', 1), ('sistema_interno', 'Sistema interno', 1), ('telefonia', 'Telefonía', 2), ('otro', 'Otro', 1)"
      in
      let* () = sql c "INSERT INTO calendarios (nombre, zona, veinticuatro_siete, horario) VALUES ('laboral_lima', 'America/Lima', false, '{\"1\":[[\"08:30\",\"18:00\"]]}'), ('24x7', 'America/Lima', true, '{}')" in
      let* () = sql c "INSERT INTO sla_politicas (prioridad, calendario_id, respuesta_min, resolucion_min) VALUES ('P1', 2, 15, 240), ('P2', 1, 30, 480), ('P3', 1, 120, 1440), ('P4', 1, 240, 2880)" in
      let* () =
        sql c
          "INSERT INTO matriz_prioridad (impacto, urgencia, prioridad) SELECT i, u, 'P3' FROM unnest(ARRAY['persona', 'area', 'sede', 'organizacion']) i, unnest(ARRAY['baja', 'media', 'alta', 'critica']) u"
      in
      let* () = sql c "INSERT INTO articulos (clave, titulo, categoria_id, pasos) VALUES ('KB-031', 'Outlook no sincroniza', 1, ARRAY['Cerrar Outlook', 'Cerrar sesión'])" in
      let* () =
        Db.exec c
          "INSERT INTO usuarios_consola (email, nombre, rol, tecnico_id, clave_hash) VALUES ('tecnico@ejemplo.test', 'Luis Paz', 'tecnico', 1, $h), ('supervisor@ejemplo.test', 'Marta Rojas', 'supervisor', 2, $h), ('gerencia@ejemplo.test', 'Gerencia', 'gerencia', NULL, $h), ('entrenador@ejemplo.test', 'Entrenadora', 'entrenador', NULL, $h), ('admin@ejemplo.test', 'Administrador', 'admin', NULL, $h)"
          (`Assoc [ ("h", `String hash) ])
      in
      sql c "INSERT INTO personas (nombre, whatsapp, correo, sede_id, area_id) VALUES ('Ana Ríos', '51987654321', 'ana@ejemplo.test', 1, 1)")

type entorno = {
  ctx : Ctx.t;
  db : Db.t;
  agente : Falsos.Agente_falso.t;
  motor : Falsos.Motor_falso.t;
  evolution : Falsos.Evolution_falso.t;
  servidores : Falsos.Servidor.t list;
}

(* Levanta la base limpia con datos semilla, el agente y el motor falsos, y el contexto. *)
let crear_entorno ?(extra = []) ?(sembrar_datos = true) () : entorno Lwt.t =
  let db = Db.conectar (Option.get url_db) in
  let* () = limpiar db in
  let* () = Migrar.aplicar ~plazo:5. db in
  let* () = if sembrar_datos then sembrar db else Lwt.return () in
  let agente = Falsos.Agente_falso.crear () in
  let motor = Falsos.Motor_falso.crear ~db ~clave:"clave-motor-prueba" in
  let evolution = Falsos.Evolution_falso.crear () in
  let sa = Falsos.Servidor.servir (Falsos.Agente_falso.handler agente) in
  let sm = Falsos.Servidor.servir (Falsos.Motor_falso.handler motor) in
  let se = Falsos.Servidor.servir (Falsos.Evolution_falso.handler evolution) in
  let cfg = config ~extra ~agente_url:(Falsos.Servidor.url sa) ~motor_url:(Falsos.Servidor.url sm) () in
  let ctx = Ctx.crear ~cfg ~db in
  (* Que los servidores ya escuchen antes de la primera llamada. *)
  let* () = Lwt_unix.sleep 0.15 in
  Lwt.return { ctx; db; agente; motor; evolution; servidores = [ sa; sm; se ] }

let cerrar_entorno (e : entorno) : unit Lwt.t =
  List.iter (fun (s : Falsos.Servidor.t) -> s.parar ()) e.servidores;
  Lwt.return ()

let con_entorno ?extra ?sembrar_datos (f : entorno -> unit Lwt.t) : unit Lwt.t =
  if not (requiere_db ()) then Lwt.return ()
  else
    let* e = crear_entorno ?extra ?sembrar_datos () in
    Lwt.finalize (fun () -> f e) (fun () -> cerrar_entorno e)

(* Consultas de verificacion. *)
let contar (db : Db.t) (sql : string) : int Lwt.t =
  let* f = Db.fila_p db ("SELECT count(*) AS n FROM (" ^ sql ^ ") x") (`Assoc []) in
  Lwt.return (Json.int_d "n" 0 f)

let fila (db : Db.t) sql params : Json.t Lwt.t = Db.fila_p db sql params
let lista (db : Db.t) sql params : Json.t list Lwt.t = Db.lista_p db sql params

(* Mensaje de WhatsApp en el formato de evolution-go. *)
let webhook_texto ?(id = "ABC123") ?(telefono = "51987654321") ?(de_mi = false) ?(grupo = false) ?(nombre = "Ana Ríos") (texto : string) : string =
  Json.to_string
    (`Assoc
      [ ("event", `String "Message");
        ( "data",
          `Assoc
            [ ( "Info",
                `Assoc
                  [ ("ID", `String id); ("Chat", `String (telefono ^ (if grupo then "@g.us" else "@s.whatsapp.net"))); ("Sender", `String (telefono ^ "@s.whatsapp.net"));
                    ("IsFromMe", `Bool de_mi); ("IsGroup", `Bool grupo); ("PushName", `String nombre) ] );
              ("Message", `Assoc [ ("conversation", `String texto) ]) ] ) ])

let entrante_whatsapp ?(id = "") ?(telefono = "51987654321") (texto : string) : Webhook.entrante =
  { Webhook.canal = "whatsapp"; chat_id = telefono; telefono = Some telefono; nombre = "Ana Ríos"; msg_id = (if id = "" then None else Some id); contenido = Webhook.Texto texto }

let reponer_ids = ref 0
let nuevo_id () = incr reponer_ids; Printf.sprintf "MSG%04d" !reponer_ids

(* Texto de los mensajes de un rol en un caso. *)
let textos_de (db : Db.t) ~(rol : string) : string list Lwt.t =
  let* l = lista db "SELECT texto FROM mensajes WHERE rol = $rol ORDER BY id" (`Assoc [ ("rol", `String rol) ]) in
  Lwt.return (List.map (Json.str_d "texto" "") l)


(* --- cliente HTTP contra la aplicacion real (Dream sobre un puerto local) --------------------------------------------------------- *)

type respuesta = { estado : int; cabeceras : (string * string) list; cuerpo : string; json : Json.t }

let servir_app (e : entorno) : Falsos.Servidor.t = Falsos.Servidor.servir (Rutas.aplicacion e.ctx)

let llamar ?token ?cuerpo ?(cabeceras = []) (srv : Falsos.Servidor.t) (metodo : Cohttp.Code.meth) (ruta : string) : respuesta Lwt.t =
  let cab = (match token with Some t -> [ ("Authorization", "Bearer " ^ t) ] | None -> []) @ (if cuerpo <> None then [ ("Content-Type", "application/json") ] else []) @ cabeceras in
  let* r = Http.pedir_completo ~cabeceras:cab ?cuerpo:(Option.map Json.to_string cuerpo) ~plazo:15. metodo (Falsos.Servidor.url srv ^ ruta) in
  match r with
  | Error f -> failwith ("la llamada " ^ ruta ^ " fallo: " ^ Http.describir f)
  | Ok (estado, cabeceras, cuerpo) ->
      Lwt.return { estado; cabeceras = List.map (fun (k, v) -> (String.lowercase_ascii k, v)) cabeceras; cuerpo; json = (match Json.parse cuerpo with Ok j -> j | Error _ -> `Null) }

(* Inicia sesion como uno de los usuarios semilla y devuelve el token. *)
let token_de (srv : Falsos.Servidor.t) (rol : string) : string Lwt.t =
  let* r = llamar srv `POST "/api/auth/login" ~cuerpo:(`Assoc [ ("email", `String (rol ^ "@ejemplo.test")); ("clave", `String "clave-de-prueba") ]) in
  if r.estado <> 200 then failwith (Printf.sprintf "login de %s fallo (%d): %s" rol r.estado r.cuerpo) else Lwt.return (Json.str_d "token" "" r.json)

let esperar_reposo (e : entorno) : unit Lwt.t =
  let* _ = Ctx.esperar_tareas ~plazo:10. e.ctx in
  let* _ = Cola_salida.esperar_reposo ~plazo:10. e.ctx.salida in
  Lwt.return ()
