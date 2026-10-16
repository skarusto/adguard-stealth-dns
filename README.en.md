# adguard-stealth-dns

[Русский](README.md) · **English**


A one-command deployer that turns a fresh Debian/Ubuntu VPS into a public
**DNS-over-HTTPS (DoH) + DNS-over-TLS (DoT) only** resolver backed by
AdGuard Home, where the domain root serves a believable decoy website and the
AdGuard admin UI lives behind a long secret path (no HTTP Basic Auth).

## What you get

- Public resolvers on `https://<domain>/dns-query` and `tls://<domain>:853`. No plain DNS.
- A decoy "corporate file manager" site on `/` (and every other path) so scanners see an innocuous page.
- The AdGuard admin UI only at `https://<domain>/<secret>/`, forwarding to AdGuard's own login — the secret path itself is the obscurity.
- A single Let's Encrypt certificate shared by Caddy (for `:443`) and AdGuard (for `:853`).
- Fully idempotent and resumable; log in `/var/log/adguard-deploy.log`.

## Installation (one line)

### 1) Prerequisites you must do first (these cannot be automated)

1. **A VPS** running Debian 12/13 or Ubuntu 22.04/24.04 with a public IPv4 address.
2. **Root access** — run as root (`sudo -i`).
3. **A domain name whose A (AAAA) record already points at the VPS IP.** The installer aborts if DNS does not resolve to this server. Set it up at your registrar/DNS provider (or DuckDNS / linkpc.net / afraid.org) before running.
4. **Inbound ports 80, 443, 853 reachable** from the internet — check both your cloud provider's firewall *and* your router.
5. **Ports 80/443/853 must be free** — nothing else may listen on them.
6. **Know your other listening ports** (SSH = 22 by default, VPNs, etc.) — the installer shows you every listening socket and asks before enabling the deny-by-default firewall.

### 2) Run the one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/skarusto/adguard-stealth-dns/main/install.sh | sudo bash
```

If you prefer not to pipe to `bash`, clone and run locally:

```bash
git clone https://github.com/skarusto/adguard-stealth-dns.git
cd adguard-stealth-dns
sudo ./install.sh
```

### 3) What happens next (8 steps, all automatic)

| Step | What |
|---|---|
| 00-preflight | OS, internet, DNS resolving to this box, required ports free |
| 10-base | apt packages, timezone |
| 20-firewall | restrictive UFW (SSH + 80 + 443 + 853) |
| 30-caddy | install Caddy, stop for the port-80 ACME challenge |
| 40-cert | certbot (standalone) + shared cert + deploy hook |
| 50-adguard | AdGuard Home from the official installer + patched config |
| 60-decoy | fetch the decoy HTML (vendored fallback included) |
| 70-caddyfile | generate + validate + start the Caddy vhost |
| 80-verify | smoke tests (DoH, decoy, secret redirect, DoT cert, listeners) |

The installer asks 4 questions interactively (domain, email, admin username,
admin password — the secret path is generated for you) and saves the answers
to `deploy.env` (mode `0600`, **keep it private**). Resume / re-run: every
step is skipped if already done; `--force` redoes everything; `--only 50-adguard`
runs a single step; `--uninstall` tears everything down.

**At the end**, the installer prints:
```
Admin URL : https://<domain>/<secret>/
DoH URL   : https://<domain>/dns-query
DoT host  : tls://<domain>:853
```

Save the secret path to a password manager — it is the entire obscurity layer.

## Usage scenarios

```bash
# interactive (asks everything)
sudo ./install.sh
sudo ./install.sh -y                   # accept defaults (only after deploy.env exists)
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

## What you end up with

- `/opt/AdGuardHome/AdGuardHome.yaml` — AdGuard config (schema_version pinned)
- `/etc/caddy/Caddyfile` — Caddy vhost
- `/var/www/fake/index.html` — decoy front site
- `/etc/ssl/adguard/{fullchain,privkey}.pem` — shared certificate managed by a certbot deploy hook
- `/etc/systemd/system/AdGuardHome.service` — deterministic unit (runs as root, so it can bind `:853`)

Services enabled: `caddy`, `AdGuardHome`, `certbot.timer`, `ufw`. AdGuard binds
the admin / DoH interface on `127.0.0.1:3000` **only**; plain DNS and DoQ are
disabled; DoT is public on `:853`.

## Important caveats

- **Secret path is the whole obscurity layer** — pick a long, unguessable value
  (the installer generates 16 hex chars by default) and never publish it.
- **Do not run `certbot renew --dry-run`** with the deploy hook installed: the
  hook would copy a *staging* certificate into place. Disable the hook first.
- **UFW blocks everything else by default** — add VPN/app ports via the
  `EXTRA_ALLOW` env var (e.g. `EXTRA_ALLOW="51820/udp 64672/udp"`).
- On AdGuard Home ~v0.107.x, **`--check-config` can hang and lock `:3000`**
  (so the `50-adguard` step avoids it; configs are validated structurally).
- The decoy form is client-side only — it never sends credentials anywhere.

## Roll back

Backups created during install stay on the box:
`/root/AdGuardHome.yaml.bak.<timestamp>`. Re-apply one manually, or run
`sudo ./install.sh --uninstall`.

## Full documentation

- [`docs/MANUAL.md`](docs/MANUAL.md) — complete step-by-step manual (English).
- [`docs/MANUAL.ru.md`](docs/MANUAL.ru.md) — то же руководство на русском.

## Security notes

- AdGuard binds the admin/DoH on `127.0.0.1:3000` **only**; DoT is public on `:853`; plain DNS and DoQ are off.
- AdGuard runs as root (so it can bind `:853`). Change if you know what you're doing.
- The secret admin path is the obscurity layer — pick a long, unguessable value (the installer generates one by default) and never publish it.
- **Do not run `certbot renew --dry-run`** with the deploy hook installed — the hook would copy a staging certificate into place.
- On AdGuard Home ~v0.107.x, **`--check-config` can hang and lock `:3000`** — the installer script deliberately avoids it.

## License

MIT. See [LICENSE](LICENSE).
