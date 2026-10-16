# 70-caddyfile.sh — write + validate + start the Caddy vhost.

CADDYFILE=/etc/caddy/Caddyfile

# Build the file by substituting __DOMAIN__ / __SECRET_PATH__ tokens.
sed -e "s|__DOMAIN__|$(toml_escape "$DOMAIN")|g" \
    -e "s|__SECRET_PATH__|$SECRET_PATH|g" \
    "$REPO_DIR/templates/Caddyfile" >"$CADDYFILE"
chmod 644 "$CADDYFILE"

log "Caddyfile written to $CADDYFILE"
log "Running 'caddy validate'..."
if ! caddy validate --config "$CADDYFILE"; then
  die "Caddyfile validation failed.\n  Fix the file at /etc/caddy/Caddyfile (inspect prints above).\n  Most often: a typo in the secret path, or wrong TLS path.\n  Re-run with --only 70-caddyfile after fixing."
fi
ok "Caddyfile is valid."

systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
  log "Waiting up to 30s for Caddy to start..."
if wait_service_active caddy 30; then
  ok "Caddy is active."
else
  err "Caddy failed to start."
  journalctl -u caddy -n 30 --no-pager >&2 || true
  die "Caddy did not start."
fi
