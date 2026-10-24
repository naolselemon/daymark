"""Standalone countdown state; deliberately outside journal tables and archives."""
from contextlib import closing
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import time

try:
    from .storage import StoreError, boolean, profile_path, revision, text
except ImportError:
    from storage import StoreError, boolean, profile_path, revision, text

OPERATIONS = {"countdown_status", "countdown_start", "countdown_pause",
              "countdown_resume", "countdown_reset", "countdown_mute"}
MAX_SECONDS = 99 * 3600 + 59 * 60 + 59


class Clock:
    def sample(self):
        return (Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                time.clock_gettime(time.CLOCK_BOOTTIME))


class CountdownStore:
    def __init__(self, profile=None, read_only=False, clock=None):
        self.path = profile_path(profile) / "countdown.sqlite3"
        self.read_only = read_only
        self.clock = clock or Clock()

    def handle(self, request):
        op, args = request["op"], request["args"]
        if op not in OPERATIONS:
            raise StoreError("protocol", "Unknown countdown operation.")
        if self.read_only:
            raise StoreError("read_only", "Countdown state is unavailable in a read-only profile.")
        observer = text(args.get("observer"), "observer", required=True)
        attach = boolean(args.get("attach", False), "attach")
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.path.is_symlink():
            raise StoreError("storage", "A countdown database symlink is not a supported profile.")
        fd = os.open(self.path, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            if stat.S_IMODE(os.fstat(fd).st_mode) != 0o600:
                os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
        with closing(sqlite3.connect(self.path, timeout=5)) as db:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA synchronous=FULL")
            db.execute("BEGIN IMMEDIATE")
            try:
                db.execute("""CREATE TABLE IF NOT EXISTS countdown (
                    id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
                    status TEXT NOT NULL, duration INTEGER NOT NULL, remaining REAL NOT NULL,
                    deadline REAL NOT NULL, boot TEXT NOT NULL, observer TEXT NOT NULL,
                    muted INTEGER NOT NULL, recovery TEXT NOT NULL)""")
                db.execute("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, digest TEXT NOT NULL)")
                db.execute("INSERT OR IGNORE INTO countdown VALUES (1,0,'idle',0,0,0,'','',0,'')")
                state = dict(db.execute("SELECT * FROM countdown WHERE id=1").fetchone())
                boot, now = self.clock.sample()
                sound = False
                # Restart attaches before completion is evaluated: an already-expired
                # timer is visible, but never produces a delayed startup sound.
                if state["status"] == "running":
                    if state["boot"] != boot:
                        state.update(status="paused", deadline=0, recovery="reboot")
                        state["revision"] += 1
                    else:
                        state["remaining"] = max(0, state["deadline"] - now)
                        if state["remaining"] == 0:
                            sound = (not attach and observer == state["observer"]
                                     and now - state["deadline"] <= 3 and not state["muted"])
                            state.update(status="finished", recovery="" if sound else "expired")
                            state["revision"] += 1
                if attach:
                    state["observer"] = observer
                if op != "countdown_status":
                    digest = hashlib.sha256(json.dumps({"op": op, "args": args}, sort_keys=True,
                                                      allow_nan=False).encode()).hexdigest()
                    receipt = db.execute("SELECT digest FROM receipts WHERE id=?", (request["requestId"],)).fetchone()
                    if receipt:
                        if receipt["digest"] != digest:
                            raise StoreError("conflict", "This request identity was already used for another countdown change.")
                        sound = False
                    else:
                        expected = revision(args.get("expectedRevision"))
                        if expected != state["revision"]:
                            raise StoreError("conflict", "The countdown changed. Refresh its state before trying again.")
                        if op == "countdown_start":
                            seconds = args.get("seconds")
                            if type(seconds) is not int or not 1 <= seconds <= MAX_SECONDS:
                                raise StoreError("validation", "Choose a duration from 00:00:01 to 99:59:59.")
                            if state["status"] not in ("idle", "finished"):
                                raise StoreError("conflict", "Cancel the existing countdown before starting another.")
                            state.update(status="running", duration=seconds, remaining=seconds,
                                         deadline=now + seconds, boot=boot, observer=observer, recovery="")
                        elif op == "countdown_pause":
                            if state["status"] != "running":
                                raise StoreError("conflict", "Only a running countdown can be paused.")
                            state.update(status="paused", deadline=0, recovery="")
                        elif op == "countdown_resume":
                            if state["status"] != "paused":
                                raise StoreError("conflict", "Only a paused countdown can be resumed.")
                            state.update(status="running", deadline=now + state["remaining"],
                                         boot=boot, observer=observer, recovery="")
                        elif op == "countdown_reset":
                            state.update(status="idle", duration=0, remaining=0, deadline=0, recovery="")
                        elif op == "countdown_mute":
                            state["muted"] = int(boolean(args.get("muted"), "muted"))
                            sound = False
                        state["revision"] += 1
                        db.execute("INSERT INTO receipts VALUES (?,?)", (request["requestId"], digest))
                db.execute("""UPDATE countdown SET revision=:revision,status=:status,duration=:duration,
                    remaining=:remaining,deadline=:deadline,boot=:boot,observer=:observer,
                    muted=:muted,recovery=:recovery WHERE id=1""", state)
                db.commit()
            except Exception:
                db.rollback()
                raise
        return {"status": state["status"], "revision": state["revision"],
                "durationSeconds": state["duration"], "remainingSeconds": math.ceil(state["remaining"]),
                "remainingExact": state["remaining"], "muted": bool(state["muted"]),
                "recovery": state["recovery"], "sound": sound}
