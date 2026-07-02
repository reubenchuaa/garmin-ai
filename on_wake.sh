#!/bin/bash
# Watches for Mac wake events and triggers sync + coach
# Runs as a background launchd agent

while true; do
    # Wait for a wake event from system log
    log stream --predicate 'eventMessage contains "Wake reason"' --style compact 2>/dev/null | while read -r line; do
        echo "$(date): Wake detected, triggering sync + coach" >> /Users/amandakoh/garmin-ai/wake.log

        # Wait a few seconds for network to come up
        sleep 10

        # Run sync first, then coach (sequential to avoid git conflicts)
        /bin/bash /Users/amandakoh/garmin-ai/sync_and_push.sh >> /Users/amandakoh/garmin-ai/sync.log 2>&1
        /bin/bash /Users/amandakoh/garmin-ai/update_coach.sh >> /Users/amandakoh/garmin-ai/coach.log 2>&1

        # Only trigger once per wake — wait 5 min before listening again
        sleep 300
    done

    # If log stream exits, restart after a pause
    sleep 5
done
