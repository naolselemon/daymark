"""One countdown, with an explicit receipt-reconciled handoff to the journal."""
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
    from .storage import StoreError, boolean, calendar_date, new_id, profile_path, revision, text
except ImportError:
    from storage import StoreError, boolean, calendar_date, new_id, profile_path, revision, text

OPERATIONS = {"countdown_status", "countdown_start", "countdown_pause",
              "countdown_resume", "countdown_reset", "countdown_mute", "countdown_log"}
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

    @staticmethod
    def _schema(db):
        db.execute("""CREATE TABLE IF NOT EXISTS countdown (
            id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
            status TEXT NOT NULL, duration INTEGER NOT NULL, remaining REAL NOT NULL,
            deadline REAL NOT NULL, boot TEXT NOT NULL, observer TEXT NOT NULL,
            muted INTEGER NOT NULL, recovery TEXT NOT NULL)""")
        db.execute("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, digest TEXT NOT NULL)")
        columns = {row["name"] for row in db.execute("PRAGMA table_info(countdown)")}
        for name in ("run_id", "activity_id", "task_id", "activity_title", "task_title"):
            if name not in columns:
                db.execute(f"ALTER TABLE countdown ADD COLUMN {name} TEXT NOT NULL DEFAULT ''")
        db.execute("""CREATE TABLE IF NOT EXISTS log_intents (
            run_id TEXT PRIMARY KEY, journal_id TEXT NOT NULL UNIQUE,
            payload TEXT NOT NULL, result TEXT NOT NULL DEFAULT '')""")
        db.execute("""INSERT OR IGNORE INTO countdown
            (id,revision,status,duration,remaining,deadline,boot,observer,muted,recovery)
            VALUES (1,0,'idle',0,0,0,'','',0,'')""")
        db.execute("UPDATE countdown SET run_id=? WHERE run_id='' AND status!='idle'", (new_id(),))

    @staticmethod
    def _persist(db, state):
        db.execute("""UPDATE countdown SET revision=:revision,status=:status,duration=:duration,
            remaining=:remaining,deadline=:deadline,boot=:boot,observer=:observer,
            muted=:muted,recovery=:recovery,run_id=:run_id,activity_id=:activity_id,
            task_id=:task_id,activity_title=:activity_title,task_title=:task_title WHERE id=1""", state)

    @staticmethod
    def _intent(db, run_id):
        return db.execute("SELECT * FROM log_intents WHERE run_id=?", (run_id,)).fetchone()

    @staticmethod
    def _journal_request(intent):
        return {"protocol": 1, "requestId": intent["journal_id"], "op": "add_session",
                "args": json.loads(intent["payload"])}

    def _reconcile(self, db, state, journal):
        intent = self._intent(db, state["run_id"])
        if intent and not intent["result"] and journal is not None:
            # Status may acknowledge an existing receipt, but must never create a
            # journal entry. Store.handle verifies the receipt's exact digest.
            receipt = journal.connection.execute(
                "SELECT 1 FROM request_receipts WHERE request_id=?", (intent["journal_id"],)).fetchone()
            if receipt:
                response = journal.handle(self._journal_request(intent))
                db.execute("UPDATE log_intents SET result=? WHERE run_id=?",
                           (json.dumps(response["result"], sort_keys=True), state["run_id"]))
                state["revision"] += 1

    @staticmethod
    def _payload(args):
        if any(name in args for name in ("minutes", "startUtc", "endUtc", "timeZone")):
            raise StoreError("validation", "Countdown entries are untimed; no duration or clock bounds are recorded.")
        task_ids = args.get("taskIds", [])
        if not isinstance(task_ids, list):
            raise StoreError("validation", "taskIds must be a list.")
        task_ids = [text(value, "taskId", required=True) for value in task_ids]
        if len(set(task_ids)) != len(task_ids):
            raise StoreError("validation", "Select each task only once.")
        return {"activityId": text(args.get("activityId"), "activityId", required=True),
                "taskIds": task_ids, "date": calendar_date(args.get("date")),
                "note": text(args.get("note", ""), "note"),
                "done": boolean(args.get("done", False), "done")}

    def _log(self, db, state, args, journal):
        if journal is None:
            raise StoreError("storage", "The journal is unavailable. The countdown has not been dismissed.")
        run_id = text(args.get("runId"), "runId", required=True)
        payload = self._payload(args)
        intent = self._intent(db, run_id)
        # Validate even a deselected original target in the journal transaction.
        # Old-run retries must use the original frozen target, not today's run.
        payload["countdownTaskId"] = (json.loads(intent["payload"])["countdownTaskId"]
                                      if intent else state["task_id"])
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        if intent:
            if encoded != intent["payload"]:
                raise StoreError("conflict", "This countdown already has a saved or pending entry. Retry its unchanged entry.")
        else:
            if state["run_id"] != run_id or state["status"] != "finished" or not state["activity_id"]:
                raise StoreError("conflict", "Only this finished, linked countdown can be logged.")
            if payload["activityId"] != state["activity_id"]:
                raise StoreError("conflict", "The entry must use the countdown's original activity.")
            journal.countdown_target(state["activity_id"], state["task_id"])
            for task_id in payload["taskIds"]:
                journal.countdown_target(state["activity_id"], task_id)
            # This commit precedes ANY journal write. These are separate SQLite
            # stores, not an atomic cross-store transaction. A crash after this
            # point leaves a frozen intent; a crash after the journal commit is
            # reconciled by its durable, exact-payload request receipt.
            db.execute("INSERT INTO log_intents (run_id,journal_id,payload) VALUES (?,?,?)",
                       (run_id, "countdown-log-" + run_id, encoded))
            state["revision"] += 1
            self._persist(db, state)
            db.commit()
            db.execute("BEGIN IMMEDIATE")
            state.update(dict(db.execute("SELECT * FROM countdown WHERE id=1").fetchone()))
            intent = self._intent(db, run_id)
            if intent is None or intent["payload"] != encoded:
                raise StoreError("conflict", "The entry changed after a rejected save. Refresh the countdown before retrying.")
        if not intent["result"]:
            # Keep the countdown lock while saving, so reset/start and concurrent
            # retry cannot race a writer. Receipt replay bypasses target checks:
            # deletion AFTER a committed entry must not strand its acknowledgement.
            try:
                response = journal.handle(self._journal_request(intent))
            except StoreError as error:
                # A known validation/deletion rejection rolls the journal write
                # back. Release only after checking that no receipt committed;
                # ambiguous I/O failures retain the frozen intent for replay.
                if error.code in ("validation", "not_found", "timer_unfinished") and not journal.connection.execute(
                        "SELECT 1 FROM request_receipts WHERE request_id=?", (intent["journal_id"],)).fetchone():
                    db.execute("DELETE FROM log_intents WHERE run_id=?", (run_id,))
                    state["revision"] += 1
                    self._persist(db, state)
                    db.commit()
                raise
            result = response["result"]
            db.execute("UPDATE log_intents SET result=? WHERE run_id=?",
                       (json.dumps(result, sort_keys=True), run_id))
            if state["run_id"] == run_id:
                state["revision"] += 1
        else:
            result = json.loads(intent["result"])
        return result

    def handle(self, request, journal=None):
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
                self._schema(db)
                state = dict(db.execute("SELECT * FROM countdown WHERE id=1").fetchone())
                boot, now = self.clock.sample()
                sound = False
                notify = False
                entry = None
                # Attach before evaluating completion: unavailable-shell expiry
                # stays visible, without a delayed startup alarm.
                if state["status"] == "running":
                    if state["boot"] != boot:
                        state.update(status="paused", deadline=0, recovery="reboot")
                        state["revision"] += 1
                    else:
                        state["remaining"] = max(0, state["deadline"] - now)
                        if state["remaining"] == 0:
                            notify = (not attach and observer == state["observer"]
                                      and now - state["deadline"] <= 3)
                            sound = notify and not state["muted"]
                            state.update(status="finished", recovery="" if notify else "expired")
                            state["revision"] += 1
                if attach:
                    state["observer"] = observer
                self._reconcile(db, state, journal)
                if op != "countdown_status":
                    digest = hashlib.sha256(json.dumps({"op": op, "args": args}, sort_keys=True,
                                                      allow_nan=False).encode()).hexdigest()
                    receipt = db.execute("SELECT digest FROM receipts WHERE id=?", (request["requestId"],)).fetchone()
                    if receipt and receipt["digest"] != digest:
                        raise StoreError("conflict", "This request identity was already used for another countdown change.")
                if op == "countdown_log":
                    if not receipt:
                        db.execute("INSERT INTO receipts VALUES (?,?)", (request["requestId"], digest))
                    entry = self._log(db, state, args, journal)
                    sound = False
                    notify = False
                elif op != "countdown_status":
                    if receipt:
                        sound = False
                        notify = False
                    else:
                        expected = revision(args.get("expectedRevision"))
                        if expected != state["revision"]:
                            raise StoreError("conflict", "The countdown changed. Refresh its state before trying again.")
                        intent = self._intent(db, state["run_id"])
                        if op in ("countdown_start", "countdown_reset") and intent and not intent["result"]:
                            raise StoreError("conflict", "Retry the pending entry before dismissing or starting another countdown.")
                        if op == "countdown_start":
                            seconds = args.get("seconds")
                            if type(seconds) is not int or not 1 <= seconds <= MAX_SECONDS:
                                raise StoreError("validation", "Choose a duration from 00:00:01 to 99:59:59.")
                            if state["status"] not in ("idle", "finished"):
                                raise StoreError("conflict", "Cancel the existing countdown before starting another.")
                            if state["status"] == "finished" and state["activity_id"] and not intent:
                                raise StoreError("conflict", "Log or explicitly dismiss the finished countdown first.")
                            activity_id = text(args.get("activityId", ""), "activityId")
                            task_id = text(args.get("taskId", ""), "taskId")
                            if task_id and not activity_id:
                                raise StoreError("validation", "A task requires its activity.")
                            target = {"activityTitle": "", "taskTitle": ""}
                            if activity_id:
                                if journal is None:
                                    raise StoreError("storage", "The journal is unavailable; the target cannot be validated.")
                                target = journal.countdown_target(activity_id, task_id)
                            state.update(status="running", duration=seconds, remaining=seconds,
                                         deadline=now + seconds, boot=boot, observer=observer, recovery="",
                                         run_id=new_id(), activity_id=activity_id, task_id=task_id,
                                         activity_title=target["activityTitle"], task_title=target["taskTitle"])
                        elif op in ("countdown_pause", "countdown_resume"):
                            if "activityId" in args or "taskId" in args:
                                raise StoreError("conflict", "Cancel the countdown before changing its target.")
                            if op == "countdown_pause":
                                if state["status"] != "running":
                                    raise StoreError("conflict", "Only a running countdown can be paused.")
                                state.update(status="paused", deadline=0, recovery="")
                            else:
                                if state["status"] != "paused":
                                    raise StoreError("conflict", "Only a paused countdown can be resumed.")
                                state.update(status="running", deadline=now + state["remaining"],
                                             boot=boot, observer=observer, recovery="")
                        elif op == "countdown_reset":
                            state.update(status="idle", duration=0, remaining=0, deadline=0, recovery="",
                                         run_id="", activity_id="", task_id="", activity_title="", task_title="")
                        elif op == "countdown_mute":
                            state["muted"] = int(boolean(args.get("muted"), "muted"))
                            sound = False
                        state["revision"] += 1
                        db.execute("INSERT INTO receipts VALUES (?,?)", (request["requestId"], digest))
                if state["status"] != "finished":
                    sound = notify = False
                self._persist(db, state)
                intent = self._intent(db, state["run_id"])
                db.commit()
            except Exception:
                db.rollback()
                raise
        target_error = ""
        if state["activity_id"] and journal is not None:
            try:
                journal.countdown_target(state["activity_id"], state["task_id"])
            except StoreError as error:
                target_error = error.message
        result = {"status": state["status"], "revision": state["revision"],
                  "durationSeconds": state["duration"], "remainingSeconds": math.ceil(state["remaining"]),
                  "remainingExact": state["remaining"], "muted": bool(state["muted"]),
                  "recovery": state["recovery"], "sound": sound, "notify": notify, "runId": state["run_id"],
                  "activityId": state["activity_id"], "taskId": state["task_id"],
                  "activityTitle": state["activity_title"], "taskTitle": state["task_title"],
                  "targetError": target_error, "logPending": bool(intent and not intent["result"]),
                  "logSaved": bool(intent and intent["result"]),
                  "logPayload": self._payload(json.loads(intent["payload"])) if intent and not intent["result"] else None}
        if entry is not None:
            result["entry"] = entry
        return result
