(* Tipos del turno de conversacion y lectura de la respuesta del agente (CONTRATOS §1). *)

type respuesta_agente = {
  respuesta : string option; (* None = el backend arma el texto (flujo fijo) *)
  etapa : string option;
  memoria : Json.t option;
  intencion : string option;
  confianza : float option;
  categoria : string option;
  categoria_confianza : float option;
  accion_tipo : string;
  accion : Json.t;
  articulos : string list;
  senales : Json.t;
  texto_guardar : string;
  juez : Json.t;
  latencia_ms : int option;
  regenerada : bool;
  frases_quitadas : int;
  costo_usd : float;
  botones : string list;
  sugerencia_tecnico : Json.t; (* {texto, confianza?, articulo?} o `Null: borrador para el tecnico, no para la persona *)
  analisis_agente : Json.t; (* el `analisis` extra del agente (bitacora, top_intenciones, ...), tal cual, para el cajon del chat web *)
}

let acciones_validas = [ "ninguna"; "crear_incidencia"; "agregar_dato"; "consultar_estado"; "pedir_tecnico"; "confirmar_solucion"; "sigue_igual"; "encuesta" ]

(* Lee lo que devolvio el agente. Es tolerante: un campo que falta toma su valor neutro; una accion desconocida se vuelve
   `ninguna` (y `accion_desconocida` queda en la bitacora de decisiones). `texto_original` solo se usa si el agente no
   mando `texto_usuario_guardar`: entonces se oculta lo que parezca una credencial. *)
let leer (j : Json.t) ~(texto_original : string) : respuesta_agente =
  let accion = Json.obj "accion" j in
  let tipo = Json.str_d "tipo" "ninguna" accion in
  let tipo = if List.mem tipo acciones_validas then tipo else "ninguna" in
  let juez = Json.obj "juez" j in
  let articulos =
    List.filter_map (function `String s -> Some s | `Assoc _ as o -> Json.str "clave" o | _ -> None) (Json.list "articulos_usados" j)
  in
  let num k = Json.float k j in
  let txt k = match Json.str k j with Some s when String.trim s <> "" -> Some s | _ -> None in
  { respuesta = (match Json.str "respuesta" j with Some s when String.trim s <> "" -> Some (String.trim s) | _ -> None);
    etapa = (match Json.str "etapa" j with Some e when List.mem e Casos.etapas -> Some e | _ -> None);
    memoria = (match Json.get "memoria" j with `Assoc _ as m -> Some m | _ -> None);
    intencion = txt "intencion"; confianza = num "confianza"; categoria = txt "categoria"; categoria_confianza = num "categoria_confianza";
    accion_tipo = tipo; accion; articulos;
    senales = Json.obj "senales" j;
    texto_guardar = (match txt "texto_usuario_guardar" with Some t -> t | None -> Mascara.ocultar_credenciales texto_original);
    juez;
    latencia_ms = (match Json.get "latencia_ms" j with `Null -> None | v -> Option.map (fun f -> int_of_float (Float.round f)) (Json.float_opt v));
    (* Los tres campos siguientes no estan en CONTRATOS §1; son los que la golden query calidad_asistente necesita. Se
       aceptan en la raiz o dentro de `juez`; si no vienen, valen 0. Ver docs/CONTRATOS.md «Cambios». *)
    regenerada = (match Json.bool "regenerada" j with Some b -> b | None -> Json.bool_d "regenerada" false juez);
    frases_quitadas = (match Json.int "frases_quitadas" j with Some n -> n | None -> Json.int_d "frases_quitadas" 0 juez);
    costo_usd = (match num "costo_usd" with Some f -> f | None -> Option.value (Json.float "costo_usd" juez) ~default:0.);
    botones = List.filter_map (function `String s -> Some s | _ -> None) (Json.list "botones" j);
    sugerencia_tecnico =
      (let st = Json.obj "sugerencia_tecnico" j in
       match Json.str_ne "texto" st with
       | Some t ->
           Json.sin_nulos
             (`Assoc [ ("texto", `String (Casos.recortar 4000 t)); ("confianza", Json.opt_float (Json.float "confianza" st)); ("articulo", Json.opt_string (Json.str_ne "articulo" st)) ])
       | None -> `Null);
    analisis_agente = Json.get "analisis" j }

(* Los veredictos de Jev local como texto corto para analitica: «respaldo=respaldada,contesta=contesta_lo_preguntado». *)
let veredicto_texto (juez : Json.t) : string =
  match Json.obj "veredictos" juez with
  | `Assoc l ->
      l
      |> List.filter_map (fun (k, v) ->
             match v with
             | `String s -> Some (k ^ "=" ^ s)
             | `Assoc _ -> Option.map (fun s -> k ^ "=" ^ s) (Json.str "veredicto" v)
             | _ -> None)
      |> String.concat ","
  | _ -> ""

let modo_juez (juez : Json.t) : string = match Json.str "modo" juez with Some ("sombra" | "activo" | "apagado" as m) -> m | _ -> "apagado"

let animo (r : respuesta_agente) = Json.str_d "animo" "neutro" r.senales
let hay_queja (r : respuesta_agente) = Json.bool_d "queja" false r.senales || animo r = "muy_negativo"

(* Lo que produce ejecutar la accion del agente. *)
type efecto = {
  textos : string list; (* lo que se le dice a la persona, en orden *)
  incidencia : string option; (* numero de la incidencia creada o usada *)
  estado_caso : string option; (* nuevo `casos.estado`, si cambia *)
  accion_final : Json.t; (* lo que realmente se hizo (para el cajon de analisis del chat web) *)
}

type resultado = {
  textos : string list;
  caso_id : int option;
  incidencia : string option;
  analisis : Json.t;
  botones : string list;
  duplicado : bool;
  pausado : bool;
  derivado : bool; (* el agente no pudo responder y se uso el respaldo de cortesia *)
}

let resultado_vacio =
  { textos = []; caso_id = None; incidencia = None; analisis = `Null; botones = []; duplicado = false; pausado = false; derivado = false }
