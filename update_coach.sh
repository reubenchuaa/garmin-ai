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
perl -e 'alarm 600; exec @ARGV' $PYTHON sync.py 3 2>&1 || echo "  [sync] Sync timed out or failed"

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
acts = sorted([a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] == today],
              key=lambda a: a.get('startTimeLocal',''))
run_types = {'running', 'trail_running', 'treadmill_running', 'track_running', 'ultra_running'}
for a in acts:
    dist = round(a.get('distance', 0) / 1000, 2)
    dur = round(a.get('duration', 0) / 60, 1)
    hr = a.get('averageHR', '?')
    atype = a.get('activityType', {}).get('typeKey', 'unknown')
    label = 'RUN' if atype in run_types else atype.upper()
    print(f'  [{label}] {a.get(\"startTimeLocal\",\"?\")[:16]}: {dist}km, {dur}min, avg HR {hr}')
" 2>/dev/null)

HAS_RUN=$($PYTHON -c "
import json
from datetime import date
d = json.load(open('garmin/data.json'))
today = date.today().isoformat()
run_types = {'running', 'trail_running', 'treadmill_running', 'track_running', 'ultra_running'}
acts = [a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] == today
        and a.get('activityType', {}).get('typeKey', '') in run_types]
print('yes' if acts else 'no')
" 2>/dev/null)

if [ -n "$NEW_ACTIVITIES" ]; then
  if [ "$HAS_RUN" = "yes" ]; then
    ACTIVITY_HINT="
IMPORTANT: Reuben has completed activities today. ALL of these must be acknowledged — do not mention only one:
$NEW_ACTIVITIES
Mark the running session(s) as DONE ✅. Do NOT suggest another run for today.
"
  else
    ACTIVITY_HINT="
NOTE: Reuben has completed non-running activity today:
$NEW_ACTIVITIES
These are NOT running sessions. His scheduled run for today may still need to happen. Check the plan.
"
  fi
fi

# --- Pre-compute July running mileage (runs only, no walks/hikes) ---
JULY_RUN_KM=$($PYTHON -c "
import json
from datetime import date
d = json.load(open('garmin/data.json'))
run_types = {'running', 'trail_running', 'treadmill_running', 'track_running', 'ultra_running'}
month = date.today().strftime('%Y-%m')
total = sum(
    a.get('distance', 0) / 1000
    for a in d.get('activities', [])
    if (a.get('startTimeLocal') or '')[:7] == month
    and a.get('activityType', {}).get('typeKey', '') in run_types
)
print(f'{total:.2f}')
" 2>/dev/null || echo "?")

# --- Get today's date info for the prompt ---
TODAY_INFO=$(date '+%A, %d %B %Y')

# --- Check Claude token expiry and warn if refresh token is expiring soon ---
$PYTHON -c "
import json, subprocess, sys
from datetime import datetime, timezone
try:
    result = subprocess.run(
        ['security', 'find-generic-password', '-s', 'Claude Code-credentials', '-a', 'amandakoh', '-w'],
        capture_output=True, text=True, timeout=5
    )
    if result.returncode != 0:
        sys.exit(0)
    cred = json.loads(result.stdout.strip())
    oauth = cred.get('claudeAiOauth', {})
    ref_exp_ms = oauth.get('refreshTokenExpiresAt')
    if not ref_exp_ms:
        sys.exit(0)
    expires = datetime.fromtimestamp(int(ref_exp_ms)/1000, tz=timezone.utc)
    now = datetime.now(tz=timezone.utc)
    days_left = (expires - now).days
    if days_left <= 3:
        import subprocess as sp
        msg = f'Claude login expires in {days_left} day(s)! Open Terminal and run: claude /login'
        sp.run(['osascript', '-e', f'display notification \"{msg}\" with title \"Garmin AI Coach\" sound name \"Ping\"'], check=False)
        print(f'  [auth] WARNING: Claude refresh token expires in {days_left} days — please run: claude /login')
    else:
        print(f'  [auth] Token OK — refresh token valid for {days_left} more days')
except Exception as e:
    pass
" 2>/dev/null || true

# --- Run Claude to generate coach note (5-min timeout) ---
# Write to a temp file first so we never corrupt the real note
TMPNOTE=$(mktemp /tmp/coach_note.XXXXXX)

# --- Build the coach prompt (shared between first attempt and retry) ---
COACH_PROMPT="
You are Reuben's running coach. Your coaching is grounded in modern exercise science and the methods of elite coaches.
$ACTIVITY_HINT

YOUR COACHING PHILOSOPHY (evidence-based):
You follow the principles used by coaches like Jack Daniels, Steve Magness, Brad Hudson, and Matt Fitzgerald:
- Polarised training distribution: ~80% easy (Zone 1-2), ~20% hard (Zone 4-5). Most runs should be truly easy (conversational pace). Quality sessions are tempo, threshold, or intervals — never in-between.
- Progressive overload: increase weekly volume by no more than 10% per week (Banister impulse-response model). ACWR between 0.8–1.3 is the safe loading zone (Gabbett 2016). Below 0.8 = undertraining and injury risk from load spikes. Above 1.5 = overreaching.
- Supercompensation: hard session → recovery → adaptation. Never stack two hard sessions on consecutive days. Allow 48h between quality sessions.
- Cardiac drift and HR discipline: in Singapore heat (30°C+), expect cardiac drift of 5–10 bpm over 45+ min. Cap easy runs by HR, not pace. If HR drifts above easy ceiling, slow down — aerobic development happens at low intensity (Maffetone method).
- Daniels' VDOT: use race prediction to set training paces. Easy pace, threshold pace, interval pace should all be derived from current fitness, not goal fitness.
- Tapering: 2–3 week taper before a goal race. Reduce volume 40–60% but maintain intensity (Mujika & Padilla 2003).
- Sleep and recovery: prioritise 7–9h sleep. HRV trend (not single readings) indicates readiness. Resting HR elevation of >5 bpm from baseline = back off. Training Readiness below 40 = mandatory easy or rest.
- Heat adaptation: takes 10–14 days of heat exposure. Running in Singapore contributes — track heat acclimatisation percentage.

YOUR TONE:
Firm, encouraging, data-driven. Like a coach who genuinely believes in him. Be direct with numbers, honest about gaps, but motivating — not harsh. When he hits a session well, give credit. When he's behind, frame it as \"here's how we fix this\" not \"you're failing.\"

⚠️ CRITICAL DATE WARNING: TODAY IS $TODAY_INFO. The previous note was written for a DIFFERENT day. Any dates in the previous note are WRONG and MUST NOT be copied. The 3-Day Plan must use $TODAY_INFO as day 1. If you output yesterday's date anywhere in the plan, the note is invalid.

JULY RUNNING MILEAGE (pre-computed, running activities only — use this exact number): ${JULY_RUN_KM}km of 100km target

RULES:
- Safety first — never risk injury. But if the data supports it, push him.
- If ACWR < 0.8: flag it. Explain the injury risk of sudden load spikes (Gabbett). Prescribe a controlled volume increase.
- If ACWR > 1.3: flag it. Prescribe an easier session or extra rest to let chronic load catch up.
- If Training Readiness < 40 or resting HR is elevated > 5 bpm above his baseline (~47): prescribe easy or rest. The body is not ready for quality work.
- If HRV trend is declining over 3+ days: note it as a fatigue signal, adjust intensity down.
- Track July 100km mileage. Tell him where he stands and what's needed.
- Easy runs: prescribe by HR cap (≤ 135 bpm), give a pace range as guidance only. If HR exceeds cap, slow down.
- Tempo/threshold runs: prescribe by pace AND HR band. Tempo = ~85-90% max HR, comfortably hard, sustainable for 20-40 min. This is the pace that builds lactate clearance capacity.
- Long runs: should be easy effort, building aerobic base. No more than 30% of weekly volume in a single run.
- Rest days: explain the science — adaptation occurs during recovery, not during the run. Rest is not weakness, it's when fitness is built.
- CRITICAL: Read context.json carefully. If it says certain days are unavailable, NEVER schedule runs on those days. Plan around them.

Read garmin/coach_data.json and context.json in the current directory.
Also read garmin/coach_note.md for your PREVIOUS advice. Use it for session consistency only:
- If the previous note planned a specific session for today that hasn't been done yet, keep that session type/distance/pace.
- If today was planned as rest, keep it as rest unless Reuben already ran today.
- You MUST write a FRESH note with TODAY's date ($TODAY_INFO) and updated numbers from coach_data.json. NEVER copy dates from the previous note.

From coach_data.json, extract and use the LATEST numbers:
- performance[most recent date]: ACWR, acwr_status, training_status, race_pred_hm, vo2max_precise, heat_acclimation_pct
- Last 7 days of wellness: training_readiness, body_battery, resting HR, stress, sleep, HRV
- Recent activities: distance, pace, avg HR, cadence, training load
- July RUNNING mileage total (running activities ONLY — exclude walks, hikes, cycling, and any non-running activity types) vs 100km target

SESSION DESIGN GUIDELINES:
- Easy run: HR ≤ 135, pace ~7:00-7:30/km (adjust for heat). Purpose: aerobic base, capillary development, fat oxidation.
- Tempo/threshold: 5-8km at ~6:00-6:15/km, HR 155-165. Purpose: raise lactate threshold, the single biggest predictor of half marathon performance.
- Long run: 10-15km at easy effort, HR ≤ 135. Purpose: build endurance, mitochondrial density, glycogen storage.
- Intervals (peak phase only): 4-6 x 800m-1km at ~5:00-5:15/km pace, 90s jog recovery. Purpose: VO2max development.
- Always include warm-up (1-2km easy) and cool-down (1-2km easy) for tempo/interval sessions.
- Weekly structure: 1 quality session + 1-2 easy runs + 1 long run + rest days. Never two quality sessions in a row.

Write the note to garmin/coach_note.md with EXACTLY this structure:

**[Bold headline: one sentence on where he stands today]**

**What your data says**
2-3 sentences. ACWR ratio (from today's performance data, NOT yesterday's), predicted HM time vs goal, July km done vs 100km target with days remaining. Reference training status and any notable wellness signals (HRV trend, sleep, readiness).

**Today's session**
What to do today. Be specific with distance, pace range, HR cap. Explain the physiological purpose of the session in one line. If rest day, explain why recovery matters.

**3-Day Plan**
- Today ($TODAY_INFO): session
- Tomorrow: session
- Day after: session

**Coach's take**
One motivating sentence grounded in what the data shows is possible.

Under 300 words. Write ONLY the markdown to garmin/coach_note.md. No commentary, no explanation — just the note content.
"

# --- Helper: validate a coach note file ---
# Returns 0 if valid (has content + references today's date), 1 otherwise
validate_coach_note() {
  local file="$1"
  local today_day today_month today_full
  today_day=$(date '+%-d')         # e.g. "12"
  today_month=$(date '+%b')        # e.g. "Jul"
  today_full=$(date '+%A')         # e.g. "Sunday"
  local note_size
  note_size=$(wc -c < "$file" 2>/dev/null || echo 0)

  # Must be non-trivial and contain bold markers
  if [ "$note_size" -lt 100 ] || ! grep -q '\*\*' "$file" 2>/dev/null; then
    echo "  [coach] Validation FAIL: too short or no bold markers (${note_size} bytes)"
    return 1
  fi
  # Must contain today's full date (e.g. "12 July 2026" or "Jul 12") in the Today line of the 3-Day Plan
  today_year=$(date '+%Y')
  today_long=$(date '+%-d %B %Y')    # e.g. "12 July 2026"
  today_short2=$(date '+%b %-d')     # e.g. "Jul 12"
  # Look for the Today bullet in the 3-Day Plan containing today's actual date
  if grep -i "Today" "$file" 2>/dev/null | grep -q "$today_long\|$today_short2"; then
    return 0
  fi
  echo "  [coach] Validation FAIL: 3-Day Plan 'Today' line does not contain $today_long"
  return 1
}

# --- Preflight: check Claude is logged in before attempting anything ---
if ! "$CLAUDE" --version > /dev/null 2>&1 || "$CLAUDE" --dangerously-skip-permissions -p "ping" 2>&1 | grep -qi "not logged in\|login\|auth"; then
  echo "  [coach] ERROR: Claude CLI not logged in — skipping coach note update entirely"
  # Do NOT re-stamp the existing note; leave it unchanged so the stale timestamp is obvious
  $PYTHON generate_dashboard.py 2>/dev/null
  /bin/bash "$REPO/git_safe_push.sh" "coach-skip: not logged in $(date '+%Y-%m-%d %H:%M')" docs/index.html 2>/dev/null
  exit 0
fi

# --- Run Claude (attempt 1) ---
TMPNOTE=$(mktemp /tmp/coach_note.XXXXXX)
perl -e 'alarm 300; exec @ARGV' "$CLAUDE" --dangerously-skip-permissions -p "$COACH_PROMPT" > "$TMPNOTE" 2>/dev/null
CLAUDE_EXIT=$?
[ $CLAUDE_EXIT -ne 0 ] && echo "  [coach] Claude attempt 1 exited with code $CLAUDE_EXIT"

# --- Validate attempt 1 ---
NOTE_OK=false
if [ -f garmin/coach_note.md ] && validate_coach_note garmin/coach_note.md; then
  NOTE_OK=true
  echo "  [coach] Attempt 1 passed validation"
else
  echo "  [coach] Attempt 1 failed validation — retrying with stricter prompt..."
  # Back up the bad note so retry can overwrite it
  cp garmin/coach_note.md garmin/coach_note.md.bad 2>/dev/null || true

  RETRY_PROMPT="RETRY — your previous output was REJECTED because it contained stale dates from the previous note.

TODAY IS: $TODAY_INFO. You MUST use this exact date for 'Today' in the 3-Day Plan. Do not write any other date for today.

$COACH_PROMPT"

  perl -e 'alarm 300; exec @ARGV' "$CLAUDE" --dangerously-skip-permissions -p "$RETRY_PROMPT" > "$TMPNOTE" 2>/dev/null
  CLAUDE_EXIT=$?
  [ $CLAUDE_EXIT -ne 0 ] && echo "  [coach] Claude attempt 2 exited with code $CLAUDE_EXIT"

  if [ -f garmin/coach_note.md ] && validate_coach_note garmin/coach_note.md; then
    NOTE_OK=true
    echo "  [coach] Attempt 2 passed validation"
  else
    echo "  [coach] WARNING: Both attempts failed validation — keeping previous note"
    # Restore the better of the two bad attempts (attempt 1 may have more content)
    cp garmin/coach_note.md.bad garmin/coach_note.md 2>/dev/null || true
  fi
  rm -f garmin/coach_note.md.bad
fi

# --- Stamp and finalise if valid ---
if [ "$NOTE_OK" = true ]; then
  note_size=$(wc -c < garmin/coach_note.md)
  TIMESTAMP="_Updated: $(date '+%A, %d %b %Y at %I:%M %p SGT')_"
  sed -i '' '/^_Updated:/d' garmin/coach_note.md
  sed -i '' '/./,$!d' garmin/coach_note.md
  printf '%s\n\n%s\n' "$TIMESTAMP" "$(cat garmin/coach_note.md)" > garmin/coach_note.md
  echo "  [coach] Note finalised (${note_size} bytes)"
fi

rm -f "$TMPNOTE"

# --- Push next workout to Garmin watch ---
$PYTHON push_workout.py 2>/dev/null || echo "  [workout] Push skipped or failed"

# --- Regenerate dashboard ---
$PYTHON generate_dashboard.py 2>/dev/null

# --- Commit and push (with locking, conflict resolution, retries) ---
/bin/bash "$REPO/git_safe_push.sh" "coach: $(date '+%Y-%m-%d %H:%M')" garmin/coach_note.md docs/index.html garmin/data.json
