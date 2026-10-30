"""Permanent activity cleanup through the public journal/countdown consumers."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from dataclasses import replace
from datetime import date, datetime, timezone
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
from threading import Barrier
import unittest
from unittest.mock import patch

from backend.countdown import CountdownStore
from backend.portability import COLUMNS
from backend.storage import SOURCE_ROOT, Store, StoreError
from backend.timer import ClockSample


class LocalDate(date):
    current = date(2030, 1, 2)

    @classmethod
    def today(cls):
        return cls.current


class LegacyClock:
    def __init__(self):
        wall = datetime(2030, 1, 2, 23, 59, 55, tzinfo=timezone.utc).timestamp()
        self.value = ClockSample(wall, 100.0, 100.0, "cleanup-test-boot", "UTC", 0)

    def sample(self):
        return self.value

    def owner(self):
        return 123, "cleanup-test-owner"

    def alive(self, pid, start):
        return (pid, start) == self.owner()

    def advance(self, seconds):
        self.value = replace(self.value, wall=self.value.wall + seconds,
                             mono=self.value.mono + seconds, boot=self.value.boot + seconds)


class CountdownClock:
    now = 100.0

    def sample(self):
        return "cleanup-countdown-boot", self.now


class ActivityCleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="daymark-activity-cleanup-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.profile = self.root / "profile"
        LocalDate.current = date(2030, 1, 2)
        patched_date = patch("backend.storage.date", LocalDate)
        patched_date.start()
        self.addCleanup(patched_date.stop)
        self.clock = LegacyClock()
        self.store = Store(self.profile, clock=self.clock)
        self.addCleanup(self.store.close)
        self.countdown_clock = CountdownClock()
        self.countdown = CountdownStore(self.profile, clock=self.countdown_clock)
        self.sequence = 0

    def request(self, op, args=None, *, owner=False):
        self.sequence += 1
        request = {"protocol": 1, "requestId": f"cleanup-{self.sequence}", "op": op, "args": args or {}}
        if owner:
            request["clientId"] = "cleanup-test-client"
        return request

    def call(self, op, args=None, **options):
        return self.store.handle(self.request(op, args, **options))

    def timer(self, op, **args):
        return self.countdown.handle(self.request("countdown_" + op, {"observer": "cleanup-test", **args}), self.store)

    def completed_countdown_entry(self, activity_id, day, note, task_id=""):
        idle = self.timer("status")
        self.timer("start", seconds=1, activityId=activity_id, taskId=task_id, expectedRevision=idle["revision"])
        self.countdown_clock.now += 1
        finished = self.timer("status")
        payload = {"runId": finished["runId"], "activityId": activity_id,
                   "taskIds": [task_id] if task_id else [], "date": day, "note": note, "done": False}
        saved = self.timer("log", **payload)
        self.timer("reset", expectedRevision=saved["revision"])
        return payload, saved["entry"]

    def countdown_rows(self):
        with closing(sqlite3.connect(self.countdown.path)) as db:
            db.row_factory = sqlite3.Row
            return {table: [dict(row) for row in db.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                    for table in ("countdown", "receipts", "log_intents")}

    def snapshot(self):
        return self.call("snapshot")["snapshot"]

    def cleanup_request(self, op, **args):
        fields = {"expectedRevision": self.snapshot()["revision"]}
        if op == "reset_today_entries":
            fields["date"] = LocalDate.today().isoformat()
        return self.request(op, {**fields, **args})

    def rows(self):
        tables = [*COLUMNS, "metadata", "schema_migrations", "request_receipts"]
        return {table: [dict(row) for row in self.store.connection.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                for table in tables}

    def rejected(self, request, code, *, store=None):
        with self.assertRaises(StoreError) as caught:
            (store or self.store).handle(request)
        self.assertEqual(caught.exception.code, code)

    def create(self, **args):
        return self.call("create_activity", {"title": "SYNTHETIC cleanup activity", **args})

    def seed_mixed_records(self):
        created = self.create(category="SYNTHETIC category", project="SYNTHETIC project",
                              plannedFor="2030-01-01", pinned=True,
                              tasks=[{"title": "Original task"}, {"title": "Archived task"}])
        activity = created["snapshot"]["activities"][0]
        task_ids = [task["id"] for task in activity["tasks"]]
        self.call("add_session", {"activityId": activity["id"], "date": "2030-01-01", "taskIds": task_ids,
                                  "note": "SYNTHETIC yesterday"})
        updated = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                                                "plannedFor": "2030-01-03",
                                                "tasks": [{"id": task_ids[0], "title": "Renamed task"}]})
        activity = updated["snapshot"]["activities"][0]
        self.call("set_task_done", {"activityId": activity["id"], "taskId": task_ids[0], "done": True,
                                   "expectedRevision": activity["revision"]})
        self.call("add_session", {"activityId": activity["id"], "date": "2030-01-02", "taskIds": [task_ids[0]],
                                  "note": "SYNTHETIC today"})
        self.call("add_session", {"activityId": activity["id"], "date": "2030-01-03", "minutes": 5,
                                  "note": "SYNTHETIC future"})
        for day in ("2030-01-01", "2030-01-02"):
            session = self.call("add_session", {"activityId": activity["id"], "date": day})["result"]
            self.call("delete_record", {"kind": "session", "id": session["sessionId"], "expectedRevision": 1})
        hidden = self.create(title="SYNTHETIC trashed activity", category="Only hidden activity",
                             tasks=[{"title": "Hidden task"}])["result"]["activityId"]
        for day in ("2030-01-01", "2030-01-02"):
            self.call("add_session", {"activityId": hidden, "date": day})
        self.call("delete_record", {"kind": "activity", "id": hidden, "expectedRevision": 1})
        legacy = self.create(title="SYNTHETIC stopped legacy timer")["result"]["activityId"]
        timer = self.call("timer_start", {"activityId": legacy}, owner=True)["result"]
        self.clock.advance(10)  # One entry/interval crosses midnight; its recorded date stays January 2.
        self.call("timer_stop", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]}, owner=True)
        self.call("save_note", {"date": "2030-01-02", "body": "SYNTHETIC Diary stays", "expectedRevision": 0})
        self.call("save_note", {"date": "2030-01-01", "body": "SYNTHETIC Diary trash stays", "expectedRevision": 0})
        self.call("delete_record", {"kind": "note", "id": "2030-01-01", "expectedRevision": 1})
        return activity["id"]

    def test_reset_removes_only_recorded_today_including_trash_and_interval_children(self):
        self.seed_mixed_records()
        before = self.rows()
        erased = {row["id"] for row in before["sessions"] if row["local_date"] == "2030-01-02"}
        response = self.store.handle(self.cleanup_request("reset_today_entries"))
        self.assertEqual(response["result"], {"deletedEntries": len(erased), "deletedActivities": 0})
        after = self.rows()
        for table in ("activities", "activity_tasks", "activity_events", "day_notes", "categories", "projects", "schema_migrations"):
            self.assertEqual(after[table], before[table], table)
        self.assertEqual(after["sessions"], [row for row in before["sessions"] if row["id"] not in erased])
        for table in ("session_tasks", "timer_sessions", "session_intervals"):
            self.assertEqual(after[table], [row for row in before[table] if row["session_id"] not in erased], table)
        self.assertEqual(after["trash"], [row for row in before["trash"]
                                         if row["kind"] != "session" or row["record_id"] not in erased])
        self.assertEqual(after["request_receipts"][:-1], before["request_receipts"])
        self.assertEqual(response["snapshot"]["revision"], before["metadata"][0]["revision"] + 1)
        self.assertFalse(any(row["date"] == "2030-01-02" for row in response["snapshot"]["sessions"]))
        self.assertEqual(self.store.connection.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_wipe_clears_every_activity_table_and_label_but_preserves_diary_and_external_files(self):
        self.seed_mixed_records()
        self.timer("status")
        self.call("export_records", {"path": str(self.root / "activities.json"), "format": "json", "scope": "activities"})
        backup = self.root / "existing-backup.sqlite3"
        with closing(sqlite3.connect(backup)) as db:
            self.store.connection.backup(db)
        for name in ("settings.sqlite3", "calendar.sqlite3"):
            with closing(sqlite3.connect(self.profile / name)) as db, db:
                db.execute("CREATE TABLE synthetic (value TEXT)")
                db.execute("INSERT INTO synthetic VALUES ('SYNTHETIC preserved settings/cache')")
        preserved_paths = [self.root / "activities.json", backup, self.profile / "settings.sqlite3",
                           self.profile / "calendar.sqlite3", self.profile / "countdown.sqlite3"]
        files_before = {path: path.read_bytes() for path in preserved_paths}
        profile_files = set(self.profile.iterdir())
        before = self.rows()
        for table in ("sessions", "session_tasks", "timer_sessions", "session_intervals", "activity_tasks", "activity_events"):
            self.assertTrue(before[table], table)
        response = self.store.handle(self.cleanup_request("wipe_activity_data"))
        self.assertEqual(response["result"], {"deletedEntries": len(before["sessions"]),
                                             "deletedActivities": len(before["activities"])})
        after = self.rows()
        for table in ("activities", "sessions", "activity_tasks", "session_tasks", "timer_sessions",
                      "session_intervals", "activity_events", "categories", "projects"):
            self.assertEqual(after[table], [], table)
        self.assertEqual(after["day_notes"], before["day_notes"])
        self.assertEqual(after["trash"], [row for row in before["trash"] if row["kind"] == "note"])
        self.assertEqual(after["schema_migrations"], before["schema_migrations"])
        self.assertEqual(after["request_receipts"][:-1], before["request_receipts"])
        self.assertEqual(after["metadata"][0]["revision"], before["metadata"][0]["revision"] + 1)
        self.assertEqual(self.store.connection.execute("PRAGMA foreign_key_check").fetchall(), [])
        self.assertEqual({path: path.read_bytes() for path in preserved_paths}, files_before)
        self.assertEqual(set(self.profile.iterdir()), profile_files)
        self.assertEqual(response["snapshot"]["activities"], [])
        self.assertEqual(response["snapshot"]["sessions"], [])
        self.assertEqual(response["snapshot"]["dayNotes"]["2030-01-02"]["body"], "SYNTHETIC Diary stays")
        reopened = Store(self.profile)
        self.addCleanup(reopened.close)
        self.assertEqual(reopened.handle(self.request("snapshot"))["snapshot"], response["snapshot"])

    def test_stale_revision_missing_revision_and_invalid_revision_never_delete(self):
        self.seed_mixed_records()
        stale = self.snapshot()["revision"]
        self.call("save_note", {"date": "2030-01-03", "body": "A concurrent Diary save", "expectedRevision": 0})
        before = self.rows()
        for op in ("reset_today_entries", "wipe_activity_data"):
            for value, code in ((stale, "conflict"), (None, "validation"), (True, "validation"),
                                (-1, "validation"), ("1", "validation")):
                with self.subTest(op=op, revision=value):
                    self.rejected(self.cleanup_request(op, expectedRevision=value), code)
                    self.assertEqual(self.rows(), before)

    def test_reset_rejects_old_future_or_invalid_day_without_touching_next_day(self):
        self.seed_mixed_records()
        before = self.rows()
        for value, code in (("2030-01-01", "conflict"), ("2030-01-03", "conflict"),
                            ("2030-02-30", "validation"), (None, "validation")):
            with self.subTest(date=value):
                self.rejected(self.cleanup_request("reset_today_entries", date=value), code)
                self.assertEqual(self.rows(), before)
        request = self.cleanup_request("reset_today_entries")
        LocalDate.current = date(2030, 1, 3)
        self.rejected(request, "conflict")
        self.assertEqual(self.rows(), before)

    def test_reset_receipt_survives_midnight_and_old_save_retry_without_deleting_new_entries(self):
        create = self.request("create_activity", {"title": "SYNTHETIC replay", "mode": "log", "date": "2030-01-02"})
        created = self.store.handle(create)
        activity_id = created["result"]["activityId"]
        add = self.request("add_session", {"activityId": activity_id, "date": "2030-01-02", "note": "SYNTHETIC original"})
        added = self.store.handle(add)
        request = self.cleanup_request("reset_today_entries")
        erased = self.store.handle(request)
        LocalDate.current = date(2030, 1, 3)
        newer = self.call("add_session", {"activityId": activity_id, "date": "2030-01-03"})
        before = self.rows()
        for old_request, result in ((request, erased["result"]), (create, created["result"]), (add, added["result"])):
            replay = self.store.handle(old_request)
            self.assertEqual(replay["result"], result)
            self.assertEqual(replay["snapshot"], newer["snapshot"])
            self.assertEqual(self.rows(), before)
        reused = dict(request, args=dict(request["args"], date="2030-01-03"))
        self.rejected(reused, "conflict")
        self.assertEqual(self.rows(), before)

    def test_wipe_receipts_survive_reopen_and_never_resurrect_or_redelete_work(self):
        create = self.request("create_activity", {"title": "SYNTHETIC erased", "category": "Old label",
                                                "mode": "log", "date": "2030-01-02"})
        original = self.store.handle(create)
        request = self.cleanup_request("wipe_activity_data")
        first = self.store.handle(request)
        newer = self.create(title="SYNTHETIC after wipe", category="New label")
        before = self.rows()
        with Store(self.profile) as reopened:
            for old_request, result in ((request, first["result"]), (create, original["result"])):
                replay = reopened.handle(old_request)
                self.assertEqual(replay["result"], result)
                self.assertEqual(replay["snapshot"], newer["snapshot"])
        self.assertEqual(self.rows(), before)
        self.rejected(dict(request, args={"expectedRevision": newer["snapshot"]["revision"]}), "conflict")
        self.assertEqual(self.rows(), before)

    def test_empty_cleanup_has_a_durable_receipt_that_cannot_delete_later_data(self):
        for op in ("reset_today_entries", "wipe_activity_data"):
            with self.subTest(op=op):
                request = self.cleanup_request(op)
                first = self.store.handle(request)
                self.assertEqual(first["result"], {"deletedEntries": 0, "deletedActivities": 0})
                newer = self.create(mode="log", date="2030-01-02")
                replay = self.store.handle(request)
                self.assertEqual(replay["result"], first["result"])
                self.assertEqual(replay["snapshot"], newer["snapshot"])
                self.store.handle(self.cleanup_request("wipe_activity_data"))

    def test_read_only_rejects_new_cleanup_and_receipt_replay(self):
        self.seed_mixed_records()
        saved = self.cleanup_request("reset_today_entries")
        self.store.handle(saved)
        before = self.rows()
        with Store(self.profile, read_only=True) as readonly:
            for request in (saved, self.cleanup_request("reset_today_entries"), self.cleanup_request("wipe_activity_data")):
                self.rejected(request, "read_only", store=readonly)
        self.assertEqual(self.rows(), before)

    def test_failure_after_child_deletions_rolls_back_every_row_and_receipt(self):
        self.seed_mixed_records()
        for op, table in (("reset_today_entries", "sessions"), ("wipe_activity_data", "activities")):
            with self.subTest(op=op):
                request = self.cleanup_request(op)
                before = self.rows()
                self.store.connection.execute(f"CREATE TRIGGER reject_cleanup BEFORE DELETE ON {table} "
                                              "BEGIN SELECT RAISE(ABORT, 'synthetic cleanup failure'); END")
                self.rejected(request, "storage")
                self.assertEqual(self.rows(), before)
                self.store.connection.execute("DROP TRIGGER reject_cleanup")
                response = self.store.handle(request)
                self.assertGreater(response["result"]["deletedEntries"] + response["result"]["deletedActivities"], 0)

    def test_unfinished_legacy_timers_reject_without_clock_latching_or_completion_changes(self):
        activity_id = self.create()["result"]["activityId"]
        timer = self.call("timer_start", {"activityId": activity_id}, owner=True)["result"]
        for state in ("running", "paused", "interrupted"):
            if state == "paused":
                self.call("timer_pause", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]}, owner=True)
            elif state == "interrupted":
                self.call("timer_resume", {"sessionId": timer["sessionId"]}, owner=True)
                self.clock.advance(100)
                self.call("snapshot", owner=True)
            before = self.rows()
            self.assertEqual(before["timer_sessions"][0]["status"], state)
            for op in ("reset_today_entries", "wipe_activity_data"):
                request = self.cleanup_request(op)
                request["clientId"] = "obsolete-owner"
                with patch.object(self.clock, "sample", side_effect=AssertionError("Cleanup sampled a legacy clock")):
                    self.rejected(request, "timer_unfinished")
                self.assertEqual(self.rows(), before)
        self.call("settle_legacy_timers")
        self.assertEqual(self.store.handle(self.cleanup_request("wipe_activity_data"))["result"],
                         {"deletedEntries": 1, "deletedActivities": 1})

    def test_countdown_running_paused_and_finished_linked_states_block_both_operations(self):
        activity_id = self.create()["result"]["activityId"]
        active = self.timer("start", seconds=10, expectedRevision=0)
        for state in ("running", "paused", "finished-linked"):
            if state == "paused":
                active = self.timer("pause", expectedRevision=active["revision"])
            elif state == "finished-linked":
                idle = self.timer("reset", expectedRevision=active["revision"])
                self.timer("start", seconds=10, activityId=activity_id, expectedRevision=idle["revision"])
                self.countdown_clock.now += 10
                active = self.timer("status")
            before = self.rows()
            countdown_before = self.countdown.path.read_bytes()
            for op in ("reset_today_entries", "wipe_activity_data"):
                self.rejected(self.cleanup_request(op), "conflict")
                self.assertEqual(self.rows(), before)
                self.assertEqual(self.countdown.path.read_bytes(), countdown_before)
        self.timer("reset", expectedRevision=active["revision"])
        self.store.handle(self.cleanup_request("wipe_activity_data"))

    def test_finished_standalone_countdown_is_unchanged_and_cleanup_replay_ignores_new_run(self):
        self.create(mode="log", date="2030-01-02")
        self.timer("start", seconds=1, expectedRevision=0)
        self.countdown_clock.now += 1
        finished = self.timer("status")
        before = self.countdown.path.read_bytes()
        request = self.cleanup_request("wipe_activity_data")
        first = self.store.handle(request)
        self.assertEqual(self.countdown.path.read_bytes(), before)
        self.timer("start", seconds=30, expectedRevision=finished["revision"])
        replay = self.store.handle(request)
        self.assertEqual(replay, first)

    def test_pending_countdown_log_cannot_race_cleanup_and_committed_retries_cannot_recreate(self):
        activity_id = self.create()["result"]["activityId"]
        self.timer("start", seconds=1, activityId=activity_id, expectedRevision=0)
        self.countdown_clock.now += 1
        finished = self.timer("status")
        payload = {"runId": finished["runId"], "activityId": activity_id, "taskIds": [], "date": "2030-01-02",
                   "note": "SYNTHETIC durable log intent", "done": False}
        with patch.object(self.store, "handle", side_effect=StoreError("storage", "Synthetic ambiguous journal write")):
            with self.assertRaises(StoreError):
                self.timer("log", **payload)
        pending = self.timer("status")
        self.assertTrue(pending["logPending"])
        before = self.rows()
        for op in ("reset_today_entries", "wipe_activity_data"):
            self.rejected(self.cleanup_request(op), "conflict")
            self.assertEqual(self.rows(), before)
        saved = self.timer("log", **payload)
        self.assertTrue(saved["logSaved"])
        self.timer("reset", expectedRevision=saved["revision"])
        erased = self.store.handle(self.cleanup_request("reset_today_entries"))
        self.assertEqual(erased["result"]["deletedEntries"], 1)
        replay = self.timer("log", **payload)
        self.assertEqual(replay["entry"], saved["entry"])
        self.assertEqual(self.snapshot()["sessions"], [])
        self.store.handle(self.cleanup_request("wipe_activity_data"))
        self.assertEqual(self.timer("log", **payload)["entry"], saved["entry"])
        self.assertEqual(self.snapshot()["activities"], [])

    def test_cleanup_reserves_countdown_before_journal_and_releases_on_rejection(self):
        self.timer("status")
        request = self.cleanup_request("wipe_activity_data")
        before = self.rows()
        with closing(sqlite3.connect(self.countdown.path)) as locked:
            locked.execute("BEGIN IMMEDIATE")
            self.rejected(request, "busy")
            self.assertFalse(self.store.connection.in_transaction)
            self.assertEqual(self.rows(), before)
            locked.rollback()
        self.assertTrue(self.store.handle(request)["ok"])

    def test_countdown_symlink_is_rejected_without_touching_target_or_journal(self):
        self.create(mode="log", date="2030-01-02")
        target = self.root / "unrelated"
        target.write_bytes(b"SYNTHETIC unrelated bytes")
        self.countdown.path.symlink_to(target)
        before = self.rows()
        self.rejected(self.cleanup_request("wipe_activity_data"), "storage")
        self.assertEqual(target.read_bytes(), b"SYNTHETIC unrelated bytes")
        self.assertEqual(self.rows(), before)

    def test_concurrent_cleanup_serializes_revision_checks_and_identical_replays(self):
        for same_request in (False, True):
            with self.subTest(same_request=same_request):
                self.create(mode="log", date="2030-01-02")
                request = self.cleanup_request("wipe_activity_data")
                second = request if same_request else self.request("wipe_activity_data", request["args"])
                barrier = Barrier(2)

                def cleanup(payload):
                    with Store(self.profile) as journal:
                        barrier.wait(timeout=5)
                        try:
                            return journal.handle(payload)
                        except StoreError as error:
                            return error.code

                with ThreadPoolExecutor(max_workers=2) as pool:
                    results = list(pool.map(cleanup, (request, second)))
                responses = [result for result in results if isinstance(result, dict)]
                self.assertEqual(len(responses), 2 if same_request else 1)
                if same_request:
                    self.assertEqual(responses[0], responses[1])
                else:
                    self.assertIn("conflict", results)
                self.assertEqual(responses[0]["result"], {"deletedEntries": 1, "deletedActivities": 1})
                self.assertEqual(self.snapshot()["activities"], [])

    def test_reset_redacts_only_erased_intents_and_wipe_retains_digest_only_replays(self):
        activity = self.create(title="SYNTHETIC target title", tasks=[{"title": "SYNTHETIC task title"}])["snapshot"]["activities"][0]
        task_id = activity["tasks"][0]["id"]
        yesterday = self.completed_countdown_entry(activity["id"], "2030-01-01", "SYNTHETIC old note", task_id)
        today = self.completed_countdown_entry(activity["id"], "2030-01-02", "SYNTHETIC erased note 日本語", task_id)
        before = self.countdown_rows()
        self.store.handle(self.cleanup_request("reset_today_entries"))
        after = self.countdown_rows()
        self.assertEqual(after["countdown"], before["countdown"])
        self.assertEqual(after["receipts"], before["receipts"])
        self.assertEqual(after["log_intents"][0], before["log_intents"][0])
        erased = json.loads(after["log_intents"][1]["payload"])
        self.assertEqual(set(erased), {"countdownTaskId", "erasedPayloadDigest"})
        self.assertEqual(erased["countdownTaskId"], task_id)
        self.assertNotIn(today[0]["note"], repr(after))
        for payload, entry in (yesterday, today):
            self.assertEqual(self.timer("log", **payload)["entry"], entry)
        with self.assertRaises(StoreError) as changed:
            self.timer("log", **dict(today[0], note="SYNTHETIC changed replay"))
        self.assertEqual(changed.exception.code, "conflict")
        self.assertEqual(len(self.snapshot()["sessions"]), 1)
        self.store.handle(self.cleanup_request("wipe_activity_data"))
        wiped = self.countdown_rows()
        for intent in wiped["log_intents"]:
            self.assertEqual(set(json.loads(intent["payload"])), {"countdownTaskId", "erasedPayloadDigest"})
        for text in (yesterday[0]["note"], today[0]["note"], activity["title"], activity["tasks"][0]["title"]):
            self.assertNotIn(text, repr(wiped))
        for payload, entry in (yesterday, today):
            self.assertEqual(self.timer("log", **payload)["entry"], entry)
        self.assertEqual(self.snapshot()["activities"], [])
        self.assertEqual(self.snapshot()["sessions"], [])

    def test_reset_uses_entry_current_date_when_redacting_a_moved_countdown_log(self):
        activity_id = self.create()["result"]["activityId"]
        moved_in = self.completed_countdown_entry(activity_id, "2030-01-01", "SYNTHETIC moved into today")
        moved_out = self.completed_countdown_entry(activity_id, "2030-01-02", "SYNTHETIC moved out of today")
        self.call("update_session", {"sessionId": moved_in[1]["sessionId"], "expectedRevision": 1, "date": "2030-01-02"})
        self.call("update_session", {"sessionId": moved_out[1]["sessionId"], "expectedRevision": 1, "date": "2030-01-03"})
        before = self.countdown_rows()
        self.store.handle(self.cleanup_request("reset_today_entries"))
        after = self.countdown_rows()
        self.assertIn("erasedPayloadDigest", json.loads(after["log_intents"][0]["payload"]))
        self.assertEqual(after["log_intents"][1], before["log_intents"][1])
        self.assertEqual(self.snapshot()["sessions"][0]["id"], moved_out[1]["sessionId"])

    def test_attached_cleanup_failure_rolls_back_intent_redaction_and_both_databases(self):
        activity_id = self.create()["result"]["activityId"]
        self.completed_countdown_entry(activity_id, "2030-01-02", "SYNTHETIC atomic deletion")
        for op, table in (("reset_today_entries", "sessions"), ("wipe_activity_data", "activities")):
            with self.subTest(op=op):
                request = self.cleanup_request(op)
                before, countdown_before = self.rows(), self.countdown_rows()
                original_connection = self.store.connection
                self.store.connection.execute(f"CREATE TRIGGER reject_attached_cleanup BEFORE DELETE ON {table} "
                                              "BEGIN SELECT RAISE(ABORT, 'synthetic attached failure'); END")
                self.rejected(request, "storage")
                self.assertIs(self.store.connection, original_connection)
                self.assertFalse(original_connection.in_transaction)
                self.assertEqual(self.rows(), before)
                self.assertEqual(self.countdown_rows(), countdown_before)
                self.store.connection.execute("DROP TRIGGER reject_attached_cleanup")
        self.store.handle(self.cleanup_request("wipe_activity_data"))
        self.assertIn("erasedPayloadDigest", json.loads(self.countdown_rows()["log_intents"][0]["payload"]))
        self.assertEqual(self.snapshot()["sessions"], [])

    def test_wipe_scrubs_import_conflict_labels_but_keeps_diary_receipts_and_replay_identity(self):
        activity_id = self.seed_mixed_records()
        activity_path, diary_path = self.root / "activities.json", self.root / "diary.json"
        for scope, path in (("activities", activity_path), ("diary", diary_path)):
            self.call("export_records", {"path": str(path), "format": "json", "scope": scope})
        before = self.snapshot()
        for kind, rows in (("category", before["categories"]), ("project", before["projects"])):
            for row in rows:
                self.call("update_label", {"kind": kind, "id": row["id"], "name": "Renamed " + row["name"],
                                          "archived": False, "expectedRevision": row["revision"]})
        activity = next(row for row in self.snapshot()["activities"] if row["id"] == activity_id)
        self.call("update_activity", {"activityId": activity_id, "expectedRevision": activity["revision"],
                                      "title": "SYNTHETIC newer destination title"})
        self.call("save_note", {"date": "2030-01-02", "body": "SYNTHETIC retained Diary revision", "expectedRevision": 1})
        requests = []
        for path in (activity_path, diary_path):
            request = self.request("restore_records", {"path": str(path), "expectedRevision": self.snapshot()["revision"]})
            response = self.store.handle(request)
            self.assertTrue(response["result"]["conflicts"])
            requests.append(request)
        receipts = {row["request_id"]: row for row in self.rows()["request_receipts"]}
        notes_before = self.rows()["day_notes"]
        self.store.handle(self.cleanup_request("wipe_activity_data"))
        after = {row["request_id"]: row for row in self.rows()["request_receipts"]}
        for request in requests:
            old, new = receipts[request["requestId"]], after[request["requestId"]]
            self.assertEqual(new["digest"], old["digest"])
            result = json.loads(new["result"])
            for old_conflict, conflict in zip(json.loads(old["result"])["conflicts"], result["conflicts"]):
                if conflict["table"] in ("categories", "projects", "activities", "sessions", "activity_events"):
                    self.assertEqual(conflict, dict(old_conflict, label="Deleted activity data"))
                else:
                    self.assertEqual(conflict, old_conflict)
            self.assertEqual(self.store.handle(request)["result"], result)
        self.assertEqual(self.rows()["day_notes"], notes_before)
        self.assertEqual(self.snapshot()["activities"], [])
        for erased_text in ("SYNTHETIC cleanup activity", "SYNTHETIC category", "SYNTHETIC project",
                            "SYNTHETIC newer destination title"):
            self.assertNotIn(erased_text, repr(self.rows()))

    def test_wipe_clears_inactive_target_titles_without_changing_clock_or_settings(self):
        self.timer("status")
        with closing(sqlite3.connect(self.countdown.path)) as db, db:
            db.execute("UPDATE countdown SET activity_title='SYNTHETIC old title',task_title='SYNTHETIC old task',muted=1")
        before = self.countdown_rows()
        self.store.handle(self.cleanup_request("wipe_activity_data"))
        after = self.countdown_rows()
        self.assertEqual(after["countdown"], [dict(before["countdown"][0], activity_title="", task_title="",
                                                  revision=before["countdown"][0]["revision"] + 1)])
        self.assertEqual(after["receipts"], before["receipts"])
        self.assertEqual(after["log_intents"], before["log_intents"])

    def test_attached_cleanup_rejects_wal_without_changing_data_or_journal_mode(self):
        self.create(mode="log", date="2030-01-02")
        self.timer("status")
        before, countdown_before = self.rows(), self.countdown_rows()
        for path in (self.store.db_path, self.countdown.path):
            with self.subTest(database=path.name):
                self.store.close()
                with closing(sqlite3.connect(path)) as db:
                    self.assertEqual(db.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
                self.store = Store(self.profile, clock=self.clock)
                self.addCleanup(self.store.close)
                request = self.cleanup_request("wipe_activity_data")
                with self.assertRaises(StoreError) as caught:
                    self.store.handle(request)
                self.assertEqual(caught.exception.code, "storage")
                self.assertIn("DELETE journal mode", caught.exception.message)
                self.assertEqual(self.rows(), before)
                self.assertEqual(self.countdown_rows(), countdown_before)
                self.store.close()
                with closing(sqlite3.connect(path)) as db:
                    self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "wal")
                    db.execute("PRAGMA journal_mode=DELETE")
                self.store = Store(self.profile, clock=self.clock)
                self.addCleanup(self.store.close)

    def test_attached_cleanup_refuses_shadowed_journal_tables(self):
        self.timer("status")
        with closing(sqlite3.connect(self.countdown.path)) as db, db:
            db.execute("CREATE TABLE sessions (id TEXT)")
        before, countdown_before = self.rows(), self.countdown_rows()
        self.rejected(self.cleanup_request("wipe_activity_data"), "storage")
        self.assertEqual(self.rows(), before)
        self.assertEqual(self.countdown_rows(), countdown_before)

    def test_helper_accepts_both_operations_with_standard_snapshot_envelope(self):
        # Separate processes use the real local day; fixed-date cases above test
        # midnight deterministically without adding a clock override to production.
        def invoke(request):
            process = subprocess.run([sys.executable, str(SOURCE_ROOT / "backend/helper.py"),
                                      "--profile", str(self.profile)], input=json.dumps(request), text=True,
                                     capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stderr, "")
            response = json.loads(process.stdout)
            self.assertTrue(response["ok"], response)
            self.assertEqual(response["requestId"], request["requestId"])
            self.assertEqual(response["protocol"], 1)
            return response

        current = invoke(self.request("snapshot"))["snapshot"]
        created = invoke(self.request("create_activity", {"title": "SYNTHETIC helper consumer", "mode": "log",
                                                           "date": current["today"]}))
        reset = invoke(self.request("reset_today_entries", {"date": current["today"],
                                                             "expectedRevision": created["snapshot"]["revision"]}))
        self.assertEqual(reset["result"], {"deletedEntries": 1, "deletedActivities": 0})
        wiped = invoke(self.request("wipe_activity_data", {"expectedRevision": reset["snapshot"]["revision"]}))
        self.assertEqual(wiped["result"], {"deletedEntries": 0, "deletedActivities": 1})
        self.assertEqual(wiped["snapshot"]["activities"], [])


if __name__ == "__main__":
    unittest.main()
