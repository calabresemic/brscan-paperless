# brscan → Paperless-ngx (Docker)

Runs Brother's `brscan4` + `brscan-skey` in a container next to Paperless-ngx. Press
**Scan → Scan to PC → Paperless-ngx** on the **MFC-L2690DW** and a PDF lands straight in Paperless's
consume folder. Replaces the Proxmox LXC built from
[calvinrw.com/brscan4-paperless-workflow](https://calvinrw.com/brscan4-paperless-workflow).

| LXC setup | This container |
|---|---|
| `brsaneconfig4 -a ...` by hand | Done at startup from `SCANNER_IP` / `SCANNER_MODEL` |
| `brscan` user, UID 1000 | `PUID`/`PGID` (files are written with that owner) |
| `start.sh` calling `brscan-skey -u ...` | `SKEY_NAME` → `user=` in `brscan-skey.config` |
| `brscan.service` (systemd) | `restart: unless-stopped` |
| `scantofile.config` (DPI, size) | `SCAN_RESOLUTION`, `SCAN_MODE`, `SCAN_SOURCE`, `SCAN_WIDTH_MM`/`SCAN_HEIGHT_MM` |
| `remove_blank` (Ghostscript inkcov) | `topdf.py`: dark-pixel % per page, `BLANK_THRESHOLD` |
| Copy to a network share | Shared bind mount `./consume:/output` |
| `PAPERLESS_CONSUMER_POLLING` | Not needed if consume is on local disk (inotify works) |

Packages: `brscan4` 0.4.11-1 and `brscan-skey` 0.3.6-0 from download.brother.com, SHA-256 pinned,
on Debian 12. **amd64 only** (Brother ships no ARM build).

## Build with GitHub Actions

1. Push to GitHub. `.github/workflows/build.yml` builds and pushes
   `ghcr.io/calabresemic/brscan-paperless:latest` on every push to `main`, weekly (Monday, no cache,
   so Debian security updates get in), and on demand from the Actions tab.
2. Dependabot (`.github/dependabot.yml`) opens weekly PRs for action versions and the base image.
   Each PR runs a test build without pushing; merging it publishes a new `latest`.
3. GHCR packages are private by default. Either `docker login ghcr.io` on the Docker host with a
   token that has `read:packages`, or make the package public under your profile → Packages.
   Keeping it private avoids redistributing Brother's driver packages.

**Optional, for base-image PRs:** Dependabot can't bump a floating tag like `bookworm-slim`.
Pin the digest once:

```bash
docker buildx imagetools inspect debian:bookworm-slim --format '{{json .Manifest.Digest}}'
# then in the Dockerfile:
FROM debian:bookworm-slim@sha256:<digest>
```

**Not tracked automatically:** the Brother `.deb` URLs and checksums. If a build fails with a
checksum mismatch, update `BRSCAN4_*` / `SKEY_*` in the Dockerfile.

## Install

1. Paste the `brscan:` service and the top-level `networks:` block from
   `docker-compose.scanner.yml` into your paperless compose file. Set `TZ` and point the volume at
   the same host folder your `webserver` mounts at `/usr/src/paperless/consume`.
2. Add the variables to your `.env` file:

   ```
   SCANNER_IP=      # printer IP (give it a DHCP reservation)
   BRSCAN_PARENT=   # host interface on the printer's network, e.g. a VLAN interface
   BRSCAN_SUBNET=   # that network's subnet in CIDR form
   BRSCAN_GATEWAY=  # that network's gateway
   BRSCAN_IP=       # free address for the container, outside the DHCP range
   ```

3. **Stop the LXC's `brscan` service first** (`systemctl disable --now brscan` in the LXC). Two
   `brscan-skey` instances under the same name confuse the printer.
4. `docker compose up -d brscan && docker compose logs -f brscan`. The startup log should list
   the printer as `brother4:net1;dev0 ... Active`.
5. To update: `docker compose pull brscan && docker compose up -d brscan`.

## Networking

brscan-skey registers **the address of `eth0`** with the printer, and the printer sends button
presses to `<that address>:54925/udp`. The container's `eth0` must therefore have an address the
printer can reach:

- **macvlan (default in the example):** the container gets its own `eth0` and IP on the printer's
  network. No port publishing or firewall rules between networks are needed.
  - The parent can be a VLAN interface with no IP on the host, which keeps the host itself off
    that network. TrueNAS: Network → Interfaces → Add → VLAN.
  - Docker allows one macvlan network per parent interface. If the parent is already used by
    another macvlan network, put this one on a VLAN interface (or `<nic>.<vlan id>`, which Docker
    creates for you) instead. The switch port must carry that VLAN tagged.
  - A macvlan container can't reach its own host. That's fine here; it only writes to the
    shared folder.
- **Host networking (`network_mode: host`)** only works if the host has an interface literally
  named `eth0` with an address the printer can reach (e.g. a Debian VM or LXC). Hosts with
  `enp…`/`br…`/`vlan…` names (TrueNAS, most bare metal) register the wrong address: the startup
  log shows the printer `Active`, but the button does nothing.
- **Bridge networking with a published port doesn't work:** `eth0` is the Docker-internal address
  and there is no setting to override what brscan-skey registers.

## Requirements / gotchas

- Printer web UI → Network → Protocol → SNMP must allow **v1/v2c read-write** (community `internal`
  by default, `SNMP_COMMUNITY` to change), or the printer shows "No PC found".
- `SKEY_NAME` is limited to about 15 characters on the display.
- Keypad choices on the printer (File/Image/OCR/Email) all run the same script.

## Tuning

- **Source names**: list what the scanner reports:
  `docker exec brscan scanimage -d 'brother4:net1;dev0' --help`
  The L2690DW ADF is single-sided, so there is no `,Duplex` source.
- **Blank pages**: each page's score is logged, e.g. `page 2: 0.002% dark -> BLANK, dropped`.
  Blank pages score about 0.00x%, a short note or signature about 0.03%. Adjust `BLANK_THRESHOLD`
  after a few real scans; `BLANK_REMOVAL=false` turns it off.
- Paper size: `SCAN_WIDTH_MM` / `SCAN_HEIGHT_MM`. Default is 211.9 × 279.4 (the L2690DW's max width is 211.9 mm,
  so Letter loses ~2 mm per side; max length is 355.6 mm for Legal). A4 = 210 × 297.
- Empty feeder → it scans the flatbed instead.

## Optional: Paperless API instead of a shared folder

Swap the final `install/mv` in `scantofile.sh` for:

```bash
curl -fsS -H "Authorization: Token $PAPERLESS_TOKEN" \
  -F document=@"$FINAL;filename=$NAME" "$PAPERLESS_URL/api/documents/post_document/"
```

Set `PAPERLESS_URL` to an address the container can reach. On macvlan that can't be the Docker
host's own IP; use a reverse proxy or another address on a different host.
