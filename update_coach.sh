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
# Walking activities are EXCLUDED — Reuben tracks walks on Garmin for a company
# project; they are NOT training and must never appear in the coach note.
walk_types = {'walking', 'indoor_walking', 'casual_walking', 'speed_walking'}
acts = sorted([a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] == today
               and a.get('activityType', {}).get('typeKey', '') not in walk_types],
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

# --- Pre-compute IPPT / training-volume summary (runs + strength, last 7 days, IPPT log) ---
IPPT_INFO=$($PYTHON -c "
import json
from datetime import date, timedelta
d = json.load(open('garmin/data.json'))
today = date.today()
run_types = {'running','trail_running','treadmill_running','track_running','ultra_running'}
strength_types = {'strength_training','hiit','indoor_cardio','cardio','functional_strength_training','calisthenics','pilates','yoga'}
def wk(days):
    lo = (today - timedelta(days)).isoformat()
    runs = [a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] >= lo and a.get('activityType', {}).get('typeKey','') in run_types]
    st = [a for a in d.get('activities', []) if (a.get('startTimeLocal') or '')[:10] >= lo and a.get('activityType', {}).get('typeKey','') in strength_types]
    return sum(a.get('distance',0) for a in runs)/1000, len(runs), len(st)
km7, r7, s7 = wk(7); km28, r28, s28 = wk(28)
test = date(2027,2,19); trip = date(2027,2,20)
out = [f'Days to IPPT deadline (19 Feb 2027): {(test-today).days}. Days to snowboarding trip (20 Feb): {(trip-today).days}.']
out.append(f'Last 7 days: {km7:.1f}km running over {r7} run(s), {s7} strength/cardio session(s). Last 28 days: {km28:.1f}km over {r28} run(s), {s28} strength/cardio session(s) (avg {s28/4:.1f}/wk).')
try:
    log = json.load(open('ippt_log.json')).get('tests', [])
except Exception:
    log = []
if not log:
    out.append('IPPT LOG: NO TESTS LOGGED YET. Baseline is untested — prescribe/confirm the baseline test (max 1-min push-ups, max 1-min sit-ups, all-out 2.4km) and tell him to log it with: python3 log_ippt.py <pushups> <situps> <M:SS> baseline')
else:
    for t in log[-6:]:
        m, s_ = divmod(int(t['run_2400_sec']), 60)
        pts = f\", {t['points']} pts\" if t.get('points') else ''
        out.append(f\"IPPT {t['type']} {t['date']}: {t['pushups']} push-ups, {t['situps']} sit-ups, 2.4km {m}:{s_:02d}{pts}\")
print(' | '.join(out))
" 2>/dev/null || echo "IPPT summary unavailable.")

# --- Pre-compute fuel/calorie data ---
FUEL_INFO=$($PYTHON -c "
import json
from datetime import date, timedelta
d = json.load(open('garmin/data.json'))
today = date.today().isoformat()
yesterday = (date.today() - timedelta(1)).isoformat()

def day_cals(dstr):
    for w in d.get('wellness', []):
        if w.get('date') == dstr:
            wl = w.get('wellness', {})
            return wl.get('totalKilocalories'), wl.get('activeKilocalories'), wl.get('bmrKilocalories')
    return None, None, None

y_total, y_active, y_bmr = day_cals(yesterday)
t_total, t_active, t_bmr = day_cals(today)

run_types = {'running','trail_running','treadmill_running','track_running','ultra_running'}
# Today's run calories
today_run_cal = sum(a.get('calories',0) for a in d.get('activities',[])
    if (a.get('startTimeLocal') or '')[:10] == today
    and a.get('activityType',{}).get('typeKey','') in run_types)

# Is today a run day (planned or done)? Use yesterday's active as proxy baseline
bmr = y_bmr or t_bmr or 1788
# Maintenance target: eat back total burn. Run day ~+400-600 over rest.
lines = []
if y_total: lines.append(f'Yesterday burned {int(y_total)} kcal total (active {int(y_active or 0)}, BMR {int(y_bmr or bmr)}).')
if today_run_cal: lines.append(f'Today run so far: {int(today_run_cal)} kcal.')
lines.append(f'BMR ~{int(bmr)} kcal. Maintenance intake target: eat back total daily burn — do NOT run a deficit (athlete wants to maintain weight and fuel training fully). Run days ~2300-2500 kcal, rest days ~2000-2100 kcal. On hard/long-run days lean slightly OVER maintenance to protect recovery and HRV.')
print(' '.join(lines))
" 2>/dev/null || echo "Calorie data unavailable.")

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
You are Reuben's fitness coach. His goal is to score IPPT GOLD (85+ points) BY 19 Feb 2027 — that date is a deadline, not a fixed test day; the official IPPT can be taken any earlier day, so aim to bank Gold early (target window 25 Jan–12 Feb, keeping up to 19 Feb as a retake buffer) — then enjoy a week-long BEGINNER snowboarding trip from 20 Feb 2027. Your coaching is grounded in exercise science.
$ACTIVITY_HINT

YOUR COACHING PHILOSOPHY (evidence-based):
- IPPT = 3 stations: 1-minute push-ups, 1-minute sit-ups, 2.4km run. Gold = 85+ total points and every station must score at least 1 point. Identify the WEAKEST station from his logged tests and weight training toward it — the cheapest points are in the weakest station. His aerobic engine (VO2max ~55.8, resting HR ~47) is strong, so the run is probably his best station, but this must be confirmed by data, not assumed.
- NEVER invent IPPT point values. Scoring depends on his age band at the test date (he turns 28-30 on 19 Feb; testing BEFORE his birthday may put him in the younger, harder band — flag this when scheduling the attempt). If no official points are logged, say targets are working estimates and tell him to check the official IPPT scoring table for his age band.
- Push-ups / sit-ups (muscular endurance): specificity + volume. Use greasing-the-groove (many submaximal sets spread through the day, never to failure), rep ladders/pyramids, density blocks (e.g. max sets of N in 10 min), and a weekly max-rep re-test no more than once per week. Perfect form = reps that count. Allow 48h before re-testing a hammered muscle group.
- 2.4km run: one interval session/week (400m or 800m repeats near goal 2.4km pace, equal or shorter recovery), one tempo or steady run, rest easy aerobic (HR <= 135 bpm, Maffetone). Time trials sparingly. Polarised: ~80% easy / 20% hard. Singapore heat inflates HR by 5-8 bpm — cap easy runs by HR, not pace.
- Progressive overload: raise weekly volume no more than ~10%. ACWR 0.8-1.3 is the safe zone (Gabbett 2016). Never two hard sessions on consecutive days. Do not stack a hard run and heavy legs on the same day.
- SNOWBOARDING PREP (beginner): leg endurance (goblet/back squats, split squats, wall sits, Bulgarian split squats, step-downs), glutes/hips (hip thrusts, lateral band walks), core and anti-rotation (planks, side planks, Pallof press), single-leg balance (BOSU/foam), ankle + hip mobility, and wrist/shoulder resilience. Falls are inevitable for a beginner — prioritise resilience over max strength. His medial knee niggle (Jun 2026) means keep light step-downs/glute work ~2x/week.
- TIMING RULES: no heavy leg sessions in the last 5 days before the official IPPT attempt or before the trip (arrive fresh, not sore). Recommend the official attempt once mocks are consistently Gold with margin. If Gold is banked, switch to maintenance + trip prep; if not, taper briefly and retake before 19 Feb. The trip itself is active recovery.
- BODY COMPOSITION (see context.json body): he is already lean (13.2% body fat, BMI 18.9) and his goal is to ADD MUSCLE for an athletic look. NEVER prescribe a calorie deficit or fat-loss dieting. Fuel at maintenance or a small surplus with ~90-110g protein/day, and include 2-3 gym lifting sessions/week (compound lifts, progressive overload) alongside IPPT work and snowboard-leg strength.
- Sleep and recovery: 7-9h sleep. HRV TREND (not single readings) = readiness. Resting HR >5 bpm above baseline (~47) = back off. Training Readiness below 40 = mandatory easy or rest. Push-up/sit-up volume still counts as load — respect it.

YOUR TONE:
Firm, encouraging, data-driven. A coach who believes he can hit Gold. Direct with numbers, honest about gaps (\"here is how we fix it\"), credit when earned.

⚠️ CRITICAL DATE WARNING: TODAY IS $TODAY_INFO. The previous note was written for a DIFFERENT day. Any dates in the previous note are WRONG and MUST NOT be copied. The 3-Day Plan must use $TODAY_INFO as day 1. If you output yesterday's date anywhere in the plan, the note is invalid.

IPPT / VOLUME DATA (pre-computed — use these exact numbers): $IPPT_INFO

RULES:
- Safety first — never risk injury. If data supports it, push him.
- If ACWR < 0.8: flag it, prescribe a controlled volume increase. If ACWR > 1.3: flag it, prescribe easier work or rest.
- If Training Readiness < 40 or resting HR > 5 bpm above baseline (~47): easy or rest; no quality work, no max-rep tests.
- If HRV trend declines over 3+ days: fatigue signal, adjust down.
- Read context.json (training_phases, ippt, trip, key_context) and ippt_log.json. Prescribe according to TODAY's phase. If the IPPT log is empty and we are in/near the Baseline Test week (16-22 Nov 2026), schedule the baseline tests (spread across 2-3 days, not all at once: e.g. push-ups + sit-ups one day, 2.4km another).
- CRITICAL — IGNORE WALKS: walking activities (walking/indoor_walking/casual_walking/speed_walking) are logged for a company project, NOT training. Exclude them from everything. If Garmin load looks inflated by walking, note briefly and lean on running + strength signals.
- Count Garmin strength_training/hiit/cardio activities as strength sessions. Reps are not on the watch, so ask him to log max-rep tests (python3 log_ippt.py ...) rather than guessing numbers.

Read garmin/coach_data.json, context.json and ippt_log.json in the current directory.
Also read garmin/coach_note.md for your PREVIOUS advice — session consistency only:
- If the previous note planned a session for today that is not yet done, keep it.
- If today was planned as rest, keep it as rest unless he already trained.
- You MUST write a FRESH note with TODAY's date ($TODAY_INFO) and updated numbers. NEVER copy dates from the previous note.

From coach_data.json use the LATEST numbers: performance (ACWR, acwr_status, training_status, vo2max_precise, heat_acclimation_pct); last 7 days of wellness (training_readiness, body_battery, resting HR, stress, sleep, HRV); recent running + strength activities.

SESSION MENU (pick per phase and weakest station; give sets x reps / distances / rest / RPE or HR cap, and a one-line physiological purpose):
- IPPT strength-endurance: push-up and sit-up ladders, density blocks, GTG sets. Pull weekly max-rep re-test only when fresh.
- Interval run: warm-up 1-2km, 6-8 x 400m or 4-5 x 800m at goal 2.4km pace, jog recovery, cool-down. Singapore heat adjusts pace.
- Tempo / steady: 20-30 min comfortably hard (HR 155-165) with warm-up and cool-down.
- Easy aerobic run: 4-6km, HR <= 135 bpm.
- Snowboard legs (gym or bodyweight): squat pattern, split squats, wall sits, hip thrusts, step-downs, calf raises; 3 sets, moderate load, controlled eccentrics. Not within 5 days of the official attempt or the trip.
- Core + balance: planks/side planks/Pallof, single-leg balance work.
- Mobility: hips, ankles, thoracic spine, wrists.
- Weekly shape: ~2 IPPT strength days, 1 interval run, 1 easy/steady run, 1 snowboard-legs session, 1 core/mobility, at least 1 full rest day.

Write the note to garmin/coach_note.md with EXACTLY this structure:

**[Bold headline: one sentence on where he stands today vs Gold]**

**What your data says**
2-3 sentences. Days to IPPT deadline and trip. Latest logged IPPT numbers by station and which station is the limiter (or: no baseline yet, here is the test plan). ACWR (from TODAY's performance data), strength sessions and run km over the last 7/28 days, and notable wellness signals (HRV trend, sleep, readiness).

**Today's session**
Specific work: exercises, sets x reps, distances, rest, HR cap or RPE. One line on the physiological purpose. If rest day, explain why recovery matters.

**3-Day Plan**
- Today ($TODAY_INFO): session
- Tomorrow: session
- Day after: session

**Snowboard Prep**
Include ONLY if today is before 19 Feb 2027 AND no heavy-leg restriction applies (not in the last 5 days before the official attempt or the trip). 2-3 bullets: this week's snowboarding-specific work (legs/glutes/core/balance/mobility), which day to do each, kept compatible with IPPT work and recovery. In the last 5 days before the attempt or trip, replace this with light mobility + balance only. Omit entirely after 19 Feb.

**Fuel**
First line: calories burned (from FUEL DATA) and today's intake target to MAINTAIN weight and fuel training (never a deficit; maintenance or small surplus, ~90-110g protein, protein-forward on lifting days). Then a full-day Singaporean meal breakdown as bullets \"- Meal: dish — ~kcal\" (Breakfast, Lunch, Snack, Dinner, Evening), ending \"Total ≈ X kcal\". Scale to training load. Close with ONE relatable single-dish equivalent for the training burn. Hawker reference kcal: chicken rice 600, char kway teow 740, nasi lemak 490, laksa 700, wanton mee 410, bak chor mee 500, economy rice 1-meat-2-veg 600, kaya toast set 450, roti prata 2pc+curry 400, Milo dinosaur 350, kopi 115, banana 105, yogurt 150, soy milk 100.

**Coach's take**
One motivating sentence grounded in what the data shows is possible.

FUEL DATA (use for the Fuel section): $FUEL_INFO

Under 380 words. Write ONLY the markdown to garmin/coach_note.md. No commentary, no explanation — just the note content.
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
/bin/bash "$REPO/git_safe_push.sh" "coach: $(date '+%Y-%m-%d %H:%M')" garmin/coach_note.md docs/index.html garmin/data.json context.json
