# Agent installation manual — driving `adguard-stealth-dns` from an AI agent

**Audience:** autonomous coding agents (Codex, OpenCode, Claude Code, Aider, …) performing the
installation *over SSH from a workstation onto a fresh Debian/Ubuntu VPS*.

**Style:** machine-oriented. Exact commands, explicit contracts, hard stops, verifiable exit
conditions. For human-oriented explanation see [`MANUAL.md`](MANUAL.md) (architecture,
step-by-step reasoning, landmines) or [`../README.en.md`](../README.en.md) (quick start).

**Repo:** `https://github.com/skarusto/adguard-stealth-dns`

---

## 0. Contract summary (read this first)

You sit on a workstation with an SSH key to the VPS. The VPS is a **fresh Debian 12/13 or
Ubuntu 22.04/24.04** box with a public IPv4 and a domain already pointed at it.

The installer is fully scriptable, but **only** under these rules:

1. Provide `DOMAIN`, `EMAIL`, `ADMIN_PASS` (and optionally `SECRET_PATH`) **before** running.
   Either in a mode-`600` `deploy.env` next to `install.sh`, or as environment variables.
   Without them it will either die or block on a prompt.
2. Run with `--yes` **and** without a TTY (`ssh -T`, `</dev/null`, or `nohup`). A TTY plus a
   missing variable = the script waits forever on `/dev/tty`.
3. **Exit code 0 does not mean the deployment is healthy.** The final `80-verify` step reports
   failures as warnings and still returns success. You must parse its output.
4. Never run destructive or known-hazardous commands (§11).
5. Stop and ask the human when §2 conditions are not met.

---

## 1. Values you must collect before touching anything

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DOMAIN` | **yes** | — | Must already have an A record pointing at the VPS public IP, propagated. |
| `EMAIL` | **yes** | — | Let's Encrypt contact. Must be a real, monitored address. |
| `ADMIN_PASS` | **yes** | — | AdGuard admin password. **Secret.** Never echo, never commit, never log. |
| `SECRET_PATH` | recommended | `/<16 hex>` (auto) | The obscurity layer. If you let it be auto-generated you must capture it from the run output. Setting it yourself makes verification deterministic. |
| `ADMIN_USER` | no | `admin` | |
| `TIMEZONE` | no | `UTC` | e.g. `Europe/Berlin`. |
| `SSH_PORT` | no | auto-detected | Set it explicitly if `sshd` runs on a non-standard port and detection could fail — this value is what UFW will allow. |
| `EXTRA_ALLOW` | no | — | Space-separated UFW specs, e.g. `"51820/udp 64672/udp"`. |
| `SKIP_FIREWALL` | no | `no` | Set `yes` only if a cloud provider already enforces the firewall and you do not want UFW. |
| `DO_UPGRADE` | no | `no` | `yes` runs a full `apt-get upgrade` (slower, less predictable). |
| `ENABLE_DEFAULT_FILTERS` | no | `yes` | |
| `DECOY_URL` | no | upstream template | Fallback to repo-vendored `assets/index.html` automatically. |
| `ADGUARD_UPSTREAMS`, `ADGUARD_BOOTSTRAP`, `ADGUARD_FALLBACK` | no | AdGuard defaults | |

**Collecting `ADMIN_PASS` from the human:** request it in a secure channel; do not paste it into
a chat transcript, a commit, or a command history. Preferred pattern: have the human provide it
only as the content of a file you `scp`, or have them run the one command themselves. If you
must handle it, keep it in memory and write it straight to a mode-`600` file on the server.

---

## 2. Hard stops — ask the human before proceeding

* DNS A record for `DOMAIN` does not resolve to the VPS public IP (or you cannot verify it).
* The VPS is not Debian/Ubuntu, or not a fresh box (something already listens on 80/443/853).
* `ADMIN_PASS` / `DOMAIN` / `EMAIL` are unavailable or were supplied over an insecure channel.
* The box is a jump host / production box where other services run — UFW deny-by-default will cut
  them off. Confirm `EXTRA_ALLOW` explicitly.
* You would need to change SSH port rules or disable UFW to keep your session alive.
* Any destructive action: `--force` on a live server, `--uninstall`, deleting certs or config.

---

## 3. Establish an SSH session and sanity-check the target

Use `-T` (no TTY) so nothing can block on a prompt, plus timeouts so you never hang forever:

```bash
VPS=203.0.113.10          # your target
SSH="ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@$VPS"
$SSH 'id -u'                              # must print 0 (root). If not, prefix with sudo -i
```

Run this whole gate as one block (last argument = the domain under test); any non-zero exit
means **stop**:

```bash
$SSH 'set -e
  . /etc/os-release
  case "$ID" in debian|ubuntu) echo "OS=$PRETTY_NAME";; *) echo "UNSUPPORTED_OS=$ID"; exit 1;; esac
  curl -fsS --max-time 10 https://api.ipify.org >/dev/null || { echo "NO_INTERNET"; exit 1; }
  IP=$(curl -fsS --max-time 8 https://api.ipify.org)
  RES=$(getent ahostsv4 "$1" | awk "{print \$1}" | sort -u | tr "\n" " ")
  echo "PUBLIC_IP=$IP"; echo "DOMAIN_RESOLVES_TO=$RES"
  for p in 80 443 853; do ss -tlnH | grep -qE "[:.]$p\$" && echo "PORT_BUSY=$p"; done
  command -v curl >/dev/null || { echo "NO_CURL"; exit 1; }
' _ example.com
```

Then, **from your own workstation**, verify reachability from outside (the installer cannot do
this for itself):

```bash
curl -sI -o /dev/null -w '%{http_code}\n' http://example.com/    # expect 000/404/301; 000 = 80 closed inbound
```

If port 80 is not reachable from the internet, Let's Encrypt **will** fail at step `40-cert`.

---

## 4. Get the code onto the server

Prefer copying a known-good tree you have already read, rather than piping a remote script into
a shell:

```bash
VPS=203.0.113.10
rsync -a --exclude .git ./ root@$VPS:/root/adguard-stealth-dns/
# or: ssh root@$VPS 'git clone --depth 1 https://github.com/skarusto/adguard-stealth-dns.git /root/adguard-stealth-dns'
```

One-liner alternative (unaudited remote code — review `install.sh` first if you care):

```bash
ssh -T root@$VPS 'curl -fsSL https://raw.githubusercontent.com/skarusto/adguard-stealth-dns/main/install.sh | sudo bash'
```

The one-liner form is fine **only** when all required variables are exported on the remote side;
see §5 for why `deploy.env` is safer than a command line.

Note the bootstrap behaviour: when `install.sh` runs from a directory that does not contain
`scripts/lib.sh` (i.e. the one-liner), it downloads the whole repo tree into a temporary
directory under `/tmp` and re-executes itself there. Every path in this manual assumes the repo
copy at `/root/adguard-stealth-dns`.

---

## 5. Create the config on the server (do not pass secrets in argv)

Secrets on a command line are visible to **every user on the box** via `ps`. Write a config file
instead.

```bash
# On your workstation:
umask 077
cat > /tmp/deploy.env <<'EOF'
DOMAIN=example.com
EMAIL=admin@example.com
SECRET_PATH=/3f9a1c27be05d4aa
ADMIN_USER=admin
ADMIN_PASS=REPLACE_ME
TIMEZONE=UTC
SSH_PORT=22
EXTRA_ALLOW=
SKIP_FIREWALL=no
DO_UPGRADE=no
EOF
scp -p /tmp/deploy.env root@$VPS:/root/adguard-stealth-dns/deploy.env
shred -u /tmp/deploy.env 2>/dev/null || rm -f /tmp/deploy.env
```

`deploy.env` is plain `KEY=value` shell syntax — quote any value containing spaces or `$`.
The installer chmods it `600` if it writes it itself; when you create it, ensure `600` yourself:

```bash
ssh -T root@$VPS 'chmod 600 /root/adguard-stealth-dns/deploy.env'
```

---

## 6. Execute the install

```bash
ssh -T root@$VPS 'cd /root/adguard-stealth-dns && setsid ./install.sh --yes </dev/null >/tmp/agent-install.out 2>&1; echo "EXIT=$?"; tail -40 /tmp/agent-install.out'
```

Why each piece:

* `./install.sh --yes` → non-interactive; skips all confirmations (firewall ACK, etc.).
* `setsid … </dev/null` → guarantees no TTY, so an accidental missing variable produces an
  immediate, actionable `die` instead of a silent hang.
* `>/tmp/agent-install.out` → the full transcript for you to parse (progress messages go to
  stderr, log lines to `/var/log/adguard-deploy.log`).
* `echo "EXIT=$?"` → capture the real exit code.

Typical run: **2–6 minutes** (apt + AdGuard Home download dominate).

**Surviving a dropped connection:** the run is idempotent and resumable, so a broken SSH session
mid-run is not fatal — reconnect and re-run the same command; completed steps are skipped.
Because of `setsid`, the run above keeps going even if your SSH session drops: output is already
redirected to `/tmp/agent-install.out` on the server, so reconnect and read that file.

**If you see** `Another deploy run is already in progress.` → a previous run is still alive or
stale. Check `ps -ef | grep install.sh`, and if nothing is running, remove
`/var/lib/adguard-deploy/.lock`.

### Available flags

```text
sudo ./install.sh                      # interactive (needs a TTY — not for agents)
sudo ./install.sh --yes                # non-interactive; requires deploy.env or env vars
sudo ./install.sh --config /path/x.env # specific config file
sudo ./install.sh --force              # redo every step (destructive on a live box)
sudo ./install.sh --only 50-adguard    # run a single step
sudo ./install.sh --uninstall          # tear everything down (with --yes: NO confirmation!)
sudo ./install.sh --help
```

Idempotency state: `/var/lib/adguard-deploy/done.<step>`. Log: `/var/log/adguard-deploy.log`.

---

## 7. Interpret the result (exit code is not enough)

**Success criteria = process exit 0 AND zero failed smoke tests AND services active.**

1. Exit code (capture the output of the §6 command first, `OUT=...`):
   ```bash
   grep -q 'EXIT=0' <<<"$OUT" || echo "INSTALLER FAILED"
   ```
   `die()` messages are single-line and actionable — always surface them verbatim.
2. Smoke test summary (printed by step `80-verify`):
   ```bash
   ssh -T root@$VPS "grep -E 'Smoke tests:|FAIL :' /tmp/agent-install.out /var/log/adguard-deploy.log | tail -20"
   ```
   Expect `Smoke tests: N passed, 0 failed.` Any `FAIL :` line → go to §9.
3. Steps completed:
   ```bash
   ssh -T root@$VPS 'ls /var/lib/adguard-deploy/'
   ```
   Expect `done.00-preflight … done.80-verify` (9 markers).
4. Services:
   ```bash
   ssh -T root@$VPS 'systemctl is-active caddy AdGuardHome ufw; ss -tlnH | grep -E "127.0.0.1:3000|:853"'
   ```
   Expect one `active` per unit (`active`, `active`, `active`), a `127.0.0.1:3000` line, and an
   `:853` line.

### Step map (what each stage does and how it fails)

| Step | Does | Hard failure (`exit 1`) | Warning only |
|---|---|---|---|
| `00-preflight` | OS, internet, DNS, free ports | no internet, domain does not resolve | DNS not pointing at *this* IP (with `--yes`: continues), port in use by another process |
| `10-base` | apt packages, timezone | apt failure | timezone not settable; upgrade skipped |
| `20-firewall` | UFW deny-incoming, allow SSH/80/443/853 | `ufw` missing, `ufw enable` failed | prints all listening sockets; skipped if `SKIP_FIREWALL=yes` |
| `30-caddy` | install Caddy, **stop it** (frees :80) | — | already installed |
| `40-cert` | certbot standalone + shared copy + deploy hook | certbot did not issue, shared cert missing | cert already exists (skips issuance) |
| `50-adguard` | official installer, config patch, unit, restart | binary/config missing, service did not start | `:3000` bound beyond localhost |
| `60-decoy` | fetch decoy HTML (vendored fallback) | empty index file | download failed → fallback used |
| `70-caddyfile` | render + `caddy validate` + start | validation failed, caddy not active | — |
| `80-verify` | smoke tests | **never fails the run** | prints `FAIL :` lines |

### Getting the credentials back

The run output ends with:

```text
Admin URL : https://<domain>/<secret>/
DoH URL   : https://<domain>/dns-query
DoT host  : tls://<domain>:853
```

`SECRET_PATH` is also in `deploy.env` — do **not** `cat` it into your transcript. Fetch only what
the human needs:

```bash
ssh -T root@$VPS 'grep -E "Admin URL|DoH URL|DoT host" /var/log/adguard-deploy.log | tail -3'
```

Report those three lines to the human and remind them to store the secret path in a password
manager — it is the entire obscurity layer.

---

## 8. Independent verification (run from your workstation, not the VPS)

Checks made from the VPS itself can lie (local DNS, local sockets). Verify externally:

```bash
D=example.com
# 1) decoy site — expect 200
curl -s -o /dev/null -w 'root=%{http_code}\n'            https://$D/
# 2) random path — expect 200 (catch-all decoy)
curl -s -o /dev/null -w 'random=%{http_code}\n'           https://$D/nothing-here
# 3) secret admin path — expect 302 (redirect into the prefixed login)
curl -s -o /dev/null -w 'secret=%{http_code}\n'           https://$D/<secret>/
# 4) DoH — expect an HTTP response with a DNS payload (see MANUAL.md Appendix B.1 doh_check.py)
curl -s -o /dev/null -w 'doh_get=%{http_code}\n'           https://$D/dns-query
# 5) DoT — expect the cert subject to contain the domain and verify OK
echo | timeout 10 openssl s_client -connect $D:853 -servername $D 2>/dev/null | openssl x509 -noout -subject
```

Admin UI exposure check (must be localhost-only):

```bash
ssh -T root@$VPS 'ss -tlnH | grep -q "^LISTEN.*127.0.0.1:3000" && echo ADMIN_LOCAL_ONLY || echo ADMIN_EXPOSED'
```

`ADMIN_EXPOSED` (or `ss` showing `*:3000` / `0.0.0.0:3000`) is a **security incident** — stop and
escalate to the human immediately.

For a real end-to-end DoH resolution + block test, use the script in
[`MANUAL.md` → Appendix B.1](MANUAL.md).

---

## 9. Failure playbook (symptom → cause → fix)

| Symptom | Likely cause | Fix |
|---|---|---|
| `Domain 'x' does not resolve` (exit 1 at preflight) | A record missing/not propagated | Wait up to 5 min, `dig +short x` from your workstation, re-run. |
| `x does not resolve to this server's public IP` warning | Wrong A record / multi-A / CDN | Point it at the VPS IP; `--yes` continues anyway and `40-cert` will then fail. |
| `certbot did not issue a certificate` (exit 1) | Inbound 80 closed (UFW **or** cloud firewall), or DNS wrong | From your workstation: `curl -I http://x/`. Open 80 inbound on both layers, re-run. |
| `Port 80/443/853 is in use by: …` | nginx/apache/something else | Stop the occupant or free the port; re-run `--only 00-preflight`. |
| `Another deploy run is already in progress` | Stale lock | `ps -ef \| grep install.sh`; if idle: `rm /var/lib/adguard-deploy/.lock`. |
| `AdGuardHome did not start` | Bad config / port collision | `journalctl -u AdGuardHome -n 40 --no-pager`; confirm YAML parses; re-run `--only 50-adguard`. |
| Unit stuck in `activating` / auto-restart | Stray `AdGuardHome` process holding `:3000` (usually from `--check-config`, which you must never run) | `ps -eo pid,ppid,etime,cmd \| grep '[A]dGuardHome'`, kill strays, `systemctl restart AdGuardHome`. |
| `Caddyfile validation failed` | typo in secret path / TLS path | Inspect printed diagnostics; edit `/etc/caddy/Caddyfile`; re-run `--only 70-caddyfile`. |
| Smoke test `FAIL : secret path (expected 302)` | caddy not running, or `SECRET_PATH` mismatch | `systemctl restart caddy`; confirm `SECRET_PATH` in `deploy.env` matches what you tested. |
| Smoke test `FAIL : no listener on :853` | AdGuard down or TLS not wired | `systemctl status AdGuardHome`; re-run `--only 50-adguard`. |
| `FAIL : 3000 not bound to localhost only` | `http.address` misconfigured | Treat as security issue: stop, inspect `/opt/AdGuardHome/AdGuardHome.yaml`. |
| SSH session died during firewall step | `SSH_PORT` wrong / cloud firewall | Restore access from the provider console; fix `SSH_PORT` or `SKIP_FIREWALL=yes`, re-run. |
| HTTP `429` while probing admin login | AdGuard rate-limits logins | Log in once, reuse the session cookie (MANUAL.md Appendix B.3). Never loop on `/control/login`. |
| DNS not resolving yet when you run verify | Propagation delay | Re-run `80-verify` later: `./install.sh --yes --force --only 80-verify`. |

Re-running is always safe: `./install.sh --yes` skips completed steps.

---

## 10. Rollback and uninstall

```bash
ssh -T root@$VPS 'cd /root/adguard-stealth-dns && setsid ./install.sh --uninstall --yes </dev/null >/tmp/uninstall.out 2>&1; echo EXIT=$?; tail -30 /tmp/uninstall.out'
```

> ⚠️ **`--uninstall --yes` skips the confirmation prompt** and removes Caddy, certbot, AdGuard
> Home, `/var/www/fake`, `/etc/ssl/adguard`, the deploy hook and state. Always get explicit
> human approval first — this is irreversible from the agent's side.

Left behind deliberately: Let's Encrypt live certs (`certbot delete --cert-name <domain>` to
remove) and UFW rules (`ufw reset` to clear — never do this to a remote box without console
access). Per-step config backups live at `/root/AdGuardHome.yaml.bak.<timestamp>`.

---

## 11. Never do this

1. **Never** `certbot renew --dry-run` while the deploy hook is installed — a *staging*
   certificate gets copied over the live one. Disable the hook first.
2. **Never** `AdGuardHome --check-config`. On v0.107.x it can spawn a full instance that never
   exits, grabs `:3000`, and loops the unit. Validate YAML structurally instead.
3. **Never** print, `cat`, `grep -r`, `git add` or commit `deploy.env` — it holds the admin
   password and the secret path.
4. **Never** change `http.address` to `0.0.0.0:3000`, disable `insecure_enabled`, or lower
   `schema_version` — admin exposure / DoH breakage / silent config migration.
5. **Never** re-run admin login in a loop (429 rate limit); one login, reuse the cookie.
6. **Never** remove the SSH UFW rule or `ufw reset`/`ufw disable` on a remote box.
7. **Never** run `--yes` unless every required variable is present in `deploy.env` or the
   environment — otherwise it either dies mid-flight or, if a TTY happens to exist, blocks on a
   prompt forever.
8. **Never** run `--force`, `--uninstall`, or repo-deletion actions without human approval.
9. **Never** assume exit 0 == healthy (§7).

---

## 12. Definition of done

Report to the human only after **all** of these pass:

- [ ] `EXIT=0` and no `FAIL :` lines in the installer output (`Smoke tests: N passed, 0 failed.`)
- [ ] All 9 `done.*` markers present in `/var/lib/adguard-deploy/`
- [ ] `caddy`, `AdGuardHome`, `ufw` all `active`
- [ ] `127.0.0.1:3000` bound; no `0.0.0.0:3000` / `*:3000`
- [ ] From your workstation: `/` → 200, random path → 200, secret path → 302, DoT cert CN matches
- [ ] DoH resolves a real name (MANUAL.md Appendix B.1)
- [ ] Admin URL + DoH URL + DoT host reported to the human; secret path flagged for password manager
- [ ] `deploy.env` present with mode `600` on the server; no secret left in your transcript or repo

Optional follow-ups to offer the human: key-only SSH, disabling password auth (MANUAL.md §15),
and `EXTRA_ALLOW` for any VPN ports.
