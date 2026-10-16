# Manual: Public DNS-over-HTTPS / DNS-over-TLS resolver with hidden admin UI and decoy front site

This manual reproduces, from scratch, the exact setup running on the reference VPS:

- **AdGuard Home** as the DNS engine.
- **Public resolvers: DoH and DoT only.** No public plain DNS (port 53), no DoQ.
- **The bare domain serves a fake "corporate file manager" page** — a decoy so scanners/port-sweeps see an innocuous site.
- **The AdGuard admin UI is not reachable at the domain root.** It lives behind a long secret path that forwards to AdGuard's own login page (no HTTP Basic Auth).
- **Caddy** terminates TLS on `:80`/`:443` and reverse-proxies the DoH endpoint and the secret admin path to AdGuard on `127.0.0.1:3000`.
- A single **Let's Encrypt certificate** is shared by Caddy (for `:443`) and AdGuard (for DoT on `:853`).

Everything below is copy-pasteable. Replace the placeholders in §0 with your own values first.

---

## Table of contents

0. [Values you must decide](#0-values-you-must-decide)
1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [DNS: point your name at the VPS](#3-dns-point-your-name-at-the-vps)
4. [Base server preparation](#4-base-server-preparation)
5. [Firewall (UFW)](#5-firewall-ufw)
6. [Install Caddy](#6-install-caddy)
7. [Issue the shared TLS certificate (certbot)](#7-issue-the-shared-tls-certificate-certbot)
8. [Install AdGuard Home](#8-install-adguard-home)
9. [Configure AdGuard Home (the critical YAML)](#9-configure-adguard-home-the-critical-yaml)
10. [Deploy the decoy front site](#10-deploy-the-decoy-front-site)
11. [Write the Caddyfile (routing brain)](#11-write-the-caddyfile-routing-brain)
12. [Start everything and verify](#12-start-everything-and-verify)
13. [Optional: import settings from another AdGuard config](#13-optional-import-settings-from-another-adguard-config)
14. [Gotchas and landmines](#14-gotchas-and-landmines)
15. [Hardening and maintenance](#15-hardening-and-maintenance)
16. [Appendix A: full file tree](#appendix-a-full-file-tree)
17. [Appendix B: verification cheat-sheet](#appendix-b-verification-cheat-sheet)
18. [Appendix C: rollback / uninstall](#appendix-c-rollback--uninstall)

---

## 0. Values you must decide

| Placeholder | Meaning | Reference example |
|---|---|---|
| `DOMAIN` | Public hostname with an A/AAAA record to the VPS | `YOURDOMAIN.example` |
| `EMAIL` | Contact email for Let's Encrypt | `you@example.com` |
| `SECRET_PATH` | Long random path hiding the admin UI. Never published. | `/REDACTED_SECRET_PATH` (no trailing slash) |
| `ADMIN_USER` | AdGuard admin username | `admin` |
| `ADMIN_PASS` | AdGuard admin password (strong) | — |
| `VPS_IP` | Public IPv4 of the server | `YOUR_VPS_IP` |

Generate a secret path (do this once, keep it):

```bash
SECRET_PATH="/$(openssl rand -hex 8)"   # -> /a1b2c3d4e5f60718
echo "$SECRET_PATH"
```

Set shell variables for the rest of this manual (paste as one block, edit values):

```bash
DOMAIN="dns.example.com"
EMAIL="you@example.com"
SECRET_PATH="/a1b2c3d4e5f60718"
ADMIN_USER="admin"
ADMIN_PASS="CHANGE_ME_TO_SOMETHING_STRONG"
```

> Recommendation: do the whole build as `root` (or with `sudo -i`). AdGuard's default unit runs the process as root; Caddy runs as the unprivileged `caddy` user.

---

## 1. Architecture

```
                          Internet
                             |
              +--------------+---------------+
              |  :80  (HTTP -> HTTPS redirect)|
              |  :443 (TLS, Caddy)            |
              |  :853 (TLS, AdGuard DoT)      |
              +--------------+---------------+
                             |
                 +-----------+-----------+
                 |        Caddy          |   terminates TLS with the shared cert
                 |  (owns :80 and :443)  |
                 +-----------+-----------+
                             |
   routing (mutually exclusive, in this order):
     1. /dns-query                      -> reverse_proxy 127.0.0.1:3000   (public DoH)
     2. $SECRET_PATH + everything under -> strip prefix -> 127.0.0.1:3000 (hidden admin UI)
     3. everything else                 -> /var/www/fake (decoy site)

                 AdGuard Home  (127.0.0.1:3000 only)
                 - admin web UI + DoH (plain HTTP behind Caddy, "insecure_enabled")
                 - DoT listener on :853 using /etc/ssl/adguard/{fullchain,privkey}.pem
                 - plain DNS: DISABLED     DoQ: DISABLED     :443: not used (Caddy owns it)
```

Key design rules:

- **Only Caddy listens publicly on `:443`.** AdGuard's own HTTPS listener is turned off (`tls.port_https: 0`) so there is no port clash and the admin UI can never be reached directly on the domain.
- **AdGuard listens only on `127.0.0.1:3000`.** Its web UI is never exposed on a public interface.
- **AdGuard's DoH runs over plain HTTP behind Caddy** (`http.doh.insecure_enabled: true`). Caddy does TLS; AdGuard just answers the DoH protocol on localhost.
- **AdGuard's DoT (`:853`) is public and speaks TLS directly** using the shared cert.
- **The decoy site is the catch-all.** Any path that isn't `/dns-query` or under `$SECRET_PATH` gets the fake page.

---

## 2. Prerequisites

- A VPS running **Debian 12/13** or **Ubuntu 22.04/24.04**, x86_64 or arm64.
- **Root** (or sudo) access.
- A **public IPv4** address.
- A **hostname** (`DOMAIN`) whose A (and optionally AAAA) record points to the VPS. If your home/server IP changes, use a dynamic-DNS provider (DuckDNS, `linkpc.net`, `afraid.org`, etc.) or a proper domain.
- **Inbound ports 80, 443, 853 reachable from the internet.** Verify from an external network later; many ISPs block 80/443 on residential links, and some cloud firewalls block them by default.
- The VPS must be able to reach the internet (for package installs and for AdGuard to fetch blocklists).
- No existing service is already using ports **80, 443, or 853**. Check before you start:

```bash
ss -tlnp | grep -E ':(80|443|853)\b' || echo "all three ports free"
```

- **Check which ports existing services already use** (e.g. WireGuard, SSH) so your firewall doesn't lock you out. See §5.

---

## 3. DNS: point your name at the VPS

Choose one:

**A) Real domain** — at your registrar/DNS provider create:

```
A     dns.example.com   ->  <VPS_IP>
```

**B) DuckDNS** (free dynamic DNS):

```bash
# create the subdomain in the DuckDNS dashboard, then:
curl -s "https://www.duckdns.org/update?domains=YOURNAME&token=YOURTOKEN&ip="
```

**C) linkpc.net / afraid.org** — use their dynamic-DNS update URL or dashboard to point `YOURNAME.<provider>` at the VPS public IP.

Verify propagation **before continuing** (Let's Encrypt will fail otherwise):

```bash
getent hosts "$DOMAIN"
# or: dig +short A "$DOMAIN"
```

The returned IP must equal your VPS public IP. Also confirm your router/provider isn't doing DNS rebinding protection or a captive portal on 80.

---

## 4. Base server preparation

```bash
apt update && apt -y upgrade
apt -y install curl wget gnupg ca-certificates apt-transport-https \
               debian-keyring debian-archive-keyring ufw openssl
timedatectl set-timezone UTC
```

Confirm DNS resolution works on the box itself (needed for installs):

```bash
getent hosts deb.debian.org || echo "resolver problem"
```

---

## 5. Firewall (UFW)

> **Read this first.** Before you enable UFW, list every port that legitimately needs to stay open (SSH, WireGuard, game servers, etc.). Enabling a deny-by-default firewall while overlooking a service port will cut it off. On the reference box, an extra WireGuard/AmneziaWG UDP port and an OpenFlux node TCP port had to be allowed for exactly this reason.

Discover what is currently listening:

```bash
ss -tlnp        # TCP
ss -ulnp        # UDP
```

Then configure (edit the extra lines to match your box; example extras shown commented):

```bash
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp          # SSH  -- NEVER forget this
ufw allow 80/tcp          # ACME HTTP-01 + HTTP->HTTPS redirect
ufw allow 443/tcp         # DoH + admin + decoy (TLS)
ufw allow 853/tcp         # DoT

# --- keep any pre-existing services (examples; REMOVE if unused) ---
# ufw allow 51820/udp     # WireGuard
# ufw allow 64672/udp     # AmneziaWG
# ufw allow 58472/tcp     # some app you run

# If the box routes a VPN, keep forwarding intact:
grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw \
  && echo "forward already ACCEPT" \
  || sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw --force enable
ufw status verbose
```

Expected result: `443/tcp`, `853/tcp`, `80/tcp`, `22/tcp` ALLOW inbound; everything else denied.

> Do **not** open `3000` or `53`. AdGuard's UI stays on localhost and plain DNS is disabled — if the firewall later shows `3000` or `53` open, something is misconfigured.

---

## 6. Install Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list

apt update
apt -y install caddy
```

The package starts Caddy immediately with the stock config. **Stop it for now** so port 80 is free for the certificate challenge:

```bash
systemctl stop caddy
```

---

## 7. Issue the shared TLS certificate (certbot)

We use **certbot** (not Caddy's built-in ACME) because the same cert/key files must be readable by **both** Caddy (for `:443`) and AdGuard (for `:853`).

```bash
apt -y install certbot
```

### 7.1 Create the shared cert directory

```bash
install -d -m 755 /etc/ssl/adguard
```

### 7.2 Obtain the certificate (standalone)

Port 80 must be free; Caddy is stopped and AdGuard is not installed yet, so we're fine. The `--pre-hook`/`--post-hook` are saved into the renewal config and will fence port 80 on every future renewal:

```bash
certbot certonly --standalone \
  --pre-hook  "systemctl stop caddy || true" \
  --post-hook "systemctl start caddy || true" \
  -d "$DOMAIN" \
  -m "$EMAIL" \
  --agree-tos --no-eff-email --non-interactive
```

Result: `/etc/letsencrypt/live/$DOMAIN/{fullchain.pem,privkey.pem}`.

### 7.3 Deploy hook (keeps the shared copy in sync, forever)

Create `/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh`:

```bash
cat > /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh <<'EOF'
#!/bin/bash
# Copy the freshly issued/renewed certificate into the shared location and
# make each service pick it up.
set -e
DOMAIN="__DOMAIN__"
LIVE="/etc/letsencrypt/live/$DOMAIN"
DEST="/etc/ssl/adguard"

install -d -m 755 "$DEST"
# fullchain: world-readable. privkey: readable by root and the caddy group only.
install -m 644 "$LIVE/fullchain.pem" "$DEST/fullchain.pem"
install -m 640 -o root -g caddy "$LIVE/privkey.pem" "$DEST/privkey.pem"
chown root:caddy "$DEST"

systemctl reload caddy   2>/dev/null || true   # Caddy hot-reloads the new cert
systemctl restart AdGuardHome 2>/dev/null || true # AdGuard re-reads cert at startup
EOF

# inject the real domain and enable it
sed -i "s|__DOMAIN__|$DOMAIN|" /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
```

Run it once now so the files exist before Caddy starts:

```bash
/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
ls -l /etc/ssl/adguard/
```

You should see `fullchain.pem` (root:root, 644) and `privkey.pem` (root:caddy, 640).

> **Why `root:caddy` + `640`:** Caddy's service runs as user `caddy` and must read the private key; AdGuard runs as root, which can read it too. If you later change Caddy's run user, update this group.

> **Renewal** is handled automatically by the `certbot.timer` systemd timer. Because renewals use `--standalone`, the saved `--pre-hook` stops Caddy to free `:80` (a few seconds of downtime), then `--post-hook` restarts it.

> **NEVER run `certbot renew --dry-run` on this box carelessly.** The dry-run uses Let's Encrypt **staging**, and the deploy hook above would dutifully copy the *staging* certificate over your live one, breaking DoT/DoH until the next real issuance. If you must dry-run, disable the deploy hook first.

---

## 8. Install AdGuard Home

Use the official installer:

```bash
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
```

This downloads AdGuard Home to `/opt/AdGuardHome`, installs a systemd unit (`AdGuardHome.service`), and starts the first-run **setup wizard** on `:3000` (listening on all interfaces temporarily).

### 8.1 Run the setup wizard once (to set the admin account)

Do this over an SSH tunnel so `:3000` is never exposed publicly:

```bash
# from YOUR machine:
ssh -L 3000:127.0.0.1:3000 root@<VPS_IP>
# then open http://127.0.0.1:3000 in your browser
```

Set the admin username/password to `$ADMIN_USER` / `$ADMIN_PASS`, finish the wizard, and let it reach the dashboard once. Then stop AdGuard so we can edit the YAML directly:

```bash
systemctl stop AdGuardHome
```

> The wizard writes a **bcrypt** hash for your password into `AdGuardHome.yaml`. Editing the YAML afterwards keeps that hash. This avoids hand-generating a compatible bcrypt string.

---

## 9. Configure AdGuard Home (the critical YAML)

Edit `/opt/AdGuardHome/AdGuardHome.yaml`. The settings below are the ones that make the whole architecture work. **Do not blindly overwrite the file** — the wizard-generated `users:`, `filters:`, `clients:`, etc. should stay. Change/insert these keys:

```yaml
http:
  address: 127.0.0.1:3000        # (1) bind the admin UI + DoH to LOCALHOST only
  session_ttl: 720h
  doh:
    enabled: true
    insecure_enabled: true       # (2) REQUIRED: TLS is terminated by Caddy,
                                 #     so Caddy->AdGuard is plain HTTP. Without
                                 #     this, /dns-query returns errors.

dns:
  bind_hosts:
    - 0.0.0.0                    # where AdGuard would bind plain DNS (unused, see below)
  port: 53
  serve_plain_dns: false         # (3) NO public plain DNS on :53
  # ... your upstream_dns / bootstrap_dns / fallback_dns / etc. stay here ...

tls:
  enabled: true
  server_name: DOMAIN            # your hostname
  force_https: false
  certificate_path: /etc/ssl/adguard/fullchain.pem   # (4) the shared cert
  private_key_path: /etc/ssl/adguard/privkey.pem
  port_https: 0                  # (5) DO NOT bind :443 -- Caddy owns it
  port_dns_over_tls: 853         # (6) public DoT lives here
  port_dns_over_quic: 0          # (7) DoQ OFF

schema_version: 34               # (8) PIN THIS -- see the warning below
```

Then apply ownership and restart:

```bash
chown root:root /opt/AdGuardHome/AdGuardHome.yaml
chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
systemctl start AdGuardHome
sleep 3
systemctl is-active AdGuardHome
ss -tlnp | grep AdGuardHome      # expect 127.0.0.1:3000 and *:853 ONLY
```

### Why each numbered line matters

1. **`http.address: 127.0.0.1:3000`** — if you leave the wizard's default (`0.0.0.0:3000`), the admin UI is reachable at `http://<VPS_IP>:3000` (and via the domain if anything proxies it), defeating the "hidden admin" design.
2. **`http.doh.insecure_enabled: true`** — AdGuard's DoH endpoint normally requires HTTPS itself. Behind Caddy we terminate TLS upstream, so AdGuard must be told to accept plain HTTP DoH. **This is the single most common cause of a broken `/dns-query`.**
3. **`dns.serve_plain_dns: false`** — no plaintext DNS exposed.
4. **cert paths** — point at the shared copy managed by the certbot deploy hook.
5. **`tls.port_https: 0`** — prevents AdGuard from fighting Caddy for `:443`. `0` = don't listen.
6. **`tls.port_dns_over_tls: 853`** — this is how DoT is exposed.
7. **`tls.port_dns_over_quic: 0`** — DoQ off (not requested; keep the attack surface minimal).
8. **`schema_version`** — see below.

> **Schema-version landmine.** If you let AdGuard perform a config migration (by writing a config whose `schema_version` is *lower* than the binary expects, then restarting), it will rewrite the YAML and can (a) re-nest `bootstrap_dns` in a way that then fails to parse, and (b) drop newer keys such as `http.doh.insecure_enabled`. On a config taken from an *older* AdGuard, set `schema_version` to the value the **current** binary uses (find it with `AdGuardHome --version` / by running the wizard once and reading the generated file) and keep it pinned. The reference deployment pins **34**.

### The systemd unit

The installer creates `/etc/systemd/system/AdGuardHome.service`. Confirm it matches (so it always loads our explicit config and never self-updates):

```ini
[Unit]
Description=AdGuard Home
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome --no-check-update
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable AdGuardHome
```

---

## 10. Deploy the decoy front site

```bash
install -d -m 755 /var/www/fake
curl -fsSL -o /var/www/fake/index.html \
  https://raw.githubusercontent.com/Liafanx/MTProxyL/refs/heads/main/templates_html/filemanager.html
chmod 644 /var/www/fake/index.html
```

That page renders a fake "corporate file manager". Its login form is client-side only (it always fails and stores nothing). Verify the file is non-trivial in size:

```bash
wc -c /var/www/fake/index.html    # expect tens of KB
```

> Any static HTML works here. The point is only that the root of the domain looks like an ordinary, boring site to automated scanners.

---

## 11. Write the Caddyfile (routing brain)

Replace `/etc/caddy/Caddyfile` with the following (substitute `DOMAIN` and `SECRET_PATH`):

```caddyfile
{
	email your@email.example     # used if Caddy ever does ACME; harmless here
}

# (Optional) trust nothing special; Caddy passes X-Forwarded-* by default.
DOMAIN {
	encode zstd gzip

	# Use the shared certbot-issued certificate (also used by AdGuard for DoT)
	tls /etc/ssl/adguard/fullchain.pem /etc/ssl/adguard/privkey.pem

	# ---- 1. Public DoH endpoint (RFC 8484), GET + POST -> AdGuard ----
	handle /dns-query {
		reverse_proxy 127.0.0.1:3000
	}

	# ---- 2. Bare secret path -> append the trailing slash ----
	handle SECRET_PATH {
		redir SECRET_PATH/ 302
	}

	# ---- 3. Secret admin UI -> AdGuard, prefix stripped from the upstream,
	#         and root-absolute redirects re-prefixed on the way back ----
	handle SECRET_PATH/* {
		uri strip_prefix SECRET_PATH
		header >Location ^/(.*)$ SECRET_PATH/$1
		reverse_proxy 127.0.0.1:3000
	}

	# ---- 4. Everything else -> the decoy site ----
	handle {
		root * /var/www/fake
		try_files {path} /index.html
		file_server
	}
}
```

For the reference example, the two `SECRET_PATH` lines become `/REDACTED_SECRET_PATH`. Concretely, handler 3 looks like:

```caddyfile
	handle /REDACTED_SECRET_PATH/* {
		uri strip_prefix /REDACTED_SECRET_PATH
		header >Location ^/(.*)$ /REDACTED_SECRET_PATH/$1
		reverse_proxy 127.0.0.1:3000
	}
```

Validate and start:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
```

### How handler 3 actually works (and why it's safe)

The nice part: **AdGuard's dashboard is sub-path tolerant**, so a prefix-stripping proxy works. This holds because AdGuard's UI:

- uses a **`HashRouter`** (`hashType="noslash"`) — its client-side routes live in the URL `#fragment`, which is never sent to the server, so the path prefix is irrelevant to navigation;
- loads its assets with **relative** paths;
- uses a **relative API base** (`control`);
- redirects to the app root after login via `pathname.replace("/login.html", "/")` — i.e. relative to the *current* path, so it stays inside the secret prefix.

Caddy strips `/REDACTED_SECRET_PATH` before the request hits AdGuard, so AdGuard thinks it is at `/`. When AdGuard emits a `Location:` redirect (e.g. `302 -> /login.html`), the line

```
header >Location ^/(.*)$ /REDACTED_SECRET_PATH/$1
```

rewrites it to `/REDACTED_SECRET_PATH/login.html` so the browser stays inside the prefix. (`header >Field <regex> <replacement>` is Caddy's deferred response-header regex replace; `>` enables defer so it runs after the proxy writes its headers.)

> If you instead use `handle_path`, Caddy strips the prefix for you — but you still need the `Location` rewrite, otherwise AdGuard's redirects escape the prefix.

---

## 12. Start everything and verify

```bash
systemctl restart AdGuardHome
systemctl restart caddy
sleep 3
systemctl is-active caddy AdGuardHome
ss -tlnp | grep -E ':(80|443|853|3000)\b'
```

Expected listeners:

```
0.0.0.0:80      caddy            (redirect -> https)
0.0.0.0:443     caddy
*:853           AdGuardHome
127.0.0.1:3000  AdGuardHome      (localhost only!)
```

Now verify from **another machine** (or via the public internet):

```bash
# 1) DoH resolves a name (wire format). Expect HTTP 200 + a DNS answer.
Q=$(printf '\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')
curl -s "https://$DOMAIN/dns-query?dns=$Q" -H 'accept: application/dns-message' \
  | xxd | head -3

# 2) Decoy site. Expect 200 + the fake HTML.
curl -sI "https://$DOMAIN/" | head -1
curl -s  "https://$DOMAIN/" | grep -io '<title>[^<]*</title>' | head -1

# 3) A random path also returns the decoy (catch-all). Expect 200.
curl -sI "https://$DOMAIN/some/random/path" | head -1

# 4) Secret admin path. Expect 302 (redirect into the prefixed login page).
curl -sI "https://$DOMAIN$SECRET_PATH/" | head -1

# 5) DoT. Expect the certificate subject/name to match DOMAIN and verify OK.
echo | openssl s_client -connect $DOMAIN:853 -servername $DOMAIN 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

For a real end-to-end resolve check, use the appendix script in §17.1 and confirm:
- a normal domain resolves (rcode 0),
- a domain that should be blocked (e.g. `doubleclick.net` with the stock AdGuard filter) returns `0.0.0.0` / NXDOMAIN.

Finally confirm the admin UI truly works through the secret link: open `https://$DOMAIN$SECRET_PATH/` in a browser, log in with `$ADMIN_USER`/`$ADMIN_PASS`, and confirm the dashboard loads and `/control/status` responds.

---

## 13. Optional: import settings from another AdGuard config

If you have an existing `AdGuardHome.yaml` from another deployment and want to bring over its **functional** settings (upstreams, filters, rules, limits) **without** importing its domain, TLS certs, admin password, or bind addresses — merge deliberately.

**Principle: start from the NEW, known-good config and copy only the values you want.** Never start from the old file (its identity/network/TLS/admin keys would clobber the new server).

Example merge script (run on the new server; adjust the allow-list to taste):

```python
# merge_adguard.py
import sys, yaml

# new (target) config and old (source) config
NEW = '/opt/AdGuardHome/AdGuardHome.yaml'
OLD = '/path/to/old/AdGuardHome.yaml'
OUT = '/tmp/AdGuardHome.merged.yaml'

new = yaml.safe_load(open(NEW))
old = yaml.safe_load(open(OLD))

def take(section, keys):
    """Copy old[section][k] -> new[section][k] for each key present in old."""
    if section not in old:
        return
    new.setdefault(section, {})
    for k in keys:
        if k in old[section]:
            new[section][k] = old[section][k]

# --- DNS behaviour (safe to import) ---
take('dns', ['upstream_dns', 'upstream_mode', 'bootstrap_dns', 'fallback_dns',
             'ratelimit', 'ratelimit_subnet_len_ipv4', 'ratelimit_subnet_len_ipv6',
             'cache_size', 'blocked_hosts', 'enable_dnssec', 'upstream_timeout',
             'refuse_any', 'edns_cs_enabled', 'disable_ipv6',
             'dnssec_query_timeout', 'use_private_ptr_resolvers'])
# --- filtering (safe to import) ---
take('filtering', ['filters', 'whitelist_filters', 'user_rules', 'safe_search',
                   'safe_browsing', 'parental', 'rewrites', 'blocked_services'])
# --- misc behaviour ---
take('clients', ['runtime_sources'])

# --- DELIBERATELY NOT IMPORTED (identity / network / TLS / auth) ---
#   users                          -> keep the new admin credentials
#   tls.*                          -> keep the new domain + cert paths
#   http.address / http.doh.*      -> keep 127.0.0.1:3000 + insecure_enabled
#   dns.bind_hosts / dns.port / dns.serve_plain_dns
#   schema_version                 -> keep pinned to the current binary's value

yaml.safe_dump(new, open(OUT, 'w'), sort_keys=False, allow_unicode=True)
print('wrote', OUT)
```

Then deploy it **safely** (see the landmine in §14 about `--check-config`):

```bash
cp -a /opt/AdGuardHome/AdGuardHome.yaml /root/AdGuardHome.yaml.bak.$(date +%s)
systemctl stop AdGuardHome
# wait until inactive (AdGuard can take several seconds to flush state)
for i in $(seq 1 60); do systemctl is-active --quiet AdGuardHome || break; sleep 1; done
cp -a /tmp/AdGuardHome.merged.yaml /opt/AdGuardHome/AdGuardHome.yaml
chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
systemctl start AdGuardHome
sleep 5
systemctl is-active AdGuardHome && echo OK || { echo "FAILED -> rolling back";
  systemctl stop AdGuardHome
  cp -a /root/AdGuardHome.yaml.bak.* /opt/AdGuardHome/AdGuardHome.yaml
  systemctl start AdGuardHome; }
```

**Rules of thumb for a safe merge:**

- After the merge, diff the result against the new config and confirm the **preserved** keys are unchanged: `users[0].password`, `tls.server_name`, `tls.certificate_path`, `tls.private_key_path`, `tls.port_https` (0), `tls.port_dns_over_quic` (0), `tls.port_dns_over_tls` (853), `http.address` (`127.0.0.1:3000`), `http.doh.insecure_enabled` (true), `dns.serve_plain_dns` (false), `schema_version`.
- Config taken from an *older* AdGuard may reference keys the newer binary renamed — validate structurally (YAML loads, keys look right) rather than trusting a blunt `--check-config`.
- Imported `user_rules` often contain `$client='<some old IP>'` scoping. Those IPs are meaningless on the new server — review and update/remove them.

---

## 14. Gotchas and landmines

These are the exact traps encountered while building the reference deployment. Read them before deploying.

1. **`AdGuardHome --check-config` is a trap on this version.**
   On AdGuard Home ~v0.107.x, `AdGuardHome --check-config -c <file>` can start a **full instance that never exits**, binding `:3000` and causing the systemd unit to loop in `activating / auto-restart` (because the port is taken). If you see the unit stuck in `activating`, look for a stray process:
   ```bash
   ps -eo pid,ppid,etime,cmd | grep '[A]dGuardHome'
   ```
   Kill the stray, then start the service normally. **To validate configs, do it structurally (YAML loads, diff against a known-good file) and deploy via `stop -> swap -> start` with a rollback copy.** Do not rely on `--check-config` on a live host.
   Also note: running `--check-config` while the service is *running* fails with a harmless `session_storage: opening db ... timeout` (the running process holds the BoltDB lock) — a false negative.

2. **`http.doh.insecure_enabled: true` is mandatory** behind a TLS-terminating reverse proxy. Omit it and `/dns-query` breaks even though the proxy looks correct.

3. **Pin `schema_version`.** Writing a config with a lower `schema_version` and restarting triggers a migration that can nest `bootstrap_dns` (unparseable) and silently drop `http.doh.insecure_enabled`. See §9.

4. **`tls.port_https: 0`** — leave AdGuard's own HTTPS listener off. If set to 443, it collides with Caddy and the admin UI may become directly reachable.

5. **`http.address` must be `127.0.0.1:3000`.** Anything like `0.0.0.0:3000` exposes the admin UI. If `ss` ever shows `*:3000` for AdGuard, treat it as a misconfiguration (in the reference case it was a stray `--check-config` process, not the service).

6. **Do not run `certbot renew --dry-run`** with the deploy hook installed — the staging cert would overwrite the live one. Disable the hook first if you must dry-run.

7. **DoT must be publicly reachable on `:853`** — verify with `openssl s_client` from outside. If it times out, check both UFW and any cloud provider firewall.

8. **AdGuard rate-limits failed logins** (HTTP `429` + `Retry-After`). Don't script repeated `/control/login` attempts. For verification, log in **once**, keep the session cookie, and reuse it.

9. **Hash-based routing is what makes the prefix trick work** — if a future AdGuard version switches the dashboard to a history/path router, the secret-prefix scheme could break. Re-test the admin flow after AdGuard upgrades.

10. **Caddy `handle` blocks are evaluated in the order written** within a site block. Keep `/dns-query` and `SECRET_PATH/*` before the catch-all `handle {}`.

---

## 15. Hardening and maintenance

**Switch SSH to keys and disable passwords:**

```bash
# on the server, after installing your public key in /root/.ssh/authorized_keys
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh
```

**Automatic security updates:**

```bash
apt -y install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades   # enable
```

**fail2ban** to throttle SSH brute force:

```bash
apt -y install fail2ban
systemctl enable --now fail2ban
```

**Run AdGuard as non-root (optional, advanced).** The default unit runs AdGuard as root so it can bind `:853`. If you prefer a dedicated user, grant `CAP_NET_BIND_SERVICE` and point the unit at that user; ensure that user can read `/etc/ssl/adguard/privkey.pem` (add it to the `caddy` group or adjust perms in the deploy hook).

**Renewal check** (visible, non-destructive):

```bash
certbot certificates
systemctl list-timers | grep certbot
```

**Keep the blocklists fresh:** AdGuard refreshes enabled filters on its own schedule (default ~24h). Confirm in the UI under *Filters*, or via the API (`/control/filtering/status` → each filter's `last_updated`).

**Backups** worth taking (they are small):

```bash
tar czf /root/adguard-etc-$(date +%F).tgz \
  /opt/AdGuardHome/AdGuardHome.yaml \
  /etc/caddy/Caddyfile \
  /var/www/fake/index.html \
  /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
```

---

## Appendix A: full file tree

```
/etc/caddy/Caddyfile                                   Caddy vhost: TLS, DoH proxy, secret admin path, decoy
/var/www/fake/index.html                               decoy front-site HTML
/opt/AdGuardHome/AdGuardHome                           AdGuard binary
/opt/AdGuardHome/AdGuardHome.yaml                      AdGuard config (schema_version pinned)
/opt/AdGuardHome/data/                                 AdGuard runtime state (query log, stats, sessions DB)
/etc/systemd/system/AdGuardHome.service                AdGuard unit
/etc/systemd/system/caddy.service                      Caddy unit (from the package)
/etc/ssl/adguard/fullchain.pem                         shared cert (root:root 644)
/etc/ssl/adguard/privkey.pem                           shared key  (root:caddy 640)
/etc/letsencrypt/live/<DOMAIN>/                        certbot live certs (symlinks)
/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh   copies certs + reloads services
```

Enabled services: `caddy`, `AdGuardHome`, `certbot.timer`, `ufw`, (optionally `fail2ban`).

---

## Appendix B: verification cheat-sheet

### B.1 Real DoH resolution + block test

```python
# doh_check.py  -- run on any machine with python3 (stdlib only)
import socket, struct, ssl, urllib.request
URL = 'https://DNS.EXAMPLE.COM/dns-query'
CTX = ssl.create_default_context()

def q(name):
    hdr = struct.pack('>HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
    body = b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\x00\x01\x00\x01'
    req = urllib.request.Request(URL, data=hdr + body,
          headers={'content-type': 'application/dns-message', 'accept': 'application/dns-message'})
    r = urllib.request.urlopen(req, context=CTX, timeout=15).read()
    flags, an = struct.unpack('>HH', r[2:6])[0], struct.unpack('>H', r[6:8])[0]
    i = 12
    while r[i] != 0: i += r[i] + 1
    i += 5
    out = []
    for _ in range(an):
        i += 2
        t, _, _, n = struct.unpack('>HHIH', r[i:i+10]); i += 10
        d = r[i:i+n]; i += n
        out.append(socket.inet_ntoa(d) if t == 1 and n == 4 else f'type{t}')
    return flags & 0xF, out

for d in ['example.com', 'cloudflare.com', 'doubleclick.net']:
    print(d, q(d))
```

Expect rcode `0` and real IPs for the first two; `0.0.0.0` (or NXDOMAIN) for `doubleclick.net` when a blocklist is enabled.

### B.2 Quick shell checks

```bash
curl -sI "https://$DOMAIN/"                                   # 200, decoy
curl -sI "https://$DOMAIN/dns-query"                          # any response (405/400 is fine; proves routing)
curl -sI "https://$DOMAIN$SECRET_PATH/"                       # 302 into prefixed login
openssl s_client -connect $DOMAIN:853 -servername $DOMAIN </dev/null 2>/dev/null | openssl x509 -noout -dates
ss -tlnp | grep -E ':(80|443|853|3000)\b'                     # 3000 must be 127.0.0.1
```

### B.3 Admin API check (single login, reused cookie)

```bash
SP="/a1b2c3d4e5f60718"; H="https://$DOMAIN"
curl -s -c /tmp/cj -o /dev/null -w 'login: %{http_code}\n' \
  -X POST "$H$SP/control/login" -H 'content-type: application/json' \
  -d '{"name":"admin","password":"YOURPASS"}'
curl -s -b /tmp/cj "$H$SP/control/status" | head -c 200; echo
curl -s -b /tmp/cj "$H$SP/control/filtering/status" | head -c 300; echo
rm -f /tmp/cj
```

---

## Appendix C: rollback / uninstall

**Roll back AdGuard config to the last good copy:**

```bash
systemctl stop AdGuardHome
cp -a /root/AdGuardHome.yaml.bak.<timestamp> /opt/AdGuardHome/AdGuardHome.yaml
systemctl start AdGuardHome
```

**Tear the whole thing down (reverse order):**

```bash
systemctl disable --now caddy
caddy stop 2>/dev/null || true

/opt/AdGuardHome/AdGuardHome -s uninstall   # removes the AdGuard unit (installed mode)
rm -rf /opt/AdGuardHome

apt -y remove --purge caddy certbot
rm -rf /var/www/fake /etc/ssl/adguard
rm -f /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh

# optional: revoke/delete the certificate
# certbot delete --cert-name "$DOMAIN"

# firewall back to default
ufw reset
```

---

*End of manual.*
