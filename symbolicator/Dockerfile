ARG SYMBOLICATOR_IMAGE
FROM ${SYMBOLICATOR_IMAGE} as symbolicator

FROM debian:trixie-slim

COPY --from=symbolicator /bin/symbolicator /bin/symbolicator
COPY --from=symbolicator /etc/symbolicator /etc/symbolicator
COPY --from=symbolicator /data /data
COPY --from=symbolicator /bin/symbolicator /bin/symbolicator

VOLUME ["/etc/symbolicator", "/data"]
EXPOSE 3021

ENTRYPOINT ["/bin/symbolicator"]
