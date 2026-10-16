# 90-uninstall.sh — reverse the deployment (best effort).

hdr "Uninstalling"
warn "This stops and removes Caddy, AdGuard Home and (after confirmation) the certificate."

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
  rm -rf /opt/AdGuardHome
fi

# Caddy + certbot (packages).
apt-get -y remove --purge caddy certbot >/dev/null 2>&1 || true

# Files.
rm -rf /var/www/fake
rm -rf /etc/ssl/adguard
rm -f  /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
rm -rf "$STATE_DIR"

warn "Certificate files under /etc/letsencrypt/live/ may remain — remove manually if desired:"
warn "  certbot delete --cert-name <domain>"
warn "UFW state is left intact (too risky to reset automatically). Reset manually with 'ufw reset' if wanted."

ok "Uninstall finished."
