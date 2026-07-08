#!/usr/bin/env python3
"""Garmin sync script — pulls recent activities and daily wellness data."""

import base64
import json
import os
import signal
import sys
import getpass
import shutil
import tempfile
from datetime import date, timedelta
from pathlib import Path

# Global timeout: kill the entire sync if it hangs for more than 10 minutes
def _timeout_handler(signum, frame):
    print("\n  TIMEOUT: sync.py exceeded 10 minutes, exiting", file=sys.stderr)
    sys.exit(1)

signal.signal(signal.SIGALRM, _timeout_handler)
signal.alarm(600)  # 10 minutes

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
    from garminconnect import Garmin

    token_b64 = os.environ.get("GARMIN_TOKEN_B64")
    if token_b64:
        # GitHub Actions path: load garth token directly, skip login()
        import garth as garth_module
        raw = base64.b64decode(token_b64)
        tmp = Path(tempfile.mkdtemp())
        try:
            # Format 1: JSON dict of files
            bundle = json.loads(raw.decode())
            for fname, data in bundle.items():
                (tmp / fname).write_text(json.dumps(data))
        except (UnicodeDecodeError, json.JSONDecodeError):
            # Format 2: tar.gz archive
            import tarfile, io
            with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as tar:
                tar.extractall(tmp)
        garth_client = garth_module.Client()
        garth_client.load(str(tmp))
        shutil.rmtree(tmp, ignore_errors=True)

        # Route OAuth exchange through Cloudflare Worker proxy to avoid Garmin 429
        # Patch at HTTPAdapter.send level so OAuth1 signs with the real Garmin URL,
        # then the URL is swapped to the proxy for transport only.
        proxy_url = os.environ.get("GARMIN_OAUTH_PROXY")
        if proxy_url:
            try:
                from requests.adapters import HTTPAdapter
                orig_url = "https://connectapi.garmin.com"
                proxy = proxy_url.rstrip("/")
                _orig_send = HTTPAdapter.send
                def _patched_send(self, request, **kwargs):
                    if "connectapi.garmin.com" in request.url:
                        request.url = request.url.replace(orig_url, proxy)
                    return _orig_send(self, request, **kwargs)
                HTTPAdapter.send = _patched_send
                print("  Using OAuth proxy for token refresh")
            except Exception as e:
                print(f"  Warning: proxy setup failed — {e}")

        client = Garmin("noop", "noop")
        client.garth = garth_client
        # Set request timeout so we never hang forever
        garth_client.sess.timeout = 30
        # Skip profile lookup — it triggers oauth refresh which Garmin blocks from cloud IPs
        client.display_name = "user"
        client.full_name = "user"
        client.unit_system = "metric"
        return client

    if TOKEN_DIR.exists():
        client = Garmin()
        try:
            client.login(tokenstore=str(TOKEN_DIR))
            client.garth.sess.timeout = 30
            client.get_user_summary(date.today().isoformat())
            # Re-save tokens after successful use (refreshes expiry)
            client.garth.dump(str(TOKEN_DIR))
            return client
        except Exception as e:
            print(f"  [auth] Token login failed: {e}", file=sys.stderr)
            # Try refreshing the OAuth2 token before giving up
            try:
                client.garth.refresh_oauth2()
                client.get_user_summary(date.today().isoformat())
                client.garth.dump(str(TOKEN_DIR))
                print("  [auth] Token refreshed successfully", file=sys.stderr)
                return client
            except Exception as e2:
                print(f"  [auth] Token refresh also failed: {e2}", file=sys.stderr)
                print("  [auth] Tokens expired — need manual re-login: cd ~/garmin-ai && python3 sync.py 1", file=sys.stderr)
                # Don't delete tokens on transient errors — only on auth failures
                err_str = str(e).lower() + str(e2).lower()
                if "401" in err_str or "unauthorized" in err_str or "forbidden" in err_str:
                    shutil.rmtree(TOKEN_DIR, ignore_errors=True)
                    print("  [auth] Tokens deleted (auth rejected)", file=sys.stderr)

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


def write_activity_note(act, details=None):
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

    # Extra details from get_activity_details
    if details:
        summary = details.get("summaryDTO", {})

        # Cadence
        cadence = summary.get("averageRunningCadenceInStepsPerMinute") or act.get("averageRunningCadenceInStepsPerMinute")
        if cadence:
            lines.append(f"**Avg Cadence:** {cadence:.0f} spm  ")

        # Running dynamics
        gct = summary.get("groundContactTime") or act.get("groundContactTime")
        vo_cm = summary.get("verticalOscillation") or act.get("verticalOscillation")
        stride = summary.get("strideLength") or act.get("strideLength")
        if gct:
            lines.append(f"**Ground Contact Time:** {gct:.0f} ms  ")
        if vo_cm:
            lines.append(f"**Vertical Oscillation:** {vo_cm:.1f} cm  ")
        if stride:
            lines.append(f"**Stride Length:** {stride:.2f} m  ")

        # Recovery time
        recovery_time = summary.get("recoveryTime")
        if recovery_time:
            lines.append(f"**Recovery Time Advised:** {recovery_time} hours  ")

        # Training load
        training_load = summary.get("trainingLoad") or act.get("activityTrainingLoad")
        if training_load:
            lines.append(f"**Training Load:** {training_load:.0f}  ")

        # HR zones
        hr_zones = details.get("heartRateDTOs") or []
        if hr_zones:
            lines.append("")
            lines.append("## HR Zones")
            zone_names = ["Zone 1 (Warm-up)", "Zone 2 (Easy)", "Zone 3 (Aerobic)", "Zone 4 (Threshold)", "Zone 5 (Max)"]
            total_secs = sum(z.get("secsInZone", 0) for z in hr_zones)
            for i, z in enumerate(hr_zones[:5]):
                secs = z.get("secsInZone", 0)
                pct = f"{secs/total_secs*100:.0f}%" if total_secs else "—"
                m, s = divmod(int(secs), 60)
                label = zone_names[i] if i < len(zone_names) else f"Zone {i+1}"
                lines.append(f"**{label}:** {m}m {s}s ({pct})  ")

        # Lap splits
        laps = details.get("splitSummaries") or []
        running_laps = [l for l in laps if l.get("splitType") == "INTERVAL_ACTIVE" or l.get("noOfSplits", 0) > 0]
        if not running_laps:
            running_laps = [l for l in laps if l.get("distance", 0) > 0]
        if running_laps:
            lines.append("")
            lines.append("## Lap Splits")
            for i, lap in enumerate(running_laps[:20], 1):
                lap_dist = lap.get("distance", 0)
                lap_spd = lap.get("averageSpeed", 0)
                lap_hr = lap.get("averageHR") or "—"
                lap_pace = format_pace(1 / lap_spd if lap_spd > 0 else None)
                lap_dist_str = f"{lap_dist/1000:.2f} km" if lap_dist else "—"
                lines.append(f"**Lap {i}:** {lap_dist_str} · {lap_pace} · {lap_hr} bpm  ")

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


def merge_data(existing, new_activities, new_wellness):
    """Merge new data into existing accumulated data.json."""
    act_ids = {a.get("activityId") for a in existing.get("activities", [])}
    for act in new_activities:
        if act.get("activityId") not in act_ids:
            existing.setdefault("activities", []).append(act)

    well_dates = {w.get("date") for w in existing.get("wellness", []) if w.get("date")}
    for w in new_wellness:
        wdate = w.get("date")
        if not wdate:
            continue
        if wdate in well_dates:
            existing["wellness"] = [w if e.get("date") == wdate else e for e in existing["wellness"]]
        else:
            existing.setdefault("wellness", []).append(w)

    return existing


def sync(days=3):
    client = load_client()

    new_activities = []
    new_wellness = []
    written = []

    today = date.today()
    dates = [(today - timedelta(days=i)).isoformat() for i in range(days - 1, -1, -1)]

    print(f"\nFetching data for: {dates[0]} → {dates[-1]}\n")

    # Activities
    try:
        activities = client.get_activities_by_date(dates[0], dates[-1])
        for act in activities:
            act_id = act.get("activityId")
            details = None
            try:
                details = client.get_activity_details(act_id)
                act["_details"] = details
            except Exception as e:
                print(f"  Warning: details for {act_id} — {e}")
            new_activities.append(act)
            fname = write_activity_note(act, details)
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
            # Fallback: build partial wellness from individual endpoints
            # Use client.garth (the authenticated garth instance), not the global garth.client
            try:
                _gc = client.garth
                _w = {}
                try:
                    _steps = _gc.connectapi(f"/usersummary-service/stats/steps/daily/{day}/{day}")
                    if _steps and len(_steps) > 0:
                        _w["totalSteps"] = _steps[0].get("totalSteps")
                        _w["totalDistanceMeters"] = _steps[0].get("totalDistance")
                except Exception:
                    pass
                try:
                    _stress = _gc.connectapi(f"/wellness-service/wellness/dailyStress/{day}")
                    if _stress:
                        _w["averageStressLevel"] = _stress.get("avgStressLevel")
                        _w["maxStressLevel"] = _stress.get("maxStressLevel")
                except Exception:
                    pass
                try:
                    _bb = _gc.connectapi("/wellness-service/wellness/bodyBattery/reports/daily", params={"startDate": day, "endDate": day})
                    if _bb and len(_bb) > 0:
                        bb_vals = [v[1] for v in _bb[0].get("bodyBatteryValuesArray", []) if isinstance(v, list) and len(v) > 1 and v[1] is not None]
                        if bb_vals:
                            _w["bodyBatteryHighestValue"] = max(bb_vals)
                            _w["bodyBatteryLowestValue"] = min(bb_vals)
                except Exception:
                    pass
                try:
                    _floors = _gc.connectapi(f"/wellness-service/wellness/floorsChartData/daily/{day}")
                    if _floors and "floorValuesArray" in _floors:
                        total_up = sum((f[2] if isinstance(f, list) and len(f) > 2 else 0) or 0 for f in _floors["floorValuesArray"])
                        _w["floorsAscended"] = total_up
                except Exception:
                    pass
                try:
                    _hr = _gc.connectapi(f"/usersummary-service/stats/heartRate/daily/{day}/{day}")
                    if _hr and len(_hr) > 0:
                        vals = _hr[0].get("values", {})
                        if vals.get("restingHR"):
                            _w["restingHeartRate"] = vals["restingHR"]
                        if vals.get("wellnessMaxAvgHR"):
                            _w["maxAvgHeartRate"] = vals["wellnessMaxAvgHR"]
                        if vals.get("wellnessMinAvgHR"):
                            _w["minAvgHeartRate"] = vals["wellnessMinAvgHR"]
                except Exception:
                    pass
                try:
                    _im = _gc.connectapi(f"/usersummary-service/stats/im/daily/{day}/{day}")
                    if _im and len(_im) > 0:
                        _w["moderateIntensityMinutes"] = _im[0].get("moderateValue", 0)
                        _w["vigorousIntensityMinutes"] = _im[0].get("vigorousValue", 0)
                except Exception:
                    pass
                try:
                    _cal = _gc.connectapi(f"/usersummary-service/stats/calories/daily/{day}/{day}")
                    if _cal and len(_cal) > 0:
                        vals = _cal[0].get("values", {})
                        if vals.get("activeCalories"):
                            _w["activeKilocalories"] = vals["activeCalories"]
                        if vals.get("totalCalories"):
                            _w["totalKilocalories"] = vals["totalCalories"]
                except Exception:
                    pass
                if _w:
                    wellness = _w
                    print(f"  Fallback wellness {day}: got {list(_w.keys())}")
            except Exception as e2:
                print(f"  Warning: fallback wellness {day} — {e2}")

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

        new_wellness.append({"date": day, "wellness": wellness, "sleep": sleep, "hrv": hrv, "training_readiness": tr})
        fname = write_wellness_note(day, wellness, sleep, hrv, tr)
        print(f"  Wellness: {fname}")
        written.append(fname)

    # Fetch daily performance metrics (once per sync, for today)
    performance = {}
    today_str = today.isoformat()

    try:
        ts = client.get_training_status(today_str) or {}
        # Extract key fields
        latest = {}
        ts_map = (ts.get("mostRecentTrainingStatus") or {}).get("latestTrainingStatusData") or {}
        if ts_map:
            latest = next(iter(ts_map.values()), {})
        acwr = (latest.get("acuteTrainingLoadDTO") or {})
        load_balance_map = (ts.get("mostRecentTrainingLoadBalance") or {}).get("metricsTrainingLoadBalanceDTOMap") or {}
        load_balance = next(iter(load_balance_map.values()), {}) if load_balance_map else {}
        vo2_data = (ts.get("mostRecentVO2Max") or {}).get("generic") or {}
        heat = (ts.get("mostRecentVO2Max") or {}).get("heatAltitudeAcclimation") or {}

        performance["training_status"] = latest.get("trainingStatusFeedbackPhrase")
        performance["fitness_trend"] = latest.get("fitnessTrend")
        performance["acwr"] = acwr.get("dailyAcuteChronicWorkloadRatio")
        performance["acwr_status"] = acwr.get("acwrStatus")
        performance["acute_load"] = acwr.get("dailyTrainingLoadAcute")
        performance["chronic_load"] = acwr.get("dailyTrainingLoadChronic")
        performance["aerobic_low_load"] = load_balance.get("monthlyLoadAerobicLow")
        performance["aerobic_high_load"] = load_balance.get("monthlyLoadAerobicHigh")
        performance["load_balance_feedback"] = load_balance.get("trainingBalanceFeedbackPhrase")
        performance["vo2max_precise"] = vo2_data.get("vo2MaxPreciseValue")
        performance["heat_acclimation_pct"] = heat.get("heatAcclimationPercentage")
        performance["heat_trend"] = heat.get("heatTrend")
        print(f"  Training status: {performance['training_status']}, ACWR: {performance['acwr']}")
    except Exception as e:
        print(f"  Warning: training status — {e}")

    try:
        rp = client.get_race_predictions() or {}
        def secs_to_time(s):
            if not s: return None
            h, m = divmod(int(s) // 60, 60)
            return f"{h}:{m:02d}:{int(s)%60:02d}" if h else f"{m}:{int(s)%60:02d}"
        performance["race_pred_5k"] = secs_to_time(rp.get("time5K"))
        performance["race_pred_10k"] = secs_to_time(rp.get("time10K"))
        performance["race_pred_hm"] = secs_to_time(rp.get("timeHalfMarathon"))
        performance["race_pred_marathon"] = secs_to_time(rp.get("timeMarathon"))
        print(f"  Race predictions — HM: {performance['race_pred_hm']}")
    except Exception as e:
        print(f"  Warning: race predictions — {e}")

    try:
        resp = client.get_respiration_data(today_str) or {}
        performance["avg_respiration"] = resp.get("avgWakingRespirationValue")
        performance["sleep_respiration"] = resp.get("avgSleepRespirationValue")
    except Exception as e:
        print(f"  Warning: respiration — {e}")

    try:
        spo2 = client.get_spo2_data(today_str) or {}
        performance["avg_spo2"] = (spo2.get("averages") or {}).get("average")
    except Exception as e:
        print(f"  Warning: SpO2 — {e}")

    # Check if we actually got any real data (not all 429'd)
    has_real_wellness = any(w.get("wellness") for w in new_wellness)
    has_real_data = bool(new_activities) or has_real_wellness or bool(performance.get("acwr"))

    if not has_real_data:
        print("\nNo real data fetched (all API calls failed). Keeping existing data.json unchanged.")
        return written

    # Merge into accumulated data.json
    existing = {}
    if DATA_FILE.exists():
        try:
            existing = json.loads(DATA_FILE.read_text())
        except Exception:
            existing = {}

    # Only merge wellness entries that actually have data
    real_wellness = [w for w in new_wellness if w.get("wellness")]
    merged = merge_data(existing, new_activities, real_wellness)

    # Store performance metrics by date (only if we got real data)
    perf_by_date = existing.get("performance", {})
    if any(v is not None for v in performance.values()):
        perf_by_date[today_str] = performance
    merged["performance"] = perf_by_date

    # Store latest activity route (compact lat/lon pairs for map)
    all_acts = sorted(merged.get("activities", []), key=lambda x: x.get("startTimeLocal", ""), reverse=True)
    latest_with_poly = next((a for a in all_acts if a.get("hasPolyline")), None)
    if latest_with_poly:
        details = latest_with_poly.get("_details")
        if details:
            geo = details.get("geoPolylineDTO", {})
            polyline = geo.get("polyline", [])
            if polyline:
                # Store compact: [[lat,lon], ...] — skip every other point to save space
                route = [[round(p["lat"], 6), round(p["lon"], 6)] for p in polyline[::2] if p.get("lat") and p.get("lon")]
                merged["latest_route"] = {
                    "name": latest_with_poly.get("activityName", "Activity"),
                    "date": (latest_with_poly.get("startTimeLocal") or "")[:10],
                    "points": route,
                }

    # Strip _details before saving (too large)
    for a in merged.get("activities", []):
        a.pop("_details", None)

    # Atomic write: write to temp file first, then rename (prevents corruption on crash)
    tmp_file = DATA_FILE.with_suffix(".json.tmp")
    tmp_file.write_text(json.dumps(merged, indent=2, default=str))
    tmp_file.replace(DATA_FILE)
    print(f"\nAll data saved to garmin/data.json")
    print(f"Markdown notes written: {len(written)} files")
    return written


if __name__ == "__main__":
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    sync(days)
