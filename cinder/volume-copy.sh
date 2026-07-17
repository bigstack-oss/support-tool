#!/bin/bash

# Configuration
DEST_IP="10.76.1.31"
DEST_PATH="/mnt/cephfs/glance/data"
VOL_ID=$1

# Check if Volume ID is provided
if [[ -z "$VOL_ID" ]]; then
    echo "Usage: $0 <volume_id>"
    exit 1
fi

echo "--- Starting Process for Volume: $VOL_ID ---"

# 1. Check Volume Status
# We use -f value -c status to get just the raw string (e.g., 'available')
STATUS=$(openstack volume show "$VOL_ID" -f value -c status)

if [[ "$STATUS" != "available" ]]; then
    echo "Error: Volume $VOL_ID is in '$STATUS' state. Must be 'available'."
    exit 1
fi

# 2. Export Metadata to JSON and SCP
echo "Exporting metadata..."
JSON_FILE="volume-$VOL_ID.json"
openstack volume show "$VOL_ID" -f json > "$JSON_FILE"

scp "$JSON_FILE" root@"$DEST_IP":"$DEST_PATH/"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to scp metadata."
    exit 1
fi

# 3. Stream Export via RBD to Remote SSH
echo "--- Exporting Volume Data: $VOL_ID ---"

rbd --id cinder -p cinder-volumes export "volume-$VOL_ID" - | \
ssh root@"$DEST_IP" "cat > '$DEST_PATH/volume-$VOL_ID.raw'"

# Capture PIPESTATUS to check both rbd and ssh success
RBD_EXIT=${PIPESTATUS[0]}
SSH_EXIT=${PIPESTATUS[1]}

if [[ $RBD_EXIT -eq 0 && $SSH_EXIT -eq 0 ]]; then
    echo "Successfully transferred: volume-$VOL_ID.raw"
    # Optional: Clean up local json file
    rm "$JSON_FILE"
else
    echo "Error: Volume transfer failed. RBD Exit: $RBD_EXIT, SSH Exit: $SSH_EXIT"
    exit 1
fi