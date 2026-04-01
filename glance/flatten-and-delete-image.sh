#!/bin/bash

IMAGE_ID=$1
POOL_NAME="cinder-volumes"

if [ -z "$IMAGE_ID" ]; then
    echo "Usage: $0 <GLANCE-ID>"
    exit 1
fi

# Added filter for status and deleted flag
VOL_QUERY="
SELECT v.id 
FROM cinder.volumes v
JOIN cinder.volume_glance_metadata m ON v.id = m.volume_id 
WHERE m.value = '$IMAGE_ID' 
  AND v.status != 'deleted' 
  AND v.deleted = 0;"

VOLUMES=$(mysql -N -s -e "$VOL_QUERY")

if [ -z "$VOLUMES" ]; then
    echo "No active dependent volumes found."
else
    echo "### Step: Analyzing Volume Attachments and Parentage..."
    echo "------------------------------------------------------------------------------------------------------------"
    printf "%-38s | %-10s | %-38s | %-15s\n" "Volume ID" "Device" "Server ID" "Server Name"
    echo "------------------------------------------------------------------------------------------------------------"
    
    NEEDS_FLATTEN=()

    for vol_id in $VOLUMES; do
        # Get attachment JSON
        ATTACH_JSON=$(openstack volume show "$vol_id" -c attachments -f json 2>/dev/null)
        
        if [ $? -ne 0 ]; then
             printf "%-38s | %-10s | %-38s | %-15s\n" "$vol_id" "ERR" "ERR" "NotFound"
             continue
        fi

        SERVER_ID=$(echo "$ATTACH_JSON" | jq -r '.attachments[0].server_id // "N/A"')
        DEVICE=$(echo "$ATTACH_JSON" | jq -r '.attachments[0].device // "N/A"')
        
        if [ "$SERVER_ID" != "N/A" ] && [ "$SERVER_ID" != "null" ]; then
            SERVER_NAME=$(openstack server show "$SERVER_ID" -c name -f value 2>/dev/null || echo "Unknown")
        else
            SERVER_NAME="Unattached"
        fi
        
        printf "%-38s | %-10s | %-38s | %-15s\n" "$vol_id" "$DEVICE" "$SERVER_ID" "$SERVER_NAME"

        # Check if Ceph considers this volume a child
        HAS_PARENT=$(rbd info "${POOL_NAME}/volume-${vol_id}" 2>/dev/null | grep "parent:")
        
        if [ ! -z "$HAS_PARENT" ]; then
            NEEDS_FLATTEN+=("$vol_id")
        fi
    done

    echo "------------------------------------------------------------------------------------------------------------"

    if [ ${#NEEDS_FLATTEN[@]} -eq 0 ]; then
        echo "No volumes require flattening."
    else
        echo "Found ${#NEEDS_FLATTEN[@]} volume(s) requiring flattening."
        read -p "Start flattening? Type 'YES': " CONFIRM_FLATTEN
        if [ "$CONFIRM_FLATTEN" == "YES" ]; then
            for vol_id in "${NEEDS_FLATTEN[@]}"; do
                echo "Flattening ${POOL_NAME}/volume-${vol_id}..."
                rbd flatten "${POOL_NAME}/volume-${vol_id}"
            done
        fi
    fi
fi

echo ""
echo "### Step: Deleting Glance Image..."
read -p "Type 'YES' to delete image $IMAGE_ID: " CONFIRM_DELETE
if [ "$CONFIRM_DELETE" == "YES" ]; then
    openstack image set --unprotected "$IMAGE_ID" 2>/dev/null
    openstack image delete "$IMAGE_ID"
fi