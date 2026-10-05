"""Cliente HTTP minimo de ClickHouse (biblioteca estandar). Es la misma via que usa el backend:
INSERT ... FORMAT JSONEachRow con date_time_input_format=best_effort, y consultas con parametros param_<nombre>."""
import base64
import re
import urllib.error
import urllib.parse
import urllib.request


class ErrorCH(Exception):
    def __init__(self, codigo_http, mensaje):
        super().__init__(mensaje)
        self.codigo_http = codigo_http
        self.mensaje = mensaje


class Cliente:
    def __init__(self, url, usuario, clave, base=None, tiempo=120):
        self.url = url.rstrip("/")
        self.base = base
        self.tiempo = tiempo
        self._auth = "Basic " + base64.b64encode(("%s:%s" % (usuario, clave)).encode()).decode()

    def _post(self, cuerpo, params):
        # wait_end_of_query=1: ClickHouse responde HTTP 200 en cuanto empieza a transmitir, asi que un limite excedido a
        # media consulta llegaria como un 200 con el cuerpo cortado y el error escrito al final. Con esta opcion guarda
        # la respuesta y devuelve un 500 de verdad. El backend DEBE mandarla en cada consulta.
        params = dict(params, wait_end_of_query="1")
        q = urllib.parse.urlencode(params)
        req = urllib.request.Request("%s/?%s" % (self.url, q), data=cuerpo, method="POST")
        req.add_header("Authorization", self._auth)
        try:
            with urllib.request.urlopen(req, timeout=self.tiempo) as r:
                return r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            raise ErrorCH(e.code, e.read().decode("utf-8", "replace").strip())

    def consulta(self, sql, parametros=None, formato="CSVWithNames", ajustes=None):
        p = {"default_format": formato}
        if self.base:
            p["database"] = self.base
        for k, v in (parametros or {}).items():
            p["param_" + k] = v
        p.update(ajustes or {})
        return self._post(sql.encode("utf-8"), p)

    def insertar_jsonl(self, tabla, datos_bytes, ajustes=None):
        p = {"query": "INSERT INTO %s FORMAT JSONEachRow" % tabla, "date_time_input_format": "best_effort"}
        if self.base:
            p["database"] = self.base
        p.update(ajustes or {})
        self._post(datos_bytes, p)

    def ejecutar(self, sql):
        return self._post(sql.encode("utf-8"), {"database": self.base} if self.base else {})


def partir_sentencias(texto_sql):
    """Parte un archivo .sql en sentencias (los comentarios -- no llevan punto y coma por convencion)."""
    lineas = [l for l in texto_sql.splitlines() if not l.strip().startswith("--")]
    return [s.strip() for s in "\n".join(lineas).split(";") if s.strip()]
