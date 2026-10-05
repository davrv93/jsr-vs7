(* Entrada de WhatsApp: normaliza el webhook de evolution-go (de internal/bot/incoming.go de kddesign) y, por
   compatibilidad, el de Evolution API v2 (`messages.upsert`). Ignora lo que no es un mensaje de una persona: eventos que
   no son mensajes, mensajes propios, grupos, difusiones, reacciones. *)

type contenido = Texto of string | No_texto of string (* audio | imagen | video | documento | sticker | ubicacion | contacto *)

type entrante = {
  canal : string; (* whatsapp | web *)
  chat_id : string; (* telefono (solo digitos) o JID si no hay telefono; en web, el id de sesion *)
  telefono : string option;
  nombre : string;
  msg_id : string option;
  contenido : contenido;
}

type resultado = Ignorar of string | Procesar of entrante

let solo_digitos (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> if c >= '0' && c <= '9' then Buffer.add_char b c) s;
  Buffer.contents b

let termina_en ~sufijo s =
  let n = String.length s and m = String.length sufijo in
  n >= m && String.sub s (n - m) m = sufijo

(* Desenvuelve los envoltorios de mensajes temporales y de «ver una vez». *)
let rec desenvolver (m : Json.t) : Json.t =
  let interno k = Json.get "message" (Json.get k m) in
  match (interno "ephemeralMessage", interno "viewOnceMessage", interno "viewOnceMessageV2", interno "documentWithCaptionMessage") with
  | (`Assoc _ as x), _, _, _ | _, (`Assoc _ as x), _, _ | _, _, (`Assoc _ as x), _ | _, _, _, (`Assoc _ as x) -> desenvolver x
  | _ -> m

let texto_no_vacio s = let t = String.trim s in if t = "" then None else Some t

(* Del cuerpo `Message` de WhatsApp al contenido, o None si no es nada que atender (reaccion, protocolo...). *)
let contenido_de_mensaje (m : Json.t) : contenido option =
  let m = desenvolver m in
  let ( >>= ) = Option.bind in
  let tiene k = Json.get k m <> `Null in
  match
    (Option.bind (Json.str "conversation" m) texto_no_vacio)
  with
  | Some t -> Some (Texto t)
  | None -> (
      match Json.str "text" (Json.get "extendedTextMessage" m) >>= texto_no_vacio with
      | Some t -> Some (Texto t)
      | None -> (
          let boton = Json.get "buttonsResponseMessage" m in
          let lista = Json.get "listResponseMessage" m in
          let plantilla = Json.get "templateButtonReplyMessage" m in
          let candidato =
            match Json.str "selectedButtonID" boton with
            | Some s when String.trim s <> "" -> Some s
            | _ -> (
                match Json.str "selectedDisplayText" boton with
                | Some s when String.trim s <> "" -> Some s
                | _ -> (
                    match Json.str "selectedRowID" (Json.get "singleSelectReply" lista) with
                    | Some s when String.trim s <> "" -> Some s
                    | _ -> (
                        match Json.str "title" lista with
                        | Some s when String.trim s <> "" -> Some s
                        | _ -> (
                            match Json.str "selectedId" plantilla with
                            | Some s when String.trim s <> "" -> Some s
                            | _ -> Json.str "selectedDisplayText" plantilla))))
          in
          match candidato >>= texto_no_vacio with
          | Some t -> Some (Texto t)
          | None ->
              let con_pie tipo clave =
                if tiene clave then
                  match Json.str "caption" (Json.get clave m) >>= texto_no_vacio with Some t -> Some (Texto t) | None -> Some (No_texto tipo)
                else None
              in
              let primero = List.find_map (fun f -> f ()) in
              primero
                [ (fun () -> con_pie "imagen" "imageMessage");
                  (fun () -> con_pie "video" "videoMessage");
                  (fun () -> con_pie "documento" "documentMessage");
                  (fun () -> if tiene "audioMessage" then Some (No_texto "audio") else None);
                  (fun () -> if tiene "stickerMessage" then Some (No_texto "sticker") else None);
                  (fun () -> if tiene "locationMessage" || tiene "liveLocationMessage" then Some (No_texto "ubicacion") else None);
                  (fun () -> if tiene "contactMessage" || tiene "contactsArrayMessage" then Some (No_texto "contacto") else None) ]))

(* Identifica el chat: telefono si el JID es de una persona; si es un @lid sin telefono alterno, el JID tal cual. *)
let chat_de ~(chat : string) ~(alterno : string) : (string * string option) option =
  let chat = if termina_en ~sufijo:"@lid" chat && termina_en ~sufijo:"@s.whatsapp.net" alterno then alterno else chat in
  if termina_en ~sufijo:"@g.us" chat || termina_en ~sufijo:"@broadcast" chat || termina_en ~sufijo:"@newsletter" chat then None
  else if termina_en ~sufijo:"@s.whatsapp.net" chat then
    let antes = String.sub chat 0 (String.length chat - String.length "@s.whatsapp.net") in
    let antes = match String.index_opt antes ':' with Some i -> String.sub antes 0 i | None -> antes in
    let d = solo_digitos antes in
    if String.length d >= 7 && String.length d <= 15 then Some (d, Some d) else Some (chat, None)
  else if chat = "" then None
  else Some (chat, None)

let limpiar_nombre (s : string) : string =
  let b = Buffer.create 32 in
  String.iter (fun c -> if Char.code c >= 32 && Char.code c <> 127 then Buffer.add_char b c) s;
  let t = String.trim (Buffer.contents b) in
  if String.length t > 80 then String.sub t 0 80 else t

let parsear (cuerpo : string) : (resultado, string) result =
  match Json.parse cuerpo with
  | Error m -> Error ("el webhook no es JSON: " ^ m)
  | Ok j -> (
      let evento = Json.str_d "event" "" j in
      let datos = Json.get "data" j in
      let armar ~id ~chat ~alterno ~de_mi ~es_grupo ~nombre ~mensaje =
        if id = "" then Ok (Ignorar "sin id de mensaje")
        else if de_mi then Ok (Ignorar "mensaje propio")
        else if es_grupo then Ok (Ignorar "grupo o difusion")
        else
          match chat_de ~chat ~alterno with
          | None -> Ok (Ignorar "grupo o difusion")
          | Some (chat_id, telefono) -> (
              match contenido_de_mensaje mensaje with
              | None -> Ok (Ignorar "sin contenido atendible")
              | Some contenido ->
                  Ok (Procesar { canal = "whatsapp"; chat_id; telefono; nombre = limpiar_nombre nombre; msg_id = Some id; contenido }))
      in
      match evento with
      | "Message" ->
          let info = Json.get "Info" datos in
          armar ~id:(Json.str_d "ID" "" info) ~chat:(Json.str_d "Chat" "" info) ~alterno:(Json.str_d "SenderAlt" "" info)
            ~de_mi:(Json.bool_d "IsFromMe" false info) ~es_grupo:(Json.bool_d "IsGroup" false info)
            ~nombre:(Json.str_d "PushName" "" info) ~mensaje:(Json.get "Message" datos)
      | "messages.upsert" | "MESSAGES_UPSERT" ->
          let key = Json.get "key" datos in
          armar ~id:(Json.str_d "id" "" key) ~chat:(Json.str_d "remoteJid" "" key) ~alterno:(Json.str_d "remoteJidAlt" "" key)
            ~de_mi:(Json.bool_d "fromMe" false key) ~es_grupo:false ~nombre:(Json.str_d "pushName" "" datos) ~mensaje:(Json.get "message" datos)
      | otro -> Ok (Ignorar ("evento " ^ otro ^ " no es un mensaje")))
