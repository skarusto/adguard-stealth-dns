# 40-cert.sh — issue the shared TLS certificate and install the deploy hook.

require_cmd certbot

install -d -m 755 /etc/ssl/adguard

CERT_LIVE="/etc/letsencrypt/live/$DOMAIN"

# --- Issue (only if we don't already have a live cert) -------------------
if [ -s "$CERT_LIVE/fullchain.pem" ]; then
  ok "Certificate already exists for $DOMAIN; skipping issuance."
else
  log "Requesting a Let's Encrypt certificate for $DOMAIN (standalone, port 80)..."
  # Port 80 must be free: Caddy is stopped (30-caddy) and AdGuard is not up yet.
  systemctl stop caddy 2>/dev/null || true
  certbot certonly --standalone \
    --pre-hook  "systemctl stop caddy || true" \
    --post-hook "systemctl start caddy || true" \
    -d "$DOMAIN" \
    -m "$EMAIL" \
    --agree-tos --no-eff-email --non-interactive
  [ -s "$CERT_LIVE/fullchain.pem" ] || die "certbot did not produce a certificate."
  ok "Certificate issued."
fi

# --- Install the deploy hook --------------------------------------------
HOOK=/etc/letsencrypt/renewal-hooks/deploy/adguard-shared-cert.sh
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sed "s|__DOMAIN__|$(toml_escape "$DOMAIN")|g" \
  "$REPO_DIR/templates/adguard-shared-cert.sh" >"$HOOK"
chmod 755 "$HOOK"
ok "Deploy hook installed: $HOOK"

# --- Run the hook once so the shared copy exists before Caddy starts -----
"$HOOK"
[ -s /etc/ssl/adguard/fullchain.pem ] || die "Shared cert copy missing after hook run."
[ -s /etc/ssl/adguard/privkey.pem ]   || die "Shared key copy missing after hook run."
ok "Shared certificate synced to /etc/ssl/adguard/."
ls -l /etc/ssl/adguard/ | sed 's/^/    /' >&2

# --- Make renewals non-fatal if services are absent ----------------------
ok "Certificate step complete."
