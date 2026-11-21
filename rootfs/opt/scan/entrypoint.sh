#!/bin/bash
# Registers the scanner with SANE and brscan-skey, then runs brscan-skey in the foreground.
set -euo pipefail

SKEY_DIR=/opt/brother/scanner/brscan-skey
log() { echo "[brscan] $*"; }
die() { log "ERROR: $*"; exit 1; }

[ -n "${SCANNER_IP:-}" ] || die "SCANNER_IP is required"
[ -d "$OUTPUT_DIR" ]     || die "$OUTPUT_DIR is not mounted (mount the Paperless consume folder there)"

# Equivalent of: brsaneconfig4 -a name=... model=... ip=...  (idempotent)
brsaneconfig4 -r Brother >/dev/null 2>&1 || true
brsaneconfig4 -a name=Brother model="$SCANNER_MODEL" ip="$SCANNER_IP" >/dev/null

# user= is the name shown on the printer's "Scan to PC" display (replaces start.sh).
# Every target (File/Image/OCR/Email) runs the same script, so keypad choices are ignored.
cat > "$SKEY_DIR/brscan-skey.config" <<CONF
password=
IMAGE="bash  /opt/scan/scantofile.sh"
OCR="bash  /opt/scan/scantofile.sh"
EMAIL="bash  /opt/scan/scantofile.sh"
FILE="bash  /opt/scan/scantofile.sh"
SEMID=b
user=${SKEY_NAME}
CONF
echo "CommunityName=${SNMP_COMMUNITY}" > "$SKEY_DIR/brscan-snmp.cfg"

mkdir -p "$OUTPUT_DIR/.brscan-tmp"
chown "$PUID:$PGID" "$OUTPUT_DIR/.brscan-tmp" 2>/dev/null || log "warning: cannot chown $OUTPUT_DIR/.brscan-tmp"

log "$SCANNER_MODEL @ $SCANNER_IP, shown as '$SKEY_NAME' -> $OUTPUT_DIR (uid $PUID:$PGID)"
log "${SCAN_RESOLUTION} dpi, $SCAN_MODE, source '$SCAN_SOURCE', blank removal=$BLANK_REMOVAL (threshold $BLANK_THRESHOLD)"
log "devices seen by brscan-skey:"
"$SKEY_DIR/brscan-skey-exe" -l 2>/dev/null | sed 's/^/  /' || true

# -f = foreground (Brother's own brscan-skey wrapper backgrounds the exe unless -f is given).
exec "$SKEY_DIR/brscan-skey-exe" -f
