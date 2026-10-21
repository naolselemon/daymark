"""Canonical entry insights remain independent of plans, slices and History pages."""

from copy import deepcopy
from datetime import date
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from backend.insights import summarize_entries
from backend.storage import Store


def activity(identifier="a", status="open"):
    return {"id": identifier, "status": status, "title": "SYNTHETIC private title"}


def entry(identifier, recorded_date, owner="a", **fields):
    return dict(id=identifier, activityId=owner, date=recorded_date, **fields)


class EntryInsightTests(unittest.TestCase):
    def test_empty_and_zero_entry_activities_have_complete_zero_bins(self):
        empty = summarize_entries([], [], "2025-01-03")
        self.assertEqual((empty["startDate"], empty["endDate"]), ("2024-12-21", "2025-01-03"))
        self.assertEqual([day["entries"] for day in empty["days"]], [0] * 14)
        self.assertEqual((empty["entryCount"], empty["activeDays"], empty["openActivities"], empty["doneActivities"]), (0, 0, 0, 0))
        self.assertEqual(empty["byActivity"], {})
        self.assertEqual(empty["recentActivityIds"], [])
        result = summarize_entries([activity(), activity("b", "done")], [], "2025-01-03")
        self.assertEqual((result["openActivities"], result["doneActivities"]), (1, 1))
        self.assertEqual(set(result["byActivity"]), {"a", "b"})
        for stats in result["byActivity"].values():
            self.assertEqual(stats, {"entryCount": 0, "activeDays": 0, "firstDate": "", "lastDate": "",
                                     "recentEntries": 0, "recentCounts": [0] * 14})

    def test_distinct_same_date_sessions_count_entries_not_days_without_mutation(self):
        activities = [activity(), activity("b")]
        sessions = [entry("one", "2025-01-06", source="untimed"),
                    entry("two", "2025-01-06", source="manual", minutes=30),
                    entry("three", "2025-01-06", "b"), entry("four", "2025-01-07")]
        original = deepcopy((activities, sessions))
        result = summarize_entries(activities, sessions, "2025-01-07")
        self.assertEqual((activities, sessions), original)
        self.assertEqual((result["entryCount"], result["activeDays"]), (4, 2))
        self.assertEqual(result["byActivity"]["a"], {"entryCount": 3, "activeDays": 2,
                         "firstDate": "2025-01-06", "lastDate": "2025-01-07", "recentEntries": 3,
                         "recentCounts": [0] * 12 + [2, 1]})
        self.assertEqual(result["byActivity"]["b"]["entryCount"], 1)
        self.assertEqual(result["byActivity"]["b"]["recentCounts"], [0] * 12 + [1, 0])
        self.assertEqual([day["entries"] for day in result["days"]],
                         [sum(stats["recentCounts"][index] for stats in result["byActivity"].values())
                          for index in range(14)])

    def test_inclusive_window_edges_exclude_old_and_future_entries_only_from_recent(self):
        sessions = [entry(str(index), day) for index, day in enumerate(
            ["2024-02-17", "2024-02-18", "2024-02-29", "2024-03-02", "2024-03-03"])]
        result = summarize_entries([activity()], sessions, "2024-03-02")
        self.assertEqual([day["date"] for day in result["days"]],
                         ["2024-02-18", "2024-02-19", "2024-02-20", "2024-02-21", "2024-02-22", "2024-02-23", "2024-02-24",
                          "2024-02-25", "2024-02-26", "2024-02-27", "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-02"])
        self.assertEqual([day["entries"] for day in result["days"]], [1] + [0] * 10 + [1, 0, 1])
        self.assertEqual((result["entryCount"], result["activeDays"]), (3, 3))
        self.assertEqual(result["byActivity"]["a"], {"entryCount": 5, "activeDays": 5,
                         "firstDate": "2024-02-17", "lastDate": "2024-03-03", "recentEntries": 3,
                         "recentCounts": [1] + [0] * 10 + [1, 0, 1]})
        maximum = summarize_entries([activity()], [entry("last", "9999-12-31")], "9999-12-31")
        self.assertEqual((maximum["startDate"], maximum["entryCount"]), ("9999-12-18", 1))

    def test_legacy_multiday_sessions_count_once_at_recorded_date_not_interval_dates(self):
        sessions = [entry("timer", "2024-12-25", source="timer", days=[
            {"date": "2025-01-06", "seconds": 30}, {"date": "2025-01-07", "seconds": 20}]),
            entry("manual", "2025-01-06", source="manual", days=[
                {"date": "2025-01-06", "seconds": 1800}, {"date": "2025-01-07", "seconds": 1800}]),
            entry("zero-timer", "2025-01-07", source="timer", days=[], minutes=0)]
        result = summarize_entries([activity()], sessions, "2025-01-08")
        self.assertEqual((result["entryCount"], result["activeDays"]), (2, 2))
        self.assertEqual(result["byActivity"]["a"]["entryCount"], 3)
        self.assertEqual(result["byActivity"]["a"]["recentCounts"], [0] * 11 + [1, 1, 0])

    def test_recent_ids_use_recent_date_then_id_with_five_cap_not_future_or_volume(self):
        activities = [activity(key) for key in ("z", "f", "e", "d", "c", "b", "a", "old", "future")]
        sessions = [entry(key, "2025-01-07", key) for key in ("f", "e", "d", "c", "b", "a")]
        sessions += [entry("z", "2025-01-06", "z"), entry("old", "2024-01-01", "old"),
                     entry("future", "2026-01-01", "future"), entry("future-z", "2026-02-01", "z")]
        sessions += [entry(f"extra-{n}", "2025-01-06", "z") for n in range(10)]
        result = summarize_entries(activities, sessions, "2025-01-07")
        self.assertEqual(result["recentActivityIds"], ["a", "b", "c", "d", "e"])
        self.assertEqual(summarize_entries(list(reversed(activities)), list(reversed(sessions)), "2025-01-07"), result)


class SnapshotInsightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="daylog-insights-")
        self.addCleanup(self.directory.cleanup)
        self.store = Store(Path(self.directory.name) / "journal")
        self.addCleanup(self.store.close)
        self.sequence = 0
        self.date_patch = patch("backend.storage.date", wraps=date)
        self.storage_date = self.date_patch.start()
        self.addCleanup(self.date_patch.stop)
        self.storage_date.today.return_value = date(2025, 1, 7)

    def call(self, op, args=None):
        self.sequence += 1
        return self.store.handle({"protocol": 1, "requestId": f"insight-{self.sequence}",
                                  "clientId": "insight-tests", "op": op, "args": args or {}})

    def create(self, **fields):
        return self.call("create_activity", dict(title="SYNTHETIC insight fixture", **fields))

    def test_snapshot_keeps_window_on_same_day_at_midnight_boundary(self):
        self.storage_date.today.side_effect = [date(2025, 1, 7), date(2025, 1, 8)]
        snapshot = self.call("snapshot")["snapshot"]
        self.assertEqual(snapshot["today"], "2025-01-07")
        self.assertEqual(snapshot["insights"]["endDate"], snapshot["today"])

    def test_planning_rescheduling_entries_and_completion_are_independent(self):
        created = self.create(plannedFor="2025-01-07")
        owner = created["result"]["activityId"]
        initial = created["snapshot"]["insights"]
        self.assertEqual(initial["entryCount"], 0)
        moved = self.call("update_activity", {"activityId": owner, "expectedRevision": 1,
                                               "title": "SYNTHETIC insight fixture", "note": "",
                                               "plannedFor": "2026-01-01"})["snapshot"]
        self.assertEqual(moved["insights"], initial)
        logged = self.call("add_session", {"activityId": owner, "date": "2025-01-06"})["snapshot"]
        self.assertEqual((logged["insights"]["entryCount"], logged["insights"]["openActivities"]), (1, 1))
        completed = self.call("set_done", {"activityId": owner, "done": True})["snapshot"]
        self.assertEqual(completed["sessions"], logged["sessions"])
        self.assertEqual(completed["insights"]["byActivity"], logged["insights"]["byActivity"])
        self.assertEqual((completed["insights"]["openActivities"], completed["insights"]["doneActivities"]), (0, 1))
        after_log = self.call("add_session", {"activityId": owner, "date": "2025-01-07"})["snapshot"]
        self.assertEqual((after_log["insights"]["entryCount"], after_log["insights"]["doneActivities"]), (2, 1))
        reopened = self.call("set_done", {"activityId": owner, "done": False})["snapshot"]
        self.assertEqual(reopened["insights"]["byActivity"], after_log["insights"]["byActivity"])
        self.assertEqual(reopened["activities"][0]["plannedFor"], "2026-01-01")

    def test_date_corrections_move_recent_bins_without_changing_all_time_totals(self):
        created = self.create(mode="log", date="2024-12-24")
        session = created["snapshot"]["sessions"][0]
        owner = session["activityId"]
        self.assertEqual(created["snapshot"]["insights"]["byActivity"][owner]["entryCount"], 1)
        self.assertEqual(created["snapshot"]["insights"]["entryCount"], 0)
        for recorded_date, expected_bins in (
                ("2024-12-25", [1] + [0] * 13),
                ("2025-01-07", [0] * 13 + [1]),
                ("2025-01-08", [0] * 14)):
            with self.subTest(recorded_date=recorded_date):
                corrected = self.call("update_session", {
                    "sessionId": session["id"], "expectedRevision": session["revision"],
                    "date": recorded_date, "minutes": None, "note": "SYNTHETIC date correction"})["snapshot"]
                session = corrected["sessions"][0]
                insights = corrected["insights"]
                stats = insights["byActivity"][owner]
                self.assertEqual([day["entries"] for day in insights["days"]], expected_bins)
                self.assertEqual(stats["recentCounts"], expected_bins)
                self.assertEqual((insights["entryCount"], stats["recentEntries"]), (sum(expected_bins), sum(expected_bins)))
                self.assertEqual((stats["entryCount"], stats["activeDays"], stats["firstDate"], stats["lastDate"]),
                                 (1, 1, recorded_date, recorded_date))

    def test_deleted_sessions_and_activities_leave_and_restore_snapshot_counts(self):
        created = self.create(mode="log", date="2025-01-07")
        snapshot = created["snapshot"]
        baseline = snapshot["insights"]
        session = snapshot["sessions"][0]
        removed = self.call("delete_record", {"kind": "session", "id": session["id"], "expectedRevision": session["revision"]})
        self.assertEqual(removed["snapshot"]["insights"]["entryCount"], 0)
        self.assertEqual([day["entries"] for day in removed["snapshot"]["insights"]["days"]], [0] * 14)
        self.assertEqual(removed["snapshot"]["insights"]["byActivity"][session["activityId"]]["recentCounts"], [0] * 14)
        self.assertEqual(removed["snapshot"]["insights"]["byActivity"][session["activityId"]]["firstDate"], "")
        restored = self.call("undo_delete", {"trashId": removed["result"]["trashId"]})["snapshot"]
        self.assertEqual(restored["insights"], baseline)
        owner = restored["activities"][0]
        removed = self.call("delete_record", {"kind": "activity", "id": owner["id"], "expectedRevision": owner["revision"]})
        hidden = removed["snapshot"]["insights"]
        self.assertEqual((hidden["entryCount"], hidden["openActivities"]), (0, 0))
        self.assertEqual(hidden["byActivity"], {})
        self.assertEqual(hidden["recentActivityIds"], [])
        restored = self.call("undo_delete", {"trashId": removed["result"]["trashId"]})["snapshot"]
        self.assertEqual(restored["insights"], baseline)

    def test_all_records_count_beyond_history_page_and_ignore_history_filters(self):
        owner = self.create()["result"]["activityId"]
        self.store.connection.executemany(
            "INSERT INTO sessions (id,activity_id,local_date,minutes,note,source,created_at) VALUES (?,?,'2025-01-06',NULL,?,'untimed','2025-01-06T12:00:00Z')",
            [(f"insight-fixture-{n:04}", owner, f"SYNTHETIC entry {n}") for n in range(205)])
        response = self.call("history")
        self.assertEqual(len(response["result"]["sessions"]), 100)
        self.assertEqual(response["result"]["total"], 205)
        insights = response["snapshot"]["insights"]
        self.assertEqual((insights["entryCount"], insights["activeDays"]), (205, 1))
        self.assertEqual(insights["byActivity"][owner]["entryCount"], 205)
        self.assertEqual(insights["byActivity"][owner]["recentCounts"], [0] * 12 + [205, 0])
        filtered = self.call("history", {"query": "no matching entry", "from": "2026-01-01"})
        self.assertEqual(filtered["result"]["total"], 0)
        self.assertEqual(filtered["snapshot"]["insights"], insights)


if __name__ == "__main__":
    unittest.main()
