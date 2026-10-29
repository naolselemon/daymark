"""Countdown clocks and explicit linked logging; isolated profiles only."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from backend.countdown import CountdownStore, MAX_SECONDS
from backend.storage import SOURCE_ROOT, Store, StoreError


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
        self.assertEqual(sum(result["notify"] for result in results), 1)
        self.assertTrue(all(result["status"] == "finished" for result in results))
        self.assertFalse(self.store.handle(requests[0])["sound"])
        self.assertFalse(self.store.handle(requests[0])["notify"])
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
        self.assertFalse(result["notify"])
        self.start(5)
        self.clock.now += 5
        result = CountdownStore(self.profile, clock=self.clock).handle(
            self.request("status", observer="restarted-window", attach=True))
        self.assertEqual(result["status"], "finished")
        self.assertFalse(result["sound"])
        self.assertFalse(result["notify"])

    def test_restart_before_deadline_attaches_for_future_sound(self):
        self.start(30)
        self.clock.now += 10
        restarted = CountdownStore(self.profile, clock=self.clock)
        attached = restarted.handle(self.request("status", observer="new-window", attach=True))
        self.assertEqual(attached["remainingSeconds"], 20)
        self.clock.now += 20
        finished = restarted.handle(self.request("status", observer="new-window"))
        self.assertTrue(finished["sound"])
        self.assertTrue(finished["notify"])

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
        self.assertFalse(result["notify"])
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
        self.assertTrue(finished["notify"])
        self.assertEqual(finished["recovery"], "")
        self.assertFalse(self.call("status")["notify"])
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
        self.assertFalse(replay["notify"])
        changed = dict(request, args=dict(request["args"], seconds=6))
        with self.assertRaises(StoreError):
            self.store.handle(changed)

    def test_lost_completion_response_is_not_reannounced_after_reopen(self):
        self.start(1)
        self.clock.now += 1
        # Delivery may disappear after SQLite committed. A new client cannot
        # distinguish that from a visible notification, so it never retries.
        self.assertTrue(self.call("status")["notify"])
        reopened = CountdownStore(self.profile, clock=self.clock)
        for attach in (False, True):
            result = reopened.handle(self.request("status", attach=attach))
            self.assertFalse(result["notify"])
            self.assertFalse(result["sound"])

    def test_completion_from_an_unattached_observer_never_announces(self):
        self.start(1)
        self.clock.now += 1
        result = self.call("status", observer="unattached-window")
        self.assertEqual(result["status"], "finished")
        self.assertFalse(result["notify"])
        self.assertFalse(result["sound"])
        self.assertFalse(self.call("status")["notify"])

    def test_failed_completion_cannot_be_announced_late_after_storage_recovers(self):
        active = self.start(1)
        self.clock.now += 1
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("CREATE TRIGGER reject_completion BEFORE UPDATE ON countdown "
                       "BEGIN SELECT RAISE(ABORT, 'synthetic completion failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.call("status")
        with closing(sqlite3.connect(self.store.path)) as db, db:
            self.assertEqual(db.execute("SELECT status,revision FROM countdown").fetchone(),
                             ("running", active["revision"]))
            db.execute("DROP TRIGGER reject_completion")
        self.clock.now += 4
        result = self.call("status")
        self.assertEqual(result["status"], "finished")
        self.assertFalse(result["notify"])
        self.assertFalse(result["sound"])

    def test_cancel_at_completion_never_announces_an_idle_timer(self):
        active = self.start(1)
        self.clock.now += 1
        result = self.call("reset", expectedRevision=active["revision"] + 1)
        self.assertEqual(result["status"], "idle")
        self.assertFalse(result["notify"])
        self.assertFalse(result["sound"])

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


class LinkedCountdownTests(unittest.TestCase):
    setUp = CountdownTests.setUp
    request = CountdownTests.request

    def journal(self):
        if not hasattr(self, "_journal"):
            self._journal = Store(self.profile)
            self.addCleanup(self._journal.close)
        return self._journal

    def record(self, op, **args):
        request = self.request("status")
        request.update(op=op, args=args)
        return self.journal().handle(request)

    def call(self, op, **args):
        return self.store.handle(self.request(op, **args), self.journal())

    def activity(self, title="Synthetic learning"):
        response = self.record("create_activity", title=title,
                               tasks=[{"title": "Ownership"}, {"title": "Borrowing"}])
        return next(row for row in response["snapshot"]["activities"]
                    if row["id"] == response["result"]["activityId"])

    def start(self, activity, task=None, seconds=10):
        state = self.call("status", attach=True)
        return self.call("start", activityId=activity["id"],
                         taskId=activity["tasks"][0]["id"] if task is None else task,
                         seconds=seconds, expectedRevision=state["revision"])

    def finish(self, activity, task=None):
        self.start(activity, task)
        self.clock.now += 10
        return self.call("status")

    def payload(self, state, **changes):
        return dict({"runId": state["runId"], "activityId": state["activityId"],
                     "taskIds": [state["taskId"]] if state["taskId"] else [],
                     "date": "2026-10-29", "note": "Synthetic explicit entry", "done": False}, **changes)

    def test_legacy_running_countdown_migrates_without_journal_link_or_retiming(self):
        self.profile.mkdir()
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("""CREATE TABLE countdown (
                id INTEGER PRIMARY KEY, revision INTEGER, status TEXT, duration INTEGER,
                remaining REAL, deadline REAL, boot TEXT, observer TEXT, muted INTEGER, recovery TEXT)""")
            db.execute("INSERT INTO countdown VALUES (1,7,'running',60,45,145,?,'window-one',1,'')",
                       (self.clock.boot,))
        state = self.store.handle(self.request("status", attach=True))
        self.assertEqual((state["status"], state["revision"], state["remainingSeconds"]), ("running", 7, 45))
        self.assertTrue(state["runId"])
        self.assertEqual((state["activityId"], state["taskId"]), ("", ""))
        self.assertTrue(state["muted"])
        self.assertFalse(state["logPending"])
        self.assertFalse((self.profile / "daylog.sqlite3").exists())
        self.assertEqual(self.store.handle(self.request("status"))["runId"], state["runId"])

    def test_link_survives_pause_reboot_and_finished_restart_without_automatic_entry(self):
        activity = self.activity()
        active = self.start(activity)
        self.clock.now += 3
        paused = self.call("pause", expectedRevision=active["revision"])
        self.assertEqual(paused["remainingSeconds"], 7)
        resumed = self.call("resume", expectedRevision=paused["revision"])
        self.clock.boot, self.clock.now = "synthetic-next-boot", 1
        recovered = CountdownStore(self.profile, clock=self.clock).handle(self.request("status", attach=True), self.journal())
        self.assertEqual((recovered["status"], recovered["remainingSeconds"]), ("paused", 7))
        self.assertEqual(recovered["runId"], active["runId"])
        self.assertEqual(recovered["taskId"], activity["tasks"][0]["id"])
        self.assertEqual(recovered["activityTitle"], activity["title"])
        self.call("resume", expectedRevision=recovered["revision"])
        self.clock.now += 7
        finished = self.call("status")
        restarted = CountdownStore(self.profile, clock=self.clock).handle(self.request("status", attach=True), self.journal())
        self.assertEqual(restarted["status"], "finished")
        self.assertEqual(restarted["runId"], resumed["runId"])
        self.assertFalse(restarted["sound"])
        self.assertEqual(self.record("snapshot")["snapshot"]["sessions"], [])
        self.assertFalse(finished["logSaved"])

    def test_explicit_multitask_log_is_one_untimed_entry_and_replay_is_idempotent(self):
        activity = self.activity()
        state = self.finish(activity)
        payload = self.payload(state, taskIds=[task["id"] for task in activity["tasks"]])
        first = self.call("log", **payload)
        again = self.call("log", **payload)
        self.assertEqual(first["entry"], again["entry"])
        self.assertTrue(again["logSaved"])
        snapshot = self.record("snapshot")["snapshot"]
        self.assertEqual(len(snapshot["sessions"]), 1)
        session = snapshot["sessions"][0]
        self.assertEqual(session["tasks"], [{"id": task["id"], "title": task["title"]}
                                           for task in activity["tasks"]])
        self.assertIsNone(session["minutes"])
        self.assertEqual((session["source"], session["startUtc"], session["endUtc"]), ("untimed", "", ""))
        self.assertEqual(snapshot["activities"][0]["status"], "open")
        self.assertEqual(session["note"], payload["note"])

    def test_whole_activity_zero_tasks_and_explicit_done_are_supported(self):
        activity = self.activity()
        state = self.finish(activity, task="")
        self.call("log", **self.payload(state, taskIds=[], note="", done=True))
        snapshot = self.record("snapshot")["snapshot"]
        self.assertEqual(snapshot["activities"][0]["status"], "done")
        self.assertTrue(snapshot["activities"][0]["tasks"])
        self.assertTrue(all(task["done"] for task in snapshot["activities"][0]["tasks"]))
        self.assertEqual(snapshot["sessions"][0]["tasks"], [])
        self.assertIsNone(snapshot["sessions"][0]["minutes"])

    def test_targets_are_validated_and_active_run_cannot_be_silently_retargeted(self):
        activity, other = self.activity(), self.activity("Other synthetic work")
        state = self.call("status")
        for activity_id, task_id in (("", activity["tasks"][0]["id"]),
                                     (activity["id"], other["tasks"][0]["id"]),
                                     ("missing-activity", "")):
            with self.subTest(activity=activity_id, task=task_id), self.assertRaises(StoreError):
                self.call("start", seconds=10, activityId=activity_id, taskId=task_id,
                          expectedRevision=state["revision"])
        active = self.start(activity)
        with self.assertRaises(StoreError):
            self.call("start", seconds=10, activityId=other["id"], expectedRevision=active["revision"])
        with self.assertRaises(StoreError):
            self.call("pause", activityId=other["id"], expectedRevision=active["revision"])
        self.assertEqual(self.call("status")["activityId"], activity["id"])
        reset = self.call("reset", expectedRevision=active["revision"])
        replacement = self.call("start", seconds=10, activityId=other["id"], expectedRevision=reset["revision"])
        self.assertEqual(replacement["activityId"], other["id"])
        self.assertNotEqual(replacement["runId"], active["runId"])

    def test_finished_link_requires_explicit_dismiss_before_new_run(self):
        state = self.finish(self.activity())
        with self.assertRaises(StoreError):
            self.call("start", seconds=10, expectedRevision=state["revision"])
        reset = self.call("reset", expectedRevision=state["revision"])
        self.assertEqual(reset["status"], "idle")
        self.assertEqual(self.record("snapshot")["snapshot"]["sessions"], [])
        self.assertEqual(self.call("start", seconds=10, expectedRevision=reset["revision"])["activityId"], "")
        with self.assertRaises(StoreError):
            self.call("log", **self.payload(state))

    def test_deleted_or_archived_target_is_visible_and_never_substituted(self):
        for remove_activity in (True, False):
            with self.subTest(delete_activity=remove_activity):
                activity = self.activity()
                state = self.finish(activity)
                if remove_activity:
                    self.record("delete_record", kind="activity", id=activity["id"], expectedRevision=activity["revision"])
                else:
                    self.record("update_activity", activityId=activity["id"], expectedRevision=activity["revision"], tasks=[])
                unavailable = self.call("status")
                self.assertTrue(unavailable["targetError"])
                self.assertEqual(unavailable["activityId"], activity["id"])
                self.assertEqual(unavailable["taskId"], state["taskId"])
                with self.assertRaises(StoreError):
                    self.call("log", **self.payload(state))
                self.assertFalse(self.call("status")["logPending"])
                self.call("reset", expectedRevision=unavailable["revision"])
        self.assertEqual(self.record("snapshot")["snapshot"]["sessions"], [])

    def test_duration_or_altered_activity_is_rejected_before_intent(self):
        activity = self.activity()
        other = self.activity()
        state = self.finish(activity)
        for changes in ({"minutes": 10}, {"startUtc": ""}, {"activityId": other["id"]},
                        {"date": "not-a-date"}, {"taskIds": ["missing"]}):
            with self.subTest(changes=changes), self.assertRaises(StoreError):
                self.call("log", **self.payload(state, **changes))
        self.assertFalse(self.call("status")["logPending"])
        self.assertEqual(self.record("snapshot")["snapshot"]["sessions"], [])

    def test_intent_is_durable_before_journal_write_and_blocks_reset_start_and_edits(self):
        state = self.finish(self.activity())
        payload = self.payload(state)
        submission = self.request("log", **payload)
        def fail_before_journal(request):
            with closing(sqlite3.connect(self.store.path)) as db:
                intent = db.execute("SELECT journal_id,payload,result FROM log_intents").fetchone()
                self.assertIsNotNone(db.execute("SELECT digest FROM receipts WHERE id=?",
                                               (submission["requestId"],)).fetchone())
                self.assertEqual(intent[0], request["requestId"])
                self.assertEqual(json.loads(intent[1]), request["args"])
                self.assertEqual(intent[2], "")
            raise RuntimeError("Synthetic crash before journal write")
        with patch.object(self.journal(), "handle", side_effect=fail_before_journal):
            with self.assertRaises(RuntimeError):
                self.store.handle(submission, self.journal())
        pending = self.call("status", attach=True)
        self.assertTrue(pending["logPending"])
        self.assertEqual(pending["logPayload"]["note"], payload["note"])
        for op, fields in (("reset", {}), ("start", {"seconds": 10})):
            with self.assertRaises(StoreError):
                self.call(op, expectedRevision=pending["revision"], **fields)
        with self.assertRaises(StoreError):
            self.call("log", **dict(payload, note="Different attempt"))
        self.assertEqual(self.record("snapshot")["snapshot"]["sessions"], [])
        restarted = CountdownStore(self.profile, clock=self.clock)
        saved = restarted.handle(self.request("log", **payload), self.journal())
        self.assertTrue(saved["logSaved"])
        self.assertFalse(saved["logPending"])
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)

    def test_lost_journal_ack_reconciles_after_restart_even_after_target_deletion(self):
        activity = self.activity()
        state = self.finish(activity)
        payload = self.payload(state)
        handle = self.journal().handle
        def commit_then_crash(request):
            handle(request)
            raise RuntimeError("Synthetic loss after journal commit")
        with patch.object(self.journal(), "handle", side_effect=commit_then_crash):
            with self.assertRaises(RuntimeError):
                self.call("log", **payload)
        with closing(sqlite3.connect(self.store.path)) as db:
            self.assertEqual(db.execute("SELECT result FROM log_intents").fetchone()[0], "")
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)
        self.record("delete_record", kind="activity", id=activity["id"], expectedRevision=activity["revision"])
        restarted = CountdownStore(self.profile, clock=self.clock)
        recovered = restarted.handle(self.request("status", attach=True), self.journal())
        self.assertTrue(recovered["logSaved"])
        self.assertFalse(recovered["logPending"])
        self.assertTrue(recovered["targetError"])
        replay = restarted.handle(self.request("log", **payload), self.journal())
        self.assertTrue(replay["entry"]["sessionId"])
        self.assertEqual(self.journal().connection.execute("SELECT count(*) FROM sessions").fetchone()[0], 1)

    def test_failed_countdown_ack_commit_keeps_replayable_journal_receipt(self):
        state = self.finish(self.activity())
        payload = self.payload(state)
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("""CREATE TRIGGER reject_log_ack BEFORE UPDATE OF result ON log_intents
                BEGIN SELECT RAISE(ABORT, 'synthetic acknowledgement failure'); END""")
        with self.assertRaises(sqlite3.IntegrityError):
            self.call("log", **payload)
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)
        with closing(sqlite3.connect(self.store.path)) as db, db:
            self.assertEqual(db.execute("SELECT result FROM log_intents").fetchone()[0], "")
            db.execute("DROP TRIGGER reject_log_ack")
        self.assertTrue(self.call("status")["logSaved"])
        self.call("log", **payload)
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)

    def test_retry_after_success_and_new_run_does_not_replace_or_duplicate(self):
        activity = self.activity()
        state = self.finish(activity)
        payload = self.payload(state)
        saved = self.call("log", **payload)
        reset = self.call("reset", expectedRevision=saved["revision"])
        active = self.call("start", seconds=90, expectedRevision=reset["revision"])
        replay = self.call("log", **payload)
        self.assertEqual(replay["entry"], saved["entry"])
        self.assertEqual((replay["status"], replay["runId"]), ("running", active["runId"]))
        with self.assertRaises(StoreError):
            self.call("log", **dict(payload, done=True))
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)

    def test_concurrent_log_retries_create_one_real_journal_entry(self):
        state = self.finish(self.activity())
        payload = self.payload(state)
        requests = [self.request("log", **payload), self.request("log", **payload)]
        def save(request):
            with Store(self.profile) as journal:
                return CountdownStore(self.profile, clock=self.clock).handle(request, journal)["entry"]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(save, requests))
        self.assertEqual(results[0], results[1])
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)

    def test_log_request_identity_cannot_be_reused_for_another_payload(self):
        state = self.finish(self.activity())
        request = self.request("log", **self.payload(state))
        saved = self.store.handle(request, self.journal())
        self.assertEqual(self.store.handle(request, self.journal())["entry"], saved["entry"])
        altered = dict(request, args=dict(request["args"], note="Different request contents"))
        with self.assertRaises(StoreError) as error:
            self.store.handle(altered, self.journal())
        self.assertEqual(error.exception.code, "conflict")
        self.assertEqual(len(self.record("snapshot")["snapshot"]["sessions"]), 1)

    def test_archive_between_intent_and_journal_write_rejects_even_deselected_target(self):
        activity = self.activity()
        state = self.finish(activity)
        payload = self.payload(state, taskIds=[])
        handle = self.journal().handle
        def archive_then_save(request):
            handle({"protocol": 1, "requestId": "synthetic-archive-race", "op": "update_activity",
                    "args": {"activityId": activity["id"], "expectedRevision": activity["revision"], "tasks": []}})
            return handle(request)
        with patch.object(self.journal(), "handle", side_effect=archive_then_save):
            with self.assertRaises(StoreError):
                self.call("log", **payload)
        self.assertEqual(self.record("snapshot")["snapshot"]["sessions"], [])
        rejected = self.call("status")
        self.assertTrue(rejected["targetError"])
        self.assertFalse(rejected["logPending"])
        self.assertEqual(self.call("reset", expectedRevision=rejected["revision"])["status"], "idle")

    def test_helper_linked_log_returns_confirmed_postsave_snapshot(self):
        def invoke(op, **args):
            request = self.request("status")
            request.update(op=op, args=args)
            process = subprocess.run([sys.executable, str(SOURCE_ROOT / "backend/helper.py"),
                                      "--profile", str(self.profile)], input=json.dumps(request),
                                     text=True, capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            response = json.loads(process.stdout)
            self.assertTrue(response["ok"], response)
            self.assertEqual(response["requestId"], request["requestId"])
            return response
        created = invoke("create_activity", title="Synthetic helper linked work", tasks=[{"title": "Read"}])
        activity = created["snapshot"]["activities"][0]
        started = invoke("countdown_start", observer="synthetic-helper", expectedRevision=0, seconds=60,
                         activityId=activity["id"], taskId=activity["tasks"][0]["id"])
        self.assertEqual(started["snapshot"]["sessions"], [])
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("UPDATE countdown SET deadline=0")
        finished = invoke("countdown_status", observer="synthetic-helper", attach=True)["result"]
        self.assertEqual(finished["status"], "finished")
        self.assertFalse(finished["sound"])
        payload = self.payload(finished)
        saved = invoke("countdown_log", observer="synthetic-helper", **payload)
        self.assertTrue(saved["result"]["logSaved"])
        self.assertEqual(saved["result"]["entry"]["sessionId"], saved["snapshot"]["sessions"][0]["id"])
        self.assertEqual(len(saved["snapshot"]["sessions"]), 1)
        replay = invoke("countdown_log", observer="synthetic-restarted-helper", **payload)
        self.assertEqual(replay["result"]["entry"], saved["result"]["entry"])
        self.assertEqual(len(replay["snapshot"]["sessions"]), 1)


if __name__ == "__main__":
    unittest.main()
