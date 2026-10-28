"""Temporary-profile portability tests: actual exports, restores, and failures."""

from contextlib import closing
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile
import unittest
from unittest.mock import patch

from backend.portability import COLUMNS, export_records, restore_records
from backend.storage import SCHEMA_VERSION, SOURCE_ROOT, Store, StoreError
from backend.timer import ClockSample


class PortableClock:
    def __init__(self):
        self.wall = datetime(2025, 1, 2, 23, 59, 30, tzinfo=timezone.utc).timestamp()
        self.mono = 100.0

    def sample(self):
        return ClockSample(self.wall, self.mono, self.mono + 1000, "test-boot", "UTC", 0)

    def owner(self):
        return 1234, "synthetic-owner"

    def alive(self, pid, start):
        return (pid, start) == self.owner()

    def advance(self, seconds):
        self.wall += seconds
        self.mono += seconds


class PortabilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daylog-portability-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.clock = PortableClock()
        self.source = Store(self.root / "source-profile", clock=self.clock)
        self.addCleanup(self.source.close)
        self.sequence = 0

    def call(self, store, op, args=None, request_id=None):
        self.sequence += 1
        return store.handle({"protocol": 1, "requestId": request_id or f"portable-{self.sequence}",
                             "clientId": "portable-test-client", "op": op, "args": args or {}})

    def target(self, name="target-profile"):
        store = Store(self.root / name, clock=PortableClock())
        self.addCleanup(store.close)
        return store

    def records(self, store):
        return {table: [dict(row) for row in store.connection.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                for table in COLUMNS}

    def all_rows(self, store):
        result = self.records(store)
        for table in ("metadata", "request_receipts", "schema_migrations"):
            result[table] = [tuple(row) for row in store.connection.execute(f"SELECT * FROM {table} ORDER BY rowid")]
        return result

    def export(self, filename="journal.json", kind="json", store=None, scope="activities"):
        path = self.root / filename
        response = self.call(store or self.source, "export_records",
                             {"format": kind, "path": str(path), "scope": scope})
        self.assertEqual(response["result"]["path"], str(path))
        return path

    def legacy_archive(self, filename="legacy-journal.json", store=None):
        """Reconstruct a pre-split archive to retain all combined-import cases.

        The shipping exporter cannot produce this combined document. Both halves
        come from real scoped exports, preserving the original full-record tests.
        """
        store = store or self.source
        prefix = f"legacy-halves-{self.sequence}-"
        activities = json.loads(self.export(prefix + "activities.json", store=store).read_text())
        diary = json.loads(self.export(prefix + "diary.json", store=store, scope="diary").read_text())
        del activities["scope"]
        activities["tables"]["day_notes"] = diary["tables"]["day_notes"]
        trash = {row["id"]: row for row in activities["tables"]["trash"] + diary["tables"]["trash"]}
        activities["tables"]["trash"] = [trash[row["id"]] for row in self.records(store)["trash"]]
        path = self.root / filename
        with path.open("x", encoding="utf-8") as stream:
            json.dump(activities, stream, ensure_ascii=False)
        return path

    def populate(self, *, running=False):
        created = self.call(self.source, "create_activity", {
            "title": "Synthetic reading 日本語", "mode": "plan", "category": "Learning", "project": "Portable",
            "plannedFor": "2025-01-02", "note": "Activity note\nSecond line"})
        activity_id = created["result"]["activityId"]
        for args in ({"date": "2025-01-02", "minutes": 12.5, "note": "Reported session"},
                     {"date": "2025-01-03", "minutes": None, "note": "Untimed session"},
                     {"date": "2025-01-02", "minutes": None, "note": "Actual interval",
                      "startUtc": "2025-01-02T23:50:00Z", "endUtc": "2025-01-03T00:10:00Z", "timeZone": "UTC"}):
            self.call(self.source, "add_session", dict(args, activityId=activity_id))
        self.call(self.source, "save_note", {"date": "2025-01-02", "body": "Daily reflection café\nMore", "expectedRevision": 0})
        removed = self.call(self.source, "create_activity", {"title": "Deleted synthetic activity", "mode": "log",
                                                                    "date": "2025-01-01", "sessionNote": "Hidden child"})
        self.call(self.source, "delete_record", {"kind": "activity", "id": removed["result"]["activityId"], "expectedRevision": 1})
        removed_session = self.call(self.source, "add_session", {"activityId": activity_id, "date": "2025-01-04", "note": "Deleted session"})
        self.call(self.source, "delete_record", {"kind": "session", "id": removed_session["result"]["sessionId"], "expectedRevision": 1})
        self.call(self.source, "save_note", {"date": "2025-01-04", "body": "Deleted reflection", "expectedRevision": 0})
        self.call(self.source, "delete_record", {"kind": "note", "id": "2025-01-04", "expectedRevision": 1})
        category = self.source.connection.execute("SELECT * FROM categories").fetchone()
        self.call(self.source, "update_label", {"kind": "category", "id": category["id"], "name": "Learning",
                                                   "archived": True, "expectedRevision": category["revision"]})
        timer = self.call(self.source, "timer_start", {"activityId": activity_id})["result"]
        self.clock.advance(10)
        self.call(self.source, "timer_pause", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]})
        timer = self.call(self.source, "timer_resume", {"sessionId": timer["sessionId"]})["result"]
        self.clock.advance(8)
        self.call(self.source, "timer_checkpoint", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]})
        if not running:
            self.call(self.source, "timer_stop", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]})
        return activity_id, timer

    def restore(self, target, path, request_id=None, expected_revision=None):
        if expected_revision is None:
            expected_revision = target.connection.execute("SELECT revision FROM metadata").fetchone()[0]
        if request_id is not None:
            if not hasattr(self, "restore_revisions"):
                self.restore_revisions = {}
            expected_revision = self.restore_revisions.setdefault((target.path, request_id), expected_revision)
        return self.call(target, "restore_records", {"path": str(path), "expectedRevision": expected_revision}, request_id)

    def assert_preserved(self, target, before):
        after = self.records(target)
        for table, rows in before.items():
            key = "local_date" if table == "day_notes" else "session_id" if table == "timer_sessions" else "id"
            indexed = {row[key]: row for row in after[table]}
            for row in rows:
                self.assertEqual(indexed[row[key]], row, (table, row[key]))

    def assert_conflict(self, result, table, key):
        self.assertIn((table, key), [(row["table"], row["key"]) for row in result["conflicts"]])
        return [row for row in result["conflicts"] if row["table"] == table and row["key"] == key]

    def assert_round_trip(self, target, name):
        restored = self.target(name)
        for scope in ("activities", "diary"):
            path = self.export(name + "-" + scope + ".json", store=target, scope=scope)
            self.restore(restored, path)
        actual, expected = self.records(restored), self.records(target)
        # Independent imports can interleave recovery markers differently.
        for records in (actual, expected):
            records["trash"].sort(key=lambda row: row["id"])
        self.assertEqual(actual, expected)

    def test_activity_exports_exclude_live_deleted_diary_and_all_diary_trash_metadata(self):
        self.populate()
        before = self.all_rows(self.source)
        notes = before["day_notes"]
        diary_trash = [row for row in before["trash"] if row["kind"] == "note"]
        for kind in ("json", "markdown"):
            for explicit in (False, True):
                with self.subTest(kind=kind, explicit_scope=explicit):
                    path = self.root / f"activity-{kind}-{explicit}.txt"
                    args = {"format": kind, "path": str(path)}
                    if explicit:
                        args["scope"] = "activities"
                    result = self.call(self.source, "export_records", args)["result"]
                    content = path.read_text()
                    self.assertEqual(result["scope"], "activities")
                    self.assertEqual(result["counts"]["day_notes"], 0)
                    for note in notes:
                        self.assertNotIn(note["body"], content)
                    for marker in diary_trash:
                        self.assertNotIn(marker["id"], content)
                    if kind == "json":
                        tables = json.loads(content)["tables"]
                        self.assertEqual(tables["day_notes"], [])
                        self.assertEqual(tables["trash"], [row for row in before["trash"] if row["kind"] != "note"])
                        for table in COLUMNS:
                            if table not in ("day_notes", "trash"):
                                self.assertEqual(tables[table], before[table])
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(self.all_rows(self.source), before)

    def test_diary_only_round_trip_preserves_empty_live_deleted_pages_and_recovery(self):
        self.populate()
        self.call(self.source, "save_note", {"date": "2025-01-05", "body": "", "expectedRevision": 0})
        source = self.records(self.source)
        path = self.export("diary-only.json", scope="diary")
        content = path.read_text()
        document = json.loads(content)
        self.assertEqual(document["scope"], "diary")
        expected = {table: [] for table in COLUMNS}
        expected["day_notes"] = source["day_notes"]
        expected["trash"] = [row for row in source["trash"] if row["kind"] == "note"]
        self.assertEqual(document["tables"], expected)
        for activity in source["activities"]:
            self.assertNotIn(activity["title"], content)
            self.assertNotIn(activity["id"], content)
        target = self.target()
        first = self.restore(target, path, "diary-import")
        self.assertEqual(self.records(target), expected)
        self.assertNotIn("2025-01-04", first["snapshot"]["dayNotes"])
        self.assertEqual(first["snapshot"]["dayNotes"]["2025-01-05"]["body"], "")
        before = self.all_rows(target)
        path.unlink()
        replay = self.restore(target, path, "diary-import")
        self.assertEqual(replay["result"], first["result"])
        self.assertEqual(self.all_rows(target), before)
        reexported = self.export("diary-reexport.json", store=target, scope="diary")
        self.assertEqual(json.loads(reexported.read_text())["tables"], expected)
        repeated = self.restore(target, reexported)["result"]
        self.assertEqual(repeated["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(repeated["duplicates"], {table: len(rows) for table, rows in expected.items()})
        restored = self.call(target, "undo_delete", {"trashId": expected["trash"][0]["id"]})["snapshot"]
        self.assertEqual(restored["dayNotes"]["2025-01-04"]["body"], "Deleted reflection")
        self.assertEqual(restored["activities"], [])
        self.assert_round_trip(target, "recovered-diary")

    def test_export_scope_validation_rejects_unknown_values_without_publishing(self):
        before = self.all_rows(self.source)
        for index, scope in enumerate((None, "", "all", "combined", "notes", True, 1, [], {})):
            with self.subTest(scope=scope):
                path = self.root / f"bad-scope-{index}.json"
                with self.assertRaises(StoreError) as failure:
                    self.call(self.source, "export_records", {"format": "json", "scope": scope, "path": str(path)})
                self.assertEqual(failure.exception.code, "validation")
                self.assertFalse(path.exists())
        with self.assertRaises(StoreError) as failure:
            self.export("diary.md", "markdown", scope="diary")
        self.assertEqual(failure.exception.code, "validation")
        self.assertFalse((self.root / "diary.md").exists())
        self.assertEqual(self.all_rows(self.source), before)

    def test_scoped_archives_reject_mislabeled_or_unknown_scope_without_importing(self):
        self.populate()
        combined = json.loads(self.legacy_archive().read_text())
        target = self.target()
        before = self.all_rows(target)
        for index, scope in enumerate(("activities", "diary", "all", None, [], {})):
            with self.subTest(scope=scope):
                document = copy.deepcopy(combined)
                document["scope"] = scope
                path = self.root / f"mislabeled-{index}.json"
                path.write_text(json.dumps(document))
                with self.assertRaises(StoreError) as failure:
                    self.restore(target, path)
                self.assertEqual(failure.exception.code, "validation")
                self.assertEqual(self.all_rows(target), before)

    def test_scoped_exports_repeat_without_overwrite_and_retry_failed_publication(self):
        self.populate()
        for scope in ("activities", "diary"):
            with self.subTest(scope=scope):
                path = self.root / (scope + "-retry.json")
                args = {"format": "json", "scope": scope, "path": str(path)}
                request_id = scope + "-same-request"
                with patch("backend.portability.os.link", side_effect=OSError("synthetic publication failure")):
                    with self.assertRaises(StoreError):
                        self.call(self.source, "export_records", args, request_id)
                self.assertFalse(path.exists())
                self.call(self.source, "export_records", args, request_id)
                content = path.read_bytes()
                before = self.all_rows(self.source)
                for retry_id in (request_id, scope + "-new-request"):
                    with self.assertRaises(StoreError) as failure:
                        self.call(self.source, "export_records", args, retry_id)
                    self.assertEqual(failure.exception.code, "conflict")
                    self.assertEqual(path.read_bytes(), content)
                other = dict(args, scope="diary" if scope == "activities" else "activities")
                with self.assertRaises(StoreError):
                    self.call(self.source, "export_records", other, request_id)
                self.assertEqual(path.read_bytes(), content)
                self.assertEqual(self.all_rows(self.source), before)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(list(self.root.glob(".daylog-export-*")), [])

    def test_complete_round_trip_preserves_ids_deleted_records_labels_events_and_context(self):
        self.populate()
        before = self.records(self.source)
        path = self.legacy_archive()
        document = json.loads(path.read_text())
        self.assertEqual((document["format"], document["formatVersion"], document["schemaVersion"]), ("daylog", 1, SCHEMA_VERSION))
        self.assertEqual(set(document["tables"]), set(COLUMNS))
        self.assertNotIn("request_receipts", document["tables"])
        target = self.target()
        response = self.restore(target, path, "one-restore")
        self.assertEqual(self.records(target), before)
        self.assertGreater(response["snapshot"]["revision"], document["revision"])
        self.assertEqual(target.connection.execute("SELECT COUNT(*) FROM request_receipts").fetchone()[0], 1)
        self.assertEqual(len(list(target.path.glob("daylog.before-restore-*.sqlite3"))), 1)
        retried = self.restore(target, path, "one-restore")
        self.assertEqual(response["result"], retried["result"])
        second_export = self.legacy_archive("second.json", store=target)
        self.assertEqual(json.loads(second_export.read_text())["tables"], document["tables"])

    def test_pin_round_trip_preserves_done_deleted_and_unpinned_activities(self):
        done = self.call(self.source, "create_activity", {
            "title": "SYNTHETIC pinned done", "mode": "log", "date": "2025-01-01",
            "plannedFor": "2028-02-03", "pinned": True, "done": True})["result"]["activityId"]
        hidden = self.call(self.source, "create_activity", {
            "title": "SYNTHETIC pinned deleted", "mode": "log", "date": "2025-01-02",
            "pinned": True})["result"]["activityId"]
        trash_id = self.call(self.source, "delete_record", {
            "kind": "activity", "id": hidden, "expectedRevision": 1})["result"]["trashId"]
        unpinned = self.call(self.source, "create_activity", {
            "title": "SYNTHETIC unpinned", "pinned": False})["result"]["activityId"]
        before = self.records(self.source)
        path = self.legacy_archive()
        document = json.loads(path.read_text())
        pins = {row["id"]: row["pinned"] for row in document["tables"]["activities"]}
        self.assertEqual(pins, {done: True, hidden: True, unpinned: False})
        self.assertTrue(all(type(value) is bool for value in pins.values()))
        target = self.target()
        restored = self.restore(target, path)["snapshot"]
        self.assertEqual(self.records(target), before)
        self.assertEqual({row["id"]: row["pinned"] for row in restored["activities"]},
                         {done: True, unpinned: False})
        self.assertTrue(all(type(row["pinned"]) is bool for row in restored["activities"]))
        self.assertEqual(json.loads(self.legacy_archive("round-trip-pins.json", store=target).read_text())["tables"],
                         document["tables"])
        recovered = self.call(target, "undo_delete", {"trashId": trash_id})["snapshot"]
        self.assertIs(next(row for row in recovered["activities"] if row["id"] == hidden)["pinned"], True)
        self.assertEqual(next(row for row in recovered["activities"] if row["id"] == done)["status"], "done")
        self.assertEqual({row["activityId"] for row in recovered["sessions"]}, {done, hidden})

    def test_schema_v4_format_one_archives_import_without_pins_and_reexport_current(self):
        self.populate()
        before = self.records(self.source)
        legacy = json.loads(self.legacy_archive().read_text())
        legacy["schemaVersion"] = 4
        for table in ("activity_tasks", "session_tasks"):
            del legacy["tables"][table]
        for row in legacy["tables"]["activities"]:
            del row["pinned"]
        path = self.root / "legacy-schema-v4.json"
        content = json.dumps(legacy, ensure_ascii=False)
        path.write_text(content)
        target = self.target()
        restored = self.restore(target, path)["snapshot"]
        self.assertEqual(self.records(target), before)
        self.assertTrue(all(row["pinned"] is False for row in restored["activities"]))
        self.assertEqual(path.read_text(), content)
        modern = json.loads(self.legacy_archive("upgraded-archive.json", store=target).read_text())
        self.assertEqual((modern["formatVersion"], modern["schemaVersion"]), (1, SCHEMA_VERSION))
        self.assertTrue(all(row["pinned"] is False for row in modern["tables"]["activities"]))
        for row in modern["tables"]["activities"]:
            del row["pinned"]
        for table in ("activity_tasks", "session_tasks"):
            self.assertEqual(modern["tables"].pop(table), [])
        self.assertEqual(modern["tables"], legacy["tables"])
        trash_id = next(row["id"] for row in before["trash"] if row["kind"] == "activity")
        recovered = self.call(target, "undo_delete", {"trashId": trash_id})["snapshot"]
        self.assertTrue(all(row["pinned"] is False for row in recovered["activities"]))

    def test_running_timer_restores_interrupted_without_unknown_elapsed_and_recovers(self):
        _, timer = self.populate(running=True)
        before = self.records(self.source)
        self.clock.advance(7200)
        path = self.legacy_archive()
        self.assertEqual(self.records(self.source), before, "Export must not latch or advance the source timer")
        target = self.target()
        result = self.restore(target, path)
        self.assertEqual(result["result"]["interruptedTimers"], 1)
        state = dict(target.connection.execute("SELECT * FROM timer_sessions").fetchone())
        self.assertEqual((state["status"], state["recovery_reason"]), ("interrupted", "restored"))
        self.assertEqual(self.records(target)["session_intervals"], before["session_intervals"])
        self.assertEqual(target.connection.execute("SELECT minutes FROM sessions WHERE id=?", (timer["sessionId"],)).fetchone()[0], 18 / 60)
        self.call(target, "timer_recover", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"], "action": "stop"})
        self.assertEqual(target.connection.execute("SELECT minutes FROM sessions WHERE id=?", (timer["sessionId"],)).fetchone()[0], 18 / 60)
        self.assertEqual(target.connection.execute("SELECT status FROM timer_sessions").fetchone()[0], "stopped")

    def test_running_timer_appends_to_populated_profile_and_repeat_does_not_recover_it_again(self):
        _, timer = self.populate(running=True)
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Unrelated local plan"})
        before = self.records(target)
        self.clock.advance(7200)
        first = self.restore(target, path)["result"]
        self.assert_preserved(target, before)
        self.assertEqual(first["interruptedTimers"], 1)
        self.assertEqual(first["conflicts"], [])
        merged = self.records(target)
        repeated = self.restore(target, path)["result"]
        self.assertEqual(self.records(target), merged)
        self.assertEqual(repeated["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(repeated["duplicates"], {table: len(rows) for table, rows in self.records(self.source).items()})
        self.assertEqual(repeated["conflicts"], [])
        self.assertEqual(repeated["interruptedTimers"], 0)
        self.assertEqual(target.connection.execute("SELECT minutes FROM sessions WHERE id=?", (timer["sessionId"],)).fetchone()[0], 18 / 60)
        self.call(target, "settle_legacy_timers")
        self.assert_round_trip(target, "running-append-merged")

    def test_paused_timer_round_trip_stays_paused_with_all_intervals(self):
        _, timer = self.populate(running=True)
        self.call(self.source, "timer_pause", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]})
        before = self.records(self.source)
        target = self.target()
        response = self.restore(target, self.legacy_archive())
        self.assertEqual(response["result"]["interruptedTimers"], 0)
        self.assertEqual(self.records(target), before)
        self.assertEqual(target.connection.execute("SELECT status FROM timer_sessions").fetchone()[0], "paused")

    def test_already_interrupted_export_has_explicit_restored_recovery_reason(self):
        _, timer = self.populate(running=True)
        self.clock.advance(100)
        self.call(self.source, "snapshot")
        self.assertEqual(self.source.connection.execute("SELECT status FROM timer_sessions").fetchone()[0], "interrupted")
        target = self.target()
        self.restore(target, self.legacy_archive())
        self.assertEqual(target.connection.execute("SELECT recovery_reason FROM timer_sessions").fetchone()[0], "restored")
        self.call(target, "timer_recover", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"], "action": "resume"})
        spans = self.records(target)["session_intervals"]
        self.assertEqual(len(spans), 3)
        self.assertIsNotNone(spans[-2]["end_utc"])
        self.assertIsNone(spans[-1]["end_utc"])
        self.assertEqual(spans[-1]["duration_seconds"], 0)

    def test_corruption_and_invalid_semantics_leave_every_target_record_unchanged(self):
        self.populate(running=True)
        original = json.loads(self.legacy_archive().read_text())
        variants = []

        def mutate(name, fn):
            document = copy.deepcopy(original)
            fn(document)
            variants.append((name, json.dumps(document)))

        mutate("future format", lambda d: d.update(formatVersion=2))
        mutate("future schema", lambda d: d.update(schemaVersion=999))
        mutate("unsupported older schema", lambda d: d.update(schemaVersion=3))
        mutate("legacy schema with new pin fields", lambda d: d.update(schemaVersion=4))
        mutate("boolean schema", lambda d: d.update(schemaVersion=True))
        mutate("boolean version", lambda d: d.update(formatVersion=True))
        mutate("negative revision", lambda d: d.update(revision=-1))
        mutate("unknown table", lambda d: d["tables"].update(sql=["DROP TABLE activities"]))
        mutate("missing table", lambda d: d["tables"].pop("activity_events"))
        mutate("missing field", lambda d: d["tables"]["activities"][0].pop("note"))
        mutate("missing current-schema pin", lambda d: d["tables"]["activities"][0].pop("pinned"))
        for value in (None, 0, 1, 2, -1, 1.0, "true", "false", [], {}):
            mutate(f"invalid pin {value!r}", lambda d, value=value: d["tables"]["activities"][0].update(pinned=value))
        mutate("broken activity reference", lambda d: d["tables"]["sessions"][0].update(activity_id="absent"))
        mutate("duplicate id", lambda d: d["tables"]["activities"].append(d["tables"]["activities"][0].copy()))
        mutate("invalid label key", lambda d: d["tables"]["categories"][0].update(name_key="wrong"))
        mutate("invalid calendar date", lambda d: d["tables"]["sessions"][0].update(local_date="2025-02-30"))
        mutate("nonfinite", lambda d: d["tables"]["sessions"][0].update(minutes=float("inf")))
        mutate("boolean duration", lambda d: d["tables"]["sessions"][0].update(minutes=True))
        mutate("negative duration", lambda d: d["tables"]["sessions"][0].update(minutes=-1))
        mutate("untimed duration", lambda d: d["tables"]["sessions"][1].update(minutes=5))
        mutate("missing completion date", lambda d: d["tables"]["activities"][0].update(status="done"))
        mutate("missing trash", lambda d: d["tables"]["trash"].clear())
        mutate("mismatched clock duration", lambda d: d["tables"]["sessions"][2].update(minutes=999))
        mutate("unknown clock zone", lambda d: d["tables"]["sessions"][2].update(time_zone="Missing/Zone"))
        mutate("timer without state", lambda d: d["tables"]["timer_sessions"].clear())
        mutate("wrong timer total", lambda d: d["tables"]["session_intervals"][0].update(duration_seconds=500))
        mutate("invalid checkpoint", lambda d: d["tables"]["session_intervals"][0].update(checkpoint_wall=1))
        mutate("naive timestamp", lambda d: d["tables"]["session_intervals"][0].update(start_utc="2025-01-02T23:59:30"))
        mutate("negative monotonic", lambda d: d["tables"]["session_intervals"][0].update(checkpoint_mono=-1))
        mutate("boot before monotonic", lambda d: d["tables"]["session_intervals"][0].update(checkpoint_boot=1))
        mutate("finite minutes overflow seconds", lambda d: d["tables"]["sessions"][0].update(minutes=1e308))
        mutate("invalid owner", lambda d: d["tables"]["session_intervals"][0].update(owner_pid=0))
        mutate("bad offset", lambda d: d["tables"]["session_intervals"][0].update(offset_seconds=86400))
        mutate("missing open interval", lambda d: d["tables"]["session_intervals"][-1].update(end_utc=d["tables"]["session_intervals"][-1]["checkpoint_utc"]))
        mutate("invalid recovery state", lambda d: d["tables"]["timer_sessions"][0].update(recovery_reason="unknown"))
        mutate("unknown recovery reason", lambda d: d["tables"]["timer_sessions"][0].update(status="interrupted", recovery_reason="invented"))
        mutate("deleted live timer", lambda d: d["tables"]["activities"][0].update(deleted_at="2025-01-03T00:00:00Z"))
        variants.extend([("truncated", '{"format":'), ("duplicate key", '{"format":"daylog","format":"daylog"}'),
                         ("overflow number", json.dumps(original).replace('"minutes": 12.5', '"minutes": 1e999'))])
        target = self.target()
        before = self.all_rows(target)
        for name, content in variants:
            with self.subTest(name=name):
                path = self.root / "corrupt.json"
                path.write_text(content)
                with self.assertRaises(StoreError):
                    self.restore(target, path)
                self.assertEqual(self.all_rows(target), before)
                self.assertEqual(list(target.path.glob("daylog.before-restore-*.sqlite3")), [])

    def test_matching_import_does_not_latch_or_advance_a_local_running_timer(self):
        self.populate(running=True)
        path = self.legacy_archive()
        self.clock.advance(100)
        before = self.records(self.source)
        result = self.restore(self.source, path)["result"]
        self.assertEqual(self.records(self.source), before)
        self.assertEqual(result["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(result["duplicates"], {table: len(rows) for table, rows in before.items()})
        self.assertEqual(result["conflicts"], [])
        self.assertEqual(result["interruptedTimers"], 0)

    def test_populated_label_only_and_receipt_only_profiles_append_all_canonical_tables(self):
        self.populate()
        incoming = self.records(self.source)
        path = self.legacy_archive()
        for name in ("populated", "category", "project", "receipt", "note"):
            with self.subTest(profile=name):
                target = self.target(name)
                if name == "populated":
                    activity = self.call(target, "create_activity", {
                        "title": "Existing destination", "mode": "log", "date": "2024-12-30",
                        "sessionNote": "Keep existing log"})["result"]["activityId"]
                    self.call(target, "delete_record", {"kind": "activity", "id": activity, "expectedRevision": 1})
                elif name in ("category", "project"):
                    target.connection.execute(
                        f"INSERT INTO {'categories' if name == 'category' else 'projects'}(id,name,name_key) VALUES (?,?,?)",
                        ("local-label", "Local label", "local label"))
                elif name == "receipt":
                    target.connection.execute("INSERT INTO request_receipts VALUES ('prior','digest','{}')")
                else:
                    self.call(target, "save_note", {"date": "2024-12-30", "body": "Keep local page", "expectedRevision": 0})
                before = self.records(target)
                receipts = [tuple(row) for row in target.connection.execute("SELECT * FROM request_receipts")]
                result = self.restore(target, path)["result"]
                self.assertEqual(result["format"], "json")
                self.assertEqual(result["counts"], {table: len(rows) for table, rows in incoming.items()})
                self.assertEqual(result["duplicates"], dict.fromkeys(COLUMNS, 0))
                self.assertEqual(result["conflicts"], [])
                self.assert_preserved(target, before)
                self.assert_preserved(target, incoming)
                for receipt in receipts:
                    self.assertIn(receipt, [tuple(row) for row in target.connection.execute("SELECT * FROM request_receipts")])
                backups = list(target.path.glob("daylog.before-restore-*.sqlite3"))
                self.assertEqual(len(backups), 1)
                with closing(sqlite3.connect(backups[0])) as backup:
                    backup.row_factory = sqlite3.Row
                    self.assertEqual({table: [dict(row) for row in backup.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                                      for table in COLUMNS}, before)
                self.assert_round_trip(target, name + "-merged")

    def test_repeated_matching_append_and_lost_ack_replay_have_stable_results(self):
        self.populate()
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Existing unrelated record"})
        first = self.restore(target, path, "append-once")
        before = self.all_rows(target)
        path.unlink()
        replay = self.restore(target, path, "append-once")
        self.assertEqual(replay["result"], first["result"])
        self.assertEqual(self.all_rows(target), before)
        path = self.legacy_archive("matching-repeat.json")
        repeated = self.restore(target, path)["result"]
        self.assertEqual(repeated["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(repeated["duplicates"], {table: len(rows) for table, rows in self.records(self.source).items()})
        self.assertEqual(repeated["conflicts"], [])
        self.assertEqual(self.records(target), {table: before[table] for table in COLUMNS})
        self.assert_round_trip(target, "repeated-merged")

    def test_edited_ids_and_same_date_diary_keep_destination_but_accept_new_logs(self):
        activity = self.call(self.source, "create_activity", {
            "title": "Shared activity", "mode": "log", "date": "2025-01-01",
            "sessionNote": "Original session"})["result"]["activityId"]
        session = self.records(self.source)["sessions"][0]["id"]
        self.call(self.source, "save_note", {"date": "2025-01-01", "body": "PRIVATE original diary", "expectedRevision": 0})
        target = self.target()
        self.restore(target, self.legacy_archive("baseline.json"))
        self.call(target, "update_activity", {"activityId": activity, "title": "Destination edited title", "expectedRevision": 1})
        self.call(target, "update_session", {"sessionId": session, "note": "Destination edited log", "expectedRevision": 1})
        self.call(target, "save_note", {"date": "2025-01-01", "body": "PRIVATE destination diary", "expectedRevision": 1})
        new_session = self.call(self.source, "add_session", {
            "activityId": activity, "date": "2025-01-02", "note": "New log on retained parent"})["result"]["sessionId"]
        same_title = self.call(self.source, "create_activity", {"title": "Destination edited title"})["result"]["activityId"]
        self.call(self.source, "save_note", {"date": "2025-01-02", "body": "New diary date", "expectedRevision": 0})
        before = self.records(target)
        result = self.restore(target, self.legacy_archive("edited.json"), "edited-append")["result"]
        self.assert_preserved(target, before)
        self.assert_conflict(result, "activities", activity)
        self.assert_conflict(result, "sessions", session)
        diary_conflicts = self.assert_conflict(result, "day_notes", "2025-01-01")
        self.assertTrue(all(row["label"] == "2025-01-01" for row in diary_conflicts))
        self.assertNotIn("PRIVATE", json.dumps(result["conflicts"]))
        self.assertEqual(result["counts"]["activities"], 1)
        self.assertEqual(result["counts"]["sessions"], 1)
        self.assertEqual(result["counts"]["day_notes"], 1)
        self.assertEqual(target.connection.execute("SELECT activity_id,note FROM sessions WHERE id=?", (new_session,)).fetchone()[:],
                         (activity, "New log on retained parent"))
        self.assertIsNotNone(target.connection.execute("SELECT 1 FROM activities WHERE id=?", (same_title,)).fetchone())
        replay = self.restore(target, self.root / "edited.json", "edited-append")["result"]
        self.assertEqual(replay, result)
        self.assert_round_trip(target, "edited-merged")

    def test_same_name_different_id_labels_map_new_relationships_and_repeat_as_duplicates(self):
        target = self.target()
        self.call(target, "create_activity", {"title": "Same title", "category": "Learning", "project": "Portable"})
        imported = self.call(self.source, "create_activity", {
            "title": "Same title", "category": "Learning", "project": "Portable"})["result"]["activityId"]
        before = self.records(target)
        original = self.records(self.source)
        self.assertNotEqual(before["categories"][0]["id"], original["categories"][0]["id"])
        self.assertNotEqual(before["projects"][0]["id"], original["projects"][0]["id"])
        path = self.legacy_archive()
        result = self.restore(target, path)["result"]
        self.assert_preserved(target, before)
        self.assertEqual(result["counts"]["activities"], 1)
        for table in ("categories", "projects"):
            self.assertEqual(result["counts"][table], 0)
            self.assertEqual(result["duplicates"][table], 1)
            self.assertEqual(self.records(target)[table], before[table])
        row = target.connection.execute("SELECT category_id,project_id FROM activities WHERE id=?", (imported,)).fetchone()
        self.assertEqual(tuple(row), (before["categories"][0]["id"], before["projects"][0]["id"]))
        merged = self.records(target)
        repeated = self.restore(target, path)["result"]
        self.assertEqual(repeated["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(repeated["conflicts"], [])
        self.assertEqual(repeated["duplicates"], {table: len(rows) for table, rows in original.items()})
        self.assertEqual(self.records(target), merged)
        self.assert_round_trip(target, "labels-merged")

    def test_existing_label_identity_wins_over_a_reused_old_name(self):
        self.call(self.source, "create_activity", {
            "title": "Original relationship", "category": "Personal", "project": "Home"})
        original = self.records(self.source)
        target = self.target()
        self.restore(target, self.legacy_archive("before-label-rename.json"))
        for kind, table, name in (("category", "categories", "Work"), ("project", "projects", "Office")):
            label = original[table][0]
            self.call(target, "update_label", {
                "kind": kind, "id": label["id"], "name": name, "archived": False,
                "expectedRevision": label["revision"]})
        self.call(target, "create_activity", {
            "title": "Different local labels", "category": "Personal", "project": "Home"})
        imported = self.call(self.source, "create_activity", {
            "title": "New record on the original labels", "category": "Personal", "project": "Home"})["result"]["activityId"]
        before = self.records(target)
        archive = self.legacy_archive("after-label-rename.json")
        result = self.restore(target, archive)["result"]
        self.assert_preserved(target, before)
        self.assertEqual(result["counts"]["activities"], 1)
        relationship = target.connection.execute(
            "SELECT category_id,project_id FROM activities WHERE id=?", (imported,)).fetchone()
        self.assertEqual(tuple(relationship), (original["categories"][0]["id"], original["projects"][0]["id"]))
        for table in ("categories", "projects"):
            self.assertEqual(self.records(target)[table], before[table])
            self.assert_conflict(result, table, original[table][0]["id"])
        merged = self.records(target)
        self.assertEqual(self.restore(target, archive)["result"]["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(self.records(target), merged)
        self.assert_round_trip(target, "renamed-labels-merged")

    def test_casefold_label_matches_keep_destination_archival_state_and_report_differences(self):
        target = self.target()
        self.call(target, "create_activity", {"title": "Local labels", "category": "Learning", "project": "Portable"})
        for kind, table in (("category", "categories"), ("project", "projects")):
            label = self.records(target)[table][0]
            self.call(target, "update_label", {
                "kind": kind, "id": label["id"], "name": label["name"], "archived": True,
                "expectedRevision": label["revision"]})
        imported = self.call(self.source, "create_activity", {
            "title": "New imported relationship", "category": "learning", "project": "portable"})["result"]["activityId"]
        incoming = self.records(self.source)
        before = self.records(target)
        path = self.legacy_archive()
        result = self.restore(target, path)["result"]
        self.assert_preserved(target, before)
        for table in ("categories", "projects"):
            self.assertEqual(result["counts"][table], 0)
            self.assertEqual(result["duplicates"][table], 0)
            self.assert_conflict(result, table, incoming[table][0]["id"])
            self.assertEqual(self.records(target)[table], before[table])
        relationship = target.connection.execute(
            "SELECT category_id,project_id FROM activities WHERE id=?", (imported,)).fetchone()
        self.assertEqual(tuple(relationship), (before["categories"][0]["id"], before["projects"][0]["id"]))
        merged = self.records(target)
        repeated = self.restore(target, path)["result"]
        self.assertEqual(repeated["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(repeated["duplicates"]["activities"], 1)
        self.assertEqual(self.records(target), merged)
        self.assert_round_trip(target, "archived-labels-merged")

    def test_local_deleted_records_and_trash_win_and_new_children_are_skipped(self):
        activity = self.call(self.source, "create_activity", {
            "title": "Deleted locally", "mode": "log", "date": "2025-01-01"})["result"]["activityId"]
        session = self.records(self.source)["sessions"][0]["id"]
        self.call(self.source, "save_note", {"date": "2025-01-01", "body": "Private deleted diary", "expectedRevision": 0})
        target = self.target()
        self.restore(target, self.legacy_archive("live-baseline.json"))
        for kind, record_id in (("session", session), ("activity", activity), ("note", "2025-01-01")):
            self.call(target, "delete_record", {"kind": kind, "id": record_id, "expectedRevision": 1})
        child = self.call(self.source, "add_session", {
            "activityId": activity, "date": "2025-01-02", "note": "Must not revive parent"})["result"]["sessionId"]
        unrelated = self.call(self.source, "create_activity", {"title": "Still imported"})["result"]["activityId"]
        before = self.records(target)
        result = self.restore(target, self.legacy_archive("deleted-conflicts.json"))["result"]
        self.assert_preserved(target, before)
        for table, key in (("activities", activity), ("sessions", session), ("sessions", child), ("day_notes", "2025-01-01")):
            self.assert_conflict(result, table, key)
        self.assertEqual(result["counts"]["sessions"], 0)
        self.assertEqual(self.records(target)["trash"], before["trash"])
        self.assertIsNone(target.connection.execute("SELECT 1 FROM sessions WHERE id=?", (child,)).fetchone())
        self.assertIsNotNone(target.connection.execute("SELECT 1 FROM activities WHERE id=?", (unrelated,)).fetchone())
        self.assert_round_trip(target, "deleted-merged")

    def test_incoming_deleted_versions_do_not_delete_live_destination_or_add_invalid_trash(self):
        activity = self.call(self.source, "create_activity", {"title": "Keep destination live"})["result"]["activityId"]
        self.call(self.source, "save_note", {"date": "2025-01-01", "body": "Keep page live", "expectedRevision": 0})
        target = self.target()
        self.restore(target, self.legacy_archive("undeleted-baseline.json"))
        for kind, key in (("activity", activity), ("note", "2025-01-01")):
            self.call(self.source, "delete_record", {"kind": kind, "id": key, "expectedRevision": 1})
        before = self.records(target)
        result = self.restore(target, self.legacy_archive("incoming-deletions.json"))["result"]
        self.assert_preserved(target, before)
        self.assert_conflict(result, "activities", activity)
        self.assert_conflict(result, "day_notes", "2025-01-01")
        self.assertEqual(result["counts"]["trash"], 0)
        self.assertEqual(self.records(target)["trash"], [])
        self.assert_round_trip(target, "incoming-deletions-merged")

    def test_active_timer_constraint_skips_whole_incoming_group_but_paused_group_can_append(self):
        _, incoming_timer = self.populate(running=True)
        for status in ("running", "paused"):
            with self.subTest(status=status):
                if status == "paused":
                    self.call(self.source, "timer_pause", {
                        "sessionId": incoming_timer["sessionId"], "intervalId": incoming_timer["intervalId"]})
                path = self.legacy_archive("incoming-" + status + ".json")
                incoming = self.records(self.source)
                target = self.target("local-timer-" + status)
                local_activity = self.call(target, "create_activity", {"title": "Keep local timer"})["result"]["activityId"]
                self.call(target, "timer_start", {"activityId": local_activity})
                before = self.records(target)
                result = self.restore(target, path)["result"]
                self.assert_preserved(target, before)
                self.assertEqual(result["interruptedTimers"], 0)
                self.assertEqual(result["counts"]["activities"], len(incoming["activities"]))
                self.assertEqual(result["counts"]["sessions"], len(incoming["sessions"]) - int(status == "running"))
                if status == "running":
                    self.assert_conflict(result, "sessions", incoming_timer["sessionId"])
                    self.assertEqual(result["counts"]["timer_sessions"], 0)
                    self.assertEqual(result["counts"]["session_intervals"], 0)
                    for table, key in (("sessions", "id"), ("timer_sessions", "session_id"), ("session_intervals", "session_id")):
                        self.assertIsNone(target.connection.execute(
                            f"SELECT 1 FROM {table} WHERE {key}=?", (incoming_timer["sessionId"],)).fetchone())
                else:
                    self.assertEqual(result["conflicts"], [])
                    self.assertEqual(result["counts"]["timer_sessions"], 1)
                    self.assertEqual(result["counts"]["session_intervals"], len(incoming["session_intervals"]))
                    self.assertEqual(target.connection.execute(
                        "SELECT status FROM timer_sessions WHERE session_id=?", (incoming_timer["sessionId"],)).fetchone()[0], "paused")
                    self.assertEqual([dict(row) for row in target.connection.execute(
                        "SELECT * FROM session_intervals WHERE session_id=? ORDER BY rowid", (incoming_timer["sessionId"],))],
                        incoming["session_intervals"])
                self.call(target, "settle_legacy_timers")
                self.assert_round_trip(target, "timer-constraint-" + status)

    def test_paused_timer_same_activity_and_completed_parent_conflicts_are_atomic(self):
        activity = self.call(self.source, "create_activity", {"title": "Shared timer parent"})["result"]["activityId"]
        baseline = self.legacy_archive("timer-parent-baseline.json")
        incoming_timer = self.call(self.source, "timer_start", {"activityId": activity})["result"]
        self.clock.advance(7)
        self.call(self.source, "timer_pause", {"sessionId": incoming_timer["sessionId"], "intervalId": incoming_timer["intervalId"]})
        self.call(self.source, "create_activity", {"title": "Independent import survives"})
        incoming = self.legacy_archive("paused-parent.json")
        for state in ("paused", "done", "deleted"):
            with self.subTest(parent=state):
                target = self.target("timer-parent-" + state)
                self.restore(target, baseline)
                if state == "paused":
                    local = self.call(target, "timer_start", {"activityId": activity})["result"]
                    self.call(target, "timer_pause", {"sessionId": local["sessionId"], "intervalId": local["intervalId"]})
                elif state == "done":
                    self.call(target, "set_done", {"activityId": activity, "done": True})
                else:
                    self.call(target, "delete_record", {"kind": "activity", "id": activity, "expectedRevision": 1})
                before = self.records(target)
                result = self.restore(target, incoming)["result"]
                self.assert_preserved(target, before)
                self.assert_conflict(result, "sessions", incoming_timer["sessionId"])
                self.assertEqual(result["counts"]["activities"], 1)
                for table in ("sessions", "timer_sessions", "session_intervals"):
                    self.assertEqual(result["counts"][table], 0)
                    self.assertEqual(self.records(target)[table], before[table])
                self.assert_round_trip(target, "timer-parent-merged-" + state)

    def test_conflicting_timer_session_does_not_import_new_intervals_or_change_local_state(self):
        activity = self.call(self.source, "create_activity", {"title": "Shared measured log"})["result"]["activityId"]
        timer = self.call(self.source, "timer_start", {"activityId": activity})["result"]
        self.clock.advance(7)
        self.call(self.source, "timer_pause", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]})
        target = self.target()
        self.restore(target, self.legacy_archive("paused-shared.json"))
        self.call(target, "update_session", {"sessionId": timer["sessionId"], "note": "Keep local measured note", "expectedRevision": 1})
        resumed = self.call(self.source, "timer_resume", {"sessionId": timer["sessionId"]})["result"]
        self.clock.advance(5)
        self.call(self.source, "timer_stop", {"sessionId": resumed["sessionId"], "intervalId": resumed["intervalId"]})
        extra = self.call(self.source, "add_session", {
            "activityId": activity, "date": "2025-01-03", "note": "Independent manual log"})["result"]["sessionId"]
        before = self.records(target)
        result = self.restore(target, self.legacy_archive("changed-timer.json"))["result"]
        self.assert_preserved(target, before)
        self.assert_conflict(result, "sessions", timer["sessionId"])
        self.assertEqual(result["counts"]["sessions"], 1)
        self.assertEqual(result["counts"]["timer_sessions"], 0)
        self.assertEqual(result["counts"]["session_intervals"], 0)
        self.assertEqual(self.records(target)["session_intervals"], before["session_intervals"])
        self.assertIsNotNone(target.connection.execute("SELECT 1 FROM sessions WHERE id=?", (extra,)).fetchone())
        self.assert_round_trip(target, "conflicting-timer-merged")

    def test_interval_id_collision_skips_whole_timer_group_and_keeps_unrelated_additions(self):
        _, incoming_timer = self.populate()
        target = self.target()
        activity = self.call(target, "create_activity", {"title": "Local measured log"})["result"]["activityId"]
        local = self.call(target, "timer_start", {"activityId": activity})["result"]
        self.call(target, "timer_stop", {"sessionId": local["sessionId"], "intervalId": local["intervalId"]})
        path = self.legacy_archive()
        document = json.loads(path.read_text())
        document["tables"]["session_intervals"][0]["id"] = local["intervalId"]
        path.write_text(json.dumps(document))
        before = self.records(target)
        result = self.restore(target, path)["result"]
        self.assert_preserved(target, before)
        self.assert_conflict(result, "sessions", incoming_timer["sessionId"])
        self.assertEqual(result["counts"]["sessions"], len(document["tables"]["sessions"]) - 1)
        self.assertEqual(result["counts"]["timer_sessions"], 0)
        self.assertEqual(result["counts"]["session_intervals"], 0)
        self.assertEqual(self.records(target)["timer_sessions"], before["timer_sessions"])
        self.assertEqual(self.records(target)["session_intervals"], before["session_intervals"])
        self.assert_round_trip(target, "interval-collision-merged")

    def test_trash_id_collision_skips_deleted_record_and_its_dependents_not_other_records(self):
        self.populate()
        path = self.legacy_archive()
        document = json.loads(path.read_text())
        incoming_trash = next(row for row in document["tables"]["trash"] if row["kind"] == "activity")
        deleted_activity = incoming_trash["record_id"]
        target = self.target()
        local = self.call(target, "create_activity", {"title": "Local deleted record"})["result"]["activityId"]
        trash = self.call(target, "delete_record", {"kind": "activity", "id": local, "expectedRevision": 1})["result"]["trashId"]
        incoming_trash["id"] = trash
        path.write_text(json.dumps(document))
        before = self.records(target)
        result = self.restore(target, path)["result"]
        self.assert_preserved(target, before)
        self.assertTrue(result["conflicts"])
        self.assertEqual(result["counts"]["activities"], len(document["tables"]["activities"]) - 1)
        self.assertIsNone(target.connection.execute("SELECT 1 FROM activities WHERE id=?", (deleted_activity,)).fetchone())
        self.assertIsNone(target.connection.execute("SELECT 1 FROM sessions WHERE activity_id=?", (deleted_activity,)).fetchone())
        self.assert_round_trip(target, "trash-collision-merged")

    def test_private_export_mode_does_not_depend_on_process_umask(self):
        old = os.umask(0o777)
        try:
            path = self.export()
        finally:
            os.umask(old)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(path.read_text())["format"], "daylog")

    def test_read_only_export_is_private_and_does_not_modify_records(self):
        self.populate()
        before = self.all_rows(self.source)
        with Store(self.source.path, read_only=True, clock=self.clock) as read_only:
            path = self.export("readonly.json", store=read_only)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(self.all_rows(read_only), before)
        self.assertEqual(path.stat().st_uid, os.getuid())

    def test_markdown_escapes_content_and_excludes_deleted_records(self):
        activity_id, _ = self.populate()
        hostile = '<script>alert("x")</script>\n# Injected heading\n```\n[click](javascript:alert(1))\n![tracking](https://example.invalid/x)\r\r![bare-cr](daylog-invalid:marker)\r\n[mixed-cr](daylog-invalid:marker)'
        self.source.connection.execute("UPDATE activities SET title=?, note=? WHERE id=?", (hostile, hostile, activity_id))
        path = self.export("journal.md", "markdown")
        content = path.read_text()
        self.assertNotIn("<script>", content)
        self.assertIn("    &lt;script&gt;", content)
        self.assertNotIn("\n# Injected heading", content)
        self.assertIn("    # Injected heading", content)
        self.assertIn("    ```", content)
        self.assertIn("    [click](javascript:alert(1))", content)
        self.assertFalse(any(line.startswith(("![", "[mixed-cr]")) for line in content.splitlines()))
        self.assertNotIn("\r", content)
        self.assertIn("Untimed", content)
        self.assertNotIn("Daily reflection", content)
        for deleted in ("Deleted synthetic activity", "Hidden child", "Deleted session", "Deleted reflection"):
            self.assertNotIn(deleted, content)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_no_clobber_no_symlinks_and_no_profile_or_source_exports(self):
        self.populate()
        occupied = self.root / "occupied.json"
        occupied.write_bytes(b"keep existing bytes")
        link = self.root / "linked.json"
        link.symlink_to(occupied)
        directory_link = self.root / "linked-directory"
        directory_link.symlink_to(self.root, target_is_directory=True)
        for path in (occupied, link, directory_link / "new.json", self.source.db_path,
                     self.source.path / "new.json", SOURCE_ROOT / "forbidden-export.json", Path("relative.json"),
                     Path("/" + str(self.source.path / "root-alias.json")), Path("/" + str(SOURCE_ROOT / "root-alias.json"))):
            with self.subTest(path=str(path)), self.assertRaises(StoreError):
                self.call(self.source, "export_records", {"format": "json", "path": str(path)})
        self.assertEqual(occupied.read_bytes(), b"keep existing bytes")
        self.assertFalse((self.root / "new.json").exists())
        self.assertFalse((self.source.path / "root-alias.json").exists())
        self.assertFalse((SOURCE_ROOT / "root-alias.json").exists())
        self.assertEqual(list(self.root.glob(".daylog-export-*")), [])

    def test_write_and_publication_failures_leave_no_partial_file(self):
        self.populate()
        for syscall in ("fsync", "link"):
            with self.subTest(syscall=syscall):
                path = self.root / (syscall + ".json")
                with patch("backend.portability.os." + syscall, side_effect=OSError("synthetic full disk")):
                    with self.assertRaises(StoreError):
                        self.call(self.source, "export_records", {"format": "json", "path": str(path)})
                self.assertFalse(path.exists())
                self.assertEqual(list(self.root.glob(".daylog-export-*")), [])

    def test_directory_sync_failure_removes_published_export(self):
        path = self.root / "sync-failure.json"
        real_fsync = os.fsync
        def fail_directory(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("synthetic directory sync failure")
            return real_fsync(fd)
        with patch("backend.portability.os.fsync", side_effect=fail_directory):
            with self.assertRaises(StoreError):
                export_records(self.source, {"format": "json", "path": str(path)})
        self.assertFalse(path.exists())
        self.assertEqual(list(self.root.glob(".daylog-export-*")), [])

    def test_restore_rejects_symlink_fifo_non_utf8_and_stale_revision(self):
        self.populate()
        path = self.legacy_archive()
        target = self.target()
        link = self.root / "restore-link.json"
        link.symlink_to(path)
        fifo = self.root / "restore-fifo"
        os.mkfifo(fifo)
        bad = self.root / "non-utf8.json"
        bad.write_bytes(b"\xff")
        before = self.all_rows(target)
        for invalid_path in (link, fifo, bad):
            with self.subTest(path=str(invalid_path)), self.assertRaises(StoreError):
                self.restore(target, invalid_path)
            self.assertEqual(self.all_rows(target), before)
        with self.assertRaises(StoreError) as error:
            self.call(target, "restore_records", {"path": str(path), "expectedRevision": 7})
        self.assertEqual(error.exception.code, "conflict")
        self.assertEqual(self.all_rows(target), before)

    def test_actual_full_append_preserves_existing_rows_and_retries_atomically(self):
        self.call(self.source, "create_activity", {"title": "Imported before large diary"})
        self.call(self.source, "save_note", {"date": "2025-01-01", "body": "SYNTHETIC full restore " * 20000, "expectedRevision": 0})
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Destination survives full disk"})
        before = self.all_rows(target)
        pages = target.connection.execute("PRAGMA page_count").fetchone()[0]
        target.connection.execute(f"PRAGMA max_page_count={pages}")
        with self.assertRaises(StoreError) as error:
            self.restore(target, path, "full-restore-retry")
        self.assertEqual(error.exception.code, "storage_full")
        self.assertEqual(self.all_rows(target), before)
        target.connection.execute("PRAGMA max_page_count=100000")
        self.restore(target, path, "full-restore-retry")
        self.assert_preserved(target, {table: before[table] for table in COLUMNS})
        self.assert_preserved(target, self.records(self.source))

    def test_mid_merge_insert_failure_rolls_back_partial_import_and_preserves_destination(self):
        activity, _ = self.populate()
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Keep local activity", "mode": "log", "date": "2024-12-30"})
        observed = []

        def observe_merge():
            observed.append(target.connection.execute("SELECT COUNT(*) FROM sessions WHERE activity_id=?", (activity,)).fetchone()[0])
            return 0

        target.connection.create_function("observe_merge", 0, observe_merge)
        target.connection.execute(
            "CREATE TRIGGER reject_notes BEFORE INSERT ON day_notes "
            "BEGIN SELECT observe_merge(); SELECT RAISE(ABORT, 'synthetic failure'); END")
        before = self.all_rows(target)
        with self.assertRaises(StoreError):
            self.restore(target, path, "trigger-retry")
        self.assertTrue(observed)
        self.assertGreater(observed[0], 0, "Failure must occur after related import rows were written")
        self.assertEqual(self.all_rows(target), before)
        target.connection.execute("DROP TRIGGER reject_notes")
        self.restore(target, path, "trigger-retry")
        self.assert_preserved(target, {table: before[table] for table in COLUMNS})
        self.assert_preserved(target, self.records(self.source))
        self.assert_round_trip(target, "trigger-retry-merged")

    def test_backup_sync_failure_leaves_populated_destination_and_retry_receipt_unchanged(self):
        self.populate()
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Existing before failed backup"})
        before = self.all_rows(target)
        with patch("backend.storage.os.fsync", side_effect=OSError("synthetic backup sync failure")):
            with self.assertRaises(StoreError):
                self.restore(target, path, "backup-retry")
        self.assertEqual(self.all_rows(target), before)
        self.assertEqual(list(target.path.glob("daylog.before-restore-*.sqlite3")), [])
        self.restore(target, path, "backup-retry")
        self.assert_preserved(target, {table: before[table] for table in COLUMNS})
        self.assert_preserved(target, self.records(self.source))

    def test_read_only_append_rejects_without_changing_populated_destination(self):
        self.populate()
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Keep read-only destination"})
        before = self.all_rows(target)
        with Store(target.path, read_only=True, clock=PortableClock()) as read_only:
            with self.assertRaises(StoreError) as failure:
                self.restore(read_only, path)
            self.assertEqual(failure.exception.code, "read_only")
            self.assertEqual(self.all_rows(read_only), before)
        self.assertEqual(list(target.path.glob("daylog.before-restore-*.sqlite3")), [])

    def test_direct_restore_savepoint_rolls_back_without_relying_on_dispatch(self):
        self.populate()
        path = self.legacy_archive()
        target = self.target()
        self.call(target, "create_activity", {"title": "Keep direct caller's existing record"})
        target.connection.execute("CREATE TRIGGER reject_notes BEFORE INSERT ON day_notes BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        before = self.all_rows(target)
        expected = target.connection.execute("SELECT revision FROM metadata").fetchone()[0]
        target.connection.execute("BEGIN IMMEDIATE")
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                restore_records(target, {"path": str(path), "expectedRevision": expected})
            self.assertEqual(self.all_rows(target), before)
        finally:
            target.connection.rollback()


if __name__ == "__main__":
    unittest.main()
