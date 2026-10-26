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
3. **A domain name with an A record for the VPS public IPv4.** Before running, manually confirm the A record resolves to this VPS's IPv4: on a mismatch the installer warns and asks whether to continue interactively; with `--yes` it continues. Do not proceed with a mismatched A record. The installer does not check AAAA; if one is published, it must also reach this server, or be corrected/removed with the DNS provider.
4. **Inbound ports 80, 443, 853 reachable** from the internet — check both your cloud provider's firewall *and* your router.
5. **Ports 80/443/853 must be free** — nothing else may listen on them.
6. **Know your other listening ports** (SSH = 22 by default, VPNs, etc.) — the installer shows you every listening socket and asks before enabling the deny-by-default firewall.

### 2) Run the one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/skarusto/adguard-stealth-dns/main/install.sh | sudo bash
```

If `git` is not installed on a fresh host, do not install it just for this deployment: use the one-liner above or fetch and unpack the repository tarball with `curl` and `tar`.

If you prefer not to pipe to `bash`, clone and run locally:

```bash
git clone https://github.com/skarusto/adguard-stealth-dns.git
cd adguard-stealth-dns
sudo ./install.sh
```

### 3) What happens next (9 steps, all automatic)

| Step | What |
|---|---|
| 00-preflight | OS, internet, DNS resolving to this box, required ports free |
| 10-base | apt packages, timezone |
| 20-firewall | restrictive UFW (SSH + 80 + 443 + 853) |
| 30-caddy | install Caddy, stop for the port-80 ACME challenge |
| 40-cert | certbot (standalone) + shared cert + deploy hook |
| 50-adguard | pinned AdGuard Home v0.107.79 release archive, local first-run setup + config patch |
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

**At the end**, DoH/DoT endpoints and the private log path are printed. The actual
Admin URL is written only to root-only `/var/log/adguard-deploy.log`; it is not
printed in the terminal and must not be copied into a transcript. Retrieve it
privately on the server from that log, or reconstruct it from `SECRET_PATH` in the
root-only `deploy.env`; then save it in a password manager. Do not paste it into chat
or a shared log:
```
Admin URL : private; see root-only log file /var/log/adguard-deploy.log
DoH URL   : https://<domain>/dns-query
DoT host  : tls://<domain>:853
```

Save the secret path to a password manager — it is the entire obscurity layer.
Both `/<secret>` and `/<secret>/` redirect to `/<secret>/login.html`.
Existing binaries are reused; changing the pinned fresh-install release requires retesting.

## Installing with an AI agent

AI agents (Codex, OpenCode, Claude Code, …) should follow
[`docs/AGENT_INSTALL.md`](docs/AGENT_INSTALL.md) instead of this section. It is written for an
agent driving the install **over SSH from a workstation** and covers:

- the non-interactive contract — required values in a mode-`600` `deploy.env`,
  then `bash ./install.sh --yes` without a TTY;
- preserving the installer's exit status over SSH: failed smoke tests return nonzero,
  so require both a successful exit and `Smoke tests: N passed, 0 failed.`;
- the SSH preflight gate and what must be confirmed with a human *before* touching the box
  (DNS including CAA, provider firewall rules, UFW lockout risk, private secrets/logs);
- external verification (decoy `200`, secret path `302`, DoH, DoT), a symptom→fix failure
  playbook, and hard "never do this" rules (`certbot renew --dry-run`,
  `AdGuardHome --check-config`, exposing `:3000`, …).

Quick start from an agent:

```bash
VPS=203.0.113.10
SSH_PORT=22  # actual SSH port; verify the host key first
ssh -T -p "$SSH_PORT" "root@$VPS" 'git clone https://github.com/skarusto/adguard-stealth-dns.git /root/adguard-stealth-dns'
# Prepare trusted deploy.env (DOMAIN, EMAIL, ADMIN_PASS, SSH_PORT), mode 600.
ssh -T -p "$SSH_PORT" "root@$VPS" 'cd /root/adguard-stealth-dns || exit; umask 077; out=$(mktemp /root/agent-install.XXXXXX.out) || exit; rc=0; setsid --wait bash ./install.sh --yes </dev/null >"$out" 2>&1 || rc=$?; printf "Exit: %s; private log: %s\n" "$rc" "$out"; exit "$rc"'
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

Configuration can also be supplied via environment variables (an existing config is
sourced afterward and overrides matching values; edit the selected file on resume):
`DOMAIN`, `EMAIL`, `SECRET_PATH`, `ADMIN_USER`, `ADMIN_PASS`, `TIMEZONE`,
`SSH_PORT`, `EXTRA_ALLOW`, `SKIP_FIREWALL`, `VPN_FORWARDING`, `DO_UPGRADE`,
`ENABLE_DEFAULT_FILTERS`, `DECOY_URL`, `ADGUARD_UPSTREAMS`,
`ADGUARD_BOOTSTRAP`, `ADGUARD_FALLBACK`.

## What you end up with

- `/opt/AdGuardHome/AdGuardHome.yaml` — AdGuard config (binary-generated schema_version preserved)
- `/opt/AdGuardHome` — private root-only directory, mode `0700`
- `/etc/caddy/Caddyfile` — Caddy vhost
- `/var/www/fake/index.html` — decoy front site
- `/etc/ssl/adguard/{fullchain,privkey}.pem` — shared certificate managed by a certbot deploy hook
- `/etc/systemd/system/AdGuardHome.service` — deterministic unit (runs as root, so it can bind `:853`)

Services enabled: `caddy`, `AdGuardHome`, `certbot.timer`, `ufw`. AdGuard binds
the admin / DoH interface on `127.0.0.1:3000` **only**; plain DNS and DoQ are
disabled; DoT is public on `:853`. Public `dns.bind_hosts` is needed for DoT,
while `serve_plain_dns=false` keeps ordinary DNS disabled.

## Important caveats

- **Secret path is the whole obscurity layer** — pick a long, unguessable value
  (the installer generates a 16-byte / 32-hex-char path by default) and never
  publish it.
- **Do not run `certbot renew --dry-run`** with the deploy hook installed: the
  hook would copy a *staging* certificate into place. Disable the hook first.
- **UFW blocks everything else by default** — review the listening sockets and warning before activation, and add required VPN/app ports via `EXTRA_ALLOW` (e.g. `EXTRA_ALLOW="51820/udp 64672/udp"`). UFW's reminder to update rules is informational; `ufw status` reflects firewall rules, while `systemctl is-active ufw` checks the service. The installer enables and starts the service.
- **VPN forwarding is opt-in.** The firewall step leaves
  `/etc/default/ufw`'s `DEFAULT_FORWARD_POLICY` untouched unless you set
  `VPN_FORWARDING=yes` (only needed if this box actually routes VPN traffic).
- **`SKIP_FIREWALL=yes` does not replace a provider firewall.** Step `50-adguard`
  downloads the official release archive and performs first-run setup over loopback,
  without exposing the wizard to the internet. Configure external firewall rules
  anyway and verify admin ports are unreachable from outside.
- **Certificate issuance can fail even when HTTP-01 works.** A successful HTTP
  challenge response (even `200`) does not rule out CAA lookup errors such as
  `SERVFAIL` at a parent domain. This is a DNS-provider/zone-owner issue, not
  proof that port 80 is blocked. Ask the DNS owner to diagnose it. An explicit
  child record `CAA 0 issue "letsencrypt.org"` can avoid the bad parent lookup in
  some cases, but is not guaranteed for every DNS/DNSSEC/CNAME setup; otherwise
  use a working domain.
- **Windows credential export error 1332:** do not write secrets until ACL
  restrictions succeed. For `icacls`, use numeric SID notation such as `*S-1-...`
  rather than localized account names, and verify access is restricted first. If this fails, leave no credentials in
  the file and use a password manager or server-side config instead. Never put
  secrets in documentation, logs, or command history.
- On AdGuard Home ~v0.107.x, **`--check-config` can hang and lock `:3000`**
  (so the `50-adguard` step avoids it; configs are validated structurally).
- The decoy page is the copy **vendored in this repo** by default; set
  `DECOY_URL` if you want to fetch a different page instead.
- The decoy form is client-side only — it never sends credentials anywhere.

## Roll back

Backups created during config patching stay beside the config:
`/opt/AdGuardHome/AdGuardHome.yaml.bak.<timestamp>` (root-only). Re-apply one manually, or run
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
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — installation errors, benign notices, and safe recovery guidance.

## Security notes

- AdGuard binds the admin/DoH on `127.0.0.1:3000` **only**; DoT is public on `:853`; plain DNS and DoQ are off.
- AdGuard runs as root (so it can bind `:853`). Change if you know what you're doing.
- The secret admin path is the obscurity layer — pick a long, unguessable value (the installer generates a 16-byte / 32-hex-char path by default) and never publish it.
- The admin password is hashed by `htpasswd` reading it from **stdin** — it is never passed in process `argv` and only lives in the mode-`600` `deploy.env`.
- **Do not run `certbot renew --dry-run`** with the deploy hook installed — the hook would copy a staging certificate into place.
- On AdGuard Home ~v0.107.x, **`--check-config` can hang and lock `:3000`** — the installer script deliberately avoids it.

## License

MIT. See [LICENSE](LICENSE).
