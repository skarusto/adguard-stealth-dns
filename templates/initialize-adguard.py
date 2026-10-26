#!/usr/bin/env python3
"""Initialize AdGuard Home through its local first-run API."""
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener


def choose_ports():
    held = []
    try:
        ports = []
        attempts = 0
        while len(ports) < 2 and attempts < 128:
            attempts += 1
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            held.append(sock)
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
            if port not in ports:
                ports.append(port)
        if len(ports) != 2:
            raise RuntimeError("could not reserve distinct local web ports")
        dns = None
        attempts = 0
        while dns is None and attempts < 128:
            attempts += 1
            tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            held.extend((tcp, udp))
            tcp.bind(("127.0.0.1", 0))
            port = tcp.getsockname()[1]
            if port in ports:
                continue
            try:
                udp.bind(("127.0.0.1", port))
            except OSError:
                continue
            dns = port
            ports.append(port)
        if dns is None:
            raise RuntimeError("could not reserve a local DNS port")
        return ports
    finally:
        for sock in held:
            sock.close()


def opener_for_localhost():
    return build_opener(ProxyHandler({}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--log-file")
    args = parser.parse_args()
    log_path = args.log_file or os.path.join(args.work_dir, "initialize.log")
    os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
    # Opening this first ensures even port-selection and startup errors have a
    # durable diagnostic, and that an unwritable log fails loudly.
    log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(log_fd, 0o600)
    log_stream = os.fdopen(log_fd, "a", encoding="utf-8", buffering=1)
    if os.path.isfile(args.config) and os.path.getsize(args.config) > 0:
        log_stream.close()
        return 0
    username = os.environ.get("ADG_INIT_USERNAME", "")
    password = os.environ.get("ADG_INIT_PASSWORD", "")
    if not username or len(password) < 8:
        log_stream.write("Initialization requires an admin username and a password of at least 8 characters.\n")
        log_stream.close()
        return 1
    child = None
    original_handlers = {
        signal.SIGTERM: signal.getsignal(signal.SIGTERM),
        signal.SIGINT: signal.getsignal(signal.SIGINT),
    }

    def on_signal(signum, _frame):
        raise InterruptedError("Received %s." % signal.Signals(signum).name)

    try:
        signal.signal(signal.SIGTERM, on_signal)
        signal.signal(signal.SIGINT, on_signal)
        wizard_port, web_port, dns_port = choose_ports()
        command = [args.binary, "-c", args.config, "-w", args.work_dir,
                   "--web-addr", "127.0.0.1:%d" % wizard_port, "--no-check-update"]
        child_env = os.environ.copy()
        child_env.pop("ADG_INIT_USERNAME", None)
        child_env.pop("ADG_INIT_PASSWORD", None)
        child = subprocess.Popen(command, stdout=log_stream, stderr=subprocess.STDOUT, env=child_env)
        opener = opener_for_localhost()
        url = "http://127.0.0.1:%d/control/install/get_addresses" % wizard_port
        deadline = time.monotonic() + 45
        ready = False
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError("AdGuard process exited before the setup API became ready.")
            try:
                with opener.open(url, timeout=1) as response:
                    if response.status == 200:
                        ready = True
                        break
            except (URLError, TimeoutError, OSError):
                pass
            time.sleep(0.25)
        if not ready:
            raise RuntimeError("Timed out waiting for the local setup API.")
        body = json.dumps({
            "web": {"ip": "127.0.0.1", "port": web_port},
            "dns": {"ip": "127.0.0.1", "port": dns_port},
            "username": username, "password": password, "language": "en",
        }).encode()
        request = Request("http://127.0.0.1:%d/control/install/configure" % wizard_port,
                          data=body, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with opener.open(request, timeout=10) as response:
                if response.status < 200 or response.status >= 300:
                    raise RuntimeError("Setup API returned HTTP %d." % response.status)
                response.read()
        except HTTPError as exc:
            # Never log a response body: the API may echo credentials verbatim
            # or in a JSON-escaped representation.
            exc.close()
            raise RuntimeError(
                "Setup API returned HTTP %d; wizard rejected the configuration. "
                "If a temporary-port bind failed, verify the port is free; also check input validity." % exc.code
            ) from None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if os.path.isfile(args.config) and os.path.getsize(args.config) > 0:
                break
            if child.poll() is not None:
                raise RuntimeError("AdGuard exited before writing its generated config.")
            time.sleep(0.1)
        else:
            raise RuntimeError("Setup succeeded but the generated config was not written.")
    except Exception as exc:
        log_stream.write("Initialization failed: " + str(exc) + "\n")
        return 1
    finally:
        try:
            if child is not None and child.poll() is None:
                try:
                    child.terminate()
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        child.kill()
                    except ProcessLookupError:
                        pass
                    child.wait()
        except Exception as exc:
            log_stream.write("Cleanup of AdGuard process failed: %s\n" % exc)
        finally:
            for sig, handler in original_handlers.items():
                signal.signal(sig, handler)
            log_stream.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
