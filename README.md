# README.md

# adguard-stealth-dns

A one-command deployer that turns a fresh Debian/Ubuntu VPS into a public
**DNS-over-HTTPS (DoH) + DNS-over-TLS (DoT) only** resolver backed by
AdGuard Home, where the domain root serves a believable decoy website and the
AdGuard admin UI lives behind a long secret path (no HTTP Basic Auth).

## What you get

- Public resolvers on `https://<domain>/dns-query` and `tls://<domain>:853`. No plain DNS.
- A decoy "corporate file manager" site on `/` (and every other path) so scanners see an innocuous page.
- The AdGuard admin UI only at `https://<domain>/<secret>/`, forwarding to AdGuard's own login — the secret path itself is the obscurity.
- A single Let's Encrypt certificate shared by Caddy (for `:443`) and AdGuard (for `:853`).
- Idempotent, resumable, logged under `/var/log/adguard-deploy.log`.

## Quick start

```bash
git clone <this-repo>
cd adguard-stealth-dns
sudo ./install.sh
```

The installer asks a few questions, saves the answers to `deploy.env` (mode `0600`),
and runs 8 steps:

| Step | What |
|---|---|
| 00-preflight | OS, internet, DNS resolves to this box, required ports free |
| 10-base | apt packages, timezone |
| 20-firewall | restrictive UFW (SSH + 80 + 443 + 853) |
| 30-caddy | install Caddy, stop for the port-80 challenge |
| 40-cert | certbot (standalone) + shared cert + deploy hook |
| 50-adguard | AdGuard Home from the official installer + patched config |
| 60-decoy | fetch the decoy HTML (vendored fallback included) |
| 70-caddyfile | generate + validate + start the Caddy vhost |
| 80-verify | smoke tests (DoH, decoy, secret redirect, DoT cert, listeners) |

Resume/re-run: every step is skipped if already done. Use `--force` to redo all steps.

## Prerequisites (do these before running)

- A **Debian 12/13** or **Ubuntu 22.04/24.04** VPS with a public IPv4.
- Root access.
- **Root privileges on the box** (run as root or `sudo -i`).
- A **hostname whose A/AAAA record already points at the VPS IP** — the script refuses to continue if DNS doesn't resolve to this box (override with `--yes`).
- Incoming ports **80, 443, 853** reachable from the internet (check your provider's firewall AND UFW).
- Nothing already listening on **80, 443, 853** (the script warns, but will not stop foreign services for you).
- Know your other ports: the script will ask before enabling the firewall, and defaults to **deny inbound** for everything except SSH + 80/443/853.

## Usage

```bash
sudo ./install.sh                      # interactive
sudo ./install.sh -y                   # accept defaults; only works after writing deploy.env
sudo ./install.sh --yes                # same
sudo ./install.sh --config ./prod.env  # use a specific config file
sudo ./install.sh --force              # redo every step
sudo ./install.sh --only 50-adguard    # run one step
sudo ./install.sh --uninstall          # tear everything down
```

Configuration can also be supplied via environment variables (highest priority):
`DOMAIN`, `EMAIL`, `SECRET_PATH`, `ADMIN_USER`, `ADMIN_PASS`, `TIMEZONE`,
`SSH_PORT`, `EXTRA_ALLOW`, `SKIP_FIREWALL`, `DO_UPGRADE`,
`ENABLE_DEFAULT_FILTERS`, `DECOY_URL`, `ADGUARD_UPSTREAMS`,
`ADGUARD_BOOTSTRAP`, `ADGUARD_FALLBACK`.

`deploy.env` (mode 0600) holds them after the first interactive run. **Keep it private.**

## Files

| Path | Purpose |
|---|---|
| `install.sh` | entry point |
| `scripts/lib.sh` | shared helpers |
| `scripts/00-preflight.sh` … `80-verify.sh` | one step each |
| `scripts/90-uninstall.sh` | teardown |
| `templates/Caddyfile` | Caddy vhost template |
| `templates/patch-adguard-config.py` | careful config patcher |
| `templates/AdGuardHome.service` | deterministic systemd unit |
| `templates/adguard-shared-cert.sh` | certbot deploy hook (common cert for Caddy+AdGuard) |
| `assets/index.html` | vendored decoy page (fallback if the live download fails) |
| `docs/MANUAL.md` | full manual (English) |
| `docs/MANUAL.ru.md` | full manual (Russian) |

## Security notes / caveats

- AdGuard binds the admin/DoH on `127.0.0.1:3000` **only**; DoT is public on `:853`; plain DNS and DoQ are off.
- AdGuard runs as root (so it can bind `:853`). Change if you know what you're doing.
- The secret admin path is the whole obscurity layer — pick a long, unguessable value (the installer generates one by default) and never publish it.
- **Do not** run `certbot renew --dry-run` carelessly: the deploy hook would copy a staging certificate into place.
- On this version (0.107.x) `AdGuardHome --check-config` can hang and lock `:3000`. The `50-adguard` step deliberately avoids it. Validate configs structurally instead.
- The decoy form is client-side only — it never sends credentials anywhere.

## Roll back

Backups created during install stay on the box:
`/root/AdGuardHome.yaml.bak.<timestamp>`. Re-apply one manually, or run `./install.sh --uninstall`.

## Licence

MIT. See LICENSE.
