"""Consumer-visible correction, Trash, archival, migration and full-storage cases."""

from contextlib import closing
from pathlib import Path
import json
import subprocess
import sys
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from backend.storage import MIGRATIONS, Store, StoreError


class M4Tests(unittest.TestCase):
    def test_numeric_overflow_cannot_commit_before_json_response_failure(self):
        request = self.request("create_activity", {"title": "SYNTHETIC overflow", "mode": "log", "minutes": 1e308})
        helper = Path(__file__).resolve().parents[1] / "backend/helper.py"
        response = subprocess.run([sys.executable, str(helper), "--profile", str(self.profile)],
                                  input=json.dumps(request) + "\n", capture_output=True, text=True, timeout=10)
        self.assertEqual(response.returncode, 0, response.stderr)
        self.assertEqual(json.loads(response.stdout)["error"]["code"], "validation")
        self.assertEqual(self.snapshot()["activities"], [])
        owner = self.activity()
        self.log(owner, minutes=1e306)
        self.log(owner, minutes=1e306)
        before = self.snapshot()
        self.fail("validation", "add_session", {"activityId": owner, "date": "2025-01-06", "minutes": 1e306})
        self.assertEqual(self.snapshot(), before)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="daylog-m4-tests-")
        self.addCleanup(self.directory.cleanup)
        self.profile = Path(self.directory.name) / "journal"
        self.store = Store(self.profile)
        self.addCleanup(self.store.close)
        self.sequence = 0

    def request(self, op, args=None):
        self.sequence += 1
        return {"protocol": 1, "requestId": f"m4-{self.sequence}", "clientId": "m4-tests", "op": op, "args": args or {}}

    def call(self, op, args=None):
        return self.store.handle(self.request(op, args))

    def fail(self, code, op, args):
        with self.assertRaises(StoreError) as error:
            self.call(op, args)
        self.assertEqual(error.exception.code, code)

    def snapshot(self):
        return self.call("snapshot")["snapshot"]

    def activity(self, **fields):
        return self.call("create_activity", dict(title="SYNTHETIC M4 activity", **fields))["result"]["activityId"]

    def log(self, owner, **fields):
        return self.call("add_session", dict(activityId=owner, date="2025-01-06", **fields))

    def test_correct_manual_and_untimed_session_without_replanning_or_completion(self):
        owner = self.activity(plannedFor="2025-02-01")
        created = self.log(owner, minutes=35, note="Original reading")
        old = created["snapshot"]["sessions"][0]
        fields = dict(sessionId=old["id"], expectedRevision=old["revision"], date="2025-01-07", minutes=None, note="Corrected untimed reflection")
        request = self.request("update_session", fields)
        corrected = self.store.handle(request)
        session = corrected["snapshot"]["sessions"][0]
        self.assertEqual((session["date"], session["minutes"], session["source"], session["note"]),
                         ("2025-01-07", None, "untimed", "Corrected untimed reflection"))
        activity = corrected["snapshot"]["activities"][0]
        self.assertEqual((activity["plannedFor"], activity["status"]), ("2025-02-01", "open"))
        self.assertEqual(self.store.handle(request)["snapshot"], corrected["snapshot"])
        self.fail("conflict", "update_session", dict(fields, note="Stale competing edit"))
        history = self.call("history", {"query": "corrected untimed", "from": "2025-01-07", "to": "2025-01-07"})["result"]
        self.assertEqual([s["id"] for s in history["sessions"]], [old["id"]])
        review = self.call("review", {"weekOf": "2025-01-07"})["result"]
        self.assertEqual((review["loggedSeconds"], review["untimedSessions"], review["completedActivities"]), (0, 1, 0))

    def test_known_clock_overlap_and_midnight_do_not_invent_date_only_positions(self):
        owner = self.activity(category="Reading")
        first = self.log(owner, minutes=None, startUtc="2025-01-06T23:30:00Z", endUtc="2025-01-07T00:30:00Z", timeZone="UTC")
        second = self.call("add_session", {"activityId": owner, "date": "2025-01-07", "startUtc": "2025-01-07T00:00:00Z", "endUtc": "2025-01-07T01:00:00Z", "timeZone": "UTC"})
        self.assertIn("warning", second["result"])
        self.log(owner, minutes=15)
        review = self.call("review", {"weekOf": "2025-01-07"})["result"]
        self.assertEqual((review["clockSeconds"], review["reportedSeconds"], review["loggedSeconds"], review["overlapSeconds"], review["sessionCount"]),
                         (5400, 900, 6300, 1800, 3))
        history = self.call("history", {"from": "2025-01-07", "to": "2025-01-07"})["result"]
        slices = {s["id"]: s["minutes"] for s in history["sessions"]}
        self.assertEqual(slices[first["result"]["sessionId"]], 30)
        self.assertEqual(slices[second["result"]["sessionId"]], 60)
        before = self.snapshot()
        self.fail("validation", "add_session", {"activityId": owner, "date": "2025-01-07", "startUtc": "2025-01-07T01:00:00", "endUtc": "2025-01-07T02:00:00Z"})
        self.fail("validation", "add_session", {"activityId": owner, "date": "2025-01-07", "minutes": 20, "startUtc": "2025-01-07T01:00:00Z", "endUtc": "2025-01-07T02:00:00Z"})
        self.assertEqual(self.snapshot(), before)

    def test_nested_trash_undo_and_permanent_delete_preserve_only_intended_records(self):
        owner = self.activity(note="SYNTHETIC-PURGE-ACTIVITY-SENTINEL")
        session = self.log(owner, note="SYNTHETIC-PURGE-SESSION-SENTINEL")["snapshot"]["sessions"][0]
        session_trash = self.call("delete_record", {"kind": "session", "id": session["id"], "expectedRevision": session["revision"]})["result"]["trashId"]
        activity = self.snapshot()["activities"][0]
        activity_trash = self.call("delete_record", {"kind": "activity", "id": owner, "expectedRevision": activity["revision"]})["result"]["trashId"]
        hidden = self.snapshot()
        self.assertEqual((hidden["activities"], hidden["sessions"], hidden["events"]), ([], [], []))
        self.fail("not_found", "undo_delete", {"trashId": session_trash})
        restored = self.call("undo_delete", {"trashId": activity_trash})["snapshot"]
        self.assertEqual([a["id"] for a in restored["activities"]], [owner])
        self.assertEqual(restored["sessions"], [])
        self.call("undo_delete", {"trashId": session_trash})
        restored_session = self.snapshot()["sessions"][0]
        self.assertEqual(restored_session["note"], "SYNTHETIC-PURGE-SESSION-SENTINEL")
        deleted = self.call("delete_record", {"kind": "session", "id": session["id"], "expectedRevision": restored_session["revision"]})["result"]["trashId"]
        self.fail("validation", "purge_deleted", {"trashId": deleted})
        self.call("purge_deleted", {"trashId": deleted, "confirmed": True})
        self.assertNotIn(b"SYNTHETIC-PURGE-SESSION-SENTINEL", self.store.db_path.read_bytes())
        self.assertEqual(self.snapshot()["activities"][0]["note"], "SYNTHETIC-PURGE-ACTIVITY-SENTINEL")
        activity = self.snapshot()["activities"][0]
        deleted = self.call("delete_record", {"kind": "activity", "id": owner, "expectedRevision": activity["revision"]})["result"]["trashId"]
        self.call("purge_deleted", {"trashId": deleted, "confirmed": True})
        self.assertNotIn(b"SYNTHETIC-PURGE-ACTIVITY-SENTINEL", self.store.db_path.read_bytes())
        self.assertEqual(self.store.connection.execute("SELECT COUNT(*) FROM activity_events").fetchone()[0], 0)

    def test_timer_deletion_requires_stop_and_note_correction_cannot_rewrite_intervals(self):
        owner = self.activity()
        running = self.call("timer_start", {"activityId": owner})["snapshot"]["timer"]["active"]
        self.fail("timer_unfinished", "delete_record", {"kind": "session", "id": running["id"], "expectedRevision": running["revision"]})
        self.fail("timer_unfinished", "delete_record", {"kind": "activity", "id": owner, "expectedRevision": 1})
        self.call("timer_pause", {"sessionId": running["id"], "intervalId": running["intervalId"]})
        self.fail("timer_unfinished", "delete_record", {"kind": "session", "id": running["id"], "expectedRevision": running["revision"]})
        stopped = self.call("timer_stop", {"sessionId": running["id"], "intervalId": running["intervalId"], "note": "Measured work"})["snapshot"]["sessions"][0]
        fixed = self.call("update_session", {"sessionId": stopped["id"], "expectedRevision": stopped["revision"], "note": "Corrected measured-work note"})["snapshot"]["sessions"][0]
        self.assertEqual(fixed["intervals"], stopped["intervals"])
        self.fail("validation", "update_session", {"sessionId": fixed["id"], "expectedRevision": fixed["revision"], "note": "Bad rewrite", "minutes": 42})
        trashed = self.call("delete_record", {"kind": "session", "id": fixed["id"], "expectedRevision": fixed["revision"]})["result"]["trashId"]
        self.fail("not_found", "timer_stop", {"sessionId": fixed["id"], "intervalId": fixed["intervalId"], "note": "Hidden mutation"})
        self.call("purge_deleted", {"trashId": trashed, "confirmed": True})
        self.assertEqual(self.store.connection.execute("SELECT COUNT(*) FROM session_intervals").fetchone()[0], 0)
        self.assertEqual(self.snapshot()["activities"][0]["status"], "open")

    def test_day_note_trash_is_visible_recoverable_and_not_silently_replaced(self):
        self.call("save_note", {"date": "2025-01-06", "body": "SYNTHETIC daily reflection", "expectedRevision": 0})
        deleted = self.call("delete_record", {"kind": "note", "id": "2025-01-06", "expectedRevision": 1})["result"]["trashId"]
        self.assertNotIn("2025-01-06", self.snapshot()["dayNotes"])
        self.fail("deleted", "save_note", {"date": "2025-01-06", "body": "Replacement", "expectedRevision": 0})
        self.call("undo_delete", {"trashId": deleted})
        note = self.snapshot()["dayNotes"]["2025-01-06"]
        self.assertEqual((note["body"], note["revision"]), ("SYNTHETIC daily reflection", 3))
        self.fail("conflict", "save_note", {"date": "2025-01-06", "body": "Stale", "expectedRevision": 1})
        result = self.call("history", {"query": "daily reflection"})["result"]
        self.assertEqual(result["notes"][0]["body"], note["body"])

    def test_archival_renaming_and_casefold_conflicts_preserve_history(self):
        owner = self.activity(category="Reading", project="Book")
        self.log(owner, minutes=12)
        before = self.snapshot()
        label = before["categories"][0]
        self.call("update_label", {"kind": "category", "id": label["id"], "name": "Study", "archived": True, "expectedRevision": label["revision"]})
        snapshot = self.snapshot()
        self.assertEqual((snapshot["categories"][0]["id"], snapshot["activities"][0]["category"]), (label["id"], "Study"))
        self.assertEqual(len(self.call("history", {"category": "study"})["result"]["sessions"]), 1)
        self.fail("archived", "create_activity", {"title": "Do not silently reuse archived labels", "category": "Study"})
        old = before["activities"][0]
        self.fail("conflict", "update_activity", {"activityId": owner, "title": old["title"], "category": old["category"], "project": old["project"], "plannedFor": old["plannedFor"], "note": "Stale rename reversal", "expectedRevision": old["revision"]})
        current = snapshot["activities"][0]
        self.call("update_activity", {"activityId": owner, "title": current["title"], "category": "Study", "project": "Book", "plannedFor": "", "note": "Retain existing archived assignment", "expectedRevision": current["revision"]})
        self.call("update_label", {"kind": "category", "id": label["id"], "name": "Study", "archived": False, "expectedRevision": 2})
        self.activity(category="STUDY")
        self.assertEqual(len(self.snapshot()["categories"]), 1)
        self.activity(category="Other")
        self.fail("conflict", "update_label", {"kind": "category", "id": label["id"], "name": "OTHER", "archived": False, "expectedRevision": 3})

    def test_history_pages_are_bounded_complete_and_mutually_consistent(self):
        owner = self.activity()
        db = self.store.connection
        db.executemany("INSERT INTO sessions (id,activity_id,local_date,minutes,note,source,created_at) VALUES (?,?,'2025-01-06',NULL,?,'untimed','2025-01-06T12:00:00Z')",
                       [(f"fixture-{n:04}", owner, f"SYNTHETIC note {n}") for n in range(205)])
        pages = [self.call("history", {"offset": offset, "limit": 100}) for offset in (0, 100, 200)]
        ids = [s["id"] for page in pages for s in page["result"]["sessions"]]
        self.assertEqual(set(ids), {f"fixture-{n:04}" for n in range(205)})
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual([p["result"]["hasMore"] for p in pages], [True, True, False])
        self.assertEqual([p["result"]["nextOffset"] for p in pages], [100, 200, 205])
        self.fail("validation", "history", {"offset": -1})
        self.fail("validation", "history", {"limit": True})

    def test_actual_sqlite_full_rollback_and_same_request_retry(self):
        self.activity()
        before = self.snapshot()
        db = self.store.connection
        pages = db.execute("PRAGMA page_count").fetchone()[0]
        db.execute(f"PRAGMA max_page_count={pages}")
        request = self.request("save_note", {"date": "2025-01-06", "body": "SYNTHETIC large retained draft\n" * 20000, "expectedRevision": 0})
        with self.assertRaises(StoreError) as error:
            self.store.handle(request)
        self.assertEqual(error.exception.code, "storage_full")
        self.assertEqual(self.snapshot(), before)
        db.execute("PRAGMA max_page_count=100000")
        response = self.store.handle(request)
        self.assertEqual(response["snapshot"]["dayNotes"]["2025-01-06"]["body"], request["args"]["body"])
        self.assertEqual(self.store.handle(request)["result"], response["result"])
        self.assertEqual(self.snapshot()["dayNotes"]["2025-01-06"]["revision"], 1)

    def test_read_only_new_mutations_preserve_all_content(self):
        owner = self.activity(category="Reading")
        session = self.log(owner)["snapshot"]["sessions"][0]
        before = self.snapshot()
        with Store(self.profile, read_only=True) as readonly:
            for op, fields in [("delete_record", {"kind": "activity", "id": owner, "expectedRevision": 1}),
                               ("update_session", {"sessionId": session["id"], "expectedRevision": 1, "date": "2025-01-06", "note": "Unsaved"}),
                               ("update_label", {"kind": "category", "id": before["categories"][0]["id"], "name": "Unsaved", "archived": True, "expectedRevision": 1})]:
                with self.assertRaises(StoreError) as error:
                    readonly.handle(self.request(op, fields))
                self.assertEqual(error.exception.code, "read_only")
        self.assertEqual(self.snapshot(), before)

    def make_v3(self, name):
        profile = Path(self.directory.name) / name
        profile.mkdir()
        with closing(sqlite3.connect(profile / "daylog.sqlite3")) as db, db:
            for version in (1, 2, 3):
                for statement in MIGRATIONS[version]:
                    db.execute(statement)
                db.execute("INSERT INTO schema_migrations VALUES (?, '2025-01-01T00:00:00Z')", (version,))
            db.execute("INSERT INTO categories VALUES ('category','Reading','reading')")
            db.execute("INSERT INTO activities VALUES ('activity','SYNTHETIC v3','category',NULL,'2025-01-01','open','Original activity','2025-01-01T00:00:00Z','','',1)")
            db.execute("INSERT INTO sessions VALUES ('session','activity','2025-01-02',NULL,'Original untimed log','untimed','2025-01-02T00:00:00Z')")
            db.execute("PRAGMA user_version=3")
        return profile

    def test_v3_upgrade_backup_and_failed_upgrade_are_recoverable(self):
        profile = self.make_v3("v3")
        with Store(profile) as upgraded:
            snapshot = upgraded.handle(self.request("snapshot"))["snapshot"]
        self.assertEqual((snapshot["activities"][0]["id"], snapshot["sessions"][0]["note"]), ("activity", "Original untimed log"))
        backup_path, = profile.glob("daylog.before-v3-*.sqlite3")
        with closing(sqlite3.connect(backup_path)) as backup:
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 3)
            self.assertEqual(backup.execute("SELECT name FROM categories").fetchone()[0], "Reading")
        failed_profile = self.make_v3("failed-v3")
        original = (failed_profile / "daylog.sqlite3").read_bytes()
        with patch.dict(MIGRATIONS, {4: MIGRATIONS[4] + ("invalid migration statement",)}):
            with self.assertRaises(StoreError):
                Store(failed_profile)
        self.assertEqual((failed_profile / "daylog.sqlite3").read_bytes(), original)
        failed_backup, = failed_profile.glob("daylog.before-v3-*.sqlite3")
        with closing(sqlite3.connect(failed_backup)) as backup:
            self.assertEqual(backup.execute("SELECT note FROM sessions").fetchone()[0], "Original untimed log")


if __name__ == "__main__":
    unittest.main()
