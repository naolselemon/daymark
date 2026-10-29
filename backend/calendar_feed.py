#!/usr/bin/env python3
"""Read-only Google iCalendar feed; private cache, never journal history."""
import argparse
from contextlib import closing
from datetime import date, datetime, time as day_time, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
import sqlite3
import stat
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

if __name__ == "__main__":
    sys.dont_write_bytecode = True

try:
    from .storage import StoreError, profile_path, storage_error
except ImportError:
    from storage import StoreError, profile_path, storage_error

OPERATIONS = {"calendar_status", "calendar_configure", "calendar_refresh", "calendar_disconnect"}
MAX_BYTES = 2 * 1024 * 1024
MAX_EVENTS = 2000
DEFAULT = {"revision": 0, "url": "", "name": "Google Calendar", "enabled": 0,
           "body": b"", "etag": "", "modified": "", "last_checked": 0,
           "last_success": 0, "error": ""}


def feed_url(value):
    if not isinstance(value, str) or len(value) > 4096 or any(ord(c) < 33 for c in value):
        raise StoreError("validation", "Enter a Google Calendar iCalendar feed address.")
    try:
        parsed = urlsplit(value)
        valid = (parsed.scheme == "https" and parsed.hostname == "calendar.google.com"
                 and parsed.port in (None, 443) and not parsed.username and not parsed.password
                 and not parsed.query and not parsed.fragment
                 and parsed.path.startswith("/calendar/ical/") and parsed.path.endswith(".ics")
                 and "\\" not in value)
    except ValueError:
        valid = False
    if not valid:
        raise StoreError("validation", "Use the HTTPS iCalendar address from Google Calendar settings, not a sharing or sign-in link.")
    return value


class FeedRedirects(HTTPRedirectHandler):
    max_redirections = 3
    max_repeats = 1

    def redirect_request(self, request, fp, code, message, headers, new_url):
        feed_url(new_url)
        return super().redirect_request(request, fp, code, message, headers, new_url)


def fetch_feed(url, etag="", modified=""):
    headers = {"Accept": "text/calendar", "Accept-Encoding": "identity", "User-Agent": "Daymark-Calendar/1"}
    if etag:
        headers["If-None-Match"] = etag
    if modified:
        headers["If-Modified-Since"] = modified
    try:
        with build_opener(FeedRedirects()).open(Request(feed_url(url), headers=headers), timeout=8) as response:
            if response.status != 200:
                raise StoreError("network", "Google Calendar did not return a calendar feed.")
            if response.headers.get("Content-Encoding", "identity").lower() not in ("", "identity"):
                raise StoreError("network", "The calendar response used an unsupported transfer encoding.")
            body = response.read(MAX_BYTES + 1)
            if len(body) > MAX_BYTES:
                raise StoreError("limit", "The calendar feed exceeds the 2 MiB limit. Existing events were kept.")
            return body, response.headers.get("ETag", "")[:1024], response.headers.get("Last-Modified", "")[:128]
    except HTTPError as error:
        if error.code == 304 and (etag or modified):
            return None, etag, modified
        if error.code in (401, 403, 404):
            raise StoreError("network", "Google Calendar could not provide this feed. Check its private iCalendar address and sharing permissions.") from None
        raise StoreError("network", "Google Calendar is unavailable. Existing events were kept.") from None
    except (URLError, TimeoutError, OSError, ValueError):
        raise StoreError("network", "Could not refresh Google Calendar. Check your connection; existing events were kept.") from None


def local_timezone():
    name = os.environ.get("TZ", "").removeprefix(":")
    if name:
        try:
            return ZoneInfo(name)
        except (ValueError, ZoneInfoNotFoundError):
            pass
    with Path("/etc/localtime").open("rb") as stream:
        return ZoneInfo.from_file(stream)


def view_window(value):
    try:
        if value is not None and not isinstance(value, str):
            raise ValueError()
        selected = date.fromisoformat(value) if isinstance(value, str) else date.today()
        if isinstance(value, str) and selected.isoformat() != value:
            raise ValueError()
        return selected - timedelta(days=30), selected + timedelta(days=90)
    except (ValueError, OverflowError):
        raise StoreError("validation", "Choose a valid calendar date with room for the calendar window.") from None


def project_events(body, first, last, zone=None):
    try:
        import icalendar
        import recurring_ical_events
    except ImportError:
        raise StoreError("dependencies", "Calendar support needs the dependencies in requirements-calendar.txt. Other Daymark features remain available.") from None
    zone = zone or local_timezone()
    try:
        calendar = icalendar.Calendar.from_ical(body)
        if calendar.name != "VCALENDAR" or calendar.errors:
            raise ValueError()
        originals = calendar.walk("VEVENT")
        for event in originals:
            if event.errors or not event.get("UID"):
                raise ValueError()
            if not event.get("DTSTART") and not (event.get("RECURRENCE-ID") and str(event.get("STATUS", "")).upper() == "CANCELLED"):
                raise ValueError()
        beginning = datetime.combine(first, day_time.min, zone)
        ending = datetime.combine(last + timedelta(days=1), day_time.min, zone)
        occurrences = recurring_ical_events.of(calendar).between(beginning, ending)
        if len(occurrences) > MAX_EVENTS:
            raise StoreError("limit", "This calendar window exceeds 2,000 occurrences. Existing events were kept.")
        result = {}
        for event in occurrences:
            if str(event.get("STATUS", "")).upper() == "CANCELLED":
                continue
            start = event.decoded("DTSTART")
            end = event.decoded("DTEND", None)
            all_day = isinstance(start, date) and not isinstance(start, datetime)
            if end is None:
                duration = event.decoded("DURATION", timedelta(days=1) if all_day else timedelta())
                end = start + duration
            if all_day:
                if isinstance(end, datetime) or not isinstance(end, date) or end <= start:
                    raise ValueError()
                start_day, end_day = start, end - timedelta(days=1)
                start_time = end_time = ""
            else:
                if not isinstance(start, datetime) or not isinstance(end, datetime):
                    raise ValueError()
                # Floating times are local; TZID/UTC events retain their actual instant.
                start = start.replace(tzinfo=zone) if start.tzinfo is None else start.astimezone(zone)
                end = end.replace(tzinfo=zone) if end.tzinfo is None else end.astimezone(zone)
                start_instant, end_instant = start.astimezone(timezone.utc), end.astimezone(timezone.utc)
                if end_instant < start_instant:
                    raise ValueError()
                start_day = start.date()
                end_day = ((end_instant - timedelta(microseconds=1)).astimezone(zone).date()
                           if end_instant > start_instant else start_day)
                start_time, end_time = start.strftime("%H:%M"), end.strftime("%H:%M")
            if start_day > last or end_day < first:
                continue
            title = str(event.get("SUMMARY", "Untitled event")).strip() or "Untitled event"
            if len(title) > 4096:
                raise ValueError()
            recurrence = event.get("RECURRENCE-ID")
            identity = str(event["UID"]) + "\n" + (str(recurrence.to_ical()) if recurrence else start.isoformat())
            key = hashlib.sha256(identity.encode("utf-8")).hexdigest()
            result[key] = {"id": key, "title": title, "startDate": start_day.isoformat(),
                           "endDate": end_day.isoformat(), "allDay": all_day,
                           "startTime": start_time, "endTime": end_time,
                           "endTimeDate": "" if all_day else end.date().isoformat()}
        return sorted(result.values(), key=lambda event: (event["startDate"], not event["allDay"], event["startTime"], event["id"]))
    except StoreError:
        raise
    except Exception:
        raise StoreError("calendar", "The feed contains invalid or unsupported calendar data. Existing events were kept.") from None


class CalendarStore:
    def __init__(self, profile=None, read_only=False, fetch=fetch_feed, now=time.time, zone=None):
        self.path = profile_path(profile) / "calendar.sqlite3"
        self.read_only, self.fetch, self.now, self.zone = read_only, fetch, now, zone

    def check_paths(self):
        for suffix in ("", "-journal", "-wal", "-shm"):
            if self.path.with_name(self.path.name + suffix).is_symlink():
                raise StoreError("storage", "A calendar database symlink is not supported.")
        if self.path.exists() and not self.path.is_file():
            raise StoreError("storage", "Calendar settings must be in a regular database file.")

    def read(self):
        self.check_paths()
        if not self.path.exists():
            return dict(DEFAULT)
        with closing(sqlite3.connect(self.path.as_uri() + "?mode=ro", uri=True, timeout=5)) as db:
            db.row_factory = sqlite3.Row
            if db.execute("PRAGMA user_version").fetchone()[0] != 1 or db.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise StoreError("storage", "Calendar settings are damaged or use an unsupported schema. They were not replaced.")
            row = db.execute("SELECT * FROM feed WHERE id=1").fetchone()
            if row is None:
                raise StoreError("storage", "Calendar settings are incomplete. They were not replaced.")
            result = dict(row)
            result.pop("id")
            return result

    def write(self, state, expected):
        if self.read_only:
            raise StoreError("read_only", "Calendar settings are read-only.")
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.check_paths()
        created = False
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        except FileExistsError:
            self.check_paths()
        else:
            os.close(fd)
            created = True
        for path, mode in ((self.path.parent, 0o700), (self.path, 0o600)):
            if stat.S_IMODE(path.stat().st_mode) != mode:
                path.chmod(mode)
        with closing(sqlite3.connect(self.path.as_uri() + "?mode=rw", uri=True, timeout=5)) as db:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA secure_delete=ON")
            db.execute("BEGIN IMMEDIATE")
            try:
                if created:
                    db.execute("""CREATE TABLE feed (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
                        url TEXT NOT NULL, name TEXT NOT NULL, enabled INTEGER NOT NULL, body BLOB NOT NULL,
                        etag TEXT NOT NULL, modified TEXT NOT NULL, last_checked REAL NOT NULL,
                        last_success REAL NOT NULL, error TEXT NOT NULL)""")
                    db.execute("PRAGMA user_version=1")
                    db.execute("INSERT INTO feed VALUES (1,:revision,:url,:name,:enabled,:body,:etag,:modified,:last_checked,:last_success,:error)", DEFAULT)
                if db.execute("PRAGMA user_version").fetchone()[0] != 1:
                    raise StoreError("storage", "Calendar settings use an unsupported schema.")
                state = dict(state, revision=expected + 1)
                changed = db.execute("""UPDATE feed SET revision=:revision,url=:url,name=:name,enabled=:enabled,
                    body=:body,etag=:etag,modified=:modified,last_checked=:last_checked,
                    last_success=:last_success,error=:error WHERE id=1 AND revision=:expected""", dict(state, expected=expected))
                if changed.rowcount != 1:
                    raise StoreError("conflict", "Calendar settings changed during this request. Refresh before trying again.")
                db.commit()
            except Exception:
                db.rollback()
                raise
        return state

    def result(self, state, first, last, events=None):
        error = state["error"]
        if events is None:
            events = []
            if state["url"] and state["body"]:
                try:
                    events = project_events(state["body"], first, last, self.zone)
                except StoreError as failure:
                    error = failure.message
        return {"configured": bool(state["url"]), "name": state["name"], "enabled": bool(state["enabled"]),
                "lastCheckedAt": state["last_checked"], "lastSuccessAt": state["last_success"],
                "error": error, "windowStart": first.isoformat(), "windowEnd": last.isoformat(), "events": events}

    def handle(self, request):
        op, args = request.get("op"), request.get("args")
        if op not in OPERATIONS or not isinstance(args, dict):
            raise StoreError("protocol", "Unknown calendar request.")
        allowed = {"url", "name", "enabled", "date"} if op == "calendar_configure" else {"date"}
        if set(args) - allowed:
            raise StoreError("validation", "Unknown calendar arguments.")
        first, last = view_window(args.get("date"))
        previous = self.read()
        if op == "calendar_status":
            return self.result(previous, first, last)
        if self.read_only:
            raise StoreError("read_only", "Calendar settings are read-only.")
        if op == "calendar_disconnect":
            if previous["url"]:
                previous = self.write(dict(DEFAULT), previous["revision"])
            return self.result(previous, first, last, [])
        state = dict(previous)
        if op == "calendar_configure":
            state["url"] = feed_url(args.get("url"))
            name = args.get("name", "").strip() if isinstance(args.get("name", ""), str) else None
            if name is None or len(name) > 160 or any(ord(c) < 32 for c in name):
                raise StoreError("validation", "Use a short calendar name without control characters.")
            if type(args.get("enabled", True)) is not bool:
                raise StoreError("validation", "Calendar enabled must be true or false.")
            state.update(name=name or "Google Calendar", enabled=int(args.get("enabled", True)), etag="", modified="")
        elif not state["url"]:
            raise StoreError("validation", "Connect a calendar first.")
        try:
            body, etag, modified = self.fetch(state["url"], state["etag"], state["modified"])
            if body is None:
                body = previous["body"]
            if not isinstance(body, bytes) or not body or len(body) > MAX_BYTES:
                raise StoreError("calendar", "The feed did not contain a usable calendar. Existing events were kept.")
            events = project_events(body, first, last, self.zone)
        except StoreError as failure:
            if op == "calendar_refresh":
                self.write(dict(previous, last_checked=self.now(), error=failure.message), previous["revision"])
            raise
        stamp = self.now()
        state.update(body=body, etag=etag, modified=modified, last_checked=stamp, last_success=stamp, error="")
        state = self.write(state, previous["revision"])
        return self.result(state, first, last, events)


def use_calendar_runtime():
    """Use an explicitly installed user environment without installing anything."""
    if all(importlib.util.find_spec(name) for name in ("icalendar", "recurring_ical_events")):
        return
    data_home = os.environ.get("XDG_DATA_HOME", "")
    base = Path(data_home) if Path(data_home).is_absolute() else Path.home() / ".local/share"
    runtime = base / "daylog-calendar-runtime"
    executable = runtime / "bin/python"
    if Path(sys.prefix) != runtime and executable.is_file() and os.access(executable, os.X_OK):
        os.execv(str(executable), [str(executable), str(Path(__file__).resolve()), *sys.argv[1:]])


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise StoreError("protocol", "Calendar requests cannot contain duplicate keys.")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description="Daymark read-only Google Calendar feed")
    parser.add_argument("--profile")
    parser.add_argument("--read-only", action="store_true")
    options = parser.parse_args()
    use_calendar_runtime()
    # Bound untrusted recurrence expansion in this short-lived child, not the shell.
    resource.setrlimit(resource.RLIMIT_CPU, (10, 12))
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    request_id = ""
    try:
        line = sys.stdin.buffer.readline(16385)
        if len(line) > 16384 or sys.stdin.buffer.read(1):
            raise StoreError("protocol", "Send one bounded calendar request.")
        request = json.loads(line, object_pairs_hook=unique_object)
        if not isinstance(request, dict) or request.get("protocol") != 1 or not isinstance(request.get("requestId"), str):
            raise StoreError("protocol", "Invalid calendar request.")
        request_id = request["requestId"]
        if not request_id or len(request_id) > 200:
            request_id = ""
            raise StoreError("protocol", "Invalid calendar request identity.")
        result = CalendarStore(options.profile, options.read_only).handle(request)
        response = {"protocol": 1, "requestId": request_id, "ok": True, "result": result}
    except StoreError as failure:
        response = {"protocol": 1, "requestId": request_id, "ok": False, "error": failure.wire()}
    except (sqlite3.Error, OSError) as failure:
        response = {"protocol": 1, "requestId": request_id, "ok": False, "error": storage_error(failure).wire()}
    except Exception:
        response = {"protocol": 1, "requestId": request_id, "ok": False,
                    "error": {"code": "calendar", "message": "The calendar request could not be completed safely. Existing journal records were not changed."}}
    sys.stdout.write(json.dumps(response, ensure_ascii=True, allow_nan=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
