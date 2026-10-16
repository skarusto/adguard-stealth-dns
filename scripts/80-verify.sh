# 80-verify.sh — end-to-end smoke checks (does NOT touch the system).

DOMAIN_IP_OK=no
if command -v getent >/dev/null 2>&1; then
  _public_ip="$(detect_public_ip 2>/dev/null || true)"
  if [ -n "$_public_ip" ] \
     && getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -qxF "$_public_ip"; then
    DOMAIN_IP_OK=yes
  fi
fi

if [ "$DOMAIN_IP_OK" = "no" ]; then
  warn "Domain does not yet resolve to this server's public IP (maybe still propagating)."
fi

PASS=0; FAIL=0

echo
log "Running verification smoke tests..."

# root returns the decoy page
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 "https://$DOMAIN/")" = "200" ] \
  && { ok "  PASS : / returns decoy (200)"; PASS=$((PASS+1)); } \
  || { warn " FAIL : / (expected 200)"; FAIL=$((FAIL+1)); }

# secret path issues a redirect
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 "https://$DOMAIN$SECRET_PATH/")" = "302" ] \
  && { ok "  PASS : secret path redirects (302)"; PASS=$((PASS+1)); } \
  || { warn " FAIL : secret path (expected 302)"; FAIL=$((FAIL+1)); }

# DoH answers a real wire-format query (RFC 8484 GET, base64url of a DNS packet).
_doh_b64="$(
  {
    printf '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'
    printf '\x07example\x03com\x00'
    printf '\x00\x01\x00\x01'
  } | base64 | tr '+/' '-_' | tr -d '=\n'
)"
_doh_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 \
  "https://$DOMAIN/dns-query?dns=$_doh_b64" 2>/dev/null || echo 000)"
if [ "$_doh_code" = "200" ]; then
  ok "  PASS : DoH answers a DNS query (200)"; PASS=$((PASS+1))
else
  warn " FAIL : DoH query returned HTTP ${_doh_code:-none} (expected 200)"; FAIL=$((FAIL+1))
fi

# AdGuard admin/DoH must NOT be reachable beyond loopback.
_l3000="$(ss -tlnH 2>/dev/null | awk '$4 ~ /:3000$/ {print $4}')"
if [ -z "$_l3000" ]; then
  warn " FAIL : nothing listening on :3000"; FAIL=$((FAIL+1))
elif printf '%s\n' "$_l3000" | grep -qvE '^(127\.0\.0\.1|\[::1\]):3000$'; then
  warn " FAIL : :3000 exposed beyond loopback: $(printf '%s ' "$_l3000")"; FAIL=$((FAIL+1))
else
  ok "  PASS : AdGuard admin/DoH bound to loopback only (:3000)"; PASS=$((PASS+1))
fi

# DoT must be publicly reachable (not loopback-only).
_l853="$(ss -tlnH 2>/dev/null | awk '$4 ~ /:853$/ {print $4}')"
if [ -z "$_l853" ]; then
  warn " FAIL : no DoT listener on :853"; FAIL=$((FAIL+1))
elif printf '%s\n' "$_l853" | grep -qvE '^(127\.0\.0\.1|\[::1\]):853$'; then
  ok "  PASS : DoT listener on :853 (public)"; PASS=$((PASS+1))
else
  warn " FAIL : DoT :853 is loopback-only (clients cannot reach it)"; FAIL=$((FAIL+1))
fi

if systemctl is-active --quiet AdGuardHome && systemctl is-active --quiet caddy; then
  ok "  PASS : AdGuardHome + Caddy active"; PASS=$((PASS+1))
else
  warn " FAIL : a core service is not active"; FAIL=$((FAIL+1))
fi

# DoT certificate sanity: the cert must cover this exact host (CN or SAN).
_cert="$(echo | timeout 10 openssl s_client -connect "$DOMAIN:853" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -text 2>/dev/null || true)"
_domain_re="${DOMAIN//./\\.}"
if printf '%s\n' "$_cert" | grep -qE "DNS:${_domain_re}([,[:space:]]|$)"; then
  ok "  PASS : DoT certificate covers $DOMAIN"; PASS=$((PASS+1))
else
  warn " FAIL : DoT certificate does not match $DOMAIN (may resolve after DNS propagation)"; FAIL=$((FAIL+1))
fi

echo
log "Smoke tests: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
  # Do NOT record this step as done, and clear any stale success marker from an
  # earlier run so a re-run actually retries the checks.
  rm -f "$STATE_DIR/done.80-verify" 2>/dev/null || true
  warn "One or more checks failed. Review the warnings above and run again once DNS/propagation settles."
  warn "Step left unmarked so it re-runs; retry with --only 80-verify."
else
  ok "All smoke checks passed."
  mark_done 80-verify 2>/dev/null || true
fi
[ "${FAIL:-0}" -eq 0 ]
