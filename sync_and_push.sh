#!/bin/bash
# Pulls latest Garmin data, regenerates dashboard, pushes to GitHub.
# Runs every 30 min via launchd — no Claude needed.
# Uses git_safe_push.sh for reliable git operations with locking and retries.

REPO="/Users/amandakoh/garmin-ai"
PYTHON="/Users/amandakoh/opt/anaconda3/bin/python3"

cd "$REPO"

# --- Pull latest ---
/bin/bash "$REPO/git_safe_push.sh" "__pull_only__" 2>/dev/null || true

# --- Sync last 3 days of Garmin data ---
$PYTHON sync.py 3

# --- Regenerate dashboard ---
$PYTHON generate_dashboard.py 2>/dev/null

# --- Commit and push (with locking, conflict resolution, retries) ---
/bin/bash "$REPO/git_safe_push.sh" "sync: $(date '+%Y-%m-%d %H:%M')" garmin/ docs/

# --- Update GitHub secret with fresh tokens ---
$PYTHON update_github_token.py 2>/dev/null || true
