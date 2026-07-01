#!/bin/bash
# Pulls latest Garmin data, regenerates dashboard, pushes to GitHub
# Runs hourly 7am-12am via launchd — no Claude needed

cd /Users/amandakoh/garmin-ai

# Pull latest from GitHub first
git pull --quiet

# Sync last 3 days of Garmin data
/usr/bin/python3 sync.py 3

# Regenerate dashboard with fresh data
python3 generate_dashboard.py 2>/dev/null

# Push if anything changed
git add garmin/ docs/
git diff --cached --quiet || git commit -m "sync: $(date '+%Y-%m-%d %H:%M')"
git push --quiet
