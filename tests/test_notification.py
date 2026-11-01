"""Private notification protocol and real process deadlines, without a desktop bus."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest

from backend.notification import (
    DEADLINE_SECONDS,
    ERROR_MESSAGE,
    MAX_INPUT_BYTES,
    MAX_TIMEOUT_MS,
    NotificationError,
    STRING_LIMITS,
    arm_deadline,
    read_request,
)


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "backend" / "notification.py"


def payload(**changes):
    request = {"title": "Private synthetic event", "icon": "/synthetic/icon.svg",
               "action": "Open Today", "timeoutMs": 60000}
    request.update(changes)
    return request


def encoded(request):
    return json.dumps(request, ensure_ascii=True).encode("utf-8")


class NotificationProtocolTests(unittest.TestCase):
    def parse(self, request):
        return read_request(io.BytesIO(encoded(request)))

    def test_unicode_round_trip_and_timeout_endpoints(self):
        for timeout in (1, MAX_TIMEOUT_MS):
            request = payload(title="Private café 日本語 \U0001f512", action="Ouvrir le calendrier",
                              icon="/synthetic/日本語.svg", timeoutMs=timeout)
            with self.subTest(timeout=timeout):
                self.assertEqual(self.parse(request), request)
                raw_utf8 = json.dumps(request, ensure_ascii=False).encode("utf-8")
                self.assertEqual(read_request(io.BytesIO(raw_utf8)), request)

    def test_string_limits_count_unicode_characters(self):
        for name, limit in STRING_LIMITS.items():
            with self.subTest(name=name):
                request = payload(**{name: "x" * limit})
                self.assertEqual(self.parse(request), request)
                with self.assertRaises(NotificationError):
                    self.parse(payload(**{name: "x" * (limit + 1)}))
        request = payload(action="\U0001f512" * STRING_LIMITS["action"])
        self.assertEqual(self.parse(request), request)
        with self.assertRaises(NotificationError):
            self.parse(payload(action="\U0001f512" * (STRING_LIMITS["action"] + 1)))

    def test_invalid_string_types_empty_nul_and_surrogates(self):
        for name in STRING_LIMITS:
            for value in (None, True, 1, [], {}, "", "private\0title", "\ud800", "\udfff"):
                with self.subTest(name=name, value=repr(value)):
                    with self.assertRaises(NotificationError) as caught:
                        self.parse(payload(**{name: value}))
                    self.assertEqual(str(caught.exception), "")

    def test_timeout_is_a_bounded_integer_not_boolean(self):
        for value in (0, -1, MAX_TIMEOUT_MS + 1, True, False, 1.0, "60000", None, [], {},
                      float("inf"), float("nan")):
            with self.subTest(value=value):
                with self.assertRaises(NotificationError):
                    self.parse(payload(timeoutMs=value))

    def test_exact_request_shape(self):
        for request in (None, [], "private", 1, True, {}, payload(extra="private")):
            with self.subTest(request=request):
                with self.assertRaises(NotificationError):
                    self.parse(request)
        for name in payload():
            request = payload()
            del request[name]
            with self.subTest(missing=name):
                with self.assertRaises(NotificationError):
                    self.parse(request)

    def test_invalid_json_utf8_duplicate_keys_and_multiple_requests(self):
        valid = encoded(payload())
        duplicate = valid[:-1] + b', "title": "other private title"}'
        for data in (b"", b"\xff", b"{", valid + valid, duplicate,
                     b"[" * 2000 + b"]" * 2000):
            with self.subTest(data_length=len(data)):
                with self.assertRaises(NotificationError) as caught:
                    read_request(io.BytesIO(data))
                self.assertEqual(str(caught.exception), "")

    def test_byte_limit_accepts_boundary_and_reads_only_overflow_sentinel(self):
        data = encoded(payload())
        exact = data + b" " * (MAX_INPUT_BYTES - len(data))
        self.assertEqual(read_request(io.BytesIO(exact)), payload())
        stream = io.BytesIO(exact + b" " * MAX_INPUT_BYTES)
        with self.assertRaises(NotificationError):
            read_request(stream)
        self.assertEqual(stream.tell(), MAX_INPUT_BYTES + 1)


class NotificationProcessTests(unittest.TestCase):
    def helper(self, data, environment=None):
        return subprocess.run([sys.executable, "-B", str(HELPER)], input=data, capture_output=True,
                              cwd=ROOT, env=environment, timeout=5)

    def assert_generic_failure(self, process):
        self.assertEqual(process.returncode, 1)
        self.assertEqual(process.stdout, b"")
        self.assertEqual(process.stderr, ERROR_MESSAGE.encode("utf-8"))
        self.assertNotIn(b"Private synthetic event", process.stderr)

    def test_malformed_private_input_has_only_generic_diagnostic(self):
        self.assert_generic_failure(self.helper(b'{"title":"Private synthetic event"'))
        self.assert_generic_failure(self.helper(encoded(payload(timeoutMs=0))))
        self.assert_generic_failure(self.helper(encoded(payload(title="private\ud800"))))
        self.assert_generic_failure(self.helper(b"x" * (MAX_INPUT_BYTES + 1)))

    def test_real_libnotify_bus_failure_does_not_print_private_input(self):
        environment = dict(os.environ)
        # An impossible socket path cannot reach the user's notification daemon.
        environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/dev/null/daymark-notification-test"
        self.assert_generic_failure(self.helper(encoded(payload()), environment))

    def child(self, code):
        return subprocess.run([sys.executable, "-B", "-c", code], cwd=ROOT,
                              capture_output=True, timeout=5)

    def test_kernel_deadline_interrupts_blocked_native_call(self):
        process = self.child(
            "import ctypes; from backend.notification import arm_deadline; "
            "native = ctypes.CDLL(None); arm_deadline(0.1); native.pause()"
        )
        self.assertEqual(process.returncode, -signal.SIGALRM)
        self.assertEqual(process.stdout, b"")
        self.assertEqual(process.stderr, b"")

    def test_kernel_deadline_interrupts_unfinished_stdin(self):
        code = (
            "import sys; from backend.notification import arm_deadline, read_request; "
            "arm_deadline(0.1); read_request(sys.stdin.buffer)"
        )
        with subprocess.Popen([sys.executable, "-B", "-c", code], cwd=ROOT,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            try:
                # Leave stdin open: neither newline nor partial JSON is an EOF.
                process.stdin.write(b'{"title":"Private synthetic event"')
                process.stdin.flush()
                returncode = process.wait(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            self.assertEqual(returncode, -signal.SIGALRM)
            self.assertEqual(process.stdout.read(), b"")
            self.assertEqual(process.stderr.read(), b"")

    def test_deadline_arms_at_short_and_maximum_boundaries(self):
        for seconds in (0.25, DEADLINE_SECONDS):
            with self.subTest(seconds=seconds):
                process = self.child(
                    "import signal; from backend.notification import arm_deadline; "
                    f"arm_deadline({seconds}); "
                    "remaining = signal.getitimer(signal.ITIMER_REAL)[0]; "
                    "signal.setitimer(signal.ITIMER_REAL, 0); print(remaining)"
                )
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertGreater(float(process.stdout), 0)
                self.assertLessEqual(float(process.stdout), seconds)

    def test_invalid_deadlines_are_rejected_before_arming(self):
        for seconds in (0, -1, DEADLINE_SECONDS + 1, float("nan"), float("inf")):
            with self.subTest(seconds=seconds):
                with self.assertRaises(NotificationError):
                    arm_deadline(seconds)


if __name__ == "__main__":
    unittest.main()
