#!/bin/bash

# --- Configuration ---
LOG_FILE="/var/log/support-snapshot-clean.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# --- Functions ---

# Function to log messages with a timestamp
log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# --- Main Script ---

log "--- Starting OpenStack Stuck Snapshot Cleanup ---"

# Use set -e to exit immediately if a command exits with a non-zero status.
# However, we will disable it locally inside the loop to handle expected failures.
set -e

# Find and log initial list of stuck snapshots
log "Identifying snapshots currently in 'deleting' state..."
STUCK_SNAPSHOTS=$(
    openstack volume snapshot list --all-project -f json | \
    jq -r '.[] | select(.Status == "deleting") | .ID'
)

if [ -z "$STUCK_SNAPSHOTS" ]; then
    log "No snapshots found in 'deleting' state. Exiting gracefully."
    log "--- Cleanup Finished ---"
    exit 0
fi

log "Found the following stuck snapshot IDs:"
echo "$STUCK_SNAPSHOTS" | tee -a "$LOG_FILE"
log "---------------------------------------------"

# Disable 'set -e' for the loop to continue processing all IDs even if one command fails
set +e

echo "$STUCK_SNAPSHOTS" | while read SNAPSHOT_ID; do
    log "Processing snapshot ID: $SNAPSHOT_ID"

    # 1. Force state to available (This command might fail, so we capture the status)
    log "  -> Attempting to set state to 'available'..."
    openstack volume snapshot set --state available "$SNAPSHOT_ID" 2>&1 | tee -a "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        log "  -> State successfully set to 'available'."
    else
        # Log error but continue to next step (sometimes a direct delete works after a failed set)
        log "  -> WARNING: Failed to force state to 'available' for $SNAPSHOT_ID. Attempting immediate delete."
    fi

    # 2. Attempt final delete
    log "  -> Attempting final delete of the snapshot..."
    openstack volume snapshot delete "$SNAPSHOT_ID" 2>&1 | tee -a "$LOG_FILE"

    if [ $? -eq 0 ]; then
        log "  -> **SUCCESS**: Snapshot $SNAPSHOT_ID successfully deleted."
    else
        log "  -> **FAILURE**: Failed to delete snapshot $SNAPSHOT_ID. It may require manual intervention."
    fi
    log "---------------------------------------------"
done

# Re-enable 'set -e' (optional, but good practice if the script continues)
set -e

# Final check for remaining stuck snapshots
log "Final check: Listing any remaining snapshots in 'deleting' state..."
openstack volume snapshot list --all-project -f json | \
jq -r '.[] | select(.Status == "deleting") | .ID' | \
tee -a "$LOG_FILE"

log "--- OpenStack Stuck Snapshot Cleanup Script Complete ---"