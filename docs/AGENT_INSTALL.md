# Install via an AI agent (SSH runbook)

For Codex, OpenCode and other agents operating **from a workstation over SSH** onto a
fresh Debian 12/13 or Ubuntu 22.04/24.04 VPS. Read this file before executing commands.
See [MANUAL.md](MANUAL.md) for architecture and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for installation errors and notices.

## 1. Collect inputs and approval

Collect the VPS address, verified SSH host-key fingerprint, SSH username/key/port,
domain, Let's Encrypt email, admin username/password (at least 8 characters), and any additional ports that
must remain accessible (`EXTRA_ALLOW`, e.g. `51820/udp 64672/udp`). Never request
passwords in public chat or put them in process arguments, source control, or logs.
The operator may instead prepare a private config file or approve password generation.

Before changing the server, obtain approval to install packages, run third-party
installers, configure services, accept Let's Encrypt's terms, and enable deny-by-default
UFW. Preserve the actual SSH port and required VPN/app ports. Have provider-console
access available. Do not reset an existing firewall or stop unrelated services.

Stop if the target is wrong, privileges are insufficient, DNS is wrong, required ports
are occupied by unrelated software, or preserving access is uncertain. DNS-provider
changes require the operator's authorization; never assume provider credentials exist.

## 2. Connect and inspect (no changes)

These examples use **Bash on the workstation** and root SSH access. For a non-root
account, arrange authorized passwordless `sudo -n` and root-owned paths first; do not
let sudo prompt invisibly. Verify the host fingerprint out of band and add the key to
known_hosts before using `StrictHostKeyChecking=yes`.

```bash
VPS=203.0.113.10                    # replace
SSH_PORT=22                        # actual SSH server port, not an assumption
DOMAIN=dns.example.com             # replace
SSH=(ssh -T -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
     -o StrictHostKeyChecking=yes "root@$VPS")
SCP=(scp -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes)
"${SSH[@]}" 'id -u; cat /etc/os-release; ss -tlnp; ss -ulnp; command -v curl; command -v openssl; command -v tar; command -v git || true'
```

Require root (`id -u` = 0), a supported OS, `curl`, `openssl`, and an IPv4 A record
matching the VPS. Inspect DNS and outbound HTTPS with bounded commands:

```bash
"${SSH[@]}" "bash -s -- '$DOMAIN'" <<'REMOTE'
set -euo pipefail
domain=$1
ip=$(curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org)
resolved=$(timeout 15 getent ahostsv4 "$domain" | awk '{print $1}' | sort -u)
printf 'Public IPv4: %s\nA records:\n%s\n' "$ip" "$resolved"
grep -qxF "$ip" <<<"$resolved" || { echo 'STOP: incorrect A record' >&2; exit 1; }
for port in 80 443 853 3000 3001; do
  listeners=$(ss -tlnH | awk -v p=":$port" '$4 ~ (p "$") {print}')
  if [ -n "$listeners" ]; then
    printf 'STOP: port %s occupied; inspect owner before proceeding\n' "$port" >&2
    exit 1
  fi
done
REMOTE
```

Validate the domain as a hostname before substituting it into remote commands (letters,
digits, dots and hyphens only; no quotes or shell syntax). On a **resume**, expected
Caddy/AdGuard listeners are not a reason to kill processes: inspect their ownership.

Confirm provider firewall/security-group rules allow TCP 80/443/853 and the real SSH
port, and block public 53/3000/3001. If AAAA is published, it must reach this server too;
otherwise correct/remove it with approval. A refused HTTP connection before any HTTP
server exists is normal: `curl` status `000` does **not** prove the firewall blocks 80.
External HTTP-01 reachability is established during ACME validation (or with an approved
temporary listener), not by probing an empty socket.

## 3. Obtain the code (Git is optional)

If Git exists, clone into `/root/adguard-stealth-dns`. Do not overwrite an existing
checkout or private `deploy.env`; inspect and reuse it on resume.

```bash
"${SSH[@]}" 'git clone https://github.com/skarusto/adguard-stealth-dns.git /root/adguard-stealth-dns'
```

If `git: command not found`, use an archive; no Git package installation is necessary:

```bash
"${SSH[@]}" 'bash -s' <<'REMOTE'
set -euo pipefail
umask 077
test ! -e /root/adguard-stealth-dns
archive=$(mktemp /root/adguard-source.XXXXXX.tar.gz)
trap 'rm -f "$archive"' EXIT
curl -fSL --connect-timeout 10 --max-time 120 \
  https://github.com/skarusto/adguard-stealth-dns/archive/refs/heads/main.tar.gz -o "$archive"
sha256sum "$archive"               # provenance record, not independent authenticity proof
install -d -m 700 /root/adguard-stealth-dns
tar -xzf "$archive" --strip-components=1 -C /root/adguard-stealth-dns
REMOTE
```

Prefer an operator-approved commit SHA instead of mutable `main` for reproducibility
(archive URL: `/archive/<commit-sha>.tar.gz`). Review downloaded scripts before running.
Never compare to a hash from another installation unless it is the exact same archive.

## 4. Prepare trusted private configuration

Have the operator supply a **shell-syntax** config file with mode 600. It is sourced
as code, not parsed as inert dotenv data; use only a trusted file. Required keys:

```text
DOMAIN=dns.example.com
EMAIL=operator@example.com
ADMIN_USER=admin
ADMIN_PASS=<securely supplied password, shell-quoted>
SSH_PORT=<actual SSH server port>
EXTRA_ALLOW='<space-separated required port/protocol entries>'
SKIP_FIREWALL=no
VPN_FORWARDING=no
DO_UPGRADE=no
```

These are placeholders, **not** an executable config. Generate shell-safe assignments
with Bash `printf '%s=%q\n' KEY "$value"` without printing them into an agent transcript.
An unset `SECRET_PATH` is generated as `/` plus 32 random hex characters and persisted;
never reuse an example secret. `TIMEZONE` defaults to UTC. Optional
`ADGUARD_UPSTREAMS`, `ADGUARD_BOOTSTRAP`, `ADGUARD_FALLBACK` take newline-separated entries.
`ENABLE_DEFAULT_FILTERS=yes` enables the stock filter. The decoy is vendored by default;
`DECOY_URL` optionally overrides it. `VPN_FORWARDING=yes` is opt-in for VPN routers.

Transfer the private file with SCP (use the same port/key as SSH), then verify metadata
only. Do not print its contents:

```bash
# CONFIG_LOCAL points to the operator's existing mode-600 file.
"${SCP[@]}" "$CONFIG_LOCAL" "root@$VPS:/root/adguard-stealth-dns/deploy.env"
"${SSH[@]}" 'chown root:root /root/adguard-stealth-dns/deploy.env; chmod 600 /root/adguard-stealth-dns/deploy.env; stat -c "%U %a %n" /root/adguard-stealth-dns/deploy.env'
```

Keep workstation copies only with authorization. On Windows, use numeric SID notation
such as `*S-1-...` with `icacls`, not localized group names; **stop before writing
secrets** if permission setup fails. Do not bypass a declined credential-export step.
The VPS config remains
the private source of credentials; do not claim local export succeeded without evidence.

## 5. Install, preserving the exit status

```bash
"${SSH[@]}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd /root/adguard-stealth-dns
umask 077
output=$(mktemp /root/agent-install.XXXXXX.out)
printf 'Private transcript: %s\n' "$output"
rc=0
setsid --wait bash ./install.sh --yes </dev/null >"$output" 2>&1 || rc=$?
printf 'Installer exit: %s\n' "$rc"
grep -E 'Smoke tests:|FAIL :|Step .* failed' "$output" || true
exit "$rc"
REMOTE
```

Use a long enough SSH/tool timeout for package downloads and ACME. `--yes` authorizes
the firewall step without another confirmation; required values must already exist.
Keep transcripts private: output/logs contain the secret admin path even though passwords
are not intentionally printed. Do not paste raw logs or configs; redact secrets first.

If the connection drops, inspect the previous process and private transcript before
starting another run. A live `flock` automatically releases when its holder exits;
**never unlink `/var/lib/adguard-deploy/.lock`** to bypass it (that can allow concurrent
installers). Markers are `/var/lib/adguard-deploy/done.<step>`; log is
`/var/log/adguard-deploy.log` (root-only).

Resume with the same `bash ./install.sh --yes` and the same config: completed steps are
skipped, the failed step retries. `--only 40-cert` or `--only 80-verify` explicitly
reruns that step even if marked done; **no `--force` needed**. `--force` redoes all
steps and is not ordinary recovery. Do not regenerate the password/path or delete certs.

Step `50-adguard` downloads the official release archive directly (not AdGuard's
auto-starting shell installer), creates `/opt/AdGuardHome` mode 700, and launches the
binary with `--web-addr` bound to loopback on an ephemeral port. It configures through
the local setup API using a different temporary web port and high, non-privileged loopback
DNS port numbers. The binary must still be launched as root during initialization; do not
run this bootstrap as an unprivileged user. It stops the tracked process, then patches final listeners. Existing configs
bypass initialization. The binary's actual schema version is preserved; never invent
one or run `AdGuardHome --check-config`. `SKIP_FIREWALL=yes` still means you are
responsible for provider/external firewall rules and external verification.

Fresh installs currently pin **v0.107.79**; existing binaries are reused. Retest first-run
setup/config patching when changing the release pin. Before patching, a private backup
is saved beside the YAML as `/opt/AdGuardHome/AdGuardHome.yaml.bak.<timestamp>`.
The full Admin URL is written only to the private deploy log, not terminal output.

## 6. Verify independently and report truthfully

`80-verify` now **returns nonzero on any failed check**, clears its stale success marker,
and prevents a misleading deployment-complete message. Still require the current-run
summary `Smoke tests: N passed, 0 failed.` — counts can change as tests are added.
Old appended log entries and markers alone do not establish current health.

Require all of these:

- All nine `done.*` markers after a complete run; Caddy and AdGuard active.
- `ufw status verbose` says active **and** `ufw.service` active/enabled, unless firewall
  management was explicitly skipped; inspect provider rules separately.
- `certbot.timer` active/enabled; shared cert/key exist with restricted key permissions.
- AdGuard admin/DoH only on `127.0.0.1:3000`, no extra wildcard/public admin listener.
- DoT on public `:853`, not just `127.0.0.1:853`; `dns.bind_hosts` controls DoT too.
  `dns.serve_plain_dns=false` must remain false and public TCP/UDP 53 must stay closed.
- From the workstation: HTTPS root/random path 200; **both** bare and slash secret
  paths redirect 302 to exactly `<secret>/login.html`; login page 200 with title
  `<title>Login</title>` (case-insensitive), no loop/decoy.
- Real DoH GET **and POST** DNS answers (not merely HTTP 200 or an empty GET), and
  a real DoT query; see [MANUAL.md Appendix B](MANUAL.md#appendix-b-verification-cheat-sheet).
- DoT certificate chain trusted, correct hostname and validity. Use bounded
  `openssl s_client -verify_hostname "$DOMAIN" -verify_return_error -servername "$DOMAIN"`;
  looking at a printed CN alone does not verify TLS.
- External 53/3000/3001 inaccessible. Local config/first-run logs/transcripts mode 600,
  AdGuard directory mode 700. Never dump YAML to verify this.

If checking admin authentication, perform one login and reuse the cookie; honor HTTP
429/Retry-After. Report unavailable external tests as **not verified**, never passed.
Deliver the Admin URL/password via the operator's approved private channel and DoH/DoT
endpoints normally; remind them to save credentials/path in a password manager. Mention
any pending DNS fixes, benign notices, or incomplete credential export.

## 7. Recovery and forbidden shortcuts

Use [TROUBLESHOOTING.md](TROUBLESHOOTING.md): it covers APT key permissions, executable
Certbot hooks, parent-domain CAA/SERVFAIL, wizard port collisions, loopback DoT,
redirect syntax, UFW states, benign package notices, and Windows ACL/export failures.

Never disable APT signature checking, ACME/TLS verification, expose the wizard to fix
setup, print secrets, blindly kill unrelated processes, reset UFW remotely, or delete
state/certs to resume. Do not run `certbot renew --dry-run` carelessly with deploy hooks;
avoid copying staging certificates over trusted live files. Destructive teardown
(`bash ./install.sh --uninstall --yes`) skips confirmation and needs explicit approval.
See the human manual for exactly what uninstall removes and leaves behind.
