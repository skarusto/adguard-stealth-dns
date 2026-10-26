# Installation errors, warnings and recovery

Based on a fresh Ubuntu 22.04 deployment with AdGuard Home v0.107.79, plus regression
coverage in `tests/`. Examples use placeholders, not deployment credentials.

## Recovery rules

Keep the existing private `deploy.env`, secret path, password and valid certificates.
After fixing the underlying cause, run `bash ./install.sh --yes` from the same checkout.
Only successfully completed steps are skipped. `--only <step>` reruns an explicit step
without `--force`. Verification failure is fatal and leaves verification unmarked.
Never disable signature/TLS validation or delete state to get past an error.

Read the **actual error**, not just the generic final step-failed message or Certbot's
generic HTTP-01 hint. Installation can be partial: no 443/853 listener before AdGuard
and Caddy configuration is expected. Do not declare completion at that point.

## `git: command not found`

Fresh VPS images may lack Git and rsync. Use the HTTPS tar archive workflow in
[AGENT_INSTALL.md §3](AGENT_INSTALL.md#3-obtain-the-code-git-is-optional), or install Git
with approval. Extract into a persistent private directory; never overwrite a resume
checkout/config. Record the commit/archive hash for provenance, not as an invented
independent authenticity check.

## `30-caddy`: `NO_PUBKEY`, GPG error, repository “not signed”

The correct key can still look missing when `_apt` cannot read it. A restrictive
`umask 077` must not create public APT metadata as mode 600. The installer explicitly
makes these files mode 644 before updating APT:

```bash
chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
          /etc/apt/sources.list.d/caddy-stable.list
runuser -u _apt -- test -r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
```

Inspect parent-directory traversal permissions too. If the files are readable and the
error remains, check the official [Caddy installation instructions](https://caddyserver.com/docs/install)
and key/source configuration. **Do not use `trusted=yes`, `--allow-unauthenticated`, or
disable signature checking.** Resume normally after repair.

## `40-cert`: `Unable to find post-hook command if in the PATH`

`if` is a shell keyword, not an executable. Certbot validates the first hook word.
Conditional hooks must start with an executable, e.g. `/bin/sh -c 'if ...; then ...; fi'`.
The installer uses this form and repairs saved renewal hook settings on an explicit
certificate-step rerun without deleting a valid cert. Recheck the saved renewal config
for a previous broken post-hook; simply changing a one-off issuance command is not
enough. Do not print unrelated account/private-key material while inspecting it.

The post-hook must not bring up Caddy's packaged default website during a failed first
installation; restart it only when deployment configuration and shared certificates exist.

## `40-cert`: parent CAA `SERVFAIL` despite a correct A record

Successful HTTP-01 fetches **do not** prove certificate issuance can succeed. CAA
authorization is a separate DNS requirement. A parent domain may have lame delegation,
authorities returning `REFUSED`, DNSSEC faults, or no reachable authority.

Inspect `/var/log/letsencrypt/letsencrypt.log` privately. With `dnsutils` available,
compare independent resolvers for the exact child **and each relevant parent**:

```bash
dig @8.8.8.8 CAA dns.example.com
dig @1.1.1.1 CAA dns.example.com
dig @8.8.8.8 CAA example.com
dig @1.1.1.1 NS example.com
```

`NOERROR` with no CAA records is not the same as `SERVFAIL`. If HTTP challenge requests
received 200 and the actual ACME error is CAA/SERVFAIL, opening more ports won't fix it.
Ask the DNS operator to repair the delegation/DNSSEC issue or, where appropriate and
supported by the provider, add a child-name authorization:

```text
dns.example.com.  CAA 0 issue "letsencrypt.org"
```

An explicit child CAA record resolved the recorded parent-lookup failure. It is **not
a universal bypass**: the child record itself must resolve reliably and CNAME/DNSSEC
rules still apply. Recheck public resolution/TTL; otherwise use a working domain with
approval. Do not repeatedly retry issuance into Let's Encrypt rate limits. Resume
without `--force`, password regeneration, certificate deletion, or account recreation.

For a real HTTP-01 connection failure, check TCP 80 at both host and provider layers,
A/AAAA records and port ownership. Curling HTTPS on a partially installed server does
not diagnose an HTTP-01 failure.

## `50-adguard`: first-run setup and missing YAML

AdGuard Home v0.107.79 waits for setup; it does not automatically write a configured
`AdGuardHome.yaml`. The repository installer avoids the upstream `scripts/install.sh`
because it auto-starts the default wizard. Instead, it downloads the official release
archive, creates `/opt/AdGuardHome` mode 700, starts the binary with its web listener
on loopback at an ephemeral port, and completes `/control/install/configure` locally
using the existing credentials. Setup uses a different temporary web port and high,
non-privileged loopback DNS port numbers; the AdGuard process still must run as root
during initialization. Do not run the bootstrap as an unprivileged user. The tracked bootstrap process is stopped before the
generated configuration is patched. It preserves the binary's actual `schema_version`;
an existing config bypasses initialization.

Startup output and safe API diagnostics are written to the private
`/opt/AdGuardHome/initialize.log` (mode 600). The helper accepts `--binary`, `--config`,
`--work-dir`, and optional `--log-file`; credentials are supplied through
`ADG_INIT_USERNAME`/`ADG_INIT_PASSWORD`, not command arguments. It stops the child process
on success, failure, and termination signals. Check the log privately and redact paths
or other sensitive details before sharing excerpts.

After initialization, config patching uses an atomic replacement and stores a root-only
backup beside the YAML as `/opt/AdGuardHome/AdGuardHome.yaml.bak.<timestamp>`. Do not
expect installer-generated backups under `/root`.

The wizard's existing port and requested web port must differ: configuring
`127.0.0.1:3000` while the temporary setup listener still occupies 3000 can return
HTTP 400 “address already in use”. A distinct temporary loopback web port avoids that
collision; the final backend is restored to `127.0.0.1:3000`. Check first-run diagnostics
privately if setup fails; don't echo request JSON/passwords, expose setup listeners
publicly, or rerun setup on an already configured instance. Never use
`AdGuardHome --check-config` as a readiness test.

`permcheck ... /opt/AdGuardHome perm=0755 want=0700` is actionable: the application
directory should be root-owned 700 and YAML/first-run logs 600. Keep permissions strict;
don't make the whole tree world-readable to fix unrelated Caddy APT permissions.

The private initialization log can contain this upstream message when the freshly
initialized process is stopped before it has handled any DNS requests:

```text
[error] closing query log: flushing log buffer: nothing to write to a file
```

Treat **only this exact shutdown message** as benign when the helper exited successfully,
the generated config exists, and final service plus DoH/DoT checks pass. Other query-log
errors, helper failures, missing config, or failed runtime checks still need investigation.

## Verification: DoT is loopback-only / misleading certificate mismatch

`dns.bind_hosts` also controls DoT. A wizard initialized with loopback DNS can leave
853 unreachable from clients even when the certificate is correct. Final configuration
must include public DNS bind hosts (the installer uses `0.0.0.0` for IPv4), while keeping:

```yaml
http:
  address: 127.0.0.1:3000
dns:
  bind_hosts: [0.0.0.0]
  serve_plain_dns: false
tls:
  port_https: 0
  port_dns_over_tls: 853
  port_dns_over_quic: 0
```

Do **not** replace a complete YAML with this fragment. Stop AdGuard before editing,
take a private backup, preserve schema/users, restart and inspect `ss -tlnp`. Keep
public plain DNS 53 disabled and admin 3000 localhost-only. Resolve listener/firewall
failures before diagnosing certificate contents. Validate TLS chain **and hostname**
and run real external DoH/DoT DNS queries. An HTTP 200 alone isn't a DNS answer.

## Secret path falls through to decoy / redirects to literal `302`

Use explicit matcher syntax in Caddy:

```caddyfile
redir * /YOUR_SECRET/login.html 302
```

Without `*`, a path argument can be parsed as the matcher and `302` as the target.
Both the bare secret path and its trailing-slash variant must redirect to the same
prefixed login page. `/login.html` under that prefix must proxy normally, not redirect
back to itself. Verify the status **and exact Location**, then HTTP 200 and
`<title>Login</title>` (case-insensitive). Validate and
inspect Caddy's adapted JSON when routing is ambiguous; treat generated configs as
private because they contain the secret path. `--only 70-caddyfile` regenerates from
the template, so change the template/config inputs rather than relying on an edit
that a rerun will overwrite.

## UFW rules active but `ufw.service` inactive

`ufw --force enable` loads rules; `systemctl enable --now ufw` also enables and starts
the service immediately. Verify both views, without clearing any rules:

```bash
ufw status verbose
systemctl is-active ufw
systemctl is-enabled ufw
```

Preserve the real SSH port and authorized extras before activation. For SSH loss,
use the provider console; don't respond by resetting/disabling the firewall remotely.
If `SKIP_FIREWALL=yes`, verify the equivalent provider/host policy explicitly instead.

## Expected notices vs failures

| Notice | Meaning / action |
|---|---|
| `debconf: delaying package configuration, since apt-utils is not installed` | Normally harmless on minimal images when apt exits 0 and configuration completes; installing apt-utils solely to silence it is unnecessary. |
| UFW “Any service NOT in that list…” | Real safety warning: confirm SSH and every required app/VPN allowance before continuing. |
| UFW “be sure to update your rules accordingly” | Expected when defaults change; verify explicit allow rules exist before activation. |
| GPG creates `/root/.gnupg` / keybox during inspection | Informational. Historical expired subkeys don't prove the current signing key is invalid; verify the actual active key and APT outcome. Never suppress genuine signature failures. |
| Caddy certificate-management / HTTP redirect messages with “valid configuration” | Usually informational for manual certificates; still check validation exit status and service health. |
| Certificate/account created but later ACME authorization fails | Partial deployment, not success. Preserve account/config and fix the actual reported ACME error. |

## Windows credential export / ACL error 1332

Localized Windows group names may not map. For `icacls`, use numeric SIDs with the `*`
prefix (notation: `*S-1-...`) instead of localized names. Prepare a private destination
using verified account SIDs and inheritance settings **before** writing credentials. If ACL setup fails
or the operator declines diagnostics, stop the export; do not create an unprotected
fallback. Verify whether a destination file is empty without displaying secrets. Report
that export did not complete; credentials remain in the root-only VPS `deploy.env`.

## Regression checks (no VPS changes)

Run from the repository with Python 3 + PyYAML installed:

```bash
python3 -m unittest discover -s tests -v
for script in install.sh scripts/*.sh templates/adguard-shared-cert.sh; do bash -n "$script" || exit; done
git diff --check
```

Tests use temporary fixtures and mocked package/service commands, not a live deployment.
They cannot establish provider firewall reachability, real ACME issuance/renewal, or DNS
provider correctness. Always run the external acceptance checks after installing.

For the optional real-Caddy routing regression, set `CADDY_BIN=/path/to/caddy` when
running the suite. It uses only loopback high ports and temporary files, with no TLS
issuance or service installation. Without that variable this one test is explicitly skipped.
