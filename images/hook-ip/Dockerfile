FROM linuxkit/alpine:146f540f25cd92ec8ff0c5b0c98342a9a95e479e AS mirror
RUN mkdir -p /out/etc/apk && cp -r /etc/apk/* /out/etc/apk/
RUN apk add curl
RUN apk add --no-cache --initdb -p /out \
    alpine-baselayout \
    bash \
    busybox \
    iproute2 \
    iptables \
    ebtables \
    ipvsadm \
    bridge-utils \
    musl \
    sed

# Remove apk residuals
RUN rm -rf /out/etc/apk /out/lib/apk /out/var/cache

FROM scratch
ENTRYPOINT []
CMD []
WORKDIR /
COPY --from=mirror /out/ /
