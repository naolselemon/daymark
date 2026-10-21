"""No-timer journal cutover against isolated canonical profiles and real archives."""

from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from backend.portability import COLUMNS
from backend.storage import Store, StoreError
from backend.timer import ClockSample


class LegacyClock:
    def __init__(self):
        wall = datetime(2025, 1, 2, 23, 59, 55, tzinfo=timezone.utc).timestamp()
        self.value = ClockSample(wall, 100.0, 100.0, "legacy-boot", "UTC", 0)

    def sample(self):
        return self.value

    def owner(self):
        return 123, "legacy-process"

    def alive(self, pid, start):
        return (pid, start) == self.owner()

    def advance(self, seconds):
        self.value = replace(self.value, wall=self.value.wall + seconds,
                             mono=self.value.mono + seconds, boot=self.value.boot + seconds)


class LegacyJournalTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="daylog-legacy-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.clock = LegacyClock()
        self.store = self.open_store("journal")
        self.sequence = 0

    def open_store(self, name, read_only=False):
        store = Store(self.root / name, read_only=read_only, clock=self.clock)
        self.addCleanup(store.close)
        return store

    def request(self, op, args=None, *, owner=False, request_id=None):
        self.sequence += 1
        request = {"protocol": 1, "requestId": request_id or f"legacy-{self.sequence}",
                   "op": op, "args": args or {}}
        if owner:
            request["clientId"] = "historical-owner"
        return request

    def call(self, op, args=None, *, store=None, **options):
        return (store or self.store).handle(self.request(op, args, **options))

    def rows(self, store=None, *, internal=False):
        store = store or self.store
        tables = list(COLUMNS)
        if internal:
            tables += ["metadata", "request_receipts", "schema_migrations"]
        return {table: [dict(row) for row in store.connection.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                for table in tables}

    def legacy_timer(self, status="running", *, seconds=7):
        activity = self.call("create_activity", {"title": "SYNTHETIC old timed work", "note": "Activity note",
                                                "plannedFor": "2025-01-01"})["result"]["activityId"]
        timer = self.call("timer_start", {"activityId": activity}, owner=True)["result"]
        self.clock.advance(seconds)
        self.call("timer_checkpoint", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]}, owner=True)
        self.call("update_session", {"sessionId": timer["sessionId"], "expectedRevision": 1,
                                     "note": "Preserved old note 日本語"})
        if status == "paused":
            self.call("timer_pause", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]}, owner=True)
        elif status == "interrupted":
            self.clock.advance(100)
            self.call("snapshot", owner=True)
        return timer

    def export(self, name, *, store=None):
        path = self.root / name
        self.call("export_records", {"format": "json", "path": str(path)}, store=store)
        return path

    def test_ownerless_reads_never_sample_advance_or_latch_legacy_clocks(self):
        self.legacy_timer()
        before = self.rows(internal=True)
        for seconds in (3, 86400):
            self.clock.advance(seconds)
            with patch.object(self.clock, "sample", side_effect=AssertionError("Journal sampled a live clock")):
                snapshot = self.call("snapshot")["snapshot"]
                self.call("history", {"query": "Preserved"})
                self.export(f"unchanged-{seconds}.json")
            session = snapshot["sessions"][0]
            self.assertEqual((session["status"], session["confirmedSeconds"], session["elapsedSeconds"]),
                             ("running", 7, 7))
            self.assertFalse(session["ownedByCaller"])
            self.assertEqual(self.rows(internal=True), before)

    def test_retirement_closes_all_unfinished_states_at_confirmed_checkpoints(self):
        paused = self.legacy_timer("paused")
        running = self.legacy_timer()
        self.clock.advance(86400)
        before = self.rows()
        with patch.object(self.clock, "sample", side_effect=AssertionError("Retirement sampled elapsed time")):
            response = self.call("settle_legacy_timers")
        self.assertEqual(response["result"], {"retiredSessions": 2})
        after = self.rows()
        self.assertEqual(after["sessions"], before["sessions"])
        self.assertEqual(after["activities"], before["activities"])
        self.assertEqual({row["status"] for row in after["timer_sessions"]}, {"stopped"})
        for old, new in zip(before["session_intervals"], after["session_intervals"]):
            self.assertEqual(new, dict(old, end_utc=old["end_utc"] or old["checkpoint_utc"]))
        for session in response["snapshot"]["sessions"]:
            self.assertEqual((session["confirmedSeconds"], session["elapsedSeconds"], session["date"]),
                             (7, 7, next(row["local_date"] for row in before["sessions"] if row["id"] == session["id"])))
            self.assertEqual(sum(day["seconds"] for day in session["days"]), 7)
        self.assertEqual([e["action"] for e in after["activity_events"] if e["action"] == "timer_retired"],
                         ["timer_retired", "timer_retired"])
        self.assertIsNone(response["snapshot"]["timer"]["active"])
        self.assertEqual(response["snapshot"]["timer"]["paused"], [])
        # Ordinary explicit completion and deletion are available after cutover.
        self.call("set_done", {"activityId": running["activityId"], "done": True})
        self.call("delete_record", {"kind": "session", "id": paused["sessionId"], "expectedRevision": 2})
        self.assertEqual(next(a for a in self.call("snapshot")["snapshot"]["activities"]
                              if a["id"] == paused["activityId"])["status"], "open")

    def test_interrupted_and_zero_length_sessions_preserve_measured_semantics(self):
        timer = self.legacy_timer("interrupted", seconds=0)
        before = self.rows()
        response = self.call("settle_legacy_timers")
        session = response["snapshot"]["sessions"][0]
        self.assertEqual((session["source"], session["minutes"], session["status"]), ("timer", 0, "stopped"))
        self.assertEqual(session["intervals"][0]["endUtc"], session["intervals"][0]["startUtc"])
        self.assertEqual(self.rows()["sessions"], before["sessions"])
        self.assertEqual(self.rows()["timer_sessions"][0]["recovery_reason"], "")
        self.assertEqual(response["snapshot"]["activities"][0]["status"], "open")
        self.call("add_session", {"activityId": timer["activityId"], "date": "2025-01-03", "note": "New untimed work", "done": True})
        sessions = self.call("snapshot")["snapshot"]["sessions"]
        self.assertIsNone(next(s for s in sessions if s["source"] == "untimed")["minutes"])

    def test_retry_after_lost_ack_is_idempotent_and_empty_retirement_stays_restoreable(self):
        self.legacy_timer()
        request = self.request("settle_legacy_timers")
        first = self.store.handle(request)
        before = self.rows(internal=True)
        self.clock.advance(86400)
        self.assertEqual(self.store.handle(request), first)
        self.assertEqual(self.rows(internal=True), before)
        self.assertEqual(self.call("settle_legacy_timers")["result"], {"retiredSessions": 0})
        self.assertEqual(self.rows(internal=True), before)
        archive = self.export("settled.json")
        empty = self.open_store("empty")
        empty_before = self.rows(empty, internal=True)
        self.assertEqual(self.call("settle_legacy_timers", store=empty)["result"], {"retiredSessions": 0})
        self.assertEqual(self.rows(empty, internal=True), empty_before)
        self.call("restore_records", {"path": str(archive), "expectedRevision": 0}, store=empty)
        self.assertEqual(self.rows(empty), self.rows())

    def test_failure_rolls_back_every_timer_event_and_receipt_then_same_request_retries(self):
        self.legacy_timer("paused")
        self.legacy_timer()
        self.clock.advance(86400)
        before = self.rows(internal=True)
        request = self.request("settle_legacy_timers")
        event = self.store._event
        calls = 0

        def fail_after_write(*args, **kwargs):
            nonlocal calls
            event(*args, **kwargs)
            calls += 1
            if calls == 2:
                raise sqlite3.OperationalError("simulated write failure")

        with patch.object(self.store, "_event", side_effect=fail_after_write):
            with self.assertRaises(StoreError) as failure:
                self.store.handle(request)
        self.assertEqual(failure.exception.code, "storage")
        self.assertEqual(self.rows(internal=True), before)
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(len(snapshot["sessions"]), 2)
        self.assertEqual(self.rows(internal=True), before, "Failure reads must not latch a timer")
        # Unrelated basic record use remains available while retirement is retried.
        self.call("create_activity", {"title": "SYNTHETIC new plan after failed cutover"})
        self.assertEqual(self.store.handle(request)["result"], {"retiredSessions": 2})

    def test_read_only_profiles_remain_browsable_and_exportable_with_visible_write_failure(self):
        self.legacy_timer()
        self.clock.advance(86400)
        before = self.rows(internal=True)
        read_only = self.open_store("journal", read_only=True)
        request = self.request("settle_legacy_timers")
        with self.assertRaises(StoreError) as failure:
            read_only.handle(request)
        self.assertEqual(failure.exception.code, "read_only")
        self.assertEqual(self.call("snapshot", store=read_only)["snapshot"]["sessions"][0]["elapsedSeconds"], 7)
        self.assertEqual(self.call("history", store=read_only)["result"]["total"], 2)
        path = self.export("read-only.json", store=read_only)
        self.assertEqual(json.loads(path.read_text())["tables"], self.rows())
        self.assertEqual(self.rows(internal=True), before)
        self.assertEqual(self.store.handle(request)["result"], {"retiredSessions": 1})

    def test_imported_running_paused_and_interrupted_timers_retire_and_round_trip(self):
        for status in ("running", "paused", "interrupted"):
            with self.subTest(status=status):
                source = self.open_store(f"source-{status}")
                original_store = self.store
                self.store = source
                try:
                    self.legacy_timer(status)
                    original = self.rows()
                    archive = self.export(f"old-{status}.json")
                finally:
                    self.store = original_store
                target = self.open_store(f"restored-{status}")
                self.clock.advance(86400)
                request = self.request("restore_records", {"path": str(archive), "expectedRevision": 0})
                target.handle(request)
                self.assertEqual(self.rows(target)["session_intervals"], original["session_intervals"])
                settled = self.call("settle_legacy_timers", store=target)
                self.assertEqual(settled["result"], {"retiredSessions": 1})
                after = self.rows(target, internal=True)
                # Retrying an import whose acknowledgement was lost must not
                # reopen timers that the following retirement already closed.
                target.handle(request)
                self.assertEqual(self.rows(target, internal=True), after)
                new_archive = self.export(f"new-{status}.json", store=target)
                round_trip = self.open_store(f"round-trip-{status}")
                self.call("restore_records", {"path": str(new_archive), "expectedRevision": 0}, store=round_trip)
                self.assertEqual(self.rows(round_trip), self.rows(target))
                self.assertEqual(self.rows(target)["activities"], original["activities"])
                self.assertEqual(self.rows(target)["sessions"], original["sessions"])

    def test_partial_session_edits_preserve_duration_clock_context_and_source(self):
        activity = self.call("create_activity", {"title": "SYNTHETIC historical metadata"})["result"]["activityId"]
        for fields in ({"minutes": None}, {"minutes": 12.5},
                       {"startUtc": "2025-01-02T23:00:00.000000Z", "endUtc": "2025-01-03T01:00:00.000000Z", "timeZone": "UTC"}):
            created = self.call("add_session", dict(activityId=activity, date="2025-01-02", note="Old", **fields))
            session_id = created["result"]["sessionId"]
            old = dict(self.store.connection.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone())
            self.call("update_session", {"sessionId": session_id, "expectedRevision": 1, "note": "New"})
            new = dict(self.store.connection.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone())
            self.assertEqual(new, dict(old, note="New", revision=2))
            if not old["start_utc"]:
                self.call("update_session", {"sessionId": session_id, "expectedRevision": 2,
                                             "note": "Moved", "date": "2025-01-04"})
                moved = dict(self.store.connection.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone())
                self.assertEqual(moved, dict(old, note="Moved", local_date="2025-01-04", revision=3))
            else:
                with self.assertRaises(StoreError) as failure:
                    self.call("update_session", {"sessionId": session_id, "expectedRevision": 2,
                                                 "note": "Do not move clocks", "date": "2025-01-04"})
                self.assertEqual(failure.exception.code, "validation")
                self.assertEqual(dict(self.store.connection.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()), new)

    def test_partial_activity_edits_preserve_archived_ids_and_detect_concurrent_label_rename(self):
        response = self.call("create_activity", {"title": "SYNTHETIC labelled activity", "category": "Old category", "project": "Old project"})
        activity = response["snapshot"]["activities"][0]
        old_ids = tuple(self.store.connection.execute("SELECT category_id,project_id FROM activities").fetchone())
        for kind, table in (("category", "categories"), ("project", "projects")):
            label = self.call("snapshot")["snapshot"][table][0]
            self.call("update_label", {"kind": kind, "id": label["id"], "name": "Archived " + kind,
                                       "archived": True, "expectedRevision": label["revision"]})
        fields = {"activityId": activity["id"], "title": "Edited", "plannedFor": "2025-02-01", "note": "Edited note",
                  "expectedRevision": activity["revision"]}
        with self.assertRaises(StoreError) as conflict:
            self.call("update_activity", fields)
        self.assertEqual(conflict.exception.code, "conflict")
        fields["expectedRevision"] = self.call("snapshot")["snapshot"]["activities"][0]["revision"]
        response = self.call("update_activity", fields)
        edited = response["snapshot"]["activities"][0]
        self.assertEqual((edited["category"], edited["project"]), ("Archived category", "Archived project"))
        self.assertEqual(tuple(self.store.connection.execute("SELECT category_id,project_id FROM activities").fetchone()), old_ids)
        self.call("update_activity", dict(fields, expectedRevision=edited["revision"], category="", project=None))
        self.assertEqual(tuple(self.store.connection.execute("SELECT category_id,project_id FROM activities").fetchone()), (None, None))


if __name__ == "__main__":
    unittest.main()
