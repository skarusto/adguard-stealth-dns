# 40-cert.sh — issue the shared TLS certificate and install the deploy hook.

require_cmd certbot
systemctl enable --now certbot.timer \
  || die "Unable to enable and start certbot.timer; check 'systemctl status certbot.timer' and resume after fixing it."

install -d -m 755 /etc/ssl/adguard

CERT_LIVE="/etc/letsencrypt/live/$DOMAIN"
POST_HOOK="/bin/sh -c 'if [ -s /etc/caddy/Caddyfile ] && grep -q /etc/ssl/adguard/fullchain.pem /etc/caddy/Caddyfile && [ -s /etc/ssl/adguard/fullchain.pem ] && [ -s /etc/ssl/adguard/privkey.pem ]; then systemctl restart caddy || true; fi'"

# --- Issue (only if we don't already have a live cert) -------------------
if [ -s "$CERT_LIVE/fullchain.pem" ]; then
  ok "Certificate already exists for $DOMAIN; skipping issuance."
else
  log "Requesting a Let's Encrypt certificate for $DOMAIN (standalone, port 80)..."
  # Port 80 must be free: Caddy is stopped (30-caddy) and AdGuard is not up yet.
  systemctl stop caddy 2>/dev/null || true
  if certbot certonly --standalone \
    --pre-hook  "systemctl stop caddy || true" \
    --post-hook "$POST_HOOK" \
    -d "$DOMAIN" \
    -m "$EMAIL" \
    --agree-tos --no-eff-email --non-interactive; then
    _certbot_status=0
  else
    _certbot_status=$?
  fi
  if [ "$_certbot_status" -ne 0 ]; then
    err "Certbot failed with an ACME error obtaining a trusted certificate for $DOMAIN (exit status $_certbot_status). Check DNS A/AAAA and inbound TCP 80 through UFW and the cloud firewall. If the ACME log reports CAA lookup SERVFAIL, repair the domain/parent nameservers or add a valid CAA record authorizing letsencrypt.org; this is a DNS-side issue, not HTTP challenge connectivity. Details: /var/log/letsencrypt/letsencrypt.log. Fix the cause and resume normally; any existing trusted certificate is retained and --force is not required."
    exit "$_certbot_status"
  fi
  if [ ! -s "$CERT_LIVE/fullchain.pem" ]; then
    die "Certbot returned success but no certificate was created for $DOMAIN. Check /var/log/letsencrypt/letsencrypt.log."
  fi
  ok "Certificate issued."
fi

# Repair only known installer-generated legacy hooks on resume. Preserve any
# unrelated user hook and warn rather than overwriting it.
RENEWAL_CONF="/etc/letsencrypt/renewal/$DOMAIN.conf"
if [ -f "$RENEWAL_CONF" ] && grep -q '^post_hook[[:space:]]*=' "$RENEWAL_CONF"; then
  if grep -Fxq "post_hook = $POST_HOOK" "$RENEWAL_CONF"; then
    : # Already current; an ordinary rerun needs no repair or warning.
  elif grep -Fxq 'post_hook = systemctl start caddy || true' "$RENEWAL_CONF" \
    || grep -Fxq 'post_hook = if [ -f /etc/caddy/Caddyfile ]; then systemctl start caddy || true; fi' "$RENEWAL_CONF" \
    || grep -Fxq "post_hook = /bin/sh -c 'if [ -f /etc/caddy/Caddyfile ]; then systemctl start caddy || true; fi'" "$RENEWAL_CONF"; then
    _post_hook_sed=${POST_HOOK//&/\\&}
    sed -i "/^post_hook[[:space:]]*=/c\\post_hook = $_post_hook_sed" "$RENEWAL_CONF" \
      || die "Could not repair the recognized legacy Certbot post-hook in $RENEWAL_CONF."
  else
    warn "Leaving custom Certbot post-hook unchanged in $RENEWAL_CONF."
  fi
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

ok "Certificate step complete."
