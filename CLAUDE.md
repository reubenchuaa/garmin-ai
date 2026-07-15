# Garmin AI Coach — Project Reference

## What this is
Automated running coach for Reuben (reubenchuahl@gmail.com). Syncs Garmin data, generates a science-backed daily coach note via Claude CLI, pushes workouts to Garmin watch, and publishes a dashboard to GitHub Pages.

## Athlete
- **Goal:** Sub 1:50 (chase 1:45) · Kiprun Singapore Half Marathon · 27 Sep 2026
- **VO2max:** ~55.8 (top 5% for age/gender)
- **Current HM prediction:** ~2:01 (needs ~11–16 min improvement)
- **Base:** ~47 resting HR, Singapore-based (heat affects all paces)
- **Health notes:** Post-illness recovery (Jun 2026), mild knee niggle (watch for recurrence)

## Key files
| File | Purpose |
|------|---------|
| `sync.py` | Fetches Garmin data (activities, wellness, performance) → `garmin/data.json` |
| `update_coach.sh` | Main pipeline: sync → trim data → detect activities → run Claude → validate note → push to git |
| `push_workout.py` | Parses coach note 3-day plan → pushes workouts to Garmin watch calendar |
| `generate_dashboard.py` | Builds `docs/index.html` (GitHub Pages dashboard) from `garmin/data.json` |
| `git_safe_push.sh` | Safe git push with locking, conflict resolution, retries |
| `sync_and_push.sh` | Lightweight sync + dashboard only (no Claude) |
| `on_wake.sh` | Runs on Mac wake via LaunchAgent |
| `context.json` | Athlete profile, training phases, Norway hike details, HR zones — coach reads this every run |
| `garmin/data.json` | Master data store (87+ activities, 191+ wellness entries) |
| `garmin/data.json.bak` | Auto-backup — self-restoration if data.json gets wiped |
| `garmin/coach_note.md` | Current coach note (regenerated every 30 min when Mac is awake) |
| `garmin/coach_data.json` | Trimmed 60-day version of data.json fed to Claude (large: ~523KB) |
| `garmin/.last_workout_push` | JSON list of pushed workouts `[{date, name, workoutId, scheduleId}]` |

## Automation
- **LaunchAgent `com.garmin.coach`** — runs `update_coach.sh` every 30 min when Mac is awake
- **LaunchAgent `com.garmin.sync`** — runs `sync_and_push.sh` every 30 min
- **LaunchAgent `com.garmin.wake`** — runs `on_wake.sh` on Mac wake
- **GitHub Actions** (`.github/workflows/garmin-sync.yml`) — syncs data 7x/day from cloud even when Mac is off; does NOT run Claude (no CLI auth in CI)

## Auth & credentials
- **Garmin credentials:** macOS Keychain (`garmin-ai` service, `email` + `password` accounts)
- **Claude CLI auth:** OAuth via `claude /login` — tokens in `~/.claude.json` + Keychain (`Claude Code-credentials`). Access token ~8h, refresh token ~28 days. Script warns via macOS notification 3 days before refresh token expires.
- **GitHub token:** In git remote URL (see `git_safe_push.sh`)

## Self-healing systems
1. **Data wipe protection:** `sync.py` refuses to write if >10% activity/wellness loss. `load_existing_data()` auto-restores from `data.json.bak` if data looks wiped (<10 activities/wellness).
2. **Coach note staleness detection:** `update_coach.sh` validates that the generated note contains today's full date in the 3-Day Plan. If stale, retries Claude once with a stricter prompt. If Claude not logged in, exits without re-stamping old note.
3. **Git conflicts:** `git_safe_push.sh` handles locking, stale locks, conflict resolution with retries.

## Training phases (from context.json)
| Phase | Dates | Focus |
|-------|-------|-------|
| Rebuild Base | Jul 5–18 | Long run up to 10–11km |
| Build + Hike Prep | Jul 19–Aug 1 | Tempo, stairs w/ pack |
| Taper | Aug 2–7 | Ease off before Norway |
| Norway Hiking | Aug 8–22 | 9 hikes, 83km, 6,059m elevation |
| Shake Out | Aug 23–29 | 2 easy runs, reintegrate |
| Peak Block | Aug 30–Sep 19 | Intervals, long runs 16–17km |
| Race Taper | Sep 20–26 | Easy + rest |
| **RACE DAY** | **Sep 27** | **Kiprun Singapore HM 🏁** |

## Norway (Aug 8–22) — key facts
9 hard hikes, all rated Hard. Hardest stretch: Aug 10 double-hike (1,155m gain) + Aug 11 (1,002m gain) back to back. Treat as high-volume aerobic cross-training. Columbia OutDry shoes need 50–80km break-in before Aug 8.

## Coaching philosophy (what the coach prompt uses)
Polarised training (Seiler 80/20), ACWR safe zone 0.8–1.3 (Gabbett 2016), Daniels VDOT paces, Maffetone HR-capped easy runs (≤135 bpm in Singapore heat), supercompensation, Mujika & Padilla tapering. Easy pace ~7:00–7:30/km. Tempo 6:00–6:15/km HR 155–165.

## Common tasks
- **Manually refresh coach note:** `cd /Users/amandakoh/garmin-ai && bash update_coach.sh`
- **Check coach note:** `cat garmin/coach_note.md`
- **Check data health:** `python3 -c "import json; d=json.load(open('garmin/data.json')); print(len(d['activities']), 'activities,', len(d['wellness']), 'wellness')"`
- **Re-login Claude:** `claude /login` (run in terminal, required every ~28 days)
- **View dashboard:** https://reubenchuaa.github.io/garmin-ai/
