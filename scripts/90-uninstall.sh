# 90-uninstall.sh — reverse the deployment (best effort).

hdr "Uninstalling"
warn "This stops and removes Caddy and AdGuard Home, the generated config, logs,"
warn "the Caddy apt repo, the systemd unit, and (after confirmation) the certificate."

if [ "$ASSUME_YES" != "yes" ]; then
  ask UNINSTALL_ACK "Really tear down the deployment? (yes/no)" "no"
  [ "$UNINSTALL_ACK" = "yes" ] || { warn "Aborted by user."; return 0 2>/dev/null || exit 0; }
fi

# Stop services first.
systemctl disable --now caddy 2>/dev/null || true
systemctl stop caddy 2>/dev/null || true
systemctl disable --now AdGuardHome 2>/dev/null || true
systemctl stop AdGuardHome 2>/dev/null || true

# AdGuard (official installer leaves a unit; remove via its flag, then rm -rf).
if [ -x /opt/AdGuardHome/AdGuardHome ]; then
  /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
fi
rm -rf /opt/AdGuardHome
# Remove the unit unconditionally in case the installer left it behind.
rm -f /etc/systemd/system/AdGuardHome.service
systemctl daemon-reload 2>/dev/null || true

# Caddy + certbot (packages).
apt-get -y remove --purge caddy certbot >/dev/null 2>&1 || true

# Caddy apt repository + signing key added at install time.
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
rm -f /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
rm -f /etc/apt/sources.list.d/caddy-stable.list
apt-get -y autoremove --purge >/dev/null 2>&1 || true

# Files.
rm -rf /var/www/fake
rm -rf /etc/ssl/adguard
rm -f  /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh

# Generated configuration (holds the admin password) + logs + state.
[ -n "${REPO_DIR:-}" ]   && rm -f -- "$REPO_DIR/deploy.env"
[ -n "${CONFIG_FILE:-}" ] && rm -f -- "$CONFIG_FILE"
rm -f /etc/adguard-deploy/deploy.env
rm -rf /etc/adguard-deploy
rm -f  /var/log/adguard-deploy.log
[ -n "${STATE_DIR:-}" ] && rm -rf -- "$STATE_DIR"

# Firewall: warn about any change we made, without risking a wrong "fix" here.
if [ -f /etc/default/ufw ] && grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
  warn "NOTE: /etc/default/ufw still has DEFAULT_FORWARD_POLICY=\"ACCEPT\" (set during install)."
  warn "      If this host does not route a VPN, restore the default with:"
  warn "      sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY=\"DROP\"/' /etc/default/ufw"
  warn "      sudo ufw reload"
fi

warn "Left intact on purpose (reset by hand if wanted):"
warn "  - UFW rules:      sudo ufw reset"
warn "  - Certificates:   sudo certbot delete --cert-name $DOMAIN   (files under /etc/letsencrypt/live/)"
warn "  - DNS records for $DOMAIN still point at this server"
warn "  - Any cloud-provider firewall rules you added"

ok "Uninstall finished."
