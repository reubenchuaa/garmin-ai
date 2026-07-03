#!/bin/bash
# Runs on Mac wake/login — pulls latest Garmin data and updates coach note via Claude

cd /Users/amandakoh/garmin-ai

# Pull latest from GitHub
git pull --quiet

# Sync latest Garmin data first
/Users/amandakoh/opt/anaconda3/bin/python3 sync.py 3 2>/dev/null

# Trim data.json to last 30 days for coach (faster Claude processing)
/Users/amandakoh/opt/anaconda3/bin/python3 -c "
import json
from datetime import date, timedelta
d = json.load(open('garmin/data.json'))
cutoff = (date.today() - timedelta(days=60)).isoformat()
d['activities'] = [a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] >= cutoff]
for a in d['activities']:
    a.pop('_details', None)
d['wellness'] = [w for w in d.get('wellness', []) if w.get('date', '') >= cutoff]
# Keep only latest performance entry
perf = d.get('performance', {})
if perf:
    latest_key = max(perf.keys())
    d['performance'] = {latest_key: perf[latest_key]}
d.pop('latest_route', None)
open('garmin/coach_data.json', 'w').write(json.dumps(d, indent=1))
" 2>/dev/null

# Run Claude to reason about the data and write coach_note.md
# 5-min timeout guard so a hung CLI call can never stall for hours
perl -e 'alarm 300; exec @ARGV' /opt/homebrew/bin/claude --dangerously-skip-permissions -p "
You are an expert running coach for Reuben. Read garmin/coach_data.json and context.json in the current directory.
Also read garmin/coach_note.md — this is your PREVIOUS advice. You must maintain consistency with it:
- Do NOT change today's plan unless new data (a completed workout, a significant readiness drop, or injury) justifies it.
- If the previous note said today is a rest day, keep it as rest unless Reuben already ran today.
- If the previous note gave a specific session for today that hasn't been done yet, keep that same session.
- You MAY update tomorrow/day-after plans if the data shifted, but explain why.
- If nothing meaningful changed since the last note, it is fine to return the same advice with updated numbers.

From data.json, extract and reason about:
- Last 7 days of wellness (training_readiness, body_battery, resting HR, stress)
- Recent activities (distance, pace, avg HR, cadence, HR zones, training load)
- performance[most recent date]: training_status, acwr + acwr_status, acute_load, chronic_load, load_balance_feedback, vo2max_precise, heat_acclimation_pct, heat_trend
- race_pred_hm (current predicted half marathon time vs goal of 1:45-1:50)
- Any missed runs (gaps in activity dates vs expected 3x/week cadence)

Write a coach note to garmin/coach_note.md with:

**[Bold headline: one sharp sentence on today's status]**

**What your data says**
2-3 sentences using actual numbers. Include ACWR ratio and what it means (safe to build / at risk), predicted HM time vs goal, training status phrase in plain English, and heat acclimatisation progress.

**Today's session**
Specific: session type, exact distance, pace range, HR cap. Adapt if ACWR is high (>1.3 = back off), if readiness is low (<50 = rest), or if there's a missed run to account for.

**3-Day Plan**
- Today (day+0, weekday): specific session
- Tomorrow (day+1, weekday): specific session
- Day after (day+2, weekday): specific session

**This week's focus**
One sentence on the phase goal and one thing to watch (knee, cadence, HR discipline, load ratio).

Be direct, use real numbers, adapt to what actually happened. Under 280 words.
Write ONLY the markdown to garmin/coach_note.md.
" 2>/dev/null

# Prepend timestamp to coach note (replace any existing timestamp line)
if [ -f garmin/coach_note.md ]; then
  TIMESTAMP="_Updated: $(date '+%A, %d %b %Y at %I:%M %p SGT')_"
  # Remove any existing timestamp lines first
  sed -i '' '/^_Updated:.*SGT_$/d' garmin/coach_note.md
  # Remove leading blank lines
  sed -i '' '/./,$!d' garmin/coach_note.md
  echo -e "$TIMESTAMP\n\n$(cat garmin/coach_note.md)" > garmin/coach_note.md
fi

# Regenerate dashboard with new coach note
/Users/amandakoh/opt/anaconda3/bin/python3 generate_dashboard.py 2>/dev/null

# Push everything back to GitHub
git add garmin/coach_note.md docs/index.html garmin/data.json
git diff --cached --quiet || git commit -m "coach: $(date '+%Y-%m-%d %H:%M')"
git stash --quiet 2>/dev/null
git pull --rebase --quiet 2>/dev/null || true
git stash pop --quiet 2>/dev/null || true
git push --quiet
