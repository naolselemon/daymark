"""Diary browsing uses canonical notes before search and bounded pagination."""

from datetime import date, timedelta
from pathlib import Path
import tempfile
import unittest

from backend.storage import Store, StoreError


class DiaryHistoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="daylog-diary-")
        self.addCleanup(self.directory.cleanup)
        self.profile = Path(self.directory.name) / "journal"
        self.store = Store(self.profile)
        self.addCleanup(self.store.close)
        self.sequence = 0

    def call(self, op, args=None, store=None):
        self.sequence += 1
        return (store or self.store).handle({"protocol": 1, "requestId": f"diary-{self.sequence}",
                                           "op": op, "args": args or {}})

    def save(self, day, body, revision=0):
        return self.call("save_note", {"date": day, "body": body, "expectedRevision": revision})

    def diary(self, **filters):
        return self.call("history", dict(kind="notes", **filters))["result"]

    def test_notes_are_filtered_before_pagination_not_from_first_mixed_page(self):
        owner = self.call("create_activity", {"title": "SYNTHETIC busy history", "mode": "plan"})["result"]["activityId"]
        for _ in range(103):
            self.call("add_session", {"activityId": owner, "date": "2030-01-01"})
        dates = [(date(2024, 1, 1) + timedelta(days=index)).isoformat() for index in range(105)]
        for day in dates:
            self.save(day, "SYNTHETIC diary " + day)

        mixed = self.call("history")["result"]
        self.assertEqual((len(mixed["sessions"]), mixed["notes"], mixed["total"]), (100, [], 208))
        first = self.diary()
        second = self.diary(offset=first["nextOffset"])
        self.assertEqual(first["total"], 105)
        self.assertEqual((len(first["notes"]), first["nextOffset"], first["hasMore"]), (100, 100, True))
        self.assertEqual((len(second["notes"]), second["nextOffset"], second["hasMore"]), (5, 105, False))
        self.assertEqual([note["date"] for note in first["notes"] + second["notes"]], list(reversed(dates)))
        self.assertEqual(first["sessions"] + first["completions"] + second["sessions"] + second["completions"], [])
        self.assertEqual(self.diary(offset=105)["notes"], [])
        self.assertEqual(self.diary()["notes"], first["notes"])

    def test_default_all_keeps_existing_mixed_result_and_note_shape(self):
        self.call("create_activity", {"title": "SYNTHETIC entry", "mode": "log", "date": "2024-01-02"})
        self.call("create_activity", {"title": "SYNTHETIC completion", "mode": "plan", "done": True})
        self.save("2024-01-02", "SYNTHETIC reflection")
        implicit = self.call("history")["result"]
        self.assertEqual(implicit, self.call("history", {"kind": "all"})["result"])
        self.assertEqual((len(implicit["sessions"]), len(implicit["completions"]), implicit["total"]), (1, 1, 3))
        self.assertEqual(self.diary()["notes"], [{"date": "2024-01-02", "body": "SYNTHETIC reflection", "revision": 1}])
        # Adding date search to Diary must not change the mixed-history search contract.
        self.assertEqual(self.call("history", {"query": "2024-01-02"})["result"]["notes"], [])
        self.assertEqual(self.diary(query="2024-01-02")["total"], 1)

    def test_activities_exclude_notes_before_counting_and_pagination(self):
        owner = self.call("create_activity", {"title": "SYNTHETIC activity", "mode": "plan"})["result"]["activityId"]
        for day in ("2024-01-01", "2024-01-03", "2024-01-05"):
            self.call("add_session", {"activityId": owner, "date": day})
        self.call("create_activity", {"title": "SYNTHETIC completion", "mode": "plan", "done": True})
        expected = self.call("history", {"kind": "activities", "limit": 2})["result"]
        expected_next = self.call("history", {"kind": "activities", "limit": 2, "offset": 2})["result"]
        for day in ("2024-01-02", "2024-01-04", "2099-01-01", "2099-01-02"):
            self.save(day, "SYNTHETIC private page")
        first = self.call("history", {"kind": "activities", "limit": 2})["result"]
        second = self.call("history", {"kind": "activities", "limit": 2, "offset": first["nextOffset"]})["result"]
        self.assertEqual(first, expected)
        self.assertEqual(second, expected_next)
        self.assertEqual((first["total"], first["nextOffset"], first["hasMore"]), (4, 2, True))
        self.assertEqual((second["total"], second["nextOffset"], second["hasMore"]), (4, 4, False))
        self.assertEqual(first["notes"] + second["notes"], [])
        self.assertEqual(len(first["sessions"] + second["sessions"]), 3)
        self.assertEqual(len(first["completions"] + second["completions"]), 1)
        exhausted = self.call("history", {"kind": "activities", "offset": 4})["result"]
        self.assertEqual((exhausted["sessions"], exhausted["notes"], exhausted["completions"], exhausted["hasMore"]),
                         ([], [], [], False))
        self.assertEqual(self.call("history", {"kind": "all"})["result"]["total"], 8)
        self.assertEqual(self.diary()["total"], 4)

    def test_activities_search_never_matches_private_bodies_or_dates(self):
        self.call("create_activity", {"title": "SYNTHETIC Café", "mode": "log", "date": "2024-02-27"})
        self.call("create_activity", {"title": "SYNTHETIC other", "note": "SYNTHETIC Café",
                                      "mode": "plan", "done": True})
        self.save("2024-02-29", "SYNTHETIC Café private-only-word")
        self.save("2099-01-01", "SYNTHETIC Café")
        for query in ("private-only-word", "2024-02-29"):
            with self.subTest(query=query):
                result = self.call("history", {"kind": "activities", "query": query})["result"]
                self.assertEqual(result, {"sessions": [], "notes": [], "completions": [],
                                          "total": 0, "nextOffset": 0, "hasMore": False})
                self.assertEqual(self.diary(query=query)["total"], 1)
        pages = [self.call("history", {"kind": "activities", "query": "CAFE\u0301",
                                      "limit": 1, "offset": offset})["result"] for offset in (0, 1)]
        self.assertEqual([page["total"] for page in pages], [2, 2])
        self.assertEqual([page["hasMore"] for page in pages], [True, False])
        self.assertEqual(pages[0]["notes"] + pages[1]["notes"], [])
        self.assertEqual(len(pages[0]["sessions"] + pages[1]["sessions"]), 1)
        self.assertEqual(len(pages[0]["completions"] + pages[1]["completions"]), 1)

    def test_unicode_body_and_recorded_date_search_precede_paging(self):
        self.save("2024-02-27", "SYNTHETIC Café Straße ΣΊΓΜΑ 東京 100%")
        self.save("2024-02-28", "SYNTHETIC unrelated")
        self.save("2024-02-29", "SYNTHETIC Cafe\u0301 STRASSE σίγμα 東京 100%")
        self.save("2024-03-01", "SYNTHETIC latest unrelated")
        self.call("create_activity", {"title": "SYNTHETIC only-activity-word", "mode": "log", "date": "2024-02-27"})
        for query in ("CAFE\u0301", "strasse", "ΣΊΓΜΑ", "東京", "100%"):
            with self.subTest(query=query):
                first = self.diary(query=query, limit=1)
                second = self.diary(query=query, limit=1, offset=1)
                self.assertEqual((first["total"], first["hasMore"]), (2, True))
                self.assertEqual([note["date"] for note in first["notes"] + second["notes"]], ["2024-02-29", "2024-02-27"])
        self.assertEqual([note["date"] for note in self.diary(query="2024-02")["notes"]],
                         ["2024-02-29", "2024-02-28", "2024-02-27"])
        self.assertEqual(self.diary(query="only-activity-word")["total"], 0)

    def test_date_ranges_constrain_both_body_and_date_matches(self):
        self.save("2024-02-28", "SYNTHETIC needle 2024-03")
        self.save("2024-02-29", "SYNTHETIC needle")
        self.save("2024-03-01", "SYNTHETIC other")
        self.save("2024-03-02", "SYNTHETIC needle")
        filters = {"from": "2024-02-29", "to": "2024-03-01"}
        self.assertEqual([note["date"] for note in self.diary(query="needle", **filters)["notes"]], ["2024-02-29"])
        self.assertEqual([note["date"] for note in self.diary(query="2024-03", **filters)["notes"]], ["2024-03-01"])
        self.assertEqual([note["date"] for note in self.diary(**filters)["notes"]], ["2024-03-01", "2024-02-29"])
        self.assertEqual(self.diary(query="2024-03-02", **filters)["total"], 0)
        # Existing label filters exclude unlabelled daily notes in either section.
        self.assertEqual(self.diary(category="Reading")["total"], 0)
        self.assertEqual(self.diary(project="Journal")["total"], 0)

    def test_saved_empty_note_conflict_delete_restore_and_replacement(self):
        day = "2024-02-29"
        self.assertEqual(self.diary()["total"], 0)
        self.save(day, "SYNTHETIC original")
        with self.assertRaises(StoreError) as stale:
            self.save(day, "SYNTHETIC stale", revision=0)
        self.assertEqual(stale.exception.code, "conflict")
        self.assertEqual(self.diary()["notes"][0]["body"], "SYNTHETIC original")
        self.save(day, "", revision=1)
        self.assertEqual(self.diary()["notes"], [{"date": day, "body": "", "revision": 2}])
        before = self.call("snapshot")["snapshot"]
        restarted = Store(self.profile)
        self.addCleanup(restarted.close)
        response = self.call("history", {"kind": "notes", "query": day}, store=restarted)
        self.assertEqual(response["result"]["notes"], [{"date": day, "body": "", "revision": 2}])
        self.assertEqual(response["snapshot"], before)

        deleted = self.call("delete_record", {"kind": "note", "id": day, "expectedRevision": 2})
        self.assertEqual(self.diary()["total"], 0)
        self.assertEqual(self.diary(query=day)["notes"], [])
        with self.assertRaises(StoreError) as replacement:
            self.save(day, "SYNTHETIC blocked replacement")
        self.assertEqual(replacement.exception.code, "deleted")
        self.call("undo_delete", {"trashId": deleted["result"]["trashId"]})
        self.assertEqual(self.diary()["notes"], [{"date": day, "body": "", "revision": 4}])
        self.save(day, "SYNTHETIC revised", revision=4)
        self.assertEqual(self.diary(query="revised")["notes"], [{"date": day, "body": "SYNTHETIC revised", "revision": 5}])
        deleted = self.call("delete_record", {"kind": "note", "id": day, "expectedRevision": 5})
        self.call("purge_deleted", {"trashId": deleted["result"]["trashId"], "confirmed": True})
        self.assertEqual(self.diary()["total"], 0)
        self.save(day, "SYNTHETIC new page")
        self.assertEqual(self.diary()["notes"], [{"date": day, "body": "SYNTHETIC new page", "revision": 1}])

    def test_invalid_kind_and_existing_filter_validation_remain_errors(self):
        before = self.call("snapshot")["snapshot"]
        for kind in ("", "note", "sessions", "NOTES", None, 1, [], {}):
            with self.subTest(kind=kind):
                with self.assertRaises(StoreError) as invalid:
                    self.call("history", {"kind": kind})
                self.assertEqual(invalid.exception.code, "validation")
        for filters in ({"from": "2024-03-01", "to": "2024-02-29"}, {"from": "2024-2-1"},
                        {"offset": -1}, {"offset": True}, {"limit": 0}, {"limit": 501}):
            with self.subTest(filters=filters):
                with self.assertRaises(StoreError) as invalid:
                    self.diary(**filters)
                self.assertEqual(invalid.exception.code, "validation")
        self.assertEqual(self.call("snapshot")["snapshot"], before)


if __name__ == "__main__":
    unittest.main()
