"""Pruebas de la seguridad de los datos (app/seguridad.py): contraseñas pegadas y enmascarado de datos personales.

    python -m app.prueba_seguridad

Sin red ni modelos. Lo que más importa de estas pruebas es que NO haya fugas (un secreto que sobrevive) y que NO
haya falsos positivos que arruinen una conversación normal («olvidé mi contraseña» tiene que seguir siendo legible).
"""
from __future__ import annotations

import sys
import time

from . import seguridad as S

fallos: list[str] = []
total = 0


def caso(nombre: str, obtenido, esperado) -> None:
    global total
    total += 1
    if obtenido != esperado:
        fallos.append(f"   ✗ {nombre}: {obtenido!r} (esperado {esperado!r})")


# --- 1. Secretos que SÍ se ocultan ---------------------------------------------------------------------------
OCULTAR = [
    ("mi clave es Perro123", "mi clave es [oculto]", "contrasena"),
    ("mi contraseña es Hola2026!", "mi contraseña es [oculto]", "contrasena"),
    ("password: Abc#1234x", "password: [oculto]", "contrasena"),
    ("Password = Zorro_77", "Password = [oculto]", "contrasena"),
    ("mi contraseña nueva es Gato#77, ¿está bien?", "mi contraseña nueva es [oculto], ¿está bien?", "contrasena"),
    ("usuario: jperez clave: Hola2026!", "usuario: jperez clave: [oculto]", "contrasena"),
    ("mi usuario es jperez y mi clave es 1234", "mi usuario es jperez y mi clave es [oculto]", "contrasena"),
    ("la clave que puse fue Zorro2025", "la clave que puse fue [oculto]", "contrasena"),
    ("mi clave del correo es: \"Mi Clave 99\"", "mi clave del correo es: \"[oculto]\"", "contrasena"),   # entre comillas, con espacios
    ("mi pin es 482915", "mi pin es [oculto]", "contrasena"),
    ("token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "token: [oculto]", "token"),
    ("sk-or-v1-abcdef0123456789abcdef0123456789", "[oculto]", "token"),
    ("AKIAIOSFODNN7EXAMPLE es mi llave", "[oculto] es mi llave", "token"),
    ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789", "Authorization: [oculto]", "token"),
    ("api key: AIzaSyA1234567890abcdefghijklmnopqrstuv", "api key: [oculto]", "token"),
    ("ghp_abcdefghijklmnopqrstuvwxyz0123456789", "[oculto]", "token"),
    ("Xk9#mP2$vL8@nQ4!zR7 es lo que me dieron", "[oculto] es lo que me dieron", "secuencia"),
    ("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "[oculto]", "secuencia"),
    ("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----", "[oculto]", "clave_privada"),
    ("contraseña: Jorge2024  y mi otra clave es Lima#99", "contraseña: [oculto]  y mi otra clave es [oculto]", "contrasena"),
]
for entrada, salida, tipo in OCULTAR:
    t, tipos = S.ocultar_secretos(entrada)
    if tipo is None:
        caso(f"ocultar({entrada!r}) oculta algo", "[oculto]" in t and "Mi Clave" not in t, True)
    else:
        caso(f"ocultar({entrada!r})", t, salida)
        caso(f"ocultar({entrada!r}) tipo", tipo in tipos, True)

# --- 2. Lo que NO se oculta (nada de falsos positivos) --------------------------------------------------------
NO_OCULTAR = [
    "olvidé mi contraseña",
    "necesito restablecer mi clave",
    "mi contraseña es incorrecta",
    "mi clave expiró ayer",
    "la clave que puse no funciona",
    "mi usuario está bloqueado",
    "no recuerdo mi contraseña de la VPN",
    "mi clave es la misma de siempre",
    "quiero cambiar mi contraseña por seguridad",
    "el token del banco no me llega",
    "mi pin es muy corto",
    "no puedo entrar al correo ana.rios@empresa.com",
    "mi equipo es PC-CONT-07 y la impresora HP-Piso3",
    "me sale el error 0x800CCC0E",
    "estoy en https://intranet.empresa.local/ventas/pedidos",
    "INC-000142",
    "ya reinicié la computadora",
    "Hola, buenos días",
    "",
]
for entrada in NO_OCULTAR:
    t, tipos = S.ocultar_secretos(entrada)
    caso(f"NO ocultar {entrada!r}", (t, tipos), (entrada, []))

# Idempotente y a prueba de rarezas.
t1, _ = S.ocultar_secretos("mi clave es Perro123")
caso("idempotente", S.ocultar_secretos(t1), (t1, []))
caso("tiene_secreto", (S.tiene_secreto("mi clave es Perro123"), S.tiene_secreto("hola")), (True, False))
for raro in (None, 5, [], {}):
    caso(f"ocultar({raro!r}) no revienta", isinstance(S.ocultar_secretos(raro)[0], str), True)
# Rendimiento: ningún patrón puede quedarse pensando con texto adversario.
for adversario in ("a" * 20000, "contraseña " * 2000, "clave es " * 2000, ("x" * 15 + " ") * 1300, "eyJ" + "a" * 5000 + "." + "b" * 5000, "@" * 5000, "1" * 5000):
    t0 = time.time()
    S.ocultar_secretos(adversario)
    S.enmascarar_pii(adversario, nombres=["Ana Ríos"])
    caso(f"rápido con texto adversario ({adversario[:10]!r}…)", time.time() - t0 < 1.5, True)

# --- 3. Enmascarado de datos personales ---------------------------------------------------------------------
NOMBRES = ["Ana Ríos", "Luis Paz"]
PII = [
    ("Soy Ana Ríos, de Contabilidad", "Soy [nombre], de Contabilidad"),
    ("mi correo es ana.rios@empresa.com", "mi correo es [correo]"),
    ("mi DNI es 45678912", "mi DNI es [dni]"),
    ("llámame al 987 654 321", "llámame al [telefono]"),
    ("mi cel es +51 987654321", "mi cel es [telefono]"),
    ("el servidor responde en 192.168.1.15", "el servidor responde en [ip]"),
    ("el equipo tiene la 10.0.4.23 y la 172.16.8.1", "el equipo tiene la [ip] y la [ip]"),
    ("entro a servidor01.empresa.local", "entro a [host]"),
    ("el RUC de la empresa es 20123456789", "el RUC de la empresa es [ruc]"),
    ("Luis Paz me llamó", "[nombre] me llamó"),
    ("luis paz me llamó", "[nombre] me llamó"),
    ("Ana me escribió ayer", "[nombre] me escribió ayer"),
    ("hable con Ríos", "hable con [nombre]"),
    ("mi jefe Carlos Pérez dice que es urgente", "mi jefe [nombre] dice que es urgente"),
    ("el ing. Paredes me dijo que reinicie", "el [nombre] me dijo que reinicie"),
    ("me llamo Rosa Quispe y no abre el correo", "me llamo [nombre] y no abre el correo"),
    ("mi clave es Perro123 y mi correo ana@x.pe", "mi clave es [oculto] y mi correo [correo]"),
]
for entrada, salida in PII:
    caso(f"pii({entrada!r})", S.enmascarar_pii(entrada, NOMBRES)[0], salida)
# Lo que NO es un dato personal se queda.
for entrada in ("mi equipo es PC-CONT-07", "me sale el error 0x80070005", "mi anexo es el 2045", "INC-000142 sigue abierta", "son las 14:30",
                "la impresora del piso 3 no imprime", "hola soy de Contabilidad", "tengo 12345 correos en la bandeja", "desde hace 2 días",
                "versión 10.0.19045", "Windows 11", "reunión a las 9:00 con 10 personas"):
    caso(f"pii NO toca {entrada!r}", S.enmascarar_pii(entrada, NOMBRES)[0], entrada)
t, c = S.enmascarar_pii("Soy Ana Ríos (ana@x.pe), DNI 45678912, cel 987654321, IP 10.0.0.9", NOMBRES)
caso("pii · cuenta lo enmascarado", c, {"correo": 1, "ip": 1, "telefono": 1, "dni": 1, "nombre": 1})
caso("preparar_para_llm quita secretos y datos", S.preparar_para_llm("clave: Hola2026! y mi DNI 45678912"), "clave: [oculto] y mi DNI [dni]")
caso("pii · nombres vacíos o raros", S.enmascarar_pii("hola", [None, 5, "", "ab"])[0], "hola")
caso("pii · None", S.enmascarar_pii(None)[0], "")

# Nombres del caso: perfil y técnicos.
n = S.nombres_del_caso({"nombre": "Ana Ríos"}, [{"tecnico": "Luis Paz"}, {"tecnico": None}, "x"])
caso("nombres_del_caso", n, ["Ana Ríos", "Luis Paz"])
t, _ = S.enmascarar_pii("El técnico Luis Paz atiende a Ana", n)
caso("pii · técnico y persona del caso", t, "El técnico [nombre] atiende a [nombre]")

# El síntoma que se guarda no lleva datos personales.
caso("sin_datos_personales · quita las cláusulas con datos", S.sin_datos_personales("soy Ana Ríos, mi correo es ana@x.pe, el excel se cierra solo", NOMBRES), "el excel se cierra solo")
caso("sin_datos_personales · sin datos no toca nada", S.sin_datos_personales("el excel se cierra solo", NOMBRES), "el excel se cierra solo")
caso("sin_datos_personales · todo con datos: entero y sin marcadores", S.sin_datos_personales("el DNI 45678912 no me deja entrar al sistema", NOMBRES), "el DNI no me deja entrar al sistema")

# Si el LLM repite un marcador, no llega a la persona.
caso("quitar_marcadores · nombre de pila", S.quitar_marcadores("Hola [nombre], ya lo reviso.", "Ana"), "Hola Ana, ya lo reviso.")
caso("quitar_marcadores · sin nombre", S.quitar_marcadores("Hola [nombre], ya lo reviso."), "Hola, ya lo reviso.")
caso("quitar_marcadores · otros marcadores", S.quitar_marcadores("Tu correo [correo] y tu IP [ip] están bien."), "Tu correo y tu IP están bien.")

# Lo que sale hacia un LLM nunca trae un secreto, pase lo que pase.
for crudo in ("mi clave es Perro123", "password: Abc#1234x", "token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"):
    for secreto in ("Perro123", "Abc#1234x", "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"):
        caso(f"el LLM no ve {secreto!r}", secreto in S.preparar_para_llm(crudo), False)

print(f"prueba_seguridad: {total - len(fallos)}/{total} casos")
for f in fallos:
    print(f)
sys.exit(1 if fallos else 0)
