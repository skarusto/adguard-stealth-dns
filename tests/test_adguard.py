import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("initialize_adguard", ROOT / "templates/initialize-adguard.py")
initializer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(initializer)


class FakeProcess:
    def __init__(self, *args, **kwargs):
        self.args = args[0]
        self.kwargs = kwargs
        self.returncode = None
        self.terminated = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = 0

    def wait(self, timeout=None):
        return self.returncode


class DeadProcess(FakeProcess):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.returncode = 9


class InitializeTests(unittest.TestCase):
    def args(self, td):
        return type("Args", (), {"binary": "/fake/AdGuardHome", "config": str(Path(td) / "AdGuardHome.yaml"),
                                  "work_dir": td, "log_file": str(Path(td) / "initialize.log")})()

    @staticmethod
    def handlers():
        return signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT)

    def test_wizard_uses_loopback_temporary_ports_and_hides_credentials_from_argv_and_child_env(self):
        with tempfile.TemporaryDirectory() as td:
            args, requests, processes = self.args(td), [], []
            class Response:
                status = 200
                def __enter__(self): return self
                def __exit__(self, *unused): return False
                def read(self): return b"{}"
            class Opener:
                def open(self, request, timeout):
                    requests.append(request)
                    if getattr(request, "data", None):
                        Path(args.config).write_text("schema_version: 34\n")
                    return Response()
            def spawn(*argv, **kwargs):
                process = FakeProcess(*argv, **kwargs)
                processes.append(process)
                return process
            old_handlers = self.handlers()
            with mock.patch.dict(os.environ, {"ADG_INIT_USERNAME": "admin", "ADG_INIT_PASSWORD": "secret-pass"}), \
                    mock.patch.object(initializer, "choose_ports", return_value=[3001, 3002, 49152]), \
                    mock.patch.object(initializer.subprocess, "Popen", side_effect=spawn) as popen, \
                    mock.patch.object(initializer, "opener_for_localhost", return_value=Opener()), \
                    mock.patch.object(initializer.argparse.ArgumentParser, "parse_args", return_value=args), \
                    mock.patch.object(initializer.time, "sleep"):
                self.assertEqual(initializer.main(), 0)
            argv = popen.call_args.args[0]
            self.assertNotIn("admin", argv)
            self.assertNotIn("secret-pass", argv)
            self.assertIn("127.0.0.1:3001", argv)
            self.assertNotIn("ADG_INIT_USERNAME", popen.call_args.kwargs["env"])
            self.assertNotIn("ADG_INIT_PASSWORD", popen.call_args.kwargs["env"])
            payload = json.loads(requests[-1].data)
            self.assertEqual(payload["web"], {"ip": "127.0.0.1", "port": 3002})
            self.assertEqual(payload["dns"], {"ip": "127.0.0.1", "port": 49152})
            self.assertEqual(payload["username"], "admin")
            self.assertEqual(payload["password"], "secret-pass")
            self.assertTrue(processes[0].terminated)
            self.assertEqual(self.handlers(), old_handlers)

    def test_existing_config_skips_process_start(self):
        with tempfile.TemporaryDirectory() as td:
            args = self.args(td)
            Path(args.config).write_text("schema_version: 34\n")
            with mock.patch.object(initializer.argparse.ArgumentParser, "parse_args", return_value=args), \
                    mock.patch.object(initializer.subprocess, "Popen") as popen:
                self.assertEqual(initializer.main(), 0)
            popen.assert_not_called()

    def test_readiness_timeout_cleans_up_child(self):
        with tempfile.TemporaryDirectory() as td:
            args, processes = self.args(td), []
            class Opener:
                def open(self, request, timeout):
                    raise URLError("not ready")
            def spawn(*argv, **kwargs):
                process = FakeProcess(*argv, **kwargs)
                processes.append(process)
                return process
            with mock.patch.dict(os.environ, {"ADG_INIT_USERNAME": "admin", "ADG_INIT_PASSWORD": "secret-pass"}), \
                    mock.patch.object(initializer, "choose_ports", return_value=[3001, 3002, 49152]), \
                    mock.patch.object(initializer.subprocess, "Popen", side_effect=spawn), \
                    mock.patch.object(initializer, "opener_for_localhost", return_value=Opener()), \
                    mock.patch.object(initializer.argparse.ArgumentParser, "parse_args", return_value=args), \
                    mock.patch.object(initializer.time, "monotonic", side_effect=[0, 0, 46]), \
                    mock.patch.object(initializer.time, "sleep"):
                self.assertEqual(initializer.main(), 1)
            self.assertTrue(processes[0].terminated)
            self.assertNotIn("secret-pass", Path(args.log_file).read_text())

    def test_http_400_omits_json_escaped_response_body_and_reaps_child(self):
        with tempfile.TemporaryDirectory() as td:
            args, processes = self.args(td), []
            password = 'p\\"ssword'
            escaped = json.dumps(password)[1:-1]
            class Opener:
                def open(self, request, timeout):
                    if not getattr(request, "data", None):
                        return type("Response", (), {"status": 200, "__enter__": lambda s: s,
                                                       "__exit__": lambda *a: False})()
                    body = ('{"error":"response body marker; credential=%s"}' % escaped).encode()
                    raise HTTPError(request.full_url, 400, "bad request", {}, io.BytesIO(body))
            def spawn(*argv, **kwargs):
                process = FakeProcess(*argv, **kwargs)
                processes.append(process)
                return process
            old_handlers = self.handlers()
            with mock.patch.dict(os.environ, {"ADG_INIT_USERNAME": "admin", "ADG_INIT_PASSWORD": password}), \
                    mock.patch.object(initializer, "choose_ports", return_value=[3001, 3002, 49152]), \
                    mock.patch.object(initializer.subprocess, "Popen", side_effect=spawn), \
                    mock.patch.object(initializer, "opener_for_localhost", return_value=Opener()), \
                    mock.patch.object(initializer.argparse.ArgumentParser, "parse_args", return_value=args):
                self.assertEqual(initializer.main(), 1)
            diagnostic = Path(args.log_file).read_text()
            self.assertIn("HTTP 400", diagnostic)
            self.assertIn("wizard rejected the configuration", diagnostic)
            self.assertNotIn(password, diagnostic)
            self.assertNotIn(escaped, diagnostic)
            self.assertNotIn("response body marker", diagnostic)
            self.assertNotIn("credential", diagnostic)
            self.assertTrue(processes[0].terminated)
            self.assertEqual(self.handlers(), old_handlers)

    def test_startup_exit_is_reported_and_signal_handlers_restored(self):
        with tempfile.TemporaryDirectory() as td:
            args = self.args(td)
            old_handlers = self.handlers()
            with mock.patch.dict(os.environ, {"ADG_INIT_USERNAME": "admin", "ADG_INIT_PASSWORD": "secret-pass"}), \
                    mock.patch.object(initializer, "choose_ports", return_value=[3001, 3002, 49152]), \
                    mock.patch.object(initializer.subprocess, "Popen", side_effect=DeadProcess), \
                    mock.patch.object(initializer.argparse.ArgumentParser, "parse_args", return_value=args):
                self.assertEqual(initializer.main(), 1)
            self.assertIn("exited before the setup API became ready", Path(args.log_file).read_text())
            self.assertEqual(self.handlers(), old_handlers)


class ConfigPatchTests(unittest.TestCase):
    def test_public_dot_binding_retains_schema_and_unrelated_settings(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML unavailable")
        with tempfile.TemporaryDirectory() as td:
            cfg = Path(td) / "AdGuardHome.yaml"
            original = "schema_version: 34\nhttp:\n  address: 127.0.0.1:3000\n  custom_setting: keep\ndns:\n  bind_hosts: [127.0.0.1]\n  serve_plain_dns: false\n  port: 5353\ntls:\n  enabled: true\n  port_dns_over_tls: 853\ncustom:\n  untouched: true\n"
            cfg.write_text(original)
            env = os.environ.copy()
            env.update({"ADG_HTTP_ADDRESS": "127.0.0.1:3000", "ADG_BIND_HOSTS": "0.0.0.0",
                        "ADG_SERVE_PLAIN_DNS": "false", "ADG_TLS_PORT_DOT": "853"})
            result = subprocess.run(["python3", str(ROOT / "templates/patch-adguard-config.py"), str(cfg)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            patched = yaml.safe_load(cfg.read_text())
            self.assertEqual(patched["schema_version"], 34)
            self.assertEqual(patched["dns"]["bind_hosts"], ["0.0.0.0"])
            self.assertFalse(patched["dns"]["serve_plain_dns"])
            self.assertEqual(patched["http"]["address"], "127.0.0.1:3000")
            self.assertEqual(patched["dns"]["port"], 5353)
            self.assertTrue(patched["custom"]["untouched"])
            backup, = Path(td).glob("AdGuardHome.yaml.bak.*")
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(cfg.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
