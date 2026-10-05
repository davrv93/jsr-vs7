(* Tabla de rutas: CONTRATOS §2 (+ las que la consola necesita y el contrato no listaba, anotadas en «Cambios»). Cada ruta
   declara el rol minimo; `Auth.ruta` autentica y comprueba el rol antes de llamar al manejador. *)

open Roles

let no_encontrada : Dream.handler = fun _ -> Seguridad.respuesta_error 404 "no_encontrado" "No encontramos esa ruta."

let handler (ctx : Ctx.t) : Dream.handler =
  let r = Auth.ruta ctx in
  Dream.router
    [ (* Publico *)
      Dream.get "/api/salud" (Api_publico.salud ctx);
      Dream.post "/api/auth/login" (Auth.login ctx);
      Dream.post "/api/chat-web" (Api_publico.chat_web ctx);
      Dream.get "/api/estado/:token" (Api_publico.estado_publico ctx);
      Dream.post "/api/estado/:token/responder" (Api_publico.responder_estado ctx);
      Dream.post "/webhook/evolution" (Api_publico.webhook ctx);
      Dream.post "/webhook/evolution/:secreto" (Api_publico.webhook ctx);
      (* Sesion y eventos *)
      Dream.get "/api/yo" (r R_tecnico Auth.yo);
      Dream.get "/api/eventos" (r R_conversaciones (Api_publico.eventos ctx));
      (* Trabajo: bandeja, incidencias, conversaciones *)
      Dream.get "/api/bandeja" (r R_tecnico (Api_incidencias.bandeja ctx));
      Dream.get "/api/incidencias" (r R_tecnico (Api_incidencias.listar ctx));
      Dream.post "/api/incidencias" (r R_tecnico (Api_incidencias.crear ctx));
      Dream.get "/api/incidencias/:id" (r R_tecnico (Api_incidencias.detalle ctx));
      Dream.post "/api/incidencias/:id/acciones" (r R_tecnico (Api_incidencias.acciones ctx));
      Dream.get "/api/casos" (r R_conversaciones (Api_casos.listar ctx));
      Dream.get "/api/casos/:id/mensajes" (r R_conversaciones (Api_casos.mensajes ctx));
      Dream.post "/api/casos/:id/tomar" (r R_tecnico (Api_casos.tomar ctx));
      Dream.post "/api/casos/:id/devolver" (r R_tecnico (Api_casos.devolver ctx));
      Dream.post "/api/casos/:id/mensajes" (r R_tecnico (Api_casos.escribir ctx));
      (* Equipo *)
      Dream.get "/api/tecnicos" (r R_supervisor (Api_equipo.listar_tecnicos ctx));
      Dream.post "/api/tecnicos" (r R_supervisor (Api_equipo.crear_tecnico ctx));
      Dream.get "/api/tecnicos/:id" (r R_supervisor (Api_equipo.obtener_tecnico ctx));
      Dream.put "/api/tecnicos/:id" (r R_supervisor (Api_equipo.actualizar_tecnico ctx));
      Dream.get "/api/grupos" (r R_supervisor (Api_equipo.listar_grupos ctx));
      Dream.post "/api/grupos" (r R_supervisor (Api_equipo.crear_grupo ctx));
      Dream.put "/api/grupos/:id" (r R_supervisor (Api_equipo.actualizar_grupo ctx));
      (* Configuracion *)
      Dream.get "/api/categorias" (r R_admin (Api_config.categorias ctx));
      Dream.put "/api/categorias" (r R_admin (Api_config.guardar_categorias ctx));
      Dream.get "/api/calendarios" (r R_admin (Api_config.calendarios ctx));
      Dream.put "/api/calendarios" (r R_admin (Api_config.guardar_calendarios ctx));
      Dream.get "/api/sla" (r R_admin (Api_config.sla ctx));
      Dream.put "/api/sla" (r R_admin (Api_config.guardar_sla ctx));
      Dream.get "/api/matriz" (r R_admin (Api_config.matriz ctx));
      Dream.put "/api/matriz" (r R_admin (Api_config.guardar_matriz ctx));
      Dream.get "/api/escalamiento/reglas" (r R_supervisor (Api_config.reglas ctx));
      Dream.put "/api/escalamiento/reglas/:id" (r R_admin (Api_config.guardar_regla ctx));
      Dream.get "/api/usuarios" (r R_admin (Api_config.usuarios ctx));
      Dream.post "/api/usuarios" (r R_admin (Api_config.crear_usuario ctx));
      Dream.put "/api/usuarios/:id" (r R_admin (Api_config.actualizar_usuario ctx));
      Dream.get "/api/avisos/plantillas" (r R_admin (Api_config.plantillas ctx));
      Dream.put "/api/avisos/plantillas" (r R_admin (Api_config.guardar_plantillas ctx));
      (* Asistente *)
      Dream.get "/api/articulos" (r R_entrenador (Api_asistente.listar_articulos ctx));
      Dream.post "/api/articulos" (r R_entrenador (Api_asistente.crear_articulo ctx));
      Dream.put "/api/articulos/:id" (r R_entrenador (Api_asistente.actualizar_articulo ctx));
      Dream.get "/api/asistente/config" (r R_entrenador (Api_asistente.config ctx));
      Dream.put "/api/asistente/config" (r R_entrenador (Api_asistente.guardar_config ctx));
      Dream.get "/api/entrenamiento/cola" (r R_entrenador (Api_asistente.cola ctx));
      Dream.get "/api/entrenamiento/estado" (r R_entrenador (Api_asistente.estado ctx));
      Dream.post "/api/entrenamiento/reentrenar" (r R_entrenador (Api_asistente.reentrenar ctx));
      Dream.post "/api/entrenamiento/publicar" (r R_entrenador (Api_asistente.publicar ctx));
      Dream.post "/api/entrenamiento/descartar" (r R_entrenador (Api_asistente.descartar ctx));
      Dream.post "/api/entrenamiento/:id/revisar" (r R_entrenador (Api_asistente.revisar ctx));
      Dream.get "/api/calidad" (r R_entrenador (Api_asistente.calidad ctx));
      (* Datos *)
      Dream.get "/api/indicadores" (r R_gerencia (Api_reportes.indicadores ctx));
      Dream.get "/api/reportes" (r R_gerencia (Api_reportes.reportes ctx));
      Dream.get "/api/buscar" (r R_tecnico (Api_reportes.buscar ctx));
      Dream.post "/api/reportes/preguntar" (r R_gerencia (Api_reportes.preguntar ctx));
      Dream.any "/**" no_encontrada ]

(* El manejador completo con sus capas: cabeceras de seguridad y CORS por fuera, luego errores en JSON y registro. *)
let aplicacion (ctx : Ctx.t) : Dream.handler =
  Dream.pipeline [ Seguridad.cabeceras ctx.cfg; Seguridad.cors ctx.cfg; Seguridad.errores; Seguridad.registro ] (handler ctx)
