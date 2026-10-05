(* Plantillas de los avisos: las de `Textos.plantillas_por_defecto`, sobreescribibles desde `configuracion` (clave
   `avisos_plantillas`, un objeto nombre -> texto) y editables por un administrador (GET/PUT /api/avisos/plantillas). Solo se
   rinden los valores de la lista blanca `Textos.claves_plantilla`: una nota interna que llegue en `datos` no sale. *)

let ( let* ) = Lwt.bind

let clave_config = "avisos_plantillas"

let cargar (db : Db.t) : (string * string) list Lwt.t =
  let* f = Db.fila_p db "SELECT valor FROM configuracion WHERE clave = $clave" (`Assoc [ ("clave", `String clave_config) ]) in
  let propias = match Json.get "valor" f with `Assoc l -> List.filter_map (fun (k, v) -> match v with `String s -> Some (k, s) | _ -> None) l | _ -> [] in
  Lwt.return (propias @ List.filter (fun (k, _) -> not (List.mem_assoc k propias)) Textos.plantillas_por_defecto)

let plantilla (todas : (string * string) list) ~(nombre : string) ~(generica : string) : string =
  match List.assoc_opt nombre todas with Some t -> t | None -> Option.value (List.assoc_opt generica todas) ~default:"Novedad en la incidencia {numero}: {titulo}."

(* Valores de una incidencia para rellenar una plantilla. `inc` es una fila de Casos.seleccion_incidencia. *)
let valores (ctx : Ctx.t) ~(inc : Json.t) ?(extra = []) () : (string * string) list =
  let ahora = Ctx.ahora ctx in
  let s k = Json.str_d k "" inc in
  let plazo k = Option.value (Tiempo.plazo_de_iso ~ahora (Json.str k inc)) ~default:"sin definir" in
  [ ("numero", s "numero"); ("prioridad", s "prioridad"); ("titulo", s "titulo"); ("estado", s "estado"); ("estado_texto", String.lowercase_ascii (Textos.estado_corto (s "estado")));
    ("tecnico", (match Json.str "tecnico" inc with Some t -> t | None -> "un técnico")); ("grupo", s "grupo"); ("categoria", s "categoria");
    ("plazo", plazo "vence_resolucion_en"); ("plazo_respuesta", plazo "vence_respuesta_en");
    ("enlace", Option.value (Textos.enlace ~base_url:ctx.cfg.base_url_publica (Json.str "token_publico" inc)) ~default:"") ]
  @ extra

let texto_para_persona (ctx : Ctx.t) (todas : (string * string) list) ~(plantilla : string) ~(inc : Json.t) : string =
  Textos.render (match List.assoc_opt plantilla todas with Some t -> t | None -> Option.value (List.assoc_opt "generica_persona" todas) ~default:"") (valores ctx ~inc ())

let guardar (db : Db.t) (nuevas : (string * string) list) : unit Lwt.t =
  Db.exec_p db
    "INSERT INTO configuracion (clave, valor, actualizado_en) VALUES ($clave, $j:valor, now()) ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado_en = now()"
    (`Assoc [ ("clave", `String clave_config); ("valor", `Assoc (List.map (fun (k, v) -> (k, `String v)) nuevas)) ])
