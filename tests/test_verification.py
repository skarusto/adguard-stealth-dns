import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts" / "80-verify.sh"


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state"
        self.state.mkdir()
        self.cfg = self.root / "AdGuardHome.yaml"
        self.cfg.write_text("dns:\n  serve_plain_dns: false\nhttp:\n  address: 127.0.0.1:3000\n")
        self.write_mock("curl", r'''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
url = args[-1]
out = args[args.index('-o') + 1] if '-o' in args else '/dev/null'
if '/dns-query?' in url:
    code = '200'
    packet = bytes.fromhex('000081800001000100000000076578616d706c6503636f6d0000010001c00c000100010000003c0004c0000201')
    mode = os.environ.get('BAD_DNS', 'no')
    if mode == 'yes': packet = b'not dns'
    elif mode == 'truncated': packet = bytes.fromhex('0000818000010001')
    elif mode == 'qname': packet = bytes.fromhex('000081800001000100000000ff')
    elif mode == 'id': packet = bytes.fromhex('123481800001000100000000076578616d706c6503636f6d0000010001c00c000100010000003c0004c0000201')
    if out != '/dev/null': open(out, 'wb').write(packet)
elif url.endswith('/login.html'):
    code = '200'
    if out != '/dev/null': open(out, 'w').write('<title>Login</title>')
elif url.endswith('/secret') or url.endswith('/secret/'):
    code = '302'
    loc = 'https://example.test/secret/login.html'
    if os.environ.get('BAD_REDIRECT') == 'yes': loc = 'https://example.test/decoy'
else:
    code = '200'; loc = ''
if '-w' in args:
    fmt = args[args.index('-w') + 1]
    print(fmt.replace('\\t', '\t').replace('%{http_code}', code).replace('%{redirect_url}', loc if code == '302' else ''), end='')
''')
        self.write_mock("ss", r'''#!/usr/bin/env python3
import os
if os.environ.get('NO_3000') != 'yes': print('LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*')
if os.environ.get('EXPOSED_3000') == 'yes': print('LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*')
if os.environ.get('NO_3000') == 'yes': print('')
if os.environ.get('LOOPBACK_853') == 'yes': print('LISTEN 0 128 127.0.0.1:853 0.0.0.0:*')
elif os.environ.get('NO_853') != 'yes': print('LISTEN 0 128 0.0.0.0:853 0.0.0.0:*')
''')
        self.write_mock("systemctl", r'''#!/usr/bin/env python3
import os, sys
cmd, unit = sys.argv[1], sys.argv[-1]
bad = os.environ.get('BAD_SERVICE') == unit
if cmd == 'is-enabled' and os.environ.get('BAD_ENABLED') == unit: bad = True
sys.exit(1 if bad else 0)
''')
        self.write_mock("ufw", r'''#!/usr/bin/env python3
import os
print('Status: inactive' if os.environ.get('UFW_INACTIVE') == 'yes' else 'Status: active')
''')
        self.write_mock("timeout", r'''#!/usr/bin/env python3
import os, sys
if os.environ.get('TLS_OK') == 'no':
    sys.exit(1)
if os.environ.get('NO_TLS_CERT') == 'yes':
    print('no peer certificate available'); sys.exit(1)
print('Verification: OK')
''')

    def write_mock(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_verify(self, **overrides):
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "DOMAIN": "example.test",
            "SECRET_PATH": "/secret",
            "STATE_DIR": str(self.state),
            "AG_CFG": str(self.cfg),
            "SKIP_FIREWALL": "no",
            "BAD_DNS": "no",
            "BAD_REDIRECT": "no",
            "EXPOSED_3000": "no",
            "LOOPBACK_853": "no",
            "NO_3000": "no",
            "NO_853": "no",
            "NO_TLS_CERT": "no",
            "UFW_INACTIVE": "no",
            "TLS_OK": "yes",
        })
        env.update(overrides)
        bash = """set -Eeuo pipefail
DOMAIN=$DOMAIN SECRET_PATH=$SECRET_PATH STATE_DIR=$STATE_DIR AG_CFG=$AG_CFG SKIP_FIREWALL=$SKIP_FIREWALL
log(){ :; }; ok(){ echo "$*"; }; warn(){ echo "$*" >&2; }; detect_public_ip(){ echo 192.0.2.1; }
mark_done(){ mkdir -p "$STATE_DIR"; : > "$STATE_DIR/done.$1"; }
source "$VERIFY"
"""
        return subprocess.run(["bash", "-c", bash], env={**env, "VERIFY": str(VERIFY)},
                              text=True, capture_output=True)

    def test_good_verification_records_success(self):
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / "done.80-verify").exists())

    def assert_failed_and_unmarked(self, **env):
        (self.state / "done.80-verify").write_text("stale")
        result = self.run_verify(**env)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / "done.80-verify").exists())

    def test_failure_propagates_and_clears_stale_marker(self):
        self.assert_failed_and_unmarked(BAD_SERVICE="caddy")

    def test_loopback_only_dot_fails(self):
        self.assert_failed_and_unmarked(LOOPBACK_853="yes")

    def test_any_exposed_3000_listener_fails_even_with_loopback(self):
        self.assert_failed_and_unmarked(EXPOSED_3000="yes")

    def test_redirect_to_wrong_location_fails(self):
        self.assert_failed_and_unmarked(BAD_REDIRECT="yes")

    def test_http_200_with_invalid_dns_payload_fails(self):
        self.assert_failed_and_unmarked(BAD_DNS="yes")

    def test_truncated_dns_header_fails(self):
        self.assert_failed_and_unmarked(BAD_DNS="truncated")

    def test_malformed_dns_qname_fails(self):
        self.assert_failed_and_unmarked(BAD_DNS="qname")

    def test_nonmatching_dns_id_fails(self):
        self.assert_failed_and_unmarked(BAD_DNS="id")

    def test_missing_listeners_fail(self):
        self.assert_failed_and_unmarked(NO_3000="yes")
        self.assert_failed_and_unmarked(NO_853="yes")

    def test_tls_verification_failure_propagates(self):
        self.assert_failed_and_unmarked(TLS_OK="no")

    def test_missing_tls_certificate_fails(self):
        self.assert_failed_and_unmarked(NO_TLS_CERT="yes")

    def test_disabled_certbot_timer_fails(self):
        self.assert_failed_and_unmarked(BAD_ENABLED="certbot.timer")

    def test_ufw_must_be_enabled_and_active(self):
        self.assert_failed_and_unmarked(BAD_ENABLED="ufw")
        self.assert_failed_and_unmarked(UFW_INACTIVE="yes")

    def test_skip_firewall_skips_ufw_checks(self):
        result = self.run_verify(SKIP_FIREWALL="yes", BAD_ENABLED="ufw", UFW_INACTIVE="yes")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
