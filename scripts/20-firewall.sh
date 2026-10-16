# 20-firewall.sh — restrictive UFW: allow SSH + 80 + 443 + 853 (+ user extras).

if [ "${SKIP_FIREWALL:-no}" = "yes" ]; then
  warn "SKIP_FIREWALL=yes — leaving the firewall untouched."
  return 0 2>/dev/null || true
fi

require_cmd ufw || { err "ufw not found; install with: apt-get install -y ufw"; die "ufw package missing"; }

log "Currently listening sockets (for your reference):"
ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/' | sed 's/^/    /' >&2 || true
ss -ulnp 2>/dev/null | awk 'NR==1 || /UNCONN/' | sed 's/^/    /' >&2 || true

log "This step will ALLOW: ${SSH_PORT}/tcp 80/tcp 443/tcp 853/tcp ${EXTRA_ALLOW:-}"
warn "Any service NOT in that list will become unreachable once UFW is enabled."
if [ "$ASSUME_YES" != "yes" ]; then
  ask FW_ACK "Enable UFW with these rules now? (yes/no)" "yes"
  [ "$FW_ACK" = "yes" ] || { warn "Skipping firewall by user request."; return 0 2>/dev/null || true; }
fi

ufw default deny incoming || die "Failed to set default deny (ufw internal error). Ensure ufw is installed."
ufw default allow outgoing || die "Failed to set default allow outgoing."

# SSH first — never lock yourself out.
ufw allow "${SSH_PORT}/tcp" comment 'SSH'

ufw allow 80/tcp  comment 'ACME HTTP-01 + HTTP->HTTPS redirect'
ufw allow 443/tcp comment 'DoH + admin + decoy (TLS)'
ufw allow 853/tcp comment 'DoT'

# Extra allowances, space-separated, e.g. "51820/udp 64672/udp 58472/tcp"
if [ -n "${EXTRA_ALLOW:-}" ]; then
  for spec in $EXTRA_ALLOW; do
    ufw allow "$spec" && ok "Allowed extra: $spec"
  done
fi

# VPN forwarding is OPT-IN (default: no). Only touch /etc/default/ufw when the
# operator explicitly sets VPN_FORWARDING=yes.
if [ "${VPN_FORWARDING:-no}" = "yes" ]; then
  if [ ! -f /etc/default/ufw ]; then
    die "VPN_FORWARDING=yes but /etc/default/ufw is missing; cannot enable forwarding."
  fi
  if grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
    ok "DEFAULT_FORWARD_POLICY is already ACCEPT."
  else
    warn "VPN_FORWARDING=yes — setting DEFAULT_FORWARD_POLICY=ACCEPT (needed to route VPN traffic)."
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    if ! grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
      die "Failed to set DEFAULT_FORWARD_POLICY in /etc/default/ufw (expected line not found). Fix it manually or unset VPN_FORWARDING."
    fi
    ok "DEFAULT_FORWARD_POLICY=ACCEPT set."
  fi
else
  log "VPN_FORWARDING=no (default) — leaving DEFAULT_FORWARD_POLICY unchanged."
fi

ufw --force enable || die "Failed to enable ufw. Check /etc/default/ufw and run 'ufw --force enable' manually to see the error."
systemctl enable ufw >/dev/null 2>&1 || true
ufw status verbose | sed 's/^/    /' >&2

ok "Firewall configured."
