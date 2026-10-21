"""Durable optional timing, measured clocks, and explicit interruption recovery."""

from dataclasses import dataclass
from datetime import datetime, time as daytime, timedelta, timezone
import os
from pathlib import Path
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

try:
    from .storage import StoreError, boolean, new_id, text
except ImportError:
    from storage import StoreError, boolean, new_id, text


GRACE_SECONDS = 15


def stamp(wall):
    return datetime.fromtimestamp(wall, timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def process_identity(pid):
    try:
        # comm may itself contain spaces and parentheses; fields after its final
        # ')' start at field 3 (state), and starttime is field 22.
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X", "x"):
            return None
        return fields[19]
    except (OSError, IndexError):
        return None


def zone_for(name, offset):
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return timezone(timedelta(seconds=offset))


@dataclass(frozen=True)
class ClockSample:
    wall: float
    mono: float
    boot: float
    boot_id: str
    time_zone: str
    offset: int


class Clock:
    def sample(self):
        wall = time.time()
        mono = time.clock_gettime(time.CLOCK_MONOTONIC)
        boot = time.clock_gettime(time.CLOCK_BOOTTIME)
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        name = os.environ.get("TZ", "").removeprefix(":")
        if not name:
            localtime = str(Path("/etc/localtime").resolve())
            name = localtime.split("/zoneinfo/", 1)[-1] if "/zoneinfo/" in localtime else ""
        local = datetime.fromtimestamp(wall).astimezone()
        offset = int(local.utcoffset().total_seconds())
        return ClockSample(wall, mono, boot, boot_id, name or str(local.tzinfo), offset)

    def owner(self):
        pid = os.getppid()
        return pid, process_identity(pid) or ""

    def alive(self, pid, start):
        return bool(start) and process_identity(pid) == start


def allocated_days(interval, seconds):
    """Split measured seconds at the interval's original local midnight boundaries.

    UTC advancement handles DST folds/gaps; fixed offsets are retained when no
    IANA zone was available. Later travel cannot redate an earlier interval.
    """
    zone = zone_for(interval["time_zone"], interval["offset_seconds"])
    cursor = datetime.fromisoformat(interval["start_utc"].replace("Z", "+00:00"))
    remaining = seconds
    result = {}
    if remaining == 0:
        return {interval["local_date"]: 0.0}
    while remaining > 0:
        local = cursor.astimezone(zone)
        tomorrow = local.date() + timedelta(days=1)
        midnight = datetime.combine(tomorrow, daytime.min, zone).astimezone(timezone.utc)
        span = (midnight - cursor).total_seconds()
        # Zones with a skipped calendar day still yield a future UTC boundary.
        if span <= 0:
            midnight = datetime.combine(tomorrow + timedelta(days=1), daytime.min, zone).astimezone(timezone.utc)
            span = (midnight - cursor).total_seconds()
        portion = min(remaining, span)
        day = local.date().isoformat()
        result[day] = result.get(day, 0.0) + portion
        cursor += timedelta(seconds=portion)
        remaining -= portion
    return result


class TimerEngine:
    def __init__(self, store, clock):
        self.store = store
        self.clock = clock

    @property
    def db(self):
        return self.store.connection

    def begin(self):
        # A single clock sample makes the entire response internally consistent.
        self.now = self.clock.sample()
        self.owner = self.clock.owner()

    def active(self):
        return self.db.execute("SELECT * FROM timer_sessions WHERE status IN ('running','interrupted')").fetchone()

    def latest(self, session_id):
        return self.db.execute("SELECT * FROM session_intervals WHERE session_id=? ORDER BY rowid DESC LIMIT 1",
                               (session_id,)).fetchone()

    def reason(self, interval):
        now = self.now
        if interval["boot_id"] != now.boot_id:
            return "system_restart"
        if not self.clock.alive(interval["owner_pid"], interval["owner_start"]):
            return "owner_exited"
        mono = now.mono - interval["checkpoint_mono"]
        boot = now.boot - interval["checkpoint_boot"]
        wall = now.wall - interval["checkpoint_wall"]
        if mono < 0 or boot < 0 or wall < 0:
            return "clock_changed"
        if abs(boot - mono) > 0.5:
            return "suspend_detected"
        if abs(wall - mono) > 2:
            return "clock_changed"
        if mono > GRACE_SECONDS:
            return "checkpoint_gap"
        return ""

    def latch(self):
        active = self.active()
        if active and active["status"] == "running":
            reason = self.reason(self.latest(active["session_id"]))
            if reason:
                self.db.execute("UPDATE timer_sessions SET status='interrupted', recovery_reason=?, updated_at=? WHERE session_id=?",
                                (reason, stamp(self.now.wall), active["session_id"]))
                self.store._event(active["activity_id"], "timer_interrupted")
                return True
        return False

    def owned(self, interval):
        return (interval["owner_pid"], interval["owner_start"]) == self.owner and \
            interval["boot_id"] == self.now.boot_id and interval["client_id"] == self.store.client_id

    def session(self, session_id):
        session_id = text(session_id, "sessionId", required=True)
        row = self.db.execute("""SELECT t.* FROM timer_sessions t JOIN sessions s ON s.id=t.session_id
            JOIN activities a ON a.id=s.activity_id WHERE t.session_id=? AND s.deleted_at='' AND a.deleted_at=''""",
            (session_id,)).fetchone()
        if row is None:
            raise StoreError("not_found", "The timer session no longer exists.")
        return row

    def expected(self, session, interval_id):
        interval_id = text(interval_id, "intervalId", required=True)
        interval = self.latest(session["session_id"])
        if interval is None or interval["id"] != interval_id:
            raise StoreError("conflict", "The timer interval changed. Review its current state before continuing.")
        return interval

    def require_healthy(self, session):
        if session["status"] == "interrupted":
            raise StoreError("recovery_required", "Review the interrupted timer before continuing.")

    def target(self, activity_id):
        activity = self.store._activity_row(activity_id)
        if activity["status"] == "done":
            raise StoreError("activity_done", "Reopen this activity explicitly before starting a timer.")
        return activity

    def result(self, session_id):
        row = self.session(session_id)
        return {"activityId": row["activity_id"], "sessionId": session_id,
                "intervalId": self.latest(session_id)["id"]}

    def open_interval(self, session_id):
        now = self.now
        zone = zone_for(now.time_zone, now.offset)
        day = datetime.fromtimestamp(now.wall, zone).date().isoformat()
        pid, start = self.owner
        if not self.clock.alive(pid, start):
            raise StoreError("owner_unavailable", "The timer owner is no longer available.")
        self.db.execute("""INSERT INTO session_intervals
            (id,session_id,start_utc,end_utc,checkpoint_utc,duration_seconds,
             checkpoint_wall,checkpoint_mono,checkpoint_boot,boot_id,owner_pid,owner_start,
             client_id,time_zone,offset_seconds,local_date)
            VALUES (?,?,?,NULL,?,0,?,?,?,?,?,?,?,?,?,?)""",
            (new_id(), session_id, stamp(now.wall), stamp(now.wall), now.wall, now.mono, now.boot,
             now.boot_id, pid, start, self.store.client_id, now.time_zone, now.offset, day))
        self.db.execute("UPDATE timer_sessions SET status='running', recovery_reason='', updated_at=? WHERE session_id=?",
                        (stamp(now.wall), session_id))

    def start(self, activity_id):
        activity = self.target(activity_id)
        active = self.active()
        if active:
            self.require_healthy(active)
            if active["activity_id"] == activity["id"]:
                return self.result(active["session_id"])
            raise StoreError("switch_required", "Confirm switching before starting another activity's timer.")
        paused = self.db.execute("SELECT * FROM timer_sessions WHERE activity_id=? AND status='paused'", (activity["id"],)).fetchone()
        if paused:
            session_id = paused["session_id"]
            action = "timer_resume"
        else:
            session_id = new_id()
            day = datetime.fromtimestamp(self.now.wall, zone_for(self.now.time_zone, self.now.offset)).date().isoformat()
            self.db.execute("INSERT INTO sessions (id,activity_id,local_date,minutes,note,source,created_at) VALUES (?,?,?,0,'','timer',?)",
                            (session_id, activity["id"], day, stamp(self.now.wall)))
            self.db.execute("INSERT INTO timer_sessions VALUES (?,?,'paused','',?)",
                            (session_id, activity["id"], stamp(self.now.wall)))
            action = "timer_start"
        self.open_interval(session_id)
        self.store._event(activity["id"], action)
        return self.result(session_id)

    def advance(self, interval):
        # Called only after the transaction's health check. Never use wall time
        # as duration or count an unconfirmed gap after an interruption.
        seconds = interval["duration_seconds"] + self.now.mono - interval["checkpoint_mono"]
        self.db.execute("""UPDATE session_intervals SET duration_seconds=?, checkpoint_utc=?,
            checkpoint_wall=?, checkpoint_mono=?, checkpoint_boot=? WHERE id=?""",
            (seconds, stamp(self.now.wall), self.now.wall, self.now.mono, self.now.boot, interval["id"]))
        self.db.execute("""UPDATE sessions SET minutes=(SELECT SUM(duration_seconds)/60.0
            FROM session_intervals WHERE session_id=?) WHERE id=?""", (interval["session_id"], interval["session_id"]))

    def close_interval(self, session, interval, status, recover=False):
        if session["status"] == "running" and not recover:
            self.advance(interval)
        if interval["end_utc"] is None:
            self.db.execute("UPDATE session_intervals SET end_utc=checkpoint_utc WHERE id=?", (interval["id"],))
        self.db.execute("UPDATE timer_sessions SET status=?, recovery_reason='', updated_at=? WHERE session_id=?",
                        (status, stamp(self.now.wall), session["session_id"]))
        self.store._event(session["activity_id"], "timer_recover_" + status if recover else "timer_" + status)

    def mutate(self, op, args):
        if op == "timer_start":
            return self.start(args.get("activityId"))
        if op == "timer_switch":
            session = self.session(args.get("expectedSessionId"))
            interval = self.expected(session, args.get("expectedIntervalId"))
            self.require_healthy(session)
            if session["status"] != "running":
                raise StoreError("conflict", "The active timer changed. Review it before switching.")
            activity = self.target(args.get("activityId"))
            if activity["id"] != session["activity_id"]:
                self.close_interval(session, interval, "paused")
            return self.start(activity["id"])
        session = self.session(args.get("sessionId"))
        if op == "timer_resume":
            self.require_healthy(session)
            if session["status"] not in ("paused", "running"):
                raise StoreError("conflict", "A stopped session cannot be resumed. Start a new timer instead.")
            return self.start(session["activity_id"])
        interval = self.expected(session, args.get("intervalId"))
        if op == "timer_checkpoint":
            if not self.owned(interval):
                raise StoreError("not_owner", "Only the live timer owner can confirm elapsed time.")
            if session["status"] == "running":
                self.advance(interval)
            elif session["status"] != "interrupted":
                raise StoreError("conflict", "This timer is no longer running.")
        elif op == "timer_recover":
            action = args.get("action")
            if action not in ("pause", "stop", "resume"):
                raise StoreError("validation", "Recovery action must be pause, stop, or resume.")
            if session["status"] != "interrupted":
                raise StoreError("conflict", "This timer no longer needs recovery.")
            self.close_interval(session, interval, "stopped" if action == "stop" else "paused", recover=True)
            if action == "resume":
                self.target(session["activity_id"])
                self.open_interval(session["session_id"])
                self.store._event(session["activity_id"], "timer_resume")
        else:
            self.require_healthy(session)
            if op == "timer_pause":
                if session["status"] == "stopped":
                    raise StoreError("conflict", "This timer has already stopped.")
                if session["status"] == "running":
                    self.close_interval(session, interval, "paused")
            elif op == "timer_stop":
                complete = boolean(args.get("completeActivity", False), "completeActivity")
                note = text(args["note"], "note") if "note" in args else None
                if session["status"] != "stopped":
                    self.close_interval(session, interval, "stopped")
                if note is not None:
                    self.db.execute("UPDATE sessions SET note=?,revision=revision+1 WHERE id=?", (note, session["session_id"]))
                if complete:
                    self.store._complete(session["activity_id"], True)
        return self.result(session["session_id"])

    def decorate(self, session, timer, intervals):
        if not intervals:
            raise StoreError("storage", "A timed session has no recorded interval. Existing records were not replaced.")
        latest = intervals[-1]
        reason = timer["recovery_reason"]
        live = bool(self.store.client_id)
        if live and timer["status"] == "running":
            reason = self.reason(latest)
        status = "interrupted" if reason else timer["status"]
        confirmed = sum(i["duration_seconds"] for i in intervals)
        elapsed = confirmed + (self.now.mono - latest["checkpoint_mono"] if live and status == "running" else 0)
        days = {}
        for interval in intervals:
            for day, seconds in allocated_days(interval, interval["duration_seconds"]).items():
                days[day] = days.get(day, 0.0) + seconds
        session.update(status=status, minutes=confirmed / 60, confirmedSeconds=confirmed, elapsedSeconds=elapsed,
                       intervalId=latest["id"], startedAt=intervals[0]["start_utc"], checkpointAt=latest["checkpoint_utc"],
                       recoveryReason=reason, ownedByCaller=live and self.owned(latest),
                       days=[{"date": day, "seconds": days[day]} for day in sorted(days)],
                       intervals=[{"id": i["id"], "startUtc": i["start_utc"], "endUtc": i["end_utc"],
                                   "checkpointUtc": i["checkpoint_utc"], "durationSeconds": i["duration_seconds"],
                                   "timeZone": i["time_zone"], "offsetSeconds": i["offset_seconds"],
                                   "localDate": i["local_date"]} for i in intervals])
        return session

    def summary(self, sessions):
        timers = [s for s in sessions if s["source"] == "timer"]
        paused_ids = [r["session_id"] for r in self.db.execute(
            "SELECT session_id FROM timer_sessions WHERE status='paused' ORDER BY updated_at DESC, rowid DESC")]
        by_id = {s["id"]: s for s in timers}
        return {"active": next((s for s in timers if s["status"] in ("running", "interrupted")), None),
                "paused": [by_id[key] for key in paused_ids], "checkpointIntervalMs": 5000,
                "graceSeconds": GRACE_SECONDS, "autoPauseOnLock": False}
