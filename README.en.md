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
| 60-decoy | install the decoy HTML (vendored copy by default; fetch only if `DECOY_URL` is set) |
| 70-caddyfile | generate + validate + start the Caddy vhost |
| 80-verify | smoke tests (DoH, decoy, secret redirect, DoT cert, listeners) |

The installer asks 4 questions interactively (domain, email, admin username,
admin password — the secret path is generated for you) and saves the answers
to `deploy.env` (mode `0600`, **keep it private**). Where that file lives depends
on how you launched the installer:

- **one-liner (`curl … | sudo bash`)** — `/etc/adguard-deploy/deploy.env`. The
  bootstrap runs from a throwaway `/tmp` directory, so it persists the config at
  a stable path; that is what lets re-runs keep the *same* secret admin path.
- **git clone (`sudo ./install.sh`)** — `deploy.env` next to `install.sh`.

Resume / re-run: every step is skipped if already done; `--force` redoes
everything; `--only 50-adguard` runs a single step (an unknown step name is
rejected up front); `--uninstall` tears everything down.

**At the end**, the installer prints:
```
Admin URL : https://<domain>/<secret>/
DoH URL   : https://<domain>/dns-query
DoT host  : tls://<domain>:853
```

Save the secret path to a password manager — it is the entire obscurity layer.

## Installing with an AI agent

AI agents (Codex, OpenCode, Claude Code, …) should follow
[`docs/AGENT_INSTALL.md`](docs/AGENT_INSTALL.md) instead of this section. It is written for an
agent driving the install **over SSH from a workstation** and covers:

- the non-interactive contract — `DOMAIN`, `EMAIL`, `ADMIN_PASS` go into a mode-`600`
  `deploy.env`, then `./install.sh --yes` with **no TTY** (`ssh -T`, `setsid … </dev/null`);
  a TTY plus a missing variable means the installer blocks on a prompt forever;
- why **exit code 0 is not proof of success** — you must parse
  `Smoke tests: N passed, 0 failed.` from step `80-verify`;
- the SSH preflight gate and what must be confirmed with a human *before* touching the box
  (DNS, port 80 reachable from outside, UFW lockout risk, secrets never in `argv`);
- external verification (decoy `200`, secret path `302`, DoH, DoT), a symptom→fix failure
  playbook, and hard "never do this" rules (`certbot renew --dry-run`,
  `AdGuardHome --check-config`, exposing `:3000`, …).

Quick start from an agent:

```bash
VPS=203.0.113.10
ssh -T root@$VPS 'git clone --depth 1 https://github.com/skarusto/adguard-stealth-dns.git /root/adguard-stealth-dns'
# then create /root/adguard-stealth-dns/deploy.env (DOMAIN, EMAIL, ADMIN_PASS), chmod 600, and:
ssh -T root@$VPS 'cd /root/adguard-stealth-dns && setsid ./install.sh --yes </dev/null >/tmp/agent-install.out 2>&1; echo EXIT=$?'
```

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
`SSH_PORT`, `EXTRA_ALLOW`, `SKIP_FIREWALL`, `VPN_FORWARDING`, `DO_UPGRADE`,
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
  (the installer generates a 16-byte / 32-hex-char path by default) and never
  publish it.
- **Do not run `certbot renew --dry-run`** with the deploy hook installed: the
  hook would copy a *staging* certificate into place. Disable the hook first.
- **UFW blocks everything else by default** — add VPN/app ports via the
  `EXTRA_ALLOW` env var (e.g. `EXTRA_ALLOW="51820/udp 64672/udp"`).
- **VPN forwarding is opt-in.** The firewall step leaves
  `/etc/default/ufw`'s `DEFAULT_FORWARD_POLICY` untouched unless you set
  `VPN_FORWARDING=yes` (only needed if this box actually routes VPN traffic).
- **`SKIP_FIREWALL=yes` is hazardous on an internet-facing box.** Before step
  `50-adguard` patches its config, AdGuard's first-run setup wizard can briefly
  listen on `0.0.0.0:3000`; keep the firewall on (or otherwise block `:3000`)
  until that step finishes.
- On AdGuard Home ~v0.107.x, **`--check-config` can hang and lock `:3000`**
  (so the `50-adguard` step avoids it; configs are validated structurally).
- The decoy page is the copy **vendored in this repo** by default; set
  `DECOY_URL` if you want to fetch a different page instead.
- The decoy form is client-side only — it never sends credentials anywhere.

## Roll back

Backups created during install stay on the box:
`/root/AdGuardHome.yaml.bak.<timestamp>`. Re-apply one manually, or run
`sudo ./install.sh --uninstall`.

`--uninstall` removes AdGuard Home, Caddy and certbot (packages), `/var/www/fake`,
`/etc/ssl/adguard`, the deploy hook and the AdGuard unit, the Caddy apt
repo/keyring, `deploy.env` (both `repo/deploy.env` and
`/etc/adguard-deploy/deploy.env`), `/var/log/adguard-deploy.log`, and the
idempotency state. It deliberately leaves behind the Let's Encrypt live
certificate (`certbot delete --cert-name <domain>` removes it), your UFW rules
(`ufw reset` clears them — never on a remote box without console access), and the
DNS A/AAAA record still pointing at this server.

## Full documentation

- [`docs/MANUAL.md`](docs/MANUAL.md) — complete step-by-step manual (English).
- [`docs/MANUAL.ru.md`](docs/MANUAL.ru.md) — то же руководство на русском.
- [`docs/AGENT_INSTALL.md`](docs/AGENT_INSTALL.md) — installation manual for AI agents (Codex, OpenCode, …) driving the deploy over SSH.

## Security notes

- AdGuard binds the admin/DoH on `127.0.0.1:3000` **only**; DoT is public on `:853`; plain DNS and DoQ are off.
- AdGuard runs as root (so it can bind `:853`). Change if you know what you're doing.
- The secret admin path is the obscurity layer — pick a long, unguessable value (the installer generates a 16-byte / 32-hex-char path by default) and never publish it.
- The admin password is hashed by `htpasswd` reading it from **stdin** — it is never passed in process `argv` and only lives in the mode-`600` `deploy.env`.
- **Do not run `certbot renew --dry-run`** with the deploy hook installed — the hook would copy a staging certificate into place.
- On AdGuard Home ~v0.107.x, **`--check-config` can hang and lock `:3000`** — the installer script deliberately avoids it.

## License

MIT. See [LICENSE](LICENSE).
