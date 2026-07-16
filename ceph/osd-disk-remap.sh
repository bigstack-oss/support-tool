#!/bin/bash

# Get the global cluster FSID
CLUSTER_FSID=$(ceph fsid)

# 1. Dynamically find all OSD IDs that are currently "down" from ceph osd df
DOWN_OSDS=$(ceph osd df | grep -w "down" | awk '{print $1}')

if [ -z "$DOWN_OSDS" ]; then
    echo "No down OSDs found! The cluster is healthy."
    exit 0
fi

# 2. Loop through each down OSD ID
for ID in $DOWN_OSDS; do
    echo "=== Processing OSD.${ID} ==="
    
    OSD_DIR="/var/lib/ceph/osd/ceph-${ID}"

    # 3. Extract correct OSD FSID and PARTUUID from dev_osd.map
    OSD_FSID=$(grep -w "/dev/sd.* ${ID}" /var/lib/ceph/osd/dev_osd.map | awk '{print $3}')
    PARTUUID=$(grep -w "/dev/sd.* ${ID}" /var/lib/ceph/osd/dev_osd.map | awk '{print $4}')
    
    CURRENT_OSD_FSID=$(ceph-osd -i ${ID} --get-osd-fsid --osd-data ${OSD_DIR})

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
    fi
done

# Show the final status
echo "=== Final OSD Status in 20 seconds (ceph osd df) ==="
sleep 20
ceph osd df