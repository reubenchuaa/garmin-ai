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

TODAY IS: $TODAY_INFO
The 3-Day Plan MUST start from TODAY. Use today's actual date and weekday. Do NOT copy dates from the previous note.

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
- You MUST write a FRESH note with TODAY's date and updated numbers from coach_data.json. NEVER return the previous note unchanged.

From coach_data.json, extract and use the LATEST numbers:
- performance[most recent date]: ACWR, acwr_status, training_status, race_pred_hm, vo2max_precise, heat_acclimation_pct
- Last 7 days of wellness: training_readiness, body_battery, resting HR, stress, sleep, HRV
- Recent activities: distance, pace, avg HR, cadence, training load
- July mileage total so far vs 100km target

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
