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
    s = w.get('sleep', {})
    if s:
        dto = s.get('dailySleepDTO', {})
        w['sleep'] = {'dailySleepDTO': {k: dto[k] for k in ('calendarDate','sleepTimeSeconds','deepSleepSeconds','lightSleepSeconds','remSleepSeconds','awakeSleepSeconds','avgHeartRate','avgSleepStress','sleepScoreFeedback') if k in dto}, 'avgOvernightHrv': s.get('avgOvernightHrv')}
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

# --- Detect today's completed activities ---
ACTIVITY_HINT=""
NEW_ACTIVITIES=$($PYTHON -c "
import json
from datetime import date
d = json.load(open('garmin/data.json'))
today = date.today().isoformat()
acts = [a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] == today]
for a in acts:
    dist = round(a.get('distance', 0) / 1000, 2)
    dur = round(a.get('duration', 0) / 60, 1)
    hr = a.get('averageHR', '?')
    print(f'  {a.get(\"startTimeLocal\",\"?\")[:16]}: {dist}km, {dur}min, avg HR {hr}')
" 2>/dev/null)

if [ -n "$NEW_ACTIVITIES" ]; then
  ACTIVITY_HINT="
IMPORTANT: Reuben has ALREADY RUN today. Here are today's completed activities:
$NEW_ACTIVITIES
Acknowledge the completed run with specific stats. Mark today's session as DONE ✅. Do NOT suggest another run for today.
"
fi

# --- Get today's date info for the prompt ---
TODAY_INFO=$(date '+%A, %d %B %Y')

# --- Run Claude to generate coach note (5-min timeout) ---
# Write to a temp file first so we never corrupt the real note
TMPNOTE=$(mktemp /tmp/coach_note.XXXXXX)

perl -e 'alarm 300; exec @ARGV' "$CLAUDE" --dangerously-skip-permissions -p "
You are Reuben's running coach. You are firm, encouraging, and data-driven. You push him to be his best while keeping it positive. You celebrate progress AND point out where he needs to step up.

Your tone: like a coach who genuinely believes in him. Be direct with the numbers, honest about gaps, but motivating — not harsh. When he hits a session well, give him credit. When he's behind, tell him clearly what needs to happen, but frame it as \"here's how we fix this\" not \"you're failing.\"
$ACTIVITY_HINT

TODAY IS: $TODAY_INFO
The 3-Day Plan MUST start from TODAY. Use today's actual date and weekday. Do NOT copy dates from the previous note.

Rules:
- Safety first — never risk injury. But if the data says he can handle more, encourage him to push.
- If ACWR is low (<0.8), flag it and explain why more volume matters.
- If he missed a scheduled run, note it and adjust the plan — no guilt trips, just solutions.
- Track his July 100km mileage closely. Tell him where he stands and what's needed.
- Race is approaching. Keep the urgency real but motivating.
- CRITICAL: Read context.json carefully. If it says certain days are unavailable, NEVER schedule runs on those days. Plan around them.

Read garmin/coach_data.json and context.json in the current directory.
Also read garmin/coach_note.md for your PREVIOUS advice. Use it for session consistency only:
- If the previous note planned a specific session for today that hasn't been done yet, keep that session type/distance/pace.
- If today was planned as rest, keep it as rest unless Reuben already ran today.
- You MUST write a FRESH note with TODAY's date and updated numbers from coach_data.json. NEVER return the previous note unchanged.

From coach_data.json, extract and use the LATEST numbers:
- performance[most recent date]: ACWR, acwr_status, training_status, race_pred_hm, vo2max_precise, heat_acclimation_pct
- Last 7 days of wellness: training_readiness, body_battery, resting HR, stress, sleep, HRV
- Recent activities: distance, pace, avg HR, cadence, training load
- July mileage total so far vs 100km target

Write the note to garmin/coach_note.md with EXACTLY this structure:

**[Bold headline: one sentence on where he stands today]**

**What your data says**
2-3 sentences. ACWR ratio (from today's performance data, NOT yesterday's), predicted HM time vs goal, July km done vs 100km target with days remaining.

**Today's session**
What to do today. Be specific with distance, pace, HR. If rest day, say why.

**3-Day Plan**
- Today ($TODAY_INFO): session
- Tomorrow: session
- Day after: session

**Coach's take**
One motivating sentence.

Under 280 words. Write ONLY the markdown to garmin/coach_note.md. No commentary, no explanation — just the note content.
" > "$TMPNOTE" 2>/dev/null

# --- Validate the new note ---
CLAUDE_EXIT=$?
if [ $CLAUDE_EXIT -ne 0 ]; then
  echo "  [coach] Claude exited with code $CLAUDE_EXIT"
fi

# Check if Claude wrote directly to coach_note.md (it should via the prompt)
# or if it wrote to stdout (captured in TMPNOTE)
if [ -f garmin/coach_note.md ]; then
  note_size=$(wc -c < garmin/coach_note.md)
  # Validate: must have content, must contain bold markers, must reference today's date
  today_short=$(date '+%b %-d')  # e.g. "Jul 7"
  today_weekday=$(date '+%a')     # e.g. "Tue"

  has_content=false
  if [ "$note_size" -gt 100 ] && grep -q '\*\*' garmin/coach_note.md 2>/dev/null; then
    has_content=true
  fi

  if [ "$has_content" = true ]; then
    # Prepend timestamp
    TIMESTAMP="_Updated: $(date '+%A, %d %b %Y at %I:%M %p SGT')_"
    sed -i '' '/^_Updated:/d' garmin/coach_note.md
    sed -i '' '/./,$!d' garmin/coach_note.md
    printf '%s\n\n%s\n' "$TIMESTAMP" "$(cat garmin/coach_note.md)" > garmin/coach_note.md
    echo "  [coach] Note updated (${note_size} bytes)"
  else
    echo "  [coach] WARNING: Coach note looks invalid (${note_size} bytes, no bold markers)"
    echo "  [coach] Content preview: $(head -3 garmin/coach_note.md)"
  fi
else
  echo "  [coach] No coach note file found after Claude run"
fi

rm -f "$TMPNOTE"

# --- Push next workout to Garmin watch ---
$PYTHON push_workout.py 2>/dev/null || echo "  [workout] Push skipped or failed"

# --- Regenerate dashboard ---
$PYTHON generate_dashboard.py 2>/dev/null

# --- Commit and push (with locking, conflict resolution, retries) ---
/bin/bash "$REPO/git_safe_push.sh" "coach: $(date '+%Y-%m-%d %H:%M')" garmin/coach_note.md docs/index.html garmin/data.json
