package semilla

// Datos fijos de la semilla sintética. TODO es inventado: ninguna persona, número ni correo
// existe. Los números de WhatsApp empiezan por 5100000 (no son válidos) y los correos terminan
// en @empresa.example, para que ningún aviso llegue a una persona real por accidente.
//
// SUPUESTO: sedes, áreas, técnicos, grupos y turnos son de ejemplo (CONTEXT.md §7).

var sedesSemilla = []string{"Sede Central", "Sede Norte", "Sede Sur", "Almacén Callao"}

var areasSemilla = []string{"Contabilidad", "Logística", "Recursos Humanos", "Ventas", "Gerencia", "Legal", "Operaciones", "Tesorería"}

var nombresSemilla = []string{"Ana", "Luis", "Marta", "Pedro", "Rosa", "Jorge", "Elena", "Carlos", "Lucía", "Diego",
	"Paula", "Raúl", "Sonia", "Víctor", "Teresa", "Andrés", "Carmen", "Hugo", "Inés", "Mateo"}

var apellidosSemilla = []string{"Ríos", "Paz", "Vega", "Cruz", "Salas", "Medina", "Quispe", "Torres", "Díaz", "Flores",
	"Rojas", "Aguilar", "Castro", "Mendoza", "Silva", "Herrera", "Ramos", "Vargas", "Núñez", "Luna"}

// tecnicoSemilla describe un técnico de ejemplo.
type tecnicoSemilla struct {
	Nombre      string
	Grupo       string
	Nivel       string
	Capacidad   int
	Responsable bool     // responsable del grupo
	Supervisor  bool     // recibe los avisos «al supervisor»
	Skills      []string // categorías con su habilidad (nivel 2; 3 en las primeras)
	TurnoTarde  bool     // 12:00-18:00 en vez del horario partido
	Guardia     bool     // entra en la rotación de guardia de P1
}

var todasCategorias = []string{"correo", "cuentas_accesos", "red_wifi", "vpn", "impresoras", "equipo", "software_oficina", "sistema_interno", "telefonia", "otro"}

var tecnicosSemilla = []tecnicoSemilla{
	{Nombre: "Luis Paz", Grupo: "Mesa N1", Nivel: "N1", Capacidad: 12, Responsable: true,
		Skills: []string{"correo", "cuentas_accesos", "impresoras", "equipo", "software_oficina", "otro"}},
	{Nombre: "Marta Rojas", Grupo: "Mesa N1", Nivel: "N1", Capacidad: 12,
		Skills: []string{"correo", "cuentas_accesos", "impresoras", "equipo", "software_oficina", "otro"}},
	{Nombre: "Iván Cruz", Grupo: "Mesa N1", Nivel: "N1", Capacidad: 12,
		Skills: []string{"correo", "cuentas_accesos", "impresoras", "equipo", "software_oficina", "otro"}},
	{Nombre: "Sofía Díaz", Grupo: "Mesa N1", Nivel: "N1", Capacidad: 12, TurnoTarde: true,
		Skills: []string{"correo", "cuentas_accesos", "impresoras", "equipo", "software_oficina", "otro"}},
	{Nombre: "Carlos Vega", Grupo: "Redes", Nivel: "N2", Capacidad: 10, Responsable: true, Guardia: true,
		Skills: []string{"red_wifi", "vpn", "telefonia"}},
	{Nombre: "Elena Ríos", Grupo: "Redes", Nivel: "N2", Capacidad: 10, Guardia: true,
		Skills: []string{"red_wifi", "vpn", "telefonia"}},
	{Nombre: "Tomás Aguilar", Grupo: "Aplicaciones", Nivel: "N2", Capacidad: 10, Responsable: true,
		Skills: []string{"sistema_interno", "software_oficina"}},
	{Nombre: "Rocío Salas", Grupo: "Aplicaciones", Nivel: "N2", Capacidad: 10,
		Skills: []string{"sistema_interno", "software_oficina"}},
	{Nombre: "Jorge Medina", Grupo: "Infraestructura", Nivel: "N3", Capacidad: 25, Responsable: true, Supervisor: true, Guardia: true,
		Skills: todasCategorias},
	{Nombre: "Paola Quispe", Grupo: "Infraestructura", Nivel: "N3", Capacidad: 25, Guardia: true, Skills: todasCategorias},
	{Nombre: "Hugo Torres", Grupo: "Infraestructura", Nivel: "N3", Capacidad: 25, Guardia: true, Skills: todasCategorias},
}

// titulosPorCategoria son los títulos que propondría el asistente.
var titulosPorCategoria = map[string][]string{
	"correo":           {"Outlook no abre", "No llegan los correos nuevos", "El correo pide la contraseña una y otra vez", "Buzón lleno"},
	"cuentas_accesos":  {"No puedo iniciar sesión", "Cuenta bloqueada", "Solicito acceso a una carpeta compartida"},
	"red_wifi":         {"Sin wifi en el segundo piso", "Internet muy lento", "No hay red en la oficina"},
	"vpn":              {"La VPN se desconecta", "No conecta la VPN desde casa"},
	"impresoras":       {"La impresora no imprime", "Atasco de papel en la impresora", "Impresora sin tóner"},
	"equipo":           {"La PC no enciende", "La pantalla parpadea", "El teclado no responde", "El equipo está muy lento"},
	"software_oficina": {"Excel se cierra solo", "No abre Word", "Necesito instalar Teams"},
	"sistema_interno":  {"El sistema de ventas no carga", "Error al emitir un reporte", "No guarda el pedido"},
	"telefonia":        {"El anexo no da tono", "No entran llamadas al anexo"},
	"otro":             {"Consulta general de TI", "Solicito un monitor adicional"},
}

// pesoCategoria reparte el volumen por categoría (más correo y equipo que telefonía).
var pesoCategoria = []struct {
	Clave string
	Peso  int
}{
	{"correo", 20}, {"cuentas_accesos", 14}, {"red_wifi", 12}, {"vpn", 6}, {"impresoras", 12},
	{"equipo", 14}, {"software_oficina", 9}, {"sistema_interno", 8}, {"telefonia", 3}, {"otro", 2},
}

// frasesUsuario y frasesAsistente son los mensajes sintéticos de cada caso (sin datos personales).
var frasesUsuario = []string{
	"Hola, tengo un problema", "No me funciona desde esta mañana", "Ya probé reiniciar y sigue igual",
	"Sí, me sale un mensaje de error", "Es urgente, estoy en medio de un cierre", "Gracias", "Ya funciona, gracias",
}

var frasesAsistente = []string{
	"Hola, cuéntame qué te pasa.", "¿Desde cuándo ocurre?", "Prueba cerrar sesión y volver a entrar.",
	"¿Te aparece algún mensaje de error?", "Voy a registrar una incidencia para que te ayude un técnico.",
	"Me alegra que se haya resuelto.", "¿Pudiste resolverlo?",
}
