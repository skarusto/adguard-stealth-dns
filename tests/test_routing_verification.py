"""Safe regressions for secret-path routing and smoke-check diagnostics."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SECRET = "/private-token"


class RoutingVerificationTests(unittest.TestCase):
    def test_smoke_verifier_under_strict_shell_with_mocked_services(self):
        failures = {
            "wrong_location": "secret path form expected 302",
            "bare_200": "secret path form expected 302",
            "login_decoy": "prefixed login page expected Login page",
            "curl_transport": "expected 200",
            "socket_refused": "no DoT TLS connection/certificate received",
            "hostname_mismatch": "DoT certificate hostname mismatch",
            "timeout_no_output": "no DoT TLS connection/certificate received",
        }
        for mode, expected in failures.items():
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                tmp = Path(temp)
                bindir = tmp / "bin"
                bindir.mkdir()
                self._write_mock_commands(bindir)
                state = tmp / "state"
                state.mkdir()
                marker = state / "done.80-verify"
                marker.write_text("stale marker\n")
                config = tmp / "AdGuardHome.yaml"
                config.write_text("dns:\n  serve_plain_dns: false\nhttp:\n  address: 127.0.0.1:3000\n")
                env = os.environ | {
                    "PATH": f"{bindir}:{os.environ['PATH']}",
                    "MOCK_MODE": mode,
                    "TEST_STATE": str(state),
                    "TEST_CONFIG": str(config),
                    "VERIFY_SCRIPT": str(ROOT / "scripts/80-verify.sh"),
                }
                result = subprocess.run(["bash", "-c", self._strict_harness()], env=env,
                                         text=True, capture_output=True)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(expected, result.stdout)
                self.assertFalse(marker.exists(), "failure must clear stale success marker")
                self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_smoke_verifier_accepts_good_mocked_services_under_strict_shell(self):
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            bindir = tmp / "bin"
            bindir.mkdir()
            self._write_mock_commands(bindir)
            config = tmp / "AdGuardHome.yaml"
            config.write_text("dns:\n  serve_plain_dns: false\nhttp:\n  address: 127.0.0.1:3000\n")
            env = os.environ | {
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "MOCK_MODE": "success",
                "TEST_STATE": str(tmp / "state"),
                "TEST_CONFIG": str(config),
                "VERIFY_SCRIPT": str(ROOT / "scripts/80-verify.sh"),
            }
            result = subprocess.run(["bash", "-c", self._strict_harness()], env=env,
                                     text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("secret path form redirects", result.stdout)
            self.assertIn("prefixed login page serves Login page (200, no redirect)", result.stdout)
            self.assertIn("DoT certificate chain trusted and hostname verified", result.stdout)
            self.assertNotIn(SECRET, result.stdout + result.stderr)

    @staticmethod
    def _strict_harness():
        return r'''set -Eeuo pipefail
DOMAIN=example.test SECRET_PATH=/private-token STATE_DIR="$TEST_STATE" AG_CFG="$TEST_CONFIG" SKIP_FIREWALL=yes
detect_public_ip() { printf '192.0.2.1'; }
warn() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "$*"; }
log() { :; }
mark_done() { :; }
source "$VERIFY_SCRIPT"
'''

    @staticmethod
    def _write_mock_commands(bindir):
        commands = {
            "curl": r'''#!/usr/bin/env python3
import os, sys
mode = os.environ['MOCK_MODE']
args = sys.argv[1:]
url = args[-1]
output = args[args.index('-o') + 1] if '-o' in args else None
if mode == 'curl_transport':
    sys.exit(7)
if url.endswith('/private-token') or url.endswith('/private-token/'):
    status = '302'
    location = 'https://example.test/private-token/login.html'
    if mode == 'bare_200' and url.endswith('/private-token'):
        status = '200'
    if mode == 'wrong_location' and url.endswith('/private-token'):
        location = 'https://example.test/private-token/'
    print(status + ('\t' + location if 'redirect_url' in ' '.join(args) else ''))
    body = b''
elif url.endswith('/private-token/login.html'):
    print('200')
    body = b'<title>Decoy page</title>' if mode == 'login_decoy' else b'<title>Login</title>'
elif '/dns-query?' in url:
    print('200')
    body = (b'\x00\x00\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00'
            b'\x07example\x03com\x00\x00\x01\x00\x01'
            b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x01\x02\x03\x04')
else:
    print('200')
    body = b''
if output and output != '/dev/null':
    open(output, 'wb').write(body)
''',
            "getent": "#!/bin/sh\nexit 0\n",
            "ss": "#!/bin/sh\nprintf 'LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*\\nLISTEN 0 128 0.0.0.0:853 0.0.0.0:*\\n'\n",
            "systemctl": "#!/bin/sh\nexit 0\n",
            "timeout": "#!/bin/sh\nshift; exec \"$@\"\n",
            "openssl": r'''#!/bin/sh
case "$MOCK_MODE" in
  socket_refused) echo 'connect:errno=111'; exit 1 ;;
  hostname_mismatch) echo 'verify error:num=62:hostname mismatch'; exit 1 ;;
  timeout_no_output) exit 124 ;;
  *) echo 'Verification: OK'; exit 0 ;;
esac
''',
        }
        for name, content in commands.items():
            path = bindir / name
            path.write_text(content)
            path.chmod(0o755)

    def test_caddy_adapt_redirect_json_and_route_order(self):
        caddy = shutil.which("caddy") or "/tmp/opencode/adguard-stealth-verification/caddy"
        if not Path(caddy).is_file():
            self.skipTest("Caddy binary unavailable")
        with tempfile.TemporaryDirectory() as temp:
            rendered = (ROOT / "templates/Caddyfile").read_text()
            for token, value in {"__DOMAIN__": "example.test", "__EMAIL__": "admin@example.test", "__SECRET_PATH__": SECRET}.items():
                rendered = rendered.replace(token, value)
            config = Path(temp) / "Caddyfile"
            config.write_text(rendered)
            result = subprocess.run([caddy, "adapt", "--config", str(config), "--adapter", "caddyfile"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            outer = json.loads(result.stdout)["apps"]["http"]["servers"]["srv0"]["routes"][0]
            routes = outer["handle"][0]["routes"][0]["handle"][-1]["routes"]
            redirects = {}
            positions = {}
            wildcard_position = None
            for index, route in enumerate(routes):
                match = route.get("match", [{}])[0].get("path", [])
                handlers = route.get("handle", [])
                for handler in handlers:
                    if handler.get("handler") == "subroute":
                        for sub in handler.get("routes", []):
                            for response in sub.get("handle", []):
                                if response.get("handler") == "static_response":
                                    redirects[match[0]] = (response.get("headers", {}).get("Location"), response.get("status_code"))
                                    positions[match[0]] = index
                                if response.get("handler") == "reverse_proxy" and match == [SECRET + "/*"]:
                                    wildcard_position = index
            self.assertEqual(redirects[SECRET], ([SECRET + "/login.html"], 302))
            self.assertEqual(redirects[SECRET + "/"], ([SECRET + "/login.html"], 302))
            self.assertLess(positions[SECRET], wildcard_position)
            self.assertLess(positions[SECRET + "/"], wildcard_position)


if __name__ == "__main__":
    unittest.main()
