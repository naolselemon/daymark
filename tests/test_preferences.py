"""Preferences use synthetic external profiles, never installed plugin data."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from backend.preferences import DEFAULTS, PreferencesStore
from backend.storage import SOURCE_ROOT, Store, StoreError


class PreferencesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="daymark-preferences-")
        self.addCleanup(temporary.cleanup)
        self.profile = Path(temporary.name) / "profile"
        self.store = PreferencesStore(self.profile)
        self.sequence = 0

    def request(self, op="get", **args):
        self.sequence += 1
        return {"protocol": 1, "requestId": f"preferences-{self.sequence}",
                "op": "preferences_" + op, "args": args}

    def call(self, op="get", **args):
        return self.store.handle(self.request(op, **args))

    def helper(self, request, read_only=False):
        command = [sys.executable, str(SOURCE_ROOT / "backend/helper.py"), "--profile", str(self.profile)]
        if read_only:
            command.append("--read-only")
        process = subprocess.run(command, input=json.dumps(request), text=True, capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "")
        response = json.loads(process.stdout)
        self.assertEqual(response["requestId"], request["requestId"])
        return response

    def test_missing_profile_defaults_do_not_write_including_read_only(self):
        self.assertEqual(self.call(), DEFAULTS)
        read_only = PreferencesStore(self.profile, read_only=True)
        self.assertEqual(read_only.handle(self.request()), DEFAULTS)
        self.assertFalse(self.profile.exists())
        with self.assertRaises(StoreError) as error:
            read_only.handle(self.request("set", changes={"openingPage": "Today"}))
        self.assertEqual(error.exception.code, "read_only")
        self.assertFalse(self.profile.exists())

    def test_typed_values_persist_across_instances_and_remain_separate(self):
        changes = {"openingPage": "last", "lastPage": "Diary", "onlineQuotes": False,
                   "diaryIdleMinutes": 15, "automaticUpdates": True}
        self.assertEqual(self.call("set", changes=changes), changes)
        self.assertEqual(PreferencesStore(self.profile).handle(self.request()), changes)
        self.assertFalse((self.profile / "daylog.sqlite3").exists())
        self.assertFalse((self.profile / "countdown.sqlite3").exists())
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.profile.stat().st_mode & 0o777, 0o700)

    def test_assignments_are_idempotent_and_preserve_unrelated_preferences(self):
        self.call("set", changes={"automaticUpdates": True, "diaryIdleMinutes": 5})
        request = self.request("set", changes={"openingPage": "Today"})
        first = self.store.handle(request)
        self.assertEqual(self.store.handle(request), first)
        self.call("set", changes={"lastPage": "Quotes"})
        result = self.call()
        self.assertEqual(result, dict(DEFAULTS, automaticUpdates=True, diaryIdleMinutes=5,
                                      openingPage="Today", lastPage="Quotes"))

    def test_all_choices_and_strict_validation(self):
        valid = {"openingPage": ("Timer", "Today", "last"),
                 "lastPage": ("Timer", "Today", "Plan", "History", "Diary", "Quotes"),
                 "onlineQuotes": (True, False), "automaticUpdates": (False, True),
                 "diaryIdleMinutes": (0, 1, 5, 15)}
        for key, values in valid.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    result = self.call("set", changes={key: value})
                    self.assertEqual(result[key], value)
                    self.assertIs(type(result[key]), type(value))
        invalid = {"openingPage": ("Diary", "timer", "Last", 0, None, []),
                   "lastPage": ("last", "Settings", "", False, {}),
                   "onlineQuotes": (0, 1, "false", None),
                   "automaticUpdates": (0, 1, "true", []),
                   "diaryIdleMinutes": (True, False, 1.0, 2, -1, "5", None),
                   "muted": (True,)}
        before = self.call()
        for key, values in invalid.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(StoreError) as error:
                    self.call("set", changes={"openingPage": "Today", key: value})
                self.assertEqual(error.exception.code, "validation")
                self.assertEqual(self.call(), before)
        for changes in (None, [], "onlineQuotes", True):
            with self.assertRaises(StoreError):
                self.call("set", changes=changes)
        for op, args in (("get", {"unexpected": 1}), ("set", {}),
                         ("set", {"changes": {}, "unexpected": 1})):
            with self.assertRaises(StoreError):
                self.call(op, **args)

    def test_concurrent_partial_changes_do_not_lose_other_keys(self):
        self.call("set", changes={})
        requests = [self.request("set", changes={"openingPage": "Today"}),
                    self.request("set", changes={"lastPage": "Plan"}),
                    self.request("set", changes={"automaticUpdates": True})]
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(lambda request: PreferencesStore(self.profile).handle(request), requests))
        self.assertEqual(self.call(), dict(DEFAULTS, openingPage="Today", lastPage="Plan", automaticUpdates=True))

    def test_failed_multi_key_save_rolls_back_every_change_and_can_retry(self):
        before = self.call("set", changes={"openingPage": "Timer", "onlineQuotes": True})
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("CREATE TRIGGER reject_write BEFORE UPDATE ON preferences WHEN NEW.key='onlineQuotes' "
                       "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        request = self.request("set", changes={"openingPage": "Today", "onlineQuotes": False})
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.handle(request)
        self.assertEqual(self.call(), before)
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("DROP TRIGGER reject_write")
        self.assertEqual(self.store.handle(request), dict(before, openingPage="Today", onlineQuotes=False))

    def test_read_only_never_changes_data_or_permissions(self):
        expected = self.call("set", changes={"diaryIdleMinutes": 1})
        self.store.path.chmod(0o644)
        before = self.store.path.read_bytes()
        reader = PreferencesStore(self.profile, read_only=True)
        self.assertEqual(reader.handle(self.request()), expected)
        with self.assertRaises(StoreError) as error:
            reader.handle(self.request("set", changes={"diaryIdleMinutes": 0}))
        self.assertEqual(error.exception.code, "read_only")
        self.assertEqual(self.store.path.read_bytes(), before)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.call(), expected)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_symlinks_including_sidecars_never_modify_targets(self):
        self.profile.mkdir()
        target = self.profile.parent / "unrelated"
        target.write_bytes(b"synthetic unrelated data")
        for suffix in ("", "-journal", "-wal", "-shm"):
            link = self.store.path.with_name(self.store.path.name + suffix)
            link.symlink_to(target)
            try:
                for op, args in (("get", {}), ("set", {"changes": {"openingPage": "Today"}})):
                    with self.subTest(suffix=suffix, op=op), self.assertRaises(StoreError):
                        self.call(op, **args)
                    self.assertEqual(target.read_bytes(), b"synthetic unrelated data")
            finally:
                link.unlink()

    def test_corrupt_unknown_and_future_settings_are_not_replaced(self):
        self.profile.mkdir()
        for content in (b"synthetic corrupt sqlite", b""):
            self.store.path.write_bytes(content)
            for op, args in (("get", {}), ("set", {"changes": {"onlineQuotes": False}})):
                with self.assertRaises((StoreError, sqlite3.Error)):
                    self.call(op, **args)
                self.assertEqual(self.store.path.read_bytes(), content)
        self.store.path.unlink()
        self.call("set", changes={"openingPage": "Today"})
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("PRAGMA user_version=999")
        before = self.store.path.read_bytes()
        with self.assertRaises(StoreError):
            self.call("set", changes={"openingPage": "Timer"})
        self.assertEqual(self.store.path.read_bytes(), before)

    def test_invalid_persisted_type_is_not_silently_defaulted(self):
        self.call("set", changes={"automaticUpdates": False})
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("UPDATE preferences SET value='1' WHERE key='automaticUpdates'")
        before = self.store.path.read_bytes()
        for op, args in (("get", {}), ("set", {"changes": {"openingPage": "Today"}})):
            with self.assertRaises(StoreError) as error:
                self.call(op, **args)
            self.assertEqual(error.exception.code, "storage")
            self.assertEqual(self.store.path.read_bytes(), before)

    def test_helper_envelope_errors_and_archives_stay_isolated(self):
        initial = self.helper(self.request())
        self.assertTrue(initial["ok"], initial)
        changed = self.helper(self.request("set", changes={"openingPage": "Today", "automaticUpdates": True}))
        self.assertTrue(changed["ok"], changed)
        self.assertEqual(changed["snapshot"], initial["snapshot"])
        self.assertEqual(changed["result"]["openingPage"], "Today")
        failed = self.helper(self.request("set", changes={"automaticUpdates": False}), read_only=True)
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["error"]["code"], "read_only")
        self.assertTrue(self.call()["automaticUpdates"])
        with Store(self.profile) as journal:
            for scope in ("activities", "diary"):
                path = self.profile.parent / (scope + ".json")
                journal.handle({"protocol": 1, "requestId": "export-" + scope, "op": "export_records",
                                "args": {"format": "json", "scope": scope, "path": str(path)}})
                content = path.read_text()
                self.assertNotIn("openingPage", content)
                self.assertNotIn("automaticUpdates", content)
                self.assertNotIn("settings.sqlite3", content)
        self.store.path.write_bytes(b"synthetic damaged preferences")
        failed = self.helper(self.request())
        self.assertFalse(failed["ok"])
        snapshot = self.helper({"protocol": 1, "requestId": "unaffected-journal", "op": "snapshot", "args": {}})
        self.assertTrue(snapshot["ok"], snapshot)
        self.assertEqual(snapshot["snapshot"], initial["snapshot"])


if __name__ == "__main__":
    unittest.main()
