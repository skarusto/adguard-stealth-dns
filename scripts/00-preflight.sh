# 00-preflight.sh — verify assumptions before touching the system.

require_cmd curl
require_cmd openssl || true

# --- OS check ------------------------------------------------------------
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ok "OS: ${PRETTY_NAME:-$ID}" ;;
    *) warn "Unsupported OS '${ID:-unknown}'. This script targets Debian/Ubuntu." ;;
  esac
else
  warn "Cannot detect OS (/etc/os-release missing)."
fi

# --- Internet ------------------------------------------------------------
echo "[preflight] Checking outbound internet access..." >&2
if ! curl -fsS --max-time 10 https://api.ipify.org >/dev/null 2>&1; then
  die "No outbound internet access (needed to install packages and fetch blocklists)."
fi
echo "[preflight] Internet OK." >&2

# --- Public IP (bounded, no silent hangs) -------------------------------
echo "[preflight] Detecting this server's public IP (single attempt, 8s max)..." >&2
PUBLIC_IP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null)" || PUBLIC_IP=""
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -fsS --max-time 8 https://icanhazip.com 2>/dev/null)" || PUBLIC_IP=""
fi
if [ -z "$PUBLIC_IP" ]; then
  warn "Could not determine this server's public IP (ISP may block the lookup providers)."
  PUBLIC_IP=""
else
  echo "[preflight] Public IP : $PUBLIC_IP" >&2
fi

# --- Domain resolution --------------------------------------------------
echo "[preflight] Resolving '$DOMAIN' ..." >&2
RESOLVED="$(timeout 20 getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$RESOLVED" ]; then
  die "Domain '$DOMAIN' does not resolve. Create the A record first (a prerequisite step)."
fi
echo "[preflight] '$DOMAIN' -> $RESOLVED" >&2
log "Public IP      : ${PUBLIC_IP:-unknown}"
log "'$DOMAIN' -> $RESOLVED"

if [ -n "$PUBLIC_IP" ] && ! grep -qw "$PUBLIC_IP" <<<"$RESOLVED"; then
  warn "'$DOMAIN' does not resolve to this server's public IP ($PUBLIC_IP)."
  warn "Let's Encrypt will FAIL until the A record points here."
  if [ "$ASSUME_YES" != "yes" ]; then
    ask PREFLIGHT_ACK "Continue anyway? (yes/no)" "no"
    [ "$PREFLIGHT_ACK" = "yes" ] || die "Aborted: fix DNS first."
  else
    warn "Continuing because --yes was given."
  fi
else
  ok "[preflight] DNS looks correct."
fi
echo "[preflight] DONE." >&2

# --- Required TCP ports are free (or already ours) ----------------------
for p in 80 443 853; do
  if port_in_use "$p"; then
    owner="$(ss -tlnp 2>/dev/null | awk -v p=":$p" '$4 ~ p {print $NF; exit}')"
    case "$owner" in
      *caddy*|*AdGuardHome*|*AdGuard*)
        ok "Port $p already used by our own service ($owner)." ;;
      *)
        warn "Port $p is in use by: ${owner:-unknown}"
        warn "If that is a web server / DNS server, stop it or free the port." ;;
    esac
  else
    ok "Port $p is free."
  fi
done

# --- Warn if AdGuard has never run and 3000 is occupied -----------------
if port_in_use 3000; then
  warn "Port 3000 is already in use (AdGuard's future admin port)."
fi

# --- SSH port detection (for the firewall step) -------------------------
if [ -z "${SSH_PORT:-}" ]; then
  SSH_PORT="$(detect_ssh_port)"
  export SSH_PORT
fi
log "SSH port       : $SSH_PORT (will be allowed through the firewall)"

ok "Preflight passed."
