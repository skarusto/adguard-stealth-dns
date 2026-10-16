#!/usr/bin/env bash
# lib.sh — shared helpers for the AdGuard stealth-DNS deployer.
# Sourced by install.sh and every step script. Not meant to be executed directly.

# ---------------------------------------------------------------------------
# Colours / logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=
fi

LOG_FILE="${LOG_FILE:-/var/log/adguard-deploy.log}"

_log() { # level colour msg...
  local level="$1" colour="$2"; shift 2
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts] [$level] $*"
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  printf '%s%s%s%s%s\n' "$colour" "$C_BOLD" "$*" "$C_RESET" "" >&2
}
log()  { _log INFO  "$C_BLUE"   "$@"; }
ok()   { _log OK    "$C_GREEN"  "$@"; }
warn() { _log WARN  "$C_YELLOW" "$@"; }
err()  { _log ERROR "$C_RED"    "$@"; }
die()  { err "$@"; exit 1; }

hdr() { # section banner
  local t=" $* "
  local n=${#t}
  local line; printf -v line '%*s' "$n" ''; line=${line// /─}
  { printf '\n%s┌%s┐%s\n' "$C_DIM" "$line" "$C_RESET"
    printf '%s│%s%s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$t" "$C_DIM" "$C_RESET"
    printf '%s└%s┘%s\n' "$C_DIM" "$line" "$C_RESET"; } >&2
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i)."; }

require_cmd() { have_cmd "$1" || die "Required command not found: $1"; }

# Render a template: replaces every __KEY__ token with the value of KEY.
# Usage: render_template <in> <out>
render_template() {
  local in="$1" out="$2" k v
  local content; content="$(cat "$in")"
  for k in "${!TEMPLATE_VARS[@]}"; do
    v="${TEMPLATE_VARS[$k]}"
    content="${content//__${k}__/$v}"
  done
  printf '%s\n' "$content" >"$out"
}

toml_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

# Non-interactive-safe prompt. Reads from /dev/tty when available.
# Usage: ask <varname> "<prompt>" [default]
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __answer=""
  if [ -n "${!__var:-}" ]; then return 0; fi
  if [ "${ASSUME_YES:-no}" = "yes" ] && [ -n "$__default" ]; then
    printf -v "$__var" '%s' "$__default"; return 0
  fi
  if [ -r /dev/tty ]; then
    if [ -n "$__default" ]; then
      printf '%s [%s]: ' "$__prompt" "$__default" >/dev/tty
    else
      printf '%s: ' "$__prompt" >/dev/tty
    fi
    IFS= read -r __answer </dev/tty || true
  fi
  [ -z "$__answer" ] && __answer="$__default"
  [ -n "$__answer" ] || die "No value provided for: $__prompt"
  printf -v "$__var" '%s' "$__answer"
}

ask_secret() {
  local __var="$1" __prompt="$2" __answer=""
  if [ -n "${!__var:-}" ]; then return 0; fi
  if [ -r /dev/tty ]; then
    printf '%s: ' "$__prompt" >/dev/tty
    IFS= read -r -s __answer </dev/tty || true
    printf '\n' >/dev/tty
  fi
  [ -n "$__answer" ] || die "No value provided for: $__prompt"
  printf -v "$__var" '%s' "$__answer"
}

# ---------------------------------------------------------------------------
# System discovery
# ---------------------------------------------------------------------------
detect_public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null)" \
    || ip="$(curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null)" \
    || ip="$(curl -fsS --max-time 8 https://icanhazip.com 2>/dev/null)" \
    || true
  printf '%s' "${ip//[$'\r\n']/}"
}

detect_ssh_port() {
  local p=""
  if [ -n "${SSH_CONNECTION:-}" ]; then
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
  fi
  if [ -z "$p" ] && have_cmd ss; then
    p="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -1)"
  fi
  [ -z "$p" ] && p=22
  printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# Idempotency markers
# ---------------------------------------------------------------------------
STATE_DIR="${STATE_DIR:-/var/lib/adguard-deploy}"
marker_done()  { [ -f "$STATE_DIR/done.$1" ]; }
mark_done()    { mkdir -p "$STATE_DIR"; date '+%F %T' >"$STATE_DIR/done.$1"; }
step_skipped() { marker_done "$1" && [ "${FORCE:-no}" != "yes" ]; }

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------
port_in_use() { # port_in_use <port>  -> 0 if something listens
  have_cmd ss || return 1
  ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

wait_service_active() { # wait_service_active <unit> <seconds>
  local unit="$1" secs="${2:-30}" i
  for i in $(seq 1 "$secs"); do
    systemctl is-active --quiet "$unit" && return 0
    sleep 1
  done
  return 1
}

random_secret_path() { printf '/%s' "$(openssl rand -hex 8)"; }
