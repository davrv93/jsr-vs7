(* Base de conocimiento inicial: si `articulos` esta vacia, se piden al agente (GET /conocimiento/articulos), se insertan como
   SUPUESTO (supuesto = true: la organizacion aun no los reviso) y se le recargan (POST /conocimiento/recargar). Si el agente esta caido
   o no tiene la ruta (404), no pasa nada: el trabajador lo reintenta en el siguiente ciclo (cada minuto, y solo mira al agente si la
   tabla sigue vacia). Idempotente: `ON CONFLICT (clave) DO NOTHING`. *)

let ( let* ) = Lwt.bind

let ya_aviso = ref false

let clave_valida (c : string) =
  let n = String.length c in
  n >= 1 && n <= 30 && String.for_all (fun ch -> (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch = '-' || ch = '_') c

let textos (j : Json.t) (k : string) (max_items : int) (max_largo : int) : Json.t =
  `List (List.filter_map (function `String s when String.trim s <> "" -> Some (`String (Casos.recortar max_largo (String.trim s))) | _ -> None) (Json.list k j) |> List.filteri (fun i _ -> i < max_items))

(* Cuantos articulos se insertaron (0 si la tabla ya tenia, o si el agente no dio nada). *)
let ejecutar (ctx : Ctx.t) : int Lwt.t =
  let* hay = Db.fila_p ctx.db "SELECT count(*)::int AS n FROM articulos" (`Assoc []) in
  if Json.int_d "n" 0 hay > 0 then Lwt.return 0
  else begin
    let* r = Agente.articulos_iniciales ctx.agente in
    match r with
    | Error m ->
        if not !ya_aviso then begin
          ya_aviso := true;
          Dream.warning (fun l -> l "conocimiento inicial: el agente no dio los articulos (%s); se reintenta cada minuto" m)
        end;
        Lwt.return 0
    | Ok arts ->
        let validos =
          List.filter_map
            (fun a ->
              match (Json.str_ne "clave" a, Json.str_ne "titulo" a) with
              | Some clave, Some titulo when clave_valida clave && (match textos a "pasos" 30 600 with `List (_ :: _) -> true | _ -> false) ->
                  Some
                    (`Assoc
                      [ ("clave", `String clave); ("titulo", `String (Casos.recortar 200 titulo));
                        ("categoria", (match Json.str "categoria" a with Some c when List.mem c Casos.categorias -> `String c | _ -> `Null));
                        ("sintomas", textos a "sintomas" 30 300); ("pasos", textos a "pasos" 30 600); ("cuerpo", `String (Casos.recortar 20000 (Json.str_d "cuerpo" "" a))) ])
              | _ -> None)
            arts
        in
        if validos = [] then Lwt.return 0
        else begin
          let* n =
            Db.usar ctx.db (fun c ->
                Lwt_list.fold_left_s
                  (fun acc a ->
                    let* k =
                      Db.afectadas c
                        "INSERT INTO articulos (clave, titulo, categoria_id, sintomas, pasos, cuerpo, estado, supuesto) VALUES ($clave, $titulo, (SELECT id FROM categorias WHERE clave = $categoria), ARRAY(SELECT jsonb_array_elements_text($j:sintomas)), ARRAY(SELECT jsonb_array_elements_text($j:pasos)), $cuerpo, 'publicado', true) ON CONFLICT (clave) DO NOTHING"
                        a
                    in
                    Lwt.return (acc + k))
                  0 validos)
          in
          Dream.log "conocimiento inicial: %d articulos del agente insertados (supuesto = true)" n;
          let* () = if n > 0 then Api_asistente.recargar_agente ctx else Lwt.return () in
          Lwt.return n
        end
  end
