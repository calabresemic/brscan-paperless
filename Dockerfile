# Brother "Scan to PC" button -> blank-page-stripped PDF -> Paperless-ngx consume folder
# Replaces the brscan4 / brscan-skey VM/LXC + NFS share. amd64 only (Brother ships x86 drivers).
FROM debian:bookworm-slim

ARG BRSCAN4_URL=https://download.brother.com/welcome/dlf105200/brscan4-0.4.11-1.amd64.deb
ARG BRSCAN4_SHA256=027b73648722ac8c8eb1a9c419d284a6562cc763feac9740a2b75a683b092972
ARG SKEY_URL=https://download.brother.com/welcome/dlf006652/brscan-skey-0.3.6-0.amd64.deb
ARG SKEY_SHA256=26b480e747a61592e401ecf900fd22de69bc680cb80a130e7a2e8665180cf37c

# curl is a runtime dependency of the brscan-skey package, keep it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        sane-utils python3 python3-pil python3-img2pdf \
        procps util-linux tini ca-certificates curl tzdata; \
    cd /tmp; \
    curl -fsSL -o brscan4.deb "$BRSCAN4_URL"; echo "$BRSCAN4_SHA256  brscan4.deb" | sha256sum -c -; \
    curl -fsSL -o skey.deb    "$SKEY_URL";    echo "$SKEY_SHA256  skey.deb"       | sha256sum -c -; \
    dpkg -i --force-all brscan4.deb skey.deb; \
    test -x /opt/brother/scanner/brscan-skey/brscan-skey-exe; \
    rm -f /tmp/*.deb; rm -rf /var/lib/apt/lists/*

COPY rootfs/ /
RUN chmod 755 /opt/scan/*.sh

ENV SCANNER_IP="" \
    SCANNER_MODEL="MFC-L2690DW" \
    SKEY_NAME="Paperless-ngx" \
    SNMP_COMMUNITY="internal" \
    OUTPUT_DIR=/output \
    FILENAME_PREFIX=scan \
    SCAN_RESOLUTION=300 \
    SCAN_MODE="True Gray" \
    SCAN_SOURCE="Automatic Document Feeder(left aligned)" \
    SCAN_WIDTH_MM=211.9 \
    SCAN_HEIGHT_MM=279.4 \
    JPEG_QUALITY=85 \
    BLANK_REMOVAL=true \
    BLANK_THRESHOLD=0.01 \
    PUID=1000 \
    PGID=1000 \
    TZ=Etc/UTC

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s \
    CMD pgrep -x brscan-skey-exe >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scan/entrypoint.sh"]
