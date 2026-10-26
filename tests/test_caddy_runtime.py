"""Optional real-Caddy routing regression; CADDY_BIN points to a local binary.

Only loopback, high ports and temporary directories are used. TLS issuance is not
tested here: the production routing template is rendered as a local HTTP site.
"""
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Backend(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/needs-login":
            self.send_response(302)
            self.send_header("Location", "/login.html")
            self.end_headers()
            return
        body = b"Login page" if self.path == "/login.html" else b"DNS backend"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@unittest.skipUnless(os.environ.get("CADDY_BIN"), "set CADDY_BIN for real Caddy checks")
class CaddyRoutingTests(unittest.TestCase):
    def test_production_handlers_with_real_caddy(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            site = directory / "site"
            site.mkdir()
            (site / "index.html").write_text("Decoy fixture")
            backend = http.server.HTTPServer(("127.0.0.1", 0), Backend)
            thread = threading.Thread(target=backend.serve_forever, daemon=True)
            thread.start()
            with contextlib.closing(socket.socket()) as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            source = (ROOT / "templates/Caddyfile").read_text()
            source = source.replace("email __EMAIL__", "admin off")
            source = source.replace("__DOMAIN__", f"http://127.0.0.1:{port}")
            source = source.replace("__SECRET_PATH__", "/test-secret")
            source = source.replace(
                "tls /etc/ssl/adguard/fullchain.pem /etc/ssl/adguard/privkey.pem", ""
            )
            source = source.replace("/var/www/fake", str(site))
            source = source.replace("127.0.0.1:3000", f"127.0.0.1:{backend.server_port}")
            config = directory / "Caddyfile"
            config.write_text(source)
            binary = os.environ["CADDY_BIN"]
            runtime_env = os.environ | {
                "XDG_CONFIG_HOME": str(directory / "config"),
                "XDG_DATA_HOME": str(directory / "data"),
            }
            try:
                adapted = subprocess.run(
                    [binary, "adapt", "--config", str(config), "--validate"],
                    capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(adapted.returncode, 0, adapted.stderr)
                parsed = json.loads(adapted.stdout)
                self.assertIn("http", parsed["apps"])
                with (directory / "caddy.log").open("w+") as log:
                    process = subprocess.Popen(
                        [binary, "run", "--config", str(config)],
                        stdout=log, stderr=log, env=runtime_env,
                    )
                    try:
                        opener = urllib.request.build_opener(
                            urllib.request.ProxyHandler({}), NoRedirect()
                        )

                        def fetch(path):
                            try:
                                return opener.open(f"http://127.0.0.1:{port}{path}", timeout=2)
                            except urllib.error.HTTPError as error:
                                return error

                        deadline = time.monotonic() + 10
                        while True:
                            try:
                                with fetch("/") as response:
                                    self.assertEqual(response.status, 200)
                                break
                            except (OSError, urllib.error.URLError):
                                if time.monotonic() >= deadline or process.poll() is not None:
                                    log.seek(0)
                                    self.fail("Caddy did not become ready: " + log.read())
                                time.sleep(0.05)

                        for path in ("/test-secret", "/test-secret/"):
                            with self.subTest(path=path), fetch(path) as response:
                                self.assertEqual(response.status, 302)
                                self.assertEqual(response.headers["Location"], "/test-secret/login.html")
                        with fetch("/test-secret/login.html") as response:
                            self.assertEqual(response.status, 200)
                            self.assertEqual(response.read(), b"Login page")
                        with fetch("/test-secret/needs-login") as response:
                            self.assertEqual(response.status, 302)
                            self.assertEqual(response.headers["Location"], "/test-secret/login.html")
                        for path in ("/", "/unknown", "/login.html"):
                            with self.subTest(path=path), fetch(path) as response:
                                self.assertEqual(response.status, 200)
                                self.assertEqual(response.read(), b"Decoy fixture")
                        with fetch("/dns-query?dns=fixture") as response:
                            self.assertEqual(response.status, 200)
                            self.assertEqual(response.read(), b"DNS backend")
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
            finally:
                backend.shutdown()
                backend.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
