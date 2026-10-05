(* Pruebas de integracion: Postgres real (JSR_TEST_DB), agente y motor falsos como servidores Dream de verdad. Se saltan
   si no hay base de prueba. Cada prueba parte de una base limpia con datos semilla (Ayuda.sembrar). *)

open Pasarela

let ( let* ) = Lwt.bind

let contiene sub s = Falsos.Agente_falso.contiene sub s
let check_contiene msg sub s = Alcotest.(check bool) (msg ^ " (contiene «" ^ sub ^ "» en «" ^ s ^ "»)") true (contiene sub s)
let check_no_contiene msg sub s = Alcotest.(check bool) (msg ^ " (no debe contener «" ^ sub ^ "»)") false (contiene sub s)
let todos textos = String.concat "\n" textos

let enviar (e : Ayuda.entorno) ?(telefono = "51987654321") texto =
  Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) ~telefono texto)

(* --- caso nuevo -> incidencia: texto fijo con numero, tecnico y plazo ------------------------------------------------- *)

let test_caso_a_incidencia _ () =
  Ayuda.con_entorno (fun e ->
      let* r1 = enviar e "no me abre el correo" in
      check_contiene "pregunta de diagnostico" "¿En qué equipo" (todos r1.textos);
      let* r2 = enviar e "mi correo, desde hoy en PC-CONT-07" in
      check_contiene "guia" "Cierra Outlook" (todos r2.textos);
      let* r3 = enviar e "sigue igual" in
      let t = todos r3.textos in
      check_contiene "numero de incidencia" "INC-000001" t;
      check_contiene "tecnico" "Luis Paz" t;
      check_contiene "plazo de primera respuesta" "te responderá antes de" t;
      check_contiene "plazo de resolucion" "Plazo de resolución" t;
      check_contiene "prioridad" "(prioridad P3)" t;
      check_contiene "enlace publico" "https://soporte.ejemplo.test/jsr/estado/" t;
      check_contiene "frase previa del agente" "Voy a registrarlo" t;
      Alcotest.(check (option string)) "numero en el resultado" (Some "INC-000001") r3.incidencia;
      (* Base de datos. *)
      let* inc = Ayuda.fila e.db "SELECT id, caso_id, persona_id, estado, canal, categoria_id FROM incidencias" (`Assoc []) in
      Alcotest.(check (option int)) "caso de la incidencia" r3.caso_id (Json.int "caso_id" inc);
      Alcotest.(check string) "estado" "asignada" (Json.str_d "estado" "" inc);
      Alcotest.(check string) "canal" "whatsapp" (Json.str_d "canal" "" inc);
      let* caso = Ayuda.fila e.db "SELECT estado, etapa, pausado_por_tecnico FROM casos" (`Assoc []) in
      Alcotest.(check string) "caso con incidencia" "con_incidencia" (Json.str_d "estado" "" caso);
      (* La persona se resolvio por su numero de WhatsApp, sin duplicarse. *)
      let* n_personas = Ayuda.contar e.db "SELECT 1 FROM personas WHERE whatsapp = '51987654321'" in
      Alcotest.(check int) "una sola persona" 1 n_personas;
      (* Lo que se envio por WhatsApp (simulado), en orden. *)
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      let enviados = Evolution.simulados e.ctx.evolution in
      Alcotest.(check bool) "todo a la misma persona" true (List.for_all (fun (d, _) -> d = "51987654321") enviados);
      Alcotest.(check bool) "el ultimo mensaje es el texto fijo" true (match List.rev enviados with (_, t) :: _ -> contiene "INC-000001" t | [] -> false);
      (* El agente recibio el contrato §1. *)
      let ultima = List.hd e.agente.recibidas in
      List.iter
        (fun k -> Alcotest.(check bool) ("peticion al agente trae " ^ k) true (Json.get k ultima <> `Null))
        [ "caso_id"; "canal"; "mensaje"; "historial"; "etapa"; "memoria"; "perfil"; "incidencias_abiertas"; "ahora" ];
      Alcotest.(check string) "canal" "whatsapp" (Json.str_d "canal" "" ultima);
      Alcotest.(check bool) "ahora en ISO UTC" true (let a = Json.str_d "ahora" "" ultima in String.length a = 20 && a.[19] = 'Z');
      let perfil = Json.obj "perfil" ultima in
      Alcotest.(check string) "perfil.nombre" "Ana Ríos" (Json.str_d "nombre" "" perfil);
      Alcotest.(check string) "perfil.sede" "Centro" (Json.str_d "sede" "" perfil);
      Alcotest.(check string) "perfil.area" "Contabilidad" (Json.str_d "area" "" perfil);
      Alcotest.(check bool) "historial con roles del contrato" true
        (List.for_all (fun h -> List.mem (Json.str_d "rol" "" h) [ "usuario"; "asistente"; "tecnico" ]) (Json.list "historial" ultima));
      Alcotest.(check bool) "el historial no repite el mensaje actual" true
        (not (List.exists (fun h -> Json.str_d "texto" "" h = "sigue igual") (Json.list "historial" ultima)));
      Lwt.return ())

(* --- incidencia duplicada: se agrega el dato, no se abre otra --------------------------------------------------------------------- *)

let test_duplicada _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* r3 = enviar e "sigue igual" in
      check_contiene "primera incidencia" "INC-000001" (todos r3.textos);
      (* Una persona escribe de nuevo por el mismo tema (otra sesion): el agente vuelve a proponer crear. *)
      e.agente.responder <-
        (fun _ ->
          ( 200,
            Falsos.Agente_falso.base ~respuesta:(Some "Voy a registrarlo.") ~etapa:"incidencia" ~memoria:(`Assoc []) ~intencion:"reportar_falla" ~confianza:0.9 ~categoria:"correo"
              ~accion:(`Assoc [ ("tipo", `String "crear_incidencia"); ("incidencia", `Assoc [ ("categoria", `String "correo"); ("titulo", `String "Otra vez el correo"); ("resumen", `String "Sigue sin llegar."); ("motivo", `String "guia_agotada") ]) ])
              () ));
      let* r4 = enviar e "el correo no llega otra vez" in
      let t = todos r4.textos in
      check_contiene "avisa que ya existe" "Ya tienes abierta la incidencia INC-000001" t;
      check_contiene "dice que agrego lo contado" "agregué lo que me contaste" t;
      let* n = Ayuda.contar e.db "SELECT 1 FROM incidencias" in
      Alcotest.(check int) "sigue habiendo una sola incidencia" 1 n;
      let* datos = Ayuda.contar e.db "SELECT 1 FROM incidencia_eventos WHERE tipo = 'dato_agregado'" in
      Alcotest.(check int) "un dato agregado" 1 datos;
      (* Y el agente vio la incidencia abierta en su peticion. *)
      let ultima = List.hd e.agente.recibidas in
      (match Json.list "incidencias_abiertas" ultima with
      | [ i ] ->
          Alcotest.(check string) "numero" "INC-000001" (Json.str_d "numero" "" i);
          Alcotest.(check string) "tecnico" "Luis Paz" (Json.str_d "tecnico" "" i);
          Alcotest.(check string) "categoria" "correo" (Json.str_d "categoria" "" i)
      | l -> Alcotest.failf "se esperaba 1 incidencia abierta y llegaron %d" (List.length l));
      Lwt.return ())

(* --- sesion de 6 horas ------------------------------------------------------------------------------------------------------------- *)

let test_sesion_6h _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "hola" in
      let* _ = enviar e "no me abre el correo" in
      let* n = Ayuda.contar e.db "SELECT 1 FROM casos" in
      Alcotest.(check int) "una sesion" 1 n;
      (* Hace 5 h: sigue la misma sesion. *)
      let* () = Db.exec_p e.db "UPDATE casos SET ultimo_mensaje = now() - interval '5 hours'" (`Assoc []) in
      let* _ = enviar e "mi correo, desde hoy" in
      let* n = Ayuda.contar e.db "SELECT 1 FROM casos" in
      Alcotest.(check int) "5 h: misma sesion" 1 n;
      (* Hace 7 h: sesion nueva, sin la etapa ni la ficha de la anterior. *)
      let* () = Db.exec_p e.db "UPDATE casos SET ultimo_mensaje = now() - interval '7 hours'" (`Assoc []) in
      let* r = enviar e "hola" in
      let* n = Ayuda.contar e.db "SELECT 1 FROM casos" in
      Alcotest.(check int) "7 h: sesion nueva" 2 n;
      let ultima = List.hd e.agente.recibidas in
      Alcotest.(check string) "etapa de caso nuevo" "recepcion" (Json.str_d "etapa" "" ultima);
      Alcotest.(check (list string)) "sin historial" [] (List.map (Json.str_d "texto" "") (Json.list "historial" ultima));
      Alcotest.(check bool) "memoria vacia" true (Json.obj "memoria" ultima = `Assoc []);
      ignore r;
      Lwt.return ())

(* --- pausa por tecnico: el asistente no responde; el mensaje llega a la incidencia ------------------------------------------ *)

let test_pausa_por_tecnico _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* r3 = enviar e "sigue igual" in
      check_contiene "incidencia" "INC-000001" (todos r3.textos);
      let caso_id = Option.get r3.caso_id in
      let* () = Db.exec_p e.db "UPDATE casos SET pausado_por_tecnico = true WHERE id = $i:id" (`Assoc [ ("id", `Int caso_id) ]) in
      let antes = List.length e.agente.recibidas in
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* r = enviar e "¿alguien me puede ayudar?" in
      Alcotest.(check (list string)) "el asistente no responde" [] r.textos;
      Alcotest.(check bool) "marcado como pausado" true r.pausado;
      Alcotest.(check int) "no se llamo al agente" antes (List.length e.agente.recibidas);
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Alcotest.(check int) "no se envio nada por WhatsApp" 0 (List.length (Evolution.simulados e.ctx.evolution));
      (* El mensaje quedo en el caso y llego a la incidencia como comentario de la persona. *)
      let* m = Ayuda.fila e.db "SELECT texto, rol FROM mensajes WHERE caso_id = $i:c ORDER BY id DESC LIMIT 1" (`Assoc [ ("c", `Int caso_id) ]) in
      Alcotest.(check string) "texto guardado" "¿alguien me puede ayudar?" (Json.str_d "texto" "" m);
      Alcotest.(check string) "rol" "usuario" (Json.str_d "rol" "" m);
      let* ev = Ayuda.fila e.db "SELECT actor_tipo, datos FROM incidencia_eventos WHERE tipo = 'comentario' LIMIT 1" (`Assoc []) in
      Alcotest.(check string) "actor del comentario" "usuario" (Json.str_d "actor_tipo" "" ev);
      Alcotest.(check string) "texto del comentario" "¿alguien me puede ayudar?" (Json.str_d "texto" "" (Json.get "datos" ev));
      Lwt.return ())

(* --- agente caido: cortesia + derivacion ------------------------------------------------------------------------------------------- *)

let test_agente_caido _ () =
  Ayuda.con_entorno (fun e ->
      (* Un puerto donde no escucha nadie: conexion rechazada, dos intentos. *)
      let ctx = { e.ctx with agente = Agente.crear ~url:"http://127.0.0.1:1" ~plazo:1.0 } in
      let t0 = Unix.gettimeofday () in
      let* r = Flujo.procesar ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "no me abre el correo, mi contraseña es Abc12345") in
      let dt = Unix.gettimeofday () -. t0 in
      Alcotest.(check bool) "reintento una vez antes de rendirse (espera de 0,4 s)" true (dt >= 0.35);
      let t = todos r.textos in
      check_contiene "cortesia" "problema técnico" t;
      check_contiene "derivacion con numero" "INC-000001" t;
      Alcotest.(check bool) "marcado como derivado" true r.derivado;
      (* La incidencia se abrio con lo que dijo la persona, sin la contraseña. *)
      let* inc = Ayuda.fila e.db "SELECT titulo, resumen FROM incidencias" (`Assoc []) in
      check_no_contiene "la contraseña no llega a la incidencia" "Abc12345" (Json.str_d "resumen" "" inc);
      let* m = Ayuda.textos_de e.db ~rol:"usuario" in
      List.iter (check_no_contiene "la contraseña no se guarda" "Abc12345") m;
      check_contiene "se guardo oculta" "[oculto]" (todos m);
      let* d = Ayuda.contar e.db "SELECT 1 FROM decisiones WHERE componente = 'agente'" in
      Alcotest.(check int) "decision registrada" 1 d;
      (* Un segundo mensaje con el agente aun caido se agrega a la misma incidencia, no abre otra. *)
      let* r2 = Flujo.procesar ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "¿hay novedades?") in
      check_contiene "se agrega a la abierta" "Lo agregué a tu incidencia abierta INC-000001" (todos r2.textos);
      let* n = Ayuda.contar e.db "SELECT 1 FROM incidencias" in
      Alcotest.(check int) "sigue habiendo una" 1 n;
      Lwt.return ())

let test_agente_caido_y_motor_caido _ () =
  Ayuda.con_entorno (fun e ->
      let ctx = { e.ctx with agente = Agente.crear ~url:"http://127.0.0.1:1" ~plazo:1.0 } in
      e.motor.caido <- true;
      let* r = Flujo.procesar ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "hola") in
      let t = todos r.textos in
      check_contiene "cortesia honesta" "problema técnico" t;
      check_no_contiene "no finge haber abierto una incidencia" "INC-" t;
      Lwt.return ())

(* --- el motor no responde al crear: no se finge --------------------------------------------------------------------------------------- *)

let test_motor_caido_al_crear _ () =
  Ayuda.con_entorno (fun e ->
      e.agente.responder <-
        (fun _ ->
          ( 200,
            Falsos.Agente_falso.base ~respuesta:(Some "Voy a registrarlo.") ~etapa:"incidencia" ~memoria:(`Assoc []) ~intencion:"reportar_falla" ~confianza:0.9 ~categoria:"vpn"
              ~accion:(`Assoc [ ("tipo", `String "crear_incidencia"); ("incidencia", `Assoc [ ("categoria", `String "vpn"); ("titulo", `String "VPN caída"); ("motivo", `String "sin_articulo") ]) ])
              () ));
      e.motor.caido <- true;
      let* r = enviar e "la vpn no conecta" in
      let t = todos r.textos in
      check_contiene "dice que no pudo" "No pude registrar tu incidencia" t;
      check_no_contiene "no promete lo que no hizo" "Voy a registrarlo" t;
      check_no_contiene "ni inventa un numero" "INC-" t;
      let* n = Ayuda.contar e.db "SELECT 1 FROM incidencias" in
      Alcotest.(check int) "no hay incidencia" 0 n;
      Lwt.return ())

(* --- sin tecnico: «cola» --------------------------------------------------------------------------------------------------------------- *)

let test_en_cola _ () =
  Ayuda.con_entorno (fun e ->
      e.motor.sin_tecnicos <- true;
      e.agente.responder <-
        (fun _ ->
          ( 200,
            Falsos.Agente_falso.base ~respuesta:None ~etapa:"incidencia" ~memoria:(`Assoc []) ~intencion:"reportar_falla" ~confianza:0.9 ~categoria:"vpn"
              ~accion:(`Assoc [ ("tipo", `String "crear_incidencia"); ("incidencia", `Assoc [ ("categoria", `String "vpn"); ("titulo", `String "VPN caída"); ("motivo", `String "sin_articulo") ]) ])
              () ));
      let* r = enviar e "la vpn no conecta" in
      let t = todos r.textos in
      check_contiene "numero" "INC-000001" t;
      check_contiene "cola del grupo" "Quedó en la cola de Redes" t;
      check_no_contiene "sin tecnico no hay «La atiende»" "La atiende" t;
      Lwt.return ())

(* --- privacidad: contraseñas ----------------------------------------------------------------------------------------------------------------- *)

let test_contrasena_oculta _ () =
  Ayuda.con_entorno (fun e ->
      let* r = enviar e "mi contraseña es Abc12345 y no entro" in
      check_contiene "el agente aviso" "ya la oculté" (todos r.textos);
      let* m = Ayuda.textos_de e.db ~rol:"usuario" in
      List.iter (check_no_contiene "la contraseña no se guarda" "Abc12345") m;
      check_contiene "se guardo oculta" "[oculto]" (todos m);
      (* Y tampoco en la cola de analitica. *)
      let* filas = Ayuda.lista e.db "SELECT payload::text AS p FROM outbox_analitica" (`Assoc []) in
      List.iter (fun f -> check_no_contiene "analitica sin contraseña" "Abc12345" (Json.str_d "p" "" f)) filas;
      Lwt.return ())

(* --- analitica: formato exacto de CONTRATOS §4 ------------------------------------------------------------------------------------------------- *)

let claves_de = function `Assoc l -> List.sort compare (List.map fst l) | _ -> []

let test_outbox_analitica _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* _ = enviar e "sigue igual" in
      let* _ = enviar e "Sí, se resolvió" in
      let* _ = enviar e "5" in
      let* filas = Ayuda.lista e.db "SELECT tabla, clave, payload FROM outbox_analitica ORDER BY id" (`Assoc []) in
      let de tabla = List.filter (fun f -> Json.str_d "tabla" "" f = tabla) filas in
      let esperadas_msg = List.sort compare [ "id"; "caso_id"; "ts"; "rol"; "canal"; "intencion"; "confianza"; "categoria"; "juez_modo"; "juez_veredicto"; "latencia_ms"; "regenerada"; "frases_quitadas"; "costo_usd"; "texto" ] in
      let msgs = de "mensajes" in
      Alcotest.(check bool) "hay mensajes encolados" true (List.length msgs >= 8);
      List.iter
        (fun f ->
          let p = Json.get "payload" f in
          Alcotest.(check (list string)) "columnas de mensajes" esperadas_msg (claves_de p);
          Alcotest.(check string) "clave" ("msg-" ^ string_of_int (Json.int_d "id" 0 p)) (Json.str_d "clave" "" f);
          Alcotest.(check string) "texto vacio sin ANALITICA_TEXTO" "" (Json.str_d "texto" "" p);
          Alcotest.(check bool) "ts ISO UTC con milisegundos" true (let ts = Json.str_d "ts" "" p in String.length ts = 24 && ts.[23] = 'Z' && ts.[10] = 'T'))
        msgs;
      let usuario = List.find (fun f -> Json.str_d "rol" "" (Json.get "payload" f) = "usuario") msgs |> Json.get "payload" in
      Alcotest.(check string) "intencion del usuario" "reportar_falla" (Json.str_d "intencion" "" usuario);
      Alcotest.(check string) "categoria" "correo" (Json.str_d "categoria" "" usuario);
      Alcotest.(check string) "juez_modo" "sombra" (Json.str_d "juez_modo" "" usuario);
      let asistente = List.find (fun f -> Json.str_d "rol" "" (Json.get "payload" f) = "asistente") msgs |> Json.get "payload" in
      Alcotest.(check int) "latencia" 420 (Json.int_d "latencia_ms" 0 asistente);
      Alcotest.(check bool) "costo" true (Json.float_opt (Json.get "costo_usd" asistente) = Some 0.0012);
      (* casos_estado *)
      let casos = de "casos_estado" in
      Alcotest.(check bool) "hay casos_estado" true (casos <> []);
      List.iter
        (fun f ->
          let p = Json.get "payload" f in
          Alcotest.(check (list string)) "columnas de casos_estado"
            (List.sort compare [ "caso_id"; "version"; "canal"; "persona_id"; "estado"; "inicio"; "ultimo_mensaje"; "tiene_incidencia"; "confirmado_resuelto" ])
            (claves_de p);
          Alcotest.(check string) "clave" (Printf.sprintf "caso-%d-%d" (Json.int_d "caso_id" 0 p) (Json.int_d "version" 0 p)) (Json.str_d "clave" "" f))
        casos;
      (* encuestas: al ENVIARLA va con puntaje null; al responder se reencola la MISMA enc-<id> con el puntaje (ts = envio). *)
      (match de "encuestas" with
      | [ f1; f2 ] ->
          let p1 = Json.get "payload" f1 and p2 = Json.get "payload" f2 in
          Alcotest.(check (list string)) "columnas de encuestas" (List.sort compare [ "id"; "incidencia_id"; "caso_id"; "ts"; "puntaje" ]) (claves_de p1);
          Alcotest.(check bool) "enviada sin responder: puntaje null" true (Json.get "puntaje" p1 = `Null);
          Alcotest.(check int) "respondida: puntaje" 5 (Json.int_d "puntaje" 0 p2);
          Alcotest.(check string) "misma clave" "enc-1" (Json.str_d "clave" "" f1);
          Alcotest.(check string) "misma clave al responder" "enc-1" (Json.str_d "clave" "" f2);
          Alcotest.(check string) "ts = momento del envio" (Json.str_d "ts" "" p1) (Json.str_d "ts" "" p2)
      | l -> Alcotest.failf "se esperaban 2 filas de encuesta (envio y respuesta) y hay %d" (List.length l));
      let* n_enc = Ayuda.contar e.db "SELECT 1 FROM encuestas" in
      Alcotest.(check int) "una sola fila en Postgres" 1 n_enc;
      let fbs = de "feedback" in
      Alcotest.(check bool) "hay feedback" true (fbs <> []);
      List.iter
        (fun f ->
          Alcotest.(check (list string)) "columnas de feedback" (List.sort compare [ "id"; "caso_id"; "mensaje_id"; "incidencia_id"; "ts"; "senal"; "valor" ]) (claves_de (Json.get "payload" f)))
        fbs;
      let se_resolvio = List.find (fun f -> Json.str_d "senal" "" (Json.get "payload" f) = "se_resolvio") fbs |> Json.get "payload" in
      Alcotest.(check bool) "el feedback lleva mensaje_id" true (Json.int "mensaje_id" se_resolvio <> None);
      (* El motor es el unico que escribe las tablas de incidencias en el outbox: la pasarela no. *)
      Alcotest.(check int) "la pasarela no encola tablas del motor" 0 (List.length (de "eventos_incidencia") + List.length (de "incidencias_estado") + List.length (de "incidencias_tiempos"));
      Lwt.return ())

(* --- contencion: «si, se resolvio» sin incidencia -------------------------------------------------------------------------------------------------- *)

let test_contencion _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* _ = enviar e "Sí, se resolvió" in
      let* _ = enviar e "4" in
      let* caso = Ayuda.fila e.db "SELECT estado FROM casos" (`Assoc []) in
      Alcotest.(check string) "el caso sigue siendo del asistente tras la encuesta" "resuelto_asistente" (Json.str_d "estado" "" caso);
      let* ultimo = Ayuda.fila e.db "SELECT payload FROM outbox_analitica WHERE tabla = 'casos_estado' ORDER BY id DESC LIMIT 1" (`Assoc []) in
      let p = Json.get "payload" ultimo in
      Alcotest.(check string) "casos_estado.estado" "resuelto_asistente" (Json.str_d "estado" "" p);
      Alcotest.(check int) "confirmado_resuelto" 1 (Json.int_d "confirmado_resuelto" 0 p);
      Alcotest.(check int) "tiene_incidencia" 0 (Json.int_d "tiene_incidencia" 1 p);
      let* fb = Ayuda.fila e.db "SELECT f.mensaje_id, m.texto FROM feedback f JOIN mensajes m ON m.id = f.mensaje_id WHERE f.senal = 'se_resolvio'" (`Assoc []) in
      Alcotest.(check string) "el feedback apunta al mensaje de la persona" "Sí, se resolvió" (Json.str_d "texto" "" fb);
      Lwt.return ())

let test_outbox_con_texto _ () =
  Ayuda.con_entorno ~extra:[ ("ANALITICA_TEXTO", "1") ] (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* filas = Ayuda.lista e.db "SELECT payload FROM outbox_analitica WHERE tabla = 'mensajes' AND payload->>'rol' = 'usuario'" (`Assoc []) in
      (match filas with
      | f :: _ -> Alcotest.(check string) "con ANALITICA_TEXTO=1 viaja el texto" "no me abre el correo" (Json.str_d "texto" "" (Json.get "payload" f))
      | [] -> Alcotest.fail "no hay mensajes");
      Lwt.return ())

(* --- encuesta, confirmacion y reapertura ------------------------------------------------------------------------------------------------------- *)

let test_resolver_confirmar_encuesta _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* _ = enviar e "sigue igual" in
      (* El tecnico resuelve (a traves del motor falso). *)
      let* _ =
        Motor.accion e.ctx.motor ~id:1 (`Assoc [ ("accion", `String "resolver"); ("actor", Motor.actor ~id:"1" "tecnico"); ("solucion", `String "Se reconfiguró el perfil") ])
      in
      let* r = enviar e "Sí, se resolvió" in
      let t = todos r.textos in
      check_contiene "cierra la incidencia" "cerré tu incidencia INC-000001" t;
      let* inc = Ayuda.fila e.db "SELECT estado, motivo_cierre FROM incidencias" (`Assoc []) in
      Alcotest.(check string) "cerrada" "cerrada" (Json.str_d "estado" "" inc);
      let* r2 = enviar e "4" in
      check_contiene "gracias por la nota" "Gracias por tu calificación" (todos r2.textos);
      let* enc = Ayuda.fila e.db "SELECT incidencia_id, caso_id, puntaje FROM encuestas" (`Assoc []) in
      Alcotest.(check int) "puntaje" 4 (Json.int_d "puntaje" 0 enc);
      Alcotest.(check (option int)) "incidencia de la encuesta" (Some 1) (Json.int "incidencia_id" enc);
      let* caso = Ayuda.fila e.db "SELECT estado FROM casos" (`Assoc []) in
      Alcotest.(check string) "caso cerrado" "cerrado" (Json.str_d "estado" "" caso);
      let* fb = Ayuda.contar e.db "SELECT 1 FROM feedback WHERE senal = 'se_resolvio'" in
      Alcotest.(check int) "feedback se_resolvio" 1 fb;
      let* usos = Ayuda.contar e.db "SELECT 1 FROM articulo_usos WHERE resultado = 'resolvio'" in
      Alcotest.(check int) "uso del articulo" 1 usos;
      Lwt.return ())

let test_sigue_igual_reabre _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* _ = enviar e "sigue igual" in
      let* _ = Motor.accion e.ctx.motor ~id:1 (`Assoc [ ("accion", `String "resolver"); ("actor", Motor.actor ~id:"1" "tecnico") ]) in
      (* Con la incidencia resuelta, «sigue igual» la reabre. *)
      e.agente.responder <-
        (fun _ -> (200, Falsos.Agente_falso.base ~respuesta:None ~etapa:"seguimiento" ~memoria:(`Assoc []) ~intencion:"sigue_igual" ~confianza:0.95 ~accion:(`Assoc [ ("tipo", `String "sigue_igual") ]) ()));
      let* r = enviar e "sigue igual, no funciona" in
      check_contiene "reabrio" "Reabrí tu incidencia INC-000001" (todos r.textos);
      let* inc = Ayuda.fila e.db "SELECT estado, reaperturas FROM incidencias" (`Assoc []) in
      Alcotest.(check string) "reabierta" "reabierta" (Json.str_d "estado" "" inc);
      Alcotest.(check int) "reaperturas" 1 (Json.int_d "reaperturas" 0 inc);
      let* fb = Ayuda.contar e.db "SELECT 1 FROM feedback WHERE senal = 'reapertura'" in
      Alcotest.(check int) "feedback de reapertura" 1 fb;
      Lwt.return ())

(* --- consultar estado: flujo fijo con datos reales ------------------------------------------------------------------------------------------------ *)

let test_consultar_estado _ () =
  Ayuda.con_entorno (fun e ->
      let* r0 = enviar e "¿cómo va mi ticket?" in
      check_contiene "sin incidencias" "No veo incidencias abiertas" (todos r0.textos);
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* _ = enviar e "sigue igual" in
      let* r = enviar e "¿cómo va mi ticket?" in
      let t = todos r.textos in
      check_contiene "numero" "INC-000001" t;
      check_contiene "titulo" "Outlook no recibe correos" t;
      check_contiene "estado" "Asignada" t;
      check_contiene "tecnico" "Luis Paz" t;
      check_contiene "plazo" "Plazo de resolución" t;
      Lwt.return ())

(* --- pedir tecnico ------------------------------------------------------------------------------------------------------------------------------- *)

let test_pedir_tecnico _ () =
  Ayuda.con_entorno (fun e ->
      let* r = enviar e "quiero hablar con un técnico" in
      let t = todos r.textos in
      check_contiene "abre incidencia" "INC-000001" t;
      let* ev = Ayuda.fila e.db "SELECT datos FROM incidencia_eventos WHERE tipo = 'creada'" (`Assoc []) in
      Alcotest.(check string) "motivo pidio_tecnico" "pidio_tecnico" (Json.str_d "motivo" "" (Json.get "datos" ev));
      (* Con la incidencia abierta, pedir un tecnico avisa a quien la atiende. *)
      let* r2 = enviar e "quiero hablar con un técnico de verdad" in
      check_contiene "avisa" "Ya avisé a quien atiende tu incidencia INC-000001" (todos r2.textos);
      let* n = Ayuda.contar e.db "SELECT 1 FROM incidencias" in
      Alcotest.(check int) "no abre otra" 1 n;
      Lwt.return ())

(* --- decisiones (capa de juicio en sombra) y veredictos de Jev local ---------------------------------------------------------------------------------- *)

let test_decisiones _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* d = Ayuda.fila e.db "SELECT componente, modo, entrada, salida FROM decisiones WHERE componente = 'asistente' ORDER BY id LIMIT 1" (`Assoc []) in
      Alcotest.(check string) "modo sombra" "sombra" (Json.str_d "modo" "" d);
      let s = Json.get "salida" d in
      Alcotest.(check string) "accion decidida" "ninguna" (Json.str_d "accion" "" s);
      Alcotest.(check string) "intencion" "reportar_falla" (Json.str_d "intencion" "" s);
      Alcotest.(check string) "juicio" "bajo" (Json.str_d "riesgo" "" (Json.get "juicio" s));
      let* j = Ayuda.fila e.db "SELECT modo, salida FROM decisiones WHERE componente = 'juez' LIMIT 1" (`Assoc []) in
      Alcotest.(check string) "veredicto del juez" "respaldada" (Json.str_d "veredicto" "" (Json.get "salida" j));
      Lwt.return ())

let test_juicio_marca_numero_en_texto_libre _ () =
  Ayuda.con_entorno (fun e ->
      e.agente.responder <-
        (fun _ -> (200, Falsos.Agente_falso.base ~respuesta:(Some "Ya registré INC-000099, te atienden en 10 minutos.") ~etapa:"recepcion" ~memoria:(`Assoc []) ~intencion:"saludo" ~confianza:0.9 ()));
      let* _ = enviar e "hola" in
      let* d = Ayuda.fila e.db "SELECT salida FROM decisiones WHERE componente = 'asistente'" (`Assoc []) in
      let j = Json.get "juicio" (Json.get "salida" d) in
      Alcotest.(check string) "riesgo medio" "medio" (Json.str_d "riesgo" "" j);
      check_contiene "motivo" "numero de incidencia o un plazo" (Json.str_d "motivo" "" j);
      Lwt.return ())

(* --- mensajes que no son texto ------------------------------------------------------------------------------------------------------------------------------ *)

let test_no_texto _ () =
  Ayuda.con_entorno (fun e ->
      let ent = { (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "") with Webhook.contenido = Webhook.No_texto "audio" } in
      let* r = Flujo.procesar e.ctx ent in
      check_contiene "aviso amable" "no puedo leer los audios" (todos r.textos);
      Alcotest.(check int) "no se llamo al agente" 0 (List.length e.agente.recibidas);
      let* m = Ayuda.textos_de e.db ~rol:"usuario" in
      Alcotest.(check (list string)) "queda constancia" [ "[audio recibido]" ] m;
      Lwt.return ())

(* --- chat web ------------------------------------------------------------------------------------------------------------------------------------------------------- *)

let test_chat_web _ () =
  Ayuda.con_entorno (fun e ->
      let* r = Flujo.procesar_web e.ctx ~sesion:"sesion-prueba-1" ~mensaje:"no me abre el correo" in
      Alcotest.(check bool) "responde" true (r.textos <> []);
      let* caso = Ayuda.fila e.db "SELECT canal, chat_id, persona_id FROM casos" (`Assoc []) in
      Alcotest.(check string) "canal web" "web" (Json.str_d "canal" "" caso);
      Alcotest.(check string) "chat_id es la sesion" "sesion-prueba-1" (Json.str_d "chat_id" "" caso);
      let* p = Ayuda.fila e.db "SELECT nombre, whatsapp FROM personas WHERE id = $i:id" (`Assoc [ ("id", Json.get "persona_id" caso) ]) in
      Alcotest.(check bool) "visitante web sin whatsapp" true (Json.get "whatsapp" p = `Null && contiene "Visitante web" (Json.str_d "nombre" "" p));
      (* Nada se manda por WhatsApp desde el chat web. *)
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Alcotest.(check int) "sin envios" 0 (List.length (Evolution.simulados e.ctx.evolution));
      let a = r.analisis in
      Alcotest.(check string) "etapa en el analisis" "diagnostico" (Json.str_d "etapa" "" a);
      Alcotest.(check string) "intencion" "reportar_falla" (Json.str_d "intencion" "" a);
      Lwt.return ())

(* --- orden y espaciado de la cola de salida -------------------------------------------------------------------------------------------------------------------------- *)

let test_cola_salida_en_orden _ () =
  let recibidos = ref [] in
  let enviar ~destino ~texto = recibidos := (destino, texto, Unix.gettimeofday ()) :: !recibidos; Lwt.return (Evolution.Enviado "x") in
  let perdidos = ref [] in
  let cola = Cola_salida.crear ~espaciado_ms:120 ~enviar ~sobre_perdido:(fun ~destino ~largo ~motivo -> perdidos := (destino, largo, motivo) :: !perdidos; Lwt.return ()) in
  ignore (Cola_salida.encolar cola ~destino:"a" [ "a1"; "a2"; "a3" ]);
  ignore (Cola_salida.encolar cola ~destino:"b" [ "b1" ]);
  let* ok = Cola_salida.esperar_reposo ~plazo:5. cola in
  Alcotest.(check bool) "se vacio" true ok;
  let orden destino = !recibidos |> List.rev |> List.filter (fun (d, _, _) -> d = destino) |> List.map (fun (_, t, _) -> t) in
  Alcotest.(check (list string)) "orden en a" [ "a1"; "a2"; "a3" ] (orden "a");
  Alcotest.(check (list string)) "orden en b" [ "b1" ] (orden "b");
  let tiempos = !recibidos |> List.rev |> List.filter (fun (d, _, _) -> d = "a") |> List.map (fun (_, _, t) -> t) in
  (match tiempos with
  | [ t1; t2; t3 ] -> Alcotest.(check bool) "espaciado de ~120 ms entre mensajes del mismo chat" true (t2 -. t1 >= 0.1 && t3 -. t2 >= 0.1)
  | _ -> Alcotest.fail "faltan mensajes");
  (* b no esperó a a: salio casi al instante. *)
  Alcotest.(check int) "nada perdido" 0 (List.length !perdidos);
  Lwt.return ()

let test_cola_salida_reintenta_y_pierde _ () =
  let intentos = ref 0 in
  let enviar ~destino:_ ~texto:_ = incr intentos; Lwt.return (Evolution.Fallo "caido") in
  let perdidos = ref [] in
  let cola = Cola_salida.crear ~espaciado_ms:0 ~enviar ~sobre_perdido:(fun ~destino ~largo ~motivo -> perdidos := (destino, largo, motivo) :: !perdidos; Lwt.return ()) in
  ignore (Cola_salida.encolar cola ~destino:"a" [ "hola" ]);
  let* _ = Cola_salida.esperar_reposo ~plazo:10. cola in
  Alcotest.(check int) "tres intentos" 3 !intentos;
  Alcotest.(check int) "se da por perdido y se avisa" 1 (List.length !perdidos);
  Lwt.return ()

let test_veredictos_del_agente_real _ () =
  Ayuda.con_entorno (fun e ->
      (* Forma que de verdad devuelve el agente: el juez apagado y, entre los «veredictos», la nota del bandido de articulos (que no es
         un veredicto). Tambien con el juez en sombra y un veredicto de verdad. *)
      e.agente.responder <-
        (fun _ ->
          let base = Falsos.Agente_falso.base ~respuesta:(Some "Hola.") ~etapa:"recepcion" ~memoria:(`Assoc []) ~intencion:"saludo" ~confianza:0.95 () in
          ( 200,
            Json.set "juez"
              (`Assoc
                [ ("modo", `String "sombra");
                  ( "veredictos",
                    `Assoc
                      [ ("rag", `Assoc [ ("modo_bandido", `String "sombra"); ("orden_puro", `List [ `String "KB-002" ]) ]);
                        ("contesta", `Assoc [ ("veredicto", `String "contesta_lo_preguntado"); ("confianza", `Float 0.86) ]) ] ) ])
              base ));
      let* _ = enviar e "hola" in
      let* juez = Ayuda.lista e.db "SELECT salida FROM decisiones WHERE componente = 'juez'" (`Assoc []) in
      Alcotest.(check int) "solo lo que trae veredicto es del juez" 1 (List.length juez);
      Alcotest.(check string) "su veredicto" "contesta_lo_preguntado" (Json.str_d "veredicto" "" (Json.get "salida" (List.hd juez)));
      let* rag = Ayuda.lista e.db "SELECT modo, salida FROM decisiones WHERE componente = 'rag'" (`Assoc []) in
      Alcotest.(check int) "lo del bandido queda como su propio componente" 1 (List.length rag);
      Alcotest.(check string) "en sombra" "sombra" (Json.str_d "modo" "" (List.hd rag));
      (* El detalle de una incidencia solo muestra veredictos reales. *)
      let* m = Ayuda.fila e.db "SELECT meta->>'juez_veredicto' AS v FROM mensajes WHERE rol = 'usuario'" (`Assoc []) in
      check_contiene "analitica: juez_veredicto sin lo que no es veredicto" "contesta=contesta_lo_preguntado" (Json.str_d "v" "" m);
      Alcotest.(check bool) "y sin el bandido" false (contiene "rag" (Json.str_d "v" "" m));
      Lwt.return ())
(* El agente real pide la nota con etapa «cierre» y memoria.pendiente = «puntaje» (no con etapa «encuesta»). *)
let test_encuesta_con_etapa_cierre _ () =
  Ayuda.con_entorno (fun e ->
      e.agente.responder <-
        (fun p ->
          let msg = Json.str_d "mensaje" "" p in
          if msg = "5" then
            (200, Falsos.Agente_falso.base ~respuesta:None ~etapa:"encuesta" ~memoria:(`Assoc []) ~intencion:"aportar_dato" ~confianza:0.9 ~accion:(`Assoc [ ("tipo", `String "encuesta"); ("puntaje", `Int 5) ]) ())
          else
            ( 200,
              Falsos.Agente_falso.base ~respuesta:(Some "Qué bueno. ¿Del 1 al 5, qué nota nos pones?") ~etapa:"cierre" ~memoria:(`Assoc [ ("pendiente", `String "puntaje") ]) ~intencion:"confirmar_solucion" ~confianza:0.95
                ~accion:(`Assoc [ ("tipo", `String "confirmar_solucion") ]) () ));
      let* _ = enviar e "ya funcionó, gracias" in
      let* filas = Ayuda.lista e.db "SELECT payload FROM outbox_analitica WHERE tabla = 'encuestas' ORDER BY id" (`Assoc []) in
      Alcotest.(check int) "al preguntar la nota se envia la encuesta (fila con puntaje NULL)" 1 (List.length filas);
      Alcotest.(check bool) "puntaje null" true (Json.get "puntaje" (Json.get "payload" (List.hd filas)) = `Null);
      let* _ = enviar e "ya funcionó otra vez" in
      let* n = Ayuda.contar e.db "SELECT 1 FROM encuestas" in
      Alcotest.(check int) "una sola pendiente por caso" 1 n;
      let* _ = enviar e "5" in
      let* filas = Ayuda.lista e.db "SELECT payload FROM outbox_analitica WHERE tabla = 'encuestas' ORDER BY id" (`Assoc []) in
      Alcotest.(check int) "al responder se reencola la misma" 2 (List.length filas);
      Alcotest.(check int) "con el puntaje" 5 (Json.int_d "puntaje" 0 (Json.get "payload" (List.nth filas 1)));
      Lwt.return ())

(* `accion.dato` + `accion.datos`: se anotan todos en la incidencia abierta. *)
let test_agregar_varios_datos _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "mi correo, desde hoy" in
      let* _ = enviar e "sigue igual" in
      let d k v = `Assoc [ ("clave", `String k); ("valor", `String v) ] in
      e.agente.responder <-
        (fun _ ->
          ( 200,
            Json.set "analisis" (`Assoc [ ("bitacora", `List [ `String "regla x" ]) ])
              (Falsos.Agente_falso.base ~respuesta:(Some "Anotado.") ~etapa:"seguimiento" ~memoria:(`Assoc []) ~intencion:"aportar_dato" ~confianza:0.9
                 ~accion:(`Assoc [ ("tipo", `String "agregar_dato"); ("dato", d "equipo" "PC-CONT-07"); ("datos", `List [ d "equipo" "PC-CONT-07"; d "sede" "Centro"; d "piso" "3" ]) ])
                 ()) ));
      let* r = enviar e "mi equipo es PC-CONT-07, en la sede Centro, piso 3" in
      Alcotest.(check (list string)) "responde el agente" [ "Anotado." ] r.textos;
      let* ev = Ayuda.lista e.db "SELECT datos FROM incidencia_eventos WHERE tipo = 'dato_agregado' ORDER BY id" (`Assoc []) in
      Alcotest.(check (list string)) "tres datos distintos (el repetido no se duplica)" [ "equipo"; "sede"; "piso" ] (List.map (fun f -> Json.str_d "clave" "" (Json.get "datos" f)) ev);
      Alcotest.(check (list string)) "con su valor" [ "PC-CONT-07"; "Centro"; "3" ] (List.map (fun f -> Json.str_d "valor" "" (Json.get "datos" f)) ev);
      Alcotest.(check bool) "el analisis del agente viaja al cajon del chat web" true (Json.get "bitacora" (Json.get "agente" r.analisis) <> `Null);
      Lwt.return ())

let test_usos_de_articulos_por_categoria _ () =
  Ayuda.con_entorno (fun e ->
      let* _ = enviar e "no me abre el correo" in
      let* _ = enviar e "sigue igual" in
      let* u = Ayuda.fila e.db "SELECT resultado, categoria_id FROM articulo_usos" (`Assoc []) in
      Alcotest.(check string) "fracaso del articulo" "sigue_igual" (Json.str_d "resultado" "" u);
      Alcotest.(check int) "en la categoria del CASO (correo)" 1 (Json.int_d "categoria_id" 0 u);
      let* r = Db.lista_p e.db "SELECT 1 AS x" (`Assoc []) in
      ignore r;
      let* () = Api_asistente.recargar_agente e.ctx in
      let recarga = List.find (fun j -> Json.str "_ruta" j = Some "/conocimiento/recargar") e.agente.recibidas in
      let art = List.hd (Json.list "articulos" recarga) in
      Alcotest.(check int) "usos: fracasos en correo" 1 (Json.int_d "fracasos" 0 (Json.get "correo" (Json.get "usos" art)));
      Alcotest.(check int) "usos: exitos" 0 (Json.int_d "exitos" 1 (Json.get "correo" (Json.get "usos" art)));
      Lwt.return ())

let () =
  Lwt_main.run
    (Alcotest_lwt.run "integracion"
       [ ( "flujo",
           [ Alcotest_lwt.test_case "caso nuevo -> incidencia con texto fijo (numero, tecnico, plazo)" `Quick test_caso_a_incidencia;
             Alcotest_lwt.test_case "incidencia duplicada -> agregar dato" `Quick test_duplicada;
             Alcotest_lwt.test_case "sesion nueva tras 6 h sin mensajes" `Quick test_sesion_6h;
             Alcotest_lwt.test_case "pausa por tecnico: no responde el asistente, el mensaje llega a la incidencia" `Quick test_pausa_por_tecnico;
             Alcotest_lwt.test_case "agente caido -> cortesia, derivacion y sin credenciales" `Slow test_agente_caido;
             Alcotest_lwt.test_case "agente y motor caidos -> cortesia honesta" `Slow test_agente_caido_y_motor_caido;
             Alcotest_lwt.test_case "motor caido al crear -> no se finge" `Quick test_motor_caido_al_crear;
             Alcotest_lwt.test_case "sin tecnico -> cola del grupo" `Quick test_en_cola;
             Alcotest_lwt.test_case "contraseña oculta al guardar y en analitica" `Quick test_contrasena_oculta;
             Alcotest_lwt.test_case "resolver -> confirmar -> encuesta" `Quick test_resolver_confirmar_encuesta;
             Alcotest_lwt.test_case "sigue igual reabre una incidencia resuelta" `Quick test_sigue_igual_reabre;
             Alcotest_lwt.test_case "consultar estado: flujo fijo con datos reales" `Quick test_consultar_estado;
             Alcotest_lwt.test_case "pedir tecnico" `Quick test_pedir_tecnico;
             Alcotest_lwt.test_case "decisiones y veredictos en sombra" `Quick test_decisiones;
             Alcotest_lwt.test_case "juicio marca numeros y plazos en texto libre" `Quick test_juicio_marca_numero_en_texto_libre;
             Alcotest_lwt.test_case "veredictos: solo los del juez; el bandido aparte" `Quick test_veredictos_del_agente_real;
             Alcotest_lwt.test_case "encuesta pedida con etapa «cierre» y pendiente «puntaje»" `Quick test_encuesta_con_etapa_cierre;
             Alcotest_lwt.test_case "agregar_dato con varios datos" `Quick test_agregar_varios_datos;
             Alcotest_lwt.test_case "usos de articulos por categoria del caso" `Quick test_usos_de_articulos_por_categoria;
             Alcotest_lwt.test_case "audio e imagen: aviso amable" `Quick test_no_texto;
             Alcotest_lwt.test_case "chat web: mismo flujo, sin WhatsApp" `Quick test_chat_web ] );
         ( "analitica",
           [ Alcotest_lwt.test_case "outbox con el formato exacto de CONTRATOS §4" `Quick test_outbox_analitica;
             Alcotest_lwt.test_case "contencion: resuelto por el asistente y confirmado" `Quick test_contencion;
             Alcotest_lwt.test_case "ANALITICA_TEXTO=1 lleva el texto" `Quick test_outbox_con_texto ] );
         ( "cola de salida",
           [ Alcotest_lwt.test_case "orden y espaciado por chat" `Quick test_cola_salida_en_orden;
             Alcotest_lwt.test_case "reintentos y aviso al perder" `Slow test_cola_salida_reintenta_y_pierde ] ) ])
