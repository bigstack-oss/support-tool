#!/bin/bash

VOLUME_ID=$1
POOL_NAME="cinder-volumes"

if [ -z "$VOLUME_ID" ]; then
    echo "Usage: $0 <VOLUME-ID>"
    exit 1
fi

# Check if volume exists first
VOL_CHECK=$(openstack volume show "$VOLUME_ID" -c id -f value 2>/dev/null)
if [ -z "$VOL_CHECK" ]; then
    echo "Error: Volume $VOLUME_ID not found."
    exit 1
fi

echo "### Step 1: Checking for Snapshots on Volume $VOLUME_ID..."
SNAPSHOTS=$(openstack volume snapshot list --volume "$VOLUME_ID" -f value -c ID)

if [ -z "$SNAPSHOTS" ]; then
    echo "No snapshots found for this volume."
else
    echo "Found the following snapshots that MUST be deleted first:"
    for snap in $SNAPSHOTS; do
        SNAP_NAME=$(openstack volume snapshot show "$snap" -f value -c name)
        echo "  - ID: $snap | Name: $SNAP_NAME"
    done

    echo ""
    read -p "Flatten dependencies and delete these snapshots? Type 'YES' to confirm: " CONFIRM_SNAP
    if [ "$CONFIRM_SNAP" != "YES" ]; then
        echo "Snapshot cleanup aborted. Cannot proceed with volume deletion."
        exit 1
    fi

    ### Step 2: Flattening and Deleting Snapshots
    for snap_id in $SNAPSHOTS; do
        echo "------------------------------------------------"
        echo "Processing Snapshot: $snap_id"
        
        # Ceph naming convention for cinder snapshots
        CEPH_SNAP_NAME="volume-${VOLUME_ID}@snapshot-${snap_id}"
        
        # Check for children (cloned volumes)
        CHILDREN=$(rbd children "${POOL_NAME}/${CEPH_SNAP_NAME}" 2>/dev/null)
        
        if [ ! -z "$CHILDREN" ]; then
            echo "Snapshot has children. Flattening now..."
            for child in $CHILDREN; do
                echo "Flattening: $child ..."
                rbd flatten "$child"
            done
        fi

        echo "Deleting snapshot $snap_id from OpenStack..."
        openstack volume snapshot delete "$snap_id"
        
        # Wait for the snapshot to actually be removed
        echo -n "Waiting for deletion."
        while openstack volume snapshot show "$snap_id" &>/dev/null; do
            echo -n "."
            sleep 2
        done
        echo " Done."
    done
fi

### Step 3: Final Volume Deletion Confirmation
echo "------------------------------------------------"
echo "All snapshot dependencies cleared."
echo "Target Volume ID: $VOLUME_ID"
echo "Target Volume Name: $(openstack volume show "$VOLUME_ID" -c name -f value)"

read -p "Are you sure you want to PERMANENTLY DELETE this volume? Type 'YES' to confirm: " CONFIRM_VOL

if [ "$CONFIRM_VOL" == "YES" ]; then
    echo "Deleting volume $VOLUME_ID..."
    if openstack volume delete "$VOLUME_ID"; then
        echo "SUCCESS: Volume deleted."
    else
        echo "ERROR: Failed to delete volume. It might be attached or in an invalid state."
    fi
else
    echo "Volume deletion cancelled."
fi