# 50-adguard.sh — install AdGuard Home, patch its config, wire the unit.

AG_DIR=/opt/AdGuardHome
AG_BIN="$AG_DIR/AdGuardHome"
AG_CFG="$AG_DIR/AdGuardHome.yaml"
AG_UNIT=/etc/systemd/system/AdGuardHome.service

# --- 1. Install the binary (official installer) --------------------------
if [ -x "$AG_BIN" ]; then
  ok "AdGuard Home binary already present: $AG_BIN"
else
  log "Installing AdGuard Home via the official installer..."
  curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
    | sh -s -- -v
  [ -x "$AG_BIN" ] || die "AdGuard Home binary not found after install."
  ok "AdGuard Home installed."
fi

# --- 2. Stop it so we can edit the config --------------------------------
systemctl stop AdGuardHome 2>/dev/null || true
pkill -f "$AG_BIN" 2>/dev/null || true
sleep 1

# --- 3. Make sure a config exists; let AdGuard generate a default if not --
if [ ! -s "$AG_CFG" ]; then
  log "No config present; starting AdGuard briefly so it writes a default config..."
  ( cd "$AG_DIR" && "$AG_BIN" -w "$AG_DIR" --no-check-update >/tmp/adguard-firstrun.log 2>&1 & )
  for _ in $(seq 1 25); do [ -s "$AG_CFG" ] && break; sleep 1; done
  pkill -f "$AG_BIN" 2>/dev/null || true
  sleep 1
  [ -s "$AG_CFG" ] || die "AdGuard did not generate $AG_CFG (see /tmp/adguard-firstrun.log)."
  ok "Default config generated."
fi

# --- 4. Deterministic systemd unit ---------------------------------------
install -m 644 "$REPO_DIR/templates/AdGuardHome.service" "$AG_UNIT"
systemctl daemon-reload
ok "Installed unit $AG_UNIT"

# --- 5. Generate the admin bcrypt hash -----------------------------------
require_cmd htpasswd
ADG_ADMIN_HASH="$(htpasswd -nbBC 14 "" "$ADMIN_PASS" | sed 's/^[^:]*://' | tr -d '\n')"
[ -n "$ADG_ADMIN_HASH" ] || die "Failed to generate a bcrypt hash for the admin password."

# --- 6. Patch the config --------------------------------------------------
log "Patching AdGuard config..."
ADG_HTTP_ADDRESS="127.0.0.1:3000" \
ADG_SERVE_PLAIN_DNS="false" \
ADG_TLS_ENABLED="true" \
ADG_TLS_SERVER_NAME="$DOMAIN" \
ADG_TLS_CERT="/etc/ssl/adguard/fullchain.pem" \
ADG_TLS_KEY="/etc/ssl/adguard/privkey.pem" \
ADG_TLS_PORT_HTTPS="0" \
ADG_TLS_PORT_DOT="853" \
ADG_TLS_PORT_DOQ="0" \
ADG_ADMIN_USER="$ADMIN_USER" \
ADG_ADMIN_HASH="$ADG_ADMIN_HASH" \
ADG_UPSTREAMS="$ADGUARD_UPSTREAMS" \
ADG_BOOTSTRAP="$ADGUARD_BOOTSTRAP" \
ADG_FALLBACK="$ADGUARD_FALLBACK" \
ADG_ENABLE_FILTERS="$ENABLE_DEFAULT_FILTERS" \
python3 "$REPO_DIR/templates/patch-adguard-config.py" "$AG_CFG"

chown root:root "$AG_CFG"
chmod 600 "$AG_CFG"
ok "Config patched."

# --- 7. Start -------------------------------------------------------------
systemctl enable AdGuardHome >/dev/null 2>&1 || true
systemctl restart AdGuardHome
if wait_service_active AdGuardHome 30; then
  ok "AdGuardHome is active."
else
  err "AdGuardHome failed to start. Recent logs:"
  journalctl -u AdGuardHome -n 30 --no-pager >&2 || true
  die "AdGuard Home did not start."
fi

# --- 8. Sanity check listeners -------------------------------------------
ss -tlnp 2>/dev/null | grep -E ':(3000|853)\b' | sed 's/^/    /' >&2 || true
if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '0\.0\.0\.0:3000|\[::\]:3000|\*:3000'; then
  warn "AdGuard appears to listen on :3000 beyond localhost — check http.address."
else
  ok "Admin/DoH is bound to localhost only; DoT is public on :853."
fi
