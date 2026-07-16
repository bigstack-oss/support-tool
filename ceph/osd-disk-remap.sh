#!/bin/bash

# Get the global cluster FSID
CLUSTER_FSID=$(ceph fsid)

# Get the current machine's hostname
CURRENT_HOST=$(hostname)

# 1. Dynamically find all OSD IDs that are currently "down" from ceph osd df
DOWN_OSDS=$(ceph osd df | grep -w "down" | awk '{print $1}')

if [ -z "$DOWN_OSDS" ]; then
    echo "No down OSDs found! The cluster is healthy."
    exit 0
fi

# 2. Loop through each down OSD ID
for ID in $DOWN_OSDS; do
    echo "=== Checking OSD.${ID} ==="
    
    # Get the hostname where this OSD is supposed to run
    OSD_HOST=$(ceph osd metadata "$ID" | jq -r '.hostname')

    # Check if the metadata query returned a blank hostname
    if [ -z "$OSD_HOST" ] || [ "$OSD_HOST" == "null" ]; then
        echo "Warning: Could not determine hostname for OSD.${ID} from metadata. Skipping host validation."
    # If the OSD hostname does not match the current host, skip it
    elif [ "$OSD_HOST" != "$CURRENT_HOST" ]; then
        echo "This OSD is not on this host. Please run the script on hostname = $OSD_HOST"
        echo "------------------------------------"
        continue
    fi

    OSD_DIR="/var/lib/ceph/osd/ceph-${ID}"

    # 3. Extract correct OSD FSID and PARTUUID from dev_osd.map
    OSD_FSID=$(grep -w "/dev/sd.* ${ID}" /var/lib/ceph/osd/dev_osd.map | awk '{print $3}')
    PARTUUID=$(grep -w "/dev/sd.* ${ID}" /var/lib/ceph/osd/dev_osd.map | awk '{print $4}')
    
    if [ -z "$OSD_FSID" ] || [ -z "$PARTUUID" ]; then
        echo "Error: Could not find mapping for OSD.${ID} in dev_osd.map"
        continue
    fi

    CURRENT_OSD_FSID=$(ceph-osd -i ${ID} --get-osd-fsid --osd-data ${OSD_DIR} 2>/dev/null)

    if [ "$OSD_FSID" != "$CURRENT_OSD_FSID" ]; then
        echo "Warning: OSD FSID mismatch for OSD.${ID}. Expected: $OSD_FSID, Found: $CURRENT_OSD_FSID"
        TARGET_PATH="/dev/disk/by-partuuid/$PARTUUID"
        CURRENT_LINK=$(readlink "$OSD_DIR/block")
        
        if [ "$CURRENT_LINK" == "$TARGET_PATH" ]; then
            echo "bluestore" > "$OSD_DIR/type"
            echo "$ID" > "$OSD_DIR/whoami"
            echo "$OSD_FSID" > "$OSD_DIR/fsid"
            echo "$CLUSTER_FSID" > "$OSD_DIR/ceph_fsid"
            echo "ready" > "$OSD_DIR/ready"
            
            chown -R ceph:ceph "$OSD_DIR"
            systemctl restart "ceph-osd@$ID"
            
            echo "OSD.${ID} has been successfully activated and brought online."
            echo "------------------------------------"
        else
            echo "Error: The 'block' symlink for OSD.${ID} does not point to the expected PARTUUID. Please check the device mapping."
            continue
        fi
    else
        echo "OSD FSID matches for OSD.${ID}. nothing to do."
        echo "------------------------------------"
    fi
done

# Show the final status
echo "=== Final OSD Status in 10 seconds (ceph osd df) ==="
sleep 10
ceph osd df