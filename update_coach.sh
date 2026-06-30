#!/bin/bash
# Runs on Mac wake/login — pulls latest Garmin data and updates coach note via Claude

cd /Users/amandakoh/Desktop/garmin-ai

# Pull latest data from GitHub
git pull --quiet

# Run Claude to reason about the data and write coach_note.md
/opt/homebrew/bin/claude --dangerously-skip-permissions -p "
You are a running coach for Reuben. Read the file garmin/data.json and context.json in the current directory.

Based on the last 7 days of Garmin data and his training context, write a coach note to garmin/coach_note.md.

The note should include:
1. A one-line headline (bold) assessing today's readiness
2. What the numbers say (use actual values)
3. What to do TODAY specifically — session type, distance, pace, HR cap
4. Adapt based on missed runs, recovery trends, or anything notable
5. A 3-day plan (Today, Tomorrow, Day after) with specific sessions
6. One forward-looking note about the week or phase

Be direct, specific, and personal. Under 250 words. Write in second person.
Write ONLY the markdown content to garmin/coach_note.md — nothing else.
" 2>/dev/null

# Push the updated coach note back to GitHub
git add garmin/coach_note.md
git diff --cached --quiet || git commit -m "coach: $(date '+%Y-%m-%d %H:%M')"
git push --quiet
