"""Synthetic M2 examples, invoked only for a newly created --demo profile."""
from datetime import date, timedelta
import json
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def seed(profile):
    profile = Path(profile).resolve()
    if profile.is_relative_to(ROOT) or (profile.exists() and any(profile.iterdir())):
        raise ValueError("Demo seeding requires a new empty profile outside the source tree.")

    def request(op, **args):
        envelope = {"protocol": 1, "requestId": "demo-" + uuid.uuid4().hex, "op": op, "args": args}
        process = subprocess.run(
            [sys.executable, str(ROOT / "backend/helper.py"), "--profile", str(profile)],
            input=json.dumps(envelope, ensure_ascii=False) + "\n", text=True,
            capture_output=True, check=True, timeout=15)
        response = json.loads(process.stdout)
        if not response.get("ok"):
            raise ValueError("Could not create isolated synthetic examples.")
        return response["result"]

    today = date.today()
    previous = (today - timedelta(days=1)).isoformat()
    current = today.isoformat()
    coding = request("create_activity", mode="plan", title="Fix login flow", category="Coding",
                     project="Portfolio Website", plannedFor=current,
                     note="Synthetic example: keep validation changes small. Token refresh still needs review.")["activityId"]
    request("add_session", activityId=coding, date=previous, minutes=45,
            note="Synthetic session: traced validation and wrote down the failure cases.")
    request("add_session", activityId=coding, date=current, minutes=35,
            note="Synthetic session: fixed validation; token refresh remains.")
    request("create_activity", mode="log", title="Read chapter three", category="Reading",
            date=previous, minutes=30,
            sessionNote="Synthetic retrospective note: pages 41–58. Constraints can clarify a design; no clock times recorded.")
    request("create_activity", mode="log", title="Called the repair service", category="Personal",
            date=current, minutes=None, done=True, sessionNote="Synthetic untimed accomplishment. Appointment arranged.")
    request("create_activity", mode="plan", title="Organize receipts", category="Chores",
            plannedFor=(today - timedelta(days=3)).isoformat(), note="Synthetic overdue plan; its date has not moved.")
    request("create_activity", mode="log", title="A short walk outside", category="Health",
            date=current, minutes=None, sessionNote="Synthetic example: noticed the changing leaves. No duration recorded.")
    request("create_activity", mode="plan", category="Learning",
            title="Understand how local-first tools preserve intentions, actual sessions, and long reflections without turning every activity into a checklist",
            note="Synthetic long note for native layout review.\n\n" +
                 "A plan records intention. A session records experience. Completion is an explicit choice. " * 8)
    request("save_note", date=current, body="Synthetic reflection: a quiet morning of coding and a walk.\nThe plan and the work did not line up perfectly, and that is useful to see.", expectedRevision=0)
