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

# --- Phase 1: internet ---------------------------------------------------
echo "[preflight 1/4] Checking outbound internet access..." >&2
if ! curl -fsS --max-time 10 https://api.ipify.org >/dev/null 2>&1; then
  die "No outbound internet access. Cannot install packages or fetch blocklists.\n
      Check: 'curl -I https://api.ipify.org' on this server. Probably UFW or hosting firewall is blocking outbound HTTPS."
fi
echo "[preflight 1/4] Internet OK." >&2
ok "OS check uses $(command -v getent) for DNS."

# --- Phase 2: public IP (single 6s attempt) ------------------------------
echo "[preflight 2/4] Detecting this server's public IP..." >&2
PUBLIC_IP="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
if [ -z "$PUBLIC_IP" ]; then
  warn "Couldn't determine public IP automatically; Let's Encrypt will still proceed."
  PUBLIC_IP=""
else
  echo "[preflight 2/4] Public IP : $PUBLIC_IP" >&2
fi

# --- Phase 3: domain resolution (bounded to 15s) -------------------------
echo "[preflight 3/4] Resolving '$DOMAIN' (bounded to 15s)..." >&2
RESOLVED="$(timeout 15 getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -z "$RESOLVED" ]; then
  die "Domain '$DOMAIN' does not resolve (no A/AAAA record).\n
      Fix: create an A record for $DOMAIN -> <this server's public IP> at your registrar/DNS.\n
      Wait for propagation (up to 5 min), then re-run the one-liner."
fi
echo "[preflight 3/4] '$DOMAIN' -> $RESOLVED" >&2
log "Public IP      : ${PUBLIC_IP:-unknown}"
log "'$DOMAIN' -> $RESOLVED"

if [ -n "$PUBLIC_IP" ] && ! grep -qw "$PUBLIC_IP" <<<"$RESOLVED"; then
  warn "[preflight 3/4] '$DOMAIN' does not resolve to this server's public IP ($PUBLIC_IP)."
  warn "Let's Encrypt will FAIL until the A record points here."
  if [ "$ASSUME_YES" != "yes" ]; then
    ask PREFLIGHT_ACK "Continue anyway? (yes/no)" "no"
    [ "$PREFLIGHT_ACK" = "yes" ] || die "Aborted: fix DNS first."
  else
    warn "Continuing because --yes was given."
  fi
else
  ok "[preflight 3/4] DNS looks correct."
fi

# --- Phase 4: ports -----------------------------------------------------
echo "[preflight 4/4] Checking required ports 80/443/853..." >&2
for p in 80 443 853; do
  if port_in_use "$p"; then
    owner="$(ss -tlnp 2>/dev/null | awk -v pp=":$p" '$4 ~ pp {print $NF; exit}')"
    case "$owner" in
      *caddy*|*AdGuardHome*|*AdGuard*) ok "Port $p already used by our own service ($owner)." ;;
      *) warn "Port $p is in use by: ${owner:-unknown} (free it before continuing)" ;;
    esac
  else
    ok "Port $p is free."
  fi
done
if port_in_use 3000; then warn "Port 3000 is already in use (AdGuard's future admin port)."; fi
if [ -z "${SSH_PORT:-}" ]; then SSH_PORT="$(detect_ssh_port)"; export SSH_PORT; fi
log "SSH port       : $SSH_PORT"
echo "[preflight 4/4] DONE." >&2

ok "Preflight passed."
