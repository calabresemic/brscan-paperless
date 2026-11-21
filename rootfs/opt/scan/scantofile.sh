#!/bin/bash
# Called by brscan-skey when "Scan to PC" is pressed. $1 = SANE device (e.g. brother4:net1;dev0)
# scan (duplex ADF, flatbed fallback) -> PDF without blank pages -> consume folder
set -uo pipefail
exec >>/proc/1/fd/1 2>&1   # output goes to `docker logs`

DEV="${1:?missing SANE device}"
log() { echo "[scan $(date '+%F %T')] $*"; }

# One scan at a time; the printer sometimes sends a duplicate event mid-scan.
exec 9>/tmp/scan.lock
flock -n 9 || { log "ignored duplicate button event"; exit 0; }

WORK=$(mktemp -d /tmp/scan.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

COMMON=(--device-name "$DEV" --resolution "$SCAN_RESOLUTION" --mode "$SCAN_MODE"
        -l 0 -t 0 -x "$SCAN_WIDTH_MM" -y "$SCAN_HEIGHT_MM" --format=tiff)

sleep 1
log "start: $SCAN_RESOLUTION dpi, $SCAN_MODE, '$SCAN_SOURCE'"
scanimage "${COMMON[@]}" --source "$SCAN_SOURCE" --batch="$WORK/p%03d.tif" 2>&1 \
    | grep -v "rounded value" | sed 's/^/  /'

shopt -s nullglob
for p in "$WORK"/p*.tif; do [ -s "$p" ] || rm -f "$p"; done
pages=("$WORK"/p*.tif)

if [ ${#pages[@]} -eq 0 ]; then
    log "feeder empty, scanning flatbed"
    scanimage "${COMMON[@]}" --source FlatBed > "$WORK/p001.tif" 2>/dev/null
    [ -s "$WORK/p001.tif" ] || rm -f "$WORK/p001.tif"
    pages=("$WORK"/p*.tif)
fi
[ ${#pages[@]} -gt 0 ] || { log "FAILED: no pages scanned"; exit 1; }

# Builds the PDF and drops blank pages (see topdf.py; scores are logged per page)
python3 -I /opt/scan/topdf.py "$WORK/out.pdf" "${pages[@]}" || { log "FAILED: PDF conversion"; exit 1; }
FINAL="$WORK/out.pdf"

NAME="${FILENAME_PREFIX}_$(date +%Y-%m-%d_%H%M%S).pdf"
STAGE="$OUTPUT_DIR/.brscan-tmp/$NAME"
# Write to a hidden subfolder then rename, so Paperless never picks up a half-written file.
if install -o "$PUID" -g "$PGID" -m 0664 "$FINAL" "$STAGE" && mv -f "$STAGE" "$OUTPUT_DIR/$NAME"; then
    log "OK -> $NAME ($(du -h "$OUTPUT_DIR/$NAME" | cut -f1))"
else
    log "FAILED: cannot write to $OUTPUT_DIR"; exit 1
fi
