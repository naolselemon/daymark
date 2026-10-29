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
        args = dict(activityId=activity["id"], date="2026-10-29", note="Compared examples")
        args.update(fields)
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

    def definitions(self, activity):
        return [{"id": task["id"], "title": task["title"]} for task in activity["tasks"]]

    def complete_task(self, activity, index, done=True):
        response = self.call("set_task_done", {"activityId": activity["id"],
            "taskId": activity["tasks"][index]["id"], "done": done, "expectedRevision": activity["revision"]})
        return next(row for row in response["snapshot"]["activities"] if row["id"] == activity["id"])

    def test_multiple_tasks_are_one_untimed_entry_with_independent_completion(self):
        activity = self.activity()
        ids = [task["id"] for task in activity["tasks"]]
        session = self.log(activity, ids)
        self.assertEqual(session["tasks"], self.definitions(activity))
        self.assertIsNone(session["minutes"])
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(len(snapshot["sessions"]), 1)
        self.assertEqual(snapshot["activities"][0]["status"], "open")
        self.assertFalse(any(task["done"] for task in snapshot["activities"][0]["tasks"]))
        self.assertEqual(self.store.connection.execute("SELECT COUNT(*) FROM sessions").fetchone()[0], 1)
        self.call("set_done", {"activityId": activity["id"], "done": True, "expectedRevision": activity["revision"]})
        again = self.log(activity, ids)
        self.assertEqual(again["tasks"], self.definitions(activity))
        self.assertEqual(self.call("snapshot")["snapshot"]["activities"][0]["status"], "done")

    def test_rename_reorder_archive_keep_snapshot_labels_and_search(self):
        activity = self.activity()
        first, second = self.definitions(activity)
        session = self.log(activity, [first["id"], second["id"]])
        changed = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 1,
                            "tasks": [dict(second, title="New borrow title"), dict(first, title="New owner title")]})["snapshot"]
        self.assertEqual([task["id"] for task in changed["activities"][0]["tasks"]], [second["id"], first["id"]])
        self.assertEqual(changed["sessions"][0]["tasks"], self.definitions(activity))
        archived = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": 2,
                             "tasks": [dict(second, title="New borrow title")]})["snapshot"]
        self.assertEqual(len(archived["activities"][0]["tasks"]), 1)
        self.assertEqual(archived["sessions"][0]["tasks"], self.definitions(activity))
        history = self.call("history", {"query": "ownership EXERCISES", "kind": "activities"})["result"]
        self.assertEqual([row["id"] for row in history["sessions"]], [session["id"]])
        self.assertEqual(history["sessions"][0]["tasks"], self.definitions(activity))
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
        self.assertEqual(selected["tasks"], list(reversed(self.definitions(activity))))
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
                      [self.definitions(activity)[0]] * 2, None):
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
                                      "tasks": [dict(self.definitions(activity)[1], title="Renamed definition")]})
        self.call("save_note", {"date": "2026-10-29", "body": "Private diary marker", "expectedRevision": 0})
        archive = self.export("activities.json")
        document = json.loads(archive.read_text())
        self.assertEqual(document["schemaVersion"], SCHEMA_VERSION)
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
                              "tasks": self.definitions(activity) + [{"title": "Later task"}]})["snapshot"]["activities"][0]
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
        self.assertEqual(response["snapshot"]["sessions"][0]["tasks"], self.definitions(activity))

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

    def test_final_task_completes_parent_and_reopen_preserves_historical_entry(self):
        activity = self.activity(plannedFor="2026-11-12")
        session = self.log(activity, [task["id"] for task in activity["tasks"]], date="2026-10-28")
        before = self.records()
        first = self.complete_task(activity, 0)
        self.assertEqual(first["status"], "open")
        self.assertEqual([task["done"] for task in first["tasks"]], [True, False])
        completed = self.complete_task(first, 1)
        self.assertEqual(completed["status"], "done")
        self.assertTrue(completed["completedAt"])
        self.assertEqual(completed["completedDate"], self.call("snapshot")["snapshot"]["today"])
        self.assertEqual(completed["plannedFor"], "2026-11-12")
        self.assertEqual(self.records()["sessions"], before["sessions"])
        self.assertEqual(self.records()["session_tasks"], before["session_tasks"])
        reopened = self.complete_task(completed, 0, False)
        self.assertEqual((reopened["status"], reopened["completedAt"], reopened["completedDate"]), ("open", "", ""))
        self.assertEqual([task["done"] for task in reopened["tasks"]], [False, True])
        self.assertEqual(self.call("snapshot")["snapshot"]["sessions"], [session])
        restarted = self.open_store("source")
        self.assertEqual(self.call("snapshot", store=restarted)["snapshot"]["activities"], [reopened])

    def test_manual_parent_completion_and_reopen_cascade_only_active_tasks(self):
        activity = self.complete_task(self.activity(), 0)
        first, second = self.definitions(activity)
        activity = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                             "tasks": [second]})["snapshot"]["activities"][0]
        done = self.call("set_done", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                                     "done": True})["snapshot"]["activities"][0]
        self.assertTrue(all(task["done"] for task in done["tasks"]))
        reopened = self.call("set_done", {"activityId": activity["id"], "expectedRevision": done["revision"],
                                         "done": False})["snapshot"]["activities"][0]
        self.assertFalse(reopened["tasks"][0]["done"])
        archived = next(task for task in self.records()["activity_tasks"] if task["id"] == first["id"])
        self.assertTrue(archived["done"])
        restored = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": reopened["revision"],
                             "tasks": [first, second]})["snapshot"]["activities"][0]
        self.assertEqual([task["done"] for task in restored["tasks"]], [True, False])
        self.assertEqual(restored["status"], "open")
        # Explicitly reopening an already-open parent resets partial progress too.
        cleared = self.call("set_done", {"activityId": activity["id"], "expectedRevision": restored["revision"],
                                        "done": False})["snapshot"]["activities"][0]
        self.assertFalse(any(task["done"] for task in cleared["tasks"]))
        self.assertGreater(cleared["revision"], restored["revision"])

    def test_task_add_remove_restore_and_empty_list_keep_parent_coherent(self):
        original = self.activity()
        activity = self.complete_task(original, 0)
        activity = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                             "tasks": self.definitions(activity)[:1]})["snapshot"]["activities"][0]
        self.assertEqual(activity["status"], "done")
        self.assertTrue(activity["tasks"][0]["done"])
        activity = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                             "tasks": self.definitions(original)})["snapshot"]["activities"][0]
        self.assertEqual(activity["status"], "open")
        self.assertEqual([task["done"] for task in activity["tasks"]], [True, False])
        activity = self.complete_task(activity, 1)
        activity = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                             "tasks": self.definitions(activity) + [{"title": "New outstanding work"}]})["snapshot"]["activities"][0]
        self.assertEqual(activity["status"], "open")
        self.assertFalse(activity["tasks"][-1]["done"])
        activity = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                             "tasks": []})["snapshot"]["activities"][0]
        self.assertEqual(activity["status"], "open")
        done = self.call("set_done", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                                     "done": True})["snapshot"]["activities"][0]
        self.assertEqual(done["status"], "done")
        self.assertEqual(done["tasks"], [])
        deleted = self.call("delete_record", {"kind": "activity", "id": done["id"], "expectedRevision": done["revision"]})
        restored = self.call("undo_delete", {"trashId": deleted["result"]["trashId"]})["snapshot"]["activities"][0]
        self.assertEqual((restored["status"], restored["completedAt"]), ("done", done["completedAt"]))
        self.assertEqual(self.records()["activity_tasks"][0]["done"], 1)

    def test_completion_revision_validation_replay_and_write_failure_are_atomic(self):
        activity = self.activity(("Only task",))
        args = {"activityId": activity["id"], "taskId": activity["tasks"][0]["id"],
                "done": True, "expectedRevision": activity["revision"]}
        before = self.records()
        with patch.object(self.store, "_event", side_effect=sqlite3.OperationalError("synthetic failure")):
            with self.assertRaises(StoreError):
                self.call("set_task_done", args, request_id="completion-retry")
        self.assertEqual(self.records(), before)
        saved = self.call("set_task_done", args, request_id="completion-retry")
        replay = self.call("set_task_done", args, request_id="completion-retry")
        self.assertEqual(saved, replay)
        before = self.records()
        for op, fields in (
            ("set_task_done", dict(args, done=False)),
            ("set_done", {"activityId": activity["id"], "done": False, "expectedRevision": activity["revision"]}),
            ("set_task_done", dict(args, done="true", expectedRevision=saved["result"]["revision"])),
        ):
            with self.subTest(op=op, fields=fields), self.assertRaises(StoreError):
                self.call(op, fields)
            self.assertEqual(self.records(), before)
        current = saved["snapshot"]["activities"][0]
        self.call("update_activity", {"activityId": current["id"], "expectedRevision": current["revision"], "tasks": []})
        before = self.records()
        current = self.call("snapshot")["snapshot"]["activities"][0]
        with self.assertRaises(StoreError):
            self.call("set_task_done", dict(args, expectedRevision=current["revision"]))
        self.assertEqual(self.records(), before)

    def test_completion_exports_roundtrip_and_old_archive_merge_keeps_local_state(self):
        activity = self.activity()
        self.log(activity, [activity["tasks"][0]["id"]])
        old = json.loads(self.export("before-completion.json").read_text())
        old["schemaVersion"] = 6
        for task in old["tables"]["activity_tasks"]:
            del task["done"]
        legacy = self.root / "schema6.json"
        legacy.write_text(json.dumps(old))
        activity = self.complete_task(activity, 0)
        archive = self.export("partial.json")
        document = json.loads(archive.read_text())
        self.assertEqual([task["done"] for task in document["tables"]["activity_tasks"]], [True, False])
        target = self.open_store("completion-target")
        self.restore(archive, target)
        before = self.records(target)
        self.restore(legacy, target)
        self.assertEqual(self.records(target), before)
        older = self.open_store("schema6-target")
        restored = self.restore(legacy, older)["snapshot"]
        self.assertFalse(any(task["done"] for task in restored["activities"][0]["tasks"]))
        self.assertEqual(restored["sessions"][0]["tasks"], self.definitions(activity)[:1])
        self.assertEqual(self.call("snapshot", store=target)["snapshot"]["activities"][0]["tasks"], activity["tasks"])
        # An old explicitly completed parent initializes active tasks, not history.
        self.call("set_done", {"activityId": activity["id"], "expectedRevision": activity["revision"], "done": True})
        completed = json.loads(self.export("completed.json").read_text())
        completed["schemaVersion"] = 6
        for task in completed["tables"]["activity_tasks"]:
            del task["done"]
        legacy_done = self.root / "schema6-done.json"
        legacy_done.write_text(json.dumps(completed))
        done_target = self.open_store("schema6-done-target")
        migrated = self.restore(legacy_done, done_target)["snapshot"]
        self.assertTrue(all(task["done"] for task in migrated["activities"][0]["tasks"]))
        self.assertEqual(migrated["sessions"], restored["sessions"])

    def test_incoherent_or_nonboolean_completion_archive_is_rejected_without_writes(self):
        self.activity(("Only",))
        original = json.loads(self.export("valid-completion.json").read_text())
        target = self.open_store("invalid-completion")
        for value in (True, 1, "true", None):
            document = copy.deepcopy(original)
            document["tables"]["activity_tasks"][0]["done"] = value
            path = self.root / "invalid-completion.json"
            path.write_text(json.dumps(document))
            before = self.records(target)
            with self.subTest(value=value), self.assertRaises(StoreError):
                self.restore(path, target)
            self.assertEqual(self.records(target), before)

    def test_v7_migration_keeps_logged_tasks_open_and_preserves_completed_parents(self):
        for done in (False, True):
            with self.subTest(done=done):
                profile = self.make_legacy_profile(6, f"schema6-migration-{done}")
                with closing(sqlite3.connect(profile / "daylog.sqlite3")) as connection, connection:
                    connection.execute("INSERT INTO activity_tasks VALUES ('task','legacy','Original title',0,'')")
                    connection.execute("INSERT INTO activity_tasks VALUES ('archived','legacy','Removed task',1,'2026-10-29T00:00:00Z')")
                    connection.execute("INSERT INTO session_tasks VALUES ('selection','entry','task','Historical title',0)")
                    if done:
                        connection.execute("UPDATE activities SET status='done',completed_at='2026-10-29T01:00:00Z',completed_date='2026-10-29'")
                    original_sessions = list(connection.execute("SELECT * FROM sessions"))
                    original_selections = list(connection.execute("SELECT * FROM session_tasks"))
                with Store(profile) as upgraded:
                    snapshot = self.call("snapshot", store=upgraded)["snapshot"]
                    self.assertIs(snapshot["activities"][0]["tasks"][0]["done"], done)
                    self.assertEqual(list(map(tuple, upgraded.connection.execute("SELECT * FROM sessions"))), original_sessions)
                    self.assertEqual(list(map(tuple, upgraded.connection.execute("SELECT * FROM session_tasks"))), original_selections)
                    self.assertEqual(upgraded.connection.execute("SELECT done FROM activity_tasks WHERE id='archived'").fetchone()[0], 0)
                backup, = profile.glob("daylog.before-v6-*.sqlite3")
                with closing(sqlite3.connect(backup)) as saved:
                    self.assertEqual(saved.execute("PRAGMA user_version").fetchone()[0], 6)
                    self.assertEqual(list(saved.execute("SELECT * FROM session_tasks")), original_selections)

    def test_failed_v7_migration_retains_original_schema_and_backup(self):
        profile = self.make_legacy_profile(6, "failed-v7")
        before = (profile / "daylog.sqlite3").read_bytes()
        with patch.dict(MIGRATIONS, {7: MIGRATIONS[7] + ("INVALID SQL",)}):
            with self.assertRaises(StoreError):
                Store(profile)
        self.assertEqual((profile / "daylog.sqlite3").read_bytes(), before)
        backup, = profile.glob("daylog.before-v6-*.sqlite3")
        with closing(sqlite3.connect(backup)) as saved:
            self.assertEqual(saved.execute("PRAGMA user_version").fetchone()[0], 6)

    def test_archived_completion_bits_survive_export_import_and_parent_reopen(self):
        activity = self.complete_task(self.activity(), 0)
        archived_id = activity["tasks"][0]["id"]
        activity = self.call("update_activity", {"activityId": activity["id"], "expectedRevision": activity["revision"],
                             "tasks": self.definitions(activity)[1:]})["snapshot"]["activities"][0]
        self.log(activity, done=True)
        target = self.open_store("archived-completion")
        restored = self.restore(self.export("archived-completion.json"), target)["snapshot"]["activities"][0]
        self.assertTrue(restored["tasks"][0]["done"])
        self.assertEqual(restored["status"], "done")
        self.call("set_done", {"activityId": restored["id"], "expectedRevision": restored["revision"], "done": False}, store=target)
        archived = next(task for task in self.records(target)["activity_tasks"] if task["id"] == archived_id)
        self.assertTrue(archived["done"])
        self.assertTrue(archived["archived_at"])
        self.assertFalse(self.call("snapshot", store=target)["snapshot"]["activities"][0]["tasks"][0]["done"])


if __name__ == "__main__":
    unittest.main()
