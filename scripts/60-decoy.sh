# 60-decoy.sh — install the fake corporate file-manager front site.

install -d -m 755 /var/www/fake

# Default to the copy vendored in the repo; only fetch when DECOY_URL is set.
_decoy_use_vendored=no
if [ -z "${DECOY_URL:-}" ]; then
  log "DECOY_URL is empty; installing the decoy page vendored in this repo."
  _decoy_use_vendored=yes
elif curl -fsSL --max-time 30 --connect-timeout 5 -o /var/www/fake/index.html "$DECOY_URL"; then
  log "Downloaded the decoy index page from $DECOY_URL."
else
  warn "Download from $DECOY_URL failed; falling back to the vendored copy."
  rm -f /var/www/fake/index.html
  _decoy_use_vendored=yes
fi

if [ "$_decoy_use_vendored" = "yes" ]; then
  if [ -s "$REPO_DIR/assets/index.html" ]; then
    cp -f "$REPO_DIR/assets/index.html" /var/www/fake/index.html
  else
    warn "No vendored copy available; writing a minimal placeholder."
    cat > /var/www/fake/index.html <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>AeroDrive Pro</title></head>
<body><h1>AeroDrive Pro — Corporate File Manager</h1><p>Sign in via your organisation portal.</p></body></html>
EOF
  fi
fi

chown root:root /var/www/fake/index.html
chmod 644 /var/www/fake/index.html
[ -s /var/www/fake/index.html ] || die "Decoy index is empty."
ok "Decoy site installed at /var/www/fake/index.html ($(wc -c < /var/www/fake/index.html) bytes)."
