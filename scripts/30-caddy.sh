# 30-caddy.sh — install Caddy from the official repository and stop it for now.

if have_cmd caddy; then
  ok "Caddy already installed: $(caddy version)"
else
  log "Adding the official Caddy apt repository..."
  curl --proto '=https' --tlsv1.2 -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl --proto '=https' --tlsv1.2 -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y
  apt-get install -y caddy
  ok "Installed: $(caddy version)"
fi

# The package starts Caddy immediately; stop it so port 80 is free for the
# ACME HTTP-01 challenge during certificate issuance.
systemctl stop caddy 2>/dev/null || true
ok "Caddy installed and stopped (will be started once the cert exists)."
