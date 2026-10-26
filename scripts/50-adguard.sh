# 50-adguard.sh — install AdGuard Home, patch its config, wire the unit.

AG_DIR=/opt/AdGuardHome
AG_BIN="$AG_DIR/AdGuardHome"
AG_CFG="$AG_DIR/AdGuardHome.yaml"
AG_UNIT=/etc/systemd/system/AdGuardHome.service
AG_VERSION=v0.107.79 # Reproducible release pin; verified against upstream release archive.

# --- 1. Install the official release archive without running its installer -
if [ -x "$AG_BIN" ]; then
  ok "AdGuard Home binary already present: $AG_BIN"
else
  case "$(uname -m)" in
    x86_64|amd64) AG_ARCH=amd64 ;;
    aarch64|arm64) AG_ARCH=arm64 ;;
    i386|i686) AG_ARCH=386 ;;
    armv6l|armv6) AG_ARCH=armv6 ;;
    armv7l|armv7) AG_ARCH=armv7 ;;
    *) die "Unsupported AdGuard Home architecture: $(uname -m)" ;;
  esac
  AG_TMP="$(mktemp -d)" || die "Could not create private AdGuard download directory."
  chmod 700 "$AG_TMP"
  trap 'rm -rf "$AG_TMP"' EXIT
  log "Downloading official AdGuard Home $AG_VERSION release archive..."
  curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 --retry-max-time 360 \
    "https://github.com/AdguardTeam/AdGuardHome/releases/download/$AG_VERSION/AdGuardHome_linux_${AG_ARCH}.tar.gz" \
    -o "$AG_TMP/adguard.tar.gz" || die "Could not download AdGuard Home release archive."
  # GitHub's release archive stores members with a leading ./ component.
  # Extract into the private staging directory rather than naming members.
  tar -xzf "$AG_TMP/adguard.tar.gz" -C "$AG_TMP" || die "Could not unpack AdGuard Home release archive."
  install -d -o root -g root -m 700 "$AG_DIR"
  install -o root -g root -m 755 "$AG_TMP/AdGuardHome/AdGuardHome" "$AG_BIN"
  rm -rf "$AG_TMP"
  trap - EXIT
  if [ ! -x "$AG_BIN" ]; then
      die "AdGuard Home binary not found after archive extraction at $AG_BIN."$'\n'"  Verify the official release archive contains AdGuardHome/AdGuardHome and retry; do not use the auto-starting installer."
  fi
  ok "AdGuard Home installed."
fi

# Stop only the managed unit. Prepare private workdir permissions before start.
systemctl stop AdGuardHome 2>/dev/null || true
install -d -o root -g root -m 700 "$AG_DIR"

# --- 2. Complete first-run wizard locally when no config exists ------------
if [ -e "$AG_CFG" ] && ! python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])) or {}; sys.exit(0 if "schema_version" in c else 1)' "$AG_CFG" 2>/dev/null; then
  die "Existing AdGuard config is invalid or has no schema_version; refusing to replace it: $AG_CFG"
fi
if [ ! -e "$AG_CFG" ]; then
  log "No config present; configuring AdGuard's first-run wizard on loopback..."
  if ! ADG_INIT_USERNAME="$ADMIN_USER" ADG_INIT_PASSWORD="$ADMIN_PASS" \
      python3 "$REPO_DIR/templates/initialize-adguard.py" \
      --binary "$AG_BIN" --work-dir "$AG_DIR" --config "$AG_CFG"; then
    die "AdGuard first-run wizard did not become ready or rejected its configure request. See $AG_DIR/initialize.log (root-only). Re-run after addressing the wizard/configuration failure."
  fi
  ok "First-run configuration generated."
fi
chown root:root "$AG_DIR"
chmod 700 "$AG_DIR"

# --- 4. Deterministic systemd unit ---------------------------------------
install -m 644 "$REPO_DIR/templates/AdGuardHome.service" "$AG_UNIT"
systemctl daemon-reload
ok "Installed unit $AG_UNIT"

# --- 5. Generate the admin bcrypt hash -----------------------------------
require_cmd htpasswd
ADG_ADMIN_HASH="$(printf '%s\n' "$ADMIN_PASS" | htpasswd -nBC 14 -i "" | sed 's/^[^:]*://' | tr -d '\n')"
[ -n "$ADG_ADMIN_HASH" ] || die "Failed to generate a bcrypt hash for the admin password."

# --- 6. Patch the config --------------------------------------------------
log "Patching AdGuard config..."
ADG_HTTP_ADDRESS="127.0.0.1:3000" \
ADG_BIND_HOSTS="0.0.0.0" \
ADG_SERVE_PLAIN_DNS="false" \
ADG_DOH_ENABLED="true" \
ADG_DOH_INSECURE_ENABLED="true" \
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
  die "AdGuard Home did not start."$'\n'"  Inspect: systemctl status AdGuardHome && journalctl -u AdGuardHome -n 40 --no-pager"$'\n'"  Confirm /opt/AdGuardHome/AdGuardHome.yaml is valid YAML and schema_version is current."
fi

# --- 8. Sanity check listeners -------------------------------------------
ss -tlnp 2>/dev/null | grep -E ':(3000|853)\b' | sed 's/^/    /' >&2 || true
if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '0\.0\.0\.0:3000|\[::\]:3000|\*:3000'; then
  warn "AdGuard appears to listen on :3000 beyond localhost — check http.address."
else
  ok "Admin/DoH is bound to localhost only; DoT is public on :853."
fi
