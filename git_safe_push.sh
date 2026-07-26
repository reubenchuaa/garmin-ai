#!/bin/bash
# Reliable git commit + push with locking, conflict resolution, and retries.
# Usage: git_safe_push.sh "commit message" [files to add...]
#
# CRITICAL INVARIANT: This script NEVER leaves conflict markers in files.
# Every git operation that can produce conflicts is followed by a check.

set -euo pipefail

REPO_DIR="/Users/amandakoh/garmin-ai"
LOCKFILE="$REPO_DIR/.git/garmin-sync.lock"
COMMIT_MSG="${1:-sync: $(date '+%Y-%m-%d %H:%M')}"
shift || true
FILES_TO_ADD=("$@")

cd "$REPO_DIR"

# --- Check for and remove conflict markers ---
has_conflict_markers() {
    grep -rql '<<<<<<< ' --include='*.json' --include='*.html' --include='*.md' . 2>/dev/null
}

resolve_conflict_markers() {
    if has_conflict_markers; then
        echo "  [git] CONFLICT MARKERS DETECTED — auto-resolving"
        grep -rl '<<<<<<< ' --include='*.json' --include='*.html' --include='*.md' . 2>/dev/null | while read -r f; do
            python3 -c "
import re
text = open('$f').read()
text = re.sub(r'<<<<<<< [^\n]*\n(.*?)\n=======\n.*?\n>>>>>>> [^\n]*', lambda m: m.group(1), text, flags=re.DOTALL)
open('$f', 'w').write(text)
" 2>/dev/null && echo "  [git] Resolved conflicts in $f" || true
        done
    fi
}

# --- Acquire exclusive lock (wait up to 5 min, then steal it) ---
acquire_lock() {
    local waited=0
    while [ -f "$LOCKFILE" ]; do
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
    resolve_conflict_markers
}

# --- Safe pull: stash, pull, pop ---
safe_pull() {
    local has_changes=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
        git stash --quiet --include-untracked 2>/dev/null || true
    fi

    if ! git pull --rebase --quiet 2>/dev/null; then
        echo "  [git] Rebase conflict, aborting rebase"
        git rebase --abort 2>/dev/null || true
        if ! git pull --quiet 2>/dev/null; then
            echo "  [git] Merge pull has conflicts, auto-resolving"
            local conflicted
            conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
            echo "$conflicted" | while read -r f; do
                [ -z "$f" ] && continue
                git checkout --ours "$f" 2>/dev/null || true
                git add "$f" 2>/dev/null || true
            done
            # The dashboard is a build artifact — never text-merge it. If it
            # conflicted, regenerate it fresh from the merged data + newest note.
            if echo "$conflicted" | grep -q "docs/index.html"; then
                if python3 generate_dashboard.py >/dev/null 2>&1; then
                    git add docs/index.html 2>/dev/null || true
                    echo "  [git] Regenerated dashboard after conflict"
                fi
            fi
            git commit --no-edit 2>/dev/null || true
        fi
    fi

    resolve_conflict_markers

    if [ "$has_changes" = true ]; then
        if ! git stash pop --quiet 2>/dev/null; then
            echo "  [git] Stash pop conflict — resolving"
            resolve_conflict_markers
            git add -A 2>/dev/null || true
            git stash drop --quiet 2>/dev/null || true
        fi
    fi

    resolve_conflict_markers
}

# --- Push whenever local is ahead of upstream (with pull-retry) ---
# CRITICAL: this must run even when there is nothing NEW to commit, because a
# merge commit created by safe_pull leaves us ahead of origin and MUST be pushed.
# The old code returned early on "nothing to commit" and never pushed the merge,
# causing the branch to drift ahead/behind and freeze the live dashboard.
push_if_ahead() {
    local attempt=0
    while [ $attempt -lt 4 ]; do
        # Integrate any new remote work first so we can fast-forward-push.
        if [ "$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)" -gt 0 ]; then
            safe_pull
        fi
        if [ "$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" -eq 0 ]; then
            echo "  [git] In sync with origin, nothing to push"
            return 0
        fi
        if git push --quiet 2>/dev/null; then
            echo "  [git] Push successful"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [git] Push failed (attempt $attempt/4), reconciling and retrying..."
        safe_pull
    done
    echo "  [git] Push failed after retries — branch left ahead of origin"
    return 1
}

# --- Commit and push with retry ---
commit_and_push() {
    if [ ${#FILES_TO_ADD[@]} -gt 0 ]; then
        git add "${FILES_TO_ADD[@]}" 2>/dev/null || true
    fi

    if git diff --cached --quiet 2>/dev/null; then
        echo "  [git] Nothing new to commit"
    else
        git commit -m "$COMMIT_MSG" 2>/dev/null || echo "  [git] Commit failed"
    fi

    # ALWAYS reconcile + push if we're ahead — covers merge commits from safe_pull.
    push_if_ahead
}

# --- Main ---
acquire_lock
cleanup_rebase
safe_pull

if [ "$COMMIT_MSG" = "__pull_only__" ]; then
    exit 0
fi

commit_and_push
