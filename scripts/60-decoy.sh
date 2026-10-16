# 60-decoy.sh — install the fake corporate file-manager front site.

log "Downloading the decoy index page from $DECOY_URL (max 30s)..."
install -d -m 755 /var/www/fake
if ! curl -fsSL --max-time 30 -o /var/www/fake/index.html "$DECOY_URL"; then
  # Fallback to the copy vendored in the repo.
  if [ -s "$REPO_DIR/assets/index.html" ]; then
    warn "Download failed; using the vendored copy from the repo."
    cp -f "$REPO_DIR/assets/index.html" /var/www/fake/index.html
  else
    warn "No vendored copy; using a minimal placeholder."
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
