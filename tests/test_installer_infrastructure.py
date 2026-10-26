"""Safe, unprivileged regression checks for installer infrastructure changes."""
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class InstallerInfrastructureTests(unittest.TestCase):
    def test_config_write_umask_is_scoped_and_file_is_private(self):
        source = (ROOT / "install.sh").read_text()
        self.assertRegex(source, r"(?s)\(\s*\n\s*umask 077\s*\n\s*\{.*?\} >\"\$CONFIG_FILE\"\s*\n\s*\)")
        self.assertIn('chmod 600 "$CONFIG_FILE"', source)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "deploy.env"
            subprocess.run(
                ["bash", "-c", 'umask 027; ( umask 077; printf secret >"$1" ); '
                 'chmod 600 "$1"; test "$(umask)" = 0027', "test", str(path)],
                check=True,
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_deploy_log_is_secured_before_first_log(self):
        source = (ROOT / "install.sh").read_text()
        secure = source.index("chmod 600 \"$LOG_FILE\"")
        first_log = source.index('log "Loading config')
        self.assertLess(secure, first_log)
        self.assertIn('Cannot secure deployment log', source)
        self.assertNotIn('LOG_FILE=/dev/null', source)

    def test_caddy_public_apt_files_are_readable_before_update(self):
        source = (ROOT / "scripts/30-caddy.sh").read_text()
        update = source.index("apt-get update")
        self.assertLess(source.index('chmod 644 "$KEYRING"'), update)
        self.assertLess(source.index('chmod 644 "$SOURCE"'), update)
        self.assertIn('[ ! -e "$KEYRING" ] || chmod 644', source)
        self.assertIn('[ ! -e "$SOURCE" ] || chmod 644', source)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            key = root / "keyring"
            repo = root / "source"
            script = source.replace("/usr/share/keyrings/caddy-stable-archive-keyring.gpg", str(key))
            script = script.replace("/etc/apt/sources.list.d/caddy-stable.list", str(repo))
            harness = r'''
set -euo pipefail
have_cmd() { return 1; }
log() { :; }; ok() { :; }; die() { echo "$*" >&2; exit 1; }
curl() { case "$*" in *gpg.key*) printf keydata;; *) printf 'deb source';; esac; }
gpg() { while [ $# -gt 0 ]; do [ "$1" != -o ] || { shift; printf keydata >"$1"; }; shift; done; }
apt-get() { test "$(stat -c %a "$KEYRING")" = 644; test "$(stat -c %a "$SOURCE")" = 644; echo "apt:$*"; }
caddy() { echo mocked; }
systemctl() { :; }
umask 077
''' + script
            completed = subprocess.run(["bash", "-c", harness], text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(key.stat().st_mode & 0o777, 0o644)
            self.assertEqual(repo.stat().st_mode & 0o777, 0o644)

            # Resume path repairs pre-existing restrictive modes as well.
            key.chmod(0o600)
            repo.chmod(0o600)
            resume = "have_cmd() { return 0; }; caddy() { echo mocked; }; systemctl() { :; }; log() { :; }; ok() { :; }; die() { exit 1; };\n" + script
            completed = subprocess.run(["bash", "-c", resume], text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(key.stat().st_mode & 0o777, 0o644)
            self.assertEqual(repo.stat().st_mode & 0o777, 0o644)

    def test_firewall_rules_precede_active_service_and_verify_status(self):
        source = (ROOT / "scripts/20-firewall.sh").read_text()
        self.assertLess(source.index('ufw allow 853/tcp'), source.index('ufw --force enable'))
        self.assertIn('systemctl enable --now ufw', source)
        self.assertIn("grep -q '^Status: active'", source)
        self.assertIn('systemctl is-active --quiet ufw.service', source)
        harness = r'''
set -euo pipefail
SKIP_FIREWALL=no ASSUME_YES=yes SSH_PORT=22 EXTRA_ALLOW='' VPN_FORWARDING=no
require_cmd() { :; }; log() { :; }; ok() { :; }; warn() { :; }
            die() { printf '%s\n' "$*" >&2; exit 1; }
ufw() { if [ "$1" = status ]; then printf 'Status: active\n'; fi; }
systemctl() { [ "$1" != is-active ]; }
ss() { :; }
source ''' + shlex.quote(str(ROOT / "scripts/20-firewall.sh")) + r'''
'''
        completed = subprocess.run(["bash", "-c", harness], text=True, capture_output=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("ufw.service is not active", completed.stderr)

    def test_certbot_hook_and_failure_diagnostics(self):
        source = (ROOT / "scripts/40-cert.sh").read_text()
        self.assertIn('systemctl enable --now certbot.timer', source)
        self.assertIn('Unable to enable and start certbot.timer', source)
        self.assertIn('if certbot certonly --standalone', source)
        self.assertIn('POST_HOOK="/bin/sh -c \'if [ -s /etc/caddy/Caddyfile ]', source)
        self.assertIn('CAA lookup SERVFAIL', source)
        self.assertIn('SERVFAIL', source)
        self.assertIn('ACME error', source)
        self.assertIn('TCP 80', source)
        self.assertIn('/var/log/letsencrypt/letsencrypt.log', source)
        self.assertIn('exit "$_certbot_status"', source)
        self.assertNotRegex(source, r'--(no-)?verify-ssl|--skip-.*verification')

        with tempfile.TemporaryDirectory() as tmp:
            live = Path(tmp) / "live" / "example.test"
            live.mkdir(parents=True)
            translated = source.replace("/etc/ssl/adguard", tmp + "/ssl")
            translated = translated.replace("/etc/letsencrypt/live", tmp + "/live")
            args = Path(tmp) / "certbot.args"
            harness = r'''
set -euo pipefail
DOMAIN=example.test EMAIL=ops@example.test REPO_DIR=''' + shlex.quote(str(ROOT)) + r'''
require_cmd() { :; }; log() { :; }; ok() { :; }
err() { printf '%s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
systemctl() { printf '%s\n' "$*" >>''' + shlex.quote(str(Path(tmp) / "systemctl.calls")) + r'''; }
            certbot() { printf '%s\n' "$@" >''' + shlex.quote(str(args)) + r'''; mkdir -p "''' + shlex.quote(str(live)) + r'''"; printf partial >"''' + shlex.quote(str(live / "fullchain.pem")) + r'''"; return 23; }
install() { mkdir -p "$4"; }
''' + translated
            completed = subprocess.run(["bash", "-c", harness], text=True, capture_output=True)
            self.assertEqual(completed.returncode, 23, completed.stderr)
            passed_args = args.read_text()
            self.assertIn("/bin/sh -c 'if [ -s /etc/caddy/Caddyfile ]", passed_args)
            self.assertIn("CAA lookup SERVFAIL", completed.stderr)
            self.assertIn("/var/log/letsencrypt/letsencrypt.log", completed.stderr)
            self.assertIn("enable --now certbot.timer", (Path(tmp) / "systemctl.calls").read_text())

    def test_existing_cert_repairs_only_legacy_post_hook(self):
        source = (ROOT / "scripts/40-cert.sh").read_text()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "letsencrypt/live/example.test"
            renewal = root / "letsencrypt/renewal/example.test.conf"
            hooks = root / "letsencrypt/renewal-hooks/deploy"
            live.mkdir(parents=True)
            renewal.parent.mkdir(parents=True)
            (live / "fullchain.pem").write_text("cert")
            (live / "privkey.pem").write_text("key")
            legacy_conf = f"version = 2\npre_hook = keep-this\npost_hook = if [ -f {root / 'caddy'}/Caddyfile ]; then systemctl start caddy || true; fi\nrenew_hook = preserve-this\n"
            renewal.write_text(legacy_conf)
            translated = source.replace("/etc/letsencrypt", str(root / "letsencrypt"))
            translated = translated.replace("/etc/ssl/adguard", str(root / "ssl"))
            translated = translated.replace("/etc/caddy", str(root / "caddy"))
            translated = translated.replace('\n"$HOOK"\n', '\nmock_deploy_hook\n')
            harness = r'''
set -euo pipefail
DOMAIN=example.test EMAIL=ops@example.test REPO_DIR=''' + shlex.quote(str(ROOT)) + r'''
require_cmd() { :; }; log() { :; }; ok() { :; }; warn() { printf '%s\n' "$*" >&2; }; err() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
systemctl() { :; }
toml_escape() { printf '%s' "$1"; }
mock_deploy_hook() { mkdir -p ''' + shlex.quote(str(root / "ssl")) + r'''; printf cert >''' + shlex.quote(str(root / "ssl/fullchain.pem")) + r'''; printf key >''' + shlex.quote(str(root / "ssl/privkey.pem")) + r'''; }
install() { command install "$@"; }
''' + translated
            completed = subprocess.run(["bash", "-c", harness], cwd=root, text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            updated = renewal.read_text()
            self.assertIn("pre_hook = keep-this", updated)
            self.assertIn("renew_hook = preserve-this", updated)
            self.assertIn("post_hook = /bin/sh -c", updated)
            self.assertIn("&& grep -q", updated)
            self.assertNotIn("post_hook = if ", updated)
            self.assertTrue((hooks / "adguard-shared-cert.sh").is_file())

            completed = subprocess.run(["bash", "-c", harness], cwd=root, text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("Leaving custom", completed.stderr)

            renewal.write_text(legacy_conf.replace(
                f"post_hook = if [ -f {root / 'caddy'}/Caddyfile ]; then systemctl start caddy || true; fi",
                "post_hook = /custom/renew-hook --keep",
            ))
            completed = subprocess.run(["bash", "-c", harness], cwd=root, text=True, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            custom = renewal.read_text()
            self.assertIn("post_hook = /custom/renew-hook --keep", custom)
            self.assertIn("pre_hook = keep-this", custom)
            self.assertIn("Leaving custom Certbot post-hook unchanged", completed.stderr)


if __name__ == "__main__":
    unittest.main()
