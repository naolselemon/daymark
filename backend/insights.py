"""Entry counts from canonical visible records, independent of interval slices."""

from datetime import date, timedelta
from heapq import nsmallest


def summarize_entries(activities, sessions, today):
    """Summarize canonical sessions once, with fourteen inclusive calendar bins."""
    end = date.fromisoformat(today)
    days = [{"date": (end - timedelta(days=offset)).isoformat(), "entries": 0}
            for offset in range(13, -1, -1)]
    day_indexes = {day["date"]: index for index, day in enumerate(days)}
    by_activity = {}
    distinct_dates = {}
    last_recent = {}
    open_count = done_count = 0
    for activity in activities:
        activity_id = activity["id"]
        by_activity[activity_id] = {"entryCount": 0, "activeDays": 0, "firstDate": "", "lastDate": "",
                                    "recentEntries": 0, "recentCounts": [0] * len(days)}
        distinct_dates[activity_id] = set()
        if activity["status"] == "done":
            done_count += 1
        else:
            open_count += 1

    for session in sessions:
        activity_id = session["activityId"]
        stats = by_activity[activity_id]
        recorded_date = session["date"]
        stats["entryCount"] += 1
        distinct_dates[activity_id].add(recorded_date)
        if not stats["firstDate"] or recorded_date < stats["firstDate"]:
            stats["firstDate"] = recorded_date
        if recorded_date > stats["lastDate"]:
            stats["lastDate"] = recorded_date
        index = day_indexes.get(recorded_date)
        if index is not None:
            days[index]["entries"] += 1
            stats["recentEntries"] += 1
            stats["recentCounts"][index] += 1
            last_recent[activity_id] = max(index, last_recent.get(activity_id, -1))

    for activity_id, stats in by_activity.items():
        stats["activeDays"] = len(distinct_dates[activity_id])

    return {"startDate": days[0]["date"], "endDate": today, "days": days,
            "entryCount": sum(day["entries"] for day in days),
            "activeDays": sum(day["entries"] > 0 for day in days),
            "openActivities": open_count, "doneActivities": done_count,
            "byActivity": by_activity,
            "recentActivityIds": nsmallest(5, last_recent, key=lambda key: (-last_recent[key], key))}
