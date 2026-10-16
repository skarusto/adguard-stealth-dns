#!/usr/bin/env bash
#
# install.sh — ONE COMMAND installer for adguard-stealth-dns:
#   - cloned repo:  sudo ./install.sh
#   - remote curl:  curl -fsSL https://raw.githubusercontent.com/skarusto/adguard-stealth-dns/main/install.sh | sudo bash
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Mode detection: are we already inside a checkout (scripts/lib.sh present)?
# ---------------------------------------------------------------------------
SELF="${BASH_SOURCE[0]:-}"
_selfdir=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  _selfdir="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || _selfdir=""
fi

if [ -z "$_selfdir" ] || [ ! -f "$_selfdir/scripts/lib.sh" ]; then
  # ---- CURL MODE: download the whole repo into a temp dir, then run it there ----
  REPO="${REPO:-skarusto/adguard-stealth-dns}"
  BRANCH="${BRANCH:-main}"
  RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
  _tmpdir="$(mktemp -d /tmp/adguard-deploy.XXXXXX)"
  trap 'rm -rf "$_tmpdir"' EXIT
  echo "[bootstrap] Downloading $REPO@$BRANCH into $_tmpdir ..."

  # First try the GitHub tree API to get the exact file list; fall back to a
  # committed manifest if that fails (offline-ish / rate-limited).
  _files=""
  if command -v curl >/dev/null 2>&1; then
    _files="$(curl -fsSL --max-time 15 \
      "https://api.github.com/repos/$REPO/git/trees/$BRANCH?recursive=1" 2>/dev/null \
      | grep -E '"path":' | sed -E 's/.*"path": *"([^"]+)".*/\1/')"
  fi
  if [ -z "$_files" ]; then
    cat >/dev/null <<'MANIFEST'
install.sh
scripts/lib.sh
scripts/00-preflight.sh
scripts/10-base.sh
scripts/20-firewall.sh
scripts/30-caddy.sh
scripts/40-cert.sh
scripts/50-adguard.sh
scripts/60-decoy.sh
scripts/70-caddyfile.sh
scripts/80-verify.sh
scripts/90-uninstall.sh
templates/Caddyfile
templates/AdGuardHome.service
templates/adguard-shared-cert.sh
templates/patch-adguard-config.py
assets/index.html
docs/MANUAL.md
docs/MANUAL.ru.md
README.md
README.ru.md
LICENSE
MANIFEST
    _files=""
    while IFS= read -r _f; do [ -n "$_f" ] && _files="$_files$_f"$'\n'; done \
      <<'MANIFEST'
install.sh
scripts/lib.sh
scripts/00-preflight.sh
scripts/10-base.sh
scripts/20-firewall.sh
scripts/30-caddy.sh
scripts/40-cert.sh
scripts/50-adguard.sh
scripts/60-decoy.sh
scripts/70-caddyfile.sh
scripts/80-verify.sh
scripts/90-uninstall.sh
templates/Caddyfile
templates/AdGuardHome.service
templates/adguard-shared-cert.sh
templates/patch-adguard-config.py
assets/index.html
docs/MANUAL.md
docs/MANUAL.ru.md
README.md
README.ru.md
LICENSE
MANIFEST
  fi

  for _f in $_files; do
    [ -z "$_f" ] && continue
    mkdir -p "$_tmpdir/$(dirname "$_f")"
    if ! curl -fsSL --retry 3 --retry-delay 1 --max-time 60 "$RAW/$_f" -o "$_tmpdir/$_f" 2>/dev/null; then
      case "$_f" in
        docs/*|assets/*|README*|LICENSE) echo "[bootstrap] optional $_f not available, skipping." >&2 ;;
        *) echo "!! failed to download $_f" >&2; exit 1 ;;
      esac
    fi
  done

  chmod +x "$_tmpdir/install.sh"
  # Hand off to the downloaded copy (which now has scripts/lib.sh beside it).
  exec bash "$_tmpdir/install.sh" "$@"
fi

# ---------------------------------------------------------------------------
# From this point on we are in CLONE mode (install.sh is next to scripts/).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$_selfdir"
REPO_DIR="$SCRIPT_DIR"

# --- real installer body (cloned into scripts/ alongside) ------------------ for a stealth AdGuard Home DNS gateway:
# public DoH + DoT only, hidden admin UI behind a secret path, decoy front site.
#
# Usage:
#   sudo ./install.sh                      # interactive, reads/creates deploy.env
#   sudo ./install.sh --config my.env      # use a specific config file
#   sudo DOMAIN=dns.example.com EMAIL=me@example.com ADMIN_PASS=secret ./install.sh --yes
#   sudo ./install.sh --force              # re-run all steps even if already done
#   sudo ./install.sh --only 70-caddyfile  # run a single step
#   sudo ./install.sh --uninstall          # tear everything down
#   sudo ./install.sh --help
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/scripts/lib.sh"

STEPS=(
  00-preflight
  10-base
  20-firewall
  30-caddy
  40-cert
  50-adguard
  60-decoy
  70-caddyfile
  80-verify
)

CONFIG_FILE="$REPO_DIR/deploy.env"
ASSUME_YES="no"
FORCE="no"
ONLY=""
DO_UNINSTALL="no"

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config)   CONFIG_FILE="$2"; shift 2 ;;
    -y|--yes)      ASSUME_YES="yes"; shift ;;
    -f|--force)    FORCE="yes"; shift ;;
    --only)        ONLY="$2"; shift 2 ;;
    --uninstall)   DO_UNINSTALL="yes"; shift ;;
    -h|--help)     usage ;;
    *)             die "Unknown argument: $1 (try --help)" ;;
  esac
done
export ASSUME_YES FORCE

require_root
mkdir -p "$STATE_DIR"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

# ---------------------------------------------------------------------------
# Config: defaults <- deploy.env <- environment <- interactive prompts
# ---------------------------------------------------------------------------
# Defaults (only used if nothing else sets them).
: "${DOMAIN:=}"
: "${EMAIL:=}"
: "${SECRET_PATH:=}"
: "${ADMIN_USER:=admin}"
: "${ADMIN_PASS:=}"
: "${TIMEZONE:=UTC}"
: "${SSH_PORT:=}"
: "${EXTRA_ALLOW:=}"
: "${SKIP_FIREWALL:=no}"
: "${DO_UPGRADE:=no}"
: "${ENABLE_DEFAULT_FILTERS:=yes}"
: "${DECOY_URL:=https://raw.githubusercontent.com/Liafanx/MTProxyL/refs/heads/main/templates_html/filemanager.html}"
: "${ADGUARD_UPSTREAMS:=}"
: "${ADGUARD_BOOTSTRAP:=}"
: "${ADGUARD_FALLBACK:=}"

if [ "$DO_UNINSTALL" != "yes" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    log "Loading config from $CONFIG_FILE"
    # shellcheck disable=SC1090
    set -a; source "$CONFIG_FILE"; set +a
  elif [ "$ASSUME_YES" != "yes" ] && [ -r /dev/tty ]; then
    log "No config file found; I'll ask a few questions and save answers to $CONFIG_FILE."
  fi

  hdr "Configuration"

  ask DOMAIN "Public domain (must already point an A/AAAA record at this server)" ""
  ask EMAIL  "Contact email for Let's Encrypt" ""

  if [ -z "$SECRET_PATH" ]; then
    SECRET_PATH="$(random_secret_path)"
    log "Generated secret admin path: $SECRET_PATH"
  fi

  ask ADMIN_USER "AdGuard admin username" "admin"
  ask_secret ADMIN_PASS "AdGuard admin password"

  # Persist the config (without clobbering an existing file's extra keys).
  if [ ! -f "$CONFIG_FILE" ] || ! grep -q '^DOMAIN=' "$CONFIG_FILE" 2>/dev/null; then
    umask 077
    {
      echo "# AdGuard stealth-DNS deploy config — generated $(date '+%F %T')"
      echo "# Keep this file private: it contains the admin password."
      printf 'DOMAIN=%q\n' "$DOMAIN"
      printf 'EMAIL=%q\n' "$EMAIL"
      printf 'SECRET_PATH=%q\n' "$SECRET_PATH"
      printf 'ADMIN_USER=%q\n' "$ADMIN_USER"
      printf 'ADMIN_PASS=%q\n' "$ADMIN_PASS"
      printf 'TIMEZONE=%q\n' "$TIMEZONE"
      printf 'SSH_PORT=%q\n' "$SSH_PORT"
      printf 'EXTRA_ALLOW=%q\n' "$EXTRA_ALLOW"
      printf 'SKIP_FIREWALL=%q\n' "$SKIP_FIREWALL"
      printf 'DO_UPGRADE=%q\n' "$DO_UPGRADE"
      printf 'ENABLE_DEFAULT_FILTERS=%q\n' "$ENABLE_DEFAULT_FILTERS"
      printf 'DECOY_URL=%q\n' "$DECOY_URL"
      printf 'ADGUARD_UPSTREAMS=%q\n' "$ADGUARD_UPSTREAMS"
      printf 'ADGUARD_BOOTSTRAP=%q\n' "$ADGUARD_BOOTSTRAP"
      printf 'ADGUARD_FALLBACK=%q\n' "$ADGUARD_FALLBACK"
    } >"$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Wrote $CONFIG_FILE (mode 600)"
  fi
fi

export DOMAIN EMAIL SECRET_PATH ADMIN_USER ADMIN_PASS TIMEZONE SSH_PORT \
       EXTRA_ALLOW SKIP_FIREWALL DO_UPGRADE ENABLE_DEFAULT_FILTERS DECOY_URL \
       ADGUARD_UPSTREAMS ADGUARD_BOOTSTRAP ADGUARD_FALLBACK \
       REPO_DIR SCRIPT_DIR STATE_DIR LOG_FILE

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
exec 9>"$STATE_DIR/.lock"
if ! flock -n 9; then die "Another deploy run is already in progress."; fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "$DO_UNINSTALL" = "yes" ]; then
  hdr "Uninstall"
  # shellcheck source=scripts/90-uninstall.sh
  source "$SCRIPT_DIR/scripts/90-uninstall.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
hdr "AdGuard stealth DNS — deploy"
log "Domain         : $DOMAIN"
log "Email          : $EMAIL"
log "Secret path    : $SECRET_PATH"
log "Admin user     : $ADMIN_USER"
log "Log file       : $LOG_FILE"
echo

for step in "${STEPS[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$step" ] && continue
  if step_skipped "$step"; then
    ok "Skipping $step (already done; use --force to redo)"
    continue
  fi
  hdr "Step $step"
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/scripts/$step.sh"
  mark_done "$step"
done

hdr "Done"
ok "Deployment complete."
echo
log "Admin URL : https://$DOMAIN$SECRET_PATH/"
log "DoH URL   : https://$DOMAIN/dns-query"
log "DoT host  : tls://$DOMAIN:853"
echo
log "Re-run any time; steps are idempotent. Use --force to redo all steps."
