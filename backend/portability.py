"""Versioned journal portability; JSON is a backup, Markdown is a readable view.

Format 1 carries canonical rows, in insertion order, and the journal revision.
Exports separate activities from diary pages; older combined archives remain
importable. Schema 5 includes boolean activity pins; schema-4 archives receive
false pins. Profile-local receipts and migrations are excluded. Restore never
reactivates a foreign timer owner.
"""

from contextlib import closing, contextmanager
from datetime import datetime, timedelta, timezone
import html
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

try:
    from .storage import (MIGRATIONS, SCHEMA_VERSION, SOURCE_ROOT, StoreError,
                          calendar_date, normalized_name, revision, text, utc_now)
except ImportError:
    from storage import (MIGRATIONS, SCHEMA_VERSION, SOURCE_ROOT, StoreError,
                         calendar_date, normalized_name, revision, text, utc_now)


FORMAT_VERSION = 1
# These are trusted identifiers, never SQL supplied by an import.
COLUMNS = {
    "categories": "id name name_key archived_at revision".split(),
    "projects": "id name name_key archived_at revision".split(),
    "activities": ("id title category_id project_id planned_for status note created_at "
                   "completed_at completed_date revision deleted_at pinned").split(),
    "sessions": ("id activity_id local_date minutes note source created_at revision "
                 "deleted_at start_utc end_utc time_zone offset_seconds").split(),
    "day_notes": "local_date body revision updated_at deleted_at".split(),
    "activity_events": "id activity_id action occurred_at from_date to_date".split(),
    "timer_sessions": "session_id activity_id status recovery_reason updated_at".split(),
    "session_intervals": ("id session_id start_utc end_utc checkpoint_utc duration_seconds "
                          "checkpoint_wall checkpoint_mono checkpoint_boot boot_id owner_pid "
                          "owner_start client_id time_zone offset_seconds local_date").split(),
    "trash": "id kind record_id deleted_at".split(),
}
NULLABLE = {("activities", "category_id"), ("activities", "project_id"),
            ("sessions", "minutes"), ("activity_events", "from_date"),
            ("activity_events", "to_date"), ("session_intervals", "end_utc")}
INTEGER_FIELDS = {"revision", "owner_pid", "offset_seconds"}
NUMBER_FIELDS = {"minutes", "duration_seconds", "checkpoint_wall", "checkpoint_mono", "checkpoint_boot"}


def invalid(message="The JSON export has invalid records or relationships."):
    raise StoreError("validation", message)


def _number(value, minimum=None):
    if type(value) not in (int, float):
        invalid()
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite or (minimum is not None and value < minimum):
        invalid()
    return value


def _timestamp(value, optional=False):
    text(value, "timestamp")
    if optional and value == "":
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            invalid()
        parsed.astimezone(timezone.utc)
        return parsed
    except (ValueError, OverflowError):
        invalid("The JSON export contains an invalid timestamp.")


def _zone(name, offset, *, required=False):
    if not -86400 < offset < 86400:
        invalid("The JSON export contains an invalid timezone offset.")
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        if required:
            invalid("The JSON export contains an unknown timezone.")
        return timezone(timedelta(seconds=offset))


@contextmanager
def _parent_directory(store, value):
    """Walk directory descriptors without following even an ancestor symlink."""
    value = text(value, "path", required=True)
    path = Path(value)
    if path.anchor != "/" or ".." in path.parts or "\x00" in value or path.name in ("", ".", ".."):
        invalid("Use an absolute file path without parent-directory traversal.")
    # Protect the entire profile, including live database sidecars and backups.
    for protected in (SOURCE_ROOT, store.path):
        if path == protected or protected in path.parents:
            invalid("Exports and imports must be outside the source tree and live profile.")
    fd = None
    try:
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        for part in path.parts[1:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd, path.name, str(path)
    except OSError:
        raise StoreError("storage", "The file location is unavailable or unsafe; use an existing directory without symlinks.") from None
    finally:
        if fd is not None:
            os.close(fd)


def _publish(directory, name, content):
    """Private staging inode, durable content, then atomic no-replace publication."""
    temporary = ".daylog-export-" + uuid.uuid4().hex
    created = published = False
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=directory)
        created = True
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        # rename() would overwrite a concurrently created destination. link()
        # atomically publishes the complete inode and fails if any name exists.
        os.link(temporary, name, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
        published = True
        os.unlink(temporary, dir_fd=directory)
        created = False
        os.fsync(directory)
    except FileExistsError:
        raise StoreError("conflict", "The export destination already exists. Choose a new filename; nothing was overwritten.") from None
    except OSError:
        if published:
            os.unlink(name, dir_fd=directory)
        raise StoreError("storage", "The export could not be published durably. No successful export was confirmed.") from None
    finally:
        if created:
            os.unlink(temporary, dir_fd=directory)


def _records(store, scope=None):
    """Read all destination records for restore, or a validated export scope."""
    tables = {}
    for table, columns in COLUMNS.items():
        if (scope == "activities" and table == "day_notes"
                or scope == "diary" and table not in ("day_notes", "trash")):
            tables[table] = []
            continue
        predicate = (" WHERE kind " + ("=" if scope == "diary" else "!=") + " 'note'"
                     if table == "trash" and scope is not None else "")
        tables[table] = [dict(row) for row in store.connection.execute(
            f"SELECT {','.join(columns)} FROM {table}{predicate} ORDER BY rowid")]
    for activity in tables["activities"]:
        activity["pinned"] = bool(activity["pinned"])
    return tables


def _plain(value):
    # Indented code blocks prevent Markdown interpretation; HTML escaping also
    # keeps the content inert in renderers that permit raw HTML. Line-prefixing
    # prevents multiline journal text from escaping its block.
    normalized = str(value).replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join("    " + html.escape(line, quote=False) for line in normalized.split("\n")) + "\n"


def _markdown(tables):
    lines = ["# Daymark activities\n", "Readable export, not a restorable backup. Diary and deleted records are excluded.\n",
             "Timer durations include confirmed time only; unknown gaps are not counted.\n"]
    labels = {name: {row["id"]: row["name"] for row in tables[name]}
              for name in ("categories", "projects")}
    sessions = {}
    for row in tables["sessions"]:
        if not row["deleted_at"]:
            sessions.setdefault(row["activity_id"], []).append(row)
    timers = {row["session_id"]: row for row in tables["timer_sessions"]}
    events = {}
    for row in tables["activity_events"]:
        events.setdefault(row["activity_id"], []).append(row)
    for activity in tables["activities"]:
        if activity["deleted_at"]:
            continue
        lines.extend(["\n## Activity\n", _plain(activity["title"]), _plain("Status: " + activity["status"])])
        for kind, key in (("Category", "categories"), ("Project", "projects")):
            name = labels[key].get(activity[kind.lower() + "_id"], "")
            if name:
                lines.append(_plain(kind + ": " + name))
        if activity["planned_for"]:
            lines.append(_plain("Planned: " + activity["planned_for"]))
        if activity["completed_at"]:
            lines.append(_plain("Completed: " + activity["completed_date"] + " (" + activity["completed_at"] + ")"))
        if activity["note"]:
            lines.extend(["\n### Activity note\n", _plain(activity["note"])])
        for session in sessions.get(activity["id"], []):
            duration = "Untimed" if session["minutes"] is None else f'{session["minutes"]:g} minutes'
            lines.extend(["\n### Session\n", _plain(session["local_date"] + " — " + duration + " — " + session["source"])])
            if session["start_utc"]:
                lines.append(_plain(session["start_utc"] + " to " + session["end_utc"] + " (" + session["time_zone"] + ")"))
            if session["id"] in timers:
                timer = timers[session["id"]]
                lines.append(_plain("Timer: " + timer["status"] + ("; " + timer["recovery_reason"] if timer["recovery_reason"] else "")))
            if session["note"]:
                lines.append(_plain(session["note"]))
        if events.get(activity["id"]):
            lines.append("\n### History\n")
            for event in events[activity["id"]]:
                detail = event["occurred_at"] + " — " + event["action"]
                if event["action"] == "reschedule":
                    detail += ": " + (event["from_date"] or "Inbox") + " → " + (event["to_date"] or "Inbox")
                lines.append(_plain(detail))
    return "\n".join(lines)


def export_records(store, args):
    """Read confirmed canonical records without checkpointing or latching timers."""
    kind = args.get("format")
    if kind not in ("json", "markdown"):
        invalid("Export format must be json or markdown.")
    scope = args.get("scope", "activities")
    if scope not in ("activities", "diary"):
        invalid("Export scope must be activities or diary.")
    if scope == "diary" and kind != "json":
        invalid("Diary export format must be json to preserve page recovery.")
    with _parent_directory(store, args.get("path")) as (directory, name, path):
        tables = _records(store, scope)
        if kind == "json":
            document = {"format": "daylog", "formatVersion": FORMAT_VERSION,
                        "schemaVersion": SCHEMA_VERSION, "scope": scope, "exportedAt": utc_now(),
                        "revision": store.connection.execute("SELECT revision FROM metadata WHERE id=1").fetchone()[0],
                        "tables": tables}
            content = json.dumps(document, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
        else:
            content = _markdown(tables)
        _publish(directory, name, content.encode("utf-8"))
    return {"path": path, "format": kind, "scope": scope,
            "counts": {table: len(rows) for table, rows in tables.items()}}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError("nonfinite JSON value")


def _read_document(store, path):
    with _parent_directory(store, path) as (directory, name, _):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                invalid("Restore requires a regular JSON export file.")
            try:
                return json.load(stream, object_pairs_hook=_unique_object, parse_constant=_reject_constant)
            except (ValueError, UnicodeError, RecursionError):
                invalid("Restore requires a valid UTF-8 JSON export without duplicate keys or nonfinite numbers.")


def _validate_rows(document):
    required = {"format", "formatVersion", "schemaVersion", "exportedAt", "revision", "tables"}
    if type(document) is not dict or set(document) not in (required, required | {"scope"}):
        invalid("This is not a complete Daymark/Daylog JSON export.")
    scope = document.get("scope")
    if "scope" in document and scope not in ("activities", "diary"):
        invalid("Export scope must be activities or diary.")
    if (document["format"] != "daylog" or type(document["formatVersion"]) is not int or
            document["formatVersion"] != FORMAT_VERSION or type(document["schemaVersion"]) is not int or
            document["schemaVersion"] not in (4, SCHEMA_VERSION)):
        invalid("Unsupported export or schema version. Use a compatible Daymark version.")
    revision(document["revision"])
    if document["revision"] > 9223372036854775806:
        invalid()
    _timestamp(document["exportedAt"])
    tables = document["tables"]
    if type(tables) is not dict or set(tables) != set(COLUMNS):
        invalid("The JSON export is missing canonical tables or has unknown tables.")
    for table, columns in COLUMNS.items():
        if type(tables[table]) is not list:
            invalid()
        fields = set(columns)
        legacy_activity = table == "activities" and document["schemaVersion"] == 4
        if legacy_activity:
            fields.remove("pinned")
        for row in tables[table]:
            if type(row) is not dict or set(row) != fields:
                invalid("The JSON export has missing or unknown record fields.")
            for key, value in row.items():
                if value is None and (table, key) in NULLABLE:
                    continue
                if key == "pinned":
                    if type(value) is not bool:
                        invalid("Activity pinned must be true or false.")
                elif key in INTEGER_FIELDS:
                    if type(value) is not int or not -9223372036854775808 <= value <= 9223372036854775807:
                        invalid()
                    if key == "revision" and value < 1:
                        invalid()
                elif key in NUMBER_FIELDS:
                    _number(value)
                else:
                    text(value, "record field")
                    if key in ("id", "activity_id", "session_id", "record_id", "category_id", "project_id") and not value.strip():
                        invalid()
            if legacy_activity:
                row["pinned"] = False
    if scope == "activities" and (tables["day_notes"] or any(row["kind"] == "note" for row in tables["trash"])):
        invalid("An activities archive must not contain diary pages or diary recovery records.")
    if scope == "diary" and (any(rows for table, rows in tables.items() if table not in ("day_notes", "trash"))
                             or any(row["kind"] != "note" for row in tables["trash"])):
        invalid("A diary archive must not contain activity records.")
    return tables


def _validate_semantics(tables):
    for table in ("categories", "projects"):
        for row in tables[table]:
            if not row["name"] or normalized_name(row["name"], "label") != row["name"] or row["name_key"] != row["name"].casefold():
                invalid("The JSON export contains an invalid label.")
            _timestamp(row["archived_at"], optional=True)
    activities = {row["id"]: row for row in tables["activities"]}
    sessions = {row["id"]: row for row in tables["sessions"]}
    timers = {row["session_id"]: row for row in tables["timer_sessions"]}
    intervals = {}
    for row in tables["activities"]:
        text(row["title"], "title", required=True)
        calendar_date(row["planned_for"], optional=True)
        _timestamp(row["created_at"])
        _timestamp(row["deleted_at"], optional=True)
        _timestamp(row["completed_at"], optional=True)
        calendar_date(row["completed_date"], optional=True)
        if row["status"] == "done":
            if not row["completed_at"] or not row["completed_date"]:
                invalid()
        elif row["status"] != "open" or row["completed_at"] or row["completed_date"]:
            invalid()
    for row in tables["sessions"]:
        if row["minutes"] is not None:
            _number(row["minutes"] * 60, 0)
        calendar_date(row["local_date"])
        _timestamp(row["created_at"])
        _timestamp(row["deleted_at"], optional=True)
        start = _timestamp(row["start_utc"], optional=True)
        end = _timestamp(row["end_utc"], optional=True)
        if bool(start) != bool(end):
            invalid()
        if start:
            zone = _zone(row["time_zone"], row["offset_seconds"], required=True)
            seconds = (end - start).total_seconds()
            if (row["source"] != "manual" or seconds <= 0 or
                    not math.isclose(row["minutes"] * 60, seconds, rel_tol=1e-9, abs_tol=1e-6) or
                    start.astimezone(zone).date().isoformat() != row["local_date"] or
                    int(start.astimezone(zone).utcoffset().total_seconds()) != row["offset_seconds"]):
                invalid("The JSON export contains inconsistent manual clock bounds.")
        elif row["time_zone"] or row["offset_seconds"]:
            invalid("Date-only sessions must not fabricate timezone context.")
        if (row["source"] == "timer") != (row["id"] in timers):
            invalid("Timer sessions must retain their timer state.")
    for row in tables["day_notes"]:
        calendar_date(row["local_date"])
        _timestamp(row["updated_at"])
        _timestamp(row["deleted_at"], optional=True)
    for row in tables["activity_events"]:
        text(row["action"], "event action", required=True)
        _timestamp(row["occurred_at"])
        for key in ("from_date", "to_date"):
            if row[key] is not None:
                calendar_date(row[key], optional=True)
        if row["action"] != "reschedule" and (row["from_date"] is not None or row["to_date"] is not None):
            invalid("Only rescheduling events may carry plan dates.")
        if row["action"] == "reschedule" and (row["from_date"] is None or row["to_date"] is None):
            invalid()
    for row in tables["session_intervals"]:
        intervals.setdefault(row["session_id"], []).append(row)
        start = _timestamp(row["start_utc"])
        checkpoint = _timestamp(row["checkpoint_utc"])
        end = _timestamp(row["end_utc"]) if row["end_utc"] is not None else None
        calendar_date(row["local_date"])
        zone = _zone(row["time_zone"], row["offset_seconds"])
        _number(row["duration_seconds"], 0)
        _number(row["checkpoint_mono"], 0)
        _number(row["checkpoint_boot"], 0)
        if row["checkpoint_boot"] < row["checkpoint_mono"] or row["duration_seconds"] > row["checkpoint_mono"]:
            invalid("The JSON export contains inconsistent measured clock context.")
        if (checkpoint < start or (end is not None and end != checkpoint) or
                not math.isclose(checkpoint.timestamp(), row["checkpoint_wall"], rel_tol=0, abs_tol=0.00001) or
                start.astimezone(zone).date().isoformat() != row["local_date"] or row["owner_pid"] <= 0 or
                not all(row[key].strip() for key in ("boot_id", "owner_start", "client_id", "time_zone"))):
            invalid("The JSON export contains invalid timer checkpoint context.")
        # Ensure later allocation and snapshot rendering cannot overflow dates.
        try:
            (start + timedelta(seconds=row["duration_seconds"])).astimezone(zone)
        except (OverflowError, ValueError):
            invalid("The JSON export contains an unrepresentable timer duration.")
    for row in tables["timer_sessions"]:
        _timestamp(row["updated_at"])
        session = sessions.get(row["session_id"])
        activity = activities.get(row["activity_id"])
        spans = intervals.get(row["session_id"], [])
        if not session or not activity or session["activity_id"] != row["activity_id"] or not spans:
            invalid("The JSON export contains broken timer relationships.")
        active = row["status"] in ("running", "interrupted")
        if sum(span["end_utc"] is None for span in spans) != int(active) or (active and spans[-1]["end_utc"] is not None):
            invalid("The JSON export contains inconsistent timer intervals.")
        if row["status"] != "stopped" and (activity["status"] != "open" or activity["deleted_at"] or session["deleted_at"]):
            invalid("Deleted or completed records cannot own unfinished timers.")
        if (row["status"] == "interrupted") != bool(row["recovery_reason"].strip()):
            invalid("The JSON export contains inconsistent timer recovery state.")
        if row["recovery_reason"] not in ("", "system_restart", "owner_exited", "clock_changed",
                                        "suspend_detected", "checkpoint_gap", "restored"):
            invalid("The JSON export contains an unknown timer recovery reason.")
        if (session["local_date"] != spans[0]["local_date"] or
                not math.isclose(session["minutes"] * 60, sum(span["duration_seconds"] for span in spans), rel_tol=1e-9, abs_tol=1e-6)):
            invalid("The JSON export contains inconsistent confirmed timer totals.")
    expected_trash = {}
    for kind, table, key in (("activity", "activities", "id"), ("session", "sessions", "id"), ("note", "day_notes", "local_date")):
        for row in tables[table]:
            if row["deleted_at"]:
                expected_trash[(kind, row[key])] = row["deleted_at"]
    actual_trash = {}
    for row in tables["trash"]:
        _timestamp(row["deleted_at"])
        actual_trash[(row["kind"], row["record_id"])] = row["deleted_at"]
    if actual_trash != expected_trash:
        invalid("The JSON export contains inconsistent deleted records and Trash entries.")


def _insert(connection, tables):
    for table, columns in COLUMNS.items():
        connection.executemany(f"INSERT INTO {table} ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})",
                               ([row[key] for key in columns] for row in tables[table]))


def _validate(document):
    tables = _validate_rows(document)
    # Run trusted current migrations, never SQL or schema definitions from the
    # file. SQLite supplies exact uniqueness/CHECK/FK enforcement before writes
    # to the target; the semantic pass covers invariants SQL does not encode.
    try:
        with closing(sqlite3.connect(":memory:")) as isolated:
            isolated.execute("PRAGMA foreign_keys=ON")
            for version in range(1, SCHEMA_VERSION + 1):
                for statement in MIGRATIONS[version]:
                    isolated.execute(statement)
            _insert(isolated, tables)
            if isolated.execute("PRAGMA foreign_key_check").fetchone() is not None:
                invalid()
        _validate_semantics(tables)
    except (sqlite3.Error, OverflowError, ValueError, TypeError):
        invalid()
    return tables


def _append_plan(existing, incoming):
    """Plan only inserts, keeping timer groups and deletion markers indivisible."""
    additions = {table: [] for table in COLUMNS}
    duplicates = {table: 0 for table in COLUMNS}
    conflicts = []
    keys = {table: columns[0] for table, columns in COLUMNS.items()}
    destination = {table: {row[keys[table]]: row for row in rows}
                   for table, rows in existing.items()}
    activities = destination["activities"].copy()
    imported_activities = set()
    source_activities = {row["id"]: row for row in incoming["activities"]}
    source_trash = {(row["kind"], row["record_id"]): row for row in incoming["trash"]}
    destination_trash = {(row["kind"], row["record_id"]): row for row in existing["trash"]}

    def conflict(table, row, reason):
        key = row[keys[table]]
        if table in ("categories", "projects"):
            label = row["name"]
        elif table == "activities":
            label = row["title"]
        elif table == "day_notes":
            label = row["local_date"]
        elif table in ("sessions", "activity_events"):
            parent = source_activities[row["activity_id"]]
            label = parent["title"]
            if table == "sessions":
                label += " — " + row["local_date"]
        elif table == "trash" and row["kind"] == "note":
            label = row["record_id"]
        else:
            label = key
        conflicts.append({"table": table, "key": key, "label": label, "reason": reason})

    def retained(table, row):
        saved = destination[table].get(row[keys[table]])
        if saved is None:
            return False
        if saved == row:
            duplicates[table] += 1
        else:
            conflict(table, row, "A different version already exists; kept the existing record.")
        return True

    def deletion_conflict(kind, row, key):
        if not row["deleted_at"]:
            return False
        marker = source_trash[(kind, row[key])]
        if (marker["id"] in destination["trash"] or
                (kind, row[key]) in destination_trash):
            conflict({"activity": "activities", "session": "sessions", "note": "day_notes"}[kind],
                     row, "Its Trash entry conflicts with an existing entry; skipped the deleted record.")
            return True
        return False

    def parent_conflict(row, *, unfinished=False):
        parent = activities.get(row["activity_id"])
        if parent is None:
            return "Its activity could not be imported."
        if parent["deleted_at"] and row["activity_id"] not in imported_activities:
            return "Its activity is already in Trash; kept the existing deletion."
        if unfinished and (parent["deleted_at"] or parent["status"] != "open"):
            return "An unfinished timer requires an open activity outside Trash."
        return ""

    # Natural-key reuse applies only to relationships in incoming rows. Even
    # archived destination labels retain their name, state, and revision.
    label_ids = {}
    for table in ("categories", "projects"):
        mapping = label_ids[table] = {}
        names = {row["name_key"]: row for row in existing[table]}
        for row in incoming[table]:
            saved = destination[table].get(row["id"])
            if saved is not None:
                mapping[row["id"]] = saved["id"]
                retained(table, row)
            elif row["name_key"] in names:
                saved = names[row["name_key"]]
                mapping[row["id"]] = saved["id"]
                if all(row[column] == saved[column] for column in COLUMNS[table] if column != "id"):
                    duplicates[table] += 1
                else:
                    conflict(table, row, "This label name already exists with different details; reused the existing label.")
            else:
                mapping[row["id"]] = row["id"]
                additions[table].append(row)

    for original in incoming["activities"]:
        row = dict(original)
        for table, field in (("categories", "category_id"), ("projects", "project_id")):
            if row[field] is not None:
                row[field] = label_ids[table][row[field]]
        if retained("activities", row) or deletion_conflict("activity", row, "id"):
            continue
        additions["activities"].append(row)
        activities[row["id"]] = row
        imported_activities.add(row["id"])

    for row in incoming["day_notes"]:
        if not retained("day_notes", row) and not deletion_conflict("note", row, "local_date"):
            additions["day_notes"].append(row)

    source_timers = {row["session_id"]: row for row in incoming["timer_sessions"]}
    source_intervals = {}
    saved_intervals = {}
    for rows, grouped in ((incoming["session_intervals"], source_intervals),
                          (existing["session_intervals"], saved_intervals)):
        for row in rows:
            grouped.setdefault(row["session_id"], []).append(row)
    active_timer = any(row["status"] in ("running", "interrupted") for row in existing["timer_sessions"])
    unfinished_activities = {row["activity_id"] for row in existing["timer_sessions"] if row["status"] != "stopped"}
    accepted_timers = {}
    interrupted = 0
    for row in incoming["sessions"]:
        timer = source_timers.get(row["id"])
        if timer is None:
            if retained("sessions", row):
                continue
            reason = parent_conflict(row)
            if reason:
                conflict("sessions", row, reason)
            elif not deletion_conflict("session", row, "id"):
                additions["sessions"].append(row)
            continue

        recovered = dict(timer)
        active = timer["status"] in ("running", "interrupted")
        if active:
            recovered["status"] = "interrupted"
            recovered["recovery_reason"] = "restored"
        spans = source_intervals[row["id"]]
        saved = destination["sessions"].get(row["id"])
        if saved is not None:
            saved_timer = destination["timer_sessions"].get(row["id"])
            if (saved == row and saved_timer in (timer, recovered) and
                    saved_intervals.get(row["id"], []) == spans):
                duplicates["sessions"] += 1
                duplicates["timer_sessions"] += 1
                duplicates["session_intervals"] += len(spans)
            else:
                conflict("sessions", row, "A different session or timer history already exists; skipped the entire timer group.")
            continue
        reason = parent_conflict(row, unfinished=timer["status"] != "stopped")
        if not reason and any(span["id"] in destination["session_intervals"] for span in spans):
            reason = "An interval ID already exists; skipped the entire timer group."
        if not reason and active and active_timer:
            reason = "An active or interrupted timer already exists; skipped the entire timer group."
        if not reason and timer["status"] != "stopped" and row["activity_id"] in unfinished_activities:
            reason = "This activity already has an unfinished timer; skipped the entire timer group."
        if reason:
            conflict("sessions", row, reason)
            continue
        if deletion_conflict("session", row, "id"):
            continue
        additions["sessions"].append(row)
        accepted_timers[row["id"]] = recovered
        if active:
            active_timer = True
            interrupted += 1
        if timer["status"] != "stopped":
            unfinished_activities.add(row["activity_id"])

    # Keep each canonical table's archive order, including interval chronology,
    # rather than reordering children by the order of their parent sessions.
    additions["timer_sessions"] = [accepted_timers[row["session_id"]]
                                   for row in incoming["timer_sessions"] if row["session_id"] in accepted_timers]
    additions["session_intervals"] = [row for row in incoming["session_intervals"]
                                      if row["session_id"] in accepted_timers]
    for row in incoming["activity_events"]:
        if retained("activity_events", row):
            continue
        reason = parent_conflict(row)
        if reason:
            conflict("activity_events", row, reason)
        else:
            additions["activity_events"].append(row)

    added_records = {(kind, row[key]) for kind, table, key in
                     (("activity", "activities", "id"), ("session", "sessions", "id"),
                      ("note", "day_notes", "local_date")) for row in additions[table]}
    for row in incoming["trash"]:
        if retained("trash", row):
            continue
        identity = (row["kind"], row["record_id"])
        if identity in added_records:
            additions["trash"].append(row)
        else:
            conflict("trash", row, "Kept the existing record and Trash state; its deletion was not imported.")
    return additions, duplicates, conflicts, interrupted


def restore_records(store, args):
    """Append compatible canonical records within the caller's transaction."""
    if store.read_only:
        raise StoreError("read_only", "A read-only profile cannot restore records.")
    expected = revision(args.get("expectedRevision"))
    current = store.connection.execute("SELECT revision FROM metadata WHERE id=1").fetchone()[0]
    if expected != current:
        raise StoreError("conflict", "The journal changed. Reload it before restoring.")
    document = _read_document(store, args.get("path"))
    tables = _validate(document)
    additions, duplicates, conflicts, interrupted = _append_plan(_records(store), tables)
    # Foreign owner/checkpoint context remains historical evidence only.
    # Imported running timers become interrupted without counting unknown time;
    # no existing row, owner, clock, or timer state is updated.
    store._backup("before-restore")
    store.connection.execute("SAVEPOINT portability_restore")
    try:
        _insert(store.connection, additions)
        store.connection.execute("UPDATE metadata SET revision=? WHERE id=1", (max(current, document["revision"]),))
        store.connection.execute("RELEASE portability_restore")
    except Exception:
        if store.connection.in_transaction:
            store.connection.execute("ROLLBACK TO portability_restore")
            store.connection.execute("RELEASE portability_restore")
        raise
    return {"format": "json", "counts": {table: len(rows) for table, rows in additions.items()},
            "duplicates": duplicates, "conflicts": conflicts, "interruptedTimers": interrupted}
