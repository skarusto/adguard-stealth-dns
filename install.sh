#!/usr/bin/env bash
set -Eeuo pipefail

SELF="${BASH_SOURCE[0]:-}"
_selfdir=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  _selfdir="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || _selfdir=""
fi

if [ -z "$_selfdir" ] || [ ! -f "$_selfdir/scripts/lib.sh" ]; then
  REPO="${REPO:-skarusto/adguard-stealth-dns}"
  BRANCH="${BRANCH:-main}"
  RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
  _tmpdir="$(mktemp -d /tmp/adguard-deploy.XXXXXX)"
  trap 'rm -rf "$_tmpdir"' EXIT
  echo "[bootstrap] Downloading $REPO@$BRANCH into $_tmpdir ..."
  _MANIFEST="install.sh
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
LICENSE"
  _files=""
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    _live="$(curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/git/trees/$BRANCH?recursive=1" 2>/dev/null | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin)
 print("\n".join(x["path"] for x in d.get("tree",[]) if x.get("type")=="blob"))
except Exception: pass
' 2>/dev/null)"
    [ -n "$_live" ] && _files="$_live"
  fi
  [ -n "$_files" ] || _files="$_MANIFEST"
  _fail=0
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    case "$_f" in
      /*|*..*)
        echo "!! refusing suspicious manifest path: $_f" >&2
        exit 1
        ;;
    esac
    mkdir -p "$_tmpdir/$(dirname "$_f")"
    if ! curl -fsSL --retry 3 --retry-delay 1 --max-time 60 "$RAW/$_f" -o "$_tmpdir/$_f" 2>/dev/null; then
      case "$_f" in
        docs/*|assets/*|README*|LICENSE) echo "[bootstrap] optional $_f not available, skipping." >&2 ;;
        *) echo "!! failed to download $_f" >&2; _fail=1 ;;
      esac
    fi
  done <<< "$_files"
  [ "$_fail" = "1" ] && exit 1
  chmod +x "$_tmpdir/install.sh"
  mkdir -p /etc/adguard-deploy
  export CONFIG_FILE="${CONFIG_FILE:-/etc/adguard-deploy/deploy.env}"
  _rc=0
  bash "$_tmpdir/install.sh" "$@" || _rc=$?
  rm -rf "$_tmpdir"
  exit "$_rc"
fi

SCRIPT_DIR="$_selfdir"
REPO_DIR="$SCRIPT_DIR"

#
# install.sh — one-command deployer for a stealth AdGuard Home DNS gateway:
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

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/deploy.env}"
ASSUME_YES="no"
FORCE="no"
ONLY=""
DO_UNINSTALL="no"

usage() {
  cat <<'EOF'
install.sh — one-command deployer for a stealth AdGuard Home DNS gateway:
public DoH + DoT only, hidden admin UI behind a secret path, decoy front site.

Usage:
  sudo ./install.sh                      # interactive, reads/creates deploy.env
  sudo ./install.sh --config my.env      # use a specific config file
  sudo DOMAIN=dns.example.com EMAIL=me@example.com ADMIN_PASS=secret ./install.sh --yes
  sudo ./install.sh --force              # re-run all steps even if already done
  sudo ./install.sh --only 70-caddyfile  # run a single step
  sudo ./install.sh --uninstall          # tear everything down
  sudo ./install.sh --help

Options:
  -c, --config FILE   Config file to read/write (default: $REPO_DIR/deploy.env)
  -y, --yes           Assume yes / non-interactive where possible
  -f, --force         Re-run steps even if already marked done
      --only STEP     Run only the named step (e.g. 70-caddyfile)
      --uninstall     Tear everything down
  -h, --help          Show this help
EOF
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

if [ -n "$ONLY" ]; then
  _only_ok="no"
  for _s in "${STEPS[@]}"; do
    if [ "$_s" = "$ONLY" ]; then _only_ok="yes"; break; fi
  done
  [ "$_only_ok" = "yes" ] || die "Unknown step: $ONLY (valid: ${STEPS[*]})"
fi

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
: "${VPN_FORWARDING:=no}"
: "${DO_UPGRADE:=no}"
: "${ENABLE_DEFAULT_FILTERS:=yes}"
: "${DECOY_URL:=}"
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

  # If there is no interactive tty, refuse to silently hang on prompts.
  if [ ! -r /dev/tty ] && [ "$ASSUME_YES" != "yes" ]; then
    die "No interactive terminal detected; cannot collect configuration. Re-run with \
         DOMAIN=... EMAIL=... ADMIN_PASS=... ./install.sh --yes  (or provide deploy.env)."
  fi

  ask DOMAIN "Public domain (must already point an A/AAAA record at this server)" ""
  ask EMAIL  "Contact email for Let's Encrypt" ""

  if [ -z "$SECRET_PATH" ]; then
    SECRET_PATH="$(random_secret_path)"
    log "Generated secret admin path: $SECRET_PATH"
  fi

  ask ADMIN_USER "AdGuard admin username" "admin"
  ask_secret ADMIN_PASS "AdGuard admin password"

  # Persist the config on every run (merge: keep unknown keys from an existing file).
  _known_keys='DOMAIN|EMAIL|SECRET_PATH|ADMIN_USER|ADMIN_PASS|TIMEZONE|SSH_PORT|EXTRA_ALLOW|SKIP_FIREWALL|VPN_FORWARDING|DO_UPGRADE|ENABLE_DEFAULT_FILTERS|DECOY_URL|ADGUARD_UPSTREAMS|ADGUARD_BOOTSTRAP|ADGUARD_FALLBACK'
  _extra=""
  if [ -f "$CONFIG_FILE" ]; then
    _extra="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE" 2>/dev/null \
      | grep -Ev "^(${_known_keys})=" 2>/dev/null || true)"
  fi
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
    printf 'VPN_FORWARDING=%q\n' "$VPN_FORWARDING"
    printf 'DO_UPGRADE=%q\n' "$DO_UPGRADE"
    printf 'ENABLE_DEFAULT_FILTERS=%q\n' "$ENABLE_DEFAULT_FILTERS"
    printf 'DECOY_URL=%q\n' "$DECOY_URL"
    printf 'ADGUARD_UPSTREAMS=%q\n' "$ADGUARD_UPSTREAMS"
    printf 'ADGUARD_BOOTSTRAP=%q\n' "$ADGUARD_BOOTSTRAP"
    printf 'ADGUARD_FALLBACK=%q\n' "$ADGUARD_FALLBACK"
    if [ -n "$_extra" ]; then
      printf '# Preserved extra keys from existing config:\n'
      printf '%s\n' "$_extra"
    fi
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "Wrote $CONFIG_FILE (mode 600)"
fi

export DOMAIN EMAIL SECRET_PATH ADMIN_USER ADMIN_PASS TIMEZONE SSH_PORT \
       EXTRA_ALLOW SKIP_FIREWALL VPN_FORWARDING DO_UPGRADE ENABLE_DEFAULT_FILTERS DECOY_URL \
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
  if ! source "$SCRIPT_DIR/scripts/$step.sh"; then
    die "Step $step failed. Fix the issue above and re-run (use --force to redo)."
  fi
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
