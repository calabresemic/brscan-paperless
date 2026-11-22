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
2. PRs from this repo also publish `:pr-<number>`, so a change can be tested on the real host
   before merging. Dependabot (`.github/dependabot.yml`) opens weekly PRs for action versions and
   the base image; those only build (their token can't push). Merging publishes a new `latest`.
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
4. `docker compose up -d brscan && docker compose logs -f brscan`. The startup log should show
   `button presses registered to <BRSCAN_IP>:54925/udp` and list the printer as
   `brother4:net1;dev0 ... Active`.
5. To update: `docker compose pull brscan && docker compose up -d brscan`.

## Networking

At startup brscan-skey registers itself with the printer over SNMP (`HOST=<ip>:54925`), and the
printer sends button presses to that address. brscan-skey's own address detection fails inside a
container and sends an empty `HOST=:54925`, which the printer rejects, so it shows "No PC found".
The entrypoint therefore writes `ip_address=` into `brscan-skey.config`:

- **Default:** the local IP the kernel uses to reach `SCANNER_IP`.
- **`SKEY_HOST_IP`:** overrides it. Use this whenever the printer must send to a different address
  than the container's own, as with bridge networking.

The startup log shows the result: `button presses registered to <ip>:54925/udp`.

Pick a network mode that gives the printer a way to reach that address:

- **macvlan (default in the example, tested):** the container gets its own IP on the printer's
  network. No port publishing and no firewall rules between networks.
  - The parent can be a VLAN interface with no IP on the host, which keeps the host itself off
    that network. TrueNAS: Network → Interfaces → Add → VLAN.
  - Docker allows one macvlan network per parent interface. If the parent is already used by
    another macvlan network, put this one on a VLAN interface (or `<nic>.<vlan id>`, which Docker
    creates for you) instead. The switch port must carry that VLAN tagged.
  - A macvlan container can't reach its own host. That's fine here; it only writes to the
    shared folder.
- **Bridge with a published port (untested):** publish `54925:54925/udp` and set `SKEY_HOST_IP` to
  the Docker host's IP. SNMP and scanning are outbound connections and work through Docker's NAT.
  The printer has to be able to reach the host on UDP 54925.
- **Host networking (untested):** `network_mode: host`. The auto-detected IP is the host's address
  toward the printer; set `SKEY_HOST_IP` if that's not the one the printer should use.

## Requirements / gotchas

- Printer web UI → Network → Protocol → SNMP must allow **v1/v2c read-write** (community `internal`
  by default, `SNMP_COMMUNITY` to change), or the printer shows "No PC found".
- `SKEY_NAME` is limited to about 15 characters on the display.
- Keypad choices on the printer (File/Image/OCR/Email) all run the same script.
- The image needs `netbase` (`/etc/protocols`). brscan4 calls `getprotobyname("tcp")` without
  checking the result and segfaults on every network scan without it.

## Troubleshooting

Shell in: `docker exec -it brscan bash`.

| Symptom | Check |
|---|---|
| Printer: "No PC found" | Startup log line `button presses registered to …` has the right IP. Watch the registration on the host with `tcpdump -ni <iface> host <printer> and udp`: the SNMP `SetRequest` must carry `HOST=<ip>:54925`, and a `badValue` reply means the printer rejected it. Also check SNMP read-write on the printer. |
| Button does nothing, no log line | UDP 54925 from the printer reaches the registered IP; `grep -i ':D68D ' /proc/net/udp` shows the listener. |
| Scan fails | Test without the button: `scanimage -d 'brother4:net1;dev0' --resolution 150 --format=pnm -o /tmp/t.pnm`, then the full pipeline: `/opt/scan/scantofile.sh 'brother4:net1;dev0'` (output goes to `docker logs`). |
| `cannot write to /output` | `PUID`/`PGID` and permissions on the consume folder. |

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
