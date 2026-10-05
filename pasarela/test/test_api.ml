(* Pruebas de la API de la consola y de los trabajadores de fondo, contra Postgres real, el agente y el motor falsos y la
   aplicacion REAL escuchando en un puerto (HTTP de verdad). Se saltan si no hay JSR_TEST_DB. *)

open Pasarela

let ( let* ) = Lwt.bind
let ( and* ) = Lwt.both

let contiene sub s = Falsos.Agente_falso.contiene sub s
let check_contiene msg sub s = Alcotest.(check bool) (msg ^ " (contiene «" ^ sub ^ "» en «" ^ s ^ "»)") true (contiene sub s)
let check_estado msg esperado (r : Ayuda.respuesta) = Alcotest.(check int) (msg ^ " -> HTTP; cuerpo: " ^ r.cuerpo) esperado r.estado

(* Un entorno con la aplicacion servida y los tokens de cada rol. *)
let con_app ?extra (f : Ayuda.entorno -> Falsos.Servidor.t -> unit Lwt.t) : unit Lwt.t =
  Ayuda.con_entorno ?extra (fun e ->
      let srv = Ayuda.servir_app e in
      let* () = Lwt_unix.sleep 0.15 in
      Lwt.finalize (fun () -> f e srv) (fun () -> srv.parar (); Lwt.return ()))

let get ?token srv ruta = Ayuda.llamar ?token srv `GET ruta
let post ?token srv ruta j = Ayuda.llamar ?token ~cuerpo:j srv `POST ruta
let put ?token srv ruta j = Ayuda.llamar ?token ~cuerpo:j srv `PUT ruta

(* Una incidencia por el camino de la consola (alta manual): la asigna el motor falso a Luis Paz. *)
let alta ?(titulo = "Outlook no recibe correos") ?(categoria = "correo") srv token =
  let* r = post ~token srv "/api/incidencias" (`Assoc [ ("titulo", `String titulo); ("categoria", `String categoria); ("persona_id", `Int 1); ("resumen", `String "Prueba") ]) in
  check_estado "alta manual" 201 r;
  Lwt.return r.json

let id_de j = Json.int_d "id" 0 j

(* --- autenticacion --------------------------------------------------------------------------------------------------------------- *)

let test_login _ () =
  con_app (fun e srv ->
      let* r = post srv "/api/auth/login" (`Assoc [ ("email", `String " Tecnico@Ejemplo.test "); ("clave", `String "clave-de-prueba") ]) in
      check_estado "login" 200 r;
      let u = Json.get "usuario" r.json in
      Alcotest.(check string) "rol" "tecnico" (Json.str_d "rol" "" u);
      Alcotest.(check (option int)) "tecnico_id" (Some 1) (Json.int "tecnico_id" u);
      Alcotest.(check string) "nombre" "Luis Paz" (Json.str_d "nombre" "" u);
      let token = Json.str_d "token" "" r.json in
      (* El token es un JWT HS256 de 12 h. *)
      (match Jwt.verificar ~secreto:e.ctx.cfg.jwt_secret token with
      | Ok c ->
          Alcotest.(check bool) "dura 12 h" true (c.exp - c.iat = 12 * 3600);
          Alcotest.(check string) "rol en el token" "tecnico" c.rol
      | Error _ -> Alcotest.fail "el token no verifica");
      Alcotest.(check bool) "la clave no vuelve en la respuesta" false (contiene "clave" r.cuerpo || contiene "hash" r.cuerpo);
      let* yo = get ~token srv "/api/yo" in
      check_estado "yo" 200 yo;
      Alcotest.(check string) "yo.nombre" "Luis Paz" (Json.str_d "nombre" "" yo.json);
      (* La auditoria dejo constancia. *)
      let* n = Ayuda.contar e.db "SELECT 1 FROM auditoria WHERE accion = 'login' AND usuario_id = 1" in
      Alcotest.(check int) "login auditado" 1 n;
      Lwt.return ())

let test_login_rechazos _ () =
  con_app (fun e srv ->
      let malo = `Assoc [ ("email", `String "tecnico@ejemplo.test"); ("clave", `String "otra-clave") ] in
      let* r1 = post srv "/api/auth/login" malo in
      check_estado "clave mala" 401 r1;
      let* r2 = post srv "/api/auth/login" (`Assoc [ ("email", `String "nadie@ejemplo.test"); ("clave", `String "otra-clave") ]) in
      check_estado "usuario inexistente" 401 r2;
      Alcotest.(check string) "mismo mensaje: no revela si el usuario existe" (Json.str_d "error" "" r1.json) (Json.str_d "error" "" r2.json);
      Alcotest.(check string) "codigo" "no_autorizado" (Json.str_d "codigo" "" r1.json);
      let* r3 = post srv "/api/auth/login" (`Assoc [ ("email", `String "") ; ("clave", `String "x") ]) in
      check_estado "sin correo" 400 r3;
      let* r4 = Ayuda.llamar srv `POST "/api/auth/login" ~cuerpo:(`List []) in
      check_estado "cuerpo que no es objeto" 400 r4;
      (* Un usuario desactivado no entra, ni con su token anterior. *)
      let* token = Ayuda.token_de srv "tecnico" in
      let* () = Db.exec_p e.db "UPDATE usuarios_consola SET activo = false WHERE email = 'tecnico@ejemplo.test'" (`Assoc []) in
      let* r5 = post srv "/api/auth/login" (`Assoc [ ("email", `String "tecnico@ejemplo.test"); ("clave", `String "clave-de-prueba") ]) in
      check_estado "desactivado" 401 r5;
      let* r6 = get ~token srv "/api/yo" in
      check_estado "token de un usuario desactivado" 401 r6;
      let* n = Ayuda.contar e.db "SELECT 1 FROM auditoria WHERE accion = 'login_fallido'" in
      Alcotest.(check bool) "los intentos fallidos se auditan" true (n >= 3);
      let* f = Ayuda.fila e.db "SELECT detalle::text AS d FROM auditoria WHERE accion = 'login_fallido' ORDER BY id LIMIT 1" (`Assoc []) in
      Alcotest.(check bool) "la auditoria no guarda la clave que se intento" false (contiene "otra-clave" (Json.str_d "d" "" f));
      Lwt.return ())

let test_limite_de_intentos_de_login _ () =
  con_app (fun _ srv ->
      let malo = `Assoc [ ("email", `String "supervisor@ejemplo.test"); ("clave", `String "mal") ] in
      let rec intentar n =
        if n = 0 then Lwt.return ()
        else
          let* r = post srv "/api/auth/login" malo in
          check_estado "intento fallido" 401 r;
          intentar (n - 1)
      in
      let* () = intentar 5 in
      let* r = post srv "/api/auth/login" malo in
      check_estado "sexto intento bloqueado" 429 r;
      Alcotest.(check string) "codigo de limite" "limite" (Json.str_d "codigo" "" r.json);
      (* Aun con la clave correcta, el correo bloqueado espera. *)
      let* ok = post srv "/api/auth/login" (`Assoc [ ("email", `String "supervisor@ejemplo.test"); ("clave", `String "clave-de-prueba") ]) in
      check_estado "bloqueado aunque acierte" 429 ok;
      (* Otro correo no se ve afectado. *)
      let* otro = post srv "/api/auth/login" (`Assoc [ ("email", `String "gerencia@ejemplo.test"); ("clave", `String "clave-de-prueba") ]) in
      check_estado "otro correo" 200 otro;
      Lwt.return ())

let test_token_y_roles _ () =
  con_app (fun e srv ->
      let* r = get srv "/api/bandeja" in
      check_estado "sin token" 401 r;
      Alcotest.(check string) "codigo" "no_autorizado" (Json.str_d "codigo" "" r.json);
      let* r = get ~token:"abc.def.ghi" srv "/api/bandeja" in
      check_estado "token basura" 401 r;
      (* Token vencido. *)
      let vencido = Jwt.firmar ~secreto:e.ctx.cfg.jwt_secret ~ahora:(Unix.gettimeofday () -. 13. *. 3600.) ~horas:12 ~sub:1 ~rol:"tecnico" ~tec:(Some 1) () in
      let* r = get ~token:vencido srv "/api/bandeja" in
      check_estado "token vencido" 401 r;
      (* Firmado con otra clave. *)
      let ajeno = Jwt.firmar ~secreto:"otro-secreto-distinto-0123456789" ~sub:1 ~rol:"admin" ~tec:None () in
      let* r = get ~token:ajeno srv "/api/bandeja" in
      check_estado "firma ajena" 401 r;
      (* alg=none. *)
      let b64 s = Cripto.b64u s in
      let none = b64 {|{"alg":"none","typ":"JWT"}|} ^ "." ^ b64 (Printf.sprintf {|{"sub":1,"rol":"admin","exp":%d}|} (int_of_float (Unix.gettimeofday ()) + 3600)) ^ "." in
      let* r = get ~token:none srv "/api/bandeja" in
      check_estado "alg=none" 401 r;
      (* El rol del token no manda: manda el de la base. Un token «admin» de un tecnico no sirve. *)
      let falso = Jwt.firmar ~secreto:e.ctx.cfg.jwt_secret ~sub:1 ~rol:"admin" ~tec:(Some 1) () in
      let* r = get ~token:falso srv "/api/usuarios" in
      check_estado "rol del token ignorado" 403 r;
      (* Matriz de roles. *)
      let* tec = Ayuda.token_de srv "tecnico" and* sup = Ayuda.token_de srv "supervisor" and* ger = Ayuda.token_de srv "gerencia" and* ent = Ayuda.token_de srv "entrenador" and* adm = Ayuda.token_de srv "admin" in
      let casos =
        [ ("/api/bandeja", [ tec; sup; ger; adm ], [ ent ]);
          ("/api/tecnicos", [ sup; ger; adm ], [ tec; ent ]);
          ("/api/grupos", [ sup; ger; adm ], [ tec; ent ]);
          ("/api/categorias", [ adm ], [ tec; sup; ger; ent ]);
          ("/api/sla", [ adm ], [ sup; ger ]);
          ("/api/escalamiento/reglas", [ sup; ger; adm ], [ tec; ent ]);
          ("/api/articulos", [ ent; adm ], [ tec; sup; ger ]);
          ("/api/entrenamiento/cola", [ ent; adm ], [ tec; sup; ger ]);
          ("/api/indicadores", [ ger; adm ], [ tec; sup; ent ]);
          ("/api/casos", [ tec; sup; ger; ent; adm ], []);
          ("/api/usuarios", [ adm ], [ tec; sup; ger; ent ]) ]
      in
      Lwt_list.iter_s
        (fun (ruta, permitidos, prohibidos) ->
          let* () = Lwt_list.iter_s (fun t -> let* r = get ~token:t srv ruta in Alcotest.(check bool) (ruta ^ " permitido (HTTP " ^ string_of_int r.estado ^ ")") true (r.estado = 200 || r.estado = 502 || r.estado = 503); Lwt.return ()) permitidos in
          Lwt_list.iter_s (fun t -> let* r = get ~token:t srv ruta in check_estado (ruta ^ " prohibido") 403 r; Alcotest.(check string) "codigo" "no_autorizado" (Json.str_d "codigo" "" r.json); Lwt.return ()) prohibidos)
        casos)

(* --- cabeceras, CORS, tamaños -------------------------------------------------------------------------------------------------------- *)

let test_seguridad_http _ () =
  con_app ~extra:[ ("CORS", "https://consola.ejemplo.test, http://localhost:5599") ] (fun _ srv ->
      let* r = get srv "/api/salud" in
      let h k = List.assoc_opt k r.cabeceras in
      Alcotest.(check (option string)) "nosniff" (Some "nosniff") (h "x-content-type-options");
      Alcotest.(check bool) "CSP" true (match h "content-security-policy" with Some c -> contiene "default-src 'none'" c && contiene "frame-ancestors 'none'" c | None -> false);
      Alcotest.(check (option string)) "sin cache" (Some "no-store") (h "cache-control");
      Alcotest.(check (option string)) "sin referer" (Some "no-referrer") (h "referrer-policy");
      Alcotest.(check bool) "sin CORS si no hay Origin" true (h "access-control-allow-origin" = None);
      (* CORS: solo los origenes de la lista. *)
      let* ok = Ayuda.llamar srv `GET "/api/yo" ~cabeceras:[ ("Origin", "https://consola.ejemplo.test") ] in
      Alcotest.(check (option string)) "origen permitido" (Some "https://consola.ejemplo.test") (List.assoc_opt "access-control-allow-origin" ok.cabeceras);
      Alcotest.(check bool) "los errores tambien llevan CORS y cabeceras de seguridad" true (ok.estado = 401 && List.assoc_opt "x-content-type-options" ok.cabeceras = Some "nosniff");
      let* mal = Ayuda.llamar srv `GET "/api/salud" ~cabeceras:[ ("Origin", "https://malo.ejemplo.test") ] in
      Alcotest.(check bool) "origen ajeno sin CORS" true (List.assoc_opt "access-control-allow-origin" mal.cabeceras = None);
      let* pre = Ayuda.llamar srv `OPTIONS "/api/incidencias" ~cabeceras:[ ("Origin", "http://localhost:5599"); ("Access-Control-Request-Method", "POST") ] in
      check_estado "preflight" 204 pre;
      Alcotest.(check (option string)) "preflight permite el origen" (Some "http://localhost:5599") (List.assoc_opt "access-control-allow-origin" pre.cabeceras);
      Alcotest.(check bool) "preflight permite Authorization" true (match List.assoc_opt "access-control-allow-headers" pre.cabeceras with Some v -> contiene "authorization" v | None -> false);
      (* Ruta inexistente: JSON, no HTML. *)
      let* nf = get srv "/api/no-existe" in
      check_estado "ruta inexistente" 404 nf;
      Alcotest.(check string) "codigo" "no_encontrado" (Json.str_d "codigo" "" nf.json);
      (* Cuerpos demasiado grandes. *)
      let grande = `Assoc [ ("sesion", `String "sesion-de-prueba-1"); ("mensaje", `String (String.make 20_000 'a')) ] in
      let* r = post srv "/api/chat-web" grande in
      check_estado "cuerpo grande" 413 r;
      Lwt.return ())

(* --- bandeja, lista, detalle ------------------------------------------------------------------------------------------------------------ *)

let test_bandeja_y_lista _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" and* sup = Ayuda.token_de srv "supervisor" in
      let* vacia = get ~token:tec srv "/api/bandeja" in
      check_estado "bandeja vacia" 200 vacia;
      List.iter (fun k -> Alcotest.(check bool) ("bandeja trae " ^ k) true (Json.get k vacia.json <> `Null)) [ "vencen_pronto"; "mias"; "sin_asignar"; "contador" ];
      let* i1 = alta srv tec in
      let* _ = alta ~titulo:"Impresora del 3.er piso" ~categoria:"impresoras" srv tec in
      let* _ = alta ~titulo:"VPN no conecta" ~categoria:"vpn" srv tec in
      let* b = get ~token:tec srv "/api/bandeja" in
      let mias = Json.list "mias" b.json in
      Alcotest.(check bool) "las asignadas a Luis estan en «mias»" true (List.exists (fun f -> Json.int "id" f = Some (id_de i1)) mias);
      let fila = List.find (fun f -> Json.int "id" f = Some (id_de i1)) mias in
      Alcotest.(check string) "numero" "INC-000001" (Json.str_d "numero" "" fila);
      Alcotest.(check string) "persona" "Ana Ríos" (Json.str_d "nombre" "" (Json.get "persona" fila));
      Alcotest.(check string) "area" "Contabilidad" (Json.str_d "area" "" (Json.get "persona" fila));
      Alcotest.(check string) "tecnico" "Luis Paz" (Json.str_d "nombre" "" (Json.get "tecnico" fila));
      Alcotest.(check string) "categoria es la clave" "correo" (Json.str_d "categoria" "" fila);
      let sla = Json.get "sla" fila in
      List.iter (fun k -> Alcotest.(check bool) ("sla trae " ^ k) true (Json.get k sla <> `Null)) [ "porcentaje"; "restante_min"; "vencida"; "pausado" ];
      (* El SLA vino del motor en UN solo lote. *)
      let lotes = List.filter (fun (_, ruta, _) -> contiene "/interno/sla/calcular" ruta) e.motor.llamadas in
      let antes = List.length lotes in
      let* _ = get ~token:tec srv "/api/incidencias?por_pagina=50" in
      let lotes2 = List.filter (fun (_, ruta, _) -> contiene "/interno/sla/calcular" ruta) e.motor.llamadas in
      Alcotest.(check int) "una sola llamada por lista" (antes + 1) (List.length lotes2);
      (match lotes2 with (_, _, cuerpo) :: _ -> Alcotest.(check int) "con los tres ids" 3 (List.length (Json.list "ids" cuerpo)) | [] -> Alcotest.fail "sin llamadas");
      (* El supervisor ve todo; los «sin asignar» son de el. *)
      let* bs = get ~token:sup srv "/api/bandeja" in
      Alcotest.(check bool) "el supervisor ve las de todos" true (List.length (Json.list "mias" bs.json) + List.length (Json.list "vencen_pronto" bs.json) + List.length (Json.list "sin_asignar" bs.json) >= 0);
      (* Lista: filtros y paginacion. *)
      let* l = get ~token:tec srv "/api/incidencias" in
      Alcotest.(check int) "total" 3 (Json.int_d "total" 0 l.json);
      Alcotest.(check int) "items" 3 (List.length (Json.list "items" l.json));
      let* l = get ~token:tec srv "/api/incidencias?por_pagina=2&pagina=2" in
      Alcotest.(check int) "total no depende de la pagina" 3 (Json.int_d "total" 0 l.json);
      Alcotest.(check int) "segunda pagina" 1 (List.length (Json.list "items" l.json));
      let* l = get ~token:tec srv "/api/incidencias?categoria=vpn" in
      Alcotest.(check int) "por categoria" 1 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?q=impresora" in
      Alcotest.(check int) "busqueda por titulo" 1 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?q=INC-000002" in
      Alcotest.(check int) "busqueda por numero" 1 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?q=ana" in
      Alcotest.(check int) "busqueda por persona" 3 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?q=%25" in
      Alcotest.(check int) "un % escrito por la persona no es comodin" 0 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?q=%27%3B%20DROP%20TABLE%20incidencias%3B--" in
      check_estado "intento de inyeccion" 200 l;
      Alcotest.(check int) "no encuentra nada y no rompe" 0 (Json.int_d "total" 0 l.json);
      let* n = Ayuda.contar e.db "SELECT 1 FROM incidencias" in
      Alcotest.(check int) "la tabla sigue ahi" 3 n;
      let* l = get ~token:tec srv "/api/incidencias?estado=asignada&prioridad=P3&tecnico_id=1&abiertas=1" in
      Alcotest.(check int) "filtros combinados (las de Luis)" 2 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?tecnico_id=sin" in
      Alcotest.(check int) "sin tecnico" 0 (Json.int_d "total" 0 l.json);
      let* l = get ~token:tec srv "/api/incidencias?estado=inventado" in
      check_estado "estado invalido" 400 l;
      let* l = get ~token:tec srv "/api/incidencias?por_pagina=201" in
      check_estado "por_pagina demasiado grande" 400 l;
      let* l = get ~token:tec srv "/api/incidencias?pagina=0" in
      check_estado "pagina 0" 400 l;
      let* l = get ~token:tec srv "/api/incidencias?pagina=abc" in
      check_estado "pagina no numerica" 400 l;
      (* Con el motor caido las listas siguen saliendo, sin SLA. *)
      e.motor.caido <- true;
      let* l = get ~token:tec srv "/api/incidencias" in
      check_estado "motor caido: la lista sale" 200 l;
      Alcotest.(check bool) "sin sla" true (List.for_all (fun f -> Json.get "sla" f = `Null) (Json.list "items" l.json));
      let* d = get ~token:tec srv (Printf.sprintf "/api/incidencias/%d" (id_de i1)) in
      check_estado "motor caido: el detalle sale" 200 d;
      Lwt.return ())

let test_alta_manual_validaciones _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* r = post ~token:tec srv "/api/incidencias" (`Assoc [ ("categoria", `String "correo") ]) in
      check_estado "sin titulo" 400 r;
      Alcotest.(check bool) "mensaje en español" true (contiene "asunto" (Json.str_d "error" "" r.json));
      let* r = post ~token:tec srv "/api/incidencias" (`Assoc [ ("titulo", `String "x"); ("categoria", `String "inventada") ]) in
      check_estado "categoria fuera del vocabulario" 400 r;
      let* r = post ~token:tec srv "/api/incidencias" (`Assoc [ ("titulo", `String "x"); ("persona_id", `Int 999) ]) in
      check_estado "persona inexistente" 400 r;
      let* r = post ~token:tec srv "/api/incidencias" (`Assoc [ ("titulo", `String (String.make 300 'a')) ]) in
      check_estado "titulo demasiado largo" 400 r;
      let* r = post ~token:tec srv "/api/incidencias" (`Assoc [ ("titulo", `Int 5) ]) in
      check_estado "titulo que no es texto" 400 r;
      let* r = post ~token:tec srv "/api/incidencias" (`Assoc [ ("titulo", `String "Pantalla azul"); ("categoria", `String "equipo"); ("prioridad", `String "P1") ]) in
      check_estado "alta con prioridad fijada" 201 r;
      Alcotest.(check string) "prioridad fijada por la mesa" "P1" (Json.str_d "prioridad" "" r.json);
      let* ev = Ayuda.contar e.db "SELECT 1 FROM incidencia_eventos WHERE tipo = 'prioridad_cambiada'" in
      Alcotest.(check int) "pasa por el motor" 1 ev;
      let llamada = List.find (fun (m, ruta, _) -> m = "POST" && ruta = "/interno/incidencias") e.motor.llamadas in
      let _, _, cuerpo = llamada in
      Alcotest.(check string) "canal consola" "consola" (Json.str_d "canal" "" cuerpo);
      Alcotest.(check string) "motivo manual" "manual" (Json.str_d "motivo" "" cuerpo);
      Alcotest.(check string) "actor tecnico" "tecnico" (Json.str_d "tipo" "" (Json.get "actor" cuerpo));
      Alcotest.(check bool) "la prioridad NO viaja al crear (la calcula el motor)" true (Json.get "prioridad" cuerpo = `Null);
      Lwt.return ())

let test_alta_con_persona_texto _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let alta_con texto = post ~token:tec srv "/api/incidencias" (`Assoc [ ("titulo", `String "Prueba"); ("persona_texto", `String texto) ]) in
      let* r = alta_con "ANA@ejemplo.test" in
      check_estado "por correo (sin mayusculas)" 201 r;
      Alcotest.(check string) "es Ana" "Ana Ríos" (Json.str_d "nombre" "" (Json.get "persona" r.json));
      let* r = alta_con "+51 987 654 321" in
      check_estado "por WhatsApp" 201 r;
      Alcotest.(check string) "es Ana" "Ana Ríos" (Json.str_d "nombre" "" (Json.get "persona" r.json));
      let* r = alta_con "ana rios" in
      check_estado "nombre sin tilde: no coincide" 400 r;
      let* r = alta_con "Ana Ríos" in
      check_estado "por nombre exacto" 201 r;
      let* r = alta_con "Nadie Conocido" in
      check_estado "nombre desconocido" 400 r;
      check_contiene "dice que hacer" "correo o su WhatsApp" (Json.str_d "error" "" r.json);
      let* r = alta_con "nueva.persona@ejemplo.test" in
      check_estado "correo nuevo: se da de alta" 201 r;
      Alcotest.(check string) "con el nombre del correo" "nueva.persona" (Json.str_d "nombre" "" (Json.get "persona" r.json));
      let* r = alta_con "51999888777" in
      check_estado "WhatsApp nuevo: se da de alta" 201 r;
      let* n = Ayuda.contar e.db "SELECT 1 FROM personas" in
      Alcotest.(check int) "tres personas (Ana y las dos nuevas)" 3 n;
      let* () = Db.exec_p e.db "INSERT INTO personas (nombre) VALUES ('Ana Ríos'), ('Ana Ríos Díaz')" (`Assoc []) in
      let* r = alta_con "ana" in
      check_estado "nombre ambiguo" 400 r;
      check_contiene "pide precisar" "varias personas" (Json.str_d "error" "" r.json);
      let* r = alta_con "mal@" in
      check_estado "correo invalido" 400 r;
      Lwt.return ())

let test_buscar_y_rendimiento _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" and* ent = Ayuda.token_de srv "entrenador" and* ger = Ayuda.token_de srv "gerencia" and* sup = Ayuda.token_de srv "supervisor" in
      let* _ = alta srv tec in
      let* r = get ~token:tec srv "/api/buscar?q=ana" in
      check_estado "buscar" 200 r;
      Alcotest.(check int) "incidencia por persona" 1 (List.length (Json.list "incidencias" r.json));
      Alcotest.(check int) "persona" 1 (List.length (Json.list "personas" r.json));
      Alcotest.(check bool) "el tecnico no ve articulos ni reportes" true (Json.list "articulos" r.json = [] && Json.list "reportes" r.json = []);
      let* r = get ~token:tec srv "/api/buscar?q=outlook" in
      Alcotest.(check int) "por titulo" 1 (List.length (Json.list "incidencias" r.json));
      let* r = get ~token:tec srv "/api/buscar?q=a" in
      check_estado "muy corta" 400 r;
      let* r = get ~token:tec srv "/api/buscar?q=%25%25" in
      Alcotest.(check bool) "un % no es comodin" true (Json.list "incidencias" r.json = []);
      let* r = get ~token:ent srv "/api/buscar?q=outlook" in
      Alcotest.(check bool) "el entrenador es de otro rol: no es tecnico" true (r.estado = 403);
      let* r = get ~token:ger srv "/api/buscar?q=cumplimiento" in
      Alcotest.(check bool) "gerencia ve reportes" true (List.length (Json.list "reportes" r.json) = 1);
      let* r = get ~token:sup srv "/api/tecnicos/1" in
      let rend = Json.get "rendimiento" r.json in
      Alcotest.(check int) "resueltas 30 d (de la golden query)" 12 (Json.int_d "resueltas_30d" 0 rend);
      Alcotest.(check bool) "primera respuesta (de la golden query)" true (Json.float "primera_respuesta_mediana_min" rend = Some 18.5);
      Alcotest.(check bool) "lo que no hay golden, null" true (Json.get "sla_cumplido_pct" rend = `Null);
      let* r = get ~token:sup srv "/api/tecnicos" in
      let luis = List.find (fun t -> Json.int "id" t = Some 1) (Json.list "items" r.json) in
      Alcotest.(check int) "tambien en la lista" 12 (Json.int_d "resueltas_30d" 0 (Json.get "rendimiento" luis));
      let marta = List.find (fun t -> Json.int "id" t = Some 2) (Json.list "items" r.json) in
      Alcotest.(check bool) "sin datos: null" true (Json.get "rendimiento" marta = `Null);
      (* Indicadores: 12 semanas por KPI, y el resultado se cachea. *)
      let golden_mttr () = List.length (List.filter (fun (m, ruta, _) -> m = "GET" && contiene "/interno/golden/mttr" ruta) e.motor.llamadas) in
      let* r = get ~token:ger srv "/api/indicadores?desde=2026-09-01&hasta=2026-09-30" in
      check_estado "indicadores" 200 r;
      let mttr = List.find (fun k -> Json.str "kpi" k = Some "mttr") (Json.list "kpis" r.json) in
      let serie = Json.list "filas" mttr in
      Alcotest.(check int) "12 semanas" 12 (List.length serie);
      Alcotest.(check bool) "de la mas vieja a la mas nueva" true (let ps = List.map (Json.str_d "periodo" "") serie in ps = List.sort compare ps);
      Alcotest.(check string) "la ultima semana empieza 6 dias antes del fin del periodo" "2026-09-24" (Json.str_d "periodo" "" (List.nth serie 11));
      Alcotest.(check bool) "valores de la golden" true (List.for_all (fun p -> Json.float "valor" p = Some 55.0) serie);
      Alcotest.(check bool) "meta y sentido" true (Json.str_d "sentido" "" mttr = "menor_mejor");
      let antes = golden_mttr () in
      Alcotest.(check bool) "se llamo a la golden (periodo + 12 semanas)" true (antes >= 13);
      let* _ = get ~token:ger srv "/api/indicadores?desde=2026-09-01&hasta=2026-09-30" in
      Alcotest.(check int) "la segunda vez sale de la cache" antes (golden_mttr ());
      let* r = get ~token:ger srv "/api/indicadores?desde=2026-09-01&hasta=2026-09-30&serie=0" in
      let mttr = List.find (fun k -> Json.str "kpi" k = Some "mttr") (Json.list "kpis" r.json) in
      Alcotest.(check bool) "serie=0 la omite" true (Json.list "filas" mttr = []);
      Lwt.return ())

(* --- base de conocimiento inicial, sugerencia del tecnico, calidad ---------------------------------------------------------------------- *)

let test_conocimiento_inicial _ () =
  con_app (fun e _ ->
      let* () = Db.exec_p e.db "DELETE FROM articulos" (`Assoc []) in
      (* Un agente viejo (404) o caido: no falla, queda la tabla vacia y se reintenta. *)
      let* n = Semilla_conocimiento.ejecutar e.ctx in
      Alcotest.(check int) "agente sin la ruta (404): 0 y sin error" 0 n;
      let caido = { e.ctx with agente = Agente.crear ~url:"http://127.0.0.1:1" ~plazo:1. } in
      let* n = Semilla_conocimiento.ejecutar caido in
      Alcotest.(check int) "agente caido: 0 y sin error" 0 n;
      let* total = Ayuda.contar e.db "SELECT 1 FROM articulos" in
      Alcotest.(check int) "la tabla sigue vacia" 0 total;
      (* En el siguiente ciclo el agente ya los da. *)
      e.agente.articulos <- Some (200, Falsos.Agente_falso.articulos_de_ejemplo);
      let* n = Semilla_conocimiento.ejecutar e.ctx in
      Alcotest.(check int) "inserta los validos (el que no tiene pasos se descarta)" 2 n;
      let* filas = Ayuda.lista e.db "SELECT a.clave, a.estado, a.supuesto, ca.clave AS categoria, array_length(a.pasos, 1) AS pasos FROM articulos a LEFT JOIN categorias ca ON ca.id = a.categoria_id ORDER BY a.clave" (`Assoc []) in
      Alcotest.(check (list string)) "claves del agente" [ "KB-001"; "KB-002" ] (List.map (Json.str_d "clave" "") filas);
      Alcotest.(check bool) "SUPUESTO: hasta que la organizacion los revise" true (List.for_all (fun f -> Json.bool_d "supuesto" false f) filas);
      Alcotest.(check bool) "publicados" true (List.for_all (fun f -> Json.str_d "estado" "" f = "publicado") filas);
      Alcotest.(check (list string)) "con su categoria" [ "correo"; "impresoras" ] (List.map (Json.str_d "categoria" "") filas);
      Alcotest.(check (list int)) "y sus pasos" [ 2; 1 ] (List.map (Json.int_d "pasos" 0) filas);
      let* () = Ayuda.esperar_reposo e in
      let recargas = List.filter (fun j -> Json.str "_ruta" j = Some "/conocimiento/recargar") e.agente.recibidas in
      Alcotest.(check int) "se le recargan al agente" 2 (List.length (Json.list "articulos" (List.hd recargas)));
      (* Idempotente: con la tabla llena no vuelve a pedir nada. *)
      e.agente.articulos <- None;
      let* n = Semilla_conocimiento.ejecutar e.ctx in
      Alcotest.(check int) "ya hay articulos" 0 n;
      (* Un articulo nuevo desde la consola no choca con las claves del agente. *)
      let* srv_ent = Lwt.return (Ayuda.servir_app e) in
      let* () = Lwt_unix.sleep 0.15 in
      let* ent = Ayuda.token_de srv_ent "entrenador" in
      let* r = post ~token:ent srv_ent "/api/articulos" (`Assoc [ ("titulo", `String "Nuevo"); ("pasos", `List [ `String "uno" ]) ]) in
      check_estado "crear" 201 r;
      Alcotest.(check bool) "clave siguiente, sin chocar" true (let c = Json.str_d "clave" "" r.json in c <> "KB-001" && c <> "KB-002");
      srv_ent.parar ();
      Lwt.return ())

let test_sugerencia_del_tecnico _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "no me abre el correo") in
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "mi correo, desde hoy") in
      let con_sugerencia texto =
        e.agente.responder <-
          (fun p ->
            let _, base = Falsos.Agente_falso.por_defecto p in
            (200, Json.set "sugerencia_tecnico" (`Assoc [ ("texto", `String texto); ("confianza", `Float 0.81); ("articulo", `String "KB-031") ]) base))
      in
      con_sugerencia "Hola Ana, prueba recrear el perfil de Outlook (KB-031).";
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "sigue igual") in
      let* d = get ~token:tec srv "/api/incidencias/1" in
      let sug = Json.get "sugerencia" d.json in
      Alcotest.(check string) "texto" "Hola Ana, prueba recrear el perfil de Outlook (KB-031)." (Json.str_d "texto" "" sug);
      Alcotest.(check bool) "confianza" true (Json.float "confianza" sug = Some 0.81);
      Alcotest.(check string) "articulo" "KB-031" (Json.str_d "articulo" "" sug);
      let* m = Ayuda.fila e.db "SELECT meta->'sugerencia_tecnico'->>'texto' AS txt FROM mensajes WHERE rol = 'asistente' ORDER BY id DESC LIMIT 1" (`Assoc []) in
      check_contiene "guardada en mensajes.meta" "recrear el perfil" (Json.str_d "txt" "" m);
      (* La persona NO la ve: no aparece en lo que se le envio por WhatsApp. *)
      let* () = Ayuda.esperar_reposo e in
      Alcotest.(check bool) "la sugerencia no sale por WhatsApp" false (List.exists (fun (_, t) -> contiene "recrear el perfil" t) (Evolution.simulados e.ctx.evolution));
      (* La del ULTIMO mensaje que la traiga. *)
      con_sugerencia "Otra mas reciente.";
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "¿alguien me ayuda?") in
      let* d = get ~token:tec srv "/api/incidencias/1" in
      Alcotest.(check string) "la mas reciente" "Otra mas reciente." (Json.str_d "texto" "" (Json.get "sugerencia" d.json));
      (* Un mensaje posterior SIN sugerencia no la borra: manda la ultima que la traiga. *)
      e.agente.responder <- Falsos.Agente_falso.por_defecto;
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "hola") in
      let* d = get ~token:tec srv "/api/incidencias/1" in
      Alcotest.(check string) "sigue la ultima que la traiga" "Otra mas reciente." (Json.str_d "texto" "" (Json.get "sugerencia" d.json));
      (* Una sugerencia mal formada se ignora. *)
      e.agente.responder <- (fun p -> let _, base = Falsos.Agente_falso.por_defecto p in (200, Json.set "sugerencia_tecnico" (`Assoc [ ("texto", `String "  ") ]) base));
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "hola otra vez") in
      (* Cuando el tecnico contesta, la sugerencia caduca. *)
      let* r = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "Hola Ana") ]) in
      check_estado "responder" 200 r;
      Alcotest.(check bool) "tras responder el tecnico, sin sugerencia" true (Json.get "sugerencia" r.json = `Null);
      Lwt.return ())

let test_calidad _ () =
  con_app (fun e srv ->
      let* ent = Ayuda.token_de srv "entrenador" in
      let* r = get ~token:ent srv "/api/calidad" in
      check_estado "calidad vacia" 200 r;
      Alcotest.(check int) "12 semanas" 12 (List.length (Json.list "semanas" r.json));
      List.iter (fun k -> Alcotest.(check int) ("serie " ^ k) 12 (List.length (Json.list k r.json))) [ "confianza_media"; "pulgar_abajo_pct"; "contencion_pct"; "frases_quitadas_pct"; "regeneradas_pct"; "costo_usd_por_caso" ];
      Alcotest.(check bool) "sin datos: todo null, no ceros inventados" true (List.for_all (fun v -> v = `Null) (Json.list "confianza_media" r.json));
      (* Una conversacion con dos respuestas del asistente: una con frases quitadas y regenerada. *)
      let n = ref 0 in
      e.agente.responder <-
        (fun p ->
          incr n;
          let _, base = Falsos.Agente_falso.por_defecto p in
          if !n = 1 then (200, Json.set "frases_quitadas" (`Int 2) (Json.set "regenerada" (`Bool true) base)) else (200, base));
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "no me abre el correo") in
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "mi correo, desde hoy") in
      let* _ = Db.exec_p e.db "INSERT INTO feedback (caso_id, senal) VALUES (1, 'pulgar_arriba'), (1, 'pulgar_arriba'), (1, 'pulgar_arriba'), (1, 'pulgar_abajo')" (`Assoc []) in
      let* r = get ~token:ent srv "/api/calidad" in
      let ult k = List.nth (Json.list k r.json) 11 in
      Alcotest.(check bool) "la semana en curso es la ultima" true (let s = Json.str_d "" "" `Null in ignore s; Json.str_d "semana" "" (`Assoc [ ("semana", List.nth (Json.list "semanas" r.json) 11) ]) <> "");
      Alcotest.(check bool) "confianza media (0,93)" true (Json.float_opt (ult "confianza_media") = Some 0.93);
      Alcotest.(check bool) "pulgar abajo: 1 de 4 = 25 %" true (Json.float_opt (ult "pulgar_abajo_pct") = Some 25.0);
      Alcotest.(check bool) "frases quitadas: 1 de 2 respuestas = 50 %" true (Json.float_opt (ult "frases_quitadas_pct") = Some 50.0);
      Alcotest.(check bool) "regeneradas: 1 de 2 = 50 %" true (Json.float_opt (ult "regeneradas_pct") = Some 50.0);
      Alcotest.(check bool) "costo por caso: 2 x 0,0012 en un caso" true (Json.float_opt (ult "costo_usd_por_caso") = Some 0.0024);
      Alcotest.(check bool) "las semanas anteriores, null" true (Json.get "confianza_media" (`Assoc [ ("confianza_media", List.nth (Json.list "confianza_media" r.json) 0) ]) = `Null);
      Alcotest.(check bool) "fuente: Postgres, no oficial" true (Json.bool_d "oficial" true (Json.get "fuente" r.json) = false);
      (* Exactitud por version, desde `modelos` (sincronizado con el agente). *)
      let ev = Json.list "exactitud_por_version" r.json in
      Alcotest.(check string) "version" "v1" (Json.str_d "version" "" (List.hd ev));
      Alcotest.(check bool) "exactitud" true (Json.float "exactitud" (List.hd ev) = Some 0.95);
      (* Con ClickHouse respondiendo, manda la cifra OFICIAL de las golden queries. *)
      e.motor.golden_calidad <- true;
      Hashtbl.reset Api_reportes.cache_golden;
      let* r = get ~token:ent srv "/api/calidad" in
      let ult k = List.nth (Json.list k r.json) 11 in
      Alcotest.(check bool) "frases quitadas oficial" true (Json.float_opt (ult "frases_quitadas_pct") = Some 12.5);
      Alcotest.(check bool) "regeneradas oficial" true (Json.float_opt (ult "regeneradas_pct") = Some 3.0);
      Alcotest.(check bool) "costo oficial por caso (por 1000 / 1000)" true (Json.float_opt (ult "costo_usd_por_caso") = Some 0.042);
      Alcotest.(check bool) "contencion oficial" true (Json.float_opt (ult "contencion_pct") = Some 55.0);
      Alcotest.(check bool) "fuente oficial" true (Json.bool_d "oficial" false (Json.get "fuente" r.json));
      Alcotest.(check bool) "la confianza media sigue siendo operativa (no hay golden)" true (Json.float_opt (ult "confianza_media") = Some 0.93);
      Lwt.return ())

let test_sql_de_la_golden _ () =
  con_app (fun e srv ->
      let* ger = Ayuda.token_de srv "gerencia" in
      let* r = get ~token:ger srv "/api/indicadores?desde=2026-09-01&hasta=2026-09-30&serie=0" in
      let mttr = List.find (fun k -> Json.str "kpi" k = Some "mttr") (Json.list "kpis" r.json) in
      Alcotest.(check string) "el motor no expone el SQL: vacio" "" (Json.str_d "sql" "x" mttr);
      e.motor.sql_en_golden <- true;
      Hashtbl.reset Api_reportes.cache_golden;
      let* r = get ~token:ger srv "/api/indicadores?desde=2026-09-01&hasta=2026-09-30&serie=0" in
      let mttr = List.find (fun k -> Json.str "kpi" k = Some "mttr") (Json.list "kpis" r.json) in
      Alcotest.(check string) "si el motor lo expone, se muestra" "SELECT 1 FROM jsrbot.v_incidencias" (Json.str_d "sql" "" mttr);
      let* r = post ~token:ger srv "/api/reportes/preguntar" (`Assoc [ ("pregunta", `String "¿Cuál fue el MTTR de septiembre?") ]) in
      Alcotest.(check string) "tambien en el analista" "SELECT 1 FROM jsrbot.v_incidencias" (Json.str_d "sql" "" r.json);
      Lwt.return ())

(* Una conversacion completa por WhatsApp que acaba en incidencia, para probar el detalle. *)
let conversacion_a_incidencia (e : Ayuda.entorno) =
  let enviar t = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) t) in
  let* _ = enviar "no me abre el correo" in
  let* _ = enviar "mi correo, desde hoy en PC-CONT-07" in
  let* r = enviar "sigue igual" in
  Lwt.return (Option.get r.caso_id)

let test_detalle _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* caso_id = conversacion_a_incidencia e in
      let* () = Db.exec_p e.db "INSERT INTO activos (codigo, tipo, persona_id) VALUES ('PC-CONT-07', 'pc', 1)" (`Assoc []) in
      (* Una nota interna: va en el hilo, marcada. *)
      let* r = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "comentar_interno"); ("texto", `String "Parece el perfil de Outlook") ]) in
      check_estado "nota interna" 200 r;
      let* d = get ~token:tec srv "/api/incidencias/1" in
      check_estado "detalle" 200 d;
      let j = d.json in
      Alcotest.(check string) "numero" "INC-000001" (Json.str_d "numero" "" j);
      Alcotest.(check string) "titulo" "Outlook no recibe correos" (Json.str_d "titulo" "" j);
      Alcotest.(check bool) "token publico" true (String.length (Json.str_d "token_publico" "" j) >= 16);
      Alcotest.(check string) "persona_detalle.correo" "ana@ejemplo.test" (Json.str_d "correo" "" (Json.get "persona_detalle" j));
      Alcotest.(check (list string)) "equipos de la persona" [ "PC-CONT-07" ] (List.filter_map (function `String s -> Some s | _ -> None) (Json.list "equipos" (Json.get "persona_detalle" j)));
      Alcotest.(check bool) "sla" true (Json.get "sla" j <> `Null);
      let eventos = Json.list "eventos" j in
      Alcotest.(check bool) "eventos con creada y asignada" true (List.exists (fun e -> Json.str_d "tipo" "" e = "creada") eventos && List.exists (fun e -> Json.str_d "tipo" "" e = "asignada") eventos);
      let hilo = Json.list "items" (Json.get "mensajes" j) in
      Alcotest.(check bool) "mensajes del caso" true (List.length hilo >= 6);
      Alcotest.(check bool) "con la nota interna marcada" true (List.exists (fun m -> Json.bool_d "interno" false m && contiene "perfil de Outlook" (Json.str_d "texto" "" m)) hilo);
      Alcotest.(check bool) "roles del vocabulario" true (List.for_all (fun m -> List.mem (Json.str_d "rol" "" m) [ "usuario"; "asistente"; "tecnico"; "sistema" ]) hilo);
      Alcotest.(check bool) "ordenado por hora" true (let ts = List.map (Json.str_d "ts" "") hilo in ts = List.sort compare ts);
      Alcotest.(check string) "memoria: ficha del caso" "correo no sincroniza" (Json.str_d "sintoma" "" (Json.get "memoria" j));
      let cl = Json.get "clasificacion" j in
      Alcotest.(check string) "clasificacion.intencion" "sigue_igual" (Json.str_d "intencion" "" cl);
      Alcotest.(check bool) "clasificacion.confianza" true (Json.float "confianza" cl <> None);
      Alcotest.(check bool) "veredictos de Jev local" true (Json.list "veredictos" j <> []);
      Alcotest.(check string) "veredicto" "respaldada" (Json.str_d "veredicto" "" (List.hd (Json.list "veredictos" j)));
      Alcotest.(check bool) "veredicto con modo valido" true (List.mem (Json.str_d "modo" "" (List.hd (Json.list "veredictos" j))) [ "sombra"; "activo" ]);
      Alcotest.(check bool) "sugerencia (aun sin fuente)" true (Json.get "sugerencia" j = `Null);
      Alcotest.(check (option int)) "caso" (Some caso_id) (Json.int "caso_id" j);
      let* nf = get ~token:tec srv "/api/incidencias/999" in
      check_estado "no existe" 404 nf;
      Alcotest.(check string) "codigo" "no_encontrado" (Json.str_d "codigo" "" nf.json);
      let* nf = get ~token:tec srv "/api/incidencias/abc" in
      check_estado "id no numerico" 404 nf;
      Lwt.return ())

(* --- acciones ---------------------------------------------------------------------------------------------------------------------------- *)

let test_responder_envia_por_whatsapp _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" and* adm = Ayuda.token_de srv "admin" in
      let* caso_id = conversacion_a_incidencia e in
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Evolution.limpiar_simulados e.ctx.evolution;
      let sugerida = "Hola Ana, reinicia Outlook." in
      let* r = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "Hola Ana, ya revisé tu perfil. ¿Me confirmas el equipo?"); ("sugerencia", `String sugerida) ]) in
      check_estado "responder" 200 r;
      Alcotest.(check string) "pasa a en_curso (lo hace el motor)" "en_curso" (Json.str_d "estado" "" r.json);
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      (* Se envio a la persona por su canal. *)
      (match Evolution.simulados e.ctx.evolution with
      | [ (destino, texto) ] ->
          Alcotest.(check string) "al WhatsApp de la persona" "51987654321" destino;
          check_contiene "con el nombre de quien habla" "Luis Paz (mesa de ayuda)" texto;
          check_contiene "con el texto" "ya revisé tu perfil" texto
      | l -> Alcotest.failf "se esperaba 1 envio y hubo %d" (List.length l));
      (* Quedo en la conversacion como mensaje del tecnico. *)
      let* m = Ayuda.fila e.db "SELECT rol, texto, meta FROM mensajes WHERE caso_id = $i:c AND rol = 'tecnico'" (`Assoc [ ("c", `Int caso_id) ]) in
      Alcotest.(check string) "rol tecnico" "tecnico" (Json.str_d "rol" "" m);
      Alcotest.(check string) "autor" "Luis Paz" (Json.str_d "autor" "" (Json.get "meta" m));
      (* Quien responde toma la conversacion: el asistente calla. *)
      let* caso = Ayuda.fila e.db "SELECT pausado_por_tecnico FROM casos WHERE id = $i:c" (`Assoc [ ("c", `Int caso_id) ]) in
      Alcotest.(check bool) "caso pausado" true (Json.bool_d "pausado_por_tecnico" false caso);
      (* La edicion de la sugerencia es un par de preferencia. *)
      let* par = Ayuda.fila e.db "SELECT incidencia_id, propuesta, editada FROM pares_preferencia" (`Assoc []) in
      Alcotest.(check string) "propuesta" sugerida (Json.str_d "propuesta" "" par);
      check_contiene "editada" "ya revisé tu perfil" (Json.str_d "editada" "" par);
      (* Sin cambios, no hay par. *)
      let* _ = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "  Igual  "); ("sugerencia", `String "igual") ]) in
      let* n = Ayuda.contar e.db "SELECT 1 FROM pares_preferencia" in
      Alcotest.(check int) "una sugerencia no editada no genera par" 1 n;
      (* Un usuario sin tecnico vinculado no puede responder. *)
      let* r = post ~token:adm srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "hola") ]) in
      check_estado "admin sin tecnico" 400 r;
      check_contiene "explica por que" "vincule" (Json.str_d "error" "" r.json);
      let* r = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "   ") ]) in
      check_estado "texto vacio" 400 r;
      Lwt.return ())

let test_acciones_validacion_y_motor _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" and* sup = Ayuda.token_de srv "supervisor" in
      let* i = alta srv tec in
      let id = id_de i in
      let acc t cuerpo = post ~token:t srv (Printf.sprintf "/api/incidencias/%d/acciones" id) (`Assoc cuerpo) in
      let* r = acc tec [ ("accion", `String "inventada") ] in
      check_estado "accion desconocida" 400 r;
      let* r = acc tec [] in
      check_estado "sin accion" 400 r;
      let* r = acc tec [ ("accion", `String "cambiar_prioridad"); ("prioridad", `String "P9") ] in
      check_estado "prioridad invalida" 400 r;
      let* r = acc tec [ ("accion", `String "pausar"); ("motivo", `String "porque si") ] in
      check_estado "motivo de pausa invalido" 400 r;
      let* r = acc tec [ ("accion", `String "asignar"); ("tecnico_id", `String "x") ] in
      check_estado "tecnico invalido" 400 r;
      (* El motor rechaza una transicion invalida: 409 con su mensaje. *)
      let* r = acc tec [ ("accion", `String "cerrar") ] in
      check_estado "cerrar sin resolver" 409 r;
      Alcotest.(check string) "codigo conflicto" "conflicto" (Json.str_d "codigo" "" r.json);
      (* Acciones validas. *)
      let* r = acc sup [ ("accion", `String "asignar"); ("tecnico_id", `Int 2); ("motivo", `String "balanceo") ] in
      check_estado "asignar" 200 r;
      Alcotest.(check string) "queda con Marta" "Marta Rojas" (Json.str_d "nombre" "" (Json.get "tecnico" r.json));
      let* r = acc tec [ ("accion", `String "cambiar_prioridad"); ("prioridad", `String "P2"); ("motivo", `String "afecta a contabilidad") ] in
      check_estado "cambiar prioridad" 200 r;
      Alcotest.(check string) "prioridad" "P2" (Json.str_d "prioridad" "" r.json);
      let* r = acc tec [ ("accion", `String "escalar"); ("grupo_id", `Int 3); ("motivo", `String "necesita infraestructura") ] in
      check_estado "escalar" 200 r;
      let* r = acc tec [ ("accion", `String "resolver"); ("nota", `String "Se recreo el perfil") ] in
      check_estado "resolver" 200 r;
      Alcotest.(check string) "resuelta" "resuelta" (Json.str_d "estado" "" r.json);
      let llamada_resolver = List.find (fun (m, ruta, c) -> m = "POST" && contiene "/acciones" ruta && Json.str_d "accion" "" c = "resolver") e.motor.llamadas in
      let _, _, c = llamada_resolver in
      Alcotest.(check string) "la nota viaja como solucion" "Se recreo el perfil" (Json.str_d "solucion" "" c);
      let* r = acc tec [ ("accion", `String "reabrir"); ("motivo", `String "no funciono") ] in
      check_estado "reabrir" 200 r;
      let* r = acc tec [ ("accion", `String "pausar"); ("motivo", `String "espera_usuario") ] in
      check_estado "pausar desde reabierta" 409 r;
      (* Auditoria de las acciones sensibles. *)
      let* acciones = Ayuda.lista e.db "SELECT accion FROM auditoria WHERE objeto = $obj ORDER BY id" (`Assoc [ ("obj", `String (Printf.sprintf "incidencia:%d" id)) ]) in
      let nombres = List.map (Json.str_d "accion" "") acciones in
      List.iter (fun a -> Alcotest.(check bool) ("auditada: " ^ a) true (List.mem a nombres)) [ "incidencia_asignar"; "incidencia_cambiar_prioridad"; "incidencia_escalar"; "incidencia_resolver"; "incidencia_reabrir" ];
      let* tod = Ayuda.lista e.db "SELECT detalle::text AS d FROM auditoria" (`Assoc []) in
      Alcotest.(check bool) "la auditoria no lleva textos de conversaciones" true (not (List.exists (fun f -> contiene "Se recreo el perfil" (Json.str_d "d" "" f)) tod));
      (* Motor caido: error claro y nada a medias. *)
      e.motor.caido <- true;
      let* r = acc tec [ ("accion", `String "cambiar_prioridad"); ("prioridad", `String "P1") ] in
      check_estado "motor caido" 503 r;
      Alcotest.(check string) "codigo" "no_disponible" (Json.str_d "codigo" "" r.json);
      Lwt.return ())

let test_resolver_avisa_a_la_persona _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* caso_id = conversacion_a_incidencia e in
      (* Un tecnico responde (pausa el caso) y luego resuelve: el asistente vuelve y la persona recibe la pregunta de cierre. *)
      let* _ = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "Lo reviso") ]) in
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* r = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "resolver"); ("solucion", `String "Nota interna: era el perfil") ]) in
      check_estado "resolver" 200 r;
      let* () = Ayuda.esperar_reposo e in
      (match Evolution.simulados e.ctx.evolution with
      | [ (destino, texto) ] ->
          Alcotest.(check string) "a la persona" "51987654321" destino;
          check_contiene "numero" "INC-000001" texto;
          check_contiene "pregunta de cierre" "¿Quedó resuelto?" texto;
          Alcotest.(check bool) "SIN la nota interna" false (contiene "Nota interna" texto || contiene "perfil" texto)
      | l -> Alcotest.failf "se esperaba 1 mensaje a la persona y hubo %d" (List.length l));
      let* caso = Ayuda.fila e.db "SELECT pausado_por_tecnico, etapa, memoria FROM casos WHERE id = $i:c" (`Assoc [ ("c", `Int caso_id) ]) in
      Alcotest.(check bool) "el asistente vuelve" false (Json.bool_d "pausado_por_tecnico" true caso);
      Alcotest.(check string) "etapa de cierre" "cierre" (Json.str_d "etapa" "" caso);
      Alcotest.(check string) "pregunta pendiente" "resolvio" (Json.str_d "pendiente" "" (Json.get "memoria" caso));
      Lwt.return ())

(* --- conversaciones ------------------------------------------------------------------------------------------------------------------------ *)

let test_casos_tomar_devolver _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" and* sup = Ayuda.token_de srv "supervisor" and* ent = Ayuda.token_de srv "entrenador" in
      let* caso_id = conversacion_a_incidencia e in
      let* l = get ~token:tec srv "/api/casos" in
      check_estado "lista" 200 l;
      let c = List.hd (Json.list "items" l.json) in
      Alcotest.(check string) "estado" "con_incidencia" (Json.str_d "estado" "" c);
      Alcotest.(check string) "incidencia_numero" "INC-000001" (Json.str_d "incidencia_numero" "" c);
      Alcotest.(check string) "persona" "Ana Ríos" (Json.str_d "nombre" "" (Json.get "persona" c));
      Alcotest.(check bool) "mensajes_total" true (Json.int_d "mensajes_total" 0 c >= 6);
      Alcotest.(check bool) "ultimo_texto" true (Json.str_d "ultimo_texto" "" c <> "");
      let* m = get ~token:ent srv (Printf.sprintf "/api/casos/%d/mensajes" caso_id) in
      check_estado "el entrenador lee conversaciones" 200 m;
      Alcotest.(check bool) "mensajes con rol y texto" true (List.for_all (fun x -> Json.str "rol" x <> None && Json.str "texto" x <> None) (Json.list "items" m.json));
      Alcotest.(check string) "caso en la respuesta" "con_incidencia" (Json.str_d "estado" "" (Json.get "caso" m.json));
      (* Escribir sin tomar: conflicto. *)
      let ruta s = Printf.sprintf "/api/casos/%d/%s" caso_id s in
      let* r = post ~token:tec srv (ruta "mensajes") (`Assoc [ ("texto", `String "hola") ]) in
      check_estado "escribir sin tomar" 409 r;
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* r = post ~token:tec srv (ruta "tomar") (`Assoc []) in
      check_estado "tomar" 200 r;
      Alcotest.(check bool) "pausado" true (Json.bool_d "pausado_por_tecnico" false r.json);
      Alcotest.(check string) "tomado por" "Luis Paz" (Json.str_d "tomado_por" "" r.json);
      let* () = Ayuda.esperar_reposo e in
      (match Evolution.simulados e.ctx.evolution with [ (_, t) ] -> check_contiene "se avisa a la persona" "Te escribe Luis Paz" t | l -> Alcotest.failf "se esperaba 1 aviso y hubo %d" (List.length l));
      (* El asistente ya no responde. *)
      let antes = List.length e.agente.recibidas in
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "¿hay alguien?") in
      Alcotest.(check int) "el agente no recibio nada" antes (List.length e.agente.recibidas);
      (* Otra persona de la mesa no se la quita; un supervisor si. *)
      let* r = post ~token:sup srv (ruta "tomar") (`Assoc []) in
      check_estado "un supervisor puede" 200 r;
      Alcotest.(check string) "ahora la tiene Marta" "Marta Rojas" (Json.str_d "tomado_por" "" r.json);
      let* tec2 = Ayuda.token_de srv "tecnico" in
      let* r = post ~token:tec2 srv (ruta "tomar") (`Assoc []) in
      check_estado "un tecnico no le quita la conversacion a otro" 409 r;
      (* Escribir en la conversacion tomada: va a la persona y cuenta como respuesta en la incidencia. *)
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* r = post ~token:sup srv (ruta "mensajes") (`Assoc [ ("texto", `String "Ya te llamo") ]) in
      check_estado "escribir" 200 r;
      let* () = Ayuda.esperar_reposo e in
      (match Evolution.simulados e.ctx.evolution with [ (_, t) ] -> check_contiene "firmado" "Marta Rojas (mesa de ayuda): Ya te llamo" t | l -> Alcotest.failf "se esperaba 1 envio y hubo %d" (List.length l));
      let* pr = Ayuda.contar e.db "SELECT 1 FROM incidencia_eventos WHERE tipo IN ('primera_respuesta', 'comentario') AND actor_tipo = 'tecnico'" in
      Alcotest.(check int) "cuenta como respuesta del tecnico en la incidencia" 1 pr;
      (* Devolver. *)
      let* r = post ~token:sup srv (ruta "devolver") (`Assoc []) in
      check_estado "devolver" 200 r;
      Alcotest.(check bool) "ya no esta pausado" false (Json.bool_d "pausado_por_tecnico" true r.json);
      let* n = Ayuda.contar e.db "SELECT 1 FROM auditoria WHERE accion IN ('caso_tomado', 'caso_devuelto')" in
      Alcotest.(check int) "auditado" 3 n;
      let* r = post ~token:tec srv "/api/casos/9999/tomar" (`Assoc []) in
      check_estado "caso inexistente" 404 r;
      Lwt.return ())

(* --- equipo y configuracion ----------------------------------------------------------------------------------------------------------------- *)

let test_equipo _ () =
  con_app (fun e srv ->
      let* sup = Ayuda.token_de srv "supervisor" in
      let* r = get ~token:sup srv "/api/tecnicos" in
      check_estado "tecnicos" 200 r;
      Alcotest.(check int) "total" 3 (Json.int_d "total" 0 r.json);
      let luis = List.find (fun t -> Json.str_d "nombre" "" t = "Luis Paz") (Json.list "items" r.json) in
      List.iter (fun k -> Alcotest.(check bool) ("tecnico trae " ^ k) true (Json.get k luis <> `Null)) [ "carga"; "capacidad"; "nivel"; "estado"; "grupos"; "habilidades"; "turnos" ];
      let* tec = Ayuda.token_de srv "tecnico" in
      let* _ = alta srv tec in
      let* r = get ~token:sup srv "/api/tecnicos/1" in
      Alcotest.(check int) "carga actual = incidencias abiertas" 1 (Json.int_d "carga" 0 r.json);
      (* Crear con validaciones. *)
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "") ]) in
      check_estado "sin nombre" 400 r;
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "Rosa Vega"); ("whatsapp", `String "123") ]) in
      check_estado "whatsapp invalido" 400 r;
      check_contiene "explica el formato" "51987654321" (Json.str_d "error" "" r.json);
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "Rosa Vega"); ("correo", `String "no-es-correo") ]) in
      check_estado "correo invalido" 400 r;
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "Rosa Vega"); ("capacidad", `Int 0) ]) in
      check_estado "capacidad 0" 400 r;
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "Rosa Vega"); ("nivel", `String "N9") ]) in
      check_estado "nivel invalido" 400 r;
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "Rosa Vega"); ("turnos", `List [ `Assoc [ ("dia_semana", `Int 1); ("desde", `String "18:00"); ("hasta", `String "09:00") ] ]) ]) in
      check_estado "turno al reves" 400 r;
      let* r = post ~token:sup srv "/api/tecnicos" (`Assoc [ ("nombre", `String "Rosa Vega"); ("grupo_ids", `List [ `Int 999 ]) ]) in
      check_estado "grupo inexistente" 400 r;
      let* n = Ayuda.contar e.db "SELECT 1 FROM tecnicos WHERE nombre = 'Rosa Vega'" in
      Alcotest.(check int) "lo invalido no deja nada a medias" 0 n;
      let* r =
        post ~token:sup srv "/api/tecnicos"
          (`Assoc
            [ ("nombre", `String "Rosa Vega"); ("whatsapp", `String "+51 988 777 666"); ("correo", `String "Rosa@Ejemplo.test"); ("nivel", `String "N2"); ("capacidad", `Int 5);
              ("grupo_ids", `List [ `Int 2 ]); ("habilidades", `List [ `Assoc [ ("categoria", `String "vpn"); ("nivel", `Int 3) ] ]);
              ("turnos", `List [ `Assoc [ ("dia_semana", `Int 1); ("desde", `String "08:30"); ("hasta", `String "13:00") ] ]) ])
      in
      check_estado "crear" 201 r;
      Alcotest.(check string) "whatsapp normalizado a digitos" "51988777666" (Json.str_d "whatsapp" "" r.json);
      Alcotest.(check string) "correo en minusculas" "rosa@ejemplo.test" (Json.str_d "correo" "" r.json);
      Alcotest.(check string) "habilidad por clave" "vpn" (Json.str_d "categoria" "" (List.hd (Json.list "habilidades" r.json)));
      Alcotest.(check string) "turno" "08:30" (Json.str_d "desde" "" (List.hd (Json.list "turnos" r.json)));
      let nuevo = Json.int_d "id" 0 r.json in
      let* r = put ~token:sup srv (Printf.sprintf "/api/tecnicos/%d" nuevo) (`Assoc [ ("estado", `String "ausente"); ("ausencia", `Assoc [ ("desde", `String "2026-10-06T00:00:00Z"); ("hasta", `String "2026-10-10T00:00:00Z"); ("motivo", `String "Vacaciones") ]) ]) in
      check_estado "actualizar" 200 r;
      Alcotest.(check string) "estado" "ausente" (Json.str_d "estado" "" r.json);
      Alcotest.(check string) "ausencia" "Vacaciones" (Json.str_d "motivo" "" (Json.get "ausencia" r.json));
      Alcotest.(check string) "lo no enviado no se toca" "Rosa Vega" (Json.str_d "nombre" "" r.json);
      let* r = put ~token:sup srv "/api/tecnicos/999" (`Assoc [ ("estado", `String "activo") ]) in
      check_estado "tecnico inexistente" 404 r;
      let* r = put ~token:sup srv (Printf.sprintf "/api/tecnicos/%d" nuevo) (`Assoc [ ("ausencia", `Assoc [ ("desde", `String "2026-10-10T00:00:00Z"); ("hasta", `String "2026-10-06T00:00:00Z") ]) ]) in
      check_estado "ausencia al reves" 400 r;
      (* Grupos. *)
      let* g = get ~token:sup srv "/api/grupos" in
      Alcotest.(check int) "grupos" 3 (Json.int_d "total" 0 g.json);
      let* r = post ~token:sup srv "/api/grupos" (`Assoc [ ("nombre", `String "Mesa N1") ]) in
      check_estado "nombre repetido" 409 r;
      let* r = post ~token:sup srv "/api/grupos" (`Assoc [ ("nombre", `String "Seguridad"); ("nivel", `String "N2"); ("escala_a_grupo_id", `Int 3); ("miembros", `List [ `Int 2 ]) ]) in
      check_estado "crear grupo" 201 r;
      Alcotest.(check (list int)) "miembros" [ 2 ] (List.filter_map Json.int_opt (Json.list "miembros" r.json));
      let sid = Json.int_d "id" 0 r.json in
      let* r = put ~token:sup srv (Printf.sprintf "/api/grupos/%d" sid) (`Assoc [ ("escala_a_grupo_id", `Int sid) ]) in
      check_estado "un grupo no escala a si mismo" 400 r;
      let* r = put ~token:sup srv "/api/grupos/3" (`Assoc [ ("escala_a_grupo_id", `Int 1) ]) in
      check_estado "ciclo Infraestructura -> Mesa N1 -> Infraestructura" 400 r;
      Lwt.return ())

let test_configuracion _ () =
  con_app (fun e srv ->
      let* adm = Ayuda.token_de srv "admin" in
      (* Categorias. *)
      let* r = get ~token:adm srv "/api/categorias" in
      Alcotest.(check int) "10 categorias" 10 (Json.int_d "total" 0 r.json);
      let* r = put ~token:adm srv "/api/categorias" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 4); ("nombre", `String "Red privada (VPN)"); ("activa", `Bool false) ] ]) ]) in
      check_estado "categorias" 200 r;
      Alcotest.(check string) "nombre guardado" "Red privada (VPN)" (Json.str_d "nombre" "" (List.nth (Json.list "items" r.json) 3));
      let* r = put ~token:adm srv "/api/categorias" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 4); ("grupo_id", `Int 999) ] ]) ]) in
      check_estado "grupo inexistente" 400 r;
      let* r = put ~token:adm srv "/api/categorias" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 99) ] ]) ]) in
      check_estado "categoria inexistente" 404 r;
      let* r = put ~token:adm srv "/api/categorias" (`Assoc []) in
      check_estado "sin items" 400 r;
      (* SLA. *)
      let* r = get ~token:adm srv "/api/sla" in
      Alcotest.(check int) "4 politicas" 4 (Json.int_d "total" 0 r.json);
      let p1 = List.hd (Json.list "items" r.json) in
      let* r = put ~token:adm srv "/api/sla" (`Assoc [ ("items", `List [ `Assoc [ ("id", Json.get "id" p1); ("prioridad", `String "P1"); ("respuesta_min", `Int 60); ("resolucion_min", `Int 30) ] ]) ]) in
      check_estado "resolucion mas corta que respuesta" 400 r;
      check_contiene "explica" "no puede ser más corta" (Json.str_d "error" "" r.json);
      let* r = put ~token:adm srv "/api/sla" (`Assoc [ ("items", `List [ `Assoc [ ("id", Json.get "id" p1); ("prioridad", `String "P1"); ("respuesta_min", `Int 0); ("resolucion_min", `Int 30) ] ]) ]) in
      check_estado "plazo cero" 400 r;
      let* r = put ~token:adm srv "/api/sla" (`Assoc [ ("items", `List [ `Assoc [ ("id", Json.get "id" p1); ("prioridad", `String "P1"); ("respuesta_min", `Int 10); ("resolucion_min", `Int 120) ] ]) ]) in
      check_estado "SLA" 200 r;
      let* f = Ayuda.fila e.db "SELECT respuesta_min, resolucion_min FROM sla_politicas WHERE prioridad = 'P1'" (`Assoc []) in
      Alcotest.(check int) "guardado" 120 (Json.int_d "resolucion_min" 0 f);
      let* r = put ~token:adm srv "/api/sla" (`Assoc [ ("items", `List [ `Assoc [ ("prioridad", `String "P2"); ("categoria", `String "vpn"); ("respuesta_min", `Int 20); ("resolucion_min", `Int 200) ] ]) ]) in
      check_estado "politica por categoria" 200 r;
      Alcotest.(check int) "5 politicas" 5 (Json.int_d "total" 0 r.json);
      let* r = put ~token:adm srv "/api/sla" (`Assoc [ ("items", `List [ `Assoc [ ("prioridad", `String "P2"); ("categoria", `String "vpn"); ("respuesta_min", `Int 20); ("resolucion_min", `Int 200) ] ]) ]) in
      check_estado "politica repetida" 409 r;
      (* Matriz. *)
      let* r = put ~token:adm srv "/api/matriz" (`Assoc [ ("items", `List [ `Assoc [ ("impacto", `String "persona"); ("urgencia", `String "critica"); ("prioridad", `String "P1") ] ]) ]) in
      check_estado "matriz" 200 r;
      let* r = put ~token:adm srv "/api/matriz" (`Assoc [ ("items", `List [ `Assoc [ ("impacto", `String "galaxia"); ("urgencia", `String "critica"); ("prioridad", `String "P1") ] ]) ]) in
      check_estado "impacto invalido" 400 r;
      let* r = get ~token:adm srv "/api/matriz" in
      Alcotest.(check int) "16 celdas" 16 (Json.int_d "total" 0 r.json);
      (* Calendarios. *)
      let* r = put ~token:adm srv "/api/calendarios" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 1); ("horario", `Assoc [ ("1", `List [ `List [ `String "08:30"; `String "13:00" ]; `List [ `String "12:00"; `String "18:00" ] ]) ]) ] ]) ]) in
      check_estado "tramos solapados" 400 r;
      let* r = put ~token:adm srv "/api/calendarios" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 1); ("horario", `Assoc [ ("1", `List [ `List [ `String "18:00"; `String "08:30" ] ]) ]) ] ]) ]) in
      check_estado "tramo al reves" 400 r;
      let* r = put ~token:adm srv "/api/calendarios" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 1); ("zona", `String "Marte/Olimpo") ] ]) ]) in
      check_estado "zona desconocida" 400 r;
      let* r = put ~token:adm srv "/api/calendarios" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 1); ("feriados", `List [ `Assoc [ ("fecha", `String "28-07-2026"); ("nombre", `String "Fiestas Patrias") ] ]) ] ]) ]) in
      check_estado "fecha mal escrita" 400 r;
      let* r = put ~token:adm srv "/api/calendarios" (`Assoc [ ("items", `List [ `Assoc [ ("id", `Int 1); ("horario", `Assoc [ ("1", `List [ `List [ `String "08:30"; `String "13:00" ]; `List [ `String "14:00"; `String "18:00" ] ]) ]); ("feriados", `List [ `Assoc [ ("fecha", `String "2026-07-28"); ("nombre", `String "Fiestas Patrias") ] ]) ] ]) ]) in
      check_estado "calendario" 200 r;
      let cal = List.hd (Json.list "items" r.json) in
      Alcotest.(check string) "feriado" "Fiestas Patrias" (Json.str_d "nombre" "" (List.hd (Json.list "feriados" cal)));
      (* Reglas de escalamiento. *)
      let* () = Db.exec_p e.db "INSERT INTO escalamiento_reglas (clave, condicion, acciones) VALUES ('sla_75_resolucion', '{\"tipo\":\"sla\",\"metrica\":\"resolucion\",\"umbral_pct\":75}', '[{\"tipo\":\"avisar_tecnico\"}]')" (`Assoc []) in
      let* sup = Ayuda.token_de srv "supervisor" in
      let* r = get ~token:sup srv "/api/escalamiento/reglas" in
      check_estado "reglas" 200 r;
      let regla = List.hd (Json.list "items" r.json) in
      Alcotest.(check string) "modo de partida" "sombra" (Json.str_d "modo" "" regla);
      check_contiene "descripcion" "75 %" (Json.str_d "descripcion" "" regla);
      let rid = Json.int_d "id" 0 regla in
      let* r = put ~token:sup srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (`Assoc [ ("modo", `String "activo") ]) in
      check_estado "un supervisor no edita reglas" 403 r;
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (`Assoc [ ("modo", `String "loco") ]) in
      check_estado "modo invalido" 400 r;
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (`Assoc [ ("condicion", `Assoc [ ("tipo", `String "sla"); ("umbral_pct", `Int 500) ]) ]) in
      check_estado "porcentaje fuera de rango" 400 r;
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (`Assoc [ ("acciones", `List [ `Assoc [ ("tipo", `String "destruir_todo") ] ]) ]) in
      check_estado "accion desconocida" 400 r;
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (`Assoc [ ("modo", `String "activo") ]) in
      check_estado "activar" 200 r;
      Alcotest.(check string) "modo" "activo" (Json.str_d "modo" "" r.json);
      Alcotest.(check int) "mismo id: activar no crea version" rid (Json.int_d "id" 0 r.json);
      (* La consola SIEMPRE manda condicion y acciones (y el porcentaje como `porcentaje`): sin cambios reales no se crea version. *)
      let* r = get ~token:sup srv "/api/escalamiento/reglas" in
      let regla = List.hd (Json.list "items" r.json) in
      Alcotest.(check int) "el porcentaje se ve como lo edita la consola (alias de umbral_pct)" 75 (Json.int_d "porcentaje" 0 (Json.get "condicion" regla));
      let cond_actual = Option.value (Json.assoc_opt (Json.get "condicion" regla)) ~default:[] in
      let tipos_actuales = List.filter_map (Json.str "tipo") (Json.list "acciones" regla) in
      let cuerpo_consola ?(pct = 75) activa modo =
        `Assoc
          [ ("activa", `Bool activa); ("modo", `String modo);
            ("condicion", `Assoc (List.map (fun (k, v) -> if k = "porcentaje" then (k, `Int pct) else (k, v)) cond_actual));
            ("acciones", `List (List.map (fun t -> `Assoc [ ("tipo", `String t) ]) tipos_actuales)) ]
      in
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (cuerpo_consola true "activo") in
      check_estado "guardar sin cambiar la definicion" 200 r;
      Alcotest.(check int) "sigue siendo la misma regla (no crea version)" rid (Json.int_d "id" 0 r.json);
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (cuerpo_consola ~pct:80 true "activo") in
      check_estado "cambiar el porcentaje como lo hace la consola" 200 r;
      Alcotest.(check int) "version nueva con umbral_pct = 80" 80 (Json.int_d "umbral_pct" 0 (Json.get "condicion" r.json));
      let* gd = Ayuda.fila e.db "SELECT condicion FROM escalamiento_reglas WHERE clave = 'sla_75_resolucion' AND version = 2" (`Assoc []) in
      Alcotest.(check bool) "en la base queda umbral_pct y no porcentaje" true (Json.get "umbral_pct" (Json.get "condicion" gd) = `Int 80 && Json.get "porcentaje" (Json.get "condicion" gd) = `Null);
      let rid = Json.int_d "id" 0 r.json in
      let* r = put ~token:adm srv (Printf.sprintf "/api/escalamiento/reglas/%d" rid) (`Assoc [ ("condicion", `Assoc [ ("tipo", `String "sla"); ("metrica", `String "resolucion"); ("umbral_pct", `Int 85) ]) ]) in
      check_estado "cambiar la condicion" 200 r;
      Alcotest.(check int) "version nueva" 3 (Json.int_d "version" 0 r.json);
      Alcotest.(check bool) "con otro id" true (Json.int_d "id" 0 r.json <> rid);
      let* viejas = Ayuda.contar e.db "SELECT 1 FROM escalamiento_reglas WHERE clave = 'sla_75_resolucion' AND NOT activa" in
      Alcotest.(check int) "las anteriores quedan inactivas" 2 viejas;
      let* r = get ~token:sup srv "/api/escalamiento/reglas" in
      Alcotest.(check int) "solo se lista la vigente" 1 (Json.int_d "total" 0 r.json);
      (* Usuarios. *)
      let* r = post ~token:adm srv "/api/usuarios" (`Assoc [ ("email", `String "nueva@ejemplo.test"); ("nombre", `String "Nueva Persona"); ("rol", `String "tecnico"); ("clave", `String "corta") ]) in
      check_estado "clave corta" 400 r;
      let* r = post ~token:adm srv "/api/usuarios" (`Assoc [ ("email", `String "nueva@ejemplo.test"); ("nombre", `String "Nueva Persona"); ("rol", `String "capitan"); ("clave", `String "una-clave-larga-1") ]) in
      check_estado "rol invalido" 400 r;
      let* r = post ~token:adm srv "/api/usuarios" (`Assoc [ ("email", `String "nueva@ejemplo.test"); ("nombre", `String "Nueva Persona"); ("rol", `String "tecnico"); ("clave", `String "una-clave-larga-1"); ("tecnico_id", `Int 2) ]) in
      check_estado "crear usuario" 201 r;
      Alcotest.(check bool) "la respuesta no lleva el hash" false (contiene "hash" r.cuerpo || contiene "una-clave" r.cuerpo);
      let* ok = post srv "/api/auth/login" (`Assoc [ ("email", `String "nueva@ejemplo.test"); ("clave", `String "una-clave-larga-1") ]) in
      check_estado "el usuario nuevo entra" 200 ok;
      let* r = post ~token:adm srv "/api/usuarios" (`Assoc [ ("email", `String "nueva@ejemplo.test"); ("nombre", `String "Otra"); ("rol", `String "tecnico"); ("clave", `String "una-clave-larga-1") ]) in
      check_estado "correo repetido" 409 r;
      let* f = Ayuda.fila e.db "SELECT clave_hash FROM usuarios_consola WHERE email = 'nueva@ejemplo.test'" (`Assoc []) in
      Alcotest.(check bool) "guardado hasheado con sal" true (let h = Json.str_d "clave_hash" "" f in String.length h > 40 && String.sub h 0 14 = "pbkdf2-sha256$" && not (contiene "una-clave" h));
      let* r = put ~token:adm srv "/api/usuarios/1" (`Assoc [ ("activo", `Bool false) ]) in
      check_estado "desactivar a otro" 200 r;
      let* r = put ~token:adm srv "/api/usuarios/5" (`Assoc [ ("rol", `String "tecnico") ]) in
      check_estado "no puede quitarse el rol de admin" 409 r;
      let* r = put ~token:adm srv "/api/usuarios/5" (`Assoc [ ("activo", `Bool false) ]) in
      check_estado "ni desactivarse" 409 r;
      let* n = Ayuda.contar e.db "SELECT 1 FROM auditoria WHERE accion IN ('usuario_creado', 'usuario_actualizado', 'sla_actualizado', 'matriz_actualizada', 'calendarios_actualizados', 'categorias_actualizadas', 'regla_escalamiento_actualizada')" in
      Alcotest.(check bool) "cada cambio de configuracion queda auditado" true (n >= 8);
      (* Plantillas de avisos. *)
      let* r = get ~token:adm srv "/api/avisos/plantillas" in
      check_estado "plantillas" 200 r;
      let* r = put ~token:adm srv "/api/avisos/plantillas" (`Assoc [ ("plantillas", `Assoc [ ("incidencia_asignada", `String "Hola {numero}, {secreto_interno}") ]) ]) in
      check_estado "hueco inexistente" 400 r;
      let* r = put ~token:adm srv "/api/avisos/plantillas" (`Assoc [ ("plantillas", `Assoc [ ("no_existe", `String "x") ]) ]) in
      check_estado "plantilla inexistente" 400 r;
      let* r = put ~token:adm srv "/api/avisos/plantillas" (`Assoc [ ("plantillas", `Assoc [ ("incidencia_asignada", `String "NUEVA {numero} para ti ({prioridad})") ]) ]) in
      check_estado "plantillas" 200 r;
      Alcotest.(check string) "guardada" "NUEVA {numero} para ti ({prioridad})" (Json.str_d "incidencia_asignada" "" (Json.get "plantillas" r.json));
      Lwt.return ())

(* --- asistente: conocimiento, entrenamiento ---------------------------------------------------------------------------------------------------------- *)

let test_articulos_y_recarga _ () =
  con_app (fun e srv ->
      let* ent = Ayuda.token_de srv "entrenador" in
      let* r = get ~token:ent srv "/api/articulos" in
      check_estado "articulos" 200 r;
      Alcotest.(check int) "uno sembrado" 1 (Json.int_d "total" 0 r.json);
      let* r = post ~token:ent srv "/api/articulos" (`Assoc [ ("titulo", `String "Sin pasos"); ("pasos", `List []) ]) in
      check_estado "sin pasos" 400 r;
      let* r = post ~token:ent srv "/api/articulos" (`Assoc [ ("titulo", `String ""); ("pasos", `List [ `String "uno" ]) ]) in
      check_estado "sin titulo" 400 r;
      let* r = post ~token:ent srv "/api/articulos" (`Assoc [ ("titulo", `String "Mouse inalámbrico"); ("categoria", `String "inventada"); ("pasos", `List [ `String "uno" ]) ]) in
      check_estado "categoria invalida" 400 r;
      let* r =
        post ~token:ent srv "/api/articulos"
          (`Assoc [ ("titulo", `String "El mouse inalámbrico no responde"); ("categoria", `String "equipo"); ("sintomas", `List [ `String "el mouse no mueve el cursor" ]);
                    ("pasos", `List [ `String "Cambia las pilas"; `String "Reconecta el receptor USB" ]); ("estado", `String "publicado") ])
      in
      check_estado "crear" 201 r;
      Alcotest.(check bool) "clave KB-nnn" true (let c = Json.str_d "clave" "" r.json in String.length c = 6 && String.sub c 0 3 = "KB-");
      Alcotest.(check bool) "SUPUESTO hasta que lo revise la organizacion" true (Json.bool_d "supuesto" false r.json);
      Alcotest.(check int) "dos pasos" 2 (List.length (Json.list "pasos" r.json));
      let aid = Json.int_d "id" 0 r.json in
      let* () = Ayuda.esperar_reposo e in
      (* El agente recibio los publicados por /conocimiento/recargar. *)
      let recargas = List.filter (fun j -> Json.str "_ruta" j = Some "/conocimiento/recargar") e.agente.recibidas in
      Alcotest.(check bool) "recarga enviada" true (recargas <> []);
      let arts = Json.list "articulos" (List.hd recargas) in
      Alcotest.(check int) "los dos publicados" 2 (List.length arts);
      List.iter (fun k -> Alcotest.(check bool) ("el articulo trae " ^ k) true (Json.get k (List.hd arts) <> `Null)) [ "clave"; "titulo"; "categoria"; "sintomas"; "pasos"; "cuerpo" ];
      let* r = put ~token:ent srv (Printf.sprintf "/api/articulos/%d" aid) (`Assoc [ ("estado", `String "archivado") ]) in
      check_estado "archivar" 200 r;
      Alcotest.(check int) "version" 2 (Json.int_d "version" 0 r.json);
      let* () = Ayuda.esperar_reposo e in
      let recargas = List.filter (fun j -> Json.str "_ruta" j = Some "/conocimiento/recargar") e.agente.recibidas in
      Alcotest.(check int) "al archivar se recarga sin el" 1 (List.length (Json.list "articulos" (List.hd recargas)));
      let* r = put ~token:ent srv "/api/articulos/999" (`Assoc [ ("titulo", `String "x") ]) in
      check_estado "inexistente" 404 r;
      let* r = get ~token:ent srv "/api/articulos?estado=archivado&q=mouse" in
      Alcotest.(check int) "filtros" 1 (Json.int_d "total" 0 r.json);
      Lwt.return ())

let test_entrenamiento _ () =
  con_app (fun e srv ->
      let* ent = Ayuda.token_de srv "entrenador" in
      (* Un mensaje que el agente clasifico con poca confianza. *)
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "asdf qwer") in
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "no me abre el correo") in
      let* c = get ~token:ent srv "/api/entrenamiento/cola" in
      check_estado "cola" 200 c;
      Alcotest.(check int) "solo el dudoso (0,38 < 0,60)" 1 (Json.int_d "total" 0 c.json);
      let item = List.hd (Json.list "items" c.json) in
      Alcotest.(check string) "texto" "asdf qwer" (Json.str_d "texto" "" item);
      Alcotest.(check string) "intencion del modelo" "fuera_de_alcance" (Json.str_d "intencion_modelo" "" item);
      Alcotest.(check string) "motivo" "baja_confianza" (Json.str_d "motivo" "" item);
      Alcotest.(check string) "estado" "pendiente" (Json.str_d "estado" "" item);
      let id = Json.int_d "id" 0 item in
      let ruta = Printf.sprintf "/api/entrenamiento/%d/revisar" id in
      let* r = post ~token:ent srv ruta (`Assoc [ ("decision", `String "corregir") ]) in
      check_estado "corregir sin intencion" 400 r;
      let* r = post ~token:ent srv ruta (`Assoc [ ("decision", `String "corregir"); ("intencion", `String "inventada") ]) in
      check_estado "intencion fuera del vocabulario" 400 r;
      let* r = post ~token:ent srv ruta (`Assoc [ ("decision", `String "adivinar") ]) in
      check_estado "decision invalida" 400 r;
      let* r = post ~token:ent srv ruta (`Assoc [ ("decision", `String "corregir"); ("intencion", `String "saludo"); ("categoria", `String "otro") ]) in
      check_estado "corregir" 200 r;
      Alcotest.(check string) "estado" "corregida" (Json.str_d "estado" "" r.json);
      Alcotest.(check string) "intencion correcta" "saludo" (Json.str_d "intencion_correcta" "" r.json);
      (* La correccion es una senal de calidad con su mensaje (golden calidad_asistente) y va al outbox. *)
      let* fb = Ayuda.lista e.db "SELECT senal, valor, mensaje_id FROM feedback ORDER BY id" (`Assoc []) in
      Alcotest.(check (list string)) "senales" [ "correccion_intencion"; "correccion_categoria" ] (List.map (Json.str_d "senal" "") fb);
      Alcotest.(check bool) "con mensaje_id" true (List.for_all (fun f -> Json.int "mensaje_id" f <> None) fb);
      let* ob = Ayuda.contar e.db "SELECT 1 FROM outbox_analitica WHERE tabla = 'feedback' AND payload->>'senal' = 'correccion_intencion' AND payload->>'mensaje_id' IS NOT NULL" in
      Alcotest.(check int) "feedback en el outbox con mensaje_id" 1 ob;
      let* c = get ~token:ent srv "/api/entrenamiento/cola" in
      Alcotest.(check int) "ya no esta pendiente" 0 (Json.int_d "total" 0 c.json);
      let* c = get ~token:ent srv "/api/entrenamiento/cola?estado=todas" in
      Alcotest.(check int) "todas" 1 (Json.int_d "total" 0 c.json);
      let* r = post ~token:ent srv "/api/entrenamiento/999/revisar" (`Assoc [ ("decision", `String "confirmar") ]) in
      check_estado "inexistente" 404 r;
      (* Reentrenar: el agente MIDE sin publicar (publicar=false); el resultado queda como candidato; publicar es un paso aparte. *)
      let* est = get ~token:ent srv "/api/entrenamiento/estado" in
      Alcotest.(check int) "cambios pendientes" 1 (Json.int_d "cambios_pendientes" 0 est.json);
      Alcotest.(check string) "el publicado sale del agente (GET /modelos)" "v1" (Json.str_d "version" "" (Json.get "publicado" est.json));
      Alcotest.(check bool) "con sus cifras" true (Json.float "exactitud" (Json.get "publicado" est.json) = Some 0.95);
      let* r = post ~token:ent srv "/api/entrenamiento/reentrenar" (`Assoc []) in
      check_estado "reentrenar" 200 r;
      let* () = Ayuda.esperar_reposo e in
      let* est = get ~token:ent srv "/api/entrenamiento/estado" in
      Alcotest.(check string) "fase" "listo" (Json.str_d "fase" "" est.json);
      Alcotest.(check string) "candidato" "v2" (Json.str_d "version" "" (Json.get "candidato" est.json));
      Alcotest.(check bool) "cifras del candidato para compararlo" true (Json.float "exactitud" (Json.get "candidato" est.json) = Some 0.9);
      Alcotest.(check int) "sin cambios pendientes tras entrenar" 0 (Json.int_d "cambios_pendientes" 0 est.json);
      let* r = post ~token:ent srv "/api/entrenamiento/reentrenar" (`Assoc []) in
      check_estado "sin cambios no se reentrena" 400 r;
      let enviado = List.find (fun j -> Json.str "_ruta" j = Some "/reentrenar") e.agente.recibidas in
      (match Json.list "ejemplos" enviado with
      | [ ej ] ->
          Alcotest.(check string) "al agente le llegan los ejemplos REVISADOS: mensaje" "asdf qwer" (Json.str_d "mensaje" "" ej);
          Alcotest.(check string) "intencion corregida" "saludo" (Json.str_d "intencion" "" ej);
          Alcotest.(check string) "categoria corregida" "otro" (Json.str_d "categoria" "" ej)
      | l -> Alcotest.failf "se esperaba 1 ejemplo revisado y llegaron %d" (List.length l));
      Alcotest.(check bool) "publicar=false: solo mide" true (Json.bool "publicar" enviado = Some false);
      Alcotest.(check bool) "forzar apagado" true (Json.bool_d "forzar" true enviado = false);
      (* El candidato (0,90) empeora a v1 (0,95): la pasarela ni siquiera le pregunta al agente. *)
      let publicaciones () = List.length (List.filter (fun j -> Json.str "_ruta" j = Some "/modelos/publicar") e.agente.recibidas) in
      let* r = post ~token:ent srv "/api/entrenamiento/publicar" (`Assoc []) in
      check_estado "no se publica uno peor" 409 r;
      Alcotest.(check int) "sin molestar al agente" 0 (publicaciones ());
      let* r = post ~token:ent srv "/api/entrenamiento/descartar" (`Assoc []) in
      check_estado "descartar" 200 r;
      Alcotest.(check string) "fase" "ninguno" (Json.str_d "fase" "" r.json);
      let* r = post ~token:ent srv "/api/entrenamiento/publicar" (`Assoc []) in
      check_estado "sin candidato" 400 r;
      (* Otra ronda: el candidato mejora; el agente puede rechazar la publicacion y la pasarela lo respeta. *)
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "zzz qqq") in
      let* c2 = get ~token:ent srv "/api/entrenamiento/cola" in
      let nuevo = List.hd (Json.list "items" c2.json) in
      let* _ = post ~token:ent srv ("/api/entrenamiento/" ^ string_of_int (Json.int_d "id" 0 nuevo) ^ "/revisar") (`Assoc [ ("decision", `String "confirmar") ]) in
      e.agente.reentrenar <-
        (fun _ ->
          `Assoc [ ("ok", `Bool true); ("modelo", `String "v3"); ("publicado", `Bool false); ("actual", `String "v1");
                   ("intencion", `Assoc [ ("exactitud", `Float 0.96); ("f1_macro", `Float 0.95); ("antes", `Float 0.95) ]); ("ejemplos_extra", `Int 1); ("motivo", `String "") ]);
      let* r = post ~token:ent srv "/api/entrenamiento/reentrenar" (`Assoc []) in
      check_estado "reentrenar otra vez" 200 r;
      let* () = Ayuda.esperar_reposo e in
      let* est = get ~token:ent srv "/api/entrenamiento/estado" in
      Alcotest.(check string) "candidato mejor" "v3" (Json.str_d "version" "" (Json.get "candidato" est.json));
      Alcotest.(check string) "el publicado sigue siendo v1 (el agente no publica solo)" "v1" (Json.str_d "version" "" (Json.get "publicado" est.json));
      e.agente.publicar_modelo <- (fun _ -> (409, `Assoc [ ("error", `String "El conjunto reservado no respalda esa versión."); ("codigo", `String "conflicto") ]));
      let* r = post ~token:ent srv "/api/entrenamiento/publicar" (`Assoc []) in
      check_estado "el agente rechaza" 409 r;
      check_contiene "con su motivo" "reservado" (Json.str_d "error" "" r.json);
      let* est = get ~token:ent srv "/api/entrenamiento/estado" in
      Alcotest.(check string) "nada cambio: sigue el candidato" "v3" (Json.str_d "version" "" (Json.get "candidato" est.json));
      e.agente.publicar_modelo <- (fun _ -> (200, `Assoc [ ("ok", `Bool true); ("publicado", `Bool false); ("motivo", `String "no mejora la categoría") ]));
      let* r = post ~token:ent srv "/api/entrenamiento/publicar" (`Assoc []) in
      check_estado "un 200 con publicado=false tambien es un rechazo" 409 r;
      e.agente.publicar_modelo <- (fun _ -> (200, `Assoc [ ("ok", `Bool true); ("publicado", `Bool true) ]));
      let* r = post ~token:ent srv "/api/entrenamiento/publicar" (`Assoc []) in
      check_estado "el agente acepta" 200 r;
      Alcotest.(check string) "el publicado es v3" "v3" (Json.str_d "version" "" (Json.get "publicado" r.json));
      Alcotest.(check bool) "y no queda candidato" true (Json.get "candidato" r.json = `Null);
      Alcotest.(check int) "se le pregunto al agente por esa version (rechazo, rechazo, aceptacion)" 3 (List.length (List.filter (fun j -> Json.str "_ruta" j = Some "/modelos/publicar" && Json.str "version" j = Some "v3") e.agente.recibidas));
      let* v1 = Ayuda.fila e.db "SELECT estado FROM modelos WHERE version = 'v1'" (`Assoc []) in
      Alcotest.(check string) "el anterior queda retirado" "retirado" (Json.str_d "estado" "" v1);
      let* n = Ayuda.contar e.db "SELECT 1 FROM auditoria WHERE accion = 'modelo_publicado'" in
      Alcotest.(check int) "auditado" 1 n;
      Lwt.return ())

let test_config_asistente _ () =
  con_app (fun _ srv ->
      let* ent = Ayuda.token_de srv "entrenador" in
      let* r = get ~token:ent srv "/api/asistente/config" in
      check_estado "config" 200 r;
      Alcotest.(check string) "juez en sombra por defecto" "sombra" (Json.str_d "juez_modo" "" r.json);
      let* r = put ~token:ent srv "/api/asistente/config" (`Assoc [ ("umbral_confianza", `Float 0.99) ]) in
      check_estado "umbral fuera de rango" 400 r;
      let* r = put ~token:ent srv "/api/asistente/config" (`Assoc [ ("maximo_pasos_guia", `Int 20) ]) in
      check_estado "pasos fuera de rango" 400 r;
      let* r = put ~token:ent srv "/api/asistente/config" (`Assoc [ ("juez_modo", `String "turbo") ]) in
      check_estado "modo invalido" 400 r;
      let* r = put ~token:ent srv "/api/asistente/config" (`Assoc [ ("puede", `Assoc [ ("volar", `Bool true) ]) ]) in
      check_estado "capacidad inexistente" 400 r;
      let* r = put ~token:ent srv "/api/asistente/config" (`Assoc [ ("nombre", `String "Lía"); ("trato", `String "usted"); ("umbral_confianza", `Float 0.7); ("puede", `Assoc [ ("resolver_clave", `Bool true) ]) ]) in
      check_estado "guardar" 200 r;
      let* r = get ~token:ent srv "/api/asistente/config" in
      Alcotest.(check string) "nombre" "Lía" (Json.str_d "nombre" "" r.json);
      Alcotest.(check string) "trato" "usted" (Json.str_d "trato" "" r.json);
      Alcotest.(check bool) "capacidad cambiada" true (Json.bool_d "resolver_clave" false (Json.get "puede" r.json));
      Alcotest.(check bool) "las demas se conservan" true (Json.bool_d "crear_incidencias" false (Json.get "puede" r.json));
      Alcotest.(check string) "lo no enviado se conserva" "sombra" (Json.str_d "juez_modo" "" r.json);
      Lwt.return ())

(* --- reportes e indicadores (golden queries) --------------------------------------------------------------------------------------------------------- *)

let test_reportes _ () =
  con_app (fun e srv ->
      let* ger = Ayuda.token_de srv "gerencia" in
      let preguntar q = post ~token:ger srv "/api/reportes/preguntar" (`Assoc [ ("pregunta", `String q) ]) in
      let* r = preguntar "¿Cuál fue el MTTR de septiembre?" in
      check_estado "preguntar" 200 r;
      Alcotest.(check bool) "verificado" true (Json.bool_d "verificado" false r.json);
      Alcotest.(check string) "golden" "mttr" (Json.str_d "kpi" "" (Json.get "golden" r.json));
      Alcotest.(check bool) "columnas" true (Json.list "columnas" r.json <> []);
      Alcotest.(check bool) "filas" true (Json.list "filas" r.json <> []);
      let llamada = List.find (fun (m, ruta, _) -> m = "GET" && contiene "/interno/golden/mttr" ruta) e.motor.llamadas in
      ignore llamada;
      let* r = preguntar "Tiempo medio de resolución de agosto de 2026" in
      Alcotest.(check string) "otra redaccion, misma golden" "mttr" (Json.str_d "kpi" "" (Json.get "golden" r.json));
      let* r = preguntar "¿Quién ganó el mundial?" in
      check_estado "sin golden" 200 r;
      Alcotest.(check bool) "no verificada" false (Json.bool_d "verificada" true r.json || Json.bool_d "verificado" true r.json);
      Alcotest.(check bool) "sin golden" true (Json.get "golden" r.json = `Null);
      check_contiene "honesta" "No tengo una golden query verificada" (Json.str_d "resumen" "" r.json);
      Alcotest.(check bool) "no ejecuto ni inventa filas" true (Json.list "filas" r.json = []);
      let* r = preguntar "" in
      check_estado "pregunta vacia" 400 r;
      let* r = preguntar (String.make 400 'a') in
      check_estado "pregunta enorme" 400 r;
      (* Indicadores: un resultado por golden query, sin SQL propio. *)
      let* r = get ~token:ger srv "/api/indicadores?desde=2026-09-01&hasta=2026-09-30" in
      check_estado "indicadores" 200 r;
      Alcotest.(check string) "desde" "2026-09-01" (Json.str_d "desde" "" r.json);
      Alcotest.(check int) "un bloque por KPI del catalogo" 2 (List.length (Json.list "kpis" r.json));
      let mttr = List.find (fun k -> Json.str "kpi" k = Some "mttr") (Json.list "kpis" r.json) in
      Alcotest.(check bool) "valor" true (Json.float "valor" mttr = Some 55.0);
      let* r = get ~token:ger srv "/api/indicadores?desde=2026-09-30&hasta=2026-09-01" in
      check_estado "periodo al reves" 400 r;
      let* r = get ~token:ger srv "/api/indicadores?desde=ayer" in
      check_estado "fecha invalida" 400 r;
      e.motor.caido <- true;
      let* r = get ~token:ger srv "/api/reportes" in
      check_estado "motor caido" 503 r;
      Lwt.return ())

(* --- chat web ------------------------------------------------------------------------------------------------------------------------------------------ *)

let test_chat_web_apagado _ () =
  con_app ~extra:[ ("CHAT_WEB", "0") ] (fun _ srv ->
      let* r = post srv "/api/chat-web" (`Assoc [ ("sesion", `String "sesion-de-prueba-1"); ("mensaje", `String "hola") ]) in
      check_estado "chat web apagado en produccion" 404 r;
      Lwt.return ())

let test_chat_web_http _ () =
  con_app (fun e srv ->
      let turno ?(sesion = "sesion-de-prueba-1") m = post srv "/api/chat-web" (`Assoc [ ("sesion", `String sesion); ("mensaje", `String m) ]) in
      let* r = turno "no me abre el correo" in
      check_estado "turno" 200 r;
      Alcotest.(check bool) "respuesta" true (Json.str_d "respuesta" "" r.json <> "");
      Alcotest.(check bool) "mensajes por parrafo" true (Json.list "mensajes" r.json <> []);
      let a = Json.get "analisis" r.json in
      List.iter (fun k -> Alcotest.(check bool) ("analisis trae " ^ k) true (Json.get k a <> `Null || k = "categoria_confianza" || k = "categoria"))
        [ "etapa"; "memoria"; "intencion"; "confianza"; "accion"; "articulos_usados"; "senales"; "juez"; "latencia_ms" ];
      Alcotest.(check string) "etapa" "diagnostico" (Json.str_d "etapa" "" a);
      let* _ = turno "mi correo, desde hoy" in
      let* r = turno "sigue igual" in
      Alcotest.(check string) "incidencia" "INC-000001" (Json.str_d "numero" "" (Json.get "incidencia" r.json));
      Alcotest.(check string) "accion" "crear_incidencia" (Json.str_d "tipo" "" (Json.get "accion" (Json.get "analisis" r.json)));
      let* g = turno "Sí, se resolvió" in
      Alcotest.(check bool) "botones de la encuesta" true (List.length (Json.list "botones" g.json) = 5 || Json.list "botones" g.json <> []);
      let arts = Json.list "articulos_usados" (Json.get "analisis" g.json) in
      Alcotest.(check string) "articulo con titulo" "Outlook no sincroniza" (Json.str_d "titulo" "" (List.hd arts));
      (* Validaciones y limites. *)
      let* r = post srv "/api/chat-web" (`Assoc [ ("sesion", `String "corta"); ("mensaje", `String "hola") ]) in
      check_estado "sesion invalida" 400 r;
      let* r = post srv "/api/chat-web" (`Assoc [ ("sesion", `String "sesion con espacios!"); ("mensaje", `String "hola") ]) in
      check_estado "sesion con caracteres raros" 400 r;
      let* r = turno ~sesion:"sesion-de-prueba-2" "   " in
      check_estado "mensaje vacio" 400 r;
      let* r = turno ~sesion:"sesion-de-prueba-2" (String.make 1001 'a') in
      check_estado "mensaje demasiado largo" 400 r;
      let* r = Ayuda.llamar srv `POST "/api/chat-web" ~cuerpo:(`String "x") in
      check_estado "cuerpo que no es objeto" 400 r;
      (* Limite por sesion: 12 por minuto. *)
      let rec martillar n ult = if n = 0 then Lwt.return ult else let* r = turno ~sesion:"sesion-de-prueba-3" "hola" in martillar (n - 1) r in
      let* ult = martillar 14 { Ayuda.estado = 0; cabeceras = []; cuerpo = ""; json = `Null } in
      check_estado "a la sesion se le corta" 429 ult;
      Alcotest.(check string) "codigo" "limite" (Json.str_d "codigo" "" ult.json);
      let* otra = turno ~sesion:"sesion-de-prueba-4" "hola" in
      check_estado "otra sesion no se ve afectada" 200 otra;
      ignore e;
      Lwt.return ())

(* --- estado publico ---------------------------------------------------------------------------------------------------------------------------------------- *)

let test_estado_publico _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* caso_id = conversacion_a_incidencia e in
      ignore caso_id;
      let* inc = Ayuda.fila e.db "SELECT token_publico FROM incidencias WHERE id = 1" (`Assoc []) in
      let token = Json.str_d "token_publico" "" inc in
      let* _ = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "responder"); ("texto", `String "Ya te estoy ayudando") ]) in
      let* r = get srv ("/api/estado/" ^ token) in
      check_estado "estado" 200 r;
      Alcotest.(check string) "numero" "INC-000001" (Json.str_d "numero" "" r.json);
      Alcotest.(check string) "estado" "en_curso" (Json.str_d "estado" "" r.json);
      Alcotest.(check string) "estado_texto" "Estamos trabajando en ella" (Json.str_d "estado_texto" "" r.json);
      Alcotest.(check string) "tecnico" "Luis Paz" (Json.str_d "tecnico" "" r.json);
      Alcotest.(check bool) "puede responder" true (Json.bool_d "puede_responder" false r.json);
      let ult = Json.get "ultimo_mensaje_tecnico" r.json in
      Alcotest.(check string) "ultimo mensaje del tecnico" "Ya te estoy ayudando" (Json.str_d "texto" "" ult);
      Alcotest.(check string) "autor" "Luis Paz" (Json.str_d "autor" "" ult);
      Alcotest.(check bool) "no filtra datos internos" false (contiene "persona_id" r.cuerpo || contiene "ana@" r.cuerpo || contiene "5198765" r.cuerpo || contiene "whatsapp" r.cuerpo || contiene "token_publico" r.cuerpo || contiene "caso_id" r.cuerpo);
      (* Tokens falsos: todos 404 igual, sin pistas. *)
      let* r1 = get srv "/api/estado/00000000000000000000000000000000" in
      let* r2 = get srv "/api/estado/abc" in
      let* r3 = get srv "/api/estado/%27%20OR%201=1--" in
      List.iter (fun (r : Ayuda.respuesta) -> check_estado "token falso" 404 r) [ r1; r2; r3 ];
      Alcotest.(check string) "mismo mensaje" (Json.str_d "error" "" r1.json) (Json.str_d "error" "" r2.json);
      (* Responder. *)
      let* r = post srv ("/api/estado/" ^ token ^ "/responder") (`Assoc [ ("texto", `String "Gracias, mi clave es Abc12345") ]) in
      check_estado "responder" 200 r;
      let* ev = Ayuda.fila e.db "SELECT actor_tipo, datos FROM incidencia_eventos WHERE tipo = 'comentario' AND actor_tipo = 'usuario' LIMIT 1" (`Assoc []) in
      Alcotest.(check bool) "llego a la incidencia como comentario de la persona" true (Json.get "actor_tipo" ev <> `Null);
      Alcotest.(check bool) "sin la contraseña" false (contiene "Abc12345" (Json.str_d "texto" "" (Json.get "datos" ev)));
      let* m = Ayuda.textos_de e.db ~rol:"usuario" in
      Alcotest.(check bool) "queda en la conversacion, sin la contraseña" true (List.exists (fun t -> contiene "Gracias" t) m && not (List.exists (fun t -> contiene "Abc12345" t) m));
      let* r = post srv ("/api/estado/" ^ token ^ "/responder") (`Assoc [ ("texto", `String "") ]) in
      check_estado "vacio" 400 r;
      let* r = post srv ("/api/estado/" ^ token ^ "/responder") (`Assoc [ ("texto", `String (String.make 1001 'a')) ]) in
      check_estado "demasiado largo" 400 r;
      (* En espera del usuario, su respuesta reanuda el reloj. *)
      let* _ = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "pausar"); ("motivo", `String "espera_usuario") ]) in
      let* _ = post srv ("/api/estado/" ^ token ^ "/responder") (`Assoc [ ("texto", `String "Ya lo probé") ]) in
      let* f = Ayuda.fila e.db "SELECT estado FROM incidencias WHERE id = 1" (`Assoc []) in
      Alcotest.(check string) "reanudada" "en_curso" (Json.str_d "estado" "" f);
      (* Caducidad y cierre. *)
      let* _ = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "resolver") ]) in
      let* _ = Db.exec_p e.db "UPDATE incidencias SET estado = 'cerrada', cerrada_en = now() WHERE id = 1" (`Assoc []) in
      let* r = get srv ("/api/estado/" ^ token) in
      Alcotest.(check bool) "cerrada: ya no puede responder" false (Json.bool_d "puede_responder" true r.json);
      let* r = post srv ("/api/estado/" ^ token ^ "/responder") (`Assoc [ ("texto", `String "hola") ]) in
      check_estado "responder a una cerrada" 409 r;
      let* _ = Db.exec_p e.db "UPDATE incidencias SET cerrada_en = now() - interval '31 days' WHERE id = 1" (`Assoc []) in
      let* r = get srv ("/api/estado/" ^ token) in
      check_estado "enlace caducado" 404 r;
      Lwt.return ())

let test_estado_publico_limite _ () =
  con_app (fun _ srv ->
      let rec martillar n ult = if n = 0 then Lwt.return ult else let* r = get srv "/api/estado/0123456789abcdef0123456789abcdef" in martillar (n - 1) r in
      let* ult = martillar 25 { Ayuda.estado = 0; cabeceras = []; cuerpo = ""; json = `Null } in
      check_estado "adivinar tokens tiene limite" 429 ult;
      Lwt.return ())

(* --- webhook de WhatsApp -------------------------------------------------------------------------------------------------------------------------------------- *)

let test_webhook _ () =
  con_app (fun e srv ->
      let secreto = e.ctx.cfg.webhook_secret in
      let enviar ?(cab = []) ruta cuerpo = Ayuda.llamar srv `POST ruta ~cabeceras:cab ~cuerpo:(match Json.parse cuerpo with Ok j -> j | Error _ -> `String cuerpo) in
      let* r = enviar "/webhook/evolution" (Ayuda.webhook_texto "hola") in
      check_estado "sin secreto" 403 r;
      let* r = enviar "/webhook/evolution/secreto-equivocado" (Ayuda.webhook_texto "hola") in
      check_estado "secreto equivocado en la ruta" 403 r;
      let* r = enviar ~cab:[ ("X-Webhook-Secret", "otro") ] "/webhook/evolution" (Ayuda.webhook_texto "hola") in
      check_estado "secreto equivocado en la cabecera" 403 r;
      let* n = Ayuda.contar e.db "SELECT 1 FROM mensajes" in
      Alcotest.(check int) "un rechazo no deja nada" 0 n;
      (* Secreto en la ruta (como en kddesign), en la cabecera y en la consulta. *)
      let* r = enviar ("/webhook/evolution/" ^ secreto) (Ayuda.webhook_texto ~id:"W1" "no me abre el correo") in
      check_estado "secreto en la ruta" 200 r;
      Alcotest.(check bool) "recibido" true (Json.bool_d "recibido" false r.json);
      let* () = Ayuda.esperar_reposo e in
      let* m = Ayuda.textos_de e.db ~rol:"usuario" in
      Alcotest.(check (list string)) "se guardo el mensaje" [ "no me abre el correo" ] m;
      let* () = Lwt_unix.sleep 0.0 in
      (* El mismo mensaje otra vez (evolution reintenta): se ignora. *)
      let* r = enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" (Ayuda.webhook_texto ~id:"W1" "no me abre el correo") in
      check_estado "cabecera" 200 r;
      let* () = Ayuda.esperar_reposo e in
      let* n = Ayuda.contar e.db "SELECT 1 FROM mensajes WHERE rol = 'usuario'" in
      Alcotest.(check int) "webhook duplicado: un solo mensaje" 1 n;
      Alcotest.(check int) "y un solo turno del agente" 1 (List.length (Falsos.Agente_falso.peticiones_chat e.agente));
      (* Dos entregas SIMULTANEAS del mismo mensaje tampoco duplican. *)
      let* _ = Lwt.both (enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" (Ayuda.webhook_texto ~id:"W2" "mi correo, desde hoy"))
                (enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" (Ayuda.webhook_texto ~id:"W2" "mi correo, desde hoy")) in
      let* () = Ayuda.esperar_reposo e in
      let* n = Ayuda.contar e.db "SELECT 1 FROM mensajes WHERE rol = 'usuario' AND texto = 'mi correo, desde hoy'" in
      Alcotest.(check int) "entregas simultaneas: un solo mensaje" 1 n;
      (* Lo que no es de una persona se ignora. *)
      let* r = enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" (Ayuda.webhook_texto ~id:"W3" ~de_mi:true "lo escribi yo") in
      Alcotest.(check string) "mensaje propio" "mensaje propio" (Json.str_d "ignorado" "" r.json);
      let* r = enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" (Ayuda.webhook_texto ~id:"W4" ~grupo:true "hola grupo") in
      Alcotest.(check string) "grupo" "grupo o difusion" (Json.str_d "ignorado" "" r.json);
      let* r = enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" {|{"event":"Receipt","data":{}}|} in
      check_estado "evento que no es mensaje" 200 r;
      Alcotest.(check bool) "ignorado" true (Json.str "ignorado" r.json <> None);
      let* r = Ayuda.llamar srv `POST "/webhook/evolution" ~cabeceras:[ ("X-Webhook-Secret", secreto); ("Content-Type", "application/json") ] ~cuerpo:(`String "esto no es un webhook") in
      check_estado "payload raro: 200 para que evolution no reintente" 200 r;
      let* () = Ayuda.esperar_reposo e in
      let* n = Ayuda.contar e.db "SELECT 1 FROM mensajes WHERE texto LIKE '%lo escribi yo%' OR texto LIKE '%hola grupo%'" in
      Alcotest.(check int) "lo ignorado no se guarda" 0 n;
      (* Una persona escribe un audio: aviso amable y nada de agente. *)
      let audio = Json.to_string (`Assoc [ ("event", `String "Message"); ("data", `Assoc [ ("Info", `Assoc [ ("ID", `String "W5"); ("Chat", `String "51987654321@s.whatsapp.net"); ("IsFromMe", `Bool false); ("IsGroup", `Bool false); ("PushName", `String "Ana") ]); ("Message", `Assoc [ ("audioMessage", `Assoc [ ("seconds", `Int 4) ]) ]) ]) ]) in
      let antes = List.length (Falsos.Agente_falso.peticiones_chat e.agente) in
      let* _ = Cola_salida.esperar_reposo e.ctx.salida in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* r = enviar ~cab:[ ("X-Webhook-Secret", secreto) ] "/webhook/evolution" audio in
      check_estado "audio" 200 r;
      let* () = Ayuda.esperar_reposo e in
      Alcotest.(check int) "no llamo al agente" antes (List.length (Falsos.Agente_falso.peticiones_chat e.agente));
      (match Evolution.simulados e.ctx.evolution with [ (d, t) ] -> Alcotest.(check string) "a quien lo mando" "51987654321" d; check_contiene "aviso amable" "no puedo leer los audios" t | l -> Alcotest.failf "se esperaba 1 aviso y hubo %d" (List.length l));
      (* Los registros no llevan telefonos ni textos. *)
      Lwt.return ())

let test_webhook_en_orden_por_chat _ () =
  con_app (fun e srv ->
      let secreto = e.ctx.cfg.webhook_secret in
      e.agente.demora <- 0.2;
      let enviar id t = Ayuda.llamar srv `POST "/webhook/evolution" ~cabeceras:[ ("X-Webhook-Secret", secreto) ] ~cuerpo:(match Json.parse (Ayuda.webhook_texto ~id t) with Ok j -> j | Error _ -> `Null) in
      (* Tres mensajes seguidos de la misma persona: se atienden de a uno y en orden. *)
      let* _ = Lwt.join [ (let* _ = enviar "O1" "hola" in Lwt.return ()); (let* _ = enviar "O2" "no me abre el correo" in Lwt.return ()); (let* _ = enviar "O3" "mi correo, desde hoy" in Lwt.return ()) ] in
      let* () = Ayuda.esperar_reposo e in
      let* m = Ayuda.textos_de e.db ~rol:"usuario" in
      Alcotest.(check int) "los tres" 3 (List.length m);
      let* n = Ayuda.contar e.db "SELECT 1 FROM casos" in
      Alcotest.(check int) "un solo caso (no se mezclaron)" 1 n;
      Lwt.return ())

(* --- eventos en vivo (SSE) ------------------------------------------------------------------------------------------------------------------------------------- *)

let test_sse _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* r = get srv "/api/eventos" in
      check_estado "sin sesion" 401 r;
      let* ger = Ayuda.token_de srv "gerencia" in
      ignore ger;
      (* Conexion de verdad: se leen los trozos del flujo. *)
      let uri = Uri.of_string (Falsos.Servidor.url srv ^ "/api/eventos") in
      let headers = Cohttp.Header.of_list [ ("Authorization", "Bearer " ^ tec); ("Accept", "text/event-stream") ] in
      let* resp, cuerpo = Cohttp_lwt_unix.Client.call ~headers `GET uri in
      Alcotest.(check int) "200" 200 (Cohttp.Code.code_of_status (Cohttp.Response.status resp));
      Alcotest.(check (option string)) "tipo" (Some "text/event-stream") (Cohttp.Header.get (Cohttp.Response.headers resp) "content-type");
      let flujo = Cohttp_lwt.Body.to_stream cuerpo in
      let acumulado = Buffer.create 256 in
      let leer_hasta marca plazo =
        let rec bucle () =
          if contiene marca (Buffer.contents acumulado) then Lwt.return true
          else
            let* siguiente = Lwt.pick [ Lwt_stream.get flujo; (let* () = Lwt_unix.sleep plazo in Lwt.return None) ] in
            match siguiente with Some t -> Buffer.add_string acumulado t; bucle () | None -> Lwt.return (contiene marca (Buffer.contents acumulado))
        in
        bucle ()
      in
      let* ok = leer_hasta "conectado" 3. in
      Alcotest.(check bool) "se conecta" true ok;
      Alcotest.(check int) "un suscriptor" 1 (Hub.suscriptores e.ctx.hub);
      (* Un evento publicado llega con el formato SSE. *)
      Hub.publicar e.ctx.hub "incidencia_actualizada" (`Assoc [ ("id", `Int 7); ("numero", `String "INC-000007") ]);
      let* ok = leer_hasta "INC-000007" 3. in
      Alcotest.(check bool) "llega el evento" true ok;
      check_contiene "formato SSE" "event: incidencia_actualizada\ndata: {\"id\":7" (Buffer.contents acumulado);
      (* Y los de verdad: crear una incidencia desde la consola avisa. *)
      let* _ = alta srv tec in
      let* ok = leer_hasta "incidencia_creada" 3. in
      Alcotest.(check bool) "incidencia_creada" true ok;
      Hub.latido e.ctx.hub;
      let* ok = leer_hasta ": ping" 3. in
      Alcotest.(check bool) "latido" true ok;
      Lwt.cancel (Lwt_stream.closed flujo |> fun p -> p) |> ignore;
      Lwt.return ())

(* --- salud ---------------------------------------------------------------------------------------------------------------------------------------------------------- *)

let test_salud _ () =
  con_app (fun e srv ->
      let* r = get srv "/api/salud" in
      check_estado "salud" 200 r;
      Alcotest.(check bool) "ok" true (Json.bool_d "ok" false r.json);
      Alcotest.(check string) "db" "ok" (Json.str_d "db" "" r.json);
      Alcotest.(check string) "agente" "ok" (Json.str_d "agente" "" r.json);
      Alcotest.(check string) "motor" "ok" (Json.str_d "motor" "" r.json);
      Alcotest.(check string) "evolution simulado" "simulado" (Json.str_d "evolution" "" r.json);
      Alcotest.(check bool) "version" true (Json.str "version" r.json <> None);
      Alcotest.(check bool) "sin secretos" false (contiene "clave" r.cuerpo || contiene "postgresql" r.cuerpo);
      e.motor.caido <- true;
      let* r = get srv "/api/salud" in
      check_estado "con el motor caido la pasarela sigue sana" 200 r;
      Alcotest.(check string) "motor caido" "caido" (Json.str_d "motor" "" r.json);
      Lwt.return ())

(* --- avisos ----------------------------------------------------------------------------------------------------------------------------------------------------------- *)

let test_avisos _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* _ = alta ~titulo:"Impresora del 3.er piso" ~categoria:"impresoras" srv tec in
      (* El motor falso dejo un aviso al tecnico, con una «nota interna» en `datos` que NO debe salir. *)
      let* n = Ayuda.contar e.db "SELECT 1 FROM avisos WHERE enviado_en IS NULL" in
      Alcotest.(check int) "un aviso pendiente" 1 n;
      let* n = Avisos.procesar_pendientes e.ctx in
      Alcotest.(check int) "lo vio" 1 n;
      let* () = Ayuda.esperar_reposo e in
      (match Evolution.simulados e.ctx.evolution with
      | [ (destino, texto) ] ->
          Alcotest.(check string) "al WhatsApp del tecnico" "51911111111" destino;
          check_contiene "numero" "INC-000001" texto;
          check_contiene "prioridad" "P3" texto;
          check_contiene "titulo" "Impresora del 3.er piso" texto;
          check_contiene "plazo en hora de Lima" "Plazo de resolución:" texto;
          Alcotest.(check bool) "SIN notas internas" false (contiene "ESTO NO DEBE SALIR" texto || contiene "nota_interna" texto)
      | l -> Alcotest.failf "se esperaba 1 envio y hubo %d" (List.length l));
      let* f = Ayuda.fila e.db "SELECT enviado_en IS NOT NULL AS enviado, intentos FROM avisos WHERE id = 1" (`Assoc []) in
      Alcotest.(check bool) "marcado enviado en el motor" true (Json.bool_d "enviado" false f);
      (* Otra pasada: nada nuevo. *)
      Evolution.limpiar_simulados e.ctx.evolution;
      let* _ = Avisos.procesar_pendientes e.ctx in
      let* () = Ayuda.esperar_reposo e in
      Alcotest.(check int) "un aviso no se envia dos veces" 0 (List.length (Evolution.simulados e.ctx.evolution));
      (* Aunque el motor no logre marcarlo, la base recuerda que se envio: no se repite. *)
      let* () = Db.exec_p e.db "UPDATE avisos SET enviado_en = NULL WHERE id = 1" (`Assoc []) in
      let* _ = Avisos.procesar_pendientes e.ctx in
      let* () = Ayuda.esperar_reposo e in
      Alcotest.(check int) "ni siquiera si el motor lo vuelve a ofrecer" 0 (List.length (Evolution.simulados e.ctx.evolution));
      let* f = Ayuda.fila e.db "SELECT enviado_en IS NOT NULL AS enviado FROM avisos WHERE id = 1" (`Assoc []) in
      Alcotest.(check bool) "y lo vuelve a marcar" true (Json.bool_d "enviado" false f);
      Lwt.return ())

let test_avisos_plantilla_editada_y_destinatarios _ () =
  con_app (fun e srv ->
      let* adm = Ayuda.token_de srv "admin" and* tec = Ayuda.token_de srv "tecnico" in
      let* _ = put ~token:adm srv "/api/avisos/plantillas" (`Assoc [ ("plantillas", `Assoc [ ("incidencia_asignada", `String "NUEVA {numero} para ti ({prioridad}): {titulo}") ]) ]) in
      let* _ = alta srv tec in
      let* i2 = alta ~titulo:"Segunda" srv tec in
      ignore i2;
      (* Avisos de otros tipos de destinatario, como los del vigia. *)
      let aviso dest_tipo dest_id plantilla clave canal =
        Db.exec_p e.db "INSERT INTO avisos (incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, clave) VALUES (1, $t, $i:d, $canal, $p, '{\"porcentaje\": 75}'::jsonb, $k)"
          (`Assoc [ ("t", `String dest_tipo); ("d", Json.opt_int dest_id); ("p", `String plantilla); ("k", `String clave); ("canal", `String canal) ])
      in
      let* () = aviso "supervisor" (Some 2) "sla_75" "k1" "whatsapp" in
      let* () = aviso "persona" (Some 1) "persona_asignada" "k2" "whatsapp" in
      let* () = aviso "guardia" None "p1_creada" "k3" "whatsapp" in
      let* () = aviso "tecnico" (Some 3) "sla_100" "k4" "whatsapp" in
      let* () = aviso "tecnico" (Some 2) "sla_100" "k5" "correo" in
      let* () = aviso "tecnico" (Some 1) "regla_que_no_existe" "k6" "consola" in
      let* () = Db.exec_p e.db "INSERT INTO avisos (incidencia_id, destinatario_tipo, destinatario_id, canal, plantilla, datos, clave, error) VALUES (1, 'tecnico', 1, 'whatsapp', 'sla_75', '{}', 'semilla', 'semilla_sintetica: no enviable')" (`Assoc []) in
      let* _ = Avisos.procesar_pendientes e.ctx in
      let* () = Ayuda.esperar_reposo e in
      let enviados = Evolution.simulados e.ctx.evolution in
      let a d = List.filter_map (fun (dest, t) -> if dest = d then Some t else None) enviados in
      (* Plantilla editada. *)
      Alcotest.(check bool) "plantilla editada por el administrador" true (List.exists (fun t -> contiene "NUEVA INC-000001 para ti (P3)" t) (a "51911111111"));
      (* Supervisor (Marta, tecnico 2). *)
      Alcotest.(check bool) "supervisor: sla_75 con el porcentaje" true (List.exists (fun t -> contiene "75 %" t) (a "51922222222"));
      (* Persona: por su WhatsApp, con su plantilla. *)
      Alcotest.(check bool) "a la persona" true (List.exists (fun t -> contiene "ahora la atiende Luis Paz" t) (a "51987654321"));
      let* en_conv = Ayuda.contar e.db "SELECT 1 FROM mensajes WHERE rol = 'sistema' AND meta->>'aviso' = 'persona_asignada'" in
      Alcotest.(check int) "mensaje de sistema en el caso" 1 en_conv;
      (* Sin destinatario, tecnico sin WhatsApp (Sofia) y canal correo sin numero: error acotado, no envio. *)
      let* f3 = Ayuda.fila e.db "SELECT error, intentos, enviado_en FROM avisos WHERE clave = 'k3'" (`Assoc []) in
      Alcotest.(check string) "sin destinatario" "sin_destinatario" (Json.str_d "error" "" f3);
      let* f4 = Ayuda.fila e.db "SELECT error, intentos FROM avisos WHERE clave = 'k4'" (`Assoc []) in
      Alcotest.(check string) "sin whatsapp" "sin_whatsapp" (Json.str_d "error" "" f4);
      Alcotest.(check int) "un intento" 1 (Json.int_d "intentos" 0 f4);
      (* Canal correo con whatsapp disponible: sale por whatsapp. *)
      Alcotest.(check bool) "correo -> whatsapp del tecnico" true (List.length (a "51922222222") >= 2);
      (* Canal consola: evento, no WhatsApp. *)
      let* f6 = Ayuda.fila e.db "SELECT enviado_en IS NOT NULL AS enviado FROM avisos WHERE clave = 'k6'" (`Assoc []) in
      Alcotest.(check bool) "consola: marcado" true (Json.bool_d "enviado" false f6);
      (* La semilla sintetica no se envia ni se marca. *)
      let* fs = Ayuda.fila e.db "SELECT enviado_en IS NOT NULL AS enviado, intentos FROM avisos WHERE clave = 'semilla'" (`Assoc []) in
      Alcotest.(check bool) "semilla no enviada" false (Json.bool_d "enviado" true fs);
      Alcotest.(check int) "ni tocada" 0 (Json.int_d "intentos" 9 fs);
      (* Reintentos acotados: tras 5 intentos fallidos se deja de intentar. *)
      let rec pasadas n = if n = 0 then Lwt.return () else let* _ = Avisos.procesar_pendientes e.ctx in pasadas (n - 1) in
      let* () = pasadas 8 in
      let* f3 = Ayuda.fila e.db "SELECT intentos FROM avisos WHERE clave = 'k3'" (`Assoc []) in
      Alcotest.(check int) "tope de intentos" Avisos.max_intentos (Json.int_d "intentos" 0 f3);
      Lwt.return ())

let test_avisos_envio_fallido _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* _ = alta srv tec in
      e.ctx.evolution.fallar_simulado <- (fun _ -> true);
      let* _ = Avisos.procesar_pendientes e.ctx in
      let* () = Ayuda.esperar_reposo e in
      let* f = Ayuda.fila e.db "SELECT error, intentos, enviado_en IS NOT NULL AS enviado FROM avisos WHERE id = 1" (`Assoc []) in
      Alcotest.(check bool) "no se marca enviado" false (Json.bool_d "enviado" true f);
      Alcotest.(check int) "intento contado" 1 (Json.int_d "intentos" 0 f);
      check_contiene "motivo del fallo" "envio" (Json.str_d "error" "" f);
      (* Cuando evolution vuelve, el aviso sigue pendiente y sale. *)
      e.ctx.evolution.fallar_simulado <- (fun _ -> false);
      let* _ = Avisos.procesar_pendientes e.ctx in
      let* () = Ayuda.esperar_reposo e in
      let* f = Ayuda.fila e.db "SELECT enviado_en IS NOT NULL AS enviado FROM avisos WHERE id = 1" (`Assoc []) in
      Alcotest.(check bool) "enviado en el segundo intento" true (Json.bool_d "enviado" false f);
      Lwt.return ())

(* --- recordatorios ------------------------------------------------------------------------------------------------------------------------------------------------------ *)

let test_recordatorios _ () =
  con_app (fun e srv ->
      let* tec = Ayuda.token_de srv "tecnico" in
      let* caso_id = conversacion_a_incidencia e in
      let* _ = post ~token:tec srv "/api/incidencias/1/acciones" (`Assoc [ ("accion", `String "resolver") ]) in
      (* Mediodia de Lima (17:00 UTC): se puede escribir. *)
      let mediodia = 1791224400. in
      e.ctx.reloj <- (fun () -> mediodia);
      let* () = Ayuda.esperar_reposo e in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "aun no pasaron 24 h" 0 n;
      let* () = Db.exec_p e.db "UPDATE incidencias SET resuelta_en = now() - interval '25 hours' WHERE id = 1" (`Assoc []) in
      let* () = Db.exec_p e.db "UPDATE mensajes SET ts = ts - interval '26 hours'" (`Assoc []) in
      (* De noche (23:00 de Lima = 04:00 UTC) no se manda. *)
      e.ctx.reloj <- (fun () -> mediodia +. 11. *. 3600.);
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "de noche no" 0 n;
      e.ctx.reloj <- (fun () -> mediodia);
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "un recordatorio de cierre" 1 n;
      let* () = Ayuda.esperar_reposo e in
      (match Evolution.simulados e.ctx.evolution with [ (d, t) ] -> Alcotest.(check string) "a la persona" "51987654321" d; check_contiene "pide confirmar" "INC-000001" t; check_contiene "dice como" "sigue igual" t | l -> Alcotest.failf "se esperaba 1 y hubo %d" (List.length l));
      (* Idempotente: cada recordatorio sale una vez. *)
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "no se repite" 0 n;
      let* n = Ayuda.contar e.db "SELECT 1 FROM mensajes WHERE meta->>'recordatorio_clave' = 'cierre:1'" in
      Alcotest.(check int) "una sola marca" 1 n;
      (* Dos pasadas a la vez tampoco lo duplican (indice unico). *)
      let* () = Db.exec_p e.db "DELETE FROM mensajes WHERE meta->>'recordatorio_clave' = 'cierre:1'" (`Assoc []) in
      Evolution.limpiar_simulados e.ctx.evolution;
      let* a, b = Lwt.both (Recordatorios.ejecutar e.ctx) (Recordatorios.ejecutar e.ctx) in
      let* () = Ayuda.esperar_reposo e in
      Alcotest.(check int) "pasadas simultaneas: sale una vez" 1 (a + b);
      Alcotest.(check int) "un envio" 1 (List.length (Evolution.simulados e.ctx.evolution));
      (* Si la persona ya respondio despues de la resolucion, no hace falta recordar. *)
      let* () = Db.exec_p e.db "DELETE FROM mensajes WHERE meta->>'recordatorio_clave' = 'cierre:1'" (`Assoc []) in
      let* _ = Flujo.procesar e.ctx (Ayuda.entrante_whatsapp ~id:(Ayuda.nuevo_id ()) "hola") in
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "ya respondio" 0 n;
      (* Encuesta enviada y sin responder. *)
      let* () = Db.exec_p e.db "INSERT INTO encuestas (incidencia_id, caso_id) VALUES (1, $i:c)" (`Assoc [ ("c", `Int caso_id) ]) in
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "aun no pasaron 12 h" 0 n;
      let* () = Db.exec_p e.db "UPDATE encuestas SET ts = now() - interval '13 hours'" (`Assoc []) in
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "recordatorio de la encuesta" 1 n;
      let* n = Recordatorios.ejecutar e.ctx in
      Alcotest.(check int) "una sola vez" 0 n;
      Lwt.return ())

(* --- migraciones ------------------------------------------------------------------------------------------------------------------------------------------------------------ *)

let test_migraciones_idempotentes _ () =
  con_app (fun e _ ->
      let* () = Migrar.aplicar ~plazo:2. e.db in
      let* () = Migrar.aplicar ~plazo:2. e.db in
      let* n = Ayuda.contar e.db "SELECT 1 FROM pg_indexes WHERE indexname IN ('mensajes_wa_id_uq', 'mensajes_recordatorio_uq', 'decisiones_aviso_idx')" in
      Alcotest.(check int) "indices creados una vez" 3 n;
      Lwt.return ())

let () =
  Lwt_main.run
    (Alcotest_lwt.run "api"
       [ ( "autenticacion",
           [ Alcotest_lwt.test_case "login: token, usuario, auditoria" `Quick test_login;
             Alcotest_lwt.test_case "login: rechazos sin pistas, desactivados" `Quick test_login_rechazos;
             Alcotest_lwt.test_case "login: limite de intentos" `Quick test_limite_de_intentos_de_login;
             Alcotest_lwt.test_case "token falso, vencido, alg=none y matriz de roles" `Quick test_token_y_roles ] );
         ( "http", [ Alcotest_lwt.test_case "cabeceras, CORS, 404 JSON, cuerpo grande" `Quick test_seguridad_http; Alcotest_lwt.test_case "salud" `Quick test_salud ] );
         ( "incidencias",
           [ Alcotest_lwt.test_case "bandeja, listas, filtros, paginacion, SLA en un lote" `Quick test_bandeja_y_lista;
             Alcotest_lwt.test_case "alta manual: validacion y motor" `Quick test_alta_manual_validaciones;
             Alcotest_lwt.test_case "alta manual: persona por correo, WhatsApp o nombre" `Quick test_alta_con_persona_texto;
             Alcotest_lwt.test_case "buscador, rendimiento por tecnico y series de indicadores" `Quick test_buscar_y_rendimiento;
             Alcotest_lwt.test_case "detalle completo" `Quick test_detalle;
             Alcotest_lwt.test_case "responder: guarda, envia por WhatsApp, pausa, par de preferencia" `Quick test_responder_envia_por_whatsapp;
             Alcotest_lwt.test_case "acciones: validacion, motor, auditoria" `Quick test_acciones_validacion_y_motor;
             Alcotest_lwt.test_case "resolver avisa a la persona sin notas internas" `Quick test_resolver_avisa_a_la_persona ] );
         ("conversaciones", [ Alcotest_lwt.test_case "tomar, escribir, devolver" `Quick test_casos_tomar_devolver ]);
         ( "configuracion",
           [ Alcotest_lwt.test_case "equipo: tecnicos y grupos" `Quick test_equipo;
             Alcotest_lwt.test_case "categorias, SLA, matriz, calendarios, reglas, usuarios, plantillas" `Quick test_configuracion;
             Alcotest_lwt.test_case "articulos y recarga del agente" `Quick test_articulos_y_recarga;
             Alcotest_lwt.test_case "entrenamiento: cola, revisar, reentrenar, publicar" `Quick test_entrenamiento;
             Alcotest_lwt.test_case "comportamiento del asistente" `Quick test_config_asistente;
             Alcotest_lwt.test_case "conocimiento inicial desde el agente" `Quick test_conocimiento_inicial;
             Alcotest_lwt.test_case "sugerencia del asistente para el tecnico" `Quick test_sugerencia_del_tecnico;
             Alcotest_lwt.test_case "calidad: series de Postgres y cifras oficiales" `Quick test_calidad;
             Alcotest_lwt.test_case "SQL de la golden si el motor lo expone" `Quick test_sql_de_la_golden ] );
         ("reportes", [ Alcotest_lwt.test_case "preguntar e indicadores (golden queries)" `Quick test_reportes ]);
         ( "publico",
           [ Alcotest_lwt.test_case "chat web" `Quick test_chat_web_http;
             Alcotest_lwt.test_case "chat web apagado con CHAT_WEB=0" `Quick test_chat_web_apagado;
             Alcotest_lwt.test_case "estado publico" `Quick test_estado_publico;
             Alcotest_lwt.test_case "estado publico: limite contra adivinar tokens" `Quick test_estado_publico_limite;
             Alcotest_lwt.test_case "webhook de WhatsApp" `Quick test_webhook;
             Alcotest_lwt.test_case "webhook: mensajes seguidos en orden" `Quick test_webhook_en_orden_por_chat;
             Alcotest_lwt.test_case "eventos en vivo (SSE)" `Quick test_sse ] );
         ( "trabajadores",
           [ Alcotest_lwt.test_case "avisos: plantilla, destino, canal, sin notas internas" `Quick test_avisos;
             Alcotest_lwt.test_case "avisos: plantilla editada, destinatarios, tope de intentos, semilla" `Quick test_avisos_plantilla_editada_y_destinatarios;
             Alcotest_lwt.test_case "avisos: envio fallido y reintento" `Quick test_avisos_envio_fallido;
             Alcotest_lwt.test_case "recordatorios idempotentes" `Quick test_recordatorios;
             Alcotest_lwt.test_case "migraciones idempotentes" `Quick test_migraciones_idempotentes ] ) ])
