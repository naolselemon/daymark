"""Reusable tasks and historical selections, using isolated synthetic profiles."""

from contextlib import closing
import copy
import json
from pathlib import Path
import sqlite3
import stat
import tempfile
import unittest
from unittest.mock import patch

from backend.portability import COLUMNS
from backend.storage import MIGRATIONS, SCHEMA_VERSION, Store, StoreError


class TaskTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daymark-tasks-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sequence = 0
        self.store = self.open_store("source")

    def open_store(self, name):
        store = Store(self.root / name)
        self.addCleanup(store.close)
        return store

    def call(self, op, args=None, *, store=None, request_id=None):
        self.sequence += 1
        return (store or self.store).handle({"protocol": 1, "requestId": request_id or f"tasks-{self.sequence}",
                                           "op": op, "args": args or {}})

    def activity(self, titles=("Ownership exercises", "Borrowing examples"), **fields):
        result = self.call("create_activity", dict(title="Synthetic Rust", note="Keep intention", pinned=True,
                                                    tasks=[{"title": title} for title in titles], **fields))
        return next(row for row in result["snapshot"]["activities"] if row["id"] == result["result"]["activityId"])

    def log(self, activity, ids=None, **fields):
        args = dict(activityId=activity["id"], date="2026-10-29", note="Compared examples", **fields)
        if ids is not None:
            args["taskIds"] = ids
        response = self.call("add_session", args)
        return next(row for row in response["snapshot"]["sessions"] if row["id"] == response["result"]["sessionId"])

    def records(self, store=None):
        connection = (store or self.store).connection
        return {table: [dict(row) for row in connection.execute(f"SELECT * FROM {table} ORDER BY rowid")]
                for table in COLUMNS}

    def export(self, name, *, scope="activities", kind="json", store=None):
        path = self.root / name
        self.call("export_records", {"path": str(path), "scope": scope, "format": kind}, store=store)
        return path

    def restore(self, path, store, request_id=None):
        revision = self.call("snapshot", store=store)["snapshot"]["revision"]
        return self.call("restore_records", {"path": str(path), "expectedRevision": revision},
                         store=store, request_id=request_id)

    def test_multiple_tasks_are_one_untimed_entry_with_independent_completion(self):
        activity = self.activity()
        ids = [task["id"] for task in activity["tasks"]]
        session = self.log(activity, ids)
        self.assertEqual(session["tasks"], activity["tasks"])
        self.assertIsNone(session["minutes"])
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(len(snapshot["sessions"]), 1)
        self.assertEqual(snapshot["activities"][0]["status"], "open")
        self.assertEqual(self.store.connection.execute("SELECT COUNT(*) FROM sessions").fetchone()[0], 1)
        self.call("set_done", {"activityId": activity["id"], "done": True})
        again = self.log(activity, ids)
        self.assertEqual(again["tasks"], activity["tasks"])
        self.assertEqual(self.call("snapshot")["snapshot"]["activities"][0]["status"], "done")

    def test_rename_reorder_archive_keep_snapshot_labels_and_search(self):
        activity = self.activity()
        first, second = activity["tasks"]
        session = self.log(activity, [first["id"], second["id"]])
        changed = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                            "tasks": [dict(second, title="New borrow title"), dict(first, title="New owner title")]})["snapshot"]
        self.assertEqual([task["id"] for task in changed["activities"][0]["tasks"]], [second["id"], first["id"]])
        self.assertEqual(changed["sessions"][0]["tasks"], activity["tasks"])
        archived = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 2,
                             "tasks": [dict(second, title="New borrow title")]})["snapshot"]
        self.assertEqual(len(archived["activities"][0]["tasks"]), 1)
        self.assertEqual(archived["sessions"][0]["tasks"], activity["tasks"])
        history = self.call("history", {"query": "ownership EXERCISES", "kind": "activities"})["result"]
        self.assertEqual([row["id"] for row in history["sessions"]], [session["id"]])
        self.assertEqual(history["sessions"][0]["tasks"], activity["tasks"])
        newer = self.log(activity, [second["id"]])
        self.assertEqual(newer["tasks"], [dict(second, title="New borrow title")])
        self.assertTrue(self.store.connection.execute("SELECT archived_at FROM activity_tasks WHERE id=?", (first["id"],)).fetchone()[0])

    def test_omitted_definitions_and_failed_entry_edits_preserve_existing_state(self):
        activity, other = self.activity(), self.activity(("Other task",))
        session = self.log(activity, [activity["tasks"][0]["id"]])
        saved = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                                             "plannedFor": "2026-11-01"})["snapshot"]
        current = next(row for row in saved["activities"] if row["id"] == activity["id"])
        self.assertEqual(current["tasks"], activity["tasks"])
        before = self.records()
        with self.assertRaises(StoreError):
            self.call("update_session", {"sessionId": session["id"], "expectedRevision": 1,
                                        "note": "Must not replace", "date": "2026-10-30",
                                        "taskIds": [other["tasks"][0]["id"]]})
        self.assertEqual(self.records(), before)
        args = {"activityId": activity["id"], "date": "2026-10-29",
                "taskIds": [task["id"] for task in activity["tasks"]]}
        first = self.call("add_session", args, request_id="same-task-entry")
        replay = self.call("add_session", args, request_id="same-task-entry")
        self.assertEqual(first, replay)
        self.assertEqual(len(replay["snapshot"]["sessions"]), 2)

    def test_edit_preserves_untouched_fields_and_archived_selections(self):
        activity = self.activity()
        ids = [task["id"] for task in activity["tasks"]]
        session = self.log(activity, ids, minutes=12)
        self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1, "tasks": []})
        changed = self.call("update_session", {"sessionId": session["id"], "expectedRevision": 1, "note": "Edited"})["snapshot"]["sessions"][0]
        self.assertEqual(changed, dict(session, revision=2, note="Edited"))
        selected = self.call("update_session", {"sessionId": session["id"], "expectedRevision": 2,
                                               "taskIds": list(reversed(ids))})["snapshot"]["sessions"][0]
        self.assertEqual(selected["tasks"], list(reversed(activity["tasks"])))
        self.assertEqual((selected["note"], selected["minutes"]), ("Edited", 12))
        self.call("update_session", {"sessionId": session["id"], "expectedRevision": 3, "taskIds": [ids[0]]})
        with self.assertRaises(StoreError):
            self.call("update_session", {"sessionId": session["id"], "expectedRevision": 4, "taskIds": ids})
        with self.assertRaises(StoreError):
            self.log(activity, ids)
        saved = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 2,
                                              "title": "Changed only title"})["snapshot"]["activities"][0]
        self.assertEqual((saved["tasks"], saved["note"], saved["pinned"]), ([], "Keep intention", True))

    def test_membership_validation_and_invalid_definitions_roll_back_every_write(self):
        activity, other = self.activity(), self.activity(("Unrelated",))
        before = self.records()
        wrong = other["tasks"][0]["id"]
        invalid = ([wrong], [activity["tasks"][0]["id"]] * 2, ["missing"], "not a list", [None])
        for ids in invalid:
            with self.subTest(ids=ids), self.assertRaises(StoreError):
                self.log(activity, ids, done=True)
            self.assertEqual(self.records(), before)
        for tasks in ([{"id": wrong, "title": "Stolen"}], [{"title": "Valid"}, {"title": "  "}],
                      [activity["tasks"][0]] * 2, None):
            with self.subTest(tasks=tasks), self.assertRaises(StoreError):
                self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                                              "title": "Must roll back", "category": "New label", "tasks": tasks})
            self.assertEqual(self.records(), before)
        with self.assertRaises(StoreError):
            self.call("create_activity", {"title": "Invalid creation", "tasks": [{"title": ""}], "category": "No leak"})
        self.assertEqual(self.records(), before)
        self.assertEqual(self.store.countdown_target(activity["id"], activity["tasks"][0]["id"]),
                         {"activityTitle": activity["title"], "taskTitle": activity["tasks"][0]["title"]})
        with self.assertRaises(StoreError):
            self.store.countdown_target(activity["id"], wrong)

    def test_delete_undo_and_purge_preserve_or_remove_children_together(self):
        activity = self.activity()
        session = self.log(activity, [task["id"] for task in activity["tasks"]])
        deleted = self.call("delete_record", {"kind": "activity", "id": activity["id"], "expectedRevision": 1})
        self.assertEqual(deleted["snapshot"]["sessions"], [])
        restored = self.call("undo_delete", {"trashId": deleted["result"]["trashId"]})["snapshot"]
        self.assertEqual(restored["sessions"][0]["tasks"], session["tasks"])
        deleted_session = self.call("delete_record", {"kind": "session", "id": session["id"], "expectedRevision": 1})
        self.call("purge_deleted", {"trashId": deleted_session["result"]["trashId"], "confirmed": True})
        self.assertEqual(self.records()["session_tasks"], [])
        self.assertEqual(len(self.records()["activity_tasks"]), 2)
        self.log(activity, [activity["tasks"][0]["id"]])
        deleted = self.call("delete_record", {"kind": "activity", "id": activity["id"], "expectedRevision": 3})
        self.call("purge_deleted", {"trashId": deleted["result"]["trashId"], "confirmed": True})
        self.assertEqual(self.records()["session_tasks"], [])
        self.assertEqual(self.records()["activity_tasks"], [])
        self.assertEqual(self.records()["sessions"], [])

    def test_scopes_markdown_and_repeat_restore_preserve_archived_history(self):
        activity = self.activity()
        self.log(activity, [task["id"] for task in activity["tasks"]])
        self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                                      "tasks": [dict(activity["tasks"][1], title="Renamed definition")]})
        self.call("save_note", {"date": "2026-10-29", "body": "Private diary marker", "expectedRevision": 0})
        archive = self.export("activities.json")
        document = json.loads(archive.read_text())
        self.assertEqual(document["schemaVersion"], 6)
        self.assertEqual(len(document["tables"]["activity_tasks"]), 2)
        self.assertEqual(len(document["tables"]["session_tasks"]), 2)
        self.assertNotIn("Private diary marker", archive.read_text())
        diary = json.loads(self.export("diary.json", scope="diary").read_text())
        self.assertEqual(diary["tables"]["activity_tasks"], [])
        self.assertEqual(diary["tables"]["session_tasks"], [])
        markdown = self.export("activities.md", kind="markdown").read_text()
        for expected in ("Renamed definition", "Ownership exercises (archived)", "Task: Borrowing examples"):
            self.assertIn(expected, markdown)
        self.assertNotIn("Private diary marker", markdown)
        target = self.open_store("restored")
        result = self.restore(archive, target)
        self.assertEqual(result["result"]["conflicts"], [])
        self.assertEqual(self.records(target), document["tables"])
        repeated = self.restore(archive, target)["result"]
        self.assertEqual(repeated["counts"], dict.fromkeys(COLUMNS, 0))
        self.assertEqual(repeated["duplicates"], {table: len(rows) for table, rows in document["tables"].items()})
        self.assertEqual(repeated["conflicts"], [])

    def test_conflicting_selection_group_never_rewrites_existing_entry(self):
        activity = self.activity()
        self.log(activity, [activity["tasks"][0]["id"]])
        archive = self.export("original.json")
        target = self.open_store("selection-conflict")
        self.restore(archive, target)
        before = self.records(target)
        changed = json.loads(archive.read_text())
        changed["tables"]["session_tasks"][0]["title"] = "Conflicting historical label"
        path = self.root / "conflicting.json"
        path.write_text(json.dumps(changed))
        result = self.restore(path, target)["result"]
        self.assertTrue(any(row["table"] == "sessions" for row in result["conflicts"]))
        self.assertEqual(self.records(target), before)

    def test_missing_task_dependency_skips_new_entry_without_changing_existing_activity(self):
        activity = self.activity(("Original task",))
        original = self.export("before-new-task.json")
        target = self.open_store("dependency-target")
        self.restore(original, target)
        before = self.records(target)
        updated = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                              "tasks": activity["tasks"] + [{"title": "Later task"}]})["snapshot"]["activities"][0]
        self.log(updated, [updated["tasks"][1]["id"]])
        result = self.restore(self.export("after-new-task.json"), target)["result"]
        self.assertEqual(result["counts"]["sessions"], 0)
        self.assertEqual(result["counts"]["session_tasks"], 0)
        self.assertTrue({"activities", "activity_tasks", "sessions"}.issubset({row["table"] for row in result["conflicts"]}))
        self.assertEqual(self.records(target), before)

    def test_new_history_can_reference_renamed_or_archived_destination_task(self):
        activity = self.activity(("Original label",))
        target = self.open_store("renamed-target")
        self.restore(self.export("definition.json"), target)
        self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1, "tasks": []}, store=target)
        self.log(activity, [activity["tasks"][0]["id"]])
        response = self.restore(self.export("later-entry.json"), target)
        self.assertEqual(response["result"]["counts"]["sessions"], 1)
        self.assertEqual(response["snapshot"]["activities"][0]["tasks"], [])
        self.assertEqual(response["snapshot"]["sessions"][0]["tasks"], activity["tasks"])

    def test_archive_wrong_activity_selection_is_rejected_atomically(self):
        activity, other = self.activity(), self.activity(("Other",))
        self.log(activity, [activity["tasks"][0]["id"]])
        document = json.loads(self.export("valid.json").read_text())
        document["tables"]["session_tasks"][0]["task_id"] = other["tasks"][0]["id"]
        path = self.root / "invalid.json"
        path.write_text(json.dumps(document))
        before = self.records()
        with self.assertRaises(StoreError):
            self.restore(path, self.store)
        self.assertEqual(self.records(), before)

    def test_schema_four_and_five_archives_restore_without_erasing_tasks(self):
        activity = self.activity(())
        self.log(activity)
        original = json.loads(self.export("modern.json").read_text())
        for version in (4, 5):
            with self.subTest(version=version):
                document = copy.deepcopy(original)
                document["schemaVersion"] = version
                del document["tables"]["activity_tasks"]
                del document["tables"]["session_tasks"]
                if version == 4:
                    for row in document["tables"]["activities"]:
                        del row["pinned"]
                path = self.root / f"legacy-{version}.json"
                path.write_text(json.dumps(document))
                target = self.open_store(f"legacy-target-{version}")
                restored = self.restore(path, target)["snapshot"]
                self.assertEqual(restored["activities"][0]["tasks"], [])
                self.assertEqual(restored["sessions"][0]["tasks"], [])
                self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                                              "tasks": [{"title": "Local task"}]}, store=target)
                before = self.records(target)
                self.restore(path, target)
                self.assertEqual(self.records(target), before)

    def test_task_identity_collision_cannot_attach_selection_to_wrong_parent(self):
        activity = self.activity(("Selected task",))
        self.log(activity, [activity["tasks"][0]["id"]])
        path = self.export("identity-source.json")
        target = self.open_store("identity-target")
        self.restore(path, target)
        document = json.loads(path.read_text())
        # A coherent foreign archive reuses the task identity under a different
        # activity. The destination identity must win without orphaning entries.
        document["tables"]["activities"][0]["id"] = "foreign-activity"
        document["tables"]["activity_tasks"][0]["activity_id"] = "foreign-activity"
        document["tables"]["sessions"][0].update(id="foreign-session", activity_id="foreign-activity")
        document["tables"]["session_tasks"][0].update(id="foreign-selection", session_id="foreign-session")
        foreign = self.root / "identity-foreign.json"
        foreign.write_text(json.dumps(document))
        response = self.restore(foreign, target)
        self.assertEqual(response["result"]["counts"]["sessions"], 0)
        self.assertEqual(response["result"]["counts"]["session_tasks"], 0)
        self.assertEqual(len(response["snapshot"]["sessions"]), 1)
        self.assertEqual(response["snapshot"]["sessions"][0]["activityId"], activity["id"])
        self.assertTrue(any(row["table"] == "sessions" for row in response["result"]["conflicts"]))

    def make_legacy_profile(self, version, name):
        profile = self.root / name
        profile.mkdir()
        with closing(sqlite3.connect(profile / "daylog.sqlite3")) as connection, connection:
            for migration in range(1, version + 1):
                for statement in MIGRATIONS[migration]:
                    connection.execute(statement)
                connection.execute("INSERT INTO schema_migrations VALUES (?,?)", (migration, "2026-10-29T00:00:00Z"))
            connection.execute("""INSERT INTO activities
                (id,title,status,note,created_at,revision) VALUES ('legacy','Legacy','open','Intention','2026-10-29T00:00:00Z',1)""")
            connection.execute("""INSERT INTO sessions
                (id,activity_id,local_date,note,source,created_at) VALUES
                ('entry','legacy','2026-10-29','Old untimed note','untimed','2026-10-29T00:00:00Z')""")
            connection.execute(f"PRAGMA user_version={version}")
        return profile

    def test_v6_migration_backs_up_legacy_profiles_and_preserves_records(self):
        for version in (4, 5):
            with self.subTest(version=version):
                profile = self.make_legacy_profile(version, f"migration-{version}")
                with Store(profile) as upgraded:
                    snapshot = self.call("snapshot", store=upgraded)["snapshot"]
                    self.assertEqual(snapshot["activities"][0]["tasks"], [])
                    self.assertEqual(snapshot["sessions"][0]["tasks"], [])
                    self.assertEqual(snapshot["sessions"][0]["note"], "Old untimed note")
                    self.assertEqual(upgraded.connection.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION)
                backup, = profile.glob(f"daylog.before-v{version}-*.sqlite3")
                self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
                with closing(sqlite3.connect(backup)) as saved:
                    self.assertEqual(saved.execute("PRAGMA user_version").fetchone()[0], version)
                    self.assertIsNone(saved.execute("SELECT name FROM sqlite_master WHERE name='activity_tasks'").fetchone())
                    self.assertEqual(saved.execute("SELECT note FROM sessions").fetchone()[0], "Old untimed note")

    def test_failed_v6_migration_keeps_original_database_and_backup(self):
        profile = self.make_legacy_profile(5, "failed-migration")
        before = (profile / "daylog.sqlite3").read_bytes()
        with patch.dict(MIGRATIONS, {6: MIGRATIONS[6] + ("INVALID SQL",)}):
            with self.assertRaises(StoreError):
                Store(profile)
        self.assertEqual((profile / "daylog.sqlite3").read_bytes(), before)
        backup, = profile.glob("daylog.before-v5-*.sqlite3")
        with closing(sqlite3.connect(backup)) as saved:
            self.assertEqual(saved.execute("PRAGMA user_version").fetchone()[0], 5)
            self.assertEqual(saved.execute("SELECT note FROM sessions").fetchone()[0], "Old untimed note")


if __name__ == "__main__":
    unittest.main()
