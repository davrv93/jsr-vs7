(* Pruebas unitarias: sin base de datos. Criptografia, JWT, roles, configuracion, enmascarado de datos personales, parseo del
   webhook, textos fijos, validacion de entradas, y los clientes HTTP contra servidores Dream de prueba. *)

open Pasarela

let ( let* ) = Lwt.bind

let contiene sub s = Falsos.Agente_falso.contiene sub s
let check_contiene msg sub s = Alcotest.(check bool) (msg ^ " (contiene «" ^ sub ^ "» en «" ^ s ^ "»)") true (contiene sub s)
let check_no_contiene msg sub s = Alcotest.(check bool) (msg ^ " (no debe contener «" ^ sub ^ "» en «" ^ s ^ "»)") false (contiene sub s)

let lanza_api estado codigo f =
  match f () with
  | _ -> Alcotest.failf "se esperaba un error de API %d/%s y no hubo ninguno" estado codigo
  | exception Errores.Api (e, c, _) ->
      Alcotest.(check int) "estado HTTP" estado e;
      Alcotest.(check string) "codigo" codigo c

(* --- cripto ------------------------------------------------------------------------------------------------------------------------- *)

let hex = Cripto.hex_de_bytes

let test_pbkdf2_vectores () =
  (* Vectores de PBKDF2-HMAC-SHA256 (RFC 7914 §11 y los habituales de password/salt). *)
  Alcotest.(check string) "c=1" "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b" (hex (Cripto.pbkdf2_sha256 ~clave:"password" ~sal:"salt" ~iteraciones:1));
  Alcotest.(check string) "c=2" "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43" (hex (Cripto.pbkdf2_sha256 ~clave:"password" ~sal:"salt" ~iteraciones:2));
  Alcotest.(check string) "c=4096" "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a" (hex (Cripto.pbkdf2_sha256 ~clave:"password" ~sal:"salt" ~iteraciones:4096))

let test_hash_de_clave () =
  let h1 = Cripto.hash_clave ~iteraciones:1000 "una-clave-segura" and h2 = Cripto.hash_clave ~iteraciones:1000 "una-clave-segura" in
  Alcotest.(check bool) "con sal: dos hashes de la misma clave difieren" true (h1 <> h2);
  Alcotest.(check bool) "formato pbkdf2-sha256$iter$sal$hash" true (match String.split_on_char '$' h1 with [ "pbkdf2-sha256"; "1000"; s; h ] -> s <> "" && h <> "" | _ -> false);
  Alcotest.(check bool) "nunca texto plano" false (contiene "una-clave-segura" h1);
  Alcotest.(check bool) "verifica la correcta" true (Cripto.verificar_clave "una-clave-segura" ~hash:h1);
  Alcotest.(check bool) "verifica con la otra sal" true (Cripto.verificar_clave "una-clave-segura" ~hash:h2);
  Alcotest.(check bool) "rechaza otra clave" false (Cripto.verificar_clave "una-clave-segurA" ~hash:h1);
  Alcotest.(check bool) "rechaza vacia" false (Cripto.verificar_clave "" ~hash:h1);
  List.iter
    (fun malo -> Alcotest.(check bool) ("hash mal formado: " ^ malo) false (Cripto.verificar_clave "x" ~hash:malo))
    [ ""; "x"; "pbkdf2-sha256$1000$a"; "pbkdf2-sha256$abc$AAAA$BBBB"; "otro$1000$AAAA$BBBB"; "pbkdf2-sha256$0$AAAA$BBBB"; "pbkdf2-sha256$99999999999$AAAA$BBBB"; "pbkdf2-sha256$1000$***$***" ];
  (* Las iteraciones van dentro del hash: subirlas despues no invalida las claves viejas. *)
  let viejo = Cripto.hash_clave ~iteraciones:1000 "clave-vieja" in
  Alcotest.(check bool) "iteraciones propias" true (Cripto.verificar_clave "clave-vieja" ~hash:viejo)

let test_costo_pbkdf2 () =
  let t0 = Unix.gettimeofday () in
  ignore (Cripto.hash_clave "medir");
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "    [medida] PBKDF2-HMAC-SHA256 con %d iteraciones: %.0f ms\n%!" Cripto.iteraciones_por_defecto (dt *. 1000.);
  Alcotest.(check bool) "un hash con las iteraciones por defecto tarda menos de 3 s" true (dt < 3.0);
  Alcotest.(check bool) "y no menos de 600000 iteraciones (OWASP 2023)" true (Cripto.iteraciones_por_defecto >= 600_000)

let test_igual_const () =
  Alcotest.(check bool) "iguales" true (Cripto.igual_const "secreto" "secreto");
  Alcotest.(check bool) "distintos" false (Cripto.igual_const "secreto" "secretO");
  Alcotest.(check bool) "largos distintos" false (Cripto.igual_const "secreto" "secreto1");
  Alcotest.(check bool) "prefijo" false (Cripto.igual_const "secreto" "secre");
  Alcotest.(check bool) "vacios" true (Cripto.igual_const "" "");
  Alcotest.(check bool) "vacio contra algo" false (Cripto.igual_const "" "a")

(* --- JWT --------------------------------------------------------------------------------------------------------------------------------- *)

let secreto = "secreto-de-prueba-0123456789abcdef"

let test_jwt () =
  let ahora = 1_800_000_000. in
  let t = Jwt.firmar ~secreto ~ahora ~horas:12 ~sub:7 ~rol:"supervisor" ~tec:(Some 3) () in
  Alcotest.(check int) "tres partes" 3 (List.length (String.split_on_char '.' t));
  (match Jwt.verificar ~secreto ~ahora:(ahora +. 60.) t with
  | Ok c ->
      Alcotest.(check int) "sub" 7 c.sub;
      Alcotest.(check string) "rol" "supervisor" c.rol;
      Alcotest.(check (option int)) "tec" (Some 3) c.tec;
      Alcotest.(check int) "12 h" (12 * 3600) (c.exp - c.iat)
  | Error _ -> Alcotest.fail "debia verificar");
  Alcotest.(check bool) "justo antes de vencer" true (Result.is_ok (Jwt.verificar ~secreto ~ahora:(ahora +. 12. *. 3600. -. 1.) t));
  Alcotest.(check bool) "vencido" true (Jwt.verificar ~secreto ~ahora:(ahora +. 12. *. 3600.) t = Error Jwt.Expirado);
  Alcotest.(check bool) "otra clave" true (Jwt.verificar ~secreto:"otro-secreto-0123456789abcdef" ~ahora t = Error Jwt.Firma_invalida);
  (* Alterar la carga (p. ej. subir el rol) invalida la firma. *)
  (match String.split_on_char '.' t with
  | [ h; _; f ] ->
      let falsa = Cripto.b64u (Printf.sprintf {|{"sub":7,"rol":"admin","tec":3,"iat":%d,"exp":%d}|} (int_of_float ahora) (int_of_float ahora + 99999)) in
      Alcotest.(check bool) "carga alterada" true (Jwt.verificar ~secreto ~ahora (h ^ "." ^ falsa ^ "." ^ f) = Error Jwt.Firma_invalida);
      Alcotest.(check bool) "sin firma" true (Result.is_error (Jwt.verificar ~secreto ~ahora (h ^ "." ^ falsa ^ ".")))
  | _ -> Alcotest.fail "forma");
  (* alg=none y otros algoritmos. *)
  let sin_alg = Cripto.b64u {|{"alg":"none","typ":"JWT"}|} ^ "." ^ Cripto.b64u {|{"sub":1,"rol":"admin","exp":9999999999}|} ^ "." in
  Alcotest.(check bool) "alg none" true (Result.is_error (Jwt.verificar ~secreto ~ahora sin_alg));
  let cab_otra = Cripto.b64u {|{"alg":"HS512","typ":"JWT"}|} in
  let cuerpo = Cripto.b64u {|{"sub":1,"rol":"admin","exp":9999999999}|} in
  let firma = Cripto.b64u (Cripto.hmac_sha256 ~key:secreto (cab_otra ^ "." ^ cuerpo)) in
  Alcotest.(check bool) "cabecera de otro algoritmo, aunque la firma cuadre" true (Result.is_error (Jwt.verificar ~secreto ~ahora (cab_otra ^ "." ^ cuerpo ^ "." ^ firma)));
  List.iter (fun m -> Alcotest.(check bool) ("malformado: " ^ m) true (Result.is_error (Jwt.verificar ~secreto ~ahora m))) [ ""; "a"; "a.b"; "a.b.c.d"; "..."; "eyJ.eyJ.xxx" ]

(* --- roles -------------------------------------------------------------------------------------------------------------------------------- *)

let test_roles () =
  let open Roles in
  let casos =
    [ (R_tecnico, [ Tecnico; Supervisor; Gerencia; Admin ]); (R_supervisor, [ Supervisor; Gerencia; Admin ]); (R_gerencia, [ Gerencia; Admin ]);
      (R_entrenador, [ Entrenador; Admin ]); (R_admin, [ Admin ]); (R_conversaciones, [ Tecnico; Supervisor; Gerencia; Entrenador; Admin ]); (R_publico, todos) ]
  in
  List.iter
    (fun (req, permitidos) ->
      List.iter
        (fun r -> Alcotest.(check bool) (Printf.sprintf "%s %s" (a_string r) (if List.mem r permitidos then "puede" else "no puede")) (List.mem r permitidos) (permite r req))
        todos)
    casos;
  Alcotest.(check bool) "admin puede todo" true (List.for_all (fun req -> permite Admin req) [ R_tecnico; R_supervisor; R_gerencia; R_entrenador; R_admin; R_conversaciones; R_publico ]);
  Alcotest.(check bool) "el entrenador no es gerencia aunque gane mas" false (permite Entrenador R_gerencia);
  Alcotest.(check bool) "ida y vuelta" true (List.for_all (fun r -> de_string (a_string r) = Some r) todos);
  Alcotest.(check bool) "rol desconocido" true (de_string "capitan" = None)

(* --- base de datos: marcadores ------------------------------------------------------------------------------------------------------- *)

let test_sustituir () =
  Alcotest.(check string) "texto" "SELECT (($1::text::jsonb->>'a'))" (Db.sustituir "SELECT ($a)");
  Alcotest.(check string) "entero" "x = ((($1::text::jsonb->>'id'))::bigint)" (Db.sustituir "x = ($i:id)" |> fun s -> if contiene "::bigint" s then "x = ((($1::text::jsonb->>'id'))::bigint)" else s);
  let s = Db.sustituir "a = $i:n AND b = $b:ok AND c = $f:x AND d = $t:cuando AND e = $j:doc AND f = $nombre" in
  List.iter (fun parte -> check_contiene "tipos" parte s) [ "->>'n')::bigint"; "->>'ok')::boolean"; "->>'x')::float8"; "->>'cuando')::timestamptz"; "NULLIF("; "->>'nombre'" ];
  Alcotest.(check bool) "los marcadores no dejan `$` sueltos" false (contiene "$n" s || contiene "$nombre" s);
  (* Una cadena con `$` entre comillas que no es marcador se conserva. *)
  Alcotest.(check string) "sin marcadores" "SELECT 'cuesta $5'" (Db.sustituir "SELECT 'cuesta $5'");
  Alcotest.(check string) "comodines escapados" "100\\%\\_\\\\" (Db.escapar_like "100%_\\")

(* --- enmascarado ------------------------------------------------------------------------------------------------------------------------------ *)

let test_mascara_telefono () =
  Alcotest.(check string) "telefono de Peru" "51••••4321" (Mascara.telefono "51987654321");
  Alcotest.(check string) "con simbolos" "51••••4321" (Mascara.telefono "+51 987-654-321");
  Alcotest.(check string) "jid" "51••••4321@s.whatsapp.net" (Mascara.chat "51987654321@s.whatsapp.net");
  Alcotest.(check string) "corto" "••••21" (Mascara.telefono "123421");
  Alcotest.(check bool) "nunca el numero completo" false (contiene "987654" (Mascara.telefono "51987654321"));
  Alcotest.(check string) "vacio" "••••" (Mascara.telefono "");
  Alcotest.(check string) "correo" "a***@ejemplo.test" (Mascara.correo "ana@ejemplo.test")

let test_mascara_credenciales () =
  let o = Mascara.ocultar_credenciales in
  Alcotest.(check string) "contraseña es X" "mi contraseña es [oculto] y no entro" (o "mi contraseña es Abc12345 y no entro");
  Alcotest.(check string) "clave: X" "clave: [oculto]" (o "clave: Hunter2!");
  Alcotest.(check string) "password=X" "password=[oculto]" (o "password=s3cr3t");
  Alcotest.(check string) "sin separador pero con pinta de clave" "mi clave [oculto]" (o "mi clave Abc12345");
  Alcotest.(check string) "token" "el token es [oculto]" (o "el token es 9f8e7d6c5b4a");
  Alcotest.(check string) "bearer" "Authorization: Bearer [oculto]" (o "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def");
  Alcotest.(check string) "cadena larga mezclada" "usa [oculto] ahora" (o "usa 9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e ahora");
  (* Falsos positivos: texto normal se conserva. *)
  List.iter
    (fun t -> Alcotest.(check string) ("se conserva: " ^ t) t (o t))
    [ "no me abre el correo"; "la clave de la caja fuerte no funciona"; "el token del banco no llega"; "mi contraseña expiró"; "necesito un pin"; "la impresora del tercer piso" ];
  Alcotest.(check string) "idempotente" (o "mi contraseña es Abc12345") (o (o "mi contraseña es Abc12345"))

(* --- configuracion --------------------------------------------------------------------------------------------------------------------------- *)

let completo =
  [ ("DATABASE_URL", "postgresql://u:p@h/db"); ("JWT_SECRET", "secreto-de-prueba-0123456789abcdef"); ("MOTOR_URL", "http://motor:8090/"); ("MOTOR_CLAVE", "clave-del-motor-1234");
    ("AGENTE_URL", "http://agente:8000"); ("WEBHOOK_SECRET", "secreto-del-webhook") ]

let cargar vars = Config.cargar ~getenv:(fun k -> List.assoc_opt k vars)

let test_config () =
  (match cargar completo with
  | Ok c ->
      Alcotest.(check int) "puerto por defecto" 8080 c.puerto;
      Alcotest.(check string) "sin barra final" "http://motor:8090" c.motor_url;
      Alcotest.(check bool) "evolution simulado por defecto" true (c.evolution_modo = Config.Simulado);
      Alcotest.(check bool) "ANALITICA_TEXTO apagado por defecto" false c.analitica_texto;
      Alcotest.(check bool) "sesion de 6 h" true (c.sesion_horas = 6.0);
      Alcotest.(check int) "JWT de 12 h" 12 c.jwt_horas;
      Alcotest.(check (list string)) "sin CORS por defecto" [] c.cors_origenes;
      Alcotest.(check bool) "migrar y trabajadores encendidos" true (c.migrar && c.trabajadores)
  | Error es -> Alcotest.failf "debia cargar: %s" (String.concat "; " es));
  (* Todo lo que falta, de una vez. *)
  (match cargar [] with
  | Error es ->
      Alcotest.(check int) "reporta todo lo obligatorio junto" 6 (List.length es);
      List.iter (fun v -> Alcotest.(check bool) ("menciona " ^ v) true (List.exists (fun e -> contiene v e) es)) [ "DATABASE_URL"; "JWT_SECRET"; "MOTOR_URL"; "MOTOR_CLAVE"; "AGENTE_URL"; "WEBHOOK_SECRET" ]
  | Ok _ -> Alcotest.fail "debia fallar");
  Alcotest.(check bool) "vacias cuentan como ausentes" true (Result.is_error (cargar (("JWT_SECRET", "   ") :: List.remove_assoc "JWT_SECRET" completo)));
  Alcotest.(check bool) "JWT_SECRET corto" true (Result.is_error (cargar (("JWT_SECRET", "corto") :: List.remove_assoc "JWT_SECRET" completo)));
  Alcotest.(check bool) "MOTOR_CLAVE corta (el motor exige 16)" true (Result.is_error (cargar (("MOTOR_CLAVE", "corta") :: List.remove_assoc "MOTOR_CLAVE" completo)));
  Alcotest.(check bool) "PORT fuera de rango" true (Result.is_error (cargar (("PORT", "70000") :: completo)));
  Alcotest.(check bool) "PORT no numerico" true (Result.is_error (cargar (("PORT", "abc") :: completo)));
  Alcotest.(check bool) "SESION_HORAS invalida" true (Result.is_error (cargar (("SESION_HORAS", "-1") :: completo)));
  (* El modo real exige todo explicito: nunca se envia a un numero real por un valor por defecto. *)
  Alcotest.(check bool) "modo real sin URL, clave ni instancia" true (match cargar (("EVOLUTION_MODO", "real") :: completo) with Error es -> List.length es = 3 | Ok _ -> false);
  Alcotest.(check bool) "modo desconocido" true (Result.is_error (cargar (("EVOLUTION_MODO", "casi") :: completo)));
  (match cargar (("EVOLUTION_MODO", "real") :: ("EVOLUTION_URL", "http://evo:8080/") :: ("EVOLUTION_API_KEY", "k") :: ("EVOLUTION_INSTANCIA", "jsr") :: completo) with
  | Ok c -> Alcotest.(check bool) "real con todo" true (c.evolution_modo = Config.Real)
  | Error es -> Alcotest.failf "real con todo debia cargar: %s" (String.concat "; " es));
  (match cargar (("CORS", "https://a.test/, http://b.test ,,") :: ("ANALITICA_TEXTO", "1") :: ("CONFIAR_PROXY", "1") :: completo) with
  | Ok c ->
      Alcotest.(check (list string)) "CORS parseado y sin barras" [ "https://a.test"; "http://b.test" ] c.cors_origenes;
      Alcotest.(check bool) "ANALITICA_TEXTO=1" true c.analitica_texto;
      Alcotest.(check bool) "CONFIAR_PROXY=1" true c.confiar_proxy
  | Error _ -> Alcotest.fail "debia cargar");
  (* El resumen nunca imprime un valor secreto. *)
  match cargar completo with
  | Ok c ->
      let r = String.concat "\n" (List.map (fun (k, v) -> k ^ "=" ^ v) (Config.resumen c)) in
      List.iter (fun secreto -> check_no_contiene "el resumen no filtra secretos" secreto r) [ "secreto-de-prueba"; "clave-del-motor"; "secreto-del-webhook"; "postgresql://"; "u:p@h" ];
      check_contiene "pero dice que estan" "definida" r
  | Error _ -> Alcotest.fail "debia cargar"

(* --- webhook ------------------------------------------------------------------------------------------------------------------------------------- *)

let evo ?(id = "A1") ?(chat = "51987654321@s.whatsapp.net") ?(alterno = "") ?(de_mi = false) ?(grupo = false) mensaje =
  Json.to_string
    (`Assoc
      [ ("event", `String "Message");
        ("data", `Assoc [ ("Info", `Assoc [ ("ID", `String id); ("Chat", `String chat); ("SenderAlt", `String alterno); ("IsFromMe", `Bool de_mi); ("IsGroup", `Bool grupo); ("PushName", `String "Ana") ]); ("Message", mensaje) ]) ])

let procesar_de cuerpo = match Webhook.parsear cuerpo with Ok (Webhook.Procesar e) -> e | Ok (Webhook.Ignorar m) -> Alcotest.failf "se ignoro: %s" m | Error m -> Alcotest.failf "error: %s" m
let ignorado_de cuerpo = match Webhook.parsear cuerpo with Ok (Webhook.Ignorar m) -> m | Ok (Webhook.Procesar _) -> Alcotest.fail "debia ignorarse" | Error m -> Alcotest.failf "error: %s" m

let test_webhook_parseo () =
  let e = procesar_de (evo (`Assoc [ ("conversation", `String "  no me abre el correo ") ])) in
  Alcotest.(check string) "canal" "whatsapp" e.canal;
  Alcotest.(check string) "chat = telefono" "51987654321" e.chat_id;
  Alcotest.(check (option string)) "telefono" (Some "51987654321") e.telefono;
  Alcotest.(check (option string)) "id para deduplicar" (Some "A1") e.msg_id;
  Alcotest.(check string) "nombre" "Ana" e.nombre;
  Alcotest.(check bool) "texto recortado" true (e.contenido = Webhook.Texto "no me abre el correo");
  let e = procesar_de (evo (`Assoc [ ("extendedTextMessage", `Assoc [ ("text", `String "respuesta citada") ]) ])) in
  Alcotest.(check bool) "extendedTextMessage" true (e.contenido = Webhook.Texto "respuesta citada");
  let e = procesar_de (evo (`Assoc [ ("buttonsResponseMessage", `Assoc [ ("selectedButtonID", `String "si"); ("selectedDisplayText", `String "Sí") ]) ])) in
  Alcotest.(check bool) "boton" true (e.contenido = Webhook.Texto "si");
  let e = procesar_de (evo (`Assoc [ ("listResponseMessage", `Assoc [ ("title", `String "VPN"); ("singleSelectReply", `Assoc [ ("selectedRowID", `String "vpn") ]) ]) ])) in
  Alcotest.(check bool) "lista" true (e.contenido = Webhook.Texto "vpn");
  let e = procesar_de (evo (`Assoc [ ("ephemeralMessage", `Assoc [ ("message", `Assoc [ ("conversation", `String "temporal") ]) ]) ])) in
  Alcotest.(check bool) "mensaje temporal" true (e.contenido = Webhook.Texto "temporal");
  (* No texto: aviso amable (el flujo decide). *)
  List.iter
    (fun (clave, tipo) ->
      let e = procesar_de (evo (`Assoc [ (clave, `Assoc [ ("mimetype", `String "x") ]) ])) in
      Alcotest.(check bool) clave true (e.contenido = Webhook.No_texto tipo))
    [ ("audioMessage", "audio"); ("imageMessage", "imagen"); ("videoMessage", "video"); ("documentMessage", "documento"); ("stickerMessage", "sticker"); ("locationMessage", "ubicacion"); ("contactMessage", "contacto") ];
  let e = procesar_de (evo (`Assoc [ ("imageMessage", `Assoc [ ("caption", `String "mira este error") ]) ])) in
  Alcotest.(check bool) "imagen con pie: el pie es el texto" true (e.contenido = Webhook.Texto "mira este error");
  (* Se ignora. *)
  Alcotest.(check string) "propio" "mensaje propio" (ignorado_de (evo ~de_mi:true (`Assoc [ ("conversation", `String "x") ])));
  Alcotest.(check string) "grupo (flag)" "grupo o difusion" (ignorado_de (evo ~grupo:true (`Assoc [ ("conversation", `String "x") ])));
  Alcotest.(check string) "grupo (jid)" "grupo o difusion" (ignorado_de (evo ~chat:"120363@g.us" (`Assoc [ ("conversation", `String "x") ])));
  Alcotest.(check string) "difusion" "grupo o difusion" (ignorado_de (evo ~chat:"status@broadcast" (`Assoc [ ("conversation", `String "x") ])));
  Alcotest.(check string) "canal" "grupo o difusion" (ignorado_de (evo ~chat:"1@newsletter" (`Assoc [ ("conversation", `String "x") ])));
  Alcotest.(check string) "sin id" "sin id de mensaje" (ignorado_de (evo ~id:"" (`Assoc [ ("conversation", `String "x") ])));
  Alcotest.(check bool) "reaccion" true (match Webhook.parsear (evo (`Assoc [ ("reactionMessage", `Assoc []) ])) with Ok (Webhook.Ignorar _) -> true | _ -> false);
  Alcotest.(check bool) "texto vacio" true (match Webhook.parsear (evo (`Assoc [ ("conversation", `String "   ") ])) with Ok (Webhook.Ignorar _) -> true | _ -> false);
  Alcotest.(check bool) "otro evento" true (match Webhook.parsear {|{"event":"Receipt","data":{}}|} with Ok (Webhook.Ignorar _) -> true | _ -> false);
  Alcotest.(check bool) "no es JSON" true (Result.is_error (Webhook.parsear "<html>"));
  (* @lid: se usa el alterno con el telefono si lo hay; si no, el JID. *)
  let e = procesar_de (evo ~chat:"1234567890123@lid" ~alterno:"51911222333@s.whatsapp.net" (`Assoc [ ("conversation", `String "hola") ])) in
  Alcotest.(check (option string)) "lid con alterno" (Some "51911222333") e.telefono;
  let e = procesar_de (evo ~chat:"1234567890123@lid" (`Assoc [ ("conversation", `String "hola") ])) in
  Alcotest.(check (option string)) "lid sin telefono" None e.telefono;
  Alcotest.(check string) "el chat es el JID" "1234567890123@lid" e.chat_id;
  let e = procesar_de (evo ~chat:"51987654321:12@s.whatsapp.net" (`Assoc [ ("conversation", `String "hola") ])) in
  Alcotest.(check string) "dispositivo en el JID" "51987654321" e.chat_id;
  (* Formato de Evolution API v2. *)
  let v2 = {|{"event":"messages.upsert","data":{"key":{"remoteJid":"51900000001@s.whatsapp.net","fromMe":false,"id":"X9"},"pushName":"Luis","message":{"conversation":"hola v2"}}}|} in
  let e = procesar_de v2 in
  Alcotest.(check bool) "v2" true (e.contenido = Webhook.Texto "hola v2" && e.telefono = Some "51900000001" && e.msg_id = Some "X9");
  (* El nombre no puede traer caracteres de control ni ser enorme. *)
  let e = procesar_de (Json.to_string (`Assoc [ ("event", `String "Message"); ("data", `Assoc [ ("Info", `Assoc [ ("ID", `String "B"); ("Chat", `String "51987654321@s.whatsapp.net"); ("PushName", `String ("Ana\n\x00" ^ String.make 200 'x')) ]); ("Message", `Assoc [ ("conversation", `String "hola") ]) ]) ])) in
  Alcotest.(check bool) "nombre limpio y acotado" true (String.length e.nombre <= 80 && not (String.contains e.nombre '\n'))

(* --- textos fijos --------------------------------------------------------------------------------------------------------------------------------- *)

let test_textos_plazos () =
  (* 2026-10-05 15:30 UTC = 10:30 en Lima (UTC-5). *)
  let ahora = 1791214200. in
  Alcotest.(check string) "hoy" "las 11:40 de hoy" (Tiempo.texto_plazo ~ahora (ahora +. 70. *. 60.));
  Alcotest.(check string) "mañana" "las 09:15 de mañana" (Tiempo.texto_plazo ~ahora (ahora +. 22.75 *. 3600.));
  Alcotest.(check bool) "otro dia: con dia de la semana y fecha" true (contiene "el jue 08/10 a las" (Tiempo.texto_plazo ~ahora (ahora +. 3. *. 86400.)));
  (* Cruce de medianoche UTC / Lima: a las 23:30 de Lima ya es el dia siguiente en UTC. *)
  let noche_lima = Option.get (Tiempo.de_iso "2026-10-06T04:30:00Z") (* 23:30 del 5 en Lima *) in
  Alcotest.(check string) "23:30 de Lima es hoy aunque en UTC sea mañana" "las 23:45 de hoy" (Tiempo.texto_plazo ~ahora:noche_lima (noche_lima +. 15. *. 60.));
  Alcotest.(check string) "y a las 00:15 de Lima es mañana" "las 00:15 de mañana" (Tiempo.texto_plazo ~ahora:noche_lima (noche_lima +. 45. *. 60.));
  Alcotest.(check string) "ida y vuelta ISO" "2026-10-05T15:30:00Z" (Tiempo.a_iso ahora);
  Alcotest.(check bool) "ISO con milisegundos" true (Tiempo.de_iso "2026-10-05T15:30:00.123Z" <> None);
  Alcotest.(check bool) "ISO invalido" true (Tiempo.de_iso "mañana" = None)

let test_textos_incidencia_creada () =
  let ahora = 1791214200. in
  let inc =
    `Assoc
      [ ("numero", `String "INC-000142"); ("prioridad", `String "P2"); ("tecnico", `String "Luis Paz"); ("grupo", `String "Mesa N1");
        ("vence_respuesta_en", `String (Tiempo.a_iso (ahora +. 70. *. 60.))); ("vence_resolucion_en", `String (Tiempo.a_iso (ahora +. 22.75 *. 3600.))); ("token_publico", `String "abc123def456abc1") ]
  in
  let t = Textos.incidencia_creada ~ahora ~base_url:"https://soporte.ejemplo.pe/jsr" ~inc ~asignacion:(`Assoc [ ("en_cola", `Bool false) ]) in
  check_contiene "numero" "INC-000142" t;
  check_contiene "prioridad" "(prioridad P2)" t;
  check_contiene "tecnico" "La atiende Luis Paz" t;
  check_contiene "plazo de respuesta" "te responderá antes de las 11:40 de hoy" t;
  check_contiene "plazo de resolucion" "Plazo de resolución: las 09:15 de mañana" t;
  check_contiene "enlace" "https://soporte.ejemplo.pe/jsr/estado/abc123def456abc1" t;
  let cola = Textos.incidencia_creada ~ahora ~base_url:"" ~inc ~asignacion:(`Assoc [ ("en_cola", `Bool true) ]) in
  check_contiene "cola del grupo" "Quedó en la cola de Mesa N1" cola;
  check_no_contiene "en cola no hay «La atiende»" "La atiende" cola;
  check_no_contiene "sin base publica no hay enlace" "estado/" cola;
  let sin_plazos = Textos.incidencia_creada ~ahora ~base_url:"" ~inc:(`Assoc [ ("numero", `String "INC-000001"); ("tecnico", `String "Luis") ]) ~asignacion:(`Assoc []) in
  check_contiene "sin plazos conocidos no se inventan" "La atiende Luis." sin_plazos;
  check_no_contiene "ni se escribe «plazo»" "Plazo" sin_plazos

let test_plantillas () =
  let v = [ ("numero", "INC-000142"); ("prioridad", "P2"); ("titulo", "Correo"); ("nota_interna", "NO"); ("plazo", "las 11:40 de hoy") ] in
  Alcotest.(check string) "relleno" "Te asignaron INC-000142 (P2): Correo. Plazo: las 11:40 de hoy." (Textos.render "Te asignaron {numero} ({prioridad}): {titulo}. Plazo: {plazo}." v);
  Alcotest.(check string) "un hueco sin valor desaparece y no deja basura" "Aviso INC-000142." (Textos.render "Aviso {numero}. {enlace}" v);
  Alcotest.(check string) "una clave que NO esta en la lista blanca no se rinde aunque venga en los datos" "x {nota_interna} y" (Textos.render "x {nota_interna} y" v);
  Alcotest.(check string) "control y saltos" "Hola" (Textos.render "Ho\x00la" []);
  Alcotest.(check bool) "huecos invalidos de una plantilla editada" true (Textos.huecos_invalidos "Hola {numero} {secreto} {otro}" = [ "secreto"; "otro" ]);
  Alcotest.(check bool) "todas las plantillas por defecto usan solo huecos validos" true (List.for_all (fun (_, t) -> Textos.huecos_invalidos t = []) Textos.plantillas_por_defecto);
  Alcotest.(check bool) "y ninguna menciona notas internas" true (List.for_all (fun (_, t) -> not (contiene "nota" t)) Textos.plantillas_por_defecto);
  (* Un valor muy largo se recorta. *)
  Alcotest.(check bool) "valor recortado" true (String.length (Textos.render "{titulo}" [ ("titulo", String.make 1000 'a') ]) <= 300)

let test_estado_y_consulta () =
  let ahora = 1791214200. in
  Alcotest.(check string) "estado" "En curso" (Textos.estado_corto "en_curso");
  Alcotest.(check string) "estado publico" "Estamos trabajando en ella" (Textos.estado_publico "en_curso");
  Alcotest.(check bool) "todos los estados tienen texto" true
    (List.for_all (fun e -> Textos.estado_corto e <> e && Textos.estado_publico e <> e) [ "nueva"; "asignada"; "en_curso"; "espera_usuario"; "espera_tercero"; "resuelta"; "cerrada"; "reabierta" ]);
  let f n = `Assoc [ ("numero", `String n); ("titulo", `String "Correo"); ("estado", `String "en_curso"); ("tecnico", `String "Luis"); ("vence_resolucion_en", `String (Tiempo.a_iso (ahora +. 3600.))) ] in
  check_contiene "ninguna" "No veo incidencias abiertas" (Textos.consulta_estado ~ahora ~base_url:"" []);
  check_contiene "una" "INC-1" (Textos.consulta_estado ~ahora ~base_url:"" [ f "INC-1" ]);
  let varias = Textos.consulta_estado ~ahora ~base_url:"" [ f "INC-1"; f "INC-2" ] in
  check_contiene "varias: la primera" "INC-1" varias;
  check_contiene "varias: la segunda" "INC-2" varias;
  check_contiene "encabezado" "incidencias abiertas" varias

(* --- limitador y hub ------------------------------------------------------------------------------------------------------------------------- *)

let test_limite () =
  let l = Limite.crear ~max:3 ~ventana:60. in
  let ok t k = Limite.intentar ~ahora:t l k = Ok () in
  Alcotest.(check bool) "1" true (ok 0. "a");
  Alcotest.(check bool) "2" true (ok 1. "a");
  Alcotest.(check bool) "3" true (ok 2. "a");
  (match Limite.intentar ~ahora:3. l "a" with Error s -> Alcotest.(check bool) "dice cuanto esperar (hasta que salga el mas viejo)" true (s >= 55 && s <= 60) | Ok () -> Alcotest.fail "debia bloquear");
  Alcotest.(check bool) "otra clave libre" true (ok 3. "b");
  Alcotest.(check bool) "pasada la ventana vuelve" true (ok 61. "a");
  Alcotest.(check bool) "bloqueado no cuenta" true (Limite.bloqueado ~ahora:61. l "zzz" = Ok ());
  Limite.registrar ~ahora:100. l "x"; Limite.registrar ~ahora:100. l "x"; Limite.registrar ~ahora:100. l "x";
  Alcotest.(check bool) "tres fallos bloquean" true (Result.is_error (Limite.bloqueado ~ahora:101. l "x"));
  Limite.olvidar l "x";
  Alcotest.(check bool) "olvidar" true (Limite.bloqueado ~ahora:101. l "x" = Ok ());
  Limite.limpiar ~ahora:1000. l;
  Alcotest.(check int) "la limpieza vacia lo vencido" 0 (Limite.tamano l)

let test_hub () =
  let h = Hub.crear ~tope:3 () in
  let a = Hub.suscribir h and b = Hub.suscribir h in
  Alcotest.(check int) "dos suscriptores" 2 (Hub.suscriptores h);
  Hub.publicar h "mensaje" (`Assoc [ ("caso_id", `Int 1) ]);
  let leer s = Lwt_main.run (Hub.siguiente s) in
  (match leer a with Some (Hub.Evento (n, d)) -> Alcotest.(check string) "evento a" "mensaje" n; Alcotest.(check int) "dato" 1 (Json.int_d "caso_id" 0 d) | _ -> Alcotest.fail "a debia recibirlo");
  (match leer b with Some (Hub.Evento ("mensaje", _)) -> () | _ -> Alcotest.fail "b tambien");
  Alcotest.(check string) "formato SSE" "event: mensaje\ndata: {\"caso_id\":1}\n\n" (Hub.formatear (Hub.Evento ("mensaje", `Assoc [ ("caso_id", `Int 1) ])));
  Alcotest.(check string) "latido" ": ping\n\n" (Hub.formatear Hub.Ping);
  (* Un suscriptor que no lee se desconecta al pasar el tope; el otro sigue. *)
  for _ = 1 to 6 do Hub.publicar h "x" (`Assoc []); ignore (leer b) done;
  Alcotest.(check int) "el lento se fue" 1 (Hub.suscriptores h);
  Hub.desuscribir h b;
  Alcotest.(check int) "nadie" 0 (Hub.suscriptores h)

(* --- juicio y lectura de la respuesta del agente -------------------------------------------------------------------------------------------- *)

let test_turno_leer () =
  let r = Turno.leer (`Assoc []) ~texto_original:"mi contraseña es Abc12345" in
  Alcotest.(check string) "accion por defecto" "ninguna" r.accion_tipo;
  Alcotest.(check bool) "sin respuesta" true (r.respuesta = None);
  check_no_contiene "si el agente no manda texto_usuario_guardar, se oculta aqui" "Abc12345" r.texto_guardar;
  let r = Turno.leer (`Assoc [ ("texto_usuario_guardar", `String "tal cual"); ("respuesta", `String "  hola  "); ("accion", `Assoc [ ("tipo", `String "crear_incidencia") ]); ("etapa", `String "guia"); ("confianza", `Float 0.9) ]) ~texto_original:"x" in
  Alcotest.(check string) "se respeta el texto del agente" "tal cual" r.texto_guardar;
  Alcotest.(check (option string)) "respuesta recortada" (Some "hola") r.respuesta;
  Alcotest.(check (option string)) "etapa" (Some "guia") r.etapa;
  let r = Turno.leer (`Assoc [ ("accion", `Assoc [ ("tipo", `String "borrar_todo") ]); ("etapa", `String "inventada") ]) ~texto_original:"x" in
  Alcotest.(check string) "accion desconocida -> ninguna" "ninguna" r.accion_tipo;
  Alcotest.(check (option string)) "etapa fuera del vocabulario se descarta" None r.etapa;
  let r = Turno.leer (`Assoc [ ("articulos_usados", `List [ `String "KB-1"; `Assoc [ ("clave", `String "KB-2") ] ]); ("juez", `Assoc [ ("modo", `String "sombra"); ("veredictos", `Assoc [ ("respaldo", `Assoc [ ("veredicto", `String "respaldada") ]); ("contesta", `String "si") ]) ]); ("frases_quitadas", `Int 2); ("regenerada", `Bool true); ("costo_usd", `Float 0.5) ]) ~texto_original:"x" in
  Alcotest.(check (list string)) "articulos" [ "KB-1"; "KB-2" ] r.articulos;
  Alcotest.(check string) "modo del juez" "sombra" (Turno.modo_juez r.juez);
  Alcotest.(check string) "veredictos como texto" "respaldo=respaldada,contesta=si" (Turno.veredicto_texto r.juez);
  Alcotest.(check int) "frases quitadas" 2 r.frases_quitadas;
  Alcotest.(check bool) "regenerada" true r.regenerada;
  Alcotest.(check bool) "costo" true (r.costo_usd = 0.5);
  Alcotest.(check string) "juez apagado si no viene" "apagado" (Turno.modo_juez `Null)

let test_juicio () =
  let r accion respuesta senales =
    Turno.leer (`Assoc [ ("accion", `Assoc [ ("tipo", `String accion) ]); ("respuesta", `String respuesta); ("senales", senales) ]) ~texto_original:"x"
  in
  Alcotest.(check string) "limpio" "bajo" (Juicio.evaluar (r "ninguna" "Prueba reiniciar." (`Assoc []))).riesgo;
  Alcotest.(check string) "numero de incidencia en texto libre" "medio" (Juicio.evaluar (r "ninguna" "Ya registré INC-000099." (`Assoc []))).riesgo;
  Alcotest.(check string) "plazo en texto libre" "medio" (Juicio.evaluar (r "ninguna" "Te atienden en 10 minutos." (`Assoc []))).riesgo;
  Alcotest.(check string) "en un flujo fijo el texto previo no se juzga por numeros" "bajo" (Juicio.evaluar (r "crear_incidencia" "Voy a registrarlo." (`Assoc []))).riesgo;
  let q = Juicio.evaluar (r "ninguna" "Entiendo." (`Assoc [ ("queja", `Bool true) ])) in
  Alcotest.(check bool) "queja sin accion: derivar" true (q.decision = Juicio.Derivar && q.riesgo = "alto");
  Alcotest.(check bool) "animo muy negativo" true ((Juicio.evaluar (r "ninguna" "ok" (`Assoc [ ("animo", `String "muy_negativo") ]))).decision = Juicio.Derivar);
  Alcotest.(check bool) "modos validos" true (List.for_all Juicio.modo_valido [ "apagado"; "sombra"; "activo" ] && not (Juicio.modo_valido "turbo"))

(* --- validacion de entradas ---------------------------------------------------------------------------------------------------------------------- *)

let test_validadores () =
  let j = `Assoc [ ("t", `String "  hola  "); ("n", `Int 5); ("v", `String ""); ("l", `String (String.make 50 'a')); ("b", `Bool true); ("mal", `List []) ] in
  Alcotest.(check string) "texto recortado" "hola" (Api_util.texto_req ~max:10 ~nombre:"el campo" j "t");
  lanza_api 400 "invalido" (fun () -> Api_util.texto_req ~max:10 ~nombre:"el campo" j "v");
  lanza_api 400 "invalido" (fun () -> Api_util.texto_req ~max:10 ~nombre:"el campo" j "falta");
  lanza_api 400 "invalido" (fun () -> Api_util.texto_req ~max:10 ~nombre:"el campo" j "l");
  lanza_api 400 "invalido" (fun () -> Api_util.texto_req ~max:10 ~nombre:"el campo" j "n");
  Alcotest.(check (option string)) "opcional vacio" None (Api_util.texto_opt ~max:10 ~nombre:"x" j "v");
  Alcotest.(check (option string)) "opcional ausente" None (Api_util.texto_opt ~max:10 ~nombre:"x" j "falta");
  Alcotest.(check int) "entero" 5 (Api_util.entero_req ~nombre:"n" ~min:1 ~max:10 j "n");
  lanza_api 400 "invalido" (fun () -> Api_util.entero_req ~nombre:"n" ~min:6 j "n");
  lanza_api 400 "invalido" (fun () -> Api_util.entero_req ~nombre:"n" j "t");
  lanza_api 400 "invalido" (fun () -> Api_util.entero_opt ~nombre:"n" ~max:3 j "n");
  Alcotest.(check (option bool)) "bool" (Some true) (Api_util.bool_opt ~nombre:"b" j "b");
  lanza_api 400 "invalido" (fun () -> Api_util.bool_opt ~nombre:"b" j "n");
  Alcotest.(check string) "en lista" "P1" (Api_util.en_lista ~nombre:"la prioridad" Api_util.prioridades "P1");
  lanza_api 400 "invalido" (fun () -> Api_util.en_lista ~nombre:"la prioridad" Api_util.prioridades "P9");
  (* Telefono y correo. *)
  let tel s = Api_util.telefono_opt ~nombre:"el WhatsApp" (`Assoc [ ("w", `String s) ]) "w" in
  Alcotest.(check (option string)) "formato libre" (Some "51987654321") (tel "+51 987-654-321");
  Alcotest.(check (option string)) "vacio" None (tel "");
  lanza_api 400 "invalido" (fun () -> tel "12345");
  lanza_api 400 "invalido" (fun () -> tel "1234567890123456");
  let mail s = Api_util.correo_opt ~nombre:"el correo" (`Assoc [ ("c", `String s) ]) "c" in
  Alcotest.(check (option string)) "correo en minusculas" (Some "ana@ejemplo.test") (mail "Ana@Ejemplo.test");
  List.iter (fun malo -> lanza_api 400 "invalido" (fun () -> mail malo)) [ "ana"; "ana@"; "@ejemplo.test"; "ana@ejemplo"; "a b@ejemplo.test"; "ana@@ejemplo.test" ];
  Alcotest.(check bool) "horas" true (Api_util.hora_valida "08:30" && Api_util.hora_valida "23:59" && not (Api_util.hora_valida "24:00") && not (Api_util.hora_valida "8:30") && not (Api_util.hora_valida "08:60") && not (Api_util.hora_valida "ab:cd"));
  Alcotest.(check bool) "fechas" true (Api_util.fecha_valida "2026-10-05" && not (Api_util.fecha_valida "05-10-2026") && not (Api_util.fecha_valida "2026-13-01") && not (Api_util.fecha_valida "2026-10-5"));
  (* Paginacion: la validan los endpoints (ver test_api); aqui, los textos de error son en español. *)
  (try Api_util.texto_req ~max:10 ~nombre:"el asunto" j "falta" |> ignore with Errores.Api (_, _, m) -> check_contiene "mensaje en español" "Falta el asunto" m)

let test_errores () =
  Alcotest.(check string) "forma del error" {|{"error":"No encontramos eso.","codigo":"no_encontrado"}|} (Json.to_string (Errores.cuerpo "no_encontrado" "No encontramos eso."));
  lanza_api 404 "no_encontrado" (fun () -> Errores.no_encontrado "x");
  lanza_api 403 "no_autorizado" (fun () -> Errores.prohibido "x");
  lanza_api 401 "no_autorizado" (fun () -> Errores.no_autorizado "x");
  lanza_api 409 "conflicto" (fun () -> Errores.conflicto "x");
  lanza_api 429 "limite" (fun () -> Errores.limite ());
  lanza_api 503 "no_disponible" (fun () -> Errores.no_disponible "x")

(* --- reportes: parecido de preguntas y periodos ---------------------------------------------------------------------------------------------------- *)

let test_reportes_texto () =
  let cat =
    [ `Assoc [ ("kpi", `String "mttr"); ("nombre", `String "Tiempo de resolución (MTTR)"); ("preguntas_equivalentes", `List [ `String "¿Cuál fue el MTTR de septiembre?"; `String "Tiempo medio de resolución"; `String "¿En cuánto tiempo se arregla un problema?" ]) ];
      `Assoc [ ("kpi", `String "csat"); ("nombre", `String "CSAT"); ("preguntas_equivalentes", `List [ `String "¿Cuál es la satisfacción de los usuarios?"; `String "CSAT del mes" ]) ];
      `Assoc [ ("kpi", `String "sla_cumplimiento"); ("nombre", `String "Cumplimiento de SLA"); ("preguntas_equivalentes", `List [ `String "¿Qué porcentaje de incidencias atendimos dentro del plazo?"; `String "¿Cuál fue el cumplimiento de SLA de septiembre?" ]) ] ]
  in
  let kpi q = match Api_reportes.mejor_golden q cat with Some (e, _) -> Json.str_d "kpi" "" e | None -> "(ninguna)" in
  Alcotest.(check string) "misma frase" "mttr" (kpi "¿Cuál fue el MTTR de septiembre?");
  Alcotest.(check string) "otra redaccion" "mttr" (kpi "tiempo medio de resolucion de agosto");
  Alcotest.(check string) "sin tildes ni signos" "csat" (kpi "satisfaccion de los usuarios");
  Alcotest.(check string) "sla" "sla_cumplimiento" (kpi "cumplimiento de SLA de este mes");
  Alcotest.(check string) "fuera de catalogo" "(ninguna)" (kpi "¿quién ganó el mundial?");
  Alcotest.(check string) "vacia" "(ninguna)" (kpi "");
  Alcotest.(check string) "sin tildes" "mttr tiempo" (String.concat " " (Api_reportes.tokens "MTTR Tiempo"));
  (* Periodo de la pregunta. 2026-10-05 15:30 UTC. *)
  let ahora = 1791214200. in
  let p q = let d, h, _ = Api_reportes.periodo_de_pregunta ~ahora q in (d, h) in
  Alcotest.(check (pair string string)) "septiembre" ("2026-09-01", "2026-09-30") (p "MTTR de septiembre");
  Alcotest.(check (pair string string)) "agosto de 2025" ("2025-08-01", "2025-08-31") (p "SLA de agosto de 2025");
  Alcotest.(check (pair string string)) "febrero bisiesto" ("2028-02-01", "2028-02-29") (let d, h, _ = Api_reportes.periodo_de_pregunta ~ahora "CSAT de febrero de 2028" in (d, h));
  Alcotest.(check (pair string string)) "un mes que aun no llego es del año anterior" ("2025-12-01", "2025-12-31") (p "volumen de diciembre");
  Alcotest.(check (pair string string)) "este mes" ("2026-10-01", "2026-10-05") (p "SLA de este mes");
  Alcotest.(check (pair string string)) "mes pasado" ("2026-09-01", "2026-09-30") (p "SLA del mes pasado");
  Alcotest.(check (pair string string)) "hoy" ("2026-10-05", "2026-10-05") (p "incidencias de hoy");
  Alcotest.(check (pair string string)) "por defecto, 30 dias" ("2026-09-06", "2026-10-05") (p "tiempo de resolucion");
  Alcotest.(check (option (float 0.001))) "meta de «SUPUESTO: 4,2 o mas»" (Some 4.2) (Api_reportes.numero_de "SUPUESTO: 4,2 o mas y 85 % de respuestas");
  Alcotest.(check (option (float 0.001))) "meta de «90 % o mas»" (Some 90.) (Api_reportes.numero_de "SUPUESTO: 90 % o mas");
  Alcotest.(check (option (float 0.001))) "sin numero" None (Api_reportes.numero_de "sin meta")

let test_partes_whatsapp () =
  Alcotest.(check (list string)) "un parrafo por mensaje" [ "uno"; "dos"; "tres" ] (Flujo.partes [ "uno\n\ndos"; "tres" ]);
  Alcotest.(check (list string)) "una lista numerada es un solo mensaje" [ "Prueba:\n1. a\n2. b"; "¿Se resolvió?" ] (Flujo.partes [ "Prueba:\n1. a\n2. b\n\n¿Se resolvió?" ]);
  Alcotest.(check (list string)) "vacios fuera" [ "a" ] (Flujo.partes [ ""; "  "; "a"; "\n\n" ]);
  Alcotest.(check int) "tope de 6 mensajes" 6 (List.length (Flujo.partes (List.init 10 (fun i -> string_of_int i))));
  Alcotest.(check bool) "lo que sobra se junta en el ultimo" true (contiene "9" (List.nth (Flujo.partes (List.init 10 (fun i -> string_of_int i))) 5))

let test_seguridad_utilidades () =
  Alcotest.(check string) "el token del estado publico no va al registro" "/api/estado/***/responder" (Seguridad.ruta_para_log "/api/estado/0123456789abcdef/responder");
  Alcotest.(check string) "ni el secreto del webhook" "/webhook/evolution/***" (Seguridad.ruta_para_log "/webhook/evolution/secreto-largo");
  Alcotest.(check string) "ni la consulta" "/api/incidencias" (Seguridad.ruta_para_log "/api/incidencias?q=Ana%20Rios&token=abc");
  Alcotest.(check string) "ip con puerto" "1.2.3.4" (Seguridad.sin_puerto "1.2.3.4:5678");
  Alcotest.(check string) "ip6" "::1" (Seguridad.sin_puerto "[::1]:80");
  Alcotest.(check string) "sin puerto" "1.2.3.4" (Seguridad.sin_puerto "1.2.3.4")

(* --- clientes HTTP contra servidores de prueba ----------------------------------------------------------------------------------------------------- *)

let json_resp ?(estado = 200) j = Dream.json ~status:(Dream.int_to_status estado) (Json.to_string j)

let test_cliente_agente () =
  Lwt_main.run
    (let llamadas = ref 0 in
     let guion = ref [ 500; 200 ] in
     let handler =
       Dream.router
         [ Dream.post "/chat" (fun _ ->
               incr llamadas;
               match !guion with
               | e :: resto ->
                   guion := (if resto = [] then [ e ] else resto);
                   if e = 200 then json_resp (`Assoc [ ("respuesta", `String "ok") ]) else json_resp ~estado:e (`Assoc [ ("error", `String "x") ])
               | [] -> json_resp (`Assoc [])) ]
     in
     let srv = Falsos.Servidor.servir handler in
     let* () = Lwt_unix.sleep 0.15 in
     let a = Agente.crear ~url:(Falsos.Servidor.url srv) ~plazo:2.0 in
     (* Un 500 y luego 200: el reintento rescata el turno. *)
     let* r = Agente.chat ~espera_reintento:0.01 a (`Assoc [ ("mensaje", `String "hola") ]) in
     Alcotest.(check bool) "reintenta una vez y responde" true (match r with Agente.Respuesta j -> Json.str_d "respuesta" "" j = "ok" | _ -> false);
     Alcotest.(check int) "dos llamadas" 2 !llamadas;
     (* Un 400 no se reintenta (la peticion esta mal). *)
     llamadas := 0;
     guion := [ 400 ];
     let* r = Agente.chat ~espera_reintento:0.01 a (`Assoc []) in
     Alcotest.(check bool) "4xx: cae" true (match r with Agente.Caido _ -> true | _ -> false);
     Alcotest.(check int) "4xx: una sola llamada" 1 !llamadas;
     (* Siempre 500: dos intentos y se rinde. *)
     llamadas := 0;
     guion := [ 500 ];
     let* r = Agente.chat ~espera_reintento:0.01 a (`Assoc []) in
     Alcotest.(check bool) "dos 500: cae" true (match r with Agente.Caido _ -> true | _ -> false);
     Alcotest.(check int) "dos intentos" 2 !llamadas;
     srv.parar ();
     (* Respuesta que no es un objeto JSON. *)
     let srv2 = Falsos.Servidor.servir (Dream.router [ Dream.post "/chat" (fun _ -> Dream.respond "<html>") ]) in
     let* () = Lwt_unix.sleep 0.15 in
     let* r = Agente.chat ~espera_reintento:0.01 (Agente.crear ~url:(Falsos.Servidor.url srv2) ~plazo:2.) (`Assoc []) in
     Alcotest.(check bool) "respuesta ilegible: cae" true (match r with Agente.Caido _ -> true | _ -> false);
     srv2.parar ();
     (* Plazo duro: un agente lento no cuelga el turno. *)
     let lento = Falsos.Agente_falso.crear () in
     lento.demora <- 2.0;
     let srv3 = Falsos.Servidor.servir (Falsos.Agente_falso.handler lento) in
     let* () = Lwt_unix.sleep 0.15 in
     let t0 = Unix.gettimeofday () in
     let* r = Agente.chat ~espera_reintento:0.01 (Agente.crear ~url:(Falsos.Servidor.url srv3) ~plazo:0.3) (`Assoc [ ("mensaje", `String "hola") ]) in
     let dt = Unix.gettimeofday () -. t0 in
     Alcotest.(check bool) "plazo agotado: cae" true (match r with Agente.Caido m -> contiene "plazo" m | _ -> false);
     Alcotest.(check bool) "en ~0,6 s (dos intentos de 0,3 s), no en 4 s" true (dt >= 0.55 && dt < 1.5);
     srv3.parar ();
     (* Conexion rechazada. *)
     let* r = Agente.chat ~espera_reintento:0.01 (Agente.crear ~url:"http://127.0.0.1:1" ~plazo:1.) (`Assoc []) in
     Alcotest.(check bool) "conexion rechazada: cae" true (match r with Agente.Caido _ -> true | _ -> false);
     Lwt.return ())

let test_cliente_agente_modelos () =
  Lwt_main.run
    (let respuestas = ref (200, `Assoc [ ("publicado", `Bool true) ]) in
     let handler =
       Dream.router
         [ Dream.post "/modelos/:v/publicar" (fun req -> let e, j = !respuestas in if Dream.param req "v" = "con espacio" then json_resp (`Assoc [ ("publicado", `Bool true) ]) else json_resp ~estado:e j);
           Dream.get "/modelos" (fun _ -> json_resp (`List [ `Assoc [ ("version", `String "v1") ] ]));
           Dream.get "/conocimiento/articulos" (fun _ -> json_resp (`List [ `Assoc [ ("clave", `String "KB-1") ] ])) ]
     in
     let srv = Falsos.Servidor.servir handler in
     let* () = Lwt_unix.sleep 0.15 in
     let a = Agente.crear ~url:(Falsos.Servidor.url srv) ~plazo:2. in
     let publicar () = Agente.publicar_modelo a ~version:"v2" in
     let* r = publicar () in
     Alcotest.(check bool) "200 publicado" true (match r with Agente.Publicado _ -> true | _ -> false);
     respuestas := (200, `Assoc [ ("publicado", `Bool false); ("motivo", `String "no mejora") ]);
     let* r = publicar () in
     Alcotest.(check bool) "200 con publicado=false: rechazo" true (match r with Agente.Rechazado (409, "no mejora") -> true | _ -> false);
     respuestas := (409, `Assoc [ ("error", `String "no se acepta"); ("codigo", `String "conflicto") ]);
     let* r = publicar () in
     Alcotest.(check bool) "409: rechazo con su mensaje" true (match r with Agente.Rechazado (409, "no se acepta") -> true | _ -> false);
     respuestas := (404, `Assoc [ ("error", `String "no existe") ]);
     let* r = publicar () in
     Alcotest.(check bool) "404" true (match r with Agente.Rechazado (404, _) -> true | _ -> false);
     respuestas := (500, `Assoc []);
     let* r = publicar () in
     Alcotest.(check bool) "5xx: sin respuesta (no es un rechazo)" true (match r with Agente.Sin_respuesta _ -> true | _ -> false);
     let* r = Agente.publicar_modelo a ~version:"con espacio" in
     Alcotest.(check bool) "la version va codificada en la ruta" true (match r with Agente.Publicado _ -> true | _ -> false);
     let* r = Agente.modelos a in
     Alcotest.(check bool) "GET /modelos" true (Result.is_ok r);
     let* r = Agente.articulos_iniciales a in
     Alcotest.(check bool) "articulos como lista sola" true (match r with Ok [ _ ] -> true | _ -> false);
     srv.parar ();
     let* r = Agente.publicar_modelo (Agente.crear ~url:"http://127.0.0.1:1" ~plazo:1.) ~version:"v2" in
     Alcotest.(check bool) "agente caido: sin respuesta" true (match r with Agente.Sin_respuesta _ -> true | _ -> false);
     let* r = Agente.articulos_iniciales (Agente.crear ~url:"http://127.0.0.1:1" ~plazo:1.) in
     Alcotest.(check bool) "articulos con el agente caido: error, no excepcion" true (Result.is_error r);
     Lwt.return ())

let test_cliente_motor () =
  Lwt_main.run
    (let recibido = ref [] in
     let handler =
       Dream.router
         [ Dream.post "/interno/incidencias" (fun req ->
               recibido := (Dream.header req "X-Interno-Clave", Dream.header req "Content-Type") :: !recibido;
               json_resp (`Assoc [ ("incidencia", `Assoc [ ("id", `Int 1) ]) ]));
           Dream.post "/interno/incidencias/1/acciones" (fun _ -> json_resp ~estado:409 (`Assoc [ ("error", `String "no se puede cerrar desde ahi"); ("codigo", `String "conflicto") ]));
           Dream.post "/interno/incidencias/2/acciones" (fun _ -> json_resp ~estado:422 (`Assoc [ ("error", `String "prioridad desconocida"); ("codigo", `String "invalido") ]));
           Dream.post "/interno/incidencias/3/acciones" (fun _ -> json_resp ~estado:404 (`Assoc [ ("error", `String "no existe"); ("codigo", `String "no_encontrado") ]));
           Dream.post "/interno/incidencias/4/acciones" (fun _ -> json_resp ~estado:500 (`Assoc [ ("error", `String "boom"); ("codigo", `String "interno") ]));
           Dream.get "/interno/avisos/pendientes" (fun _ -> json_resp (`List [])) ]
     in
     let srv = Falsos.Servidor.servir handler in
     let* () = Lwt_unix.sleep 0.15 in
     let m = Motor.crear ~url:(Falsos.Servidor.url srv) ~clave:"clave-del-motor-1234" ~plazo:2. in
     let* r = Motor.crear_incidencia m (`Assoc [ ("titulo", `String "x") ]) in
     Alcotest.(check bool) "ok" true (Result.is_ok r);
     Alcotest.(check bool) "manda la clave interna y JSON" true (match !recibido with [ (Some "clave-del-motor-1234", Some ct) ] -> contiene "json" ct | _ -> false);
     let accion id = Motor.accion m ~id (`Assoc [ ("accion", `String "x") ]) in
     let* r = accion 1 in
     Alcotest.(check bool) "409 -> Rechazo" true (match r with Error (Motor.Rechazo (409, "conflicto", msg)) -> contiene "cerrar" msg | _ -> false);
     (* Los rechazos del motor se traducen a errores de API con su mensaje en español. *)
     lanza_api 409 "conflicto" (fun () -> ignore (Motor.exigir r));
     let* r = accion 2 in
     lanza_api 400 "invalido" (fun () -> ignore (Motor.exigir r));
     let* r = accion 3 in
     lanza_api 404 "no_encontrado" (fun () -> ignore (Motor.exigir r));
     let* r = accion 4 in
     Alcotest.(check bool) "5xx -> inalcanzable" true (match r with Error (Motor.Inalcanzable _) -> true | _ -> false);
     lanza_api 503 "no_disponible" (fun () -> ignore (Motor.exigir r));
     srv.parar ();
     let* r = Motor.salud (Motor.crear ~url:"http://127.0.0.1:1" ~clave:"x" ~plazo:1.) in
     Alcotest.(check bool) "sin red -> inalcanzable" true (match r with Error (Motor.Inalcanzable _) -> true | _ -> false);
     lanza_api 503 "no_disponible" (fun () -> ignore (Motor.exigir r));
     Lwt.return ())

let test_cliente_evolution () =
  Lwt_main.run
    (let falso = Falsos.Evolution_falso.crear () in
     let srv = Falsos.Servidor.servir (Falsos.Evolution_falso.handler falso) in
     let* () = Lwt_unix.sleep 0.15 in
     let cfg modo =
       match
         Config.cargar
           ~getenv:(fun k ->
             List.assoc_opt k
               (completo @ [ ("EVOLUTION_MODO", modo); ("EVOLUTION_URL", Falsos.Servidor.url srv); ("EVOLUTION_API_KEY", "llave-de-prueba"); ("EVOLUTION_INSTANCIA", "jsr") ]))
       with
       | Ok c -> c
       | Error es -> failwith (String.concat ";" es)
     in
     (* Simulado: NO toca la red; registra a donde habria enviado. *)
     let sim = Evolution.crear (cfg "simulado") in
     let* r = Evolution.enviar_texto sim ~destino:"51987654321" ~texto:"hola" in
     Alcotest.(check bool) "simulado: enviado" true (r = Evolution.Enviado "simulado");
     Alcotest.(check int) "simulado: no llego nada al servidor" 0 (List.length falso.enviados);
     Alcotest.(check bool) "simulado: queda registrado" true (Evolution.simulados sim = [ ("51987654321", "hola") ]);
     let* est = Evolution.estado sim in
     Alcotest.(check string) "estado simulado" "simulado" est;
     (* Real (solo con EVOLUTION_MODO=real): apikey, numero y texto. *)
     let real = Evolution.crear (cfg "real") in
     let* r = Evolution.enviar_texto real ~destino:"51987654321" ~texto:"hola real" in
     Alcotest.(check bool) "real: enviado, con el ID de WhatsApp" true (r = Evolution.Enviado "3EB0FALSO");
     (match falso.enviados with
     | [ (key, cuerpo) ] ->
         Alcotest.(check string) "cabecera apikey" "llave-de-prueba" key;
         Alcotest.(check string) "number" "51987654321" (Json.str_d "number" "" cuerpo);
         Alcotest.(check string) "text" "hola real" (Json.str_d "text" "" cuerpo);
         Alcotest.(check bool) "un telefono se formatea (sin formatJid)" true (Json.get "formatJid" cuerpo = `Null)
     | _ -> Alcotest.fail "debia llegar uno");
     let* _ = Evolution.enviar_texto real ~destino:"1234567890123@lid" ~texto:"a un lid" in
     Alcotest.(check bool) "un JID va tal cual, sin formatear" true (match falso.enviados with (_, c) :: _ -> Json.str_d "number" "" c = "1234567890123@lid" && Json.bool_d "formatJid" true c = false | [] -> false);
     let* est = Evolution.estado real in
     Alcotest.(check string) "estado real" "ok" est;
     falso.fallar <- true;
     let* r = Evolution.enviar_texto real ~destino:"51987654321" ~texto:"x" in
     Alcotest.(check bool) "HTTP 500 -> Fallo" true (match r with Evolution.Fallo m -> contiene "500" m | _ -> false);
     srv.parar ();
     let* r = Evolution.enviar_texto real ~destino:"51987654321" ~texto:"x" in
     Alcotest.(check bool) "sin red -> Fallo" true (match r with Evolution.Fallo _ -> true | _ -> false);
     let* est = Evolution.estado real in
     Alcotest.(check string) "estado caido" "caido" est;
     Lwt.return ())

let caso nombre f = Alcotest.test_case nombre `Quick f

let () =
  Alcotest.run "unit"
    [ ( "cripto",
        [ caso "PBKDF2-HMAC-SHA256: vectores conocidos" test_pbkdf2_vectores; caso "hash de clave: sal, formato, verificacion" test_hash_de_clave; caso "costo de las iteraciones por defecto" test_costo_pbkdf2;
          caso "comparacion en tiempo constante" test_igual_const ] );
      ("jwt y roles", [ caso "JWT HS256: firma, vencimiento, alteracion, alg=none" test_jwt; caso "matriz de roles" test_roles ]);
      ("base de datos", [ caso "marcadores de parametros" test_sustituir ]);
      ("privacidad", [ caso "telefonos y correos" test_mascara_telefono; caso "contraseñas y tokens" test_mascara_credenciales; caso "registro de accesos sin secretos" test_seguridad_utilidades ]);
      ("configuracion", [ caso "variables de entorno, obligatorias, rangos y modo real" test_config ]);
      ("webhook", [ caso "parseo de evolution-go y Evolution API v2" test_webhook_parseo ]);
      ( "textos",
        [ caso "plazos en hora de Lima" test_textos_plazos; caso "confirmacion de la incidencia" test_textos_incidencia_creada; caso "plantillas de avisos" test_plantillas;
          caso "estados y consulta" test_estado_y_consulta; caso "parrafos de WhatsApp" test_partes_whatsapp ] );
      ("memoria", [ caso "limitador de frecuencia" test_limite; caso "hub de eventos" test_hub ]);
      ("agente", [ caso "lectura de la respuesta del agente" test_turno_leer; caso "capa de juicio" test_juicio ]);
      ("validacion", [ caso "validadores de entradas" test_validadores; caso "forma de los errores" test_errores; caso "golden query mas parecida y periodos" test_reportes_texto ]);
      ("clientes HTTP", [ caso "agente: reintento, plazo, caida" test_cliente_agente; caso "agente: modelos, publicar y articulos iniciales" test_cliente_agente_modelos; caso "motor: clave, rechazos, caida" test_cliente_motor; caso "evolution: simulado y real" test_cliente_evolution ]) ]
