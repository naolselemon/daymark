"""Canonical local records for the short-lived Daymark helper (stdlib only)."""

from contextlib import closing
from datetime import date, datetime, timezone
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import unicodedata
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


SCHEMA_VERSION = 7
SOURCE_ROOT = Path(__file__).resolve().parents[1]
TIMER_MUTATIONS = {"timer_start", "timer_resume", "timer_pause", "timer_stop",
                   "timer_switch", "timer_checkpoint", "timer_recover"}
MUTATIONS = {"create_activity", "add_session", "update_activity", "set_done", "set_task_done", "save_note",
             "update_session", "delete_record", "undo_delete", "purge_deleted", "update_label",
             "restore_records", "settle_legacy_timers"} | TIMER_MUTATIONS
COUNTDOWN_OPERATIONS = {"countdown_status", "countdown_start", "countdown_pause",
                        "countdown_resume", "countdown_reset", "countdown_mute", "countdown_log"}
OPERATIONS = (MUTATIONS | {"snapshot", "history", "review", "export_records"}
              | COUNTDOWN_OPERATIONS | {"preferences_get", "preferences_set"})

# Version 1 is the record model; version 2 adds transactional replay receipts.
MIGRATIONS = {
    1: (
        "CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL)",
        "INSERT INTO metadata VALUES (1, 0)",
        "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)",
        "CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE)",
        "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE)",
        """CREATE TABLE activities (
            id TEXT PRIMARY KEY, title TEXT NOT NULL,
            category_id TEXT REFERENCES categories(id), project_id TEXT REFERENCES projects(id),
            planned_for TEXT NOT NULL DEFAULT '', status TEXT NOT NULL CHECK(status IN ('open','done')),
            note TEXT NOT NULL, created_at TEXT NOT NULL, completed_at TEXT NOT NULL DEFAULT '',
            completed_date TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL CHECK(revision > 0))""",
        """CREATE TABLE sessions (
            id TEXT PRIMARY KEY, activity_id TEXT NOT NULL REFERENCES activities(id),
            local_date TEXT NOT NULL, minutes REAL CHECK(minutes IS NULL OR minutes > 0),
            note TEXT NOT NULL, source TEXT NOT NULL CHECK(source IN ('manual','untimed')),
            created_at TEXT NOT NULL)""",
        "CREATE INDEX sessions_activity ON sessions(activity_id)",
        "CREATE INDEX sessions_date ON sessions(local_date)",
        """CREATE TABLE day_notes (local_date TEXT PRIMARY KEY, body TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision > 0), updated_at TEXT NOT NULL)""",
        """CREATE TABLE activity_events (id TEXT PRIMARY KEY,
            activity_id TEXT NOT NULL REFERENCES activities(id), action TEXT NOT NULL,
            occurred_at TEXT NOT NULL, from_date TEXT, to_date TEXT)""",
    ),
    2: (
        """CREATE TABLE request_receipts (request_id TEXT PRIMARY KEY,
            digest TEXT NOT NULL, result TEXT NOT NULL)""",
    ),
    3: (
        """CREATE TABLE sessions_v3 (
            id TEXT PRIMARY KEY, activity_id TEXT NOT NULL REFERENCES activities(id),
            local_date TEXT NOT NULL, minutes REAL,
            note TEXT NOT NULL, source TEXT NOT NULL CHECK(source IN ('manual','untimed','timer')),
            created_at TEXT NOT NULL,
            CHECK((source='untimed' AND minutes IS NULL) OR
                  (source='manual' AND minutes IS NOT NULL AND minutes > 0) OR
                  (source='timer' AND minutes IS NOT NULL AND minutes >= 0)))""",
        "INSERT INTO sessions_v3 SELECT * FROM sessions",
        "DROP TABLE sessions",
        "ALTER TABLE sessions_v3 RENAME TO sessions",
        "CREATE INDEX sessions_activity ON sessions(activity_id)",
        "CREATE INDEX sessions_date ON sessions(local_date)",
        """CREATE TABLE timer_sessions (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            activity_id TEXT NOT NULL REFERENCES activities(id),
            status TEXT NOT NULL CHECK(status IN ('running','paused','interrupted','stopped')),
            recovery_reason TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL)""",
        "CREATE UNIQUE INDEX one_active_timer ON timer_sessions((1)) WHERE status IN ('running','interrupted')",
        "CREATE UNIQUE INDEX one_unfinished_timer ON timer_sessions(activity_id) WHERE status != 'stopped'",
        """CREATE TABLE session_intervals (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES timer_sessions(session_id),
            start_utc TEXT NOT NULL, end_utc TEXT, checkpoint_utc TEXT NOT NULL,
            duration_seconds REAL NOT NULL DEFAULT 0 CHECK(duration_seconds >= 0),
            checkpoint_wall REAL NOT NULL, checkpoint_mono REAL NOT NULL, checkpoint_boot REAL NOT NULL,
            boot_id TEXT NOT NULL, owner_pid INTEGER NOT NULL, owner_start TEXT NOT NULL,
            client_id TEXT NOT NULL, time_zone TEXT NOT NULL, offset_seconds INTEGER NOT NULL,
            local_date TEXT NOT NULL)""",
        "CREATE UNIQUE INDEX one_open_interval ON session_intervals((1)) WHERE end_utc IS NULL",
        "CREATE INDEX intervals_session ON session_intervals(session_id)",
    ),
    4: (
        "ALTER TABLE categories ADD COLUMN archived_at TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE categories ADD COLUMN revision INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE projects ADD COLUMN archived_at TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN revision INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE activities ADD COLUMN deleted_at TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE sessions ADD COLUMN revision INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE sessions ADD COLUMN deleted_at TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE sessions ADD COLUMN start_utc TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE sessions ADD COLUMN end_utc TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE sessions ADD COLUMN time_zone TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE sessions ADD COLUMN offset_seconds INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE day_notes ADD COLUMN deleted_at TEXT NOT NULL DEFAULT ''",
        """CREATE TABLE trash (id TEXT PRIMARY KEY,
            kind TEXT NOT NULL CHECK(kind IN ('activity','session','note')),
            record_id TEXT NOT NULL, deleted_at TEXT NOT NULL, UNIQUE(kind,record_id))""",
        "CREATE INDEX activities_visible ON activities(deleted_at, status, planned_for)",
        "CREATE INDEX sessions_visible ON sessions(deleted_at, local_date)",
    ),
    5: (
        "ALTER TABLE activities ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1))",
    ),
    6: (
        """CREATE TABLE activity_tasks (
            id TEXT PRIMARY KEY, activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            position INTEGER NOT NULL CHECK(position >= 0), archived_at TEXT NOT NULL DEFAULT '')""",
        "CREATE INDEX tasks_activity ON activity_tasks(activity_id, archived_at, position)",
        "CREATE UNIQUE INDEX tasks_active_order ON activity_tasks(activity_id, position) WHERE archived_at=''",
        """CREATE TABLE session_tasks (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            task_id TEXT NOT NULL REFERENCES activity_tasks(id),
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            position INTEGER NOT NULL CHECK(position >= 0),
            UNIQUE(session_id, task_id), UNIQUE(session_id, position))""",
    ),
    7: (
        "ALTER TABLE activity_tasks ADD COLUMN done INTEGER NOT NULL DEFAULT 0 CHECK(done IN (0,1))",
        """UPDATE activity_tasks SET done=1 WHERE archived_at='' AND activity_id IN
            (SELECT id FROM activities WHERE status='done')""",
    ),
}


class StoreError(Exception):
    def __init__(self, code, message, current_note=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.current_note = current_note

    def wire(self):
        result = {"code": self.code, "message": self.message}
        if self.current_note is not None:
            result["currentNote"] = self.current_note
        return result


def storage_error(error):
    code = getattr(error, "sqlite_errorcode", 0) & 255
    if code in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
        return StoreError("busy", "The database is busy. Your changes were not saved; retry when it is available.")
    if code in (sqlite3.SQLITE_READONLY, sqlite3.SQLITE_PERM) or isinstance(error, PermissionError):
        return StoreError("read_only", "The profile is read-only or is not writable. Your changes were not saved.")
    if code == sqlite3.SQLITE_FULL or getattr(error, "errno", None) in (errno.ENOSPC, errno.EDQUOT):
        return StoreError("storage_full", "Storage is full. Your changes were not saved; free space and retry the retained draft.")
    return StoreError("storage", "The database could not be read or saved. Existing records have not been replaced.")


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def new_id():
    return uuid.uuid4().hex


def text(value, field, required=False):
    if not isinstance(value, str):
        raise StoreError("validation", f"{field} must be text.")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise StoreError("validation", f"{field} must contain valid Unicode.") from None
    if required and not value.strip():
        raise StoreError("validation", f"{field} is required.")
    return value


def calendar_date(value, field="date", optional=False):
    value = text(value, field)
    if value == "" and optional:
        return value
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        raise StoreError("validation", f"{field} must be a valid YYYY-MM-DD date.") from None
    if parsed.isoformat() != value:
        raise StoreError("validation", f"{field} must be a valid YYYY-MM-DD date.")
    return value


def duration(value):
    if value is None:
        return None
    if type(value) not in (int, float):
        raise StoreError("validation", "minutes must be a positive finite number or null.")
    try:
        valid = math.isfinite(value) and value > 0 and math.isfinite(value * 60)
    except OverflowError:
        valid = False
    if not valid:
        raise StoreError("validation", "minutes must be positive and representable as finite seconds, or null.")
    return value


def boolean(value, field="done"):
    if type(value) is not bool:
        raise StoreError("validation", f"{field} must be true or false.")
    return value


def revision(value):
    if type(value) is not int or value < 0:
        raise StoreError("validation", "expectedRevision must be a nonnegative integer.")
    return value


def normalized_name(value, field):
    return unicodedata.normalize("NFC", text(value, field).strip())


def profile_path(profile=None):
    if profile is None:
        data_home = os.environ.get("XDG_DATA_HOME", "")
        base = Path(data_home) if data_home and Path(data_home).is_absolute() else Path.home() / ".local/share"
        path = base / "daylog"
    else:
        path = Path(profile)
        if not path.is_absolute():
            raise StoreError("validation", "The profile path must be absolute.")
    path = path.resolve()
    if path == SOURCE_ROOT or SOURCE_ROOT in path.parents:
        raise StoreError("validation", "The data profile must be outside the source tree.")
    return path


def validate_request(request):
    if not isinstance(request, dict):
        raise StoreError("protocol", "A JSON request object is required.")
    if type(request.get("protocol")) is not int or request["protocol"] != 1:
        raise StoreError("protocol", "Unsupported protocol version.")
    if not isinstance(request.get("requestId"), str) or not request["requestId"].strip():
        raise StoreError("protocol", "A nonempty requestId is required.")
    try:
        request["requestId"].encode("utf-8")
    except UnicodeEncodeError:
        raise StoreError("protocol", "requestId must contain valid Unicode.") from None
    if not isinstance(request.get("op"), str) or request["op"] not in OPERATIONS:
        raise StoreError("protocol", "Unknown operation.")
    if not isinstance(request.get("args"), dict):
        raise StoreError("protocol", "args must be an object.")
    if "clientId" in request:
        text(request["clientId"], "clientId", required=True)
    if request["op"] in TIMER_MUTATIONS and "clientId" not in request:
        raise StoreError("protocol", "Timer operations require a nonempty clientId.")


class Store:
    def __init__(self, profile=None, read_only=False, clock=None):
        self.path = profile_path(profile)
        self.db_path = self.path / "daylog.sqlite3"
        self.connection = None
        self.read_only = read_only
        self.client_id = ""
        try:
            from .timer import Clock, TimerEngine
        except ImportError:
            from timer import Clock, TimerEngine
        self.timer = TimerEngine(self, clock if clock is not None else Clock())
        try:
            self._open(read_only)
        except (sqlite3.Error, OSError) as error:
            self.close()
            raise storage_error(error) from None
        except Exception:
            self.close()
            raise

    def _open(self, read_only):
        if self.db_path.is_symlink():
            raise StoreError("storage", "A database symlink is not a supported profile.")
        existing = self.db_path.exists()
        if not read_only:
            self.path.mkdir(mode=0o700, parents=True, exist_ok=True)
            if not existing:
                try:
                    fd = os.open(self.db_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                except FileExistsError:
                    existing = True
                else:
                    os.close(fd)
        mode = "ro" if read_only else "rw"
        self.connection = sqlite3.connect(
            self.db_path.as_uri() + "?mode=" + mode, uri=True, timeout=0.5, isolation_level=None
        )
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.execute("PRAGMA secure_delete=ON")
        version = self.connection.execute("PRAGMA user_version").fetchone()[0]
        if version > SCHEMA_VERSION:
            raise StoreError("storage", "This database uses a newer schema. Use a compatible Daymark version; it was not changed.")
        if self.connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise StoreError("storage", "The database is damaged. It was not replaced or repaired.")
        if self.connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise StoreError("storage", "The database has invalid record relationships. It was not changed.")
        if version == 0:
            tables = self.connection.execute("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").fetchall()
            if tables:
                raise StoreError("storage", "The database has an unrecognized schema. It was not changed.")
        # Do not change permissions on a corrupt, unknown, future, or read-only database.
        if not read_only:
            # No-op chmod still changes ctime and wakes profile watchers. Reads
            # must not trigger an endless read/notification loop.
            if stat.S_IMODE(self.path.stat().st_mode) != 0o700:
                self.path.chmod(0o700)
            if stat.S_IMODE(self.db_path.stat().st_mode) != 0o600:
                self.db_path.chmod(0o600)
        if version < SCHEMA_VERSION:
            if read_only:
                raise StoreError("read_only", "The database needs a schema upgrade and cannot be opened read-only.")
            self._migrate(existing)

    def _migrate(self, existing):
        # Reserve the writer before backup. A separate read connection avoids backing
        # up from a connection holding a write transaction, which SQLite cannot do.
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            current = self.connection.execute("PRAGMA user_version").fetchone()[0]
            if current > SCHEMA_VERSION:
                raise StoreError("storage", "The database schema changed; reopen with a compatible version.")
            if current < SCHEMA_VERSION and existing:
                self._backup(f"before-v{current}")
            for next_version in range(current + 1, SCHEMA_VERSION + 1):
                for statement in MIGRATIONS[next_version]:
                    self.connection.execute(statement)
                self.connection.execute("INSERT INTO schema_migrations VALUES (?, ?)", (next_version, utc_now()))
                self.connection.execute(f"PRAGMA user_version={next_version}")
            self.connection.commit()
        except Exception:
            self.connection.rollback()
            raise

    def _backup(self, label):
        # Caller reserves the writer before invoking this. The read connection
        # copies the last committed database, including WAL, never an open writer.
        backup_path = self.path / f"daylog.{label}-{new_id()}.sqlite3"
        fd = os.open(backup_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        try:
            with closing(sqlite3.connect(self.db_path.as_uri() + "?mode=ro", uri=True)) as source, \
                    closing(sqlite3.connect(backup_path)) as target:
                source.backup(target)
            with backup_path.open("rb") as saved:
                os.fsync(saved.fileno())
            directory = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except Exception:
            backup_path.unlink(missing_ok=True)
            raise
        return str(backup_path)

    def close(self):
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def handle(self, request):
        validate_request(request)
        op, args = request["op"], request["args"]
        self.client_id = request.get("clientId", "")
        mutation = op in MUTATIONS
        try:
            self.connection.execute("BEGIN" if self.read_only else "BEGIN IMMEDIATE")
            # Only historical owner-tagged timer clients observe live clocks.
            # The journal sends no owner: reading it must neither count time nor
            # mutate a legacy timer before retirement can commit atomically.
            if self.client_id:
                self.timer.begin()
            if (self.client_id and not self.read_only
                    and op not in ("export_records", "restore_records", "settle_legacy_timers")
                    and self.timer.latch()):
                self.connection.execute("UPDATE metadata SET revision=revision+1 WHERE id=1")
            # Recovery detection survives a rejected operation, but none of that
            # operation's partial writes do.
            self.connection.execute("SAVEPOINT operation")
            try:
                if mutation:
                    if self.read_only:
                        raise StoreError("read_only", "The profile is read-only. Your changes were not saved.")
                    try:
                        payload = {"op": op, "args": args}
                        if op in TIMER_MUTATIONS:
                            payload["clientId"] = self.client_id
                        digest = hashlib.sha256(json.dumps(
                            payload, ensure_ascii=True, sort_keys=True,
                            separators=(",", ":"), allow_nan=False
                        ).encode("utf-8")).hexdigest()
                    except (ValueError, OverflowError):
                        raise StoreError("validation", "Request values must be finite JSON values.") from None
                    receipt = self.connection.execute(
                        "SELECT digest, result FROM request_receipts WHERE request_id=?", (request["requestId"],)
                    ).fetchone()
                    if receipt is not None:
                        if receipt["digest"] != digest:
                            raise StoreError("conflict", "This requestId was already used for different changes. Use a new requestId.")
                        result = json.loads(receipt["result"])
                    else:
                        result = (self.timer.mutate(op, args) if op in TIMER_MUTATIONS
                                  else getattr(self, "_" + op)(args))
                        changed = op != "settle_legacy_timers" or result["retiredSessions"] > 0
                        if changed:
                            self.connection.execute("UPDATE metadata SET revision=revision+1 WHERE id=1")
                        # Retirement with nothing to settle is a true no-op:
                        # leave both the journal revision and replay history alone.
                        if changed and op != "timer_checkpoint":
                            self.connection.execute(
                                "INSERT INTO request_receipts VALUES (?, ?, ?)",
                                (request["requestId"], digest, json.dumps(result, separators=(",", ":")))
                            )
                    snapshot = self._snapshot()
                else:
                    snapshot = self._snapshot()
                    if op == "snapshot":
                        result = {}
                    elif op == "history":
                        result = self._history(args, snapshot)
                    elif op == "review":
                        try:
                            from .review import weekly_review
                        except ImportError:
                            from review import weekly_review
                        result = weekly_review(snapshot, args)
                    else:
                        try:
                            from .portability import export_records
                        except ImportError:
                            from portability import export_records
                        result = export_records(self, args)
                response = {"protocol": 1, "requestId": request["requestId"], "ok": True, "result": result,
                            "snapshot": snapshot}
            except (StoreError, sqlite3.Error, OSError):
                # SQLITE_FULL can automatically roll back the whole transaction;
                # do not replace its useful error with "no such savepoint".
                if self.connection.in_transaction:
                    self.connection.execute("ROLLBACK TO operation")
                    self.connection.execute("RELEASE operation")
                    self.connection.commit()
                raise
            self.connection.execute("RELEASE operation")
            self.connection.commit()
            return response
        except (sqlite3.Error, OSError) as error:
            self.connection.rollback()
            raise storage_error(error) from None
        except Exception:
            self.connection.rollback()
            raise

    def _label(self, table, name, current_id=None):
        # table is only a private constant, never request data.
        if not name:
            return None
        key = name.casefold()
        row = self.connection.execute(f"SELECT id, archived_at FROM {table} WHERE name_key=?", (key,)).fetchone()
        if row:
            if row["archived_at"] and row["id"] != current_id:
                raise StoreError("archived", "Unarchive this label before assigning it to another activity.")
            return row["id"]
        label_id = new_id()
        self.connection.execute(f"INSERT INTO {table} (id,name,name_key) VALUES (?, ?, ?)", (label_id, name, key))
        return label_id

    def _activity_row(self, activity_id):
        activity_id = text(activity_id, "activityId", required=True)
        row = self.connection.execute("SELECT * FROM activities WHERE id=? AND deleted_at=''", (activity_id,)).fetchone()
        if row is None:
            raise StoreError("not_found", "The activity no longer exists.")
        return row

    def _event(self, activity_id, action, before=None, after=None):
        self.connection.execute("INSERT INTO activity_events VALUES (?, ?, ?, ?, ?, ?)",
                                (new_id(), activity_id, action, utc_now(), before, after))

    def _complete(self, activity_id, done, *, cascade=True):
        activity = self._activity_row(activity_id)
        if done and self.connection.execute(
                "SELECT 1 FROM timer_sessions WHERE activity_id=? AND status!='stopped'", (activity_id,)).fetchone():
            raise StoreError("timer_unfinished", "Stop this activity's timer explicitly before marking it done.")
        changed_tasks = 0
        if cascade:
            changed_tasks = self.connection.execute(
                "UPDATE activity_tasks SET done=? WHERE activity_id=? AND archived_at='' AND done!=?",
                (done, activity_id, done)).rowcount
        status = "done" if done else "open"
        if activity["status"] == status:
            if changed_tasks:
                self.connection.execute("UPDATE activities SET revision=revision+1 WHERE id=?", (activity_id,))
            return
        completed = datetime.now(timezone.utc) if done else None
        self.connection.execute(
            "UPDATE activities SET status=?, completed_at=?, completed_date=?, revision=revision+1 WHERE id=?",
            (status, completed.isoformat(timespec="microseconds").replace("+00:00", "Z") if done else "",
             completed.astimezone().date().isoformat() if done else "", activity_id)
        )
        self._event(activity_id, "complete" if done else "reopen")

    def _manual_fields(self, args):
        day = calendar_date(args.get("date"))
        minutes = duration(args.get("minutes"))
        note = text(args.get("note", ""), "note")
        start = text(args.get("startUtc", ""), "startUtc")
        end = text(args.get("endUtc", ""), "endUtc")
        zone_name = text(args.get("timeZone", "UTC"), "timeZone")
        if not start and not end:
            return day, minutes, note, "", "", "", 0
        try:
            first = datetime.fromisoformat(start.replace("Z", "+00:00"))
            last = datetime.fromisoformat(end.replace("Z", "+00:00"))
            if first.utcoffset() is None or last.utcoffset() is None:
                raise ValueError()
            first, last = first.astimezone(timezone.utc), last.astimezone(timezone.utc)
            zone = ZoneInfo(zone_name)
            measured = (last - first).total_seconds() / 60
            local = first.astimezone(zone)
        except (ValueError, OverflowError, ZoneInfoNotFoundError):
            raise StoreError("validation", "Both clock bounds must be timezone-aware ISO timestamps, with a valid IANA time zone.") from None
        if measured <= 0:
            raise StoreError("validation", "The clock end must follow its start.")
        if day != local.date().isoformat():
            raise StoreError("validation", "The session date must match the clock start in its logging time zone.")
        if minutes is not None and not math.isclose(minutes, measured, rel_tol=1e-9, abs_tol=1e-9):
            raise StoreError("validation", "Clocked duration is derived from the interval. Leave minutes empty or match its duration.")
        return (day, measured, note, first.isoformat(timespec="microseconds").replace("+00:00", "Z"),
                last.isoformat(timespec="microseconds").replace("+00:00", "Z"), zone_name,
                int(local.utcoffset().total_seconds()))

    def _insert_session(self, activity_id, fields):
        day, minutes, note, start, end, zone, offset = fields
        session_id = new_id()
        self.connection.execute("""INSERT INTO sessions
            (id,activity_id,local_date,minutes,note,source,created_at,start_utc,end_utc,time_zone,offset_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (session_id, activity_id, day, minutes, note, "untimed" if minutes is None else "manual",
             utc_now(), start, end, zone, offset))
        return session_id

    def _set_activity_tasks(self, activity_id, definitions):
        """Replace active definitions without changing historical entry labels."""
        if not isinstance(definitions, list):
            raise StoreError("validation", "tasks must be a list of task definitions.")
        existing = {row["id"]: row for row in self.connection.execute(
            "SELECT * FROM activity_tasks WHERE activity_id=?", (activity_id,))}
        desired, seen = [], set()
        for definition in definitions:
            if not isinstance(definition, dict) or set(definition) - {"id", "title"}:
                raise StoreError("validation", "Each task requires a title and optional existing id.")
            title = text(definition.get("title"), "task title", required=True).strip()
            task_id = text(definition["id"], "task id", required=True) if "id" in definition else new_id()
            if task_id in seen:
                raise StoreError("validation", "A task may appear only once.")
            if "id" in definition and task_id not in existing:
                raise StoreError("validation", "Task ids must belong to this activity.")
            seen.add(task_id)
            desired.append((task_id, title))
        # Temporarily archive the active list so reordering never collides with
        # the unique active-position index. The caller's transaction is atomic.
        self.connection.execute(
            "UPDATE activity_tasks SET archived_at=? WHERE activity_id=? AND archived_at=''",
            (utc_now(), activity_id))
        for position, (task_id, title) in enumerate(desired):
            if task_id in existing:
                self.connection.execute(
                    "UPDATE activity_tasks SET title=?,position=?,archived_at='' WHERE id=?",
                    (title, position, task_id))
            else:
                self.connection.execute(
                    "INSERT INTO activity_tasks (id,activity_id,title,position) VALUES (?,?,?,?)",
                    (task_id, activity_id, title, position))
        self._reconcile_task_completion(activity_id)

    def _reconcile_task_completion(self, activity_id):
        states = self.connection.execute(
            "SELECT COUNT(*) total, MIN(done) done FROM activity_tasks WHERE activity_id=? AND archived_at=''",
            (activity_id,)).fetchone()
        if states["total"]:
            self._complete(activity_id, bool(states["done"]), cascade=False)

    def _set_task_done(self, args):
        activity = self._activity_row(args.get("activityId"))
        if activity["revision"] != revision(args.get("expectedRevision")):
            raise StoreError("conflict", "The activity changed. Reload it before changing task completion.")
        task_id = text(args.get("taskId"), "taskId", required=True)
        done = boolean(args.get("done"))
        task = self.connection.execute(
            "SELECT done FROM activity_tasks WHERE id=? AND activity_id=? AND archived_at=''",
            (task_id, activity["id"])).fetchone()
        if task is None:
            raise StoreError("not_found", "The active task no longer exists.")
        if bool(task["done"]) != done:
            self.connection.execute("UPDATE activity_tasks SET done=? WHERE id=?", (done, task_id))
            self._reconcile_task_completion(activity["id"])
            self.connection.execute("UPDATE activities SET revision=revision+1 WHERE id=?", (activity["id"],))
        current = self._activity_row(activity["id"])
        return {"activityId": activity["id"], "taskId": task_id, "revision": current["revision"]}

    def _set_session_tasks(self, session_id, activity_id, task_ids):
        """Keep retained snapshot labels, even when a definition was renamed."""
        if not isinstance(task_ids, list):
            raise StoreError("validation", "taskIds must be a list of task ids.")
        existing = {row["task_id"]: row for row in self.connection.execute(
            "SELECT * FROM session_tasks WHERE session_id=?", (session_id,))}
        definitions = {row["id"]: row for row in self.connection.execute(
            "SELECT * FROM activity_tasks WHERE activity_id=?", (activity_id,))}
        selections, seen = [], set()
        for task_id in task_ids:
            task_id = text(task_id, "task id", required=True)
            if task_id in seen:
                raise StoreError("validation", "A task may be selected only once.")
            definition = definitions.get(task_id)
            if definition is None or (definition["archived_at"] and task_id not in existing):
                raise StoreError("validation", "Selected tasks must be active and belong to this activity.")
            seen.add(task_id)
            old = existing.get(task_id)
            selections.append((old["id"] if old else new_id(), task_id,
                               old["title"] if old else definition["title"]))
        self.connection.execute("DELETE FROM session_tasks WHERE session_id=?", (session_id,))
        self.connection.executemany(
            "INSERT INTO session_tasks (id,session_id,task_id,title,position) VALUES (?,?,?,?,?)",
            ((selection_id, session_id, task_id, title, position)
             for position, (selection_id, task_id, title) in enumerate(selections)))

    def countdown_target(self, activity_id, task_id=""):
        activity = self._activity_row(activity_id)
        task_id = text(task_id, "taskId")
        title = ""
        if task_id:
            task = self.connection.execute(
                "SELECT title FROM activity_tasks WHERE id=? AND activity_id=? AND archived_at=''",
                (task_id, activity["id"])).fetchone()
            if task is None:
                raise StoreError("validation", "Choose an active task belonging to this activity.")
            title = task["title"]
        return {"activityTitle": activity["title"], "taskTitle": title}

    def _session_result(self, session_id):
        row = self.connection.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        result = {"activityId": row["activity_id"], "sessionId": session_id, "revision": row["revision"]}
        if not row["start_utc"]:
            return result
        first = datetime.fromisoformat(row["start_utc"]).timestamp()
        last = datetime.fromisoformat(row["end_utc"]).timestamp()
        rows = self.connection.execute("""SELECT s.start_utc, s.minutes * 60 seconds FROM sessions s
            JOIN activities a ON a.id=s.activity_id
            WHERE s.id!=? AND s.deleted_at='' AND a.deleted_at='' AND s.start_utc!=''
            UNION ALL SELECT i.start_utc, i.duration_seconds FROM session_intervals i
            JOIN sessions s ON s.id=i.session_id JOIN activities a ON a.id=s.activity_id
            WHERE s.id!=? AND s.deleted_at='' AND a.deleted_at=''""", (session_id, session_id))
        for other in rows:
            beginning = datetime.fromisoformat(other["start_utc"]).timestamp()
            if first < beginning + other["seconds"] and beginning < last:
                result["warning"] = "Clock intervals overlap. Review counts combined clock time once; category totals may overlap."
                break
        return result

    def _create_activity(self, args):
        title = text(args.get("title"), "title", required=True).strip()
        category = normalized_name(args.get("category", ""), "category")
        project = normalized_name(args.get("project", ""), "project")
        planned = calendar_date(args.get("plannedFor", ""), "plannedFor", optional=True)
        note = text(args.get("note", ""), "note")
        mode = args.get("mode", "plan")
        if mode not in ("plan", "log"):
            raise StoreError("validation", "mode must be plan or log.")
        done = boolean(args.get("done", False))
        pinned = boolean(args.get("pinned", False), "pinned")
        day = calendar_date(args.get("date", date.today().isoformat())) if mode == "log" else None
        minutes = duration(args.get("minutes"))
        session_note = text(args.get("sessionNote", ""), "sessionNote")
        activity_id = new_id()
        self.connection.execute("""INSERT INTO activities
            (id,title,category_id,project_id,planned_for,status,note,created_at,completed_at,completed_date,revision,pinned)
            VALUES (?, ?, ?, ?, ?, 'open', ?, ?, '', '', 1, ?)""",
                                (activity_id, title, self._label("categories", category),
                                 self._label("projects", project), planned, note, utc_now(), pinned))
        if "tasks" in args:
            self._set_activity_tasks(activity_id, args["tasks"])
        result = {"activityId": activity_id}
        if mode == "log":
            session_id = self._insert_session(activity_id, self._manual_fields(
                dict(args, date=day, note=session_note)))
            self._set_session_tasks(session_id, activity_id, args.get("taskIds", []))
            result.update(self._session_result(session_id))
        if done:
            self._complete(activity_id, True)
        return result

    def _add_session(self, args):
        activity = self._activity_row(args.get("activityId"))
        if "countdownTaskId" in args:
            self.countdown_target(activity["id"], args["countdownTaskId"])
        fields = self._manual_fields(args)
        done = boolean(args.get("done", False))
        session_id = self._insert_session(activity["id"], fields)
        self._set_session_tasks(session_id, activity["id"], args.get("taskIds", []))
        if done:
            self._complete(activity["id"], True)
        return self._session_result(session_id)

    def _update_activity(self, args):
        activity = self._activity_row(args.get("activityId"))
        expected = revision(args.get("expectedRevision"))
        title = text(args["title"], "title", required=True).strip() if "title" in args else activity["title"]
        category_id = (self._label("categories", normalized_name("" if args["category"] is None else args["category"], "category"), activity["category_id"])
                       if "category" in args else activity["category_id"])
        project_id = (self._label("projects", normalized_name("" if args["project"] is None else args["project"], "project"), activity["project_id"])
                      if "project" in args else activity["project_id"])
        planned = calendar_date(args.get("plannedFor", activity["planned_for"]), "plannedFor", optional=True)
        note = text(args.get("note", activity["note"]), "note")
        pinned = boolean(args.get("pinned", bool(activity["pinned"])), "pinned")
        if activity["revision"] != expected:
            raise StoreError("conflict", "The activity changed since this editor loaded. Reload it before saving.")
        self.connection.execute(
            "UPDATE activities SET title=?, category_id=?, project_id=?, planned_for=?, note=?, pinned=?, revision=revision+1 WHERE id=?",
            (title, category_id, project_id, planned, note, pinned, activity["id"])
        )
        if "tasks" in args:
            self._set_activity_tasks(activity["id"], args["tasks"])
        if activity["planned_for"] != planned:
            self._event(activity["id"], "reschedule", activity["planned_for"], planned)
        return {"activityId": activity["id"], "revision": self._activity_row(activity["id"])["revision"]}

    def _set_done(self, args):
        activity = self._activity_row(args.get("activityId"))
        if activity["revision"] != revision(args.get("expectedRevision")):
            raise StoreError("conflict", "The activity changed. Reload it before changing completion.")
        self._complete(activity["id"], boolean(args.get("done")))
        return {"activityId": activity["id"], "revision": self._activity_row(activity["id"])["revision"]}

    def _save_note(self, args):
        day = calendar_date(args.get("date"))
        body = text(args.get("body"), "body")
        expected = revision(args.get("expectedRevision"))
        row = self.connection.execute("SELECT * FROM day_notes WHERE local_date=?", (day,)).fetchone()
        if row and row["deleted_at"]:
            raise StoreError("deleted", "This daily note is in Trash. Undo or permanently delete it before writing a replacement.")
        current = {"date": day, "body": row["body"] if row else "", "revision": row["revision"] if row else 0,
                   "updatedAt": row["updated_at"] if row else ""}
        if current["revision"] != expected:
            raise StoreError("conflict", "The daily note changed elsewhere. Review the saved note before choosing to overwrite it.", current)
        self.connection.execute(
            "INSERT INTO day_notes (local_date,body,revision,updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(local_date) DO UPDATE SET body=excluded.body, revision=excluded.revision, updated_at=excluded.updated_at",
            (day, body, expected + 1, utc_now())
        )
        return {"date": day, "revision": expected + 1}

    def _session_row(self, session_id):
        row = self.connection.execute("""SELECT s.* FROM sessions s JOIN activities a ON a.id=s.activity_id
            WHERE s.id=? AND s.deleted_at='' AND a.deleted_at=''""",
            (text(session_id, "sessionId", required=True),)).fetchone()
        if row is None:
            raise StoreError("not_found", "The session no longer exists.")
        return row

    def _update_session(self, args):
        row = self._session_row(args.get("sessionId"))
        if row["revision"] != revision(args.get("expectedRevision")):
            raise StoreError("conflict", "The session changed elsewhere. Reload it before saving.")
        if row["source"] == "timer":
            if any(key in args for key in ("date", "minutes", "startUtc", "endUtc", "timeZone")):
                raise StoreError("validation", "Measured intervals are preserved. Edit the note, or explicitly delete and relog a correction.")
            self.connection.execute("UPDATE sessions SET note=?, revision=revision+1 WHERE id=?",
                                    (text(args.get("note", row["note"]), "note"), row["id"]))
        elif not any(key in args for key in ("minutes", "startUtc", "endUtc", "timeZone")):
            day = calendar_date(args.get("date", row["local_date"]))
            if row["start_utc"] and day != row["local_date"]:
                raise StoreError("validation", "Clocked history keeps its original date. Edit its note without moving the interval.")
            # A journal note/date edit preserves the original measurement and
            # timezone bytes, rather than reinterpreting old clock metadata.
            self.connection.execute("UPDATE sessions SET local_date=?, note=?, revision=revision+1 WHERE id=?",
                                    (day, text(args.get("note", row["note"]), "note"), row["id"]))
        else:
            fields = {"date": row["local_date"], "minutes": row["minutes"], "note": row["note"],
                      "startUtc": row["start_utc"], "endUtc": row["end_utc"], "timeZone": row["time_zone"] or "UTC"}
            fields.update(args)
            day, minutes, note, start, end, zone, offset = self._manual_fields(fields)
            self.connection.execute("""UPDATE sessions SET local_date=?, minutes=?, note=?, source=?,
                start_utc=?, end_utc=?, time_zone=?, offset_seconds=?, revision=revision+1 WHERE id=?""",
                (day, minutes, note, "untimed" if minutes is None else "manual", start, end, zone, offset, row["id"]))
        if "taskIds" in args:
            self._set_session_tasks(row["id"], row["activity_id"], args["taskIds"])
        self._event(row["activity_id"], "edit_session")
        return self._session_result(row["id"])

    def _update_label(self, args):
        kind = text(args.get("kind"), "kind")
        if kind not in ("category", "project"):
            raise StoreError("validation", "Choose category or project.")
        table = "categories" if kind == "category" else "projects"
        label_id = text(args.get("id"), "id", required=True)
        name = normalized_name(args.get("name"), "name")
        if not name:
            raise StoreError("validation", "A label name is required.")
        archived = boolean(args.get("archived"), "archived")
        row = self.connection.execute(f"SELECT * FROM {table} WHERE id=?", (label_id,)).fetchone()
        if row is None:
            raise StoreError("not_found", "The label no longer exists.")
        if row["revision"] != revision(args.get("expectedRevision")):
            raise StoreError("conflict", "The label changed elsewhere. Reload it before saving.")
        if self.connection.execute(f"SELECT 1 FROM {table} WHERE name_key=? AND id!=?", (name.casefold(), label_id)).fetchone():
            raise StoreError("conflict", "A label with this name already exists.")
        self.connection.execute(f"UPDATE {table} SET name=?,name_key=?,archived_at=?,revision=revision+1 WHERE id=?",
                                (name, name.casefold(), (row["archived_at"] or utc_now()) if archived else "", label_id))
        self.connection.execute(f"UPDATE activities SET revision=revision+1 WHERE {kind}_id=?", (label_id,))
        return {"id": label_id, "revision": row["revision"] + 1}

    def _delete_record(self, args):
        kind = text(args.get("kind"), "kind")
        record_id = text(args.get("id"), "id", required=True)
        expected = revision(args.get("expectedRevision"))
        if kind == "activity":
            row = self._activity_row(record_id)
            unfinished = self.connection.execute("SELECT 1 FROM timer_sessions WHERE activity_id=? AND status!='stopped'",
                                                 (record_id,)).fetchone()
            table, key = "activities", "id"
        elif kind == "session":
            row = self._session_row(record_id)
            unfinished = self.connection.execute("SELECT 1 FROM timer_sessions WHERE session_id=? AND status!='stopped'",
                                                 (record_id,)).fetchone()
            table, key = "sessions", "id"
        elif kind == "note":
            calendar_date(record_id)
            row = self.connection.execute("SELECT * FROM day_notes WHERE local_date=? AND deleted_at=''", (record_id,)).fetchone()
            if row is None:
                raise StoreError("not_found", "The daily note no longer exists.")
            unfinished = None
            table, key = "day_notes", "local_date"
        else:
            raise StoreError("validation", "Choose an activity, session or daily note.")
        if row["revision"] != expected:
            raise StoreError("conflict", "The record changed elsewhere. Reload it before deleting.")
        if unfinished:
            raise StoreError("timer_unfinished", "Stop the timer explicitly before moving this record to Trash.")
        when, trash_id = utc_now(), new_id()
        self.connection.execute(f"UPDATE {table} SET deleted_at=?, revision=revision+1 WHERE {key}=?", (when, record_id))
        self.connection.execute("INSERT INTO trash VALUES (?,?,?,?)", (trash_id, kind, record_id, when))
        if kind != "note":
            self._event(record_id if kind == "activity" else row["activity_id"], "delete_" + kind)
        return {"trashId": trash_id}

    def _trash_row(self, trash_id):
        row = self.connection.execute("SELECT * FROM trash WHERE id=?", (text(trash_id, "trashId", required=True),)).fetchone()
        if row is None:
            raise StoreError("not_found", "This Trash entry has already been restored or permanently deleted.")
        return row

    def _undo_delete(self, args):
        row = self._trash_row(args.get("trashId"))
        kind, record_id = row["kind"], row["record_id"]
        if kind == "session":
            session = self.connection.execute("SELECT activity_id FROM sessions WHERE id=?", (record_id,)).fetchone()
            self._activity_row(session["activity_id"])
            table, key, owner = "sessions", "id", session["activity_id"]
        elif kind == "activity":
            table, key, owner = "activities", "id", record_id
        else:
            table, key, owner = "day_notes", "local_date", None
        self.connection.execute(f"UPDATE {table} SET deleted_at='',revision=revision+1 WHERE {key}=?", (record_id,))
        self.connection.execute("DELETE FROM trash WHERE id=?", (row["id"],))
        if owner:
            self._event(owner, "restore_" + kind)
        return {"kind": kind, "id": record_id}

    def _purge_deleted(self, args):
        if not boolean(args.get("confirmed", False), "confirmed"):
            raise StoreError("validation", "Permanently deleting content requires explicit confirmation.")
        row = self._trash_row(args.get("trashId"))
        kind, record_id = row["kind"], row["record_id"]
        if kind in ("activity", "session"):
            predicate = "activity_id=?" if kind == "activity" else "id=?"
            self.connection.execute(f"""DELETE FROM session_intervals WHERE session_id IN
                (SELECT id FROM sessions WHERE {predicate})""", (record_id,))
            self.connection.execute(f"""DELETE FROM timer_sessions WHERE session_id IN
                (SELECT id FROM sessions WHERE {predicate})""", (record_id,))
            self.connection.execute(f"""DELETE FROM trash WHERE kind='session' AND record_id IN
                (SELECT id FROM sessions WHERE {predicate})""", (record_id,))
            self.connection.execute(f"DELETE FROM sessions WHERE {predicate}", (record_id,))
            if kind == "activity":
                self.connection.execute("DELETE FROM activity_events WHERE activity_id=?", (record_id,))
                self.connection.execute("DELETE FROM activities WHERE id=?", (record_id,))
        else:
            self.connection.execute("DELETE FROM day_notes WHERE local_date=?", (record_id,))
        self.connection.execute("DELETE FROM trash WHERE id=?", (row["id"],))
        return {"kind": kind, "id": record_id}

    def _settle_legacy_timers(self, args):
        """Close legacy work at confirmed checkpoints, never at the current clock."""
        unfinished = self.connection.execute(
            "SELECT session_id,activity_id FROM timer_sessions WHERE status!='stopped' ORDER BY rowid"
        ).fetchall()
        when = utc_now()
        for timer in unfinished:
            self.connection.execute("""UPDATE session_intervals SET end_utc=checkpoint_utc
                WHERE session_id=? AND end_utc IS NULL""", (timer["session_id"],))
            self.connection.execute("""UPDATE timer_sessions
                SET status='stopped',recovery_reason='',updated_at=? WHERE session_id=?""",
                (when, timer["session_id"]))
            self._event(timer["activity_id"], "timer_retired")
        return {"retiredSessions": len(unfinished)}

    def _restore_records(self, args):
        try:
            from .portability import restore_records
        except ImportError:
            from portability import restore_records
        return restore_records(self, args)

    def _trash(self):
        return [dict(r) for r in self.connection.execute("""SELECT t.id,t.kind,t.record_id recordId,t.deleted_at deletedAt,
            CASE t.kind WHEN 'activity' THEN a.title WHEN 'session' THEN sa.title ELSE t.record_id END title
            FROM trash t LEFT JOIN activities a ON t.kind='activity' AND a.id=t.record_id
            LEFT JOIN sessions s ON t.kind='session' AND s.id=t.record_id
            LEFT JOIN activities sa ON sa.id=s.activity_id ORDER BY t.deleted_at DESC,t.id""")]

    def _activities(self):
        tasks = {}
        for row in self.connection.execute(
                "SELECT id,activity_id,title,done FROM activity_tasks WHERE archived_at='' ORDER BY activity_id,position"):
            tasks.setdefault(row["activity_id"], []).append(
                {"id": row["id"], "title": row["title"], "done": bool(row["done"])})
        rows = self.connection.execute("""SELECT a.*, c.name category, p.name project FROM activities a
            LEFT JOIN categories c ON a.category_id=c.id LEFT JOIN projects p ON a.project_id=p.id
            WHERE a.deleted_at='' ORDER BY a.created_at, a.id""")
        return [{"id": r["id"], "title": r["title"], "category": r["category"] or "", "project": r["project"] or "",
                 "plannedFor": r["planned_for"], "status": r["status"], "note": r["note"], "dateCreated": r["created_at"],
                 "completedAt": r["completed_at"], "completedDate": r["completed_date"],
                 "pinned": bool(r["pinned"]), "revision": r["revision"], "tasks": tasks.get(r["id"], [])} for r in rows]

    def _sessions(self):
        try:
            from .review import manual_days
        except ImportError:
            from review import manual_days
        timers = {r["session_id"]: r for r in self.connection.execute("SELECT * FROM timer_sessions")}
        intervals = {}
        for row in self.connection.execute("SELECT * FROM session_intervals ORDER BY rowid"):
            intervals.setdefault(row["session_id"], []).append(row)
        tasks = {}
        for row in self.connection.execute("SELECT session_id,task_id,title FROM session_tasks ORDER BY session_id,position"):
            tasks.setdefault(row["session_id"], []).append({"id": row["task_id"], "title": row["title"]})
        rows = self.connection.execute("""SELECT s.* FROM sessions s JOIN activities a ON a.id=s.activity_id
            WHERE s.deleted_at='' AND a.deleted_at='' ORDER BY s.local_date DESC,s.created_at,s.id""")
        result = []
        for r in rows:
            session = {"id": r["id"], "activityId": r["activity_id"], "date": r["local_date"], "minutes": r["minutes"],
                       "note": r["note"], "source": r["source"], "status": "stopped", "clock": "", "createdAt": r["created_at"],
                       "revision": r["revision"], "startUtc": r["start_utc"], "endUtc": r["end_utc"],
                       "timeZone": r["time_zone"], "offsetSeconds": r["offset_seconds"],
                       "tasks": tasks.get(r["id"], [])}
            if r["source"] == "timer":
                self.timer.decorate(session, timers[r["id"]], intervals.get(r["id"], []))
            elif r["start_utc"]:
                session["clock"] = r["start_utc"] + " → " + r["end_utc"]
                session["days"] = manual_days(r["start_utc"], r["end_utc"], r["time_zone"], r["offset_seconds"])
            result.append(session)
        return result

    def _notes(self):
        return {r["local_date"]: {"body": r["body"], "revision": r["revision"], "updatedAt": r["updated_at"]}
                for r in self.connection.execute("SELECT * FROM day_notes WHERE deleted_at='' ORDER BY local_date")}

    def _snapshot(self):
        try:
            from .insights import summarize_entries
            from .review import summarize
        except ImportError:
            from insights import summarize_entries
            from review import summarize
        events = []
        for row in self.connection.execute("""SELECT e.* FROM activity_events e JOIN activities a ON a.id=e.activity_id
                WHERE a.deleted_at='' ORDER BY e.occurred_at,e.id"""):
            event = {"id": row["id"], "activityId": row["activity_id"], "action": row["action"], "occurredAt": row["occurred_at"]}
            if row["action"] == "reschedule":
                event.update({"from": row["from_date"], "to": row["to_date"]})
            events.append(event)
        sessions = self._sessions()
        activities = self._activities()
        summary = summarize(activities, sessions)
        today = date.today().isoformat()
        return {"revision": self.connection.execute("SELECT revision FROM metadata WHERE id=1").fetchone()[0],
                "today": today, "activities": activities, "sessions": sessions,
                "insights": summarize_entries(activities, sessions, today),
                "dayNotes": self._notes(), "events": events, "timer": self.timer.summary(sessions),
                "categories": [dict(r) for r in self.connection.execute("SELECT id,name,archived_at archivedAt,revision FROM categories ORDER BY name_key,id")],
                "projects": [dict(r) for r in self.connection.execute("SELECT id,name,archived_at archivedAt,revision FROM projects ORDER BY name_key,id")],
                "trash": self._trash(), "daySummaries": {d["date"]: d for d in summary["days"]}}

    def _history(self, args, snapshot):
        kind = text(args.get("kind", "all"), "kind")
        if kind not in ("all", "notes", "activities"):
            raise StoreError("validation", "History kind must be all, notes, or activities.")
        query = unicodedata.normalize("NFC", text(args.get("query", ""), "query")).casefold()
        category = normalized_name(args.get("category", ""), "category").casefold()
        project = normalized_name(args.get("project", ""), "project").casefold()
        start = calendar_date(args.get("from", ""), "from", optional=True)
        end = calendar_date(args.get("to", ""), "to", optional=True)
        if start and end and start > end:
            raise StoreError("validation", "The start date must not follow the end date.")
        offset, limit = args.get("offset", 0), args.get("limit", 100)
        if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
            raise StoreError("validation", "History offset must be nonnegative and limit must be between 1 and 500.")

        def in_range(day):
            return (not start or day >= start) and (not end or day <= end)

        def matches(*values):
            return not query or any(query in unicodedata.normalize("NFC", value).casefold() for value in values)

        found_sessions = []
        completions = []
        if kind in ("all", "activities"):
            activities = {a["id"]: a for a in snapshot["activities"]}
            selected = {key: a for key, a in activities.items()
                        if (not category or category == a["category"].casefold())
                        and (not project or project == a["project"].casefold())}
            sessions = snapshot["sessions"]
            represented = {s["activityId"] for s in sessions}
            for session in sessions:
                if session["activityId"] not in selected:
                    continue
                activity = selected[session["activityId"]]
                if not matches(activity["title"], activity["note"], session["note"],
                               *(task["title"] for task in session["tasks"])):
                    continue
                slices = ([dict(session, date=day["date"], minutes=day["seconds"] / 60, slice=True)
                           for day in session["days"]] if "days" in session else [session])
                found_sessions.extend(s for s in slices if in_range(s["date"]))
            found_sessions.sort(key=lambda s: s["date"], reverse=True)
            completions = [a for a in selected.values() if a["status"] == "done" and a["id"] not in represented
                           and in_range(a["completedDate"]) and matches(a["title"], a["note"])]
            completions.sort(key=lambda a: (a["completedDate"], a["completedAt"], a["id"]), reverse=True)
        notes = [] if kind == "activities" or category or project else [dict(date=day, body=n["body"], revision=n["revision"])
                                               for day, n in snapshot["dayNotes"].items()
                                               if in_range(day) and matches(n["body"], day if kind == "notes" else "")]
        entries = [(s["date"], s["createdAt"], s["id"], "sessions", s) for s in found_sessions]
        entries.extend((n["date"], "", n["date"], "notes", n) for n in notes)
        entries.extend((a["completedDate"], a["completedAt"], a["id"], "completions", a) for a in completions)
        entries.sort(key=lambda e: e[:4], reverse=True)
        result = {"sessions": [], "notes": [], "completions": [], "total": len(entries),
                  "nextOffset": min(offset + limit, len(entries)), "hasMore": offset + limit < len(entries)}
        for _, _, _, kind, entry in entries[offset:offset + limit]:
            result[kind].append(entry)
        return result
