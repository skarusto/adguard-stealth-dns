"""Focused, isolated regression tests for provisioning shell steps."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


class ProvisioningTests(unittest.TestCase):
    def test_private_modes_are_scoped_and_ssh_is_resolved_in_parent(self):
        installer = (ROOT / "install.sh").read_text()
        cfg = installer.index("  umask 077")
        self.assertGreater(installer.index("  (", installer.index("_extra=\"\"")), 0)
        self.assertGreater(installer.index("  )", cfg), cfg)
        self.assertIn('chmod 600 "$CONFIG_FILE"', installer)
        self.assertIn('chmod 600 "$LOG_FILE"', installer)
        parent_detection = installer.index('SSH_PORT="$(detect_ssh_port)"')
        config_save = installer.index('>"$CONFIG_FILE"')
        self.assertLess(parent_detection, config_save)
        self.assertIn("Invalid SSH_PORT", installer)
        self.assertIn('Missing DOMAIN;', installer)
        self.assertIn('Missing EMAIL;', installer)
        self.assertIn('Missing ADMIN_PASS;', installer)
        self.assertNotIn('log "Admin URL : https://$DOMAIN$SECRET_PATH/', installer)
        manifest = installer.split('_MANIFEST="', 1)[1].split('"', 1)[0]
        self.assertIn("templates/initialize-adguard.py", manifest)
        self.assertIn("README.en.md", manifest)
        self.assertNotIn("README.ru.md", manifest)
        self.assertIn("docs/AGENT_INSTALL.md", manifest)
        if (ROOT / "docs/TROUBLESHOOTING.md").exists():
            self.assertIn("docs/TROUBLESHOOTING.md", manifest)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "deploy.env"
            result = run([
                "bash", "-c",
                'umask 077; ( umask 077; printf "ADMIN_PASS=secret\\n" >"$1" ); '
                'chmod 600 "$1"; test "$(stat -c %a "$1")" = 600; '
                'test "$(umask)" = 0077', "test", str(path),
            ])
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_preflight_dns_failure_is_actionable_under_errexit(self):
        text = (ROOT / "scripts/00-preflight.sh").read_text()
        self.assertIn('if ! RESOLVED="$(timeout 15 getent', text)
        self.assertIn("DNS lookup for '$DOMAIN' failed or timed out", text)

    def test_caddy_repository_files_are_public_before_apt_update(self):
        text = (ROOT / "scripts/30-caddy.sh").read_text()
        chmod_key = text.index('chmod 644 "$KEYRING"')
        chmod_source = text.index('chmod 644 "$SOURCE"')
        update = text.index("apt-get update")
        self.assertLess(chmod_key, update)
        self.assertLess(chmod_source, update)
        self.assertIn("NO_PUBKEY", text)
        self.assertNotRegex(text, r"allow-unauthenticated|trusted=yes|AllowInsecure")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            key = root / "keyring.gpg"
            source = root / "caddy.list"
            script = text.replace("/usr/share/keyrings/caddy-stable-archive-keyring.gpg", str(key))
            script = script.replace("/etc/apt/sources.list.d/caddy-stable.list", str(source))
            script_path = root / "30-caddy.sh"
            script_path.write_text(script)
            mockbin = root / "bin"
            mockbin.mkdir()
            (mockbin / "curl").write_text(
                '#!/bin/sh\ncase "$*" in *gpg.key*) printf keydata;; *) printf "deb source\\n";; esac\n'
            )
            (mockbin / "gpg").write_text(
                '#!/bin/sh\nwhile [ "$#" -gt 0 ]; do '
                '[ "$1" != -o ] || { shift; printf keydata >"$1"; }; shift; done\n'
            )
            (mockbin / "apt-get").write_text(
                '#!/bin/sh\n'
                'test "$(stat -c %a "$KEYRING")" = 644 || exit 41\n'
                'test "$(stat -c %a "$SOURCE")" = 644 || exit 42\n'
                'echo "apt-get $*" >>"$CALL_LOG"\n'
            )
            (mockbin / "systemctl").write_text('#!/bin/sh\nexit 0\n')
            (mockbin / "caddy").write_text('#!/bin/sh\necho mocked\n')
            for executable in mockbin.iterdir():
                executable.chmod(0o755)
            harness = (
                'set -Eeuo pipefail; log(){ :; }; ok(){ :; }; '
                'die(){ printf "%s\\n" "$*" >&2; exit 1; }; '
                'have_cmd(){ [ "$CADDY_INSTALLED" = yes ]; }; '
                'source "$STEP_FILE"'
            )
            env = os.environ.copy()
            env.update(
                PATH=f"{mockbin}:{env['PATH']}", KEYRING=str(key), SOURCE=str(source),
                STEP_FILE=str(script_path), CALL_LOG=str(root / "calls"),
                CADDY_INSTALLED="no",
            )
            first = run(["bash", "-c", "umask 077; " + harness], env=env)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(key.stat().st_mode & 0o777, 0o644)
            self.assertEqual(source.stat().st_mode & 0o777, 0o644)
            self.assertEqual((root / "calls").read_text().count("apt-get"), 2)

            # An interrupted earlier run can leave both files at 0600; resume
            # repairs modes before using an already-installed Caddy package.
            key.chmod(0o600)
            source.chmod(0o600)
            env["CADDY_INSTALLED"] = "yes"
            resumed = run(["bash", "-c", "umask 077; " + harness], env=env)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertEqual(key.stat().st_mode & 0o777, 0o644)
            self.assertEqual(source.stat().st_mode & 0o777, 0o644)

    def test_preflight_getent_failure_runs_and_prints_guidance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mockbin = root / "bin"
            mockbin.mkdir()
            (mockbin / "curl").write_text('#!/bin/sh\nprintf "192.0.2.5\\n"\n')
            (mockbin / "getent").write_text('#!/bin/sh\nexit 2\n')
            (mockbin / "timeout").write_text('#!/bin/sh\nshift; exec "$@"\n')
            for executable in mockbin.iterdir():
                executable.chmod(0o755)
            harness = r'''
set -Eeuo pipefail
require_cmd() { :; }
log() { :; }; ok() { :; }; warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
DOMAIN=example.test ASSUME_YES=yes
port_in_use() { return 1; }
source "$STEP_FILE"
'''
            env = os.environ.copy()
            env.update(PATH=f"{mockbin}:{env['PATH']}", STEP_FILE=str(ROOT / "scripts/00-preflight.sh"))
            result = run(["bash", "-c", harness], env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("DNS lookup for 'example.test' failed or timed out", result.stderr)
            self.assertIn("Check the domain's A record and DNS resolver/network", result.stderr)

    def test_installer_propagates_ssh_port_and_preserves_umask_safely(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            scripts = repo / "scripts"
            scripts.mkdir(parents=True)
            installer_copy = repo / "install.sh"
            installer_copy.write_text((ROOT / "install.sh").read_text())
            installer_copy.chmod(0o755)
            (scripts / "lib.sh").write_text((ROOT / "scripts/lib.sh").read_text())
            (scripts / "20-firewall.sh").write_text((ROOT / "scripts/20-firewall.sh").read_text())
            mockbin = root / "bin"
            mockbin.mkdir()
            mocks = {
                "id": '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n',
                "chown": '#!/bin/sh\nexit 0\n',
                "stat": '#!/bin/sh\ncase "$*" in *%a:%u*) echo 600:0;; *) exec /usr/bin/stat "$@";; esac\n',
                "flock": '#!/bin/sh\nexit 0\n',
                "ss": '#!/bin/sh\nexit 0\n',
                "ufw": '#!/bin/sh\necho "ufw $*" >>"$CALL_LOG"\n'
                       'if [ "$1" = status ]; then echo "Status: active"; fi\n',
                "systemctl": '#!/bin/sh\necho "systemctl $*" >>"$CALL_LOG"\nexit 0\n',
            }
            for name, content in mocks.items():
                path = mockbin / name
                path.write_text(content)
                path.chmod(0o755)
            config = root / "deploy.env"
            logfile = root / "deploy.log"
            state = root / "state"
            calls = root / "firewall-calls"
            env = os.environ.copy()
            env.update(
                PATH=f"{mockbin}:{env['PATH']}",
                SSH_CONNECTION="198.51.100.7 55123 192.0.2.10 2222",
                DOMAIN="example.test", EMAIL="ops@example.test", ADMIN_PASS="not-a-real-secret",
                CONFIG_FILE=str(config), LOG_FILE=str(logfile), STATE_DIR=str(state),
                CALL_LOG=str(calls),
            )
            env.pop("SSH_PORT", None)
            command = [
                "bash", "-c",
                'umask 022; ./install.sh --yes --only 20-firewall; rc=$?; '
                'printf "PARENT_UMASK=%s\\n" "$(umask)"; exit "$rc"',
            ]
            result = run(command, cwd=repo, env=env, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PARENT_UMASK=0022", result.stdout)
            saved = config.read_text()
            self.assertIn("SSH_PORT=2222", saved)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertEqual(logfile.stat().st_mode & 0o777, 0o600)
            self.assertIn("ufw allow 2222/tcp comment SSH", calls.read_text())
            secret_path = next(line.split("=", 1)[1] for line in saved.splitlines() if line.startswith("SECRET_PATH="))
            self.assertNotIn(secret_path, result.stdout + result.stderr)

            # --yes must fail promptly for absent required configuration, not prompt.
            missing_env = env.copy()
            missing_env.pop("DOMAIN")
            missing_env.pop("EMAIL")
            missing_env.pop("ADMIN_PASS")
            missing_env["CONFIG_FILE"] = str(root / "missing.env")
            missing = run(["bash", "-c", 'umask 022; ./install.sh --yes --only 20-firewall'],
                          cwd=repo, env=missing_env, timeout=5)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("Missing DOMAIN", missing.stderr)

    def test_firewall_starts_and_verifies_systemd_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "calls"
            (bin_dir / "ufw").write_text(
                '#!/bin/sh\necho "ufw $*" >>"$CALL_LOG"\n'
                'if [ "$1" = status ]; then echo "Status: active"; fi\n'
            )
            (bin_dir / "systemctl").write_text(
                '#!/bin/sh\necho "systemctl $*" >>"$CALL_LOG"\nexit 0\n'
            )
            (bin_dir / "ss").write_text('#!/bin/sh\nexit 0\n')
            for script in bin_dir.iterdir():
                script.chmod(0o755)
            harness = r'''
set -Eeuo pipefail
require_cmd() { :; }
log() { :; }; ok() { :; }; warn() { :; }; err() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
SKIP_FIREWALL=no ASSUME_YES=yes SSH_PORT=2222 EXTRA_ALLOW= VPN_FORWARDING=no
source "$STEP_FILE"
'''
            env = os.environ.copy()
            env.update(PATH=f"{bin_dir}:{env['PATH']}", CALL_LOG=str(log),
                       STEP_FILE=str(ROOT / "scripts/20-firewall.sh"))
            result = run(["bash", "-c", harness], env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text().splitlines()
            self.assertIn("ufw --force enable", calls)
            self.assertIn("systemctl enable --now ufw", calls)
            self.assertIn("systemctl is-active --quiet ufw.service", calls)
            self.assertLess(calls.index("ufw --force enable"), calls.index("systemctl enable --now ufw"))

    def _cert_sandbox(self, root, certbot_status=0):
        substitutions = {
            "/etc/ssl/adguard": str(root / "etc/ssl/adguard"),
            "/etc/letsencrypt": str(root / "etc/letsencrypt"),
            "/etc/caddy/Caddyfile": str(root / "etc/caddy/Caddyfile"),
            "/var/log/letsencrypt/letsencrypt.log": str(root / "var/log/letsencrypt/letsencrypt.log"),
        }
        script = (ROOT / "scripts/40-cert.sh").read_text()
        template = (ROOT / "templates/adguard-shared-cert.sh").read_text()
        for original, replacement in substitutions.items():
            script = script.replace(original, replacement)
            template = template.replace(original, replacement)
        generated = root / "40-cert.sh"
        generated.write_text(script)
        template_path = root / "adguard-shared-cert.sh"
        template_path.write_text(template)
        mockbin = root / "bin"
        mockbin.mkdir()
        calls = root / "systemctl-calls"
        (mockbin / "systemctl").write_text(
            '#!/bin/sh\necho "$*" >>"$CALL_LOG"\nexit 0\n'
        )
        (mockbin / "install").write_text(
            '#!/bin/sh\nmode=755; directory=no; positional=\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  case "$1" in\n'
            '    -d) directory=yes; shift ;;\n'
            '    -m) mode=$2; shift 2 ;;\n'
            '    -o|-g) shift 2 ;;\n'
            '    *) positional="$positional $1"; shift ;;\n'
            '  esac\n'
            'done\n'
            'set -- $positional\n'
            'if [ "$directory" = yes ]; then mkdir -p "$1"; chmod "$mode" "$1"; '
            'else cp "$1" "$2"; chmod "$mode" "$2"; fi\n'
        )
        certbot = mockbin / "certbot"
        certbot.write_text(
            '#!/bin/sh\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = --post-hook ]; then printf "%s\\n" "$2" >"$HOOK_FILE"; shift 2; continue; fi\n'
            '  shift\n'
            'done\n'
            'mkdir -p "$CERT_LIVE"\n'
            'printf cert >"$CERT_LIVE/fullchain.pem"\n'
            'printf key >"$CERT_LIVE/privkey.pem"\n'
            'exit "$CERTBOT_STATUS"\n'
        )
        for command in mockbin.iterdir():
            command.chmod(0o755)
        cert_live = root / "etc/letsencrypt/live/example.test"
        env = os.environ.copy()
        env.update(
            PATH=f"{mockbin}:{env['PATH']}", CALL_LOG=str(calls),
            HOOK_FILE=str(root / "post-hook"), CERTBOT_STATUS=str(certbot_status),
            WARN_LOG=str(root / "warnings"),
            CERT_LIVE=str(cert_live), DOMAIN="example.test", EMAIL="admin@example.test",
            REPO_DIR=str(root), TEMPLATE_PATH=str(template_path),
        )
        # Keep the transformed script's template lookup inside the sandbox.
        generated.write_text(generated.read_text().replace(
            '"$REPO_DIR/templates/adguard-shared-cert.sh"', '"$TEMPLATE_PATH"'))
        return generated, env, root / "post-hook", calls, cert_live

    def test_certbot_hook_validation_and_conditional_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script, env, hook_file, calls, cert_live = self._cert_sandbox(root)
            command = ["bash", "-c", 'set -Eeuo pipefail; require_cmd(){ :; }; toml_escape(){ printf "%s" "$1"; }; log(){ :; }; ok(){ :; }; warn(){ printf "%s\\n" "$*" >>"$WARN_LOG"; }; err(){ printf "%s\\n" "$*" >&2; }; die(){ printf "%s\\n" "$*" >&2; exit 1; }; source "$1"', "test", str(script)]
            result = run(command, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            hook = hook_file.read_text().strip()
            self.assertTrue(hook.startswith("/bin/sh -c "), hook)
            # A package-default Caddyfile is insufficient; no shared certificate means no restart.
            caddyfile = root / "etc/caddy/Caddyfile"
            caddyfile.parent.mkdir(parents=True, exist_ok=True)
            caddyfile.write_text("default site")
            hook_result = run(["/bin/sh", "-c", hook], env=env)
            self.assertEqual(hook_result.returncode, 0, hook_result.stderr)
            self.assertNotIn("restart caddy", calls.read_text())
            # Only a deployed shared-cert config and the shared cert/key cause restart.
            shared = root / "etc/ssl/adguard"
            shared.mkdir(parents=True, exist_ok=True)
            (shared / "fullchain.pem").write_text("cert")
            (shared / "privkey.pem").write_text("key")
            caddyfile.write_text(f"tls {shared}/fullchain.pem {shared}/privkey.pem")
            run(["/bin/sh", "-c", hook], env=env, check=True)
            self.assertIn("restart caddy", calls.read_text())

            # A normal resume with an existing certificate repairs old renewal
            # settings instead of relying on issuance to rewrite them.
            renewal = root / "etc/letsencrypt/renewal/example.test.conf"
            renewal.parent.mkdir(parents=True, exist_ok=True)
            renewal.write_text(
                f"post_hook = if [ -f {root / 'etc/caddy/Caddyfile'} ]; "
                "then systemctl start caddy || true; fi\n"
            )
            resumed = run(command, env=env)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertIn("post_hook = /bin/sh -c 'if", renewal.read_text())
            self.assertNotIn("custom Certbot post-hook", env["WARN_LOG"].read_text() if Path(env["WARN_LOG"]).exists() else "")

            renewal.write_text("post_hook = systemctl start caddy || true\n")
            plain_legacy_resume = run(command, env=env)
            self.assertEqual(plain_legacy_resume.returncode, 0, plain_legacy_resume.stderr)
            self.assertIn("post_hook = /bin/sh -c 'if", renewal.read_text())

            # The exact current hook is an idempotent no-op, while a genuinely
            # custom command is preserved and reported rather than overwritten.
            env["WARN_LOG"] = str(root / "warnings")
            Path(env["WARN_LOG"]).write_text("")
            current = renewal.read_text()
            current_resume = run(command, env=env)
            self.assertEqual(current_resume.returncode, 0, current_resume.stderr)
            self.assertEqual(renewal.read_text(), current)
            self.assertEqual(Path(env["WARN_LOG"]).read_text(), "")

            renewal.write_text("post_hook = echo operator-custom-command\n")
            custom_resume = run(command, env=env)
            self.assertEqual(custom_resume.returncode, 0, custom_resume.stderr)
            self.assertEqual(renewal.read_text(), "post_hook = echo operator-custom-command\n")
            self.assertIn("Leaving custom Certbot post-hook unchanged", Path(env["WARN_LOG"]).read_text())

    def test_certbot_failure_reports_acme_and_log_without_forcing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script, env, _hook, _calls, _live = self._cert_sandbox(root, certbot_status=1)
            result = run(["bash", "-c", 'set -Eeuo pipefail; require_cmd(){ :; }; toml_escape(){ printf "%s" "$1"; }; log(){ :; }; ok(){ :; }; err(){ printf "%s\\n" "$*" >&2; }; die(){ printf "%s\\n" "$*" >&2; exit 1; }; source "$1"', "test", str(script)], env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ACME error", result.stderr)
            self.assertIn("CAA lookup SERVFAIL", result.stderr)
            self.assertIn("/var/log/letsencrypt/letsencrypt.log", result.stderr)
            self.assertIn("resume normally", result.stderr)
            self.assertIn("--force is not required", result.stderr)


if __name__ == "__main__":
    unittest.main()
