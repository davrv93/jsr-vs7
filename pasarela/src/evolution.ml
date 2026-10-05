(* Cliente de evolution-go (fork Go de Evolution API): `POST /send/text` con la cabecera `apikey`.

   Dos modos (Config.modo_evolution):
   - Simulado (por defecto): NO manda nada; registra a donde habria enviado (telefono enmascarado y largo del texto) y
     guarda el mensaje en memoria para las pruebas. Es el modo de desarrollo y de todas las pruebas.
   - Real: envia de verdad. Solo con EVOLUTION_MODO=real y URL, clave e instancia definidas.
   AGENTS §1.4 regla 3: no se manda WhatsApp a numeros reales para probar. *)

let ( let* ) = Lwt.bind

type t = {
  modo : Config.modo_evolution;
  url : string;
  api_key : string;
  instancia : string;
  plazo : float;
  mutable simulados : (string * string) list; (* (destino, texto), el mas reciente primero; tope de 200 *)
  mutable fallar_simulado : (string -> bool); (* para pruebas: que un destino falle *)
}

let crear (c : Config.t) : t =
  { modo = c.evolution_modo; url = c.evolution_url; api_key = c.evolution_api_key; instancia = c.evolution_instancia;
    plazo = c.evolution_timeout_s; simulados = []; fallar_simulado = (fun _ -> false) }

let es_simulado e = e.modo = Config.Simulado

let simulados e = List.rev e.simulados
let limpiar_simulados e = e.simulados <- []

(* Destino -> campo `number`: el JID completo se manda tal cual; un telefono, solo digitos. *)
let campo_numero (destino : string) : (string * Json.t) list =
  if String.contains destino '@' then [ ("number", `String destino); ("formatJid", `Bool false) ] else [ ("number", `String destino) ]

type resultado = Enviado of string (* id del mensaje en WhatsApp, si lo dio *) | Fallo of string

let enviar_texto (e : t) ~(destino : string) ~(texto : string) : resultado Lwt.t =
  match e.modo with
  | Config.Simulado ->
      if e.fallar_simulado destino then Lwt.return (Fallo "simulado: fallo forzado")
      else begin
        Dream.log "[evolution simulado] enviaria a %s (%d caracteres)" (Mascara.chat destino) (String.length texto);
        e.simulados <- (destino, texto) :: (if List.length e.simulados >= 200 then List.filteri (fun i _ -> i < 199) e.simulados else e.simulados);
        Lwt.return (Enviado "simulado")
      end
  | Config.Real -> (
      let cuerpo = Json.to_string (`Assoc (campo_numero destino @ [ ("text", `String texto) ])) in
      let cabeceras = Http.json_cabeceras [ ("apikey", e.api_key) ] in
      let* r = Http.pedir ~cabeceras ~cuerpo ~plazo:e.plazo `POST (e.url ^ "/send/text") in
      match r with
      | Error f -> Lwt.return (Fallo (Http.describir f))
      | Ok (estado, resp) when estado >= 200 && estado < 300 ->
          let id =
            match Json.parse resp with
            | Ok j -> Option.value (Json.str "ID" (Json.path [ "data"; "Info" ] j)) ~default:""
            | Error _ -> ""
          in
          Lwt.return (Enviado id)
      | Ok (estado, _) -> Lwt.return (Fallo (Printf.sprintf "evolution respondio HTTP %d" estado)))

(* Para /api/salud: simulado, ok, caido. *)
let estado (e : t) : string Lwt.t =
  match e.modo with
  | Config.Simulado -> Lwt.return "simulado"
  | Config.Real -> (
      let* r = Http.pedir ~cabeceras:[ ("apikey", e.api_key) ] ~plazo:4.0 `GET (e.url ^ "/instance/status") in
      match r with Ok (estado, _) when estado >= 200 && estado < 300 -> Lwt.return "ok" | _ -> Lwt.return "caido")
