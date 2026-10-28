"""Calendar behavior against synthetic feeds and isolated private caches."""
from contextlib import closing
from datetime import date
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

from backend.calendar_feed import CalendarStore, FeedRedirects, feed_url, project_events, view_window
from backend.storage import SOURCE_ROOT, Store, StoreError

URL = "https://calendar.google.com/calendar/ical/synthetic%40example.test/private-0123456789abcdef/basic.ics"


def calendar(*events, extra=""):
    return ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Daymark//Isolated test//EN\r\n" + extra
            + "".join("BEGIN:VEVENT\r\n" + event + "\r\nEND:VEVENT\r\n" for event in events)
            + "END:VCALENDAR\r\n").encode()


SINGLE = calendar("UID:synthetic-one\r\nDTSTART:20261029T230000Z\r\nDTEND:20261030T010000Z\r\nSUMMARY:Synthetic late event")


class CalendarProjectionTests(unittest.TestCase):
    def project(self, body, zone="UTC", first="2026-10-01", last="2026-11-30"):
        return project_events(body, date.fromisoformat(first), date.fromisoformat(last), ZoneInfo(zone))

    def test_timed_events_use_local_dates_and_preserve_midnight_end_exclusion(self):
        event = self.project(SINGLE, "Africa/Addis_Ababa")[0]
        self.assertEqual((event["startDate"], event["endDate"], event["startTime"], event["endTime"]),
                         ("2026-10-30", "2026-10-30", "02:00", "04:00"))
        midnight = calendar("UID:midnight\r\nDTSTART:20261029T220000Z\r\nDTEND:20261030T000000Z\r\nSUMMARY:Ends at midnight")
        event = self.project(midnight)[0]
        self.assertEqual((event["startDate"], event["endDate"]), ("2026-10-29", "2026-10-29"))
        self.assertEqual(event["endTimeDate"], "2026-10-30")
        self.assertEqual(self.project(midnight, first="2026-10-30", last="2026-10-31"), [])

    def test_fall_back_event_compares_instants_not_repeated_wall_times(self):
        body = calendar("UID:fold\r\nDTSTART:20261101T053000Z\r\nDTEND:20261101T061500Z\r\nSUMMARY:Across repeated hour")
        event = self.project(body, "America/New_York")[0]
        self.assertEqual((event["startDate"], event["endDate"]), ("2026-11-01", "2026-11-01"))
        self.assertEqual((event["startTime"], event["endTime"]), ("01:30", "01:15"))

    def test_all_day_dates_do_not_shift_with_timezone_and_end_is_exclusive(self):
        body = calendar("UID:all-day\r\nDTSTART;VALUE=DATE:20261029\r\nDTEND;VALUE=DATE:20261101\r\nSUMMARY:Three days")
        for zone in ("UTC", "Pacific/Auckland", "America/Los_Angeles"):
            event = self.project(body, zone)[0]
            self.assertEqual((event["startDate"], event["endDate"], event["allDay"]), ("2026-10-29", "2026-10-31", True))
            self.assertEqual((event["startTime"], event["endTime"]), ("", ""))
        self.assertEqual(len(self.project(body, first="2026-10-30", last="2026-10-30")), 1)

    def test_recurrence_exclusion_override_and_dst(self):
        body = calendar(
            "UID:weekly\r\nDTSTART;TZID=America/New_York:20261025T090000\r\nDTEND;TZID=America/New_York:20261025T100000\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nEXDATE;TZID=America/New_York:20261101T090000\r\nSUMMARY:Weekly",
            "UID:weekly\r\nRECURRENCE-ID;TZID=America/New_York:20261108T090000\r\nDTSTART;TZID=America/New_York:20261108T103000\r\nDTEND;TZID=America/New_York:20261108T113000\r\nSUMMARY:Moved occurrence")
        events = self.project(body)
        self.assertEqual([(e["startDate"], e["startTime"], e["title"]) for e in events],
                         [("2026-10-25", "13:00", "Weekly"), ("2026-11-08", "15:30", "Moved occurrence")])
        self.assertNotEqual(events[0]["id"], events[1]["id"])
        self.assertEqual(self.project(body), events)

    def test_cancelled_occurrence_is_absent(self):
        body = calendar(
            "UID:daily\r\nDTSTART:20261029T090000Z\r\nDTEND:20261029T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Daily",
            "UID:daily\r\nRECURRENCE-ID:20261030T090000Z\r\nDTSTART:20261030T090000Z\r\nDTEND:20261030T100000Z\r\nSTATUS:CANCELLED\r\nSUMMARY:Cancelled")
        self.assertEqual([e["startDate"] for e in self.project(body)], ["2026-10-29", "2026-10-31"])

    def test_floating_events_use_calendar_timezone_and_unicode_is_plain(self):
        body = calendar("UID:floating\r\nDTSTART:20261029T090000\r\nDTEND:20261029T100000\r\nSUMMARY:<b>ሰላም</b>",
                        extra="X-WR-TIMEZONE:Africa/Addis_Ababa\r\n")
        event = self.project(body)[0]
        self.assertEqual(event["startTime"], "06:00")
        self.assertEqual(event["title"], "<b>ሰላም</b>")

    def test_invalid_calendar_is_not_accepted_as_an_empty_calendar(self):
        for body in (b"<html>Sign in</html>", calendar("UID:bad\r\nSUMMARY:Missing date")):
            with self.subTest(body=body), self.assertRaises(StoreError):
                self.project(body)
        self.assertEqual(self.project(calendar()), [])

    def test_occurrence_limit_rejects_instead_of_silently_truncating(self):
        body = calendar("UID:frequent\r\nDTSTART:20261029T000000Z\r\nDTEND:20261029T000100Z\r\nRRULE:FREQ=MINUTELY;COUNT=2001\r\nSUMMARY:Frequent")
        with self.assertRaises(StoreError) as failure:
            self.project(body)
        self.assertEqual(failure.exception.code, "limit")

    def test_window_and_url_boundary_validation(self):
        self.assertEqual(view_window("2026-10-29"), (date(2026, 9, 29), date(2027, 1, 27)))
        for value in ("2026-02-30", "20261029", 12, "0001-01-01", "9999-12-31"):
            with self.subTest(value=value), self.assertRaises(StoreError):
                view_window(value)
        self.assertEqual(feed_url(URL), URL)
        for value in ("file:///tmp/private.ics", "http://calendar.google.com/calendar/ical/x.ics",
                      "https://calendar.google.com.evil.test/calendar/ical/x.ics",
                      "https://me:secret@calendar.google.com/calendar/ical/x.ics",
                      URL + "?secret=x", URL + "#fragment", URL + "\n", "https://127.0.0.1/private.ics"):
            with self.subTest(value=value), self.assertRaises(StoreError):
                feed_url(value)

    def test_redirect_cannot_forward_private_link_to_another_host(self):
        with self.assertRaises(StoreError):
            FeedRedirects().redirect_request(None, None, 302, "Found", {}, "https://example.test/stolen.ics")


class CalendarStorageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="daymark-calendar-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.profile = self.root / "profile"
        self.body = SINGLE
        self.tick = 1000
        self.failure = None
        self.calls = 0
        self.store = CalendarStore(self.profile, fetch=self.fetch, now=lambda: self.tick, zone=ZoneInfo("UTC"))

    def fetch(self, url, etag, modified):
        self.calls += 1
        if self.failure:
            raise self.failure
        return self.body, '"synthetic"', ""

    def call(self, op="status", **args):
        return self.store.handle({"op": "calendar_" + op, "args": dict(date="2026-10-29", **args)})

    def connect(self):
        return self.call("configure", url=URL, name="Synthetic calendar", enabled=True)

    def test_unconfigured_status_is_offline_and_does_not_create_a_profile(self):
        result = self.call()
        self.assertFalse(result["configured"])
        self.assertEqual(result["events"], [])
        self.assertEqual(self.calls, 0)
        self.assertFalse(self.profile.exists())

    def test_private_cache_and_response_exclusion_without_journal_mutation(self):
        result = self.connect()
        self.assertEqual(result["events"][0]["title"], "Synthetic late event")
        self.assertNotIn(URL, json.dumps(result))
        self.assertNotIn("private-", json.dumps(result))
        self.assertFalse((self.profile / "daylog.sqlite3").exists())
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.profile.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.call()["events"], result["events"])
        self.assertEqual(self.calls, 1)

    def test_refresh_replaces_changed_and_cancelled_events_without_duplicates(self):
        before = self.connect()
        self.tick = 2000
        self.body = calendar("UID:synthetic-one\r\nDTSTART:20261030T100000Z\r\nDTEND:20261030T110000Z\r\nSUMMARY:Rescheduled")
        changed = self.call("refresh")
        self.assertEqual([(e["title"], e["startDate"]) for e in changed["events"]], [("Rescheduled", "2026-10-30")])
        self.assertEqual(self.call("refresh")["events"], changed["events"])
        self.assertEqual(changed["lastSuccessAt"], 2000)
        self.body = calendar()
        self.assertEqual(self.call("refresh")["events"], [])
        self.assertEqual(before["events"][0]["title"], "Synthetic late event")

    def test_network_and_parse_failures_keep_last_good_cache_and_attempt_time(self):
        before = self.connect()
        self.tick = 2000
        self.failure = StoreError("network", "Could not refresh. Existing events were kept.")
        with self.assertRaises(StoreError):
            self.call("refresh")
        saved = self.call()
        self.assertEqual(saved["events"], before["events"])
        self.assertEqual((saved["lastCheckedAt"], saved["lastSuccessAt"]), (2000, 1000))
        self.assertTrue(saved["error"])
        self.failure, self.body = None, b"not a calendar"
        with self.assertRaises(StoreError):
            self.call("refresh")
        self.assertEqual(self.call()["events"], before["events"])

    def test_failed_reconfiguration_keeps_original_connection(self):
        before = self.connect()
        self.body = b"invalid"
        with self.assertRaises(StoreError):
            self.call("configure", url=URL.replace("0123456789abcdef", "abcdef0123456789"), name="Replacement")
        self.assertEqual(self.call(), before)

    def test_disconnect_wins_over_inflight_refresh(self):
        self.connect()
        second = CalendarStore(self.profile, zone=ZoneInfo("UTC"))
        def disconnect_during_fetch(*unused):
            second.handle({"op": "calendar_disconnect", "args": {}})
            return SINGLE, "", ""
        self.store.fetch = disconnect_during_fetch
        with self.assertRaises(StoreError) as failure:
            self.call("refresh")
        self.assertEqual(failure.exception.code, "conflict")
        self.assertFalse(self.call()["configured"])
        self.assertEqual(self.call()["events"], [])
        with closing(sqlite3.connect(self.store.path)) as connection:
            self.assertEqual(connection.execute("SELECT url,body FROM feed").fetchone(), ("", b""))

    def test_read_only_and_symlink_refusal_preserve_existing_files(self):
        self.connect()
        original = self.store.path.read_bytes()
        read_only = CalendarStore(self.profile, read_only=True, zone=ZoneInfo("UTC"))
        self.assertTrue(read_only.handle({"op": "calendar_status", "args": {}})["configured"])
        with self.assertRaises(StoreError):
            read_only.handle({"op": "calendar_disconnect", "args": {}})
        self.assertEqual(self.store.path.read_bytes(), original)
        linked = self.root / "linked"
        linked.mkdir()
        (linked / "calendar.sqlite3").symlink_to(self.store.path)
        with self.assertRaises(StoreError):
            CalendarStore(linked).handle({"op": "calendar_status", "args": {}})
        self.assertEqual(self.store.path.read_bytes(), original)

    def test_conditional_not_modified_keeps_events_and_acknowledges_refresh(self):
        before = self.connect()
        self.body = None
        self.tick = 2000
        result = self.call("refresh")
        self.assertEqual(result["events"], before["events"])
        self.assertEqual(result["lastSuccessAt"], 2000)

    def test_calendar_secrets_are_not_in_activity_or_diary_exports(self):
        self.connect()
        with Store(self.profile) as journal:
            for scope in ("activities", "diary"):
                path = self.root / (scope + ".json")
                journal.handle({"protocol": 1, "requestId": scope, "op": "export_records",
                                "args": {"path": str(path), "format": "json", "scope": scope}})
                exported = path.read_text()
                self.assertNotIn("private-", exported)
                self.assertNotIn("Synthetic late event", exported)
                self.assertNotIn("calendar.sqlite3", exported)
            snapshot = journal.handle({"protocol": 1, "requestId": "snapshot", "op": "snapshot", "args": {}})["snapshot"]
            self.assertEqual((snapshot["activities"], snapshot["sessions"]), ([], []))

    def test_cli_status_is_safe_offline_and_reports_validation_without_secret_echo(self):
        request = {"protocol": 1, "requestId": "calendar-cli", "op": "calendar_configure", "args": {"url": "https://evil.test/private-secret.ics"}}
        process = subprocess.run([sys.executable, str(SOURCE_ROOT / "backend/calendar_feed.py"), "--profile", str(self.profile)],
                                 input=json.dumps(request), capture_output=True, text=True, timeout=15)
        self.assertEqual(process.returncode, 0, process.stderr)
        response = json.loads(process.stdout)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "validation")
        self.assertNotIn("private-secret", process.stdout + process.stderr)
        self.assertFalse(self.profile.exists())


if __name__ == "__main__":
    unittest.main()
