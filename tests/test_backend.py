"""Persistent behavior exercised through independent real helper processes."""

from contextlib import closing, contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from backend.storage import MIGRATIONS, SCHEMA_VERSION, SOURCE_ROOT, Store, StoreError, profile_path


HELPER = SOURCE_ROOT / "backend/helper.py"


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daylog-backend-")
        self.addCleanup(self.temporary.cleanup)
        self.profile = Path(self.temporary.name) / "profile"
        self.sequence = 0

    def request(self, op, args=None, request_id=None):
        self.sequence += 1
        return {"protocol": 1, "requestId": request_id or f"request-{self.sequence}", "op": op, "args": args or {}}

    def invoke(self, request, *, read_only=False, profile=None, env=None):
        command = [sys.executable, str(HELPER), "--profile", str(profile or self.profile)]
        if read_only:
            command.append("--read-only")
        raw = request if isinstance(request, bytes) else (json.dumps(request, ensure_ascii=True) + "\n").encode()
        process = subprocess.run(command, input=raw, capture_output=True, timeout=10, env=env)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, b"")
        self.assertEqual(len(process.stdout.splitlines()), 1)
        response = json.loads(process.stdout)
        self.assertEqual(response["protocol"], 1)
        if isinstance(request, dict) and isinstance(request.get("requestId"), str):
            self.assertEqual(response["requestId"], request["requestId"])
        return response

    def call(self, op, args=None, **options):
        response = self.invoke(self.request(op, args), **options)
        self.assertTrue(response["ok"], response)
        return response

    def rejected(self, op, args, code):
        response = self.invoke(self.request(op, args))
        self.assertFalse(response["ok"], response)
        self.assertEqual(response["error"]["code"], code)
        return response

    def create(self, **fields):
        return self.call("create_activity", dict(title="A task", mode="plan", **fields))

    def edit_fields(self, activity, **changes):
        fields = {key: activity[key] for key in ("title", "category", "project", "plannedFor", "note")}
        fields.update(activityId=activity["id"], expectedRevision=activity["revision"])
        fields.update(changes)
        return fields

    @contextmanager
    def database(self, path=None):
        with closing(sqlite3.connect(path or self.profile / "daylog.sqlite3")) as connection, connection:
            yield connection

    def test_pin_only_updates_persist_without_changing_dates_history_or_counts(self):
        self.call("create_activity", {"title": "SYNTHETIC recurring reading", "mode": "log",
                                     "date": "2024-01-03", "plannedFor": "2029-02-04",
                                     "category": "Reading", "project": "Book", "note": "Keep this note"})
        before = self.create(plannedFor="2024-01-02")["snapshot"]
        activity, other = before["activities"]
        self.assertIs(activity["pinned"], False)
        self.assertIs(other["pinned"], False)
        history = self.call("history")["result"]
        pinned = self.call("update_activity", {"activityId": activity["id"], "pinned": True,
                                                "expectedRevision": activity["revision"]})
        expected = dict(before, revision=before["revision"] + 1,
                        activities=[dict(activity, pinned=True, revision=activity["revision"] + 1), other])
        self.assertEqual(pinned["snapshot"], expected)
        self.assertIs(pinned["snapshot"]["activities"][0]["pinned"], True)
        self.assertEqual(self.call("snapshot")["snapshot"], expected)
        self.assertEqual(self.call("history")["result"], history)
        unpinned = self.call("update_activity", {"activityId": activity["id"], "pinned": False,
                                                  "expectedRevision": activity["revision"] + 1})["snapshot"]
        self.assertEqual(unpinned, dict(before, revision=before["revision"] + 2,
                                       activities=[dict(activity, revision=activity["revision"] + 2), other]))
        self.assertIs(self.call("snapshot")["snapshot"]["activities"][0]["pinned"], False)

    def test_pins_survive_edits_completion_reopen_and_delete_restore(self):
        created = self.create(pinned=True, plannedFor="2028-03-01")
        activity = created["snapshot"]["activities"][0]
        self.assertIs(activity["pinned"], True)
        edited = self.call("update_activity", self.edit_fields(
            activity, title="SYNTHETIC revised title", note="Revised note", plannedFor="2028-03-02"))
        self.assertIs(edited["snapshot"]["activities"][0]["pinned"], True)
        completed = self.call("set_done", {"activityId": activity["id"], "done": True})["snapshot"]
        done = completed["activities"][0]
        self.assertIs(done["pinned"], True)
        unpinned = self.call("update_activity", {"activityId": activity["id"], "pinned": False,
                                                  "expectedRevision": done["revision"]})["snapshot"]
        self.assertEqual(unpinned, dict(completed, revision=completed["revision"] + 1,
                                       activities=[dict(done, pinned=False, revision=done["revision"] + 1)]))
        repinned = self.call("update_activity", {"activityId": activity["id"], "pinned": True,
                                                  "expectedRevision": done["revision"] + 1})["snapshot"]
        self.assertEqual(repinned, dict(completed, revision=completed["revision"] + 2,
                                       activities=[dict(done, revision=done["revision"] + 2)]))
        logged = self.call("add_session", {"activityId": activity["id"], "date": "2024-01-05"})["snapshot"]
        self.assertEqual(logged["activities"], repinned["activities"])
        reopened = self.call("set_done", {"activityId": activity["id"], "done": False})["snapshot"]
        current = reopened["activities"][0]
        self.assertIs(current["pinned"], True)
        self.assertEqual((current["status"], current["completedAt"], current["completedDate"]), ("open", "", ""))
        deleted = self.call("delete_record", {"kind": "activity", "id": activity["id"],
                                               "expectedRevision": current["revision"]})
        self.assertEqual((deleted["snapshot"]["activities"], deleted["snapshot"]["sessions"]), ([], []))
        restored = self.call("undo_delete", {"trashId": deleted["result"]["trashId"]})["snapshot"]
        self.assertEqual(restored["activities"], [dict(current, revision=current["revision"] + 2)])
        self.assertEqual(restored["sessions"], reopened["sessions"])
        self.assertEqual(restored["insights"], reopened["insights"])
        self.assertIs(self.call("snapshot")["snapshot"]["activities"][0]["pinned"], True)

    def test_pin_cas_and_replay_never_overwrite_a_newer_pin_or_editor(self):
        create_request = self.request("create_activity", {"title": "SYNTHETIC pin replay", "pinned": True})
        created = self.invoke(create_request)
        self.assertTrue(created["ok"], created)
        original = created["snapshot"]["activities"][0]
        pin_request = self.request("update_activity", {"activityId": original["id"], "pinned": False,
                                                        "expectedRevision": original["revision"]})
        unpinned = self.invoke(pin_request)
        self.assertTrue(unpinned["ok"], unpinned)
        current = unpinned["snapshot"]["activities"][0]
        self.rejected("update_activity", self.edit_fields(original, title="Stale editor"), "conflict")
        self.rejected("update_activity", {"activityId": original["id"], "pinned": True,
                                     "expectedRevision": original["revision"]}, "conflict")
        self.assertEqual(self.call("snapshot")["snapshot"], unpinned["snapshot"])
        edited = self.call("update_activity", self.edit_fields(current, note="Newer ordinary edit"))["snapshot"]
        self.assertIs(edited["activities"][0]["pinned"], False)
        self.rejected("update_activity", {"activityId": original["id"], "pinned": True,
                                     "expectedRevision": current["revision"]}, "conflict")
        repinned = self.call("update_activity", {"activityId": original["id"], "pinned": True,
                                                  "expectedRevision": edited["activities"][0]["revision"]})["snapshot"]
        for request, response in ((create_request, created), (pin_request, unpinned)):
            replay = self.invoke(request)
            self.assertTrue(replay["ok"], replay)
            self.assertEqual(replay["result"], response["result"])
            self.assertEqual(replay["snapshot"], repinned)
        reused = self.invoke(dict(pin_request, args=dict(pin_request["args"], pinned=True)))
        self.assertEqual(reused["error"]["code"], "conflict")
        self.assertEqual(self.call("snapshot")["snapshot"], repinned)

    def test_pins_require_booleans_and_invalid_writes_leave_no_receipts(self):
        before = self.create()["snapshot"]
        activity = before["activities"][0]
        with self.database() as connection:
            receipts = connection.execute("SELECT * FROM request_receipts").fetchall()
        for value in (None, 0, 1, 0.0, 1.0, "true", "false", "", [], {}):
            with self.subTest(pinned=value):
                self.rejected("create_activity", {"title": "Invalid pin", "category": "Uncommitted",
                                             "pinned": value}, "validation")
                self.rejected("update_activity", {"activityId": activity["id"], "pinned": value,
                                             "category": "Uncommitted", "expectedRevision": activity["revision"]}, "validation")
                self.assertEqual(self.call("snapshot")["snapshot"], before)
        for expected in (None, True, -1, "1"):
            with self.subTest(expectedRevision=expected):
                self.rejected("update_activity", {"activityId": activity["id"], "pinned": True,
                                             "expectedRevision": expected}, "validation")
        with self.database() as connection:
            self.assertEqual(connection.execute("SELECT * FROM request_receipts").fetchall(), receipts)
        retry = self.request("update_activity", {"activityId": activity["id"], "pinned": "true",
                                                  "expectedRevision": activity["revision"]})
        self.assertEqual(self.invoke(retry)["error"]["code"], "validation")
        retry["args"]["pinned"] = True
        saved = self.invoke(retry)
        self.assertTrue(saved["ok"], saved)
        self.assertIs(saved["snapshot"]["activities"][0]["pinned"], True)

    def test_title_only_and_default_log_date_survive_fresh_processes(self):
        created = self.call("create_activity", {"title": "Only a title"})
        activity = created["snapshot"]["activities"][0]
        self.assertEqual((activity["category"], activity["project"], activity["plannedFor"]), ("", "", ""))
        self.assertEqual(activity["status"], "open")
        self.assertEqual(created["snapshot"]["sessions"], [])
        logged = self.call("create_activity", {"title": "Retrospective", "mode": "log"})
        session = logged["snapshot"]["sessions"][0]
        self.assertEqual(session["date"], logged["snapshot"]["today"])
        self.assertIsNone(session["minutes"])
        self.assertEqual((session["source"], session["status"], session["clock"]), ("untimed", "stopped", ""))
        restarted = self.call("snapshot")["snapshot"]
        self.assertEqual(restarted, logged["snapshot"])
        self.assertEqual(restarted["revision"], 2)

    def test_two_sessions_reschedule_complete_and_reopen_keep_actual_dates(self):
        created = self.create(plannedFor="2025-01-02")
        activity_id = created["result"]["activityId"]
        first = self.call("add_session", {"activityId": activity_id, "date": "2025-01-03", "minutes": 25.5, "note": "first"})
        second = self.call("add_session", {"activityId": activity_id, "date": "2025-01-05", "minutes": None, "note": "second"})
        self.assertEqual(second["snapshot"]["activities"][0]["status"], "open")
        before_sessions = second["snapshot"]["sessions"]
        updated = self.call("update_activity", self.edit_fields(second["snapshot"]["activities"][0], plannedFor="2025-09-20"))
        event = updated["snapshot"]["events"][0]
        self.assertEqual((event["action"], event["from"], event["to"]), ("reschedule", "2025-01-02", "2025-09-20"))
        self.assertEqual(updated["snapshot"]["sessions"], before_sessions)
        completed = self.call("set_done", {"activityId": activity_id, "done": True})
        done = completed["snapshot"]["activities"][0]
        self.assertEqual(done["status"], "done")
        self.assertTrue(done["completedAt"].endswith("Z"))
        self.assertEqual(done["completedDate"], completed["snapshot"]["today"])
        repeated = self.call("set_done", {"activityId": activity_id, "done": True})
        self.assertEqual(repeated["snapshot"]["activities"], completed["snapshot"]["activities"])
        self.assertEqual(repeated["snapshot"]["events"], completed["snapshot"]["events"])
        reopened = self.call("set_done", {"activityId": activity_id, "done": False})
        open_activity = reopened["snapshot"]["activities"][0]
        self.assertEqual((open_activity["status"], open_activity["completedAt"], open_activity["completedDate"]), ("open", "", ""))
        self.assertEqual(reopened["snapshot"]["sessions"], before_sessions)
        self.assertEqual([e["action"] for e in reopened["snapshot"]["events"]], ["reschedule", "complete", "reopen"])
        self.assertEqual([s["id"] for s in self.call("history")["result"]["sessions"]],
                         [second["result"]["sessionId"], first["result"]["sessionId"]])

    def test_adding_session_to_done_activity_never_reopens_or_duplicates_it(self):
        created = self.create(done=True)
        original = created["snapshot"]["activities"][0]
        result = self.call("add_session", {"activityId": original["id"], "date": "2024-02-29", "minutes": 5, "done": False})
        self.assertEqual(result["snapshot"]["activities"], [original])
        self.assertEqual(result["snapshot"]["sessions"][0]["activityId"], original["id"])
        self.assertEqual(self.call("history")["result"]["completions"], [])

    def test_log_with_completion_is_atomic_and_untimed_is_not_zero(self):
        logged = self.call("create_activity", {"title": "Called service", "mode": "log", "date": "2020-02-02", "done": True})
        activity = logged["snapshot"]["activities"][0]
        session = logged["snapshot"]["sessions"][0]
        self.assertEqual(activity["status"], "done")
        self.assertEqual(session["date"], "2020-02-02")
        self.assertIsNone(session["minutes"])
        before = self.call("snapshot")["snapshot"]
        self.rejected("create_activity", {"title": "Bad entry", "category": "Never created", "mode": "log", "date": "2025-02-29", "done": True}, "validation")
        self.assertEqual(self.call("snapshot")["snapshot"], before)

    def test_failed_completion_rolls_back_activity_session_labels_and_receipt(self):
        before = self.call("snapshot")["snapshot"]
        with self.database() as connection:
            connection.execute("""CREATE TRIGGER refuse_completion BEFORE UPDATE OF status ON activities
                WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT, 'private database diagnostic'); END""")
        request = self.request("create_activity", {"title": "Atomic", "category": "New label", "project": "New project",
                                                   "mode": "log", "date": "2024-01-01", "done": True})
        failed = self.invoke(request)
        self.assertEqual(failed["error"]["code"], "storage")
        self.assertNotIn("private database diagnostic", json.dumps(failed))
        self.assertEqual(self.call("snapshot")["snapshot"], before)
        with self.database() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM request_receipts").fetchone()[0], 0)
            connection.execute("DROP TRIGGER refuse_completion")
        retried = self.invoke(request)
        self.assertTrue(retried["ok"], retried)
        self.assertEqual(retried["snapshot"]["activities"][0]["status"], "done")
        self.assertEqual(retried["snapshot"]["sessions"][0]["activityId"], retried["result"]["activityId"])

    def test_add_session_can_explicitly_complete_an_open_activity(self):
        created = self.create()
        activity_id = created["result"]["activityId"]
        completed = self.call("add_session", {"activityId": activity_id, "date": "2024-01-01",
                                              "minutes": 15, "done": True})
        activity = completed["snapshot"]["activities"][0]
        self.assertEqual(activity["status"], "done")
        self.assertEqual(activity["completedDate"], completed["snapshot"]["today"])
        self.assertEqual(completed["snapshot"]["sessions"][0]["source"], "manual")
        self.assertEqual(completed["snapshot"]["events"][0]["action"], "complete")

    def test_sql_unicode_and_normalized_optional_names_roundtrip(self):
        title = "Straße 東京 '; DROP TABLE activities; --"
        note = "مرحبا\nSELECT * FROM day_notes; 🐍"
        created = self.call("create_activity", {"title": title, "note": note, "mode": "log", "date": "2024-01-01",
                                               "category": "  Cafe\u0301 ", "project": " Straße ", "sessionNote": "ΣΊΓΜΑ"})
        self.call("create_activity", {"title": "Second", "category": "CAFÉ", "project": "STRASSE", "mode": "plan"})
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(snapshot["activities"][0]["title"], title)
        self.assertEqual(snapshot["activities"][0]["note"], note)
        self.assertEqual([c["name"] for c in snapshot["categories"]], ["Café"])
        self.assertEqual([p["name"] for p in snapshot["projects"]], ["Straße"])
        self.assertEqual(snapshot["activities"][1]["category"], "Café")
        history = self.call("history", {"query": "STRASSE", "category": "cafe\u0301", "project": "strasse"})["result"]
        self.assertEqual(history["sessions"], created["snapshot"]["sessions"])
        self.assertEqual(self.call("history", {"query": "SELECT *"})["result"]["sessions"], created["snapshot"]["sessions"])
        self.assertEqual(self.call("history", {"query": "σίγμα"})["result"]["sessions"], created["snapshot"]["sessions"])

    def test_history_search_filters_dates_and_daily_note_independence(self):
        logged = self.call("create_activity", {"title": "Book", "mode": "log", "category": "Reading", "project": "Library",
                                              "date": "2024-03-03", "plannedFor": "2029-10-20", "sessionNote": "Needle in a session"})
        self.call("add_session", {"activityId": logged["result"]["activityId"], "date": "2024-03-04", "minutes": 20, "note": "Other day"})
        self.call("save_note", {"date": "2024-03-03", "body": "A daily NEEDLE", "expectedRevision": 0})
        result = self.call("history", {"query": "needle", "from": "2024-03-03", "to": "2024-03-03"})["result"]
        self.assertEqual([s["date"] for s in result["sessions"]], ["2024-03-03"])
        self.assertEqual(result["notes"], [{"date": "2024-03-03", "body": "A daily NEEDLE", "revision": 1}])
        filtered = self.call("history", {"query": "needle", "category": "READING", "project": "library"})["result"]
        self.assertEqual(filtered["sessions"], result["sessions"])
        self.assertEqual(filtered["notes"], [])
        self.assertEqual(self.call("history", {"from": "2029-10-20"})["result"]["sessions"], [])
        self.rejected("history", {"from": "2025-01-01", "to": "2024-01-01"}, "validation")
        self.rejected("history", {"from": "2024-2-1"}, "validation")

    def test_completion_only_history_uses_persisted_local_completion_date(self):
        # These two zones are 26 hours apart, so their local calendar dates differ
        # regardless of the wall clock hour. No system clock changes are needed.
        east = dict(os.environ, TZ="XXX-14")
        west = dict(os.environ, TZ="XXX12")
        created = self.call("create_activity", {"title": "Only completed", "mode": "plan", "done": True,
                                               "plannedFor": "1999-01-01", "category": "Personal"}, env=east)
        activity = created["snapshot"]["activities"][0]
        day = activity["completedDate"]
        restarted = self.call("snapshot", env=west)["snapshot"]
        self.assertNotEqual(restarted["today"], day)
        self.assertEqual(restarted["activities"][0]["completedDate"], day)
        result = self.call("history", {"from": day, "to": day, "query": "completed", "category": "personal"}, env=west)["result"]
        self.assertEqual(result["completions"], [activity])
        self.assertEqual(result["sessions"], [])
        self.assertEqual(self.call("history", {"from": "1999-01-01", "to": "1999-01-01"})["result"]["completions"], [])
        self.call("add_session", {"activityId": activity["id"], "date": "2001-01-01", "minutes": None})
        # Even when the session lies outside the filter, don't invent a second entry.
        self.assertEqual(self.call("history", {"from": day, "to": day})["result"]["completions"], [])

    def test_activity_cas_rejects_stale_form_without_changing_sessions(self):
        created = self.create()
        activity = created["snapshot"]["activities"][0]
        updated = self.call("update_activity", self.edit_fields(activity, title="New title", plannedFor="2024-05-02"))
        self.rejected("update_activity", self.edit_fields(activity, title="Stale overwrite", category="Must not exist"), "conflict")
        self.assertEqual(self.call("snapshot")["snapshot"], updated["snapshot"])
        unchanged = self.call("update_activity", self.edit_fields(updated["snapshot"]["activities"][0], note="Only note"))
        self.assertEqual(unchanged["snapshot"]["events"], updated["snapshot"]["events"])
        inbox = self.call("update_activity", self.edit_fields(unchanged["snapshot"]["activities"][0], plannedFor=""))
        self.assertEqual(inbox["snapshot"]["events"][-1]["to"], "")

    def test_note_cas_identical_new_writes_conflicts_and_explicit_overwrite(self):
        args = {"date": "2024-04-01", "body": "first draft", "expectedRevision": 0}
        saved = self.call("save_note", args)
        conflict = self.rejected("save_note", dict(args, body="stale draft"), "conflict")
        self.assertEqual(conflict["error"]["currentNote"], dict(date=args["date"], **saved["snapshot"]["dayNotes"][args["date"]]))
        same = self.call("save_note", dict(args, expectedRevision=1))
        self.assertEqual(same["result"]["revision"], 2)
        self.rejected("save_note", dict(args, expectedRevision=1), "conflict")
        overwritten = self.call("save_note", dict(args, body="user reviewed and chose overwrite", expectedRevision=2))
        self.assertEqual(overwritten["snapshot"]["dayNotes"][args["date"]]["revision"], 3)
        cleared = self.call("save_note", dict(args, body="", expectedRevision=3))
        self.assertEqual(self.call("snapshot")["snapshot"]["dayNotes"], cleared["snapshot"]["dayNotes"])

    def test_concurrent_note_writers_have_one_winner_and_one_conflict(self):
        self.call("snapshot")
        command = [sys.executable, str(HELPER), "--profile", str(self.profile)]
        processes = []
        for body in ("Writer A", "Writer B"):
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            process.stdin.write((json.dumps(self.request("save_note", {"date": "2024-01-01", "body": body, "expectedRevision": 0})) + "\n").encode())
            process.stdin.close()
            process.stdin = None
            processes.append(process)
        responses = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(stderr, b"")
            responses.append(json.loads(stdout))
        successes = [r for r in responses if r["ok"]]
        failures = [r for r in responses if not r["ok"]]
        self.assertEqual(len(successes), 1)
        self.assertEqual([r["error"]["code"] for r in failures], ["conflict"])
        self.assertEqual(failures[0]["error"]["currentNote"]["body"], successes[0]["snapshot"]["dayNotes"]["2024-01-01"]["body"])

    def test_every_mutation_replay_returns_current_snapshot_without_reapplying(self):
        create_request = self.request("create_activity", {"title": "Replay", "mode": "plan"})
        created = self.invoke(create_request)
        activity = created["snapshot"]["activities"][0]
        requests = [create_request,
                    self.request("add_session", {"activityId": activity["id"], "date": "2024-01-01", "minutes": None}),
                    self.request("update_activity", self.edit_fields(activity, title="Changed", plannedFor="2024-02-02")),
                    self.request("set_done", {"activityId": activity["id"], "done": True}),
                    self.request("save_note", {"date": "2024-01-01", "body": "Original note", "expectedRevision": 0})]
        originals = [created] + [self.invoke(r) for r in requests[1:]]
        self.assertTrue(all(r["ok"] for r in originals))
        self.call("set_done", {"activityId": activity["id"], "done": False})
        current = self.call("save_note", {"date": "2024-01-01", "body": "Newer note", "expectedRevision": 1})["snapshot"]
        for request, original in zip(requests, originals):
            with self.subTest(operation=request["op"]):
                replay = self.invoke(request)
                self.assertTrue(replay["ok"], replay)
                self.assertEqual(replay["result"], original["result"])
                self.assertEqual(replay["snapshot"], current)
                changed = dict(request, args=dict(request["args"], unexpected="different payload"))
                conflict = self.invoke(changed)
                self.assertEqual(conflict["error"]["code"], "conflict")
        self.assertEqual(self.call("snapshot")["snapshot"], current)
        with self.database() as connection:
            receipts = connection.execute("SELECT digest, result FROM request_receipts").fetchall()
        for digest, result in receipts:
            self.assertEqual(len(digest), 64)
            self.assertLessEqual(set(json.loads(result)), {"activityId", "sessionId", "revision", "date"})
        self.assertNotIn("Original note", str(receipts))
        self.assertNotIn("Changed", str(current["events"]))

    def test_invalid_inputs_are_atomic_and_failed_id_can_be_retried(self):
        self.call("snapshot")
        cases = [{"title": " "}, {"title": "x", "mode": "timer"}, {"title": "x", "done": 1},
                 {"title": "x", "plannedFor": "2024-02-30"}, {"title": "x", "minutes": 0},
                 {"title": "x", "minutes": -1}, {"title": "x", "minutes": True},
                 {"title": "x", "minutes": "20"}, {"title": "x", "category": None},
                 {"title": "x", "note": ["bad"]}, {"title": "\ud800"}]
        for args in cases:
            with self.subTest(args=args):
                self.rejected("create_activity", args, "validation")
        request = self.request("create_activity", {"title": "", "mode": "plan"})
        self.assertFalse(self.invoke(request)["ok"])
        self.assertEqual(self.call("snapshot")["snapshot"]["revision"], 0)
        request["args"]["title"] = "Corrected draft"
        self.assertTrue(self.invoke(request)["ok"])
        self.rejected("add_session", {"activityId": "missing", "date": "2024-01-01"}, "not_found")
        self.rejected("save_note", {"date": "2024-01-01", "body": "bad revision", "expectedRevision": True}, "validation")

    def test_protocol_errors_are_sanitized_and_do_not_create_a_profile(self):
        inputs = [b"not json\n", b"{}\n{}\n", b"{\"protocol\":1,\"protocol\":1}\n", b"\xff\n",
                  b"{\"value\":NaN}\n", [], {"protocol": 2, "requestId": "x", "op": "snapshot", "args": {}},
                  {"protocol": 1, "requestId": "x", "op": "delete_everything", "args": {}},
                  {"protocol": 1, "requestId": "x", "op": "snapshot", "args": []}]
        for value in inputs:
            with self.subTest(value=value):
                response = self.invoke(value)
                self.assertFalse(response["ok"])
                self.assertEqual(response["error"]["code"], "protocol")
                self.assertFalse(self.profile.exists())

    def test_real_readonly_connection_reads_but_refuses_writes(self):
        self.create(note="Sensitive marker should not leak into errors")
        before = (self.profile / "daylog.sqlite3").read_bytes()
        self.assertTrue(self.call("snapshot", read_only=True)["ok"])
        failed = self.invoke(self.request("save_note", {"date": "2024-01-01", "body": "Secret failed write", "expectedRevision": 0}), read_only=True)
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["error"]["code"], "read_only")
        self.assertNotIn("Secret", json.dumps(failed))
        self.assertEqual((self.profile / "daylog.sqlite3").read_bytes(), before)

    def test_actual_busy_failure_can_retry_the_same_request_after_unlock(self):
        before = self.create()["snapshot"]
        request = self.request("save_note", {"date": "2024-01-01", "body": "Not lost", "expectedRevision": 0})
        with self.database() as lock:
            lock.execute("BEGIN IMMEDIATE")
            failed = self.invoke(request)
            self.assertFalse(failed["ok"])
            self.assertEqual(failed["error"]["code"], "busy")
            lock.rollback()
        self.assertEqual(self.call("snapshot")["snapshot"], before)
        retried = self.invoke(request)
        self.assertTrue(retried["ok"])
        self.assertEqual(retried["snapshot"]["dayNotes"]["2024-01-01"]["body"], "Not lost")

    def test_corrupt_future_and_unknown_databases_are_untouched(self):
        for kind in ("corrupt", "future", "unknown"):
            with self.subTest(kind=kind):
                profile = Path(self.temporary.name) / kind
                profile.mkdir(mode=0o755)
                database = profile / "daylog.sqlite3"
                if kind == "corrupt":
                    database.write_bytes(b"Not a database. Preserve this exact content.")
                else:
                    with self.database(database) as connection:
                        connection.execute("CREATE TABLE private_records (body TEXT)")
                        connection.execute("INSERT INTO private_records VALUES ('Preserve this')")
                        if kind == "future":
                            connection.execute(f"PRAGMA user_version={SCHEMA_VERSION + 1}")
                database.chmod(0o644)
                profile.chmod(0o755)
                before = database.read_bytes()
                failed = self.invoke(self.request("snapshot"), profile=profile)
                self.assertFalse(failed["ok"])
                self.assertEqual(failed["error"]["code"], "storage")
                self.assertEqual(database.read_bytes(), before)
                self.assertEqual(stat.S_IMODE(database.stat().st_mode), 0o644)
                self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o755)
                self.assertEqual(sorted(p.name for p in profile.iterdir()), ["daylog.sqlite3"])

    def make_v4(self):
        self.profile.mkdir()
        with self.database() as connection:
            for version in range(1, 5):
                for statement in MIGRATIONS[version]:
                    connection.execute(statement)
                connection.execute("INSERT INTO schema_migrations VALUES (?, '2024-01-01T00:00:00Z')", (version,))
            connection.executemany("""INSERT INTO activities
                (id,title,planned_for,status,note,created_at,completed_at,completed_date,revision,deleted_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)""", [
                    ("open", "SYNTHETIC v4 open", "2028-01-01", "open", "Original intention",
                     "2024-01-01T00:00:00Z", "", "", 2, ""),
                    ("deleted", "SYNTHETIC v4 deleted", "", "done", "Retained completed note",
                     "2024-01-01T00:00:00Z", "2024-01-02T12:00:00Z", "2024-01-02", 3, "2024-01-03T00:00:00Z"),
                ])
            connection.execute("""INSERT INTO sessions
                (id,activity_id,local_date,minutes,note,source,created_at)
                VALUES ('entry','open','2024-01-02',NULL,'Actual old entry','untimed','2024-01-02T12:00:00Z')""")
            connection.execute("INSERT INTO day_notes VALUES ('2024-01-02','Old reflection',1,'2024-01-02T12:00:00Z','')")
            connection.execute("INSERT INTO activity_events VALUES ('event','deleted','complete','2024-01-02T12:00:00Z',NULL,NULL)")
            connection.execute("INSERT INTO trash VALUES ('trash','activity','deleted','2024-01-03T00:00:00Z')")
            connection.execute("UPDATE metadata SET revision=7")
            connection.execute("PRAGMA user_version=4")

    def test_v4_pin_upgrade_backs_up_committed_wal_and_defaults_existing_records(self):
        self.make_v4()
        tables = ("activities", "sessions", "day_notes", "activity_events", "trash", "metadata", "request_receipts")
        with self.database() as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute("UPDATE activities SET note='Committed WAL note' WHERE id='open'")
            writer.commit()
            before = {table: writer.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall() for table in tables}
            snapshot = self.call("snapshot")["snapshot"]
            backups = list(self.profile.glob("daylog.before-v4-*.sqlite3"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
            with self.database(backups[0]) as backup:
                self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 4)
                self.assertNotIn("pinned", [row[1] for row in backup.execute("PRAGMA table_info(activities)")])
                self.assertEqual({table: backup.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall()
                                  for table in tables}, before)
        self.assertIs(snapshot["activities"][0]["pinned"], False)
        self.assertEqual(snapshot["revision"], 7)
        self.assertEqual(snapshot["events"], [])
        with self.database() as upgraded:
            self.assertEqual(upgraded.execute("PRAGMA user_version").fetchone()[0], 5)
            self.assertEqual(upgraded.execute("SELECT * FROM activities ORDER BY rowid").fetchall(),
                             [row + (0,) for row in before["activities"]])
            self.assertEqual({table: upgraded.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall()
                              for table in tables if table != "activities"},
                             {table: rows for table, rows in before.items() if table != "activities"})
        recovered_profile = Path(self.temporary.name) / "recovered-v4-backup"
        recovered_profile.mkdir()
        (recovered_profile / "daylog.sqlite3").write_bytes(backups[0].read_bytes())
        self.assertEqual(self.call("snapshot", profile=recovered_profile)["snapshot"], snapshot)
        restored = self.call("undo_delete", {"trashId": "trash"})["snapshot"]
        self.assertTrue(all(activity["pinned"] is False for activity in restored["activities"]))
        self.assertEqual(self.call("snapshot")["snapshot"], restored)
        self.assertEqual(list(self.profile.glob("daylog.before-v4-*.sqlite3")), backups)

    def test_failed_v5_pin_migration_keeps_v4_data_and_recoverable_backup(self):
        self.make_v4()
        before = (self.profile / "daylog.sqlite3").read_bytes()
        with patch.dict(MIGRATIONS, {5: MIGRATIONS[5] + ("invalid migration statement",)}):
            with self.assertRaises(StoreError):
                Store(self.profile)
        self.assertEqual((self.profile / "daylog.sqlite3").read_bytes(), before)
        backup_path, = self.profile.glob("daylog.before-v4-*.sqlite3")
        with self.database(backup_path) as backup:
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 4)
            self.assertNotIn("pinned", [row[1] for row in backup.execute("PRAGMA table_info(activities)")])
            self.assertEqual(backup.execute("SELECT note FROM activities WHERE id='open'").fetchone()[0], "Original intention")
        self.assertIs(self.call("snapshot")["snapshot"]["activities"][0]["pinned"], False)

    def make_v1(self, broken=False):
        self.profile.mkdir()
        with self.database() as connection:
            for statement in MIGRATIONS[1]:
                connection.execute(statement)
            connection.execute("INSERT INTO schema_migrations VALUES (1, '2024-01-01T00:00:00Z')")
            connection.execute("INSERT INTO day_notes VALUES ('2024-01-01', 'Keep this note', 4, '2024-01-01T00:00:00Z')")
            connection.execute("UPDATE metadata SET revision=4")
            connection.execute("PRAGMA user_version=1")
            if broken:
                connection.execute("CREATE TABLE request_receipts (unexpected TEXT)")

    def test_upgrade_creates_consistent_private_backup_before_migration(self):
        self.make_v1()
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(snapshot["dayNotes"]["2024-01-01"]["body"], "Keep this note")
        self.assertEqual(snapshot["dayNotes"]["2024-01-01"]["revision"], 4)
        backups = list(self.profile.glob("daylog.before-v1-*.sqlite3"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        with self.database(backups[0]) as backup:
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(backup.execute("SELECT body, revision FROM day_notes").fetchone(), ("Keep this note", 4))
            self.assertEqual(backup.execute("SELECT name FROM sqlite_master WHERE name='request_receipts'").fetchall(), [])
        with self.database() as connection:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION)
            self.assertEqual(connection.execute("SELECT version FROM schema_migrations ORDER BY version").fetchall(),
                             [(version,) for version in range(1, SCHEMA_VERSION + 1)])
        self.call("save_note", {"date": "2024-01-01", "body": "After upgrade", "expectedRevision": 4})
        self.assertEqual(list(self.profile.glob("daylog.before-v1-*.sqlite3")), backups)

    def test_failed_migration_rolls_back_and_keeps_old_records_and_backup(self):
        self.make_v1(broken=True)
        before = (self.profile / "daylog.sqlite3").read_bytes()
        failure = self.invoke(self.request("snapshot"))
        self.assertFalse(failure["ok"])
        self.assertEqual(failure["error"]["code"], "storage")
        self.assertEqual((self.profile / "daylog.sqlite3").read_bytes(), before)
        backups = list(self.profile.glob("daylog.before-v1-*.sqlite3"))
        self.assertEqual(len(backups), 1)
        with self.database(backups[0]) as backup:
            self.assertEqual(backup.execute("SELECT body FROM day_notes").fetchone()[0], "Keep this note")

    def test_readonly_old_schema_does_not_upgrade_or_create_backup(self):
        self.make_v1()
        before = (self.profile / "daylog.sqlite3").read_bytes()
        failure = self.invoke(self.request("snapshot"), read_only=True)
        self.assertEqual(failure["error"]["code"], "read_only")
        self.assertEqual((self.profile / "daylog.sqlite3").read_bytes(), before)
        self.assertEqual(list(self.profile.glob("daylog.before-*.sqlite3")), [])

    def test_snapshot_does_not_retrigger_profile_watchers(self):
        self.create()
        paths = (self.profile, self.profile / "daylog.sqlite3")
        before = [(path.stat().st_mtime_ns, path.stat().st_ctime_ns) for path in paths]
        self.call("snapshot")
        self.call("history")
        # IN_ATTRIB also wakes file watchers. A metadata-only read loop can
        # starve timer checkpoints just as effectively as a data-write loop.
        self.assertEqual([(path.stat().st_mtime_ns, path.stat().st_ctime_ns) for path in paths], before)

    def test_helper_runtime_never_changes_watched_plugin_code(self):
        installed = Path(self.temporary.name) / "installed/backend"
        shutil.copytree(HELPER.parent, installed, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        environment = dict(os.environ)
        environment.pop("PYTHONDONTWRITEBYTECODE", None)
        environment.pop("PYTHONPYCACHEPREFIX", None)

        def code_state():
            return {str(path.relative_to(installed)):
                    (path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest())
                    for path in installed.rglob("*") if path.is_file()}

        before = code_state()
        archive = Path(self.temporary.name) / "journal.json"
        # Export also exercises the lazily imported portability module.
        for request in (self.request("create_activity", {"title": "SYNTHETIC installed activity"}),
                        self.request("export_records", {"format": "json", "path": str(archive)})):
            process = subprocess.run(
                [sys.executable, str(installed / "helper.py"), "--profile", str(self.profile)],
                input=json.dumps(request), text=True, capture_output=True, timeout=10, env=environment)
            self.assertEqual(process.returncode, 0, process.stderr)
            response = json.loads(process.stdout)
            self.assertTrue(response["ok"], response)
        self.assertEqual(json.loads(archive.read_text())["tables"]["activities"][0]["title"],
                         "SYNTHETIC installed activity")
        # Omarchy reloads plugins on source-tree writes, even bytecode caches.
        self.assertEqual(code_state(), before)

    def test_owner_permissions_and_foreign_keys(self):
        self.call("snapshot")
        self.assertEqual(stat.S_IMODE(self.profile.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.profile / "daylog.sqlite3").stat().st_mode), 0o600)
        with Store(self.profile) as store:
            self.assertEqual(store.connection.execute("PRAGMA foreign_keys").fetchone()[0], 1)
            with self.assertRaises(sqlite3.IntegrityError):
                store.connection.execute("INSERT INTO sessions (id,activity_id,local_date,minutes,note,source,created_at) VALUES ('orphan','missing','2024-01-01',NULL,'','untimed','2024-01-01T00:00:00Z')")
        self.assertEqual(self.call("snapshot")["snapshot"]["sessions"], [])

    def test_xdg_defaults_explicit_profiles_and_source_symlink_rejection(self):
        xdg = Path(self.temporary.name) / "xdg"
        home = Path(self.temporary.name) / "home"
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(xdg), "HOME": str(home)}):
            self.assertEqual(profile_path(), xdg / "daylog")
            with Store() as store:
                result = store.handle(self.request("snapshot"))
                self.assertEqual(result["snapshot"]["activities"], [])
        self.assertTrue((xdg / "daylog/daylog.sqlite3").is_file())
        with patch.dict(os.environ, {"XDG_DATA_HOME": "relative-is-invalid", "HOME": str(home)}):
            self.assertEqual(profile_path(), home / ".local/share/daylog")
        with self.assertRaises(StoreError) as relative:
            profile_path("relative")
        self.assertEqual(relative.exception.code, "validation")
        for path in (SOURCE_ROOT, SOURCE_ROOT / "forbidden-test-profile"):
            with self.assertRaises(StoreError):
                profile_path(path)
        link = Path(self.temporary.name) / "source-link"
        link.symlink_to(SOURCE_ROOT, target_is_directory=True)
        with self.assertRaises(StoreError):
            profile_path(link / "profile")

    def test_database_symlink_is_not_followed(self):
        self.profile.mkdir()
        target = Path(self.temporary.name) / "unrelated.sqlite3"
        target.write_bytes(b"unrelated bytes")
        (self.profile / "daylog.sqlite3").symlink_to(target)
        failed = self.invoke(self.request("snapshot"))
        self.assertEqual(failed["error"]["code"], "storage")
        self.assertEqual(target.read_bytes(), b"unrelated bytes")


if __name__ == "__main__":
    unittest.main()
