#!/usr/bin/env python3
"""
Parse today's coach note and push the next scheduled workout to Garmin Connect.
The workout appears in the Garmin Connect workout library and syncs to the watch
automatically on next Bluetooth/Wi-Fi sync.

Usage: python3 push_workout.py
"""

import json
import re
import sys
import os
from datetime import date, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TOKEN_DIR = SCRIPT_DIR / ".garmin_tokens"
COACH_NOTE = SCRIPT_DIR / "garmin" / "coach_note.md"
CONTEXT_FILE = SCRIPT_DIR / "context.json"
LAST_PUSH_FILE = SCRIPT_DIR / "garmin" / ".last_workout_push"


def load_client():
    """Load authenticated Garmin client (reuses sync.py token logic)."""
    from garminconnect import Garmin
    import garth
    import shutil

    # GitHub Actions: load from env
    token_b64 = os.environ.get("GARMIN_TOKEN_B64")
    if token_b64:
        import base64, tempfile
        tmp = Path(tempfile.mkdtemp())
        for name, data in json.loads(base64.b64decode(token_b64)).items():
            (tmp / name).write_text(data)
        client = Garmin()
        garth_client = garth.Client()
        garth_client.load(str(tmp))
        client.garth = garth_client
        client.display_name = client.get_full_name()["displayName"]
        client.unit_system = "metric"
        shutil.rmtree(tmp, ignore_errors=True)
        return client

    if TOKEN_DIR.exists():
        client = Garmin()
        try:
            client.login(tokenstore=str(TOKEN_DIR))
            client.garth.sess.timeout = 30
            client.get_user_summary(date.today().isoformat())
            return client
        except Exception:
            shutil.rmtree(TOKEN_DIR, ignore_errors=True)

    # Fresh interactive login
    email = os.environ.get("GARMIN_EMAIL") or input("Garmin email: ")
    import getpass
    password = os.environ.get("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")
    client = Garmin(email, password)
    client.login()
    TOKEN_DIR.mkdir(exist_ok=True)
    client.garth.dump(str(TOKEN_DIR))
    return client


def parse_coach_note():
    """Parse coach note to extract the next run session with structured details."""
    if not COACH_NOTE.exists():
        print("No coach note found")
        return None

    text = COACH_NOTE.read_text()

    # Find the 3-Day Plan section
    plan_match = re.search(r"\*\*3-Day Plan\*\*(.*?)(?:\n\*\*[^*]|\Z)", text, re.DOTALL)
    if not plan_match:
        print("No 3-Day Plan section found")
        return None

    plan_text = plan_match.group(1)
    today = date.today()

    # Parse each day in the plan
    sessions = []
    for line in plan_text.strip().split("\n"):
        # Strip markdown list markers and bold
        line = re.sub(r"^\s*-\s*", "", line)
        line = re.sub(r"\*\*", "", line)
        line = line.strip()
        if not line:
            continue

        # Skip rest/blackout/cannot-run days
        lower = line.lower()
        if any(x in lower for x in ["cannot run", "rest", "blackout", "done", "no run"]):
            continue

        # Extract workout details
        session = parse_session(line)
        if session:
            # Figure out the date from various formats:
            # "Today (Mon, Jul 6):", "Tomorrow (Tue, Jul 7):", "Wednesday (Jul 8):",
            # "Mon, Jul 6:", "Tue 7 Jul:", "Jul 8:", etc.
            session_date = None

            if re.search(r"\btoday\b", lower):
                session_date = today
            elif re.search(r"\btomorrow\b", lower):
                session_date = today + timedelta(days=1)
            elif re.search(r"\bday after\b", lower):
                session_date = today + timedelta(days=2)
            else:
                # Try to extract month + day: "Jul 8", "8 Jul", "Aug 12", etc.
                months = {"jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                          "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12}
                mon_str = None
                day_str = None
                m1 = re.search(
                    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d+)",
                    line, re.IGNORECASE
                )
                if m1:
                    mon_str, day_str = m1.group(1), m1.group(2)
                else:
                    m2 = re.search(
                        r"(\d+)\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*",
                        line, re.IGNORECASE
                    )
                    if m2:
                        mon_str, day_str = m2.group(2), m2.group(1)
                if mon_str and day_str:
                    try:
                        m = months[mon_str[:3].lower()]
                        d = int(day_str)
                        session_date = date(today.year, m, d)
                    except (ValueError, KeyError):
                        pass

            if session_date:
                session["date"] = session_date.isoformat()
            sessions.append(session)

    if not sessions:
        print("No runnable sessions found in plan")
        return None

    # Return all upcoming sessions (today and future)
    upcoming = [s for s in sessions if s.get("date", "") >= today.isoformat()]
    return upcoming if upcoming else sessions


def parse_session(line):
    """Parse a session line into structured workout steps."""
    lower = line.lower()

    # Detect tempo/interval sessions
    is_tempo = any(x in lower for x in ["tempo", "interval", "threshold"])

    # Extract total distance
    total_match = re.search(r"(\d+)\s*km\s*(?:total)?", lower)
    total_km = int(total_match.group(1)) if total_match else None

    # Extract warmup distance: "2km easy warm-up", "2km warm-up", "2km easy +"
    warmup_match = re.search(r"(\d+(?:\.\d+)?)\s*km\s*(?:easy\s+)?(?:warm|wu)", lower)
    if not warmup_match and is_tempo:
        # In a tempo workout, "Xkm easy" before the tempo portion = warmup
        warmup_match = re.search(r"(\d+(?:\.\d+)?)\s*km\s*easy(?:\s*[+→])", lower)
    warmup_km = float(warmup_match.group(1)) if warmup_match else None

    # Extract cooldown distance
    cooldown_match = re.search(r"(\d+(?:\.\d+)?)\s*km\s*(?:cool|cd)", lower)
    cooldown_km = float(cooldown_match.group(1)) if cooldown_match else None

    # Extract tempo/interval distance
    tempo_match = re.search(r"(\d+(?:\.\d+)?)\s*km\s*(?:at\s+|tempo|@)", lower)
    tempo_km = float(tempo_match.group(1)) if tempo_match else None

    # Extract pace range (e.g., 6:00-6:15/km or 7:00–7:15/km)
    pace_match = re.search(r"(\d+:\d+)\s*[–-]\s*(\d+:\d+)\s*/?\s*km", line)
    pace_min = pace_max = None
    if pace_match:
        def pace_to_ms(p):
            parts = p.split(":")
            secs = int(parts[0]) * 60 + int(parts[1])
            return round(1000 / secs, 3)  # m/s
        pace_min = pace_to_ms(pace_match.group(2))  # slower pace = lower m/s
        pace_max = pace_to_ms(pace_match.group(1))  # faster pace = higher m/s

    # Extract HR range (e.g., HR 155-165 or HR ≤135)
    hr_match = re.search(r"HR\s*[≤<]?\s*(\d+)\s*[–-]\s*(\d+)", line)
    hr_cap_match = re.search(r"HR\s*[≤<]\s*(\d+)", line)
    hr_low = hr_high = None
    if hr_match:
        hr_low = int(hr_match.group(1))
        hr_high = int(hr_match.group(2))
    elif hr_cap_match:
        hr_high = int(hr_cap_match.group(1))
        hr_low = hr_high - 20  # reasonable range

    # For tempo sessions where the plan line omits explicit warm-up/cool-down
    # (common in the condensed 3-Day Plan), synthesize a sensible structure.
    # The stated distance IS the tempo block; add a 2km warm-up + 2km cool-down
    # AROUND it (not carved out of it).
    if is_tempo and not warmup_km and total_km:
        warmup_km = 2.0
        cooldown_km = 2.0
        tempo_km = total_km

    # Build workout structure
    if is_tempo and warmup_km and tempo_km:
        # Structured tempo workout
        if not cooldown_km and total_km:
            cooldown_km = total_km - warmup_km - tempo_km
        elif not cooldown_km:
            cooldown_km = warmup_km  # mirror warmup

        name = f"Tempo {int(tempo_km)}km"
        if pace_match:
            name += f" @ {pace_match.group(1)}-{pace_match.group(2)}/km"

        return {
            "name": name,
            "type": "tempo",
            "steps": [
                {"type": "warmup", "distance_m": int(warmup_km * 1000)},
                {"type": "interval", "distance_m": int(tempo_km * 1000),
                 "pace_min_ms": pace_min, "pace_max_ms": pace_max,
                 "hr_low": hr_low, "hr_high": hr_high},
                {"type": "cooldown", "distance_m": int(cooldown_km * 1000)},
            ]
        }
    elif total_km or total_match:
        # Simple easy run
        dist = total_km or 5
        name = f"Easy {dist}km"
        if pace_match:
            name += f" @ {pace_match.group(1)}-{pace_match.group(2)}/km"

        target = {}
        if hr_high:
            target = {"hr_low": hr_low, "hr_high": hr_high}
        elif pace_min:
            target = {"pace_min_ms": pace_min, "pace_max_ms": pace_max}

        return {
            "name": name,
            "type": "easy",
            "steps": [
                {"type": "warmup", "distance_m": int(dist * 1000), **target},
            ]
        }

    return None


def build_garmin_workout(session):
    """Convert parsed session into Garmin Connect workout JSON."""
    steps = []
    for i, step in enumerate(session["steps"], 1):
        step_type_map = {
            "warmup": (1, "warmup"),
            "interval": (3, "interval"),
            "cooldown": (2, "cooldown"),
        }
        type_id, type_key = step_type_map.get(step["type"], (3, "interval"))

        garmin_step = {
            "type": "ExecutableStepDTO",
            "stepOrder": i,
            "stepType": {"stepTypeId": type_id, "stepTypeKey": type_key},
            "endCondition": {"conditionTypeId": 3, "conditionTypeKey": "distance"},
            "endConditionValue": step["distance_m"],
        }

        # Prefer HR target for tempo steps, pace for easy
        if step.get("hr_low") and step.get("hr_high") and step["type"] == "interval":
            garmin_step["targetType"] = {
                "workoutTargetTypeId": 4,
                "workoutTargetTypeKey": "heart.rate.zone"
            }
            garmin_step["targetValueOne"] = step["hr_low"]
            garmin_step["targetValueTwo"] = step["hr_high"]
        elif step.get("pace_min_ms") and step.get("pace_max_ms"):
            garmin_step["targetType"] = {
                "workoutTargetTypeId": 6,
                "workoutTargetTypeKey": "pace.zone"
            }
            garmin_step["targetValueOne"] = step["pace_min_ms"]
            garmin_step["targetValueTwo"] = step["pace_max_ms"]
        else:
            garmin_step["targetType"] = {
                "workoutTargetTypeId": 1,
                "workoutTargetTypeKey": "no.target"
            }

        steps.append(garmin_step)

    workout = {
        "workoutName": session["name"],
        "sportType": {"sportTypeId": 1, "sportTypeKey": "running"},
        "workoutSegments": [{
            "segmentOrder": 1,
            "sportType": {"sportTypeId": 1, "sportTypeKey": "running"},
            "workoutSteps": steps,
        }]
    }

    return workout


def push_to_garmin(client, workout, schedule_date=None):
    """Push workout to Garmin Connect and optionally schedule it."""
    url = "/workout-service/workout"
    headers = {
        "Referer": "https://connect.garmin.com/modern/workouts",
        "nk": "NT",
    }

    resp = client.garth.connectapi(
        url, method="POST", json=workout, headers=headers, referrer=True
    )

    if not resp or not isinstance(resp, dict):
        print(f"  [workout] Failed to create workout: {resp}")
        return None

    workout_id = resp.get("workoutId")
    if not workout_id:
        print(f"  [workout] No workoutId in response: {resp}")
        return None

    print(f"  [workout] Created: {workout['workoutName']} (ID: {workout_id})")

    # Schedule it to a specific date so it shows on the calendar/watch
    schedule_id = None
    if schedule_date:
        sched_url = f"/workout-service/schedule/{workout_id}"
        try:
            sched_resp = client.garth.connectapi(
                sched_url, method="POST", json={"date": schedule_date}, headers=headers
            )
            schedule_id = sched_resp.get("workoutScheduleId") if isinstance(sched_resp, dict) else None
            print(f"  [workout] Scheduled for {schedule_date}")
        except Exception as e:
            print(f"  [workout] Schedule failed (workout still created): {e}")

    return workout_id, schedule_id


def load_push_state():
    """Load push state: list of pushed workouts [{date, name, workoutId, scheduleId}]."""
    if LAST_PUSH_FILE.exists():
        try:
            data = json.loads(LAST_PUSH_FILE.read_text())
            # Migrate old single-workout format to list
            if isinstance(data, dict):
                return [data]
            return data
        except (json.JSONDecodeError, ValueError):
            pass
    return []


def already_pushed(session):
    """Check if this exact workout was already pushed."""
    state = load_push_state()
    return any(
        s.get("date") == session.get("date") and s.get("name") == session["name"]
        for s in state
    )


def save_push_state(sessions_pushed):
    """Record all pushed workouts for dedup and cleanup."""
    LAST_PUSH_FILE.write_text(json.dumps(sessions_pushed) + "\n")


def cleanup_old_workouts(client, new_sessions):
    """Delete previously pushed workouts that are no longer in the plan.
    Keeps the Garmin workout library and calendar clean."""
    old_state = load_push_state()
    new_keys = {(s.get("date"), s["name"]) for s in new_sessions}

    for old in old_state:
        old_key = (old.get("date"), old.get("name"))
        if old_key in new_keys:
            continue  # Still in the plan, keep it
        # Delete schedule entry first
        if old.get("scheduleId"):
            try:
                client.garth.connectapi(
                    f"/workout-service/schedule/{old['scheduleId']}",
                    method="DELETE",
                )
            except Exception:
                pass
        # Delete the workout
        if old.get("workoutId"):
            try:
                client.garth.connectapi(
                    f"/workout-service/workout/{old['workoutId']}",
                    method="DELETE",
                )
                print(f"  [workout] Deleted old: {old.get('name')} (ID: {old['workoutId']})")
            except Exception as e:
                print(f"  [workout] Could not delete {old.get('workoutId')}: {e}")


def cleanup_calendar(client, sessions):
    """Remove any AI-coach workouts from the calendar that aren't in the current plan.
    Prevents stale/orphaned workouts from cluttering the watch."""
    try:
        today = date.today()
        # Get current month's calendar (Garmin uses 0-indexed months)
        resp = client.garth.connectapi(f"/calendar-service/year/{today.year}/month/{today.month - 1}")
        cal_workouts = [i for i in resp.get("calendarItems", []) if i.get("itemType") == "workout"]

        # Known session keys from current plan
        plan_names = {s["name"] for s in sessions}
        plan_dates = {s.get("date") for s in sessions}
        # Known IDs we pushed
        pushed_ids = {s.get("scheduleId") for s in load_push_state()}

        for item in cal_workouts:
            title = item.get("title", "")
            sched_id = item.get("id")
            item_date = item.get("date", "")

            # Only touch workouts that look like ours (contain @ or pace patterns)
            if "@" not in title and "km" not in title.lower():
                continue
            # Skip if it's in the current plan
            if title in plan_names and item_date in plan_dates:
                continue
            # Skip if it's in our push state (we'll handle via cleanup_old_workouts)
            if sched_id in pushed_ids:
                continue
            # It's an orphan — delete it
            if item_date >= today.isoformat():
                try:
                    client.garth.connectapi(f"/workout-service/schedule/{sched_id}", method="DELETE")
                    print(f"  [workout] Cleaned orphan from calendar: {title} ({item_date})")
                except Exception:
                    pass
    except Exception as e:
        print(f"  [workout] Calendar cleanup skipped: {e}")


def main():
    sessions = parse_coach_note()
    if not sessions:
        print("No workout to push")
        return

    # Filter out already-pushed sessions
    to_push = [s for s in sessions if not already_pushed(s)]
    if not to_push:
        names = ", ".join(f"{s['name']} ({s.get('date','?')})" for s in sessions)
        print(f"  [workout] Already pushed: {names} — skipping")
        return

    try:
        client = load_client()
        cleanup_calendar(client, sessions)
        cleanup_old_workouts(client, sessions)

        pushed = []
        # Keep any already-pushed sessions in state
        old_state = load_push_state()
        for old in old_state:
            if any(s.get("date") == old.get("date") and s["name"] == old.get("name") for s in sessions):
                pushed.append(old)

        for session in to_push:
            print(f"  [workout] Pushing: {session['name']} ({session['type']}) for {session.get('date', '?')}")
            for s in session["steps"]:
                print(f"    - {s['type']}: {s['distance_m']}m", end="")
                if s.get("hr_low"):
                    print(f", HR {s['hr_low']}-{s['hr_high']}", end="")
                if s.get("pace_min_ms"):
                    print(f", pace {s['pace_min_ms']:.3f}-{s['pace_max_ms']:.3f} m/s", end="")
                print()

            workout = build_garmin_workout(session)
            workout_id, schedule_id = push_to_garmin(client, workout, schedule_date=session.get("date"))
            if workout_id:
                pushed.append({
                    "date": session.get("date"),
                    "name": session["name"],
                    "workoutId": workout_id,
                    "scheduleId": schedule_id,
                })
                print(f"  ✅ Pushed: {session['name']} → {session.get('date', '?')}")

        save_push_state(pushed)
    except Exception as e:
        print(f"\n  [workout] Push failed: {e}")


if __name__ == "__main__":
    main()
