# 20-firewall.sh — restrictive UFW: allow SSH + 80 + 443 + 853 (+ user extras).

if [ "${SKIP_FIREWALL:-no}" = "yes" ]; then
  warn "SKIP_FIREWALL=yes — leaving the firewall untouched."
  return 0 2>/dev/null || true
fi

require_cmd ufw

log "Currently listening sockets (for your reference):"
ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/' | sed 's/^/    /' >&2 || true
ss -ulnp 2>/dev/null | awk 'NR==1 || /UNCONN/' | sed 's/^/    /' >&2 || true

log "This step will ALLOW: ${SSH_PORT}/tcp 80/tcp 443/tcp 853/tcp ${EXTRA_ALLOW:-}"
warn "Any service NOT in that list will become unreachable once UFW is enabled."
if [ "$ASSUME_YES" != "yes" ]; then
  ask FW_ACK "Enable UFW with these rules now? (yes/no)" "yes"
  [ "$FW_ACK" = "yes" ] || { warn "Skipping firewall by user request."; return 0 2>/dev/null || true; }
fi

ufw default deny incoming
ufw default allow outgoing

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

# Keep VPN forwarding working if the box routes traffic.
if [ -f /etc/default/ufw ]; then
  if ! grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
    warn "Setting DEFAULT_FORWARD_POLICY=ACCEPT (needed if this host routes a VPN)."
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  fi
fi

ufw --force enable
systemctl enable ufw >/dev/null 2>&1 || true
ufw status verbose | sed 's/^/    /' >&2

ok "Firewall configured."
