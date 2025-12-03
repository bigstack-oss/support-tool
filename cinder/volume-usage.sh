#!/bin/bash

# --- Configuration ---
LOG_FILE="/var/log/ceph/support-cinder-volumes-usage.log"
RBD_POOL="cinder-volumes"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# --- Functions ---

# Function to log messages with a timestamp
log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# --- Main Script ---

log "--- Starting Ceph Volume Usage Collection ---"

## 1. Collect Overall Ceph Cluster Usage (ceph df)
log "Collecting overall Ceph cluster disk usage ('ceph df')..."
echo "--- Overall Ceph DF Snapshot at $TIMESTAMP ---" >> "$LOG_FILE"
ceph df >> "$LOG_FILE"
echo "" >> "$LOG_FILE" # Add a newline for separation

## 2. Collect Individual RBD Volume Usage (rbd du)
log "Collecting individual RBD usage for pool '$RBD_POOL'..."

# Create a temporary file to store the rbd du output
TEMP_USAGE_FILE=$(mktemp)

# Loop through all RBD images in the specified pool
for i in $(rbd ls cinder-volumes); do
    rbd du cinder-volumes/$i >> "$LOG_FILE"
done

# Add a header for the individual volume usage data
echo "--- Individual RBD Volume Usage Snapshot at $TIMESTAMP ---" >> "$LOG_FILE"
echo -e "RBD_IMAGE\tSIZE\tUSED_SIZE\tMAX_AVAIL\t%USED" >> "$LOG_FILE"

# Append the collected data from the temporary file to the final log file
cat "$TEMP_USAGE_FILE" >> "$LOG_FILE"
echo "" >> "$LOG_FILE" # Add a newline for separation

# Clean up the temporary file
rm "$TEMP_USAGE_FILE"

log "--- Usage Collection Complete. Data appended to $LOG_FILE ---"