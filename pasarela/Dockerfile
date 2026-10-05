# pasarela · imagen de produccion.
#
#   1. cimientos      OCaml + dependencias ya compiladas. Es la capa cara (10-25 min). Las instrucciones son IDENTICAS a las de
#                     Dockerfile.cimientos (hasta `opam clean`) para que Docker reutilice la capa que dejo `make cimientos`; en un
#                     servidor sin cache se paga una vez y despues solo se recompila el codigo propio.
#   2. construccion   dune build --profile release.
#   3. final          Alpine, usuario sin privilegios, solo el binario y las bibliotecas que enlaza. Sin shell de herramientas ni
#                     compilador. HEALTHCHECK con el propio binario (`pasarela salud`).
#
# Alpine (musl) de punta a punta: un binario compilado en glibc no arranca en musl.
FROM ocaml/opam:alpine-3.19-ocaml-5.1 AS cimientos
USER root
RUN apk add --no-cache gmp-dev pkgconf openssl-dev m4 libev-dev zlib-dev linux-headers \
                       postgresql-dev libffi-dev bash curl
USER opam
RUN opam update -y \
 && opam install -y dune lwt yojson re dream digestif base64 caqti caqti-lwt caqti-driver-postgresql \
                    cohttp-lwt-unix alcotest alcotest-lwt \
 && opam clean -a -c
WORKDIR /w

FROM cimientos AS construccion
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam src ./src
COPY --chown=opam:opam bin ./bin
# test/ no entra en la imagen: las pruebas corren con `make probar`. dune necesita ver que no hay mas directorios con dune.
RUN opam exec -- dune build --profile release bin/main.exe \
 && install -m 755 _build/default/bin/main.exe /tmp/pasarela \
 && strip /tmp/pasarela

FROM alpine:3.19
RUN apk add --no-cache libpq libev libssl3 libcrypto3 ca-certificates tzdata \
 && adduser -D -H -u 10001 pasarela
COPY --from=construccion /tmp/pasarela /usr/local/bin/pasarela
USER pasarela
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=6s --start-period=20s --retries=3 CMD ["/usr/local/bin/pasarela", "salud"]
ENTRYPOINT ["/usr/local/bin/pasarela"]
