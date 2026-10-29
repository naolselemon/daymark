"""Isolated timer regressions: real wire/process races and injected clock boundaries."""

from contextlib import closing
from dataclasses import replace
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

from backend.storage import MIGRATIONS, SOURCE_ROOT, Store, StoreError
from backend.timer import ClockSample, process_identity


HELPER = SOURCE_ROOT / "backend/helper.py"


class FakeClock:
    def __init__(self, instant="2025-01-01T12:00:00+00:00", zone="UTC"):
        wall = datetime.fromisoformat(instant).timestamp()
        offset = int(datetime.fromtimestamp(wall, ZoneInfo(zone)).utcoffset().total_seconds())
        self.value = ClockSample(wall, 100.0, 100.0, "test-boot", zone, offset)
        self.identity = (123, "process-start")
        self.live = {self.identity}

    def sample(self):
        return self.value

    def owner(self):
        return self.identity

    def alive(self, pid, start):
        return (pid, start) in self.live

    def advance(self, seconds, *, wall=None, boot=None):
        self.value = replace(self.value, wall=self.value.wall + (seconds if wall is None else wall),
                             mono=self.value.mono + seconds, boot=self.value.boot + (seconds if boot is None else boot))

    def zone(self, name):
        offset = int(datetime.fromtimestamp(self.value.wall, ZoneInfo(name)).utcoffset().total_seconds())
        self.value = replace(self.value, time_zone=name, offset=offset)


class TimerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daylog-timer-")
        self.addCleanup(self.temporary.cleanup)
        self.profile = Path(self.temporary.name) / "profile"
        self.clock = FakeClock()
        self.sequence = 0
        self.store = Store(self.profile, clock=self.clock)
        self.addCleanup(self.store.close)

    def request(self, op, args=None, client="view-a", request_id=None):
        self.sequence += 1
        return {"protocol": 1, "requestId": request_id or f"timer-{self.sequence}",
                "op": op, "args": args or {}, "clientId": client}

    def call(self, op, args=None, **options):
        return self.store.handle(self.request(op, args, **options))

    def fail(self, code, op, args=None, **options):
        with self.assertRaises(StoreError) as error:
            self.call(op, args, **options)
        self.assertEqual(error.exception.code, code)

    def create(self, title="Timer fixture", **args):
        return self.call("create_activity", dict(title=title, **args))["result"]["activityId"]

    def start(self, activity=None):
        return self.call("timer_start", {"activityId": activity or self.create()})["snapshot"]["timer"]["active"]

    def expected(self, session):
        return {"sessionId": session["id"], "intervalId": session["intervalId"]}

    def snapshot(self):
        return self.call("snapshot")["snapshot"]

    def test_double_start_receipt_and_repeated_resume_never_duplicate_intervals(self):
        activity = self.create()
        request = self.request("timer_start", {"activityId": activity})
        first = self.store.handle(request)
        self.assertEqual(self.store.handle(request)["result"], first["result"])
        active = self.start(activity)
        resumed = self.call("timer_resume", {"sessionId": active["id"]})["snapshot"]["timer"]["active"]
        self.assertEqual(resumed["intervalId"], active["intervalId"])
        self.assertEqual(len(resumed["intervals"]), 1)
        self.assertEqual(resumed["confirmedSeconds"], 0)
        self.assertEqual(resumed["minutes"], 0)
        self.assertEqual(len(self.snapshot()["sessions"]), 1)
        changed = dict(request, clientId="view-b")
        with self.assertRaises(StoreError) as error:
            self.store.handle(changed)
        self.assertEqual(error.exception.code, "conflict")

    def test_pause_resume_stop_preserve_intervals_notes_and_completion_independence(self):
        session = self.start()
        self.clock.advance(5)
        checkpoint = self.call("timer_checkpoint", self.expected(session))["snapshot"]["timer"]["active"]
        self.assertEqual(checkpoint["confirmedSeconds"], 5)
        self.clock.advance(3)
        paused = self.call("timer_pause", self.expected(session))["snapshot"]
        self.assertIsNone(paused["timer"]["active"])
        self.assertEqual(paused["timer"]["paused"][0]["confirmedSeconds"], 8)
        self.clock.advance(3600)
        resumed = self.call("timer_resume", {"sessionId": session["id"]})["snapshot"]["timer"]["active"]
        self.assertNotEqual(resumed["intervalId"], session["intervalId"])
        self.assertEqual(resumed["confirmedSeconds"], 8)
        self.clock.advance(2)
        stopped = self.call("timer_stop", dict(self.expected(resumed), note="Kept session note"))["snapshot"]
        self.assertEqual(stopped["sessions"][0]["confirmedSeconds"], 10)
        self.assertEqual(stopped["sessions"][0]["note"], "Kept session note")
        self.assertEqual(stopped["activities"][0]["status"], "open")
        self.assertEqual(len(stopped["sessions"][0]["intervals"]), 2)
        self.assertTrue(all(i["endUtc"] for i in stopped["sessions"][0]["intervals"]))
        new_session = self.start(session["activityId"])
        self.assertNotEqual(new_session["id"], session["id"])

    def test_switch_is_atomic_and_stale_confirmation_cannot_touch_new_interval(self):
        first = self.start()
        other = self.create("Other fixture")
        self.fail("switch_required", "timer_start", {"activityId": other})
        self.clock.advance(4)
        switch = {"activityId": other, "expectedSessionId": first["id"], "expectedIntervalId": first["intervalId"]}
        second = self.call("timer_switch", switch)["snapshot"]["timer"]["active"]
        self.fail("conflict", "timer_switch", switch)
        self.call("timer_pause", self.expected(second))
        new_first = self.start(first["activityId"])
        self.fail("conflict", "timer_pause", self.expected(first))
        self.fail("conflict", "timer_stop", dict(self.expected(first), completeActivity=True))
        self.fail("conflict", "timer_switch", switch)
        current = self.snapshot()["timer"]["active"]
        self.assertEqual(current["intervalId"], new_first["intervalId"])
        self.assertEqual(current["confirmedSeconds"], 4)
        self.assertTrue(all(a["status"] == "open" for a in self.snapshot()["activities"]))

    def test_invalid_switch_target_does_not_pause_current_timer(self):
        active = self.start()
        done = self.create("Completed fixture", done=True)
        self.fail("activity_done", "timer_switch", {"activityId": done, "expectedSessionId": active["id"],
                                                    "expectedIntervalId": active["intervalId"]})
        self.assertEqual(self.snapshot()["timer"]["active"]["intervalId"], active["intervalId"])

    def test_completion_requires_explicit_stop_and_manual_work_still_works(self):
        active = self.start()
        for status in ("running", "paused"):
            with self.subTest(status=status):
                self.fail("timer_unfinished", "set_done", {"activityId": active["activityId"], "done": True, "expectedRevision": self.snapshot()["activities"][0]["revision"]})
                self.fail("timer_unfinished", "add_session", {"activityId": active["activityId"], "date": "2025-01-01", "done": True})
                self.assertEqual(len(self.snapshot()["sessions"]), 1)
                if status == "running":
                    self.call("timer_pause", self.expected(active))
        logged = self.call("add_session", {"activityId": active["activityId"], "date": "2024-12-31"})
        self.assertIsNone(next(s for s in logged["snapshot"]["sessions"] if s["source"] == "untimed")["minutes"])
        stopped = self.call("timer_stop", dict(self.expected(active), completeActivity=True))["snapshot"]
        self.assertEqual(stopped["activities"][0]["status"], "done")
        self.fail("activity_done", "timer_start", {"activityId": active["activityId"]})
        self.call("set_done", {"activityId": active["activityId"], "done": False, "expectedRevision": stopped["activities"][0]["revision"]})
        self.assertEqual(self.start(active["activityId"])["status"], "running")

    def test_checkpoint_owner_and_foreign_explicit_controls(self):
        active = self.start()
        self.clock.advance(5)
        foreign = self.call("snapshot", client="view-b")["snapshot"]["timer"]["active"]
        self.assertFalse(foreign["ownedByCaller"])
        self.assertEqual(foreign["elapsedSeconds"], 5)
        self.assertEqual(foreign["confirmedSeconds"], 0)
        self.fail("not_owner", "timer_checkpoint", self.expected(active), client="view-b")
        self.assertEqual(self.snapshot()["timer"]["active"]["confirmedSeconds"], 0)
        self.call("timer_pause", self.expected(active), client="view-b")
        self.assertEqual(self.snapshot()["timer"]["paused"][0]["confirmedSeconds"], 5)
        resumed = self.call("timer_resume", {"sessionId": active["id"]}, client="view-b")["snapshot"]["timer"]["active"]
        self.assertTrue(resumed["ownedByCaller"])
        self.fail("not_owner", "timer_checkpoint", self.expected(resumed))

    def test_reload_new_client_cannot_adopt_owner_and_gap_never_counts(self):
        active = self.start()
        self.clock.advance(5)
        self.call("timer_checkpoint", self.expected(active))
        self.clock.advance(10)
        same = self.call("timer_start", {"activityId": active["activityId"]}, client="reloaded")["snapshot"]["timer"]["active"]
        self.assertFalse(same["ownedByCaller"])
        self.fail("not_owner", "timer_checkpoint", self.expected(active), client="reloaded")
        self.clock.advance(6)
        interrupted = self.call("snapshot", client="reloaded")["snapshot"]["timer"]["active"]
        self.assertEqual((interrupted["status"], interrupted["recoveryReason"]), ("interrupted", "checkpoint_gap"))
        self.assertEqual(interrupted["elapsedSeconds"], 5)
        resumed = self.call("timer_recover", dict(self.expected(active), action="resume"), client="reloaded")["snapshot"]["timer"]["active"]
        self.assertNotEqual(resumed["intervalId"], active["intervalId"])
        self.assertEqual(resumed["confirmedSeconds"], 5)
        self.assertTrue(resumed["ownedByCaller"])
        self.fail("conflict", "timer_recover", dict(self.expected(active), action="stop"))

    def test_thresholds_and_checkpoint_repeats_use_measured_duration(self):
        active = self.start()
        self.clock.advance(15, wall=17, boot=15.5)
        request = self.request("timer_checkpoint", self.expected(active))
        acknowledged = self.store.handle(request)["snapshot"]["timer"]["active"]
        self.assertEqual(acknowledged["status"], "running")
        self.assertEqual(acknowledged["confirmedSeconds"], 15)
        replay = self.store.handle(request)["snapshot"]["timer"]["active"]
        self.assertEqual(replay["confirmedSeconds"], 15)
        self.clock.advance(1, wall=3.01)
        interrupted = self.call("timer_checkpoint", self.expected(active))["snapshot"]["timer"]["active"]
        self.assertEqual(interrupted["status"], "interrupted")
        self.assertEqual(interrupted["confirmedSeconds"], 15)

    def test_sub_tolerance_wall_reversal_cannot_close_before_interval_start(self):
        active = self.start()
        self.clock.advance(0.1, wall=-0.3)
        self.fail("recovery_required", "timer_stop", self.expected(active))
        interrupted = self.snapshot()["timer"]["active"]
        self.assertEqual(interrupted["recoveryReason"], "clock_changed")
        self.assertEqual(interrupted["confirmedSeconds"], 0)
        self.assertIsNone(interrupted["intervals"][0]["endUtc"])
        recovered = self.call("timer_recover", dict(self.expected(active), action="stop"))["snapshot"]["sessions"][0]
        self.assertEqual(recovered["intervals"][0]["endUtc"], recovered["intervals"][0]["startUtc"])
        self.assertEqual(recovered["confirmedSeconds"], 0)

    def test_stop_and_complete_failure_rolls_back_interval_and_session_note(self):
        active = self.start()
        self.clock.advance(5)
        self.store.connection.execute("""CREATE TRIGGER refuse_timer_completion BEFORE UPDATE OF status ON activities
            WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END""")
        self.fail("storage", "timer_stop", dict(self.expected(active), completeActivity=True, note="Unsaved draft"))
        current = self.snapshot()["timer"]["active"]
        self.assertEqual(current["intervalId"], active["intervalId"])
        self.assertEqual(current["confirmedSeconds"], 0)
        self.assertEqual(current["note"], "")
        self.assertIsNone(current["intervals"][0]["endUtc"])
        self.store.connection.execute("DROP TRIGGER refuse_timer_completion")
        stopped = self.call("timer_stop", dict(self.expected(active), completeActivity=True, note="Saved draft"))["snapshot"]
        self.assertEqual(stopped["activities"][0]["status"], "done")
        self.assertEqual(stopped["sessions"][0]["confirmedSeconds"], 5)
        self.assertEqual(stopped["sessions"][0]["note"], "Saved draft")

    def test_clock_suspend_boot_and_owner_discontinuities_freeze_confirmed_time(self):
        cases = (("clock_changed", lambda c: c.advance(1, wall=-10)),
                 ("clock_changed", lambda c: c.advance(1, wall=100)),
                 ("suspend_detected", lambda c: c.advance(1, wall=21, boot=21)),
                 ("checkpoint_gap", lambda c: c.advance(16)),
                 ("system_restart", lambda c: setattr(c, "value", replace(c.value, boot_id="next-boot"))),
                 ("owner_exited", lambda c: c.live.clear()),
                 ("owner_exited", lambda c: setattr(c, "live", {(123, "reused-pid-start")})))
        for index, (reason, change) in enumerate(cases):
            with self.subTest(reason=reason, index=index):
                profile = Path(self.temporary.name) / f"discontinuity-{index}"
                clock = FakeClock()
                with Store(profile, clock=clock) as store:
                    activity = store.handle(self.request("create_activity", {"title": "Isolated fixture"}))["result"]["activityId"]
                    active = store.handle(self.request("timer_start", {"activityId": activity}))["snapshot"]["timer"]["active"]
                    clock.advance(5)
                    store.handle(self.request("timer_checkpoint", self.expected(active)))
                    change(clock)
                    response = store.handle(self.request("snapshot"))["snapshot"]["timer"]["active"]
                    self.assertEqual(response["status"], "interrupted")
                    self.assertEqual(response["recoveryReason"], reason)
                    self.assertEqual(response["elapsedSeconds"], 5)
                    self.assertEqual(response["confirmedSeconds"], 5)

    def test_unhealthy_checkpoint_returns_successful_interrupted_snapshot(self):
        active = self.start()
        self.clock.advance(16)
        response = self.call("timer_checkpoint", self.expected(active))
        self.assertTrue(response["ok"])
        self.assertEqual(response["snapshot"]["timer"]["active"]["status"], "interrupted")
        self.assertEqual(response["snapshot"]["timer"]["active"]["confirmedSeconds"], 0)

    def test_rejected_transition_durably_latches_transient_clock_fault(self):
        active = self.start()
        before = self.clock.value
        self.clock.advance(1, wall=-10)
        self.fail("recovery_required", "timer_start", {"activityId": active["activityId"]})
        self.clock.value = before
        with Store(self.profile, clock=self.clock) as restarted:
            interrupted = restarted.handle(self.request("snapshot"))["snapshot"]["timer"]["active"]
        self.assertEqual(interrupted["recoveryReason"], "clock_changed")
        self.fail("recovery_required", "timer_stop", self.expected(active))
        paused = self.call("timer_recover", dict(self.expected(active), action="pause"))["snapshot"]
        self.assertIsNone(paused["timer"]["active"])
        self.assertEqual(paused["timer"]["paused"][0]["confirmedSeconds"], 0)
        self.assertEqual(paused["sessions"][0]["intervals"][0]["endUtc"], active["checkpointAt"])
        self.assertEqual(paused["activities"][0]["status"], "open")

    def test_read_only_snapshot_truthful_without_latching_or_changing_database(self):
        active = self.start()
        self.clock.advance(20)
        database = self.profile / "daylog.sqlite3"
        before = database.read_bytes()
        with Store(self.profile, read_only=True, clock=self.clock) as readonly:
            snapshot = readonly.handle(self.request("snapshot"))["snapshot"]
            self.assertEqual(snapshot["timer"]["active"]["status"], "interrupted")
            with self.assertRaises(StoreError) as error:
                readonly.handle(self.request("timer_recover", dict(self.expected(active), action="stop")))
            self.assertEqual(error.exception.code, "read_only")
        self.assertEqual(database.read_bytes(), before)
        self.assertEqual(self.store.connection.execute("SELECT status FROM timer_sessions").fetchone()[0], "running")
        recovered = self.call("timer_recover", dict(self.expected(active), action="stop"))["snapshot"]
        self.assertEqual(recovered["sessions"][0]["status"], "stopped")
        self.assertEqual(recovered["activities"][0]["status"], "open")

    def test_day_rollover_history_slices_and_travel_do_not_move_earlier_time(self):
        self.clock.value = replace(self.clock.value, wall=datetime(2025, 1, 1, 23, 59, 55, tzinfo=timezone.utc).timestamp())
        active = self.start()
        self.clock.advance(10)
        paused = self.call("timer_pause", self.expected(active))["snapshot"]["timer"]["paused"][0]
        self.assertEqual(paused["days"], [{"date": "2025-01-01", "seconds": 5}, {"date": "2025-01-02", "seconds": 5}])
        history = self.call("history", {"from": "2025-01-02", "to": "2025-01-02"})["result"]["sessions"]
        self.assertEqual(len(history), 1)
        self.assertTrue(history[0]["slice"])
        self.assertEqual(history[0]["minutes"], 5 / 60)
        self.assertEqual(history[0]["id"], active["id"])
        self.clock.zone("America/Los_Angeles")
        resumed = self.start(active["activityId"])
        self.clock.advance(5)
        final = self.call("timer_stop", self.expected(resumed))["snapshot"]["sessions"][0]
        self.assertEqual(final["days"], [{"date": "2025-01-01", "seconds": 10}, {"date": "2025-01-02", "seconds": 5}])
        self.assertEqual([i["timeZone"] for i in final["intervals"]], ["UTC", "America/Los_Angeles"])
        self.assertEqual([i["offsetSeconds"] for i in final["intervals"]], [0, -28800])
        self.assertEqual(final["confirmedSeconds"], 15)
        self.assertEqual(len(self.snapshot()["sessions"]), 1)

    def test_dst_spring_gap_and_fall_fold_are_measured_not_wall_hours(self):
        for index, instant in enumerate(("2025-03-09T01:59:55-05:00", "2025-11-02T01:59:55-04:00")):
            with self.subTest(instant=instant):
                clock = FakeClock(instant, "America/New_York")
                with Store(Path(self.temporary.name) / f"dst-{index}", clock=clock) as store:
                    activity = store.handle(self.request("create_activity", {"title": "DST fixture"}))["result"]["activityId"]
                    active = store.handle(self.request("timer_start", {"activityId": activity}))["snapshot"]["timer"]["active"]
                    clock.advance(10)
                    stopped = store.handle(self.request("timer_stop", self.expected(active)))["snapshot"]["sessions"][0]
                    self.assertEqual(stopped["confirmedSeconds"], 10)
                    self.assertEqual(stopped["days"], [{"date": instant[:10], "seconds": 10}])
                    self.assertEqual(stopped["intervals"][0]["offsetSeconds"], -18000 if index == 0 else -14400)

    def test_every_timer_transition_receipt_replays_without_modifying_newer_state(self):
        activity = self.create()
        saved = []

        def apply(op, args):
            request = self.request(op, args)
            response = self.store.handle(request)
            saved.append((request, response["result"]))
            return response["snapshot"]["timer"]["active"]

        first = apply("timer_start", {"activityId": activity})
        apply("timer_pause", self.expected(first))
        resumed = apply("timer_resume", {"sessionId": first["id"]})
        other = self.create("Receipt fixture")
        second = apply("timer_switch", {"activityId": other, "expectedSessionId": resumed["id"], "expectedIntervalId": resumed["intervalId"]})
        self.clock.advance(16)
        apply("timer_recover", dict(self.expected(second), action="resume"))
        current = self.snapshot()["timer"]["active"]
        apply("timer_stop", self.expected(current))
        before = self.snapshot()
        for request, result in saved:
            with self.subTest(op=request["op"]):
                replay = self.store.handle(request)
                self.assertEqual(replay["result"], result)
                self.assertEqual(replay["snapshot"], before)

    def test_database_constraints_reject_global_and_per_activity_duplicates(self):
        active = self.start()
        other = self.create("Constraint fixture")
        db = self.store.connection
        db.execute("INSERT INTO sessions (id,activity_id,local_date,minutes,note,source,created_at) VALUES ('candidate',?,'2025-01-01',0,'','timer','2025-01-01T00:00:00Z')", (other,))
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("INSERT INTO timer_sessions VALUES ('candidate',?,'running','','now')", (other,))
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("INSERT INTO timer_sessions VALUES ('candidate',?,'paused','','now')", (active["activityId"],))
        db.execute("INSERT INTO timer_sessions VALUES ('candidate',?,'paused','','now')", (other,))
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("""INSERT INTO session_intervals SELECT 'duplicate','candidate',start_utc,end_utc,
                checkpoint_utc,duration_seconds,checkpoint_wall,checkpoint_mono,checkpoint_boot,boot_id,
                owner_pid,owner_start,client_id,time_zone,offset_seconds,local_date FROM session_intervals""")
        # Remove only the deliberately incomplete constraint fixture.
        db.execute("DELETE FROM timer_sessions WHERE session_id='candidate'")
        db.execute("DELETE FROM sessions WHERE id='candidate'")

    def test_v2_wal_upgrade_backup_preserves_manual_and_untimed_records(self):
        profile = Path(self.temporary.name) / "v2"
        profile.mkdir()
        db = sqlite3.connect(profile / "daylog.sqlite3")
        self.addCleanup(db.close)
        db.execute("PRAGMA journal_mode=WAL")
        for version in (1, 2):
            for statement in MIGRATIONS[version]:
                db.execute(statement)
            db.execute("INSERT INTO schema_migrations VALUES (?, 'fixture')", (version,))
        db.execute("INSERT INTO activities VALUES ('activity','Migration fixture',NULL,NULL,'','open','','fixture','','',1)")
        db.execute("INSERT INTO sessions VALUES ('manual','activity','2025-01-01',2.5,'','manual','fixture')")
        db.execute("INSERT INTO sessions VALUES ('untimed','activity','2025-01-02',NULL,'','untimed','fixture')")
        db.execute("PRAGMA user_version=2")
        db.commit()
        with Store(profile, clock=self.clock) as upgraded:
            sessions = upgraded.handle(self.request("snapshot"))["snapshot"]["sessions"]
        self.assertEqual({s["id"]: s["minutes"] for s in sessions}, {"manual": 2.5, "untimed": None})
        backups = list(profile.glob("daylog.before-v2-*.sqlite3"))
        self.assertEqual(len(backups), 1)
        with closing(sqlite3.connect(backups[0])) as backup:
            self.assertEqual(backup.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(backup.execute("SELECT COUNT(*) FROM sessions").fetchone()[0], 2)
            self.assertEqual(backup.execute("PRAGMA integrity_check").fetchone()[0], "ok")


class TimerProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daylog-timer-process-")
        self.addCleanup(self.temporary.cleanup)
        self.profile = Path(self.temporary.name) / "profile"
        self.sequence = 0

    def request(self, op, args=None, client="process-view"):
        self.sequence += 1
        return {"protocol": 1, "requestId": f"process-{self.sequence}", "op": op, "args": args or {}, "clientId": client}

    def invoke(self, request, read_only=False):
        command = [sys.executable, str(HELPER), "--profile", str(self.profile)]
        if read_only:
            command.append("--read-only")
        process = subprocess.run(command, input=json.dumps(request) + "\n", text=True, capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "")
        return json.loads(process.stdout)

    def create(self, title):
        response = self.invoke(self.request("create_activity", {"title": title}))
        self.assertTrue(response["ok"], response)
        return response["result"]["activityId"]

    def test_racing_identical_requests_replay_one_durable_start(self):
        activity = self.create("Idempotent race fixture")
        request = self.request("timer_start", {"activityId": activity})
        command = [sys.executable, str(HELPER), "--profile", str(self.profile)]
        processes = [subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for _ in range(2)]
        for process in processes:
            process.stdin.write((json.dumps(request) + "\n").encode())
            process.stdin.close()
            process.stdin = None
        responses = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stderr, b"")
            responses.append(json.loads(stdout))
        self.assertTrue(all(r["ok"] for r in responses), responses)
        self.assertEqual(responses[0]["result"], responses[1]["result"])
        self.assertEqual(len(responses[1]["snapshot"]["sessions"]), 1)
        self.assertEqual(len(responses[1]["snapshot"]["timer"]["active"]["intervals"]), 1)

    def test_concurrent_helper_clients_have_one_global_winner(self):
        activities = [self.create("Race fixture A"), self.create("Race fixture B")]
        command = [sys.executable, str(HELPER), "--profile", str(self.profile)]
        processes = []
        for index, activity in enumerate(activities):
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            process.stdin.write((json.dumps(self.request("timer_start", {"activityId": activity}, client=f"view-{index}")) + "\n").encode())
            process.stdin.close()
            process.stdin = None
            processes.append(process)
        responses = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stderr, b"")
            responses.append(json.loads(stdout))
        self.assertEqual(sum(r["ok"] for r in responses), 1, responses)
        self.assertEqual([r["error"]["code"] for r in responses if not r["ok"]], ["switch_required"])
        snapshot = self.invoke(self.request("snapshot"))["snapshot"]
        self.assertEqual(len(snapshot["sessions"]), 1)
        self.assertEqual(len(snapshot["sessions"][0]["intervals"]), 1)
        with closing(sqlite3.connect(self.profile / "daylog.sqlite3")) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM session_intervals WHERE end_utc IS NULL").fetchone()[0], 1)

    def test_owner_exit_and_zombie_are_immediately_visible_after_helper_restart(self):
        activity = self.create("Owner exit fixture")
        request = self.request("timer_start", {"activityId": activity})
        launcher = """import subprocess, sys
p = subprocess.run([sys.executable, sys.argv[1], '--profile', sys.argv[2]], input=sys.argv[3]+'\\n', text=True, capture_output=True, check=True)
print(p.stdout.strip(), flush=True)
sys.stdin.readline()
"""
        owner = subprocess.Popen([sys.executable, "-c", launcher, str(HELPER), str(self.profile), json.dumps(request)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: owner.kill() if owner.poll() is None else None)
        started = json.loads(owner.stdout.readline())
        self.assertTrue(started["ok"], started)
        active = started["snapshot"]["timer"]["active"]
        live = self.invoke(self.request("snapshot"))["snapshot"]["timer"]["active"]
        self.assertEqual(live["status"], "running")
        self.assertFalse(live["ownedByCaller"])
        owner.stdin.write("exit\n")
        owner.stdin.flush()
        # Wait for exit without reaping, so the helper must reject a zombie owner.
        self.assertEqual(owner.stdout.read(), "")
        os.waitid(os.P_PID, owner.pid, os.WEXITED | os.WNOWAIT)
        self.assertIsNone(process_identity(owner.pid))
        readonly = self.invoke(self.request("snapshot"), read_only=True)["snapshot"]["timer"]["active"]
        self.assertEqual(readonly["recoveryReason"], "owner_exited")
        self.assertEqual(readonly["elapsedSeconds"], 0)
        owner.communicate(timeout=10)
        blocked = self.invoke(self.request("timer_start", {"activityId": activity}))
        self.assertEqual(blocked["error"]["code"], "recovery_required")
        recovered = self.invoke(self.request("timer_recover", {"sessionId": active["id"], "intervalId": active["intervalId"], "action": "resume"}))
        self.assertTrue(recovered["ok"], recovered)
        resumed = recovered["snapshot"]["timer"]["active"]
        self.assertEqual(resumed["confirmedSeconds"], 0)
        self.assertNotEqual(resumed["intervalId"], active["intervalId"])

    def test_missing_client_rejected_before_profile_creation_and_fake_wire_clock_ignored(self):
        request = self.request("timer_start", {"activityId": "missing"})
        del request["clientId"]
        response = self.invoke(request)
        self.assertEqual(response["error"]["code"], "protocol")
        self.assertFalse(self.profile.exists())
        activity = self.create("Clock isolation fixture")
        request = self.request("timer_start", {"activityId": activity, "now": "1900-01-01", "clock": -1})
        response = self.invoke(request)
        self.assertTrue(response["ok"], response)
        self.assertFalse(response["snapshot"]["timer"]["active"]["startedAt"].startswith("1900"))


if __name__ == "__main__":
    unittest.main()
