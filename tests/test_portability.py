"""Temporary-profile portability tests: actual exports, restores, and failures."""

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
from backend.storage import SOURCE_ROOT, Store, StoreError
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

    def export(self, filename="journal.json", kind="json", store=None):
        path = self.root / filename
        response = self.call(store or self.source, "export_records", {"format": kind, "path": str(path)})
        self.assertEqual(response["result"]["path"], str(path))
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

    def restore(self, target, path, request_id=None):
        return self.call(target, "restore_records", {"path": str(path), "expectedRevision": 0}, request_id)

    def test_complete_round_trip_preserves_ids_deleted_records_labels_events_and_context(self):
        self.populate()
        before = self.records(self.source)
        path = self.export()
        document = json.loads(path.read_text())
        self.assertEqual((document["format"], document["formatVersion"], document["schemaVersion"]), ("daylog", 1, 5))
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
        second_export = self.export("second.json", store=target)
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
        path = self.export()
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
        self.assertEqual(json.loads(self.export("round-trip-pins.json", store=target).read_text())["tables"],
                         document["tables"])
        recovered = self.call(target, "undo_delete", {"trashId": trash_id})["snapshot"]
        self.assertIs(next(row for row in recovered["activities"] if row["id"] == hidden)["pinned"], True)
        self.assertEqual(next(row for row in recovered["activities"] if row["id"] == done)["status"], "done")
        self.assertEqual({row["activityId"] for row in recovered["sessions"]}, {done, hidden})

    def test_schema_v4_format_one_archives_import_without_pins_and_reexport_as_v5(self):
        self.populate()
        before = self.records(self.source)
        legacy = json.loads(self.export().read_text())
        legacy["schemaVersion"] = 4
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
        modern = json.loads(self.export("upgraded-archive.json", store=target).read_text())
        self.assertEqual((modern["formatVersion"], modern["schemaVersion"]), (1, 5))
        self.assertTrue(all(row["pinned"] is False for row in modern["tables"]["activities"]))
        for row in modern["tables"]["activities"]:
            del row["pinned"]
        self.assertEqual(modern["tables"], legacy["tables"])
        trash_id = next(row["id"] for row in before["trash"] if row["kind"] == "activity")
        recovered = self.call(target, "undo_delete", {"trashId": trash_id})["snapshot"]
        self.assertTrue(all(row["pinned"] is False for row in recovered["activities"]))

    def test_running_timer_restores_interrupted_without_unknown_elapsed_and_recovers(self):
        _, timer = self.populate(running=True)
        before = self.records(self.source)
        self.clock.advance(7200)
        path = self.export()
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

    def test_paused_timer_round_trip_stays_paused_with_all_intervals(self):
        _, timer = self.populate(running=True)
        self.call(self.source, "timer_pause", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"]})
        before = self.records(self.source)
        target = self.target()
        response = self.restore(target, self.export())
        self.assertEqual(response["result"]["interruptedTimers"], 0)
        self.assertEqual(self.records(target), before)
        self.assertEqual(target.connection.execute("SELECT status FROM timer_sessions").fetchone()[0], "paused")

    def test_already_interrupted_export_has_explicit_restored_recovery_reason(self):
        _, timer = self.populate(running=True)
        self.clock.advance(100)
        self.call(self.source, "snapshot")
        self.assertEqual(self.source.connection.execute("SELECT status FROM timer_sessions").fetchone()[0], "interrupted")
        target = self.target()
        self.restore(target, self.export())
        self.assertEqual(target.connection.execute("SELECT recovery_reason FROM timer_sessions").fetchone()[0], "restored")
        self.call(target, "timer_recover", {"sessionId": timer["sessionId"], "intervalId": timer["intervalId"], "action": "resume"})
        spans = self.records(target)["session_intervals"]
        self.assertEqual(len(spans), 3)
        self.assertIsNotNone(spans[-2]["end_utc"])
        self.assertIsNone(spans[-1]["end_utc"])
        self.assertEqual(spans[-1]["duration_seconds"], 0)

    def test_corruption_and_invalid_semantics_leave_every_target_record_unchanged(self):
        self.populate(running=True)
        original = json.loads(self.export().read_text())
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

    def test_rejected_restore_does_not_latch_a_populated_profiles_timer(self):
        self.populate(running=True)
        path = self.export()
        self.clock.advance(100)
        before = self.all_rows(self.source)
        expected = self.source.connection.execute("SELECT revision FROM metadata").fetchone()[0]
        with self.assertRaises(StoreError) as error:
            self.call(self.source, "restore_records", {"path": str(path), "expectedRevision": expected})
        self.assertEqual(error.exception.code, "conflict")
        self.assertEqual(self.all_rows(self.source), before)

    def test_populated_profiles_including_label_only_and_receipt_only_are_refused(self):
        self.populate()
        path = self.export()
        inserts = {
            "category": "INSERT INTO categories(id,name,name_key) VALUES ('label','Label','label')",
            "project": "INSERT INTO projects(id,name,name_key) VALUES ('label','Label','label')",
            "receipt": "INSERT INTO request_receipts VALUES ('prior','digest','{}')",
            "note": "INSERT INTO day_notes(local_date,body,revision,updated_at) VALUES ('2025-01-01','',1,'2025-01-01T00:00:00Z')",
            "trash": "INSERT INTO trash VALUES ('trash','activity','absent','2025-01-01T00:00:00Z')",
        }
        for name, sql in inserts.items():
            with self.subTest(name=name):
                target = self.target(name)
                target.connection.execute(sql)
                before = self.all_rows(target)
                with self.assertRaises(StoreError) as error:
                    self.restore(target, path)
                self.assertEqual(error.exception.code, "conflict")
                self.assertEqual(self.all_rows(target), before)

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
        self.assertIn("Daily reflection", content)
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
        path = self.export()
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

    def test_actual_full_restore_preserves_error_and_retries_atomically(self):
        self.call(self.source, "save_note", {"date": "2025-01-01", "body": "SYNTHETIC full restore " * 20000, "expectedRevision": 0})
        path = self.export()
        target = self.target()
        before = self.all_rows(target)
        pages = target.connection.execute("PRAGMA page_count").fetchone()[0]
        target.connection.execute(f"PRAGMA max_page_count={pages}")
        with self.assertRaises(StoreError) as error:
            self.restore(target, path, "full-restore-retry")
        self.assertEqual(error.exception.code, "storage_full")
        self.assertEqual(self.all_rows(target), before)
        target.connection.execute("PRAGMA max_page_count=100000")
        self.restore(target, path, "full-restore-retry")
        self.assertEqual(self.records(target), self.records(self.source))

    def test_insert_failure_rolls_back_every_imported_record(self):
        self.populate()
        path = self.export()
        target = self.target()
        target.connection.execute("CREATE TRIGGER reject_notes BEFORE INSERT ON day_notes BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        before = self.all_rows(target)
        with self.assertRaises(StoreError):
            self.restore(target, path)
        self.assertEqual(self.all_rows(target), before)

    def test_direct_restore_savepoint_rolls_back_without_relying_on_dispatch(self):
        self.populate()
        path = self.export()
        target = self.target()
        target.connection.execute("CREATE TRIGGER reject_notes BEFORE INSERT ON day_notes BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        before = self.all_rows(target)
        target.connection.execute("BEGIN IMMEDIATE")
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                restore_records(target, {"path": str(path), "expectedRevision": 0})
            self.assertEqual(self.all_rows(target), before)
        finally:
            target.connection.rollback()


if __name__ == "__main__":
    unittest.main()
