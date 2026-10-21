"""Canonical review accounting; date-only durations never acquire clock positions.

Clock totals union physical UTC spans after clipping in each interval's historic
local zone. Categories and days are independent unions: categories may overlap,
and a physical span recorded in different historic zones may belong to different
dates. Consequently their sums need not equal the all-category/week union.
"""

from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone
import math

try:
    from .storage import StoreError, calendar_date, normalized_name, text
    from .timer import zone_for
except ImportError:
    from storage import StoreError, calendar_date, normalized_name, text
    from timer import zone_for


UTC = timezone.utc


def union_seconds(spans):
    """Measure half-open UTC timestamp pairs in O(n log n), without mutation."""
    total = 0.0
    end = None
    for start, stop in sorted(spans):
        if stop <= start:
            continue
        if end is None or start >= end:
            total += stop - start
            end = stop
        elif stop > end:
            total += stop - end
            end = stop
    return total


def _instant(value, field):
    value = text(value, field, required=True)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError
        return parsed.timestamp()
    except (ValueError, OverflowError, OSError):
        raise StoreError("validation", f"{field} must be a timezone-aware timestamp.") from None


def _range(from_date, to_date):
    start = calendar_date(from_date, "from", optional=True)
    end = calendar_date(to_date, "to", optional=True)
    if start and end and start > end:
        raise StoreError("validation", "The start date must not follow the end date.")
    return start, end


def _in_range(day, start, end):
    return bool(day) and (not start or day >= start) and (not end or day <= end)


def _midnight(day, zone):
    return datetime.combine(day, time.min, zone).timestamp()


def _day_spans(start, end, zone, from_date="", to_date=""):
    """Yield (local date, UTC start, UTC end), advancing by days, never seconds.

    Clip before iterating so a week of a centuries-long interval costs a week,
    not centuries. UTC boundaries preserve 23/25-hour days and skipped dates.
    """
    if from_date:
        start = max(start, _midnight(date.fromisoformat(from_date), zone))
    if to_date and to_date != "9999-12-31":
        end = min(end, _midnight(date.fromisoformat(to_date) + timedelta(days=1), zone))
    if start < end:
        try:
            # Reject an unrepresentable unbounded interval immediately rather
            # than walking millions of days before reaching the calendar limit.
            datetime.fromtimestamp(start, zone)
            datetime.fromtimestamp(end, zone)
        except (ValueError, OverflowError, OSError):
            raise StoreError("validation", "The clock interval exceeds supported calendar dates.") from None
    while start < end:
        try:
            local_day = datetime.fromtimestamp(start, zone).date()
            if local_day == date.max:
                # There is no representable next midnight. A finite endpoint
                # within this last day still has a well-defined allocation.
                datetime.fromtimestamp(end, zone)
                boundary = end
            else:
                tomorrow = local_day + timedelta(days=1)
                boundary = _midnight(tomorrow, zone)
                while boundary <= start:
                    tomorrow += timedelta(days=1)
                    boundary = _midnight(tomorrow, zone)
        except (ValueError, OverflowError, OSError):
            raise StoreError("validation", "The clock interval exceeds supported calendar dates.") from None
        stop = min(end, boundary)
        day = local_day.isoformat()
        if _in_range(day, from_date, to_date):
            yield day, start, stop
        start = stop


def interval_days(start_utc, seconds, time_zone, offset_seconds=0, from_date="", to_date=""):
    """Allocate measured seconds using original IANA zone or saved offset.

    Optional inclusive date bounds clip before splitting. The caller retains its
    canonical start local date for a zero-duration timer, just as M3 does.
    """
    from_date, to_date = _range(from_date, to_date)
    try:
        valid = type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0
    except OverflowError:
        valid = False
    if not valid:
        raise StoreError("validation", "Interval seconds must be finite and nonnegative.")
    start = _instant(start_utc, "startUtc")
    zone = zone_for(time_zone, offset_seconds)
    if seconds == 0:
        day = datetime.fromtimestamp(start, zone).date().isoformat()
        return [{"date": day, "seconds": 0.0}] if _in_range(day, from_date, to_date) else []
    return [{"date": day, "seconds": stop - begin}
            for day, begin, stop in _day_spans(start, start + seconds, zone, from_date, to_date)]


def manual_days(start_utc, end_utc, time_zone, offset_seconds=0):
    """Allocate known manual bounds; no clock is inferred from reported minutes."""
    start = _instant(start_utc, "startUtc")
    end = _instant(end_utc, "endUtc")
    if end <= start:
        raise StoreError("validation", "endUtc must follow startUtc.")
    zone = zone_for(time_zone, offset_seconds)
    return [{"date": day, "seconds": stop - begin}
            for day, begin, stop in _day_spans(start, end, zone)]


def _clock_intervals(session):
    if session["source"] == "timer":
        for interval in session["intervals"]:
            start = _instant(interval["startUtc"], "startUtc")
            # Wall end/checkpoint timestamps may have drifted. Only the durable
            # measured duration counts, never elapsedSeconds or unknown downtime.
            yield (start, start + interval["durationSeconds"],
                   zone_for(interval["timeZone"], interval["offsetSeconds"]),
                   interval["localDate"])
    elif session.get("startUtc") and session.get("endUtc"):
        start = _instant(session["startUtc"], "startUtc")
        end = _instant(session["endUtc"], "endUtc")
        zone = zone_for(session.get("timeZone", "UTC"), session.get("offsetSeconds", 0))
        yield start, end, zone, datetime.fromtimestamp(start, zone).date().isoformat()


def _bucket():
    return {"spans": [], "reportedSeconds": 0.0, "untimedSessions": 0,
            "completedActivities": 0, "sessionIds": set()}


def _totals(bucket):
    spans = bucket["spans"]
    clock = union_seconds(spans)
    if not math.isfinite(clock + bucket["reportedSeconds"]):
        raise StoreError("validation", "Logged duration exceeds the supported numeric range. Reduce or correct the reported duration.")
    overlap = max(0.0, math.fsum(end - start for start, end in spans) - clock)
    return {"clockSeconds": clock, "reportedSeconds": bucket["reportedSeconds"],
            "loggedSeconds": clock + bucket["reportedSeconds"],
            "untimedSessions": bucket["untimedSessions"],
            "completedActivities": bucket["completedActivities"],
            "overlapSeconds": overlap, "hasOverlaps": overlap > 0,
            "sessionCount": len(bucket["sessionIds"])}


def summarize(activities, sessions, from_date="", to_date="", category="", project=""):
    """Summarize visible canonical snapshots, not UI history's per-day slices.

    Inclusive local-date bounds apply independently in each saved zone. Completion
    is counted once on completedDate even without sessions. Untimed work counts
    separately, while date-only user-reported minutes remain fully additive.
    """
    from_date, to_date = _range(from_date, to_date)
    category = normalized_name(category, "category").casefold()
    project = normalized_name(project, "project").casefold()
    selected = {a["id"]: a for a in activities
                if not a.get("deletedAt")
                and (not category or category == normalized_name(a["category"], "category").casefold())
                and (not project or project == normalized_name(a["project"], "project").casefold())}
    total = _bucket()
    days = defaultdict(_bucket)
    categories = defaultdict(_bucket)
    seen = set()
    for session in sessions:
        session_id = session["id"]
        activity = selected.get(session["activityId"])
        if activity is None or session.get("deletedAt") or session_id in seen:
            continue
        seen.add(session_id)
        name = activity["category"]
        clocked = session["source"] == "timer" or bool(session.get("startUtc") and session.get("endUtc"))
        if clocked:
            for start, end, zone, local_day in _clock_intervals(session):
                portions = _day_spans(start, end, zone, from_date, to_date)
                if start == end and _in_range(local_day, from_date, to_date):
                    portions = [(local_day, start, end)]
                for day, begin, stop in portions:
                    for bucket in (total, categories[name], days[day]):
                        bucket["spans"].append((begin, stop))
                        bucket["sessionIds"].add(session_id)
        else:
            day = session["date"]
            if not _in_range(day, from_date, to_date):
                continue
            for bucket in (total, categories[name], days[day]):
                bucket["sessionIds"].add(session_id)
                if session["minutes"] is None:
                    bucket["untimedSessions"] += 1
                else:
                    bucket["reportedSeconds"] += session["minutes"] * 60
    for activity in selected.values():
        day = activity["completedDate"]
        if activity["status"] == "done" and _in_range(day, from_date, to_date):
            total["completedActivities"] += 1
            days[day]["completedActivities"] += 1
    category_rows = []
    for name in sorted(categories, key=lambda value: (value.casefold(), value)):
        values = _totals(categories[name])
        category_rows.append({"name": name, **{key: values[key] for key in
                             ("clockSeconds", "reportedSeconds", "loggedSeconds", "untimedSessions")}})
    return {"from": from_date, "to": to_date, **_totals(total), "categories": category_rows,
            "days": [{"date": day, **_totals(days[day])} for day in sorted(days)]}


def weekly_review(snapshot, args):
    """Return the Monday-Sunday week containing weekOf (default snapshot today)."""
    week_of = calendar_date(args.get("weekOf", snapshot.get("today", date.today().isoformat())), "weekOf")
    selected = date.fromisoformat(week_of)
    try:
        monday = selected - timedelta(days=selected.weekday())
        sunday = monday + timedelta(days=6)
    except OverflowError:
        raise StoreError("validation", "The selected week exceeds supported calendar dates.") from None
    return summarize(snapshot["activities"], snapshot["sessions"], monday.isoformat(), sunday.isoformat(),
                     args.get("category", ""), args.get("project", ""))
