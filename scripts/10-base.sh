# 10-base.sh — base packages, timezone, optional full upgrade.

export DEBIAN_FRONTEND=noninteractive

log "apt-get update..."
apt-get update -y

PKGS=(
  ca-certificates gnupg curl wget openssl
  debian-keyring debian-archive-keyring apt-transport-https
  ufw python3 python3-yaml apache2-utils certbot
  lsb-release
)

log "Installing base packages: ${PKGS[*]}"
apt-get install -y --no-install-recommends "${PKGS[@]}"

if [ "${DO_UPGRADE:-no}" = "yes" ]; then
  log "Upgrading installed packages (DO_UPGRADE=yes)..."
  apt-get -y upgrade
else
  log "Skipping full upgrade (set DO_UPGRADE=yes to enable)."
fi

if [ -n "${TIMEZONE:-}" ]; then
  if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    ok "Timezone set to $TIMEZONE"
  else
    warn "Could not set timezone to '$TIMEZONE'."
  fi
fi

ok "Base preparation complete."
