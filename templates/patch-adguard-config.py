#!/usr/bin/env python3
"""
patch-adguard-config.py — safely patch an existing AdGuardHome.yaml.

Design: we take an AdGuard-generated config and change ONLY the keys we care
about, so the binary's own schema_version and defaults are preserved and no
migration is triggered. Values come from environment variables (see below).

Env vars (all optional; unset ones are left untouched):
  ADG_HTTP_ADDRESS        e.g. "127.0.0.1:3000"
  ADG_SERVE_PLAIN_DNS     "true" | "false"
  ADG_TLS_ENABLED         "true" | "false"
  ADG_TLS_SERVER_NAME     hostname
  ADG_TLS_CERT            path to fullchain.pem
  ADG_TLS_KEY             path to privkey.pem
  ADG_TLS_PORT_HTTPS      int (0 = do not listen)
  ADG_TLS_PORT_DOT        int (e.g. 853)
  ADG_TLS_PORT_DOQ        int (0 = off)
  ADG_ADMIN_USER          username
  ADG_ADMIN_HASH          bcrypt hash for that user
  ADG_UPSTREAMS           newline-separated upstream entries
  ADG_BOOTSTRAP           newline-separated bootstrap servers
  ADG_FALLBACK            newline-separated fallback servers
  ADG_ENABLE_FILTERS      "yes" to enable the stock AdGuard DNS filter

Also optionally merges functional settings from another config:
  ADG_MERGE_FROM          path to a source AdGuardHome.yaml
"""
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("python3-yaml is required (apt-get install python3-yaml)\n")
    sys.exit(3)

PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/AdGuardHome/AdGuardHome.yaml"

with open(PATH, "r", encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh) or {}


def env(name):
    v = os.environ.get(name)
    return v if v not in (None, "") else None


def as_bool(name):
    v = env(name)
    if v is None:
        return None
    return v.strip().lower() in ("1", "true", "yes", "on")


def as_int(name):
    v = env(name)
    return None if v is None else int(v)


def lines(name):
    v = env(name)
    if v is None:
        return None
    return [ln for ln in v.splitlines() if ln.strip()]


# --- http -----------------------------------------------------------------
http = cfg.setdefault("http", {})
if (addr := env("ADG_HTTP_ADDRESS")):
    http["address"] = addr
doh = http.setdefault("doh", {})
# Behind a TLS-terminating reverse proxy AdGuard must accept plain-HTTP DoH.
doh["enabled"] = True
doh["insecure_enabled"] = True

# --- dns ------------------------------------------------------------------
dns = cfg.setdefault("dns", {})
if (spd := as_bool("ADG_SERVE_PLAIN_DNS")) is not None:
    dns["serve_plain_dns"] = spd
if (ups := lines("ADG_UPSTREAMS")) is not None:
    dns["upstream_dns"] = ups
if (bs := lines("ADG_BOOTSTRAP")) is not None:
    dns["bootstrap_dns"] = bs
if (fb := lines("ADG_FALLBACK")) is not None:
    dns["fallback_dns"] = fb

# --- tls ------------------------------------------------------------------
tls = cfg.setdefault("tls", {})
if (v := as_bool("ADG_TLS_ENABLED")) is not None:
    tls["enabled"] = v
if (v := env("ADG_TLS_SERVER_NAME")):
    tls["server_name"] = v
if (v := env("ADG_TLS_CERT")):
    tls["certificate_path"] = v
if (v := env("ADG_TLS_KEY")):
    tls["private_key_path"] = v
if (v := as_int("ADG_TLS_PORT_HTTPS")) is not None:
    tls["port_https"] = v
if (v := as_int("ADG_TLS_PORT_DOT")) is not None:
    tls["port_dns_over_tls"] = v
if (v := as_int("ADG_TLS_PORT_DOQ")) is not None:
    tls["port_dns_over_quic"] = v

# --- admin user -----------------------------------------------------------
user = env("ADG_ADMIN_USER")
pwd_hash = env("ADG_ADMIN_HASH")
if user and pwd_hash:
    users = cfg.get("users")
    if not isinstance(users, list) or not users:
        users = [{}]
    entry = users[0] if isinstance(users[0], dict) else {}
    entry["name"] = user
    entry["password"] = pwd_hash
    users[0] = entry
    cfg["users"] = users

# --- optional: enable the stock AdGuard DNS filter ------------------------
if (as_bool("ADG_ENABLE_FILTERS") is True):
    filters = cfg.setdefault("filters", [])
    found = False
    for flt in filters:
        if not isinstance(flt, dict):
            continue
        if flt.get("id") == 1 or flt.get("name") == "AdGuard DNS filter":
            flt["enabled"] = True
            flt.setdefault("url", "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt")
            found = True
    if not found:
        filters.insert(0, {
            "enabled": True,
            "url": "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt",
            "name": "AdGuard DNS filter",
            "id": 1,
        })

# --- optional: merge functional settings from an older config -------------
src = env("ADG_MERGE_FROM")
if src and os.path.isfile(src):
    old = yaml.safe_load(open(src, "r", encoding="utf-8")) or {}

    def take(section, keys):
        if section not in old or not isinstance(old[section], dict):
            return
        dst = cfg.setdefault(section, {})
        for k in keys:
            if k in old[section]:
                dst[k] = old[section][k]

    take("dns", ["upstream_dns", "upstream_mode", "bootstrap_dns", "fallback_dns",
                 "ratelimit", "ratelimit_subnet_len_ipv4", "ratelimit_subnet_len_ipv6",
                 "cache_size", "blocked_hosts", "enable_dnssec", "upstream_timeout",
                 "refuse_any", "edns_cs_enabled", "disable_ipv6"])
    take("filtering", ["filters", "whitelist_filters", "user_rules", "safe_search",
                       "safe_browsing", "parental", "rewrites", "blocked_services"])
    # Deliberately NOT imported: users, tls, http.address, dns.bind_hosts,
    # dns.port, dns.serve_plain_dns, schema_version.

with open(PATH, "w", encoding="utf-8") as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False, allow_unicode=True, default_flow_style=False)

print("patched", PATH)
