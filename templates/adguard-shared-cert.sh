#!/bin/bash
# adguard-shared-cert.sh — certbot deploy hook.
# Copies the freshly issued/renewed certificate into the shared location used by
# BOTH Caddy (for :443) and AdGuard Home (for DoT on :853), then makes each
# service pick it up. Installed to:
#   /etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
#
# The __DOMAIN__ token is replaced at install time.
set -e

DOMAIN="__DOMAIN__"
LIVE="/etc/letsencrypt/live/$DOMAIN"
DEST="/etc/ssl/adguard"

[ -s "$LIVE/fullchain.pem" ] || { echo "no cert at $LIVE"; exit 0; }

install -d -m 755 "$DEST"

# fullchain: world-readable. privkey: readable only by root and the caddy group,
# because Caddy's service runs as user 'caddy' and AdGuard runs as root.
install -m 644 "$LIVE/fullchain.pem" "$DEST/fullchain.pem"
if getent group caddy >/dev/null 2>&1; then
  install -m 640 -o root -g caddy "$LIVE/privkey.pem" "$DEST/privkey.pem"
  chown root:caddy "$DEST"
else
  install -m 600 -o root -g root "$LIVE/privkey.pem" "$DEST/privkey.pem"
fi

systemctl reload caddy       2>/dev/null || true
systemctl restart AdGuardHome 2>/dev/null || true

echo "adguard-shared-cert: synced $DOMAIN cert to $DEST"
