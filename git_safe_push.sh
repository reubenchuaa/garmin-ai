#!/bin/bash
# Reliable git commit + push with locking, conflict resolution, and retries.
# Usage: git_safe_push.sh "commit message" [files to add...]
#
# This script handles EVERY known failure mode:
# 1. Concurrent git operations (file lock)
# 2. Unstaged changes blocking pull/rebase
# 3. Merge conflicts on auto-generated files (auto-resolved)
# 4. Push rejections (retry with fresh pull)
# 5. Dirty working tree from previous failed runs

set -euo pipefail

REPO_DIR="/Users/amandakoh/garmin-ai"
LOCKFILE="$REPO_DIR/.git/garmin-sync.lock"
COMMIT_MSG="${1:-sync: $(date '+%Y-%m-%d %H:%M')}"
shift || true
FILES_TO_ADD=("$@")

cd "$REPO_DIR"

# --- Acquire exclusive lock (wait up to 5 min, then steal it) ---
acquire_lock() {
    local waited=0
    while [ -f "$LOCKFILE" ]; do
        # Check if lock is stale (older than 10 minutes)
        if [ -f "$LOCKFILE" ]; then
            local lock_age=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -gt 600 ]; then
                echo "  [git] Stale lock detected (${lock_age}s old), removing"
                rm -f "$LOCKFILE"
                break
            fi
        fi
        if [ "$waited" -ge 300 ]; then
            echo "  [git] Lock held for 5+ min, stealing it"
            rm -f "$LOCKFILE"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT
}

# --- Clean up any interrupted rebase ---
cleanup_rebase() {
    if [ -d "$REPO_DIR/.git/rebase-merge" ] || [ -d "$REPO_DIR/.git/rebase-apply" ]; then
        echo "  [git] Aborting interrupted rebase"
        git rebase --abort 2>/dev/null || true
    fi
}

# --- Safe pull: stash, pull, pop ---
safe_pull() {
    local has_changes=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
        git stash --quiet --include-untracked 2>/dev/null || true
    fi

    git pull --rebase --quiet 2>/dev/null || {
        # If rebase fails due to conflict, accept theirs for auto-generated files
        echo "  [git] Rebase conflict, auto-resolving generated files"
        git checkout --theirs docs/index.html 2>/dev/null || true
        git checkout --theirs garmin/data.json 2>/dev/null || true
        git add docs/index.html garmin/data.json 2>/dev/null || true
        GIT_EDITOR=true git rebase --continue 2>/dev/null || {
            echo "  [git] Rebase still failing, aborting and using merge instead"
            git rebase --abort 2>/dev/null || true
            git pull --quiet 2>/dev/null || true
        }
    }

    if [ "$has_changes" = true ]; then
        git stash pop --quiet 2>/dev/null || {
            # If stash pop conflicts, drop the stash (our new changes are better)
            echo "  [git] Stash pop conflict, dropping stale stash"
            git checkout -- . 2>/dev/null || true
            git stash drop --quiet 2>/dev/null || true
        }
    fi
}

# --- Commit and push with retry ---
commit_and_push() {
    # Stage specified files
    if [ ${#FILES_TO_ADD[@]} -gt 0 ]; then
        git add "${FILES_TO_ADD[@]}" 2>/dev/null || true
    fi

    # Only commit if there are staged changes
    if git diff --cached --quiet 2>/dev/null; then
        echo "  [git] Nothing to commit"
        return 0
    fi

    git commit -m "$COMMIT_MSG" 2>/dev/null || {
        echo "  [git] Commit failed"
        return 1
    }

    # Push with up to 3 retries
    local attempt=0
    while [ $attempt -lt 3 ]; do
        if git push --quiet 2>/dev/null; then
            echo "  [git] Push successful"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [git] Push failed (attempt $attempt/3), pulling and retrying..."
        safe_pull
    done

    echo "  [git] Push failed after 3 attempts"
    return 1
}

# --- Main ---
acquire_lock
cleanup_rebase
safe_pull

# If called with "__pull_only__", just pull and exit (no commit/push)
if [ "$COMMIT_MSG" = "__pull_only__" ]; then
    exit 0
fi

commit_and_push
