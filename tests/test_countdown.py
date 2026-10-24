"""Standalone countdown invariants; synthetic profiles and injected boot clocks."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from backend.countdown import CountdownStore, MAX_SECONDS
from backend.storage import SOURCE_ROOT, StoreError


class Clock:
    boot = "synthetic-boot"
    now = 100.0

    def sample(self):
        return self.boot, self.now


class CountdownTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="daymark-countdown-")
        self.addCleanup(temporary.cleanup)
        self.profile = Path(temporary.name) / "profile"
        self.clock = Clock()
        self.counter = 0
        self.store = CountdownStore(self.profile, clock=self.clock)

    def request(self, op, **args):
        self.counter += 1
        return {"protocol": 1, "requestId": f"synthetic-{self.counter}",
                "op": "countdown_" + op, "args": {"observer": "window-one", **args}}

    def call(self, op, **args):
        return self.store.handle(self.request(op, **args))

    def start(self, seconds=60):
        before = self.call("status", attach=True)
        return self.call("start", seconds=seconds, expectedRevision=before["revision"])

    def test_zero_invalid_and_maximum_duration(self):
        for value in (0, -1, True, 1.5, "60", MAX_SECONDS + 1, None):
            with self.subTest(seconds=value), self.assertRaises(StoreError) as error:
                self.call("start", seconds=value, expectedRevision=0)
            self.assertEqual(error.exception.code, "validation")
        result = self.start(MAX_SECONDS)
        self.assertEqual(result["remainingSeconds"], MAX_SECONDS)

    def test_start_pause_resume_and_reset_do_not_create_journal(self):
        active = self.start(90)
        self.assertEqual(active["status"], "running")
        self.clock.now += 12.25
        paused = self.call("pause", expectedRevision=active["revision"])
        self.assertEqual(paused["status"], "paused")
        self.assertEqual(paused["remainingExact"], 77.75)
        self.clock.now += 90000
        self.assertEqual(self.call("status")["remainingExact"], 77.75)
        resumed = self.call("resume", expectedRevision=paused["revision"])
        self.clock.now += 0.75
        self.assertEqual(self.call("status")["remainingSeconds"], 77)
        reset = self.call("reset", expectedRevision=resumed["revision"])
        self.assertEqual(reset["status"], "idle")
        self.assertEqual(reset["remainingSeconds"], 0)
        self.assertFalse((self.profile / "daylog.sqlite3").exists())

    def test_only_one_concurrent_start_wins(self):
        self.call("status")
        requests = [self.request("start", seconds=60, expectedRevision=0),
                    self.request("start", seconds=90, expectedRevision=0)]
        def start(request):
            try:
                return CountdownStore(self.profile, clock=self.clock).handle(request)["status"]
            except StoreError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertCountEqual(list(pool.map(start, requests)), ["running", "conflict"])
        current = self.call("status")
        with self.assertRaises(StoreError):
            self.call("start", seconds=10, expectedRevision=current["revision"])

    def test_completion_claim_is_atomic_and_never_repeats(self):
        self.start(1)
        self.clock.now += 1
        requests = [self.request("status"), self.request("status")]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda request: CountdownStore(self.profile, clock=self.clock).handle(request), requests))
        self.assertEqual(sum(result["sound"] for result in results), 1)
        self.assertTrue(all(result["status"] == "finished" for result in results))
        self.assertFalse(self.store.handle(requests[0])["sound"])
        self.clock.now += 1000
        self.assertEqual(self.call("status")["remainingSeconds"], 0)
        self.assertFalse(self.call("status")["sound"])

    def test_late_completion_and_restart_are_silent(self):
        self.start(5)
        self.clock.now += 9
        result = self.call("status")
        self.assertEqual(result["status"], "finished")
        self.assertEqual(result["recovery"], "expired")
        self.assertFalse(result["sound"])
        self.start(5)
        self.clock.now += 5
        result = CountdownStore(self.profile, clock=self.clock).handle(
            self.request("status", observer="restarted-window", attach=True))
        self.assertEqual(result["status"], "finished")
        self.assertFalse(result["sound"])

    def test_restart_before_deadline_attaches_for_future_sound(self):
        self.start(30)
        self.clock.now += 10
        restarted = CountdownStore(self.profile, clock=self.clock)
        attached = restarted.handle(self.request("status", observer="new-window", attach=True))
        self.assertEqual(attached["remainingSeconds"], 20)
        self.clock.now += 20
        finished = restarted.handle(self.request("status", observer="new-window"))
        self.assertTrue(finished["sound"])

    def test_reboot_retains_last_confirmed_remainder_paused(self):
        self.start(60)
        self.clock.now += 15
        self.assertEqual(self.call("status")["remainingSeconds"], 45)
        self.clock.boot = "another-boot"
        self.clock.now = 2
        result = self.call("status", attach=True)
        self.assertEqual(result["status"], "paused")
        self.assertEqual(result["recovery"], "reboot")
        self.assertEqual(result["remainingSeconds"], 45)
        self.assertFalse(result["sound"])
        self.clock.now += 100000
        self.assertEqual(self.call("status")["remainingSeconds"], 45)
        resumed = self.call("resume", expectedRevision=result["revision"])
        self.assertEqual(resumed["status"], "running")
        self.assertEqual(resumed["recovery"], "")

    def test_suspend_elapsed_boot_time_finishes_without_late_sound(self):
        self.start(60)
        # CLOCK_BOOTTIME includes suspend; unknown wall-time arithmetic is absent.
        self.clock.now += 120
        self.assertEqual(self.call("status")["status"], "finished")
        self.assertFalse(self.call("status")["sound"])

    def test_muting_is_persistent_and_completion_stays_visible(self):
        muted = self.call("mute", expectedRevision=0, muted=True)
        active = self.call("start", expectedRevision=muted["revision"], seconds=1)
        self.assertTrue(active["muted"])
        self.clock.now += 1
        finished = self.call("status")
        self.assertEqual(finished["status"], "finished")
        self.assertFalse(finished["sound"])
        self.assertTrue(CountdownStore(self.profile, clock=self.clock).handle(self.request("status"))["muted"])

    def test_replay_does_not_restart_or_repeat_sound(self):
        request = self.request("start", expectedRevision=0, seconds=5)
        first = self.store.handle(request)
        self.clock.now += 3
        replay = self.store.handle(request)
        self.assertEqual(replay["revision"], first["revision"])
        self.assertEqual(replay["remainingSeconds"], 2)
        self.clock.now += 2
        replay = self.store.handle(request)
        self.assertEqual(replay["status"], "finished")
        self.assertFalse(replay["sound"])
        changed = dict(request, args=dict(request["args"], seconds=6))
        with self.assertRaises(StoreError):
            self.store.handle(changed)

    def test_countdown_database_symlink_never_modifies_target(self):
        self.profile.mkdir()
        target = self.profile.parent / "unrelated-file"
        target.write_bytes(b"synthetic unrelated data")
        self.store.path.symlink_to(target)
        with self.assertRaises(StoreError) as error:
            self.call("status")
        self.assertEqual(error.exception.code, "storage")
        self.assertEqual(target.read_bytes(), b"synthetic unrelated data")

    def test_countdown_database_permissions_are_private_on_creation_and_reopen(self):
        self.call("status")
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        self.store.path.chmod(0o644)
        self.call("status")
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_failed_storage_leaves_no_acknowledged_transition(self):
        initial = self.call("status")
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("CREATE TRIGGER reject_write BEFORE UPDATE ON countdown BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END")
        request = self.request("start", expectedRevision=initial["revision"], seconds=30)
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.handle(request)
        with closing(sqlite3.connect(self.store.path)) as db, db:
            self.assertEqual(db.execute("SELECT status,revision FROM countdown").fetchone(), ("idle", 0))
            self.assertEqual(db.execute("SELECT count(*) FROM receipts").fetchone()[0], 0)
            db.execute("DROP TRIGGER reject_write")
        self.assertEqual(self.store.handle(request)["status"], "running")
        with self.assertRaises(StoreError) as error:
            CountdownStore(self.profile, read_only=True).handle(self.request("status"))
        self.assertEqual(error.exception.code, "read_only")

    def test_helper_preserves_snapshot_envelope_and_journal_revision(self):
        def invoke(request):
            process = subprocess.run([sys.executable, str(SOURCE_ROOT / "backend/helper.py"),
                                      "--profile", str(self.profile)], input=json.dumps(request),
                                     text=True, capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stderr, "")
            result = json.loads(process.stdout)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["requestId"], request["requestId"])
            return result
        initial = invoke(self.request("status", attach=True))
        started = invoke(self.request("start", seconds=60, expectedRevision=0))
        self.assertEqual(started["result"]["status"], "running")
        self.assertEqual(started["snapshot"], initial["snapshot"])
        self.assertEqual(started["snapshot"]["sessions"], [])


if __name__ == "__main__":
    unittest.main()
