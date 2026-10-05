(* Indicadores y reportes. NINGUN KPI se calcula aqui (AGENTS §1.4 regla 7): las cifras salen de las golden queries que
   ejecuta el motor (`/interno/golden`). La pasarela solo (a) reparte la peticion, (b) elige la golden query mas parecida a una
   pregunta por sus `preguntas_equivalentes` y (c) da forma a la respuesta para la consola. *)

let ( let* ) = Lwt.bind
open Api_util

(* --- catalogo ----------------------------------------------------------------------------------------------------------------- *)

let catalogo (ctx : Ctx.t) : Json.t list Lwt.t =
  let* r = Motor.golden_catalogo ctx.motor in
  match Motor.exigir r with
  | `List l -> Lwt.return l
  | `Assoc _ as j -> Lwt.return (Json.list "kpis" j)
  | _ -> Lwt.return []

(* --- fechas (hora de Lima) ----------------------------------------------------------------------------------------------------- *)

let fecha_de (t : float) : string =
  let tm = Tiempo.lima t in
  Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

let dias_del_mes anio mes =
  match mes with 2 -> if (anio mod 4 = 0 && anio mod 100 <> 0) || anio mod 400 = 0 then 29 else 28 | 4 | 6 | 9 | 11 -> 30 | _ -> 31

let dias_entre (desde : string) (hasta : string) : int option =
  let parsear s = Tiempo.de_iso (s ^ "T00:00:00Z") in
  match (parsear desde, parsear hasta) with Some a, Some b -> Some (int_of_float ((b -. a) /. 86400.)) | _ -> None

(* ?desde=&hasta= (AAAA-MM-DD). Por defecto, los ultimos 30 dias. *)
let periodo (ctx : Ctx.t) (req : Dream.request) : string * string =
  let ahora = Ctx.ahora ctx in
  let hasta = match consulta req "hasta" with Some h -> h | None -> fecha_de ahora in
  let desde = match consulta req "desde" with Some d -> d | None -> fecha_de (ahora -. (29. *. 86400.)) in
  if not (fecha_valida desde && fecha_valida hasta) then Errores.invalido "Las fechas van como AAAA-MM-DD."
  else
    match dias_entre desde hasta with
    | Some n when n < 0 -> Errores.invalido "«desde» no puede ser posterior a «hasta»."
    | Some n when n > 731 -> Errores.invalido "El periodo no puede pasar de dos años."
    | _ -> (desde, hasta)

(* --- forma para la consola ---------------------------------------------------------------------------------------------------- *)

(* Primer numero de un texto como «SUPUESTO: 4,2 o mas»: la meta de un KPI. *)
let numero_de (s : string) : float option =
  let b = Buffer.create 8 in
  let hecho = ref false in
  String.iter
    (fun c ->
      if not !hecho then
        if (c >= '0' && c <= '9') || ((c = ',' || c = '.') && Buffer.length b > 0) then Buffer.add_char b (if c = ',' then '.' else c)
        else if Buffer.length b > 0 then hecho := true)
    s;
  float_of_string_opt (Buffer.contents b)

(* Que columna de la fila es «la cifra» de cada KPI. Es presentacion (la consola muestra un numero grande); el calculo es de la
   golden query. *)
let columna_principal = function
  | "sla_cumplimiento" | "fcr" | "contencion_asistente" | "reaperturas" | "tasa_escalamiento" -> Some "porcentaje"
  | "mttr" | "frt" -> Some "mediana_min"
  | "csat" -> Some "csat_media"
  | "calidad_asistente" -> Some "exactitud_frente_a_correcciones_pct"
  | _ -> None

let menor_es_mejor = function "mttr" | "frt" | "reaperturas" | "tasa_escalamiento" | "pendientes_antiguedad" -> true | _ -> false

let valor_principal (kpi : string) (filas : Json.t list) : float option =
  let suma col = List.fold_left (fun acc f -> match Json.float col f with Some v -> Some (Option.value acc ~default:0. +. v) | None -> acc) None filas in
  match kpi with
  | "pendientes_antiguedad" -> suma "incidencias"
  | "productividad_tecnico" -> suma "resueltas"
  | "volumen" -> (match List.find_opt (fun f -> Json.str "dimension" f = Some "total") filas with Some f -> Json.float "incidencias" f | None -> None)
  | "sla_cumplimiento" -> (
      match List.find_opt (fun f -> Json.str "metrica" f = Some "resolucion") filas with Some f -> Json.float "porcentaje" f | None -> (match filas with f :: _ -> Json.float "porcentaje" f | [] -> None))
  | k -> ( match (columna_principal k, filas) with Some col, f :: _ -> Json.float col f | _ -> None)

(* Cache de resultados de golden queries por (kpi, desde, hasta): las 12 semanas de cada sparkline serian 12 llamadas por KPI en cada
   apertura de Indicadores. Un resultado vale 5 minutos (el outbox llega a ClickHouse cada 10 s). *)
let cache_golden : (string, float * (Json.t, Motor.fallo) result) Hashtbl.t = Hashtbl.create 256

let golden_con_cache (ctx : Ctx.t) ~(kpi : string) ~(desde : string) ~(hasta : string) : (Json.t, Motor.fallo) result Lwt.t =
  let clave = String.concat "|" [ kpi; desde; hasta ] in
  let ahora = Ctx.ahora ctx in
  match Hashtbl.find_opt cache_golden clave with
  | Some (t, r) when ahora -. t < 300. -> Lwt.return r
  | _ ->
      let* r = Motor.golden ctx.motor ~kpi ~desde ~hasta ~grupo:"" in
      (* Solo se guardan los aciertos: un fallo del motor no se queda 5 minutos. *)
      if Result.is_ok r then Hashtbl.replace cache_golden clave (ahora, r);
      if Hashtbl.length cache_golden > 2000 then Hashtbl.reset cache_golden;
      Lwt.return r

let suma_dias (fecha : string) (n : int) : string =
  match Tiempo.de_iso (fecha ^ "T12:00:00Z") with Some t -> fecha_de (t +. (float_of_int n *. 86400.) +. 5. *. 3600.) | None -> fecha

(* Las 12 semanas que terminan en `hasta`, de la mas vieja a la mas nueva: [{periodo, valor}]. `periodo` es el primer dia de cada
   semana. El valor de cada una lo da la golden query de esa semana. *)
let serie_semanal (ctx : Ctx.t) ~(kpi : string) ~(tiene_desde : bool) ~(hasta : string) : Json.t list Lwt.t =
  let semanas = List.init 12 (fun i -> 11 - i) in
  Lwt_list.map_p
    (fun i ->
      let fin = suma_dias hasta (-7 * i) in
      let ini = suma_dias fin (-6) in
      let* r =
        Lwt.catch
          (fun () -> Lwt_unix.with_timeout 6. (fun () -> golden_con_cache ctx ~kpi ~desde:(if tiene_desde then ini else fin) ~hasta:fin))
          (fun _ -> Lwt.return (Error (Motor.Inalcanzable "plazo")))
      in
      let valor = match r with Ok j -> valor_principal kpi (Json.list "filas" j) | Error _ -> None in
      Lwt.return (`Assoc [ ("periodo", `String ini); ("valor", Json.opt_float valor) ]))
    semanas

let kpi_para_consola (entrada : Json.t) (resultado : (Json.t, Motor.fallo) result) ~(serie : Json.t list) ~(desde : string) ~(hasta : string) : Json.t =
  let kpi = Json.str_d "kpi" "" entrada in
  let meta = Option.bind (Json.str "objetivo" entrada) numero_de in
  let base =
    [ ("kpi", `String kpi); ("titulo", `String (Json.str_d "nombre" kpi entrada)); ("definicion", `String (Json.str_d "definicion" "" entrada));
      (* El SQL de la golden query solo se muestra si el motor lo expone (`sql` en el catalogo o en el resultado); hoy no lo hace. *)
      ("sql", `String (match Json.str_ne "sql" entrada with Some q -> q | None -> (match resultado with Ok r -> Json.str_d "sql" "" r | Error _ -> "")));
      ("unidad", `String (Json.str_d "unidad" "" entrada)); ("meta", Json.opt_float meta);
      ("sentido", `String (if menor_es_mejor kpi then "menor_mejor" else "mayor_mejor")); ("objetivo", Json.get "objetivo" entrada); ("desde", `String desde); ("hasta", `String hasta);
      ("filas", `List serie) ]
  in
  match resultado with
  | Ok r ->
      let filas = Json.list "filas" r in
      let valor = valor_principal kpi filas in
      let pide =
        match (valor, meta) with Some v, Some m -> if menor_es_mejor kpi then v > m else v < m | _ -> false
      in
      Json.sin_nulos
        (`Assoc
          (base
          @ [ ("version", Json.get "version" r); ("valor", Json.opt_float valor); ("filas_golden", `List filas); ("pide_accion", `Bool pide);
              ("detalle", (if filas = [] then `String "Sin datos en el periodo." else `Null)) ]))
  | Error f ->
      Dream.warning (fun l -> l "golden %s: %s" kpi (Motor.describir_fallo f));
      let detalle =
        match f with
        | Motor.Rechazo (_, _, msg) when msg <> "" -> msg
        | _ -> "No se pudo calcular ahora; inténtalo de nuevo en un momento."
      in
      Json.sin_nulos (`Assoc (base @ [ ("version", Json.get "version" entrada); ("valor", `Null); ("detalle", `String detalle) ]))

let indicadores (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let desde, hasta = periodo ctx req in
  let con_serie = consulta req "serie" <> Some "0" in
  let* cat = catalogo ctx in
  let* kpis =
    Lwt_list.map_p
      (fun entrada ->
        let kpi = Json.str_d "kpi" "" entrada in
        let tiene_desde = List.mem (`String "desde") (Json.list "parametros" entrada) in
        let* r = golden_con_cache ctx ~kpi ~desde ~hasta in
        let* serie = if con_serie && Result.is_ok r && valor_principal kpi (match r with Ok j -> Json.list "filas" j | Error _ -> []) <> None then serie_semanal ctx ~kpi ~tiene_desde ~hasta else Lwt.return [] in
        Lwt.return (kpi_para_consola entrada r ~serie ~desde ~hasta))
      cat
  in
  ok (`Assoc [ ("desde", `String desde); ("hasta", `String hasta); ("kpis", `List kpis) ])

(* Rendimiento por tecnico de los ultimos 30 dias: SOLO de la golden query `productividad_tecnico` (ninguna cifra se calcula
   aqui). Si el motor o ClickHouse no responden, sale vacio y la ficha muestra «—». *)
let rendimiento_por_tecnico (ctx : Ctx.t) : (int, Json.t) Hashtbl.t Lwt.t =
  let tabla = Hashtbl.create 16 in
  let hasta = fecha_de (Ctx.ahora ctx) in
  let desde = fecha_de (Ctx.ahora ctx -. (29. *. 86400.)) in
  let* r = Lwt.catch (fun () -> Lwt_unix.with_timeout 4. (fun () -> golden_con_cache ctx ~kpi:"productividad_tecnico" ~desde ~hasta)) (fun _ -> Lwt.return (Error (Motor.Inalcanzable "plazo"))) in
  (match r with
  | Ok j ->
      List.iter
        (fun f ->
          match Json.int "tecnico_id" f with
          | Some id ->
              Hashtbl.replace tabla id
                (`Assoc [ ("resueltas_30d", Json.get "resueltas" f); ("sla_cumplido_pct", `Null); ("primera_respuesta_mediana_min", Json.get "frt_mediana_min" f) ])
          | None -> ())
        (Json.list "filas" j)
  | Error _ -> ());
  Lwt.return tabla

let reportes (ctx : Ctx.t) (_u : Auth.usuario) (_req : Dream.request) : Dream.response Lwt.t =
  let* cat = catalogo ctx in
  let items =
    List.mapi
      (fun i e ->
        `Assoc
          [ ("id", `Int (i + 1)); ("nombre", Json.get "nombre" e); ("descripcion", Json.get "definicion" e); ("golden", Json.get "kpi" e); ("programado", `Null) ])
      cat
  in
  lista items (List.length items)

(* --- analista: la golden query mas parecida a la pregunta --------------------------------------------------------------------- *)

let sin_tildes (s : string) : string =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = '\xc3' && !i + 1 < n then begin
      (match s.[!i + 1] with
      | '\xa1' | '\x81' -> Buffer.add_char b 'a'
      | '\xa9' | '\x89' -> Buffer.add_char b 'e'
      | '\xad' | '\x8d' -> Buffer.add_char b 'i'
      | '\xb3' | '\x93' -> Buffer.add_char b 'o'
      | '\xba' | '\x9a' | '\xbc' | '\x9c' -> Buffer.add_char b 'u'
      | '\xb1' | '\x91' -> Buffer.add_char b 'n'
      | _ -> ());
      i := !i + 2
    end
    else begin
      Buffer.add_char b (Char.lowercase_ascii c);
      incr i
    end
  done;
  Buffer.contents b

let vacias = [ "de"; "del"; "la"; "el"; "los"; "las"; "un"; "una"; "en"; "por"; "para"; "que"; "cual"; "cuales"; "cuanto"; "cuantos"; "cuanta"; "cuantas"; "fue"; "es"; "son"; "y"; "a"; "al"; "se"; "mi"; "mis"; "nuestro"; "este"; "esta"; "como"; "hubo"; "hay"; "tuvo"; "tenemos" ]

let tokens (s : string) : string list =
  let s = sin_tildes s in
  let b = Buffer.create 16 and out = ref [] in
  let cerrar () =
    if Buffer.length b > 0 then begin
      let t = Buffer.contents b in
      if (not (List.mem t vacias)) && String.length t > 1 then out := t :: !out;
      Buffer.clear b
    end
  in
  String.iter (fun c -> if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then Buffer.add_char b c else cerrar ()) s;
  cerrar ();
  List.sort_uniq compare !out

(* Raiz grosera para que «resolvemos» y «resolver» coincidan: primeros 5 caracteres de las palabras largas. *)
let raiz t = if String.length t > 6 then String.sub t 0 5 else t

let similitud (pregunta : string list) (candidata : string list) : float =
  let a = List.sort_uniq compare (List.map raiz pregunta) and b = List.sort_uniq compare (List.map raiz candidata) in
  if a = [] || b = [] then 0.
  else
    let comunes = List.length (List.filter (fun x -> List.mem x b) a) in
    let c = float_of_int comunes in
    (* Coeficiente de Dice: reparte el parecido entre las dos frases. *)
    2. *. c /. float_of_int (List.length a + List.length b)

let mejor_golden (pregunta : string) (cat : Json.t list) : (Json.t * float) option =
  let tp = tokens pregunta in
  let puntaje entrada =
    let frases = Json.str_d "nombre" "" entrada :: List.filter_map (function `String s -> Some s | _ -> None) (Json.list "preguntas_equivalentes" entrada) in
    List.fold_left (fun m f -> Float.max m (similitud tp (tokens f))) 0. frases
  in
  let ranking = List.map (fun e -> (e, puntaje e)) cat |> List.sort (fun (_, a) (_, b) -> compare b a) in
  match ranking with (e, p) :: _ when p >= 0.45 -> Some (e, p) | _ -> None

let meses = [ ("enero", 1); ("febrero", 2); ("marzo", 3); ("abril", 4); ("mayo", 5); ("junio", 6); ("julio", 7); ("agosto", 8); ("septiembre", 9); ("setiembre", 9); ("octubre", 10); ("noviembre", 11); ("diciembre", 12) ]

(* Periodo que pide la pregunta: «de septiembre», «de agosto de 2026», «este mes», «el mes pasado», «esta semana», «hoy»; por defecto, los
   ultimos 30 dias. Los meses sin año son los del año en curso (o el anterior si el mes aun no llega). *)
let periodo_de_pregunta ~(ahora : float) (pregunta : string) : string * string * string =
  let p = sin_tildes pregunta in
  let tiene s = Re.execp (Re.compile (Re.str s)) p in
  let hoy = Tiempo.lima ahora in
  let anio = hoy.Unix.tm_year + 1900 and mes = hoy.Unix.tm_mon + 1 in
  let del_mes a m = (Printf.sprintf "%04d-%02d-01" a m, Printf.sprintf "%04d-%02d-%02d" a m (dias_del_mes a m)) in
  let mes_nombrado = List.find_opt (fun (n, _) -> tiene n) meses in
  match mes_nombrado with
  | Some (nombre, m) ->
      let a =
        match Re.exec_opt (Re.compile (Re.seq [ Re.group (Re.seq [ Re.alt [ Re.str "20" ]; Re.digit; Re.digit ]) ])) p with
        | Some g -> (match int_of_string_opt (Re.Group.get g 1) with Some y -> y | None -> anio)
        | None -> if m > mes then anio - 1 else anio
      in
      let d, h = del_mes a m in
      (d, h, "de " ^ nombre ^ " de " ^ string_of_int a)
  | None ->
      if tiene "mes pasado" || tiene "mes anterior" then
        let a, m = if mes = 1 then (anio - 1, 12) else (anio, mes - 1) in
        let d, h = del_mes a m in
        (d, h, "del mes pasado")
      else if tiene "este mes" || tiene "mes actual" then
        let d, _ = del_mes anio mes in
        (d, fecha_de ahora, "de este mes")
      else if tiene "esta semana" then
        let dow = (hoy.Unix.tm_wday + 6) mod 7 in
        (fecha_de (ahora -. (float_of_int dow *. 86400.)), fecha_de ahora, "de esta semana")
      else if tiene "hoy" then (fecha_de ahora, fecha_de ahora, "de hoy")
      else if tiene "ayer" then (fecha_de (ahora -. 86400.), fecha_de (ahora -. 86400.), "de ayer")
      else (fecha_de (ahora -. (29. *. 86400.)), fecha_de ahora, "de los últimos 30 días")

let preguntar (ctx : Ctx.t) (_u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let* b = Seguridad.cuerpo_json ~max:4096 req in
  let pregunta = texto_req ~max:300 ~nombre:"la pregunta" b "pregunta" in
  let* cat = catalogo ctx in
  match mejor_golden pregunta cat with
  | None ->
      ok
        (`Assoc
          [ ("pregunta", `String pregunta); ("golden", `Null); ("verificado", `Bool false); ("verificada", `Bool false); ("sql", `String ""); ("columnas", `List []); ("filas", `List []);
            ( "resumen",
              `String "No tengo una golden query verificada que responda esa pregunta, así que no te doy una cifra: una cifra sin definición oficial puede confundir. Prueba con otras palabras o pide a Datos que cree el reporte." );
            ("nota", `String "Sin golden query: no se ejecutó nada.");
            ("sugerencias", `List (List.filter_map (fun e -> Option.map (fun p -> `String p) (match Json.list "preguntas_equivalentes" e with `String s :: _ -> Some s | _ -> None)) (List.filteri (fun i _ -> i < 6) cat))) ])
  | Some (entrada, puntaje) -> (
      let kpi = Json.str_d "kpi" "" entrada in
      let desde, hasta, texto_periodo = periodo_de_pregunta ~ahora:(Ctx.ahora ctx) pregunta in
      let* r = Motor.golden ctx.motor ~kpi ~desde ~hasta ~grupo:"" in
      let j = Motor.exigir r in
      let filas = Json.list "filas" j in
      let columnas = match filas with `Assoc l :: _ -> List.map fst l | _ -> [] in
      let tabla = List.map (fun f -> `List (List.map (fun c -> match Json.get c f with `Float _ | `Int _ | `String _ | `Null as v -> v | v -> `String (Json.to_string v)) columnas)) filas in
      let nombre = Json.str_d "nombre" kpi entrada in
      let version = Json.get "version" j in
      let valor = valor_principal kpi filas in
      let resumen =
        match valor with
        | Some v -> Printf.sprintf "%s %s: %s %s." nombre texto_periodo (let s = Printf.sprintf "%.2f" v in if Float.is_integer v then Printf.sprintf "%.0f" v else s) (Json.str_d "unidad" "" entrada)
        | None -> if filas = [] then Printf.sprintf "%s %s: sin datos en el periodo." nombre texto_periodo else Printf.sprintf "%s %s: ve la tabla." nombre texto_periodo
      in
      ok
        (Json.sin_nulos
           (`Assoc
             [ ("pregunta", `String pregunta); ("golden", `Assoc [ ("kpi", `String kpi); ("nombre", `String nombre); ("version", version) ]); ("verificado", `Bool true); ("verificada", `Bool true);
               ("sql", `String (match Json.str_ne "sql" entrada with Some q -> q | None -> Json.str_d "sql" "" j)); ("resumen", `String resumen); ("unidad", Json.get "unidad" entrada); ("columnas", `List (List.map (fun c -> `String c) columnas)); ("filas", `List tabla);
               ("desde", `String desde); ("hasta", `String hasta); ("parecido", `Float puntaje);
               ("nota", `String (Printf.sprintf "Golden query %s v%s · del %s al %s. %s" kpi (match version with `Int i -> string_of_int i | _ -> "?") desde hasta (Json.str_d "definicion" "" entrada))) ])))

(* --- buscador global (⌘K) ------------------------------------------------------------------------------------------------------ *)

let buscar (ctx : Ctx.t) (u : Auth.usuario) (req : Dream.request) : Dream.response Lwt.t =
  let q = match consulta req "q" with Some q when String.length q >= 2 && String.length q <= 100 -> q | _ -> Errores.invalido "Escribe al menos 2 caracteres para buscar." in
  let p = `Assoc [ ("q", `String (Db.escapar_like q)) ] in
  let como col = Printf.sprintf "%s ILIKE '%%' || $q || '%%' ESCAPE '\\'" col in
  let* incidencias =
    Db.lista_p ctx.db
      ("SELECT i.id, i.numero, i.titulo, i.estado, p.nombre AS persona FROM incidencias i LEFT JOIN personas p ON p.id = i.persona_id WHERE " ^ como "i.numero" ^ " OR " ^ como "i.titulo" ^ " OR " ^ como "p.nombre"
     ^ " ORDER BY i.creada_en DESC LIMIT 5")
      p
  in
  let* personas =
    Db.lista_p ctx.db
      ("SELECT p.id, p.nombre, a.nombre AS area FROM personas p LEFT JOIN areas a ON a.id = p.area_id WHERE " ^ como "p.nombre" ^ " OR " ^ como "p.correo" ^ " OR " ^ como "p.whatsapp" ^ " ORDER BY p.nombre LIMIT 5")
      p
  in
  let* articulos =
    if Roles.permite u.rol Roles.R_entrenador then Db.lista_p ctx.db ("SELECT a.id, a.clave, a.titulo FROM articulos a WHERE " ^ como "a.titulo" ^ " OR " ^ como "a.clave" ^ " ORDER BY a.clave LIMIT 5") p else Lwt.return []
  in
  let* reportes =
    if Roles.permite u.rol Roles.R_gerencia then
      let* cat = Lwt.catch (fun () -> catalogo ctx) (fun _ -> Lwt.return []) in
      let tq = tokens q in
      Lwt.return
        (List.filteri (fun i _ -> i < 5)
           (List.filter_map
              (fun e ->
                let t = tokens (Json.str_d "nombre" "" e ^ " " ^ Json.str_d "kpi" "" e) in
                if tq <> [] && List.for_all (fun x -> List.exists (fun y -> String.length x <= String.length y && String.sub y 0 (String.length x) = x) t) tq then
                  Some (`Assoc [ ("golden", Json.get "kpi" e); ("nombre", Json.get "nombre" e) ])
                else None)
              cat))
    else Lwt.return []
  in
  ok (`Assoc [ ("incidencias", `List incidencias); ("personas", `List personas); ("articulos", `List articulos); ("reportes", `List reportes) ])
