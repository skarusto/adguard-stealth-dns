# 30-caddy.sh — install Caddy from the official repository and stop it for now.

KEYRING=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
SOURCE=/etc/apt/sources.list.d/caddy-stable.list
# Repair these public apt inputs on resume too: a prior umask may have left
# them unreadable to the _apt user.
[ ! -e "$KEYRING" ] || chmod 644 "$KEYRING" || die "Cannot make Caddy apt keyring readable: $KEYRING"
[ ! -e "$SOURCE" ] || chmod 644 "$SOURCE" || die "Cannot make Caddy apt source readable: $SOURCE"

if have_cmd caddy; then
  ok "Caddy already installed: $(caddy version)"
else
  log "Adding the official Caddy apt repository..."
  curl --proto '=https' --tlsv1.2 -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --batch --yes --dearmor -o "$KEYRING"
  chmod 644 "$KEYRING" || die "Cannot make Caddy apt keyring readable: $KEYRING"
  curl --proto '=https' --tlsv1.2 -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee "$SOURCE" >/dev/null
  chmod 644 "$SOURCE" || die "Cannot make Caddy apt source readable: $SOURCE"
  apt-get update -y || die "APT could not update the Caddy repository. Check keyring/source-list readability (mode 0644) and any NO_PUBKEY/signature errors; do not disable signature checking."
  apt-get install -y caddy || die "APT could not install Caddy. Check repository signature errors and apt output; do not disable signature checking."
  ok "Installed: $(caddy version)"
fi

# The package starts Caddy immediately; stop it so port 80 is free for the
# ACME HTTP-01 challenge during certificate issuance.
systemctl stop caddy 2>/dev/null || true
ok "Caddy installed and stopped (will be started once the cert exists)."
