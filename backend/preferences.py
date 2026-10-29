"""Typed application preferences, isolated from journal records and archives."""
from contextlib import closing
import json
import os
import sqlite3
import stat

try:
    from .storage import StoreError, profile_path
except ImportError:
    from storage import StoreError, profile_path

OPERATIONS = {"preferences_get", "preferences_set"}
DEFAULTS = {"openingPage": "Timer", "lastPage": "Timer", "onlineQuotes": True,
            "diaryIdleMinutes": 0, "automaticUpdates": False}
PAGES = ("Timer", "Today", "Plan", "History", "Diary", "Quotes")


def validate_changes(changes):
    if type(changes) is not dict:
        raise StoreError("validation", "Preference changes must be an object.")
    for key, value in changes.items():
        if key not in DEFAULTS:
            raise StoreError("validation", "Unknown preference.")
        if key in ("onlineQuotes", "automaticUpdates"):
            valid = type(value) is bool
        elif key == "diaryIdleMinutes":
            valid = type(value) is int and value in (0, 1, 5, 15)
        elif key == "openingPage":
            valid = type(value) is str and value in ("Timer", "Today", "last")
        else:
            valid = type(value) is str and value in PAGES
        if not valid:
            raise StoreError("validation", f"Invalid value for {key}.")
    return changes


class PreferencesStore:
    def __init__(self, profile=None, read_only=False):
        self.path = profile_path(profile) / "settings.sqlite3"
        self.read_only = read_only

    def _check_paths(self):
        for suffix in ("", "-journal", "-wal", "-shm"):
            if self.path.with_name(self.path.name + suffix).is_symlink():
                raise StoreError("storage", "A settings database symlink is not a supported profile.")
        if self.path.exists() and not self.path.is_file():
            raise StoreError("storage", "Settings must be stored in a regular database file.")

    def _read(self, db):
        if db.execute("PRAGMA user_version").fetchone()[0] != 1:
            raise StoreError("storage", "Settings use an unrecognized schema. They were not changed.")
        if db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise StoreError("storage", "Settings are damaged. They were not replaced or repaired.")
        values = {}
        try:
            for key, encoded in db.execute("SELECT key,value FROM preferences"):
                if key in values:
                    raise ValueError("duplicate preference")
                values[key] = json.loads(encoded)
            validate_changes(values)
        except (ValueError, TypeError, StoreError):
            raise StoreError("storage", "Settings contain invalid values. They were not changed.") from None
        return dict(DEFAULTS, **values)

    def _secure(self):
        # Avoid redundant chmod notifications, and never alter a read-only profile.
        for path, mode in ((self.path.parent, 0o700), (self.path, 0o600)):
            if stat.S_IMODE(path.stat().st_mode) != mode:
                path.chmod(mode)

    def handle(self, request):
        op, args = request["op"], request["args"]
        if op not in OPERATIONS:
            raise StoreError("protocol", "Unknown preferences operation.")
        if type(args) is not dict or set(args) != ({"changes"} if op == "preferences_set" else set()):
            raise StoreError("validation", "Invalid preferences arguments.")
        changes = validate_changes(args["changes"]) if op == "preferences_set" else None
        if changes is not None and self.read_only:
            raise StoreError("read_only", "Settings are read-only. Your changes were not saved.")
        self._check_paths()
        if changes is None and not self.path.exists():
            return dict(DEFAULTS)

        created = False
        if changes is not None:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            except FileExistsError:
                self._check_paths()
            else:
                os.close(fd)
                created = True
        mode = "rw" if changes is not None else "ro"
        with closing(sqlite3.connect(self.path.as_uri() + "?mode=" + mode, uri=True, timeout=5)) as db:
            if changes is not None:
                db.execute("PRAGMA synchronous=FULL")
            db.execute("BEGIN IMMEDIATE" if changes is not None else "BEGIN")
            try:
                if created:
                    db.execute("CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                    db.execute("PRAGMA user_version=1")
                values = self._read(db)
                if not self.read_only:
                    self._secure()
                if changes is not None:
                    for key, value in changes.items():
                        db.execute("INSERT INTO preferences VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                                   (key, json.dumps(value, allow_nan=False, separators=(",", ":"))))
                    values.update(changes)
                db.commit()
            except Exception:
                db.rollback()
                raise
        return values
