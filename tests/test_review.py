"""Deterministic review regressions against canonical and isolated store snapshots."""

from copy import deepcopy
from datetime import datetime
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from backend.review import interval_days, manual_days, summarize, union_seconds, weekly_review
from backend.storage import Store, StoreError


def activity(identifier="a", category="Coding", project="Fixture", completed=""):
    return {"id": identifier, "title": "Synthetic review activity", "category": category,
            "project": project, "status": "done" if completed else "open", "completedDate": completed,
            "completedAt": completed + "T12:00:00Z" if completed else "", "plannedFor": "2040-01-01"}


def manual(identifier, start, end, owner="a", zone="UTC", offset=0):
    return {"id": identifier, "activityId": owner, "source": "manual", "date": start[:10],
            "startUtc": start, "endUtc": end, "timeZone": zone, "offsetSeconds": offset,
            "minutes": (datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp()
                        - datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()) / 60}


def reported(identifier="reported", minutes=30, owner="a", day="2025-01-01"):
    return {"id": identifier, "activityId": owner, "source": "untimed" if minutes is None else "manual",
            "date": day, "minutes": minutes, "startUtc": "", "endUtc": ""}


def interval(start, seconds, zone="UTC", offset=0, day=None):
    return {"startUtc": start, "endUtc": "2040-01-01T00:00:00Z", "durationSeconds": seconds,
            "timeZone": zone, "offsetSeconds": offset, "localDate": day or start[:10]}


def timer(intervals, identifier="timer", owner="a"):
    return {"id": identifier, "activityId": owner, "source": "timer", "date": intervals[0]["localDate"],
            "intervals": intervals, "minutes": sum(i["durationSeconds"] for i in intervals) / 60,
            "elapsedSeconds": 999999, "status": "interrupted"}


def day_totals(result):
    return {row["date"]: row for row in result["days"]}


class ReviewAccountingTests(unittest.TestCase):
    def test_union_handles_unsorted_nested_adjacent_zero_and_disjoint_spans_without_mutation(self):
        spans = [(12, 13), (2, 6), (0, 4), (7, 7), (1, 2), (6, 9)]
        original = list(spans)
        self.assertEqual(union_seconds(spans), 10)
        self.assertEqual(spans, original)
        self.assertEqual(union_seconds([]), 0)

    def test_clock_union_reported_duration_untimed_and_category_totals_are_distinct(self):
        activities = [activity(), activity("b", "Reading")]
        sessions = [manual("one", "2025-01-01T10:00:00Z", "2025-01-01T11:00:00Z"),
                    manual("two", "2025-01-01T10:30:00Z", "2025-01-01T11:30:00Z", "b"),
                    reported(), reported("untimed", None, "b")]
        original = deepcopy((activities, sessions))
        result = summarize(activities, sessions)
        self.assertEqual(result["clockSeconds"], 5400)
        self.assertEqual(result["reportedSeconds"], 1800)
        self.assertEqual(result["loggedSeconds"], 7200)
        self.assertEqual(result["overlapSeconds"], 1800)
        self.assertTrue(result["hasOverlaps"])
        self.assertEqual(result["untimedSessions"], 1)
        self.assertEqual(result["sessionCount"], 4)
        self.assertEqual(result["categories"], [
            {"name": "Coding", "clockSeconds": 3600, "reportedSeconds": 1800,
             "loggedSeconds": 5400, "untimedSessions": 0},
            {"name": "Reading", "clockSeconds": 3600, "reportedSeconds": 0,
             "loggedSeconds": 3600, "untimedSessions": 1}])
        self.assertEqual(result["days"][0]["overlapSeconds"], 1800)
        self.assertEqual((activities, sessions), original)

    def test_same_category_union_is_not_sum_of_its_sessions(self):
        result = summarize([activity()], [
            manual("one", "2025-01-01T10:00:00Z", "2025-01-01T12:00:00Z"),
            manual("two", "2025-01-01T10:30:00Z", "2025-01-01T11:00:00Z")])
        self.assertEqual(result["categories"][0]["clockSeconds"], 7200)
        self.assertEqual(result["overlapSeconds"], 1800)

    def test_midnight_splits_actual_time_without_duplicating_session(self):
        session = manual("night", "2025-01-05T23:30:00Z", "2025-01-06T01:00:00Z")
        result = summarize([activity()], [session])
        self.assertEqual(result["sessionCount"], 1)
        self.assertEqual(result["clockSeconds"], 5400)
        self.assertEqual({day: row["clockSeconds"] for day, row in day_totals(result).items()},
                         {"2025-01-05": 1800, "2025-01-06": 3600})
        result = summarize([activity()], [session], "2025-01-06", "2025-01-06")
        self.assertEqual(result["clockSeconds"], 3600)
        self.assertEqual(result["sessionCount"], 1)

    def test_exact_midnight_end_does_not_create_next_day_entry(self):
        self.assertEqual(manual_days("2025-01-01T23:00:00Z", "2025-01-02T00:00:00Z", "UTC"),
                         [{"date": "2025-01-01", "seconds": 3600}])

    def test_dst_full_days_have_actual_23_and_25_hours(self):
        for start, end, seconds in [
            ("2025-03-09T00:00:00-05:00", "2025-03-10T00:00:00-04:00", 23 * 3600),
            ("2025-11-02T00:00:00-04:00", "2025-11-03T00:00:00-05:00", 25 * 3600),
        ]:
            with self.subTest(start=start):
                expected = [{"date": start[:10], "seconds": seconds}]
                self.assertEqual(manual_days(start, end, "America/New_York"), expected)
                self.assertEqual(interval_days(start, seconds, "America/New_York"), expected)
                result = summarize([activity()], [manual("dst", start, end, zone="America/New_York")])
                self.assertEqual(result["clockSeconds"], seconds)

    def test_dst_fold_overlaps_in_physical_time_not_displayed_clock_labels(self):
        sessions = [manual("first", "2025-11-02T01:15:00-04:00", "2025-11-02T01:45:00-04:00", zone="America/New_York"),
                    manual("second", "2025-11-02T01:15:00-05:00", "2025-11-02T01:45:00-05:00", zone="America/New_York")]
        result = summarize([activity()], sessions)
        self.assertEqual(result["clockSeconds"], 3600)
        self.assertFalse(result["hasOverlaps"])

    def test_skipped_calendar_day_is_not_fabricated(self):
        self.assertEqual(manual_days("2011-12-29T23:00:00-10:00", "2011-12-31T01:00:00+14:00", "Pacific/Apia"),
                         [{"date": "2011-12-29", "seconds": 3600},
                          {"date": "2011-12-31", "seconds": 3600}])

    def test_fixed_offset_fallback_preserves_historic_date(self):
        self.assertEqual(interval_days("2025-01-01T20:00:00Z", 7200, "Unavailable/Historic", 10800),
                         [{"date": "2025-01-01", "seconds": 3600},
                          {"date": "2025-01-02", "seconds": 3600}])

    def test_timer_uses_confirmed_duration_not_wall_end_or_live_elapsed(self):
        session = timer([interval("2025-01-01T23:59:55Z", 10)])
        result = summarize([activity()], [session])
        self.assertEqual(result["clockSeconds"], 10)
        self.assertEqual(result["reportedSeconds"], 0)
        self.assertEqual(result["untimedSessions"], 0)
        self.assertEqual(result["sessionCount"], 1)
        self.assertEqual([row["clockSeconds"] for row in result["days"]], [5, 5])

    def test_zero_confirmed_timer_is_a_session_not_untimed_effort(self):
        result = summarize([activity()], [timer([interval("2025-01-01T00:00:00Z", 0)])])
        self.assertEqual(result["sessionCount"], 1)
        self.assertEqual(result["untimedSessions"], 0)
        self.assertEqual(result["clockSeconds"], 0)
        self.assertEqual(result["days"][0]["date"], "2025-01-01")

    def test_travel_preserves_each_resumed_interval_zone(self):
        session = timer([interval("2025-01-01T23:59:55Z", 10),
                         interval("2025-01-02T00:00:05Z", 5, "America/Los_Angeles", -28800, "2025-01-01")])
        result = summarize([activity()], [session])
        self.assertEqual(result["sessionCount"], 1)
        self.assertEqual(result["clockSeconds"], 15)
        self.assertEqual({day: row["clockSeconds"] for day, row in day_totals(result).items()},
                         {"2025-01-01": 10, "2025-01-02": 5})
        self.assertEqual(summarize([activity()], [session], "2025-01-01", "2025-01-01")["clockSeconds"], 10)

    def test_cross_zone_overlap_is_unioned_globally_after_local_date_selection(self):
        sessions = [manual("utc", "2025-01-06T00:00:00Z", "2025-01-06T01:00:00Z"),
                    manual("west", "2025-01-06T00:00:00Z", "2025-01-06T01:00:00Z", zone="America/Los_Angeles")]
        all_dates = summarize([activity()], sessions)
        self.assertEqual(all_dates["clockSeconds"], 3600)
        self.assertEqual(all_dates["overlapSeconds"], 3600)
        self.assertEqual(sum(row["clockSeconds"] for row in all_dates["days"]), 7200)
        for day in ("2025-01-05", "2025-01-06"):
            result = summarize([activity()], sessions, day, day)
            self.assertEqual(result["clockSeconds"], 3600)
            self.assertEqual(result["sessionCount"], 1)
            self.assertFalse(result["hasOverlaps"])
        snapshot = {"activities": [activity()], "sessions": sessions, "today": "2025-01-06"}
        self.assertEqual(weekly_review(snapshot, {})["sessionCount"], 1)

    def test_completions_count_once_independently_of_sessions_and_plans(self):
        activities = [activity(completed="2025-01-02"), activity("b", completed="2025-01-02"), activity("c")]
        sessions = [reported("one"), reported("two", None), reported("three", None, "c")]
        result = summarize(activities, sessions)
        self.assertEqual(result["completedActivities"], 2)
        self.assertEqual(day_totals(result)["2025-01-02"]["completedActivities"], 2)
        self.assertNotIn("2040-01-01", day_totals(result))
        result = summarize(activities, sessions, "2025-01-02", "2025-01-02")
        self.assertEqual(result["completedActivities"], 2)
        self.assertEqual(result["sessionCount"], 0)
        activities[0].update(status="open", completedDate="")
        self.assertEqual(summarize(activities, sessions)["completedActivities"], 1)

    def test_filters_match_normalized_names_and_apply_to_completion_and_session_totals(self):
        activities = [activity(category="Café", completed="2025-01-01"),
                      activity("b", "Reading", "Other", completed="2025-01-01")]
        sessions = [reported(), reported("other", 60, "b")]
        result = summarize(activities, sessions, category="  CAFE\u0301  ", project="fixture")
        self.assertEqual(result["reportedSeconds"], 1800)
        self.assertEqual(result["completedActivities"], 1)
        self.assertEqual(result["sessionCount"], 1)
        self.assertEqual(summarize(activities, sessions, category="missing")["days"], [])

    def test_duplicate_session_id_does_not_duplicate_reported_or_untimed_counts(self):
        session = reported()
        untimed = reported("untimed", None)
        result = summarize([activity()], [session, deepcopy(session), untimed, deepcopy(untimed)])
        self.assertEqual(result["reportedSeconds"], 1800)
        self.assertEqual(result["untimedSessions"], 1)
        self.assertEqual(result["sessionCount"], 2)

    def test_date_only_duration_is_additive_uncapped_and_never_overlap_checked(self):
        result = summarize([activity(category="")], [reported(minutes=3000), reported("two", 3000)])
        self.assertEqual(result["reportedSeconds"], 360000)
        self.assertEqual(result["clockSeconds"], 0)
        self.assertEqual(result["overlapSeconds"], 0)
        self.assertEqual(result["categories"][0]["name"], "")

    def test_week_boundaries_cross_year_and_default_to_snapshot_today(self):
        snapshot = {"activities": [activity()], "sessions": [reported()], "today": "2025-01-01"}
        for args in ({}, {"weekOf": "2024-12-30"}, {"weekOf": "2025-01-05"}):
            with self.subTest(args=args):
                result = weekly_review(snapshot, args)
                self.assertEqual((result["from"], result["to"]), ("2024-12-30", "2025-01-05"))
                self.assertEqual(result["reportedSeconds"], 1800)
        self.assertEqual(weekly_review(snapshot, {"weekOf": "2025-01-06"})["sessionCount"], 0)

    def test_invalid_review_arguments_raise_validation_errors(self):
        snapshot = {"activities": [], "sessions": [], "today": "2025-01-01"}
        for args in ({"weekOf": "2025-02-30"}, {"weekOf": "20250101"}, {"weekOf": ""},
                     {"weekOf": None}, {"category": []}, {"project": 1}, {"weekOf": "9999-12-31"}):
            with self.subTest(args=args), self.assertRaises(StoreError) as error:
                weekly_review(snapshot, args)
            self.assertEqual(error.exception.code, "validation")
        with self.assertRaises(StoreError):
            summarize([], [], "2025-01-02", "2025-01-01")

    def test_manual_interval_requires_aware_forward_bounds(self):
        for start, end in [("2025-01-01T00:00:00", "2025-01-01T01:00:00Z"),
                           ("2025-01-01T00:00:00Z", "2025-01-01T00:00:00Z"),
                           ("2025-01-01T01:00:00Z", "2025-01-01T00:00:00Z")]:
            with self.subTest(start=start, end=end), self.assertRaises(StoreError):
                manual_days(start, end, "UTC")
        for seconds in (-1, float("inf"), float("nan"), True):
            with self.subTest(seconds=seconds), self.assertRaises(StoreError):
                interval_days("2025-01-01T00:00:00Z", seconds, "UTC")

    def test_calendar_extremes_do_not_advance_past_representable_end(self):
        for day in ("0001-01-01", "9999-12-31"):
            with self.subTest(day=day):
                self.assertEqual(manual_days(day + "T12:00:00Z", day + "T13:00:00Z", "UTC"),
                                 [{"date": day, "seconds": 3600}])

    def test_long_interval_is_clipped_before_day_iteration(self):
        session = manual("long", "1900-01-01T00:00:00Z", "2300-01-01T00:00:00Z")
        # Counting actual boundary conversions checks the algorithm, not a flaky
        # wall-clock threshold. Seven selected days must not scan four centuries.
        from backend import review
        with patch.object(review, "_midnight", wraps=review._midnight) as boundaries:
            result = summarize([activity()], [session], "2025-01-06", "2025-01-12")
        self.assertEqual(result["clockSeconds"], 7 * 86400)
        self.assertEqual(len(result["days"]), 7)
        self.assertLessEqual(boundaries.call_count, 10)
        self.assertEqual(interval_days("2025-01-01T00:00:00Z", 1e100, "UTC",
                                       from_date="2025-01-06", to_date="2025-01-12"),
                         [{"date": f"2025-01-{day:02}", "seconds": 86400} for day in range(6, 13)])

    def test_substantial_overlapping_history_retains_union_and_distinct_sessions(self):
        sessions = [manual(str(index), "2025-01-01T10:00:00Z", "2025-01-01T11:00:00Z")
                    for index in range(12000)]
        result = summarize([activity()], sessions)
        self.assertEqual(result["clockSeconds"], 3600)
        self.assertEqual(result["overlapSeconds"], 11999 * 3600)
        self.assertEqual(result["sessionCount"], 12000)


class ReviewVisibleSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daylog-review-")
        self.addCleanup(self.temporary.cleanup)
        self.store = Store(Path(self.temporary.name) / "profile")
        self.addCleanup(self.store.close)
        self.sequence = 0

    def call(self, op, args=None):
        self.sequence += 1
        return self.store.handle({"protocol": 1, "requestId": f"review-{self.sequence}",
                                  "clientId": "review-fixture", "op": op, "args": args or {}})

    def review(self, snapshot):
        return summarize(snapshot["activities"], snapshot["sessions"])

    def test_manual_bounds_day_summaries_and_weekly_wire_review_agree(self):
        created = self.call("create_activity", {"title": "Clock bounds fixture", "mode": "log",
                                               "date": "2025-01-05", "minutes": None,
                                               "startUtc": "2025-01-05T23:30:00Z",
                                               "endUtc": "2025-01-06T00:30:00Z", "timeZone": "UTC"})
        owner = created["result"]["activityId"]
        first = created["snapshot"]["sessions"][0]
        self.assertEqual(first["days"], [{"date": "2025-01-05", "seconds": 1800},
                                         {"date": "2025-01-06", "seconds": 1800}])
        extra = self.call("add_session", {"activityId": owner, "date": "2025-01-06", "minutes": None,
                                          "startUtc": "2025-01-06T00:00:00Z",
                                          "endUtc": "2025-01-06T01:00:00Z", "timeZone": "UTC"})
        daily = extra["snapshot"]["daySummaries"]["2025-01-06"]
        self.assertEqual(daily["clockSeconds"], 3600)
        self.assertEqual(daily["overlapSeconds"], 1800)
        self.assertTrue(daily["hasOverlaps"])
        result = self.call("review", {"weekOf": "2025-01-06"})["result"]
        self.assertEqual((result["from"], result["to"]), ("2025-01-06", "2025-01-12"))
        self.assertEqual(result["clockSeconds"], 3600)
        self.assertEqual(result["reportedSeconds"], 0)
        self.assertEqual(result["sessionCount"], 2)

    def test_deleted_session_activity_undo_and_purge_use_only_visible_snapshots(self):
        created = self.call("create_activity", {"title": "Deletion review fixture", "mode": "log",
                                               "date": "2025-01-01", "minutes": 30, "category": "Fixture"})
        owner = created["result"]["activityId"]
        extra = self.call("add_session", {"activityId": owner, "date": "2025-01-01", "minutes": None})
        sessions = extra["snapshot"]["sessions"]
        timed = next(row for row in sessions if row["minutes"] is not None)
        self.assertEqual(self.review(extra["snapshot"])["untimedSessions"], 1)
        deleted = self.call("delete_record", {"kind": "session", "id": timed["id"],
                                               "expectedRevision": timed["revision"]})
        self.assertEqual(self.review(deleted["snapshot"])["reportedSeconds"], 0)
        self.assertEqual(self.review(deleted["snapshot"])["sessionCount"], 1)
        session_trash = deleted["result"]["trashId"]
        current = deleted["snapshot"]["activities"][0]
        deleted_owner = self.call("delete_record", {"kind": "activity", "id": owner,
                                                    "expectedRevision": current["revision"]})
        self.assertEqual(self.review(deleted_owner["snapshot"])["sessionCount"], 0)
        restored = self.call("undo_delete", {"trashId": deleted_owner["result"]["trashId"]})
        self.assertEqual(self.review(restored["snapshot"])["untimedSessions"], 1)
        self.assertEqual(self.review(restored["snapshot"])["reportedSeconds"], 0)
        restored_session = self.call("undo_delete", {"trashId": session_trash})
        self.assertEqual(self.review(restored_session["snapshot"])["reportedSeconds"], 1800)
        timed = next(row for row in restored_session["snapshot"]["sessions"] if row["id"] == timed["id"])
        deleted_again = self.call("delete_record", {"kind": "session", "id": timed["id"],
                                                     "expectedRevision": timed["revision"]})
        purged = self.call("purge_deleted", {"trashId": deleted_again["result"]["trashId"], "confirmed": True})
        self.assertEqual(self.review(purged["snapshot"])["reportedSeconds"], 0)
        self.assertEqual(self.review(purged["snapshot"])["untimedSessions"], 1)

    def test_corrected_duration_and_archived_renamed_category_remain_canonical(self):
        created = self.call("create_activity", {"title": "Correction review fixture", "mode": "log",
                                               "date": "2025-01-01", "minutes": 30, "category": "Before"})
        session = created["snapshot"]["sessions"][0]
        corrected = self.call("update_session", {"sessionId": session["id"], "expectedRevision": session["revision"],
                                                  "date": "2025-01-02", "minutes": 45, "note": "Synthetic correction"})
        self.assertEqual(self.review(corrected["snapshot"])["reportedSeconds"], 2700)
        self.assertEqual(self.review(corrected["snapshot"])["days"][0]["date"], "2025-01-02")
        label = corrected["snapshot"]["categories"][0]
        renamed = self.call("update_label", {"kind": "category", "id": label["id"], "name": "After",
                                              "archived": True, "expectedRevision": label["revision"]})
        snapshot = renamed["snapshot"]
        result = summarize(snapshot["activities"], snapshot["sessions"], category="after")
        self.assertEqual(result["reportedSeconds"], 2700)
        self.assertEqual(result["categories"][0]["name"], "After")


if __name__ == "__main__":
    unittest.main()
