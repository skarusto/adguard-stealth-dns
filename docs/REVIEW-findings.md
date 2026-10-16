# Deep Review: Auto-Deployment Scripts

Review-only audit — no code was changed. Full pass over `install.sh`, 12 stage
scripts under `scripts/`, 4 files under `templates/`, and both READMEs
(~1,100 LOC total). Date: 2026-10-16.

---

## CRITICAL

**1. Broken `--help` output** — `install.sh:109`
`sed -n '2,24p' "$0"` was written for a layout where the usage comment block was
at the top. The bootstrap block (`install.sh:4-64`) was later inserted above it,
so `--help` now dumps raw bootstrap code (the `SELF=...` / curl-download logic),
not the usage text at `install.sh:70-81`. First thing a cautious user sees is
garbage. *Direction: re-anchor the range to the actual comment block, or extract
usage into a heredoc so it can't drift again.*

**2. `curl | sh` of the AdGuard installer without `-f`** —
`scripts/50-adguard.sh:13-14`
`curl -s -S -L ... | sh -s -- -v` has no `--fail`. A 404/5xx error page body is
piped into `sh` as root. With `pipefail` inherited, curl's failure doesn't save
you because `sh` happily "succeeds" on garbage. Same pattern class as the
bootstrap, but here there isn't even a manifest fallback. *Direction: add `-f`,
pin a version/ref instead of `master`, and verify the binary checksum
post-install.*

**3. Admin password exposed in process argv** — `scripts/50-adguard.sh:47`
`htpasswd -nbBC 14 "" "$ADMIN_PASS"` puts the plaintext password in argv,
visible via `ps` to any local process for the duration of the call. This
directly contradicts the documented contract: `README.en.md:85` promises
"secrets never in `argv`" and `docs/AGENT_INSTALL.md:134` is literally titled
"do not pass secrets in argv". *Direction: pipe via stdin
(`printf '%s\n' "$ADMIN_PASS" | htpasswd -nBC 14 -i ""`), and fix the README
claim regardless.*

**4. Caddy ACME email is set to the domain** — `templates/Caddyfile:2`
`email __DOMAIN__` — only `__DOMAIN__` and `__SECRET_PATH__` tokens are
substituted (`scripts/70-caddyfile.sh:6-7`), so Caddy registers its ACME
account with `dns.example.com` as the contact address. Let's Encrypt expiry
notices and the intended `$EMAIL` never reach the operator. *Direction: add an
`__EMAIL__` token substitution.*

---

## HIGH

**5. Bootstrap tmpdir is never cleaned** — `install.sh:14-15, 63`
`trap 'rm -rf "$_tmpdir"' EXIT` is set, then
`exec bash "$_tmpdir/install.sh"` replaces the shell. Bash does **not** run EXIT
traps on `exec` — every one-liner run leaks `/tmp/adguard-deploy.XXXXXX`.
Cosmetic today (no secrets at that point), but it's dead cleanup code and it
accumulates. *Direction: `rm -rf` before `exec`, or
`bash ...; rc=$?; rm -rf; exit $rc`.*

**6. Bootstrap accepts arbitrary path traversal from the live tree API** —
`install.sh:41-60`
The file list comes from the GitHub tree API and is trusted verbatim:
`mkdir -p "$_tmpdir/$(dirname "$_f")"` + `curl ... -o "$_tmpdir/$_f"`. A
compromised or malicious tree entry named `../../../etc/cron.d/x` writes outside
the tmpdir, as root. It's a trust-the-repo model, but path sanitization is free
insurance for a repo whose users are specifically security-conscious and install
via `curl|bash`. *Direction: reject any `$_f` containing `..` or starting with
`/`; ideally pin a SHA256 of the manifest.*

**7. One-liner re-runs silently regenerate the secret path** —
`install.sh:10-15, 63` + `173-176`
The bootstrap always downloads into a *fresh* `mktemp -d`, and
`CONFIG_FILE="$REPO_DIR/deploy.env"` (`install.sh:102`) resolves to that
tmpdir. So on the documented primary install path (`curl | sudo bash`), a saved
`deploy.env` is never found, all four questions are re-asked, and
`random_secret_path` mints a **new admin path every re-run** — the previously
distributed Admin URL breaks. README.en.md's "Resume / re-run: every step is
idempotent" is only true for the git-clone path. *Direction: persist
`deploy.env` at a stable location (`/root/` or `/etc/adguard-deploy/`) in the
bootstrap path, or explicitly document that re-runs must use the clone path.*

**8. Certbot post-hook starts Caddy with the default Caddyfile mid-install** —
`scripts/40-cert.sh:18`
After issuance, the post-hook `systemctl start caddy || true` fires *before*
`70-caddyfile` writes the real vhost — Caddy comes up serving its stock
"Congratulations" default page on 80/443 for the remainder of the install. For a
tool whose entire premise is "scanners must only ever see the decoy," a default
Caddy landing page on the domain during (and after any renewal until the real
Caddyfile exists) is a real stealth leak. *Direction: post-hook should start
caddy only after first deploy — or gate it on the Caddyfile existing.*

**9. Uninstall leaves the admin password behind** — `scripts/90-uninstall.sh`
Teardown removes services, `/opt/AdGuardHome`, `/var/www/fake`,
`/etc/ssl/adguard` — but never touches `deploy.env` (mode 600, contains
`ADMIN_PASS=%q`), `/var/log/adguard-deploy.log`, the Caddy apt repo
(`/etc/apt/sources.list.d/caddy-stable.list` + keyring), or the
`DEFAULT_FORWARD_POLICY` edit from `20-firewall.sh:42`. Only the LE cert and
UFW are mentioned as "left behind" (`90-uninstall.sh:32-34`) — the password
file isn't mentioned at all. *Direction: at minimum warn loudly about
`deploy.env`; ideally remove or shred it on request.*

---

## MEDIUM

**10. All multi-line `die` messages render as literal `\n`** — pervasive
(`00-preflight.sh:21,41`, `40-cert.sh:23`, `50-adguard.sh:16,35,81`,
`70-caddyfile.sh:14`)
Inside double quotes, `\n` in bash is not a newline — `die "…\n  Fix: …"` prints
a literal backslash-n mid-sentence. The "symptom→fix" error quality claimed in
`README.en.md:86` is degraded everywhere it matters. *Direction: `$'…\n…'`
ANSI-C quoting or separate `err` calls.*

**11. `check()` in the verify stage is dead code, and the DoH check can never
pass** — `scripts/80-verify.sh:15-19, 34-36`
`check()` (which uses `eval` — itself a smell) is defined and never called; all
checks are hand-rolled. The DoH block computes `bad` and then only ever `warn`s
— a bare GET to `/dns-query` without a wire-format query returns an empty body,
so this "check" warns on every run and contributes nothing to PASS/FAIL, while
README.en.md:83 markets "N passed, 0 failed" as the success contract.
*Direction: either send a real RFC 8484 GET with a base64url `dns=` parameter
and assert a response, or drop the block.*

**12. Verify can't be re-run without `--force` after DNS settles** —
`80-verify.sh:66` vs `install.sh:242` + `80-verify.sh:70`
The failure advice says "run again once DNS/propagation settles," but
`mark_done 80-verify` runs unconditionally (and again from `install.sh:249`),
so a plain re-run **skips** verify. The user hits the exact scenario the message
anticipates and the tool won't re-check. *Direction: don't mark verify done when
`FAIL>0`.*

**13. `--config` prompt-persistence clobbers extra keys despite the comment** —
`install.sh:181-205`
The comment says "without clobbering an existing file's extra keys," but the
`! grep -q '^DOMAIN='` branch rewrites the whole file with only the 15 known
keys. Conversely, if the file *does* contain `DOMAIN=`, nothing is persisted —
interactive changes this run (e.g. a retyped `ADMIN_PASS`) are used now and
silently lost next run. *Direction: merge, don't rewrite; and persist on
change.*

**14. `gpg --dearmor` hangs/re-prompts on re-run after partial failure** —
`scripts/30-caddy.sh:7-8`
If the Caddy repo/keyring was added but `apt-get install caddy` failed, a
re-run hits `gpg --dearmor -o` on an existing file — gpg prompts to overwrite,
hanging the install (or failing non-interactively). The `have_cmd caddy` guard
doesn't cover this state. *Direction: `--batch --yes` or write to a temp path.*

**15. `DEFAULT_FORWARD_POLICY=ACCEPT` is speculative scope creep and may
silently no-op** — `scripts/20-firewall.sh:39-44`
The sed only matches an uncommented line (silently does nothing otherwise), and
flipping the host's global forward policy to ACCEPT "in case this routes a VPN"
widens the attack surface on a box that may not route anything. *Direction: make
it an opt-in config flag, and fail loudly if the sed doesn't match.*

**16. DoT cert verification is a substring match** — `80-verify.sh:56-57`
`grep -q "CN.*$DOMAIN"` on the subject line accepts
`CN = dns.example.com.attacker.tld` — anything containing the domain as a
substring passes. Modern LE certs also carry identity in SAN, which isn't
checked at all. *Direction: match `CN = $DOMAIN$` or check SANs via
`openssl x509 -checkhost`.*

**17. Verify has no curl timeouts** — `80-verify.sh:24,29,34`
All three external curls lack `--max-time`; a hung Caddy or a blackholed route
stalls the "smoke test" indefinitely under `set -e` context. *Direction: add
`--max-time 10 --connect-timeout 5`.*

**18. Patch script's own contract is violated internally; no schema guard** —
`templates/patch-adguard-config.py:72-75` and `40-41, 159-160`
The docstring promises "unset ones are left untouched," but
`http.doh.enabled`/`insecure_enabled` are **unconditionally** forced `True` on
every run — including on `--force` re-runs of an operator-customized config.
`insecure_enabled` (plain-HTTP DoH) is currently safe only because
`http.address` is pinned to localhost; any future change to that binding makes
plaintext DoH public. Also: the file is fully rewritten via `yaml.safe_dump`
with no `schema_version` precheck — if a future AdGuard renames
`tls.port_https` etc., the patch writes orphan keys and the docstring's "no
migration is triggered" claim quietly becomes false. *Direction: honor the
env-var contract for doh keys, and assert/validate `schema_version` before
writing.*

**19. Uninstall leaves a dangling systemd unit if AdGuard was partially
removed** — `scripts/90-uninstall.sh:18-21`
The `-s uninstall` call is gated on `[ -x /opt/AdGuardHome/AdGuardHome ]`; if
that binary is already gone, `/etc/systemd/system/AdGuardHome.service`
(installed by `50-adguard.sh:41`) is never removed. *Direction: `rm -f` the
unit + `daemon-reload` unconditionally.*

**20. First-run AdGuard wizard briefly public when `SKIP_FIREWALL=yes`** —
ordering dependency `20-firewall.sh` → `50-adguard.sh:13-14`
The official AGH installer starts the service, which on a virgin install binds
its setup wizard on `0.0.0.0:3000` unauthenticated until `50-adguard.sh:22`
stops it. Normally step 20 has already firewalled 3000 — the step ordering
silently saves the design. With `SKIP_FIREWALL=yes` (a documented option), the
wizard is internet-reachable during that window. *Direction: document the
hazard on the `SKIP_FIREWALL` knob, or pre-bind/stop before the installer
runs.*

**21. Default decoy content is third-party-controlled** — `install.sh:148`
`DECOY_URL` defaults to a raw URL in someone else's repo
(`Liafanx/MTProxyL`). That party can change what your "stealth" server serves
to every scanner at any time. The vendored fallback (`assets/index.html`)
exists and is good — but it's only used when the download *fails*, not when the
content *changes*. *Direction: default to the vendored copy; treat remote fetch
as the opt-in.*

**22. Step-name drift in the Russian README** — `README.md:44-54`
The RU table lists steps `1-preflight … 9-verify`; actual step IDs are
`00-preflight … 90-verify`. Anyone following the RU doc to use
`--only 3-firewall` gets silent confusion (the loop just matches nothing and
runs *all* steps — see LOW #28). The EN table is correct.

---

## LOW / NIT

**23.** `00-preflight.sh:4` — `require_cmd openssl || true` is dead protection:
`require_cmd` → `die` → `exit 1` terminates the shell; `|| true` never runs.
Either require it for real (it *is* needed by `random_secret_path`,
`lib.sh:144`) or drop the `|| true`.

**24.** `00-preflight.sh:25` — `ok "OS check uses $(command -v getent) for
DNS."` is a leftover nonsense log line.

**25.** `install.sh:82` — `set -Eeuo pipefail` declared twice (lines 2 and 82);
`SCRIPT_DIR`/`REPO_DIR` also computed twice (66-67 vs 84-85).

**26.** `install.sh:166` — "No interactive terminal detected **after preflight**"
fires *before* any step runs.

**27.** `lib.sh:60` — `toml_escape` is a sed-replacement escape, not
TOML-related; also `SECRET_PATH` in `70-caddyfile.sh:7` is substituted
**without** escaping — safe today only because the installer generates hex
paths; a user-supplied `SECRET_PATH` containing `|` corrupts the Caddyfile via
sed injection.

**28.** `install.sh:241` — `--only <typo>` matches no steps; the loop runs
**all** steps instead of erroring. Validate `$ONLY` against `$STEPS` up front.

**29.** `templates/AdGuardHome.service` — runs as root with zero hardening. No
`User=`, `NoNewPrivileges=`, `ProtectSystem=`, `PrivateTmp=`. AGH supports
dropping to a dedicated user with `CAP_NET_BIND_SERVICE` for :853.

**30.** `openssl rand -hex 8` (64-bit) for the secret path (`lib.sh:144`) is
fine, but given "the secret path is the *entire* obscurity layer"
(README.en.md:132), `-hex 16` costs nothing.

**31.** `80-verify.sh:44` — the `:853` listener check matches `127.0.0.1:853`
too; it doesn't actually verify DoT is *public*.

**32.** `10-base.sh:25-31` — changing the host timezone is an unexpected side
effect for a DNS deployer; harmless but worth a config guard.

**33.** Caddy repo key and AdGuard installer are fetched over plain HTTPS with
no pinning (`30-caddy.sh:7`, `50-adguard.sh:13`) — standard curl|bash posture,
but for this audience, `--proto '=https'` + checksum pinning is cheap.

**34.** `lib.sh:135-141` — `i` in the `wait_service_active` loop is an unused
var (shellcheck SC2034 noise).

---

## What's done well (genuinely)

- **Idempotency markers + flock** (`lib.sh:122-125`, `install.sh:216-217`) —
  clean, simple, correct resumability for the clone path.
- **Config collection separated from execution**, env precedence
  (defaults ← file ← env ← prompt) implemented correctly, `printf %q` when
  persisting (`install.sh:187-201`) — the file is always safely re-sourceable.
- **The YAML patch approach** (`patch-adguard-config.py`) is the right call vs
  sed-ing AdGuard's config — it preserves schema_version and only touches named
  keys.
- **`AdGuardHome` bound to `127.0.0.1:3000` with an explicit post-start listener
  assertion** (`50-adguard.sh:86-90`) — defense in depth on the one binding
  that would deanonymize the whole design.
- **The deploy-hook cert sync** (`adguard-shared-cert.sh`) correctly handles the
  caddy-group permission split and reloads both consumers — the trickiest part
  of shared-cert setups, done right.
- **Firewall-before-AdGuard step ordering** prevents the first-run wizard
  exposure in the default configuration (see #20 for the exception).
- **`/dev/tty` prompting** with the non-tty refusal (`install.sh:165-168`) is
  the correct pattern for sudo/CI contexts.
- **Uninstall is honest about what it won't reverse** (UFW, LE certs) — just
  incomplete on the password file (#9).

---

## Top 5 priorities

1. **#1** — fix `--help` (trivial, and it's the first impression for cautious
   operators).
2. **#3** — get `ADMIN_PASS` out of argv and reconcile the false "never in
   argv" README/AGENT doc claim.
3. **#4 + #8** — Caddy ACME email uses the domain instead of `$EMAIL`; certbot
   post-hook serves the default Caddy page on the stealth domain mid-install.
4. **#7** — one-liner re-runs regenerate `SECRET_PATH`, silently breaking the
   distributed Admin URL and contradicting the idempotency claim.
5. **#2 + #6** — harden the two `curl`-as-root paths (`-f`/pinning on the
   AdGuard installer; path-traversal guard in the bootstrap manifest loop).

Overall: the architecture and the security *design* are solid — the gaps are
concentrated in the bootstrap/re-run lifecycle, two silent credential/correctness
bugs, and error-path polish.
