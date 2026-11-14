#!/usr/bin/env python3
"""Check private client transport against fake Unix sockets, without starting a GUI service.

Run after swift build: python3 scripts/test-private-client.py .build/debug/computercub
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())
if any(parent.suffix == ".app" for parent in Path(BINARY).parents):
    raise SystemExit("Use an unbundled debug build; never run this probe on an installed app.")


class PrivateClientTests(unittest.TestCase):
    def setUp(self):
        # Keep the path below Darwin's Unix socket length limit.
        self.directory = tempfile.TemporaryDirectory(prefix="cub-test.", dir="/tmp")
        self.home = self.directory.name
        self.socket_path = str(Path(self.home) / "computercub.sock")
        self.env = {**os.environ, "COMPUTERCUB_HOME": self.home}

    def tearDown(self):
        self.directory.cleanup()

    def client(self, *args):
        return subprocess.run(
            [BINARY, *args], env=self.env, capture_output=True, text=True, timeout=15
        )

    def exchange(self, reply, *args):
        requests = []
        errors = []
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(self.socket_path)
            server.listen(4)
            # A freshly linked binary may take longer to start on its first run.
            server.settimeout(10)

            def respond():
                try:
                    while True:
                        try:
                            connection, _ = server.accept()
                        except socket.timeout:
                            return
                        with connection:
                            connection.settimeout(2)
                            with connection.makefile("rb") as stream:
                                requests.append(json.loads(stream.readline()))
                            if reply is not None:
                                connection.sendall(reply)
                        server.settimeout(0.5)
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=respond)
            worker.start()
            try:
                result = self.client(*args)
            finally:
                worker.join(timeout=11)
            self.assertFalse(worker.is_alive(), "client kept reconnecting")
            self.assertEqual(errors, [])
        Path(self.socket_path).unlink()
        self.assertEqual([request["args"] for request in requests], [list(args)])
        return result

    def test_missing_private_socket_fails_without_local_fallback(self):
        # doctor would succeed if the client fell back to in-process execution.
        result = self.client("doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("couldn't connect to private service", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_reply_is_returned_and_later_socket_loss_fails(self):
        result = self.exchange(b'{"ok":true,"out":"private reply"}\n', "doctor")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "private reply\n")
        result = self.client("doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("couldn't connect to private service", result.stderr)

    def test_permission_denial_does_not_restart_or_retry(self):
        reply = b'{"ok":false,"out":"Screen Recording denied","restart":true}\n'
        result = self.exchange(reply, "shot", "w1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Screen Recording denied", result.stderr)

    def test_accessibility_denial_is_returned(self):
        reply = b'{"ok":false,"out":"Accessibility denied","restart":false}\n'
        result = self.exchange(reply, "windows")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Accessibility denied", result.stderr)

    def test_service_closes_without_reply(self):
        result = self.exchange(None, "doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("outcome is unknown", result.stderr)

    def test_malformed_reply_fails(self):
        result = self.exchange(b'not JSON\n', "doctor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("outcome is unknown", result.stderr)


if __name__ == "__main__":
    unittest.main()
