#!/bin/bash

# Configuration
source /etc/admin-openrc.sh
DEST_IP="10.76.1.31"
DEST_PATH="/mnt/cephfs/glance/data"
SERVER_ID=$1

if [ -z "$SERVER_ID" ]; then
    echo "Usage: $0 <SERVER_ID>"
    exit 1
fi

# 1. Fetch Server Details
SERVER_JSON=$(openstack server show "$SERVER_ID" -f json)
SERVER_NAME=$(echo "$SERVER_JSON" | jq -r '.name' | tr ' ' '_')
IMAGE_VAL=$(echo "$SERVER_JSON" | jq -r '.image')
STATUS=$(echo "$SERVER_JSON" | jq -r '.status')

echo "--- Starting Process for Server: $SERVER_NAME ---"

# 2. Power Status Check
if [[ "$STATUS" == "ACTIVE" ]]; then
    echo "The Server is currently running, do you want poweroff to continue? type \"YES\" to proceed"
    read -r USER_RESPONSE
    
    if [[ "$USER_RESPONSE" == "YES" ]]; then
        echo "Stopping server $SERVER_ID..."
        openstack server stop "$SERVER_ID"
        
        # Poll status until SHUTOFF
        while true; do
            CURRENT_STATUS=$(openstack server show "$SERVER_ID" -c status -f value)
            if [[ "$CURRENT_STATUS" == "SHUTOFF" ]]; then
                echo "Server is now SHUTOFF. Proceeding..."
                break
            fi
            echo "Waiting for server to power off (Current: $CURRENT_STATUS)..."
            sleep 5
        done
    else
        echo "Aborting. Server must be powered off for a consistent export."
        exit 0
    fi
fi

# 3. Process Attached Volumes
VOL_IDS=$(echo "$SERVER_JSON" | jq -r '.volumes_attached[]?.id // empty')

if [ -z "$VOL_IDS" ]; then
    echo "No attached volumes found."
else
    for VOL_ID in $VOL_IDS; do
        VOL_JSON=$(openstack volume show "$VOL_ID" -f json)
        VOL_NAME=$(echo "$VOL_JSON" | jq -r '.name')
        VOL_SIZE=$(echo "$VOL_JSON" | jq -r '.size')
        
        DEVICE_PATH=$(echo "$VOL_JSON" | jq -r --arg SID "$SERVER_ID" '.attachments[] | select(.server_id == $SID) | .device')
        DEVICE_NAME=$(basename "$DEVICE_PATH")
        
        [ -z "$DEVICE_NAME" ] && DEVICE_NAME="vol-$VOL_ID"
        FINAL_FILENAME="${SERVER_NAME}-${VOL_NAME}-${VOL_SIZE}GB-${DEVICE_NAME}.raw"

        echo "--- Exporting Volume: $VOL_ID ($DEVICE_NAME) ---"
        
        rbd --id cinder -p cinder-volumes export "volume-$VOL_ID" - | \
        ssh root@"$DEST_IP" "cat > '$DEST_PATH/$FINAL_FILENAME'"

        if [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]]; then
            echo "Successfully transferred: $FINAL_FILENAME"
        else
            echo "Error: Volume transfer failed."
        fi
    done
fi

echo "--- All tasks for $SERVER_NAME complete ---"