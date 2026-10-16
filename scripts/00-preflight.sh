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
if ! curl -fsS --max-time 10 https://api.ipify.org >/dev/null 2>&1; then
  die "No outbound internet access (needed to install packages and fetch blocklists)."
fi

# --- Domain resolves to this server -------------------------------------
PUBLIC_IP="$(detect_public_ip || true)"
[ -n "$PUBLIC_IP" ] || warn "Could not determine this server's public IP."

RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$RESOLVED" ]; then
  die "Domain '$DOMAIN' does not resolve. Create the A record first (a prerequisite step)."
fi
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
  ok "DNS looks correct."
fi

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
