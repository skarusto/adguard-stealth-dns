# 80-verify.sh — end-to-end smoke checks (does NOT touch the system).

DOMAIN_IP_OK=no
if command -v getent >/dev/null 2>&1; then
  _public_ip="$(detect_public_ip 2>/dev/null || true)"
  if [ -n "$_public_ip" ] && getent ahostsv4 "$DOMAIN" 2>/dev/null \
      | awk '{print $1}' | grep -qxF "$_public_ip"; then
    DOMAIN_IP_OK=yes
  fi
fi
[ "$DOMAIN_IP_OK" = yes ] || warn "Domain does not yet resolve to this server's public IP (maybe still propagating)."

PASS=0; FAIL=0
echo
log "Running verification smoke tests..."

_record_pass() { ok "  PASS : $1"; PASS=$((PASS+1)); }
_record_fail() { warn " FAIL : $1"; FAIL=$((FAIL+1)); }

# Decoy front page.
_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 "https://$DOMAIN/" 2>/dev/null)" || _code=000
[ "$_code" = 200 ] && _record_pass "/ returns decoy (200)" || _record_fail "/ (expected 200)"

# Both forms of the private path redirect to the exact prefixed login URL.
for _path in "$SECRET_PATH" "$SECRET_PATH/"; do
  _redirect="$(curl -sS -o /dev/null -w '%{http_code}\t%{redirect_url}' --max-redirs 0 \
    --max-time 10 --connect-timeout 5 "https://$DOMAIN$_path" 2>/dev/null)" || _redirect=
  _code="${_redirect%%$'\t'*}"; _location="${_redirect#*$'\t'}"
  if [ "$_code" = 302 ] && [ "$_location" = "https://$DOMAIN$SECRET_PATH/login.html" ]; then
    _record_pass "secret path form redirects to prefixed login page (302)"
  else
    _record_fail "secret path form expected 302 to prefixed login page"
  fi
done

# Login page should be served, not redirected back into a loop.
_login_file="$(mktemp)" || _login_file=
if [ -n "$_login_file" ] && _login_code="$(curl -sS -o "$_login_file" -w '%{http_code}' --max-redirs 0 \
    --max-time 10 --connect-timeout 5 "https://$DOMAIN$SECRET_PATH/login.html" 2>/dev/null)" \
    && [ "$_login_code" = 200 ] \
    && grep -Eqi '<title>[[:space:]]*Login([[:space:]]+page)?[[:space:]]*</title>' "$_login_file"; then
  _record_pass "prefixed login page serves Login page (200, no redirect)"
else
  _record_fail "prefixed login page expected Login page (200, no redirect)"
fi
[ -z "$_login_file" ] || rm -f -- "$_login_file"

# Issue an RFC 8484 GET and validate the response as a successful DNS answer.
_doh_b64="$( { printf '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00';
  printf '\x07example\x03com\x00'; printf '\x00\x01\x00\x01'; } \
  | base64 | tr '+/' '-_' | tr -d '=\n')"
_doh_file="$(mktemp)" || _doh_file=
_doh_code=000
if [ -n "$_doh_file" ]; then
  _doh_code="$(curl -sS -o "$_doh_file" -w '%{http_code}' --max-time 10 --connect-timeout 5 \
    "https://$DOMAIN/dns-query?dns=$_doh_b64" 2>/dev/null)" || _doh_code=000
fi
if [ "$_doh_code" = 200 ] && [ -s "$_doh_file" ] && python3 - "$_doh_file" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()

def u16(pos):
    if pos < 0 or pos + 2 > len(data):
        raise ValueError("truncated integer")
    return int.from_bytes(data[pos:pos + 2], "big")

def read_name(pos):
    """Read a DNS name, resolving bounded compression pointers safely."""
    labels = []
    cursor = pos
    resume = None
    seen = set()
    wire_length = 1
    while True:
        if cursor >= len(data):
            raise ValueError("truncated name")
        length = data[cursor]
        if length & 0xc0 == 0xc0:
            if cursor + 1 >= len(data):
                raise ValueError("truncated compression pointer")
            target = ((length & 0x3f) << 8) | data[cursor + 1]
            if target >= len(data) or target in seen:
                raise ValueError("invalid compression pointer")
            seen.add(target)
            if resume is None:
                resume = cursor + 2
            cursor = target
            continue
        if length & 0xc0:
            raise ValueError("reserved label encoding")
        cursor += 1
        if length == 0:
            return b".".join(labels).lower(), (resume if resume is not None else cursor)
        if length > 63 or cursor + length > len(data):
            raise ValueError("invalid/truncated label")
        wire_length += length + 1
        if wire_length > 255:
            raise ValueError("oversized name")
        labels.append(data[cursor:cursor + length])
        cursor += length

try:
    if len(data) < 12 or data[0:2] != b"\x00\x00":
        raise ValueError("short header or nonmatching ID")
    flags = u16(2)
    qd, an = u16(4), u16(6)
    if not flags & 0x8000 or flags & 0x7800 or flags & 0x0200 or flags & 0x000f:
        raise ValueError("not a successful standard response")
    if qd != 1 or an < 1:
        raise ValueError("unexpected question/answer count")
    name, pos = read_name(12)
    if name != b"example.com" or u16(pos) != 1 or u16(pos + 2) != 1:
        raise ValueError("question does not match example.com A IN")
    pos += 4
    has_address = False
    for _ in range(an):
        _owner, pos = read_name(pos)
        if pos + 10 > len(data):
            raise ValueError("truncated answer record")
        rrtype, rrclass = u16(pos), u16(pos + 2)
        rdlength = u16(pos + 8)
        pos += 10
        if pos + rdlength > len(data):
            raise ValueError("truncated answer data")
        if rrtype == 1 and rrclass == 1 and rdlength == 4:
            has_address = True
        pos += rdlength
    if not has_address:
        raise ValueError("no A address answer")
except (ValueError, IndexError):
    sys.exit(1)
sys.exit(0)
PY
then
  _record_pass "DoH returned a valid DNS answer"
else
  _record_fail "DoH response was not a valid successful DNS answer"
fi
[ -z "$_doh_file" ] || rm -f -- "$_doh_file"

# Admin backend must have listeners, and every one must be loopback. Do not
# accidentally pass a mixed loopback + public binding set.
_l3000="$(ss -tlnH 2>/dev/null | awk '$4 ~ /:3000$/ {print $4}')" || _l3000=
if [ -z "$_l3000" ]; then
  _record_fail "nothing listening on :3000"
elif printf '%s\n' "$_l3000" | grep -qvE '^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|::1):3000$'; then
  _record_fail "an AdGuard :3000 listener is exposed beyond loopback"
else
  _record_pass "AdGuard admin/DoH bound to loopback only (:3000)"
fi

# DoT needs at least one non-loopback binding; localhost must not mask it.
_l853="$(ss -tlnH 2>/dev/null | awk '$4 ~ /:853$/ {print $4}')" || _l853=
if [ -z "$_l853" ]; then
  _record_fail "no DoT listener on :853"
elif printf '%s\n' "$_l853" | grep -qE '^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|::1):853$' \
    && ! printf '%s\n' "$_l853" | grep -qvE '^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|::1):853$'; then
  _record_fail "DoT :853 is loopback-only (clients cannot reach it)"
else
  _record_pass "DoT listener on :853 (public)"
fi

# Parse configuration structure rather than matching keys in arbitrary sections.
_cfg="${AG_CFG:-/opt/AdGuardHome/AdGuardHome.yaml}"
if [ -r "$_cfg" ] && python3 - "$_cfg" <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
valid = (isinstance(config, dict)
         and isinstance(config.get("dns"), dict)
         and config["dns"].get("serve_plain_dns") is False
         and isinstance(config.get("http"), dict)
         and config["http"].get("address") == "127.0.0.1:3000")
sys.exit(0 if valid else 1)
PY
then
  _record_pass "plain DNS disabled and AdGuard HTTP bound to 127.0.0.1:3000"
else
  _record_fail "AdGuard config must disable plain DNS and bind HTTP to 127.0.0.1:3000"
fi

if systemctl is-active --quiet AdGuardHome && systemctl is-active --quiet caddy; then
  _record_pass "AdGuardHome + Caddy active"
else
  _record_fail "a core service is not active"
fi
if [ "${SKIP_FIREWALL:-no}" = yes ]; then
  log "SKIP_FIREWALL=yes: skipping UFW active-state check."
elif systemctl is-enabled --quiet ufw \
    && systemctl is-active --quiet ufw \
    && _ufw_status="$(ufw status 2>/dev/null)" \
    && printf '%s\n' "$_ufw_status" | grep -qE '^Status:[[:space:]]+active$'; then
  _record_pass "UFW is enabled and reports active"
else
  _record_fail "UFW must be enabled and report active"
fi
if systemctl is-enabled --quiet certbot.timer && systemctl is-active --quiet certbot.timer; then
  _record_pass "Certbot renewal timer enabled and active"
else
  _record_fail "Certbot renewal timer is not enabled and active"
fi

# Verify both hostname and chain using OpenSSL's verifier, bounded in time.
# Capture output even on failure: openssl may return nonzero for a bad cert,
# while a failed socket can produce no certificate at all.
if _dot_tls="$(timeout 15 openssl s_client -brief -verify_return_error -verify_hostname "$DOMAIN" \
    -connect "$DOMAIN:853" -servername "$DOMAIN" </dev/null 2>&1)"; then
  _dot_tls_status=0
else
  _dot_tls_status=$?
fi
if [ "$_dot_tls_status" -eq 0 ] && printf '%s\n' "$_dot_tls" | grep -q 'Verification: OK'; then
  _record_pass "DoT certificate chain trusted and hostname verified"
elif printf '%s\n' "$_dot_tls" | grep -qiE 'hostname mismatch|verify error:num=62|does not match'; then
  _record_fail "DoT certificate hostname mismatch for $DOMAIN"
elif [ "$_dot_tls_status" -eq 124 ] || [ -z "$_dot_tls" ] \
    || printf '%s\n' "$_dot_tls" | grep -qiE 'no peer certificate|connection refused|connect:errno|unable to connect|network is unreachable|timed out'; then
  _record_fail "no DoT TLS connection/certificate received on $DOMAIN:853"
else
  _record_fail "DoT certificate chain/hostname verification failed"
fi
unset _dot_tls _dot_tls_status

echo
log "Smoke tests: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
  rm -f "$STATE_DIR/done.80-verify" 2>/dev/null || true
  warn "One or more checks failed. Review the warnings above and run again once DNS/propagation settles."
  warn "Step left unmarked so it re-runs; retry with --only 80-verify."
else
  ok "All smoke checks passed."
  mark_done 80-verify 2>/dev/null || true
fi
[ "$FAIL" -eq 0 ]
