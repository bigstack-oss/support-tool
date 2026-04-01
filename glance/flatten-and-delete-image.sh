#!/bin/bash

IMAGE_ID=$1

if [ -z "$IMAGE_ID" ]; then
    echo "Usage: $0 <GLANCE-ID>"
    exit 1
fi

echo "### Step 1: Querying dependent volumes via MySQL..."
VOLUMES=$(mysql -N -s -e \
"SELECT volumes.id FROM cinder.volumes JOIN cinder.volume_glance_metadata ON volumes.id = cinder.volume_glance_metadata.volume_id WHERE cinder.volume_glance_metadata.value = '$IMAGE_ID';")

if [ -z "$VOLUMES" ]; then
    echo "No dependent volumes found."
else
    echo "### Step 2: Analyzing Volume Attachments..."
    echo "volume_id, device, server_id, server_name"
    echo "----------------------------------------"
    
    for vol_id in $VOLUMES; do
        # Get attachment JSON
        ATTACH_JSON=$(openstack volume show "$vol_id" -c attachments -f json)
        
        # Check if volume is attached
        SERVER_ID=$(echo "$ATTACH_JSON" | jq -r '.attachments[0].server_id // "N/A"')
        DEVICE=$(echo "$ATTACH_JSON" | jq -r '.attachments[0].device // "N/A"')
        
        if [ "$SERVER_ID" != "N/A" ]; then
            SERVER_NAME=$(openstack server show "$SERVER_ID" -c name -f value 2>/dev/null || echo "Unknown")
        else
            SERVER_NAME="Unattached"
        fi
        
        echo "$vol_id, $DEVICE, $SERVER_ID, $SERVER_NAME"
    done

    echo ""
    read -p "Start flattening all volumes? Type 'YES' to confirm: " CONFIRM_FLATTEN
    if [ "$CONFIRM_FLATTEN" == "YES" ]; then
        for vol_id in $VOLUMES; do
            echo "Flattening volume: $vol_id ..."
            rbd flatten cinder-volumes/volume-"$vol_id"
        done
        echo "Flattening complete."
    else
        echo "Flattening aborted."
        exit 1
    fi
fi

echo "### Step 3: Deleting Image..."
read -p "Ready to delete image $IMAGE_ID? Type 'YES' to confirm: " CONFIRM_DELETE
if [ "$CONFIRM_DELETE" == "YES" ]; then
    # Unset protected flag if it exists
    openstack image set --unprotected "$IMAGE_ID"
    openstack image delete "$IMAGE_ID"
    echo "Image $IMAGE_ID deleted successfully."
else
    echo "Deletion aborted."
fi