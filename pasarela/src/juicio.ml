(* Capa de juicio de la pasarela (herencia de internal/juicio de kddesign): revisa lo que PROPONE el agente antes de
   ejecutarlo. En modo `sombra` (el de partida, AGENTS §1.4 regla 6) solo lo registra en `decisiones`; en `activo`
   ademas lo aplica. Reglas de partida (SUPUESTO: se ajustan con los datos del piloto):

   1. El texto libre del asistente NO debe traer numeros de incidencia ni plazos: los escribe el codigo (CONTRATOS §1).
   2. Una queja explicita o un animo muy negativo se deriva a una persona.
   3. Una incidencia propuesta con confianza muy baja se revisa. *)

type decision = Enviar | Derivar

type salida = { decision : decision; riesgo : string; motivo : string }

let re_numero = Re.(compile (seq [ no_case (str "INC-"); rep1 digit ]))
let re_plazo = Re.(compile (seq [ alt [ no_case (str "en "); no_case (str "dentro de ") ]; rep1 digit; rep (char ' '); alt [ no_case (str "minuto"); no_case (str "hora"); no_case (str "día"); no_case (str "dia") ] ]))

let modo_valido = function "apagado" | "sombra" | "activo" -> true | _ -> false

let evaluar (r : Turno.respuesta_agente) : salida =
  let fijo = List.mem r.accion_tipo [ "crear_incidencia"; "consultar_estado"; "pedir_tecnico"; "encuesta" ] in
  let texto = Option.value r.respuesta ~default:"" in
  if (not fijo) && (Re.execp re_numero texto || Re.execp re_plazo texto) then
    { decision = Enviar; riesgo = "medio"; motivo = "el texto del asistente menciona un numero de incidencia o un plazo; eso lo escribe el codigo" }
  else if Turno.hay_queja r && r.accion_tipo = "ninguna" then
    { decision = Derivar; riesgo = "alto"; motivo = "queja explicita o animo muy negativo sin accion: conviene que lo vea una persona" }
  else if r.accion_tipo = "crear_incidencia" && (match r.confianza with Some c -> c < 0.4 | None -> false) then
    { decision = Enviar; riesgo = "medio"; motivo = "incidencia propuesta con confianza menor a 0,40 en la intencion" }
  else { decision = Enviar; riesgo = "bajo"; motivo = "sin observaciones" }

let a_json (s : salida) : Json.t =
  `Assoc
    [ ("decision", `String (match s.decision with Enviar -> "enviar" | Derivar -> "derivar")); ("riesgo", `String s.riesgo); ("motivo", `String s.motivo) ]
