#!/bin/bash

# Script to run backfill every 6 hours
# Calculates the time window dynamically based on current time

echo "Starting periodic backfill service (every 6 hours)"
echo "========================================="

while true; do
    # Calculate the time window for the last 6 hours
    END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    START_TIME=$(date -u -d "6 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-6H +"%Y-%m-%dT%H:%M:%SZ")

    echo ""
    echo "$(date): Starting backfill"
    echo "Period: $START_TIME to $END_TIME"
    echo "----------------------------------------"

    # Run the indexer backfill
    /usr/local/bin/indexer backfill \
        --start "$START_TIME" \
        --end "$END_TIME"

    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo "$(date): Backfill completed successfully"
    else
        echo "$(date): Backfill failed with exit code $EXIT_CODE"
        echo "Will retry in 6 hours..."
    fi

    echo "$(date): Sleeping for 6 hours until next run..."
    sleep 21600  # 6 hours in seconds
done