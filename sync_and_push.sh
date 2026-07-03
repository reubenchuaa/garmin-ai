#!/bin/bash
# Pulls latest Garmin data, regenerates dashboard, pushes to GitHub
# Runs hourly 7am-12am via launchd — no Claude needed

cd /Users/amandakoh/garmin-ai

# Pull latest from GitHub first
git pull --quiet

# Sync last 3 days of Garmin data
/Users/amandakoh/opt/anaconda3/bin/python3 sync.py 3

# Regenerate dashboard with fresh data
/Users/amandakoh/opt/anaconda3/bin/python3 generate_dashboard.py 2>/dev/null

# Push if anything changed
git add garmin/ docs/
git diff --cached --quiet || git commit -m "sync: $(date '+%Y-%m-%d %H:%M')"
git stash --quiet 2>/dev/null
git pull --rebase --quiet 2>/dev/null || true
git stash pop --quiet 2>/dev/null || true
git push --quiet

# Update GitHub secret with fresh tokens so Actions runs don't get 429'd
/Users/amandakoh/opt/anaconda3/bin/python3 update_github_token.py 2>/dev/null
