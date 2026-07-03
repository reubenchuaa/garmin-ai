#!/bin/bash
# Watches for Mac wake events and triggers sync + coach.
# Runs as a persistent background launchd agent (KeepAlive).
# Waits 10s after wake for network, then runs coach (which includes data sync).
# Skips if coach is already running (lock file check).

REPO="/Users/amandakoh/garmin-ai"
LOCKFILE="$REPO/.git/garmin-sync.lock"

while true; do
    log stream --predicate 'eventMessage contains "Wake reason"' --style compact 2>/dev/null | while read -r line; do
        echo "$(date): Wake detected"

        # Skip if another sync/coach is already running
        if [ -f "$LOCKFILE" ]; then
            lock_age=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -lt 600 ]; then
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
