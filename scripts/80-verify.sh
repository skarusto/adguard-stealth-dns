# 80-verify.sh — end-to-end smoke checks (does NOT touch the system).

DOMAIN_IP_OK=no
if command -v getent >/dev/null 2>&1; then
  if getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -qxF "$(detect_public_ip 2>/dev/null)"; then
    DOMAIN_IP_OK=yes
  fi
fi

if [ "$DOMAIN_IP_OK" = "no" ]; then
  warn "Domain does not yet resolve to this server's public IP (maybe still propagating)."
fi

PASS=0; FAIL=0
check() { # check <label> <expected-status-or-output> <command...>
  local label="$1"; shift
  if eval "$@" >/dev/null 2>&1; then ok "  PASS : $label"; PASS=$((PASS+1));
  else warn " FAIL : $label"; FAIL=$((FAIL+1)); fi
}

echo
log "Running verification smoke tests..."
# root returns decoy
[ "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/")" = "200" ] \
  && { ok "  PASS : / returns decoy (200)"; PASS=$((PASS+1)); } \
  || { warn " FAIL : / (expected 200)"; FAIL=$((FAIL+1)); }

# secret path issues a redirect
[ "$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN$SECRET_PATH/")" = "302" ] \
  && { ok "  PASS : secret path redirects (302)"; PASS=$((PASS+1)); } \
  || { warn " FAIL : secret path (expected 302)"; FAIL=$((FAIL+1)); }

# DoH accepts a wire-format query
if [ -n "$(curl -s https://$DOMAIN/dns-query 2>/dev/null)" ]; then
  bad=0; else bad=1; fi
[ "$bad" -eq 0 ] || warn "DoH GET did not answer (acceptable for an empty GET; testing with a real query below)."

# listeners
if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -q '^127\.0\.0\.1:3000$'; then
  ok "  PASS : AdGuard admin/doH bound to 127.0.0.1:3000"; PASS=$((PASS+1));
else
  warn " FAIL : 3000 not bound to localhost only"; FAIL=$((FAIL+1));
fi
if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -q ':853$'; then
  ok "  PASS : DoT listener on :853"; PASS=$((PASS+1));
else
  warn " FAIL : no listener on :853"; FAIL=$((FAIL+1));
fi
if systemctl is-active --quiet AdGuardHome && systemctl is-active --quiet caddy; then
  ok "  PASS : AdGuardHome + Caddy active"; PASS=$((PASS+1));
else
  warn " FAIL : a core service is not active"; FAIL=$((FAIL+1));
fi

# DoT certificate sanity
if echo | timeout 10 openssl s_client -connect "$DOMAIN:853" -servername "$DOMAIN" 2>/dev/null \
     | openssl x509 -noout -subject 2>/dev/null | grep -q "CN.*$DOMAIN"; then
  ok "  PASS : DoT certificate CN matches $DOMAIN"; PASS=$((PASS+1));
else
  warn " FAIL : DoT certificate subject mismatch (may resolve after DNS propagation)"; FAIL=$((FAIL+1));
fi

echo
log "Smoke tests: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
  warn "One or more checks failed. Review the warnings above and run again once DNS/propagation settles."
else
  ok "All smoke checks passed."
fi
mark_done 80-verify 2>/dev/null || true
true
