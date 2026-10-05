# pasarela · jsrbot. Todo corre en Docker: en el Mac no hay OCaml.
#   make cimientos   construye la imagen con OCaml + dependencias (la capa cara, una sola vez)
#   make construir   compila el binario en modo release (-> dist/pasarela, ELF de Linux)
#   make probar      pruebas unitarias, de flujo y de la API contra un Postgres efimero (esquema de backend/migrations)
#   make imagen      imagen final de produccion (Alpine, usuario sin privilegios, healthcheck)
#   make humo        arranca la pasarela con el motor y el agente falsos y recorre login -> bandeja -> detalle -> accion -> chat web
CIMIENTOS ?= jsr/pasarela-cimientos:local
IMAGEN    ?= jsr/pasarela:local
export CIMIENTOS

.PHONY: cimientos construir probar imagen humo limpiar

cimientos:
	docker build -f Dockerfile.cimientos -t $(CIMIENTOS) .

construir:
	mkdir -p dist
	scripts/en-cimientos.sh sh -c 'dune build --profile release bin/main.exe && cp /home/opam/_build/default/bin/main.exe /w/dist/pasarela'
	@ls -l dist/pasarela

probar:
	scripts/probar.sh

imagen:
	docker build -t $(IMAGEN) .

humo:
	scripts/humo-docker.sh

limpiar:
	rm -rf dist _build
	-docker volume rm jsr-pasarela-build

.PHONY: carga e2e
carga:
	scripts/pg-pruebas.sh arrancar >/dev/null
	scripts/en-cimientos.sh dune build ./bin/main.exe ./test/falsos/falsos_main.exe
	DOCKER_EXTRA="--network container:jsr-pasarela-pg -e DATABASE_URL=$$(scripts/pg-pruebas.sh url)" scripts/en-cimientos.sh bash scripts/carga.sh $(N); rc=$$?; scripts/pg-pruebas.sh parar; exit $$rc

e2e:
	scripts/e2e-docker.sh
