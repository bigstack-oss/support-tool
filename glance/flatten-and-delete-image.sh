#!/bin/bash

IMAGES_POOL="glance-images"

if [ -z "$1" ]; then
    echo "Usage: $0 <GLANCE-ID-OR-NAME>"
    exit 1
fi

# Resolve name or ID to the actual UUID - RBD images are keyed by UUID, not name
IMAGE_ID=$(openstack image show "$1" -c id -f value 2>/dev/null)
if [ -z "$IMAGE_ID" ]; then
    echo "Could not resolve image '$1' to an ID."
    exit 1
fi

# Added filter for status and deleted flag
VOL_QUERY="
SELECT v.id 
FROM cinder.volumes v
JOIN cinder.volume_glance_metadata m ON v.id = m.volume_id
WHERE m.key = 'image_id'
  AND m.value = '$IMAGE_ID'
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

        # Determine the Ceph pool for this volume from its host attribute
        VOL_HOST=$(openstack volume show "$vol_id" -c os-vol-host-attr:host -f value 2>/dev/null)
        if [ "$VOL_HOST" == "cube@ceph#ceph" ]; then
            POOL_NAME="cinder-volumes"
        else
            POOL_NAME="${VOL_HOST#*#}"
        fi

        # Check if Ceph considers this volume a child
        HAS_PARENT=$(rbd info "${POOL_NAME}/volume-${vol_id}" 2>/dev/null | grep "parent:")

        if [ ! -z "$HAS_PARENT" ]; then
            NEEDS_FLATTEN+=("${vol_id}|${POOL_NAME}")
        fi
    done

    echo "------------------------------------------------------------------------------------------------------------"

    if [ ${#NEEDS_FLATTEN[@]} -eq 0 ]; then
        echo "No volumes require flattening."
    else
        echo "Found ${#NEEDS_FLATTEN[@]} volume(s) requiring flattening."
        read -p "Start flattening? Type 'YES': " CONFIRM_FLATTEN
        if [ "$CONFIRM_FLATTEN" == "YES" ]; then
            for entry in "${NEEDS_FLATTEN[@]}"; do
                vol_id="${entry%|*}"
                pool="${entry#*|}"
                echo "Flattening ${pool}/volume-${vol_id}..."
                rbd flatten "${pool}/volume-${vol_id}"
            done
        fi
    fi
fi

echo ""
echo "### Step: Checking Ceph directly for clones of the Glance image (this is the actual backend-store check)..."

SNAPS=$(rbd -p "$IMAGES_POOL" snap ls "$IMAGE_ID" 2>/dev/null | awk 'NR>1 {print $2}')

if [ -z "$SNAPS" ]; then
    echo "No snapshots found for ${IMAGES_POOL}/${IMAGE_ID} (image may live in a different pool, or has no snapshot)."
else
    IMG_NEEDS_FLATTEN=()
    for snap in $SNAPS; do
        while IFS= read -r child; do
            [ -z "$child" ] && continue
            IMG_NEEDS_FLATTEN+=("$child")
        done < <(rbd -p "$IMAGES_POOL" children "${IMAGE_ID}@${snap}" 2>/dev/null)
    done

    if [ ${#IMG_NEEDS_FLATTEN[@]} -eq 0 ]; then
        echo "No Ceph-level clones found."
    else
        echo "Found ${#IMG_NEEDS_FLATTEN[@]} clone(s) directly referencing this image in Ceph:"
        printf '  %s\n' "${IMG_NEEDS_FLATTEN[@]}"
        read -p "Start flattening these? Type 'YES': " CONFIRM_IMG_FLATTEN
        if [ "$CONFIRM_IMG_FLATTEN" == "YES" ]; then
            for child in "${IMG_NEEDS_FLATTEN[@]}"; do
                echo "Flattening ${child}..."
                rbd flatten "$child"
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