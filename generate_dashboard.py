#!/usr/bin/env python3
"""Generate dashboard.html from garmin/data.json and context.json."""

import json
import os
from datetime import date, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
DATA_FILE = SCRIPT_DIR / "garmin" / "data.json"
CONTEXT_FILE = SCRIPT_DIR / "context.json"
DOCS_DIR = SCRIPT_DIR / "docs"
OUTPUT_FILE = DOCS_DIR / "index.html"


def load_data():
    if not DATA_FILE.exists():
        return {"activities": [], "wellness": []}
    return json.loads(DATA_FILE.read_text())


def load_context():
    if not CONTEXT_FILE.exists():
        return {}
    return json.loads(CONTEXT_FILE.read_text())


def g(d, *keys):
    for k in keys:
        if isinstance(d, dict):
            d = d.get(k)
        else:
            return None
    return d if d is not None else None


def get_wellness_range(data, days=14):
    today = date.today()
    dates = {(today - timedelta(days=i)).isoformat() for i in range(days)}
    items = [w for w in data.get("wellness", []) if w["date"] in dates]
    return sorted(items, key=lambda x: x["date"])


def get_recent_activities(data, n=8):
    acts = sorted(data.get("activities", []), key=lambda x: x.get("startTimeLocal", ""), reverse=True)
    return acts[:n]


def get_coaching(data, context):
    """Rule-based daily coaching — no API needed."""
    today = date.today()
    race_date = date.fromisoformat(context.get("race_date", "2026-09-27"))
    days_to_race = (race_date - today).days
    easy_hr_cap = context.get("hr_zones", {}).get("easy_max", 135)

    # Current training phase
    current_phase = None
    for phase in context.get("training_phases", []):
        if phase["start"] <= today.isoformat() <= phase["end"]:
            current_phase = phase
            break

    # Today's wellness
    today_w = next((w for w in data.get("wellness", []) if w["date"] == today.isoformat()), None)
    tr_score = None
    bb_peak = None
    rhr = None
    hrv = None
    hrv_status = None
    stress = None
    if today_w:
        tr_list = today_w.get("training_readiness", [])
        tr_score = tr_list[0].get("score") if tr_list else None
        bb_peak = g(today_w, "wellness", "bodyBatteryHighestValue")
        rhr = g(today_w, "wellness", "restingHeartRate")
        hrv = g(today_w, "hrv", "hrvSummary", "lastNight")
        hrv_status = (g(today_w, "hrv", "hrvSummary", "status") or "").upper()
        stress = g(today_w, "wellness", "averageStressLevel")

    # Most recent run
    recent_acts = get_recent_activities(data, 3)
    last_run = next((a for a in recent_acts if "run" in (a.get("activityType", {}).get("typeKey", "")).lower()), None)
    days_since_run = None
    if last_run:
        last_run_date = date.fromisoformat((last_run.get("startTimeLocal") or "")[:10])
        days_since_run = (today - last_run_date).days

    # --- Recovery score (composite) ---
    # Use TR if available, else estimate from BB + HRV
    recovery_score = tr_score
    if recovery_score is None and bb_peak is not None:
        recovery_score = bb_peak  # rough proxy

    # --- Decision logic ---
    phase_name = current_phase["name"] if current_phase else "Training"
    phase_focus = current_phase["focus"] if current_phase else ""

    # Headline
    if recovery_score is not None:
        if recovery_score >= 75:
            headline = "Recovery looks strong — green light to run today."
        elif recovery_score >= 50:
            headline = "Moderate recovery — keep it easy today."
        else:
            headline = "Low readiness — prioritise rest or a very short walk."
    else:
        headline = "Check your Garmin for today's readiness before heading out."

    # Today's recommendation
    lines = [f"**{headline}**", ""]

    # Body paragraph 1 — what the numbers say
    metrics_parts = []
    if tr_score is not None:
        metrics_parts.append(f"Training Readiness is {tr_score}")
    if bb_peak is not None:
        metrics_parts.append(f"Body Battery peaked at {bb_peak}")
    if rhr is not None:
        metrics_parts.append(f"resting HR is {rhr} bpm")
    if hrv is not None:
        status_note = f" ({hrv_status.lower()})" if hrv_status else ""
        metrics_parts.append(f"HRV last night was {hrv} ms{status_note}")
    if stress is not None:
        stress_label = "low" if stress < 26 else ("moderate" if stress < 51 else "elevated")
        metrics_parts.append(f"average stress was {stress} ({stress_label})")

    if metrics_parts:
        lines.append("Your numbers today: " + ", ".join(metrics_parts) + ".")
        lines.append("")

    # Body paragraph 2 — what to do
    if recovery_score is not None and recovery_score >= 75:
        if phase_name == "Confirm Recovery":
            lines.append(
                f"Stick to the recovery protocol: easy 5–6 km at 7:00–7:30/km, "
                f"HR under {easy_hr_cap} bpm. Singapore heat will push your HR up — "
                f"slow down rather than let it creep above the cap."
            )
        elif phase_name == "Rebuild Base":
            lines.append(
                f"Good day to extend your long run. Aim for 8–10 km at an easy conversational pace, "
                f"HR under {easy_hr_cap} bpm. Focus on time on feet, not pace."
            )
        elif phase_name in ("Build + Hike Prep", "Peak Block"):
            lines.append(
                f"Readiness supports a quality session. Consider a tempo effort: "
                f"10–12 km with 20 min at 155–165 bpm in the middle. "
                f"Warm up and cool down easy."
            )
        elif phase_name == "Norway Hiking":
            lines.append(
                "You're in Norway — today's hiking is your training. Enjoy it. "
                "Focus on fuelling well and managing your knees on the descents."
            )
        else:
            lines.append(
                f"Good recovery — an easy 5–6 km run today is well within range. "
                f"Keep HR under {easy_hr_cap} bpm."
            )
    elif recovery_score is not None and recovery_score >= 50:
        lines.append(
            f"Keep today easy: 4–5 km at a relaxed pace, HR strictly under {easy_hr_cap} bpm. "
            f"If you feel flat after 10 minutes, turn around. No hero miles today."
        )
    else:
        lines.append(
            "Skip the run today. Rest, hydrate, and get to bed early. "
            "One rest day now protects the whole training block."
        )

    lines.append("")

    # --- 3-day plan ---
    def day_plan(offset):
        """Return a one-line plan for today+offset days."""
        target_date = today + timedelta(days=offset)
        label = ["Today", "Tomorrow", "Day after"][offset]
        dow = target_date.strftime("%a")

        # Which phase are we in on that day?
        p = None
        for phase in context.get("training_phases", []):
            if phase["start"] <= target_date.isoformat() <= phase["end"]:
                p = phase
                break
        pname = p["name"] if p else phase_name

        # Simple weekly pattern logic: run Mon/Wed/Fri-ish during base phases
        # Use recovery_score only for today; assume moderate recovery for future days
        is_run_day = offset == 0  # we already decided today above
        # For future days, plan alternating run/rest
        if offset > 0:
            # Count runs in last 7 days to decide cadence
            recent_run_dates = set()
            for a in data.get("activities", []):
                d = (a.get("startTimeLocal") or "")[:10]
                if d >= (today - timedelta(days=7)).isoformat():
                    if "run" in (a.get("activityType", {}).get("typeKey", "")).lower():
                        recent_run_dates.add(d)
            runs_this_week = sum(1 for d in recent_run_dates if d >= (today - timedelta(days=today.weekday())).isoformat())
            # Alternate run/rest for future days
            is_run_day = (offset % 2 == 1)  # tomorrow rest, day after run (simple pattern)

        if pname == "Norway Hiking":
            return f"**{label} ({dow}):** Hiking — active recovery, manage knees on descents."
        elif pname == "Race Taper":
            return f"**{label} ({dow}):** Easy 3–4 km shakeout or rest. Stay fresh."
        elif pname == "RACE DAY":
            return f"**{label} ({dow}):** 🏁 RACE DAY — Kiprun Singapore Half Marathon. Sub 1:50, chase 1:45."
        elif not is_run_day:
            return f"**{label} ({dow}):** Rest or easy walk. Let your body absorb the training."
        elif pname == "Confirm Recovery":
            return f"**{label} ({dow}):** Easy run — 5–6 km, 7:00–7:30/km, HR under {easy_hr_cap} bpm."
        elif pname == "Rebuild Base":
            if offset == 2:
                return f"**{label} ({dow}):** Long run — 8–10 km easy, HR under {easy_hr_cap} bpm, focus on time on feet."
            return f"**{label} ({dow}):** Easy run — 6–7 km, relaxed pace, HR under {easy_hr_cap} bpm."
        elif pname in ("Build + Hike Prep", "Peak Block"):
            if offset == 2:
                return f"**{label} ({dow}):** Tempo run — 10 km with 20 min at 155–165 bpm, easy warm-up/cool-down."
            return f"**{label} ({dow}):** Easy run — 6 km, HR under {easy_hr_cap} bpm."
        else:
            return f"**{label} ({dow}):** Easy run — 5 km, HR under {easy_hr_cap} bpm."

    lines.append("**3-Day Plan:**")
    lines.append("")
    for i in range(3):
        lines.append(day_plan(i))
    lines.append("")
    lines.append(f"*{days_to_race} days to race · Phase: {phase_name}*")

    return "\n".join(lines)


def js_arr(lst):
    return "[" + ",".join("null" if v is None else str(v) for v in lst) + "]"


def generate_html(data, context, coaching_text):
    today = date.today()
    race_date = date.fromisoformat(context.get("race_date", "2026-09-27"))
    days_to_race = (race_date - today).days

    wellness_14 = get_wellness_range(data, 14)
    today_w = next((w for w in wellness_14 if w["date"] == today.isoformat()), None)

    # Today's metrics
    rhr = g(today_w, "wellness", "restingHeartRate") or "—" if today_w else "—"
    bb_hi = g(today_w, "wellness", "bodyBatteryHighestValue") or "—" if today_w else "—"
    bb_lo = g(today_w, "wellness", "bodyBatteryLowestValue") or "—" if today_w else "—"
    stress = g(today_w, "wellness", "averageStressLevel") or "—" if today_w else "—"
    steps_raw = g(today_w, "wellness", "totalSteps") if today_w else None
    steps = f"{steps_raw:,}" if isinstance(steps_raw, int) else "—"
    hrv_n = g(today_w, "hrv", "hrvSummary", "lastNight") or "—" if today_w else "—"
    hrv_w = g(today_w, "hrv", "hrvSummary", "weeklyAvg") or "—" if today_w else "—"
    hrv_s = g(today_w, "hrv", "hrvSummary", "status") or "—" if today_w else "—"
    sleep_secs = g(today_w, "sleep", "dailySleepDTO", "sleepTimeSeconds") if today_w else None
    sleep_str = f"{int(sleep_secs)//3600}h {(int(sleep_secs)%3600)//60}m" if sleep_secs else "—"
    sleep_score = g(today_w, "sleep", "dailySleepDTO", "sleepScores", "overall", "value") or "—" if today_w else "—"
    tr_list = (today_w or {}).get("training_readiness", [])
    tr_score = tr_list[0].get("score") if tr_list else None
    tr_level = tr_list[0].get("level", "—") if tr_list else "—"

    tr_color = "#6b7280"
    if tr_score is not None:
        if tr_score >= 75: tr_color = "#10b981"
        elif tr_score >= 50: tr_color = "#f59e0b"
        else: tr_color = "#ef4444"

    # Chart data
    labels = json.dumps([w["date"][5:] for w in wellness_14])
    chart_bb_high = js_arr([g(w, "wellness", "bodyBatteryHighestValue") for w in wellness_14])
    chart_bb_low  = js_arr([g(w, "wellness", "bodyBatteryLowestValue") for w in wellness_14])
    chart_tr      = js_arr([g(w, "training_readiness", 0, "score") if w.get("training_readiness") else None for w in wellness_14])
    chart_rhr     = js_arr([g(w, "wellness", "restingHeartRate") for w in wellness_14])
    chart_hrv     = js_arr([g(w, "hrv", "hrvSummary", "lastNight") for w in wellness_14])

    # Activities table
    acts_rows = ""
    for act in get_recent_activities(data, 8):
        d = (act.get("startTimeLocal") or "")[:10]
        name = act.get("activityName", "Workout")
        dist = act.get("distance", 0)
        dist_s = f"{dist/1000:.2f} km" if dist else "—"
        dur = int(act.get("duration") or 0)
        dur_s = f"{dur//3600}h {(dur%3600)//60}m" if dur >= 3600 else f"{dur//60}m"
        hr = act.get("averageHR") or "—"
        spd = act.get("averageSpeed", 0)
        if spd and spd > 0:
            spm = (1 / spd) * 1000
            pace_s = f"{int(spm)//60}:{int(spm)%60:02d}/km"
        else:
            pace_s = "—"
        te = act.get("aerobicTrainingEffect")
        te_s = f"{te:.1f}" if te else "—"
        acts_rows += f"<tr><td>{d[5:]}</td><td>{name}</td><td>{dist_s}</td><td>{pace_s}</td><td>{hr}</td><td>{dur_s}</td><td>{te_s}</td></tr>\n"

    # Training phase timeline
    phase_html = ""
    for phase in context.get("training_phases", []):
        ps, pe = phase["start"], phase["end"]
        is_current = ps <= today.isoformat() <= pe
        is_past = pe < today.isoformat()
        cls = "phase-current" if is_current else ("phase-past" if is_past else "phase-future")
        tag = '<span class="now-tag">NOW</span>' if is_current else ""
        phase_html += f"""<div class="phase {cls}">
          <div class="phase-left">{tag}<span class="phase-name">{phase['name']}</span></div>
          <div class="phase-right"><span class="phase-dates">{ps[5:]} – {pe[5:]}</span><span class="phase-focus">{phase['focus']}</span></div>
        </div>\n"""

    # Coach HTML — convert markdown bold to <strong>
    import re
    coach_html = ""
    for para in coaching_text.strip().split("\n"):
        para = para.strip()
        if not para:
            continue
        para = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', para)
        coach_html += f"<p>{para}</p>\n"

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{context.get('athlete_name', 'Garmin')} · Training Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh}}
a{{color:inherit;text-decoration:none}}
.header{{background:linear-gradient(135deg,#1e3a5f,#0f172a);padding:20px 16px 16px;border-bottom:1px solid #1e293b}}
.header h1{{font-size:1.25rem;font-weight:700;color:#f1f5f9}}
.header .sub{{font-size:0.8rem;color:#94a3b8;margin-top:3px}}
.pills{{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}}
.pill{{display:inline-block;padding:4px 12px;border-radius:20px;font-size:0.75rem;font-weight:600}}
.pill-blue{{background:#1e3a5f;border:1px solid #3b82f6;color:#93c5fd}}
.pill-green{{background:#052e16;border:1px solid #22c55e;color:#86efac}}
.wrap{{max-width:900px;margin:0 auto;padding:14px}}
.sec{{font-size:0.68rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:#475569;margin:22px 0 8px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px}}
.card{{background:#1e293b;border-radius:10px;padding:12px;border:1px solid #334155}}
.card .lbl{{font-size:0.65rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em;margin-bottom:5px}}
.card .val{{font-size:1.5rem;font-weight:700;color:#f1f5f9;line-height:1}}
.card .sub2{{font-size:0.7rem;color:#94a3b8;margin-top:2px}}
.tr-wrap{{display:grid;grid-template-columns:auto 1fr;gap:8px;align-items:start}}
.tr-card{{background:#1e293b;border-radius:10px;padding:14px 16px;border:2px solid {tr_color};min-width:110px;text-align:center}}
.tr-card .lbl{{font-size:0.65rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em;margin-bottom:6px}}
.tr-card .score{{font-size:2.8rem;font-weight:800;color:{tr_color};line-height:1}}
.tr-card .level{{font-size:0.8rem;color:{tr_color};font-weight:700;margin-top:3px;text-transform:uppercase}}
.coach-card{{background:#1e293b;border-radius:10px;padding:16px;border-left:3px solid #3b82f6}}
.coach-card p{{font-size:0.88rem;line-height:1.65;color:#cbd5e1}}
.coach-card p+p{{margin-top:8px}}
.coach-card strong{{color:#f1f5f9}}
.box{{background:#1e293b;border-radius:10px;padding:14px;border:1px solid #334155;margin-bottom:8px}}
.box h3{{font-size:0.68rem;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:#475569;margin-bottom:10px}}
table{{width:100%;border-collapse:collapse;font-size:0.78rem}}
th{{text-align:left;color:#475569;font-weight:600;font-size:0.65rem;text-transform:uppercase;letter-spacing:.04em;padding:5px 6px;border-bottom:1px solid #334155}}
td{{padding:7px 6px;border-bottom:1px solid #1e293b;color:#cbd5e1}}
tr:last-child td{{border-bottom:none}}
.phase{{display:flex;justify-content:space-between;align-items:center;padding:8px 12px;border-radius:8px;margin-bottom:5px;gap:12px}}
.phase-past{{background:#0f172a;opacity:.5}}
.phase-current{{background:#1e3a5f;border:1px solid #3b82f6}}
.phase-future{{background:#1e293b}}
.phase-left{{display:flex;align-items:center;gap:8px;min-width:130px}}
.phase-name{{font-size:0.82rem;font-weight:600;color:#e2e8f0}}
.phase-past .phase-name{{color:#475569}}
.phase-right{{display:flex;flex-direction:column;align-items:flex-end;gap:2px}}
.phase-dates{{font-size:0.68rem;color:#64748b}}
.phase-focus{{font-size:0.73rem;color:#94a3b8;text-align:right}}
.phase-current .phase-focus{{color:#93c5fd}}
.now-tag{{background:#3b82f6;color:#fff;font-size:0.6rem;font-weight:700;padding:2px 6px;border-radius:4px;text-transform:uppercase}}
.footer{{font-size:0.65rem;color:#334155;text-align:center;padding:20px 0 12px}}
@media(max-width:520px){{
  .tr-wrap{{grid-template-columns:1fr}}
  .cards{{grid-template-columns:repeat(2,1fr)}}
  .phase-right{{display:none}}
}}
</style>
</head>
<body>
<div class="header">
<div style="max-width:900px;margin:0 auto">
  <h1>🏃 {context.get('athlete_name','Reuben')} · Training Dashboard</h1>
  <div class="sub">{context.get('race_name','Race')} · {context.get('target_time','')}</div>
  <div class="pills">
    <span class="pill pill-blue">🏁 {days_to_race} days to race</span>
    <span class="pill pill-green">Updated {today.isoformat()}</span>
  </div>
</div>
</div>

<div class="wrap">

<div class="sec">Today's Recovery</div>
<div class="tr-wrap">
  <div class="tr-card">
    <div class="lbl">Readiness</div>
    <div class="score">{tr_score if tr_score is not None else '—'}</div>
    <div class="level">{tr_level.replace('_',' ')}</div>
  </div>
  <div class="cards" style="margin:0">
    <div class="card"><div class="lbl">Resting HR</div><div class="val">{rhr}</div><div class="sub2">bpm</div></div>
    <div class="card"><div class="lbl">Body Battery</div><div class="val">{bb_hi}</div><div class="sub2">peak · {bb_lo} low</div></div>
    <div class="card"><div class="lbl">HRV</div><div class="val">{hrv_n}</div><div class="sub2">ms · {hrv_s}</div></div>
    <div class="card"><div class="lbl">Stress</div><div class="val">{stress}</div><div class="sub2">avg</div></div>
    <div class="card"><div class="lbl">Sleep</div><div class="val" style="font-size:1.1rem">{sleep_str}</div><div class="sub2">score {sleep_score}</div></div>
    <div class="card"><div class="lbl">Steps</div><div class="val" style="font-size:1.1rem">{steps}</div><div class="sub2">today</div></div>
  </div>
</div>

<div class="sec">Daily Coach</div>
<div class="coach-card">
  {coach_html}
</div>

<div class="sec">14-Day Trends</div>
<div class="box"><h3>Body Battery</h3><canvas id="bb" height="75"></canvas></div>
<div class="box"><h3>Training Readiness</h3><canvas id="tr" height="75"></canvas></div>
<div class="box"><h3>Resting Heart Rate</h3><canvas id="rhr" height="75"></canvas></div>
<div class="box"><h3>HRV Last Night</h3><canvas id="hrv" height="75"></canvas></div>

<div class="sec">Recent Activities</div>
<div class="box" style="overflow-x:auto">
  <table>
    <thead><tr><th>Date</th><th>Name</th><th>Dist</th><th>Pace</th><th>Avg HR</th><th>Time</th><th>TE</th></tr></thead>
    <tbody>{acts_rows}</tbody>
  </table>
</div>

<div class="sec">Training Plan</div>
<div class="box">
  {phase_html}
</div>

<div class="footer">Garmin Connect · auto-synced daily at 6 AM SGT</div>
</div>

<script>
CHART_JS_PLACEHOLDER
</script>
</body>
</html>"""

    js = (
        "const L=" + labels + ";\n"
        "const opt=(ymin,ymax)=>({"
        '"responsive":true,'
        '"plugins":{"legend":{"labels":{"color":"#64748b","font":{"size":10}}}},'
        '"scales":{"x":{"ticks":{"color":"#475569","font":{"size":10}},"grid":{"color":"#1e293b"}},'
        '"y":{"ticks":{"color":"#475569","font":{"size":10}},"grid":{"color":"#334155"},"min":ymin,"max":ymax}}'
        "});\n"
        "new Chart(document.getElementById('bb'),{"
        '"type":"line","data":{"labels":L,"datasets":['
        '{"label":"Peak","data":' + chart_bb_high + ',"borderColor":"#10b981","backgroundColor":"rgba(16,185,129,.1)","fill":true,"tension":.35,"pointRadius":3},'
        '{"label":"Low","data":' + chart_bb_low + ',"borderColor":"#f59e0b","backgroundColor":"rgba(245,158,11,.05)","fill":true,"tension":.35,"pointRadius":3}'
        ']},"options":opt(0,100)});\n'
        "new Chart(document.getElementById('tr'),{"
        '"type":"line","data":{"labels":L,"datasets":['
        '{"label":"Readiness","data":' + chart_tr + ',"borderColor":"#3b82f6","backgroundColor":"rgba(59,130,246,.1)","fill":true,"tension":.35,"pointRadius":3}'
        ']},"options":opt(0,100)});\n'
        "new Chart(document.getElementById('rhr'),{"
        '"type":"line","data":{"labels":L,"datasets":['
        '{"label":"RHR","data":' + chart_rhr + ',"borderColor":"#ef4444","backgroundColor":"rgba(239,68,68,.1)","fill":true,"tension":.35,"pointRadius":3}'
        ']},"options":opt()});\n'
        "new Chart(document.getElementById('hrv'),{"
        '"type":"line","data":{"labels":L,"datasets":['
        '{"label":"HRV","data":' + chart_hrv + ',"borderColor":"#a855f7","backgroundColor":"rgba(168,85,247,.1)","fill":true,"tension":.35,"pointRadius":3}'
        ']},"options":opt()});\n'
    )
    return html.replace("CHART_JS_PLACEHOLDER", js)


if __name__ == "__main__":
    DOCS_DIR.mkdir(exist_ok=True)
    data = load_data()
    context = load_context()
    print("Calling Claude for coaching text...")
    coaching = get_coaching(data, context)
    print("Generating dashboard...")
    html = generate_html(data, context, coaching)
    OUTPUT_FILE.write_text(html)
    print(f"Dashboard written → {OUTPUT_FILE}")
