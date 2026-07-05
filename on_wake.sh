#!/bin/bash
# Watches for Mac wake events and triggers sync + coach.
# Runs as a persistent background launchd agent (KeepAlive).
# Waits 10s after wake for network, then runs coach (which includes data sync).
# Kills stale processes and skips if coach is already running.

REPO="/Users/amandakoh/garmin-ai"
LOCKFILE="$REPO/.git/garmin-sync.lock"

# Kill any stale sync/coach processes older than 15 minutes
kill_stale() {
    local pids
    pids=$(pgrep -f "update_coach\.sh|sync\.py" 2>/dev/null)
    for pid in $pids; do
        # Don't kill ourselves
        [ "$pid" = "$$" ] && continue
        local age=$(ps -o etime= -p "$pid" 2>/dev/null | awk -F: '{if(NF==3){print $1*3600+$2*60+$3}else if(NF==2){print $1*60+$2}else{print $1}}')
        if [ -n "$age" ] && [ "$age" -gt 900 ]; then
            echo "$(date): Killing stale process $pid (${age}s old)"
            kill "$pid" 2>/dev/null
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    # Remove stale lock
    if [ -f "$LOCKFILE" ]; then
        local lock_age=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -gt 900 ]; then
            echo "$(date): Removing stale lock (${lock_age}s old)"
            rm -f "$LOCKFILE"
        fi
    fi
}

while true; do
    log stream --predicate 'eventMessage contains "Wake reason"' --style compact 2>/dev/null | while read -r line; do
        echo "$(date): Wake detected"

        # Kill any stale processes from before sleep
        kill_stale

        # Skip if another sync/coach is currently running (and not stale)
        if [ -f "$LOCKFILE" ]; then
            lock_age=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -lt 900 ]; then
                echo "$(date): Skipping — another sync is running (lock ${lock_age}s old)"
                sleep 300
                continue
            fi
        fi

        # Wait for network
        sleep 10

        echo "$(date): Triggering sync + coach"
        /bin/bash "$REPO/update_coach.sh" >> "$REPO/coach.log" 2>&1

        # Cooldown — don't trigger again for 10 minutes
        sleep 600
    done

    # If log stream exits unexpectedly, restart after a pause
    sleep 5
done
