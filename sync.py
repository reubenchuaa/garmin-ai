#!/usr/bin/env python3
"""Garmin sync script — pulls recent activities and daily wellness data."""

import json
import os
import sys
import getpass
from datetime import date, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
GARMIN_DIR = SCRIPT_DIR / "garmin"
TOKEN_DIR = SCRIPT_DIR / ".garmin_tokens"
DATA_FILE = GARMIN_DIR / "data.json"

GARMIN_DIR.mkdir(exist_ok=True)


def load_client():
    """Return an authenticated Garmin client.

    In GitHub Actions, reads token from GARMIN_TOKEN_B64 env var.
    Locally, reads from the .garmin_tokens folder.
    """
    import base64, tempfile, shutil
    from garminconnect import Garmin

    token_b64 = os.environ.get("GARMIN_TOKEN_B64")
    if token_b64:
        # GitHub Actions path: decode token bundle to a temp directory
        bundle = json.loads(base64.b64decode(token_b64).decode())
        tmp = Path(tempfile.mkdtemp())
        for fname, data in bundle.items():
            (tmp / fname).write_text(json.dumps(data))
        client = Garmin("noop", "noop")
        client.login(tokenstore=str(tmp))
        shutil.rmtree(tmp, ignore_errors=True)
        return client

    if TOKEN_DIR.exists():
        client = Garmin()
        try:
            client.login(tokenstore=str(TOKEN_DIR))
            client.get_user_summary(date.today().isoformat())
            return client
        except Exception:
            shutil.rmtree(TOKEN_DIR, ignore_errors=True)

    # Fresh interactive login (local only)
    email = os.environ.get("GARMIN_EMAIL") or input("Garmin email: ")
    password = os.environ.get("GARMIN_PASSWORD") or getpass.getpass("Garmin password: ")

    client = Garmin(email, password)
    try:
        client.login()
    except Exception as e:
        err = str(e)
        if "MFA" in err or "2FA" in err or "needs_mfa" in err or "code" in err.lower() or "NeedsMFAException" in type(e).__name__:
            mfa = input("Garmin sent a verification code to your email/phone. Enter it here: ")
            client.garth.login(email, password, prompt=lambda _: mfa)
        else:
            raise

    TOKEN_DIR.mkdir(exist_ok=True)
    client.garth.dump(str(TOKEN_DIR))
    TOKEN_DIR.chmod(0o700)
    print("Login successful — token saved for future runs.")
    return client


def activity_type_label(act):
    t = act.get("activityType", {}).get("typeKey", "workout")
    return t.replace("_", " ").title()


def format_duration(seconds):
    if not seconds:
        return "—"
    h, m = divmod(int(seconds) // 60, 60)
    return f"{h}h {m}m" if h else f"{m}m"


def format_pace(seconds_per_meter):
    if not seconds_per_meter or seconds_per_meter <= 0:
        return "—"
    spm = seconds_per_meter * 1000  # per km
    m, s = divmod(int(spm), 60)
    return f"{m}:{s:02d} /km"


def write_activity_note(act):
    name = act.get("activityName", "Workout")
    start = (act.get("startTimeLocal") or "")[:10]
    act_id = act.get("activityId", "unknown")
    filename = GARMIN_DIR / f"activity_{start}_{act_id}.md"

    duration = format_duration(act.get("duration"))
    distance_m = act.get("distance") or 0
    distance_km = f"{distance_m / 1000:.2f} km" if distance_m else "—"
    hr_avg = act.get("averageHR") or "—"
    hr_max = act.get("maxHR") or "—"
    calories = act.get("calories") or "—"
    avg_speed = act.get("averageSpeed") or 0
    pace = format_pace(1 / avg_speed if avg_speed > 0 else None)
    sport = activity_type_label(act)
    elevation = act.get("elevationGain")
    elevation_str = f"{elevation:.0f} m" if elevation else "—"
    te_raw = act.get("aerobicTrainingEffect")
    training_effect = f"{te_raw:.1f}" if te_raw else "—"
    vo2 = act.get("vO2MaxValue") or "—"

    lines = [
        f"# {name}",
        f"**Date:** {start}  ",
        f"**Sport:** {sport}  ",
        f"**Duration:** {duration}  ",
        f"**Distance:** {distance_km}  ",
        f"**Pace:** {pace}  ",
        f"**Avg HR:** {hr_avg} bpm  ",
        f"**Max HR:** {hr_max} bpm  ",
        f"**Calories:** {calories}  ",
        f"**Elevation Gain:** {elevation_str}  ",
        f"**Aerobic Training Effect:** {training_effect}  ",
        f"**VO2 Max:** {vo2}  ",
    ]

    filename.write_text("\n".join(lines) + "\n")
    return str(filename.name)


def write_wellness_note(day_str, wellness, sleep_data, hrv_data, training_readiness):
    filename = GARMIN_DIR / f"wellness_{day_str}.md"

    def g(d, *keys):
        for k in keys:
            if isinstance(d, dict):
                d = d.get(k)
            else:
                return "—"
        return d if d is not None else "—"

    rhr = g(wellness, "restingHeartRate")
    bb_high = g(wellness, "bodyBatteryHighestValue")
    bb_low = g(wellness, "bodyBatteryLowestValue")
    stress = g(wellness, "averageStressLevel")
    steps = g(wellness, "totalSteps")

    sleep_score = g(sleep_data, "dailySleepDTO", "sleepScores", "overall", "value")
    sleep_total = g(sleep_data, "dailySleepDTO", "sleepTimeSeconds")
    if isinstance(sleep_total, (int, float)):
        h, m = divmod(int(sleep_total) // 60, 60)
        sleep_total = f"{h}h {m}m"

    deep = g(sleep_data, "dailySleepDTO", "deepSleepSeconds")
    rem = g(sleep_data, "dailySleepDTO", "remSleepSeconds")
    if isinstance(deep, (int, float)):
        deep = f"{deep // 3600:.1f}h"
    if isinstance(rem, (int, float)):
        rem = f"{rem // 3600:.1f}h"

    hrv_weekly = g(hrv_data, "hrvSummary", "weeklyAvg")
    hrv_last = g(hrv_data, "hrvSummary", "lastNight")
    hrv_status = g(hrv_data, "hrvSummary", "status")

    tr_score = "—"
    tr_level = "—"
    if isinstance(training_readiness, list) and training_readiness:
        tr = training_readiness[0]
        tr_score = g(tr, "score")
        tr_level = g(tr, "level")

    lines = [
        f"# Daily Wellness — {day_str}",
        "",
        "## Recovery",
        f"**Resting Heart Rate:** {rhr} bpm  ",
        f"**HRV (last night):** {hrv_last} ms  ",
        f"**HRV (weekly avg):** {hrv_weekly} ms  ",
        f"**HRV Status:** {hrv_status}  ",
        f"**Body Battery high/low:** {bb_high} / {bb_low}  ",
        f"**Average Stress:** {stress}  ",
        "",
        "## Sleep",
        f"**Total Sleep:** {sleep_total}  ",
        f"**Sleep Score:** {sleep_score}  ",
        f"**Deep Sleep:** {deep}  ",
        f"**REM Sleep:** {rem}  ",
        "",
        "## Activity",
        f"**Steps:** {steps}  ",
        "",
        "## Training Readiness",
        f"**Score:** {tr_score}  ",
        f"**Level:** {tr_level}  ",
    ]

    filename.write_text("\n".join(lines) + "\n")
    return str(filename.name)


def sync(days=3):
    client = load_client()

    all_data = {"activities": [], "wellness": []}
    written = []

    today = date.today()
    dates = [(today - timedelta(days=i)).isoformat() for i in range(days - 1, -1, -1)]

    print(f"\nFetching data for: {dates[0]} → {dates[-1]}\n")

    # Activities
    try:
        activities = client.get_activities_by_date(dates[0], dates[-1])
        for act in activities:
            all_data["activities"].append(act)
            fname = write_activity_note(act)
            print(f"  Activity: {fname}")
            written.append(fname)
    except Exception as e:
        print(f"  Warning: could not fetch activities — {e}")

    # Daily wellness
    for day in dates:
        wellness, sleep, hrv, tr = {}, {}, {}, []

        try:
            wellness = client.get_user_summary(day) or {}
        except Exception as e:
            print(f"  Warning: wellness {day} — {e}")

        try:
            sleep = client.get_sleep_data(day) or {}
        except Exception as e:
            print(f"  Warning: sleep {day} — {e}")

        try:
            hrv = client.get_hrv_data(day) or {}
        except Exception as e:
            print(f"  Warning: HRV {day} — {e}")

        try:
            tr = client.get_training_readiness(day) or []
        except Exception as e:
            print(f"  Warning: training readiness {day} — {e}")

        all_data["wellness"].append({"date": day, "wellness": wellness, "sleep": sleep, "hrv": hrv, "training_readiness": tr})
        fname = write_wellness_note(day, wellness, sleep, hrv, tr)
        print(f"  Wellness: {fname}")
        written.append(fname)

    # Write combined JSON
    DATA_FILE.write_text(json.dumps(all_data, indent=2, default=str))
    print(f"\nAll data saved to garmin/data.json")
    print(f"Markdown notes written: {len(written)} files")
    return written


if __name__ == "__main__":
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    sync(days)
