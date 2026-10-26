"""Focused, unprivileged tests for AdGuard initialization and patching."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "templates/initialize-adguard.py"
PATCHER = ROOT / "templates/patch-adguard-config.py"


@unittest.skipIf(yaml is None, "PyYAML unavailable")
class AdGuardInitializationTests(unittest.TestCase):
    def test_helper_posts_credentials_without_arguments_and_cleans_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg, log, marker = root / "config.yaml", root / "initialize.log", root / "pid"
            binary = root / "fake-adguard"
            binary.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import http.server, json, sys
                from urllib.parse import urlparse
                open(%r, 'w').write(str(__import__('os').getpid()))
                port = int(sys.argv[sys.argv.index('--web-addr') + 1].split(':')[-1])
                cfg = sys.argv[sys.argv.index('-c') + 1]
                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
                    def do_POST(self):
                        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                        assert body['username'] == 'safe-user' and body['password'] == 'very-secret-password'
                        assert body['web']['port'] > 0 and body['web']['port'] != port
                        assert body['dns']['port'] > 0 and body['dns']['port'] not in (port, body['web']['port'])
                        assert body['web']['ip'] == body['dns']['ip'] == '127.0.0.1'
                        open(cfg, 'w').write('schema_version: 34\\n')
                        self.send_response(200); self.end_headers()
                    def log_message(self, *args): pass
                http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
            ''' % str(marker)))
            binary.chmod(0o700)
            env = os.environ.copy()
            env.update(ADG_INIT_USERNAME="safe-user", ADG_INIT_PASSWORD="very-secret-password")
            result = subprocess.run([sys.executable, str(HELPER), "--binary", str(binary),
                                     "--config", str(cfg), "--work-dir", tmp, "--log-file", str(log)],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr + (log.read_text() if log.exists() else ""))
            self.assertEqual(yaml.safe_load(cfg.read_text())["schema_version"], 34)
            diagnostics = log.read_text() if log.exists() else ""
            self.assertNotIn("very-secret-password", result.stdout + result.stderr + diagnostics)
            if log.exists():
                self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(marker.read_text()), 0)

    def test_http_400_is_sanitized_and_child_is_reaped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg, log, marker = root / "config.yaml", root / "initialize.log", root / "pid"
            binary = root / "fake-adguard"
            binary.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import http.server, os, sys
                open(%r, 'w').write(str(os.getpid()))
                port = int(sys.argv[sys.argv.index('--web-addr') + 1].split(':')[-1])
                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(200); self.end_headers()
                    def do_POST(self):
                        self.rfile.read(int(self.headers['Content-Length']))
                        self.send_response(400); self.end_headers()
                        self.wfile.write(b'checking 127.0.0.1:3000: bind failed; safe-user very-secret-password')
                    def log_message(self, *args): pass
                http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
            ''' % str(marker)))
            binary.chmod(0o700)
            env = os.environ.copy()
            env.update(ADG_INIT_USERNAME="safe-user", ADG_INIT_PASSWORD="very-secret-password")
            result = subprocess.run([sys.executable, str(HELPER), "--binary", str(binary),
                                     "--config", str(cfg), "--work-dir", tmp],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1)
            diagnostic = log.read_text()
            self.assertIn("HTTP 400", diagnostic)
            self.assertIn("bind failed", diagnostic)
            self.assertNotIn("safe-user", diagnostic)
            self.assertNotIn("very-secret-password", diagnostic)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(marker.read_text()), 0)

    def test_early_child_exit_output_is_logged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / "failed-adguard"
            binary.write_text("#!/bin/sh\necho 'bind collision on loopback'\nexit 9\n")
            binary.chmod(0o700)
            env = os.environ.copy()
            env.update(ADG_INIT_USERNAME="safe-user", ADG_INIT_PASSWORD="very-secret-password")
            result = subprocess.run([sys.executable, str(HELPER), "--binary", str(binary),
                                     "--config", str(root / "config.yaml"), "--work-dir", tmp],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 1)
            diagnostic = (root / "initialize.log").read_text()
            self.assertIn("bind collision", diagnostic)
            self.assertIn("exited before", diagnostic)

    def test_sigterm_reaps_recorded_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker, binary = root / "pid", root / "fake-adguard"
            binary.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import http.server, os, sys
                open(%r, 'w').write(str(os.getpid()))
                port = int(sys.argv[sys.argv.index('--web-addr') + 1].split(':')[-1])
                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self): self.send_response(200); self.end_headers()
                    def do_POST(self): self.send_response(200); self.end_headers()
                    def log_message(self, *args): pass
                http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()
            ''' % str(marker)))
            binary.chmod(0o700)
            env = os.environ.copy()
            env.update(ADG_INIT_USERNAME="safe-user", ADG_INIT_PASSWORD="very-secret-password")
            proc = subprocess.Popen([sys.executable, str(HELPER), "--binary", str(binary),
                                     "--config", str(root / "config.yaml"), "--work-dir", tmp], env=env)
            try:
                import time
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(marker.exists(), "AdGuard child did not start")
                proc.terminate()
                self.assertEqual(proc.wait(timeout=5), 1)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(marker.read_text()), 0)
                self.assertIn("Received SIGTERM", (root / "initialize.log").read_text())
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()

    def test_patcher_corrects_loopback_dot_binding_preserves_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "config.yaml"
            cfg.write_text("schema_version: 34\nhttp:\n  address: 127.0.0.1:9000\ndns:\n  bind_hosts: [127.0.0.1]\n  serve_plain_dns: true\ntls: {}\n")
            env = os.environ.copy()
            env.update(ADG_DNS_BIND_HOSTS="0.0.0.0", ADG_SERVE_PLAIN_DNS="false",
                       ADG_HTTP_ADDRESS="127.0.0.1:3000")
            subprocess.run([sys.executable, str(PATCHER), str(cfg)], env=env, check=True,
                           capture_output=True, text=True)
            data = yaml.safe_load(cfg.read_text())
            self.assertEqual(data["schema_version"], 34)
            self.assertEqual(data["dns"]["bind_hosts"], ["0.0.0.0"])
            self.assertFalse(data["dns"]["serve_plain_dns"])
            self.assertEqual(data["http"]["address"], "127.0.0.1:3000")
            backups = list(Path(tmp).glob("config.yaml.bak.*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
