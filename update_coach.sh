#!/bin/bash
# Runs on Mac wake/login — pulls latest Garmin data and updates coach note via Claude
# Uses git_safe_push.sh for reliable git operations with locking and retries.

REPO="/Users/amandakoh/garmin-ai"
PYTHON="/Users/amandakoh/opt/anaconda3/bin/python3"
CLAUDE="/opt/homebrew/bin/claude"

cd "$REPO"

# --- Pull latest ---
/bin/bash "$REPO/git_safe_push.sh" "__pull_only__" 2>/dev/null || true

# --- Sync latest Garmin data (last 3 days, 10-min timeout) ---
perl -e 'alarm 600; exec @ARGV' $PYTHON sync.py 3 2>/dev/null || echo "  [sync] Sync timed out or failed"

# --- Trim data.json for coach (last 60 days) ---
$PYTHON -c "
import json, sys
from datetime import date, timedelta
try:
    d = json.load(open('garmin/data.json'))
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f'Error reading data.json: {e}', file=sys.stderr)
    sys.exit(1)
cutoff = (date.today() - timedelta(days=60)).isoformat()
d['activities'] = [a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] >= cutoff]
for a in d['activities']:
    a.pop('_details', None)
d['wellness'] = [w for w in d.get('wellness', []) if w.get('date', '') >= cutoff]
for w in d['wellness']:
    # Trim sleep to just the summary (dailySleepDTO) — raw arrays are 100KB+ each
    s = w.get('sleep', {})
    if s:
        dto = s.get('dailySleepDTO', {})
        w['sleep'] = {'dailySleepDTO': {k: dto[k] for k in ('calendarDate','sleepTimeSeconds','deepSleepSeconds','lightSleepSeconds','remSleepSeconds','awakeSleepSeconds','avgHeartRate','avgSleepStress','sleepScoreFeedback') if k in dto}, 'avgOvernightHrv': s.get('avgOvernightHrv')}
    # Trim HRV to just the summary
    h = w.get('hrv', {})
    if h:
        w['hrv'] = {'hrvSummary': h.get('hrvSummary', {})}
perf = d.get('performance', {})
if perf:
    latest_key = max(perf.keys())
    d['performance'] = {latest_key: perf[latest_key]}
d.pop('latest_route', None)
open('garmin/coach_data.json', 'w').write(json.dumps(d, indent=1))
" || { echo "Coach data trim failed"; exit 1; }

# --- Back up current coach note before Claude overwrites ---
if [ -f garmin/coach_note.md ]; then
  cp garmin/coach_note.md garmin/coach_note.md.bak
fi

# --- Run Claude to generate coach note (5-min timeout) ---
perl -e 'alarm 300; exec @ARGV' "$CLAUDE" --dangerously-skip-permissions -p "
You are Reuben's no-nonsense running coach. You are STRICT, DIRECT, and you PUSH him hard. You do not sugarcoat. You hold him accountable to his goals — 1:45-1:50 half marathon, 100km in July, and peak fitness for Norway.

Your tone: demanding but fair. If he skipped a run, call it out bluntly. If his numbers are slipping, tell him. If he's on track, acknowledge it briefly and raise the bar. You care about him — that's WHY you push. Coddling him means he misses his goals.

Rules:
- NEVER compromise on injury safety — but don't use safety as an excuse to go easy when the data says he can handle more.
- If ACWR is low (<0.8), push harder. He's UNDERTRAINING. Call it out.
- If he missed a scheduled run, demand he makes it up. No free passes.
- If his pace was too slow on an easy run, fine. But if he's consistently sandbagging, say so.
- Track his July 100km mileage obsessively. Tell him exactly where he stands and what he needs per week to hit it.
- Race is in 84 days. Every session matters. Remind him.

Read garmin/coach_data.json and context.json in the current directory.
Also read garmin/coach_note.md — this is your PREVIOUS advice. You must maintain consistency with it:
- Do NOT change today's plan unless new data (a completed workout, a significant readiness drop, or injury) justifies it.
- If the previous note said today is a rest day, keep it as rest unless Reuben already ran today.
- If the previous note gave a specific session for today that hasn't been done yet, keep that same session.
- You MAY update tomorrow/day-after plans if the data shifted, but explain why.
- If nothing meaningful changed since the last note, it is fine to return the same advice with updated numbers.

From data.json, extract and reason about:
- Last 7 days of wellness (training_readiness, body_battery, resting HR, stress, sleep duration + stages, HRV overnight avg)
- Recent activities (distance, pace, avg HR, cadence, HR zones, training load)
- performance[most recent date]: training_status, acwr + acwr_status, acute_load, chronic_load, load_balance_feedback, vo2max_precise, heat_acclimation_pct, heat_trend
- race_pred_hm (current predicted half marathon time vs goal of 1:45-1:50)
- Any missed runs (gaps in activity dates vs expected 3x/week cadence)

Write a coach note to garmin/coach_note.md with:

**[Bold headline: one STRICT sentence — push him or call him out]**

**The numbers don't lie**
2-3 sentences with real data. ACWR ratio and what it means, predicted HM time vs goal (highlight the GAP), July mileage done vs target (with exact km remaining and days left). Be blunt about what's working and what's not.

**Today's session — non-negotiable**
Specific: session type, exact distance, pace range, HR cap. No wiggle room. If the data supports pushing harder, push harder. Only back off for genuine injury risk or readiness below 40.

**3-Day Plan**
- Today (day+0, weekday): specific session — no excuses
- Tomorrow (day+1, weekday): specific session
- Day after (day+2, weekday): specific session

**Bottom line**
One sentence: what he MUST do this week to stay on track. Be direct. If he's falling behind, say it.

Be demanding, use real numbers, push hard. Under 280 words.
Write ONLY the markdown to garmin/coach_note.md.
" 2>/dev/null

# --- Validate coach note wasn't corrupted by timeout ---
if [ -f garmin/coach_note.md ]; then
  # Check if the note has actual content (at least 50 chars, contains a bold header)
  note_size=$(wc -c < garmin/coach_note.md)
  if [ "$note_size" -lt 50 ] || ! grep -q '^\*\*' garmin/coach_note.md 2>/dev/null; then
    echo "  [coach] Coach note looks corrupt or incomplete (${note_size} bytes), restoring backup"
    if [ -f garmin/coach_note.md.bak ]; then
      cp garmin/coach_note.md.bak garmin/coach_note.md
    fi
  else
    # Prepend timestamp
    TIMESTAMP="_Updated: $(date '+%A, %d %b %Y at %I:%M %p SGT')_"
    sed -i '' '/^_Updated:.*SGT_$/d' garmin/coach_note.md
    sed -i '' '/./,$!d' garmin/coach_note.md
    printf '%s\n\n%s\n' "$TIMESTAMP" "$(cat garmin/coach_note.md)" > garmin/coach_note.md
  fi
  rm -f garmin/coach_note.md.bak
else
  echo "  [coach] No coach note generated"
fi

# --- Regenerate dashboard ---
$PYTHON generate_dashboard.py 2>/dev/null

# --- Commit and push (with locking, conflict resolution, retries) ---
/bin/bash "$REPO/git_safe_push.sh" "coach: $(date '+%Y-%m-%d %H:%M')" garmin/coach_note.md docs/index.html garmin/data.json
