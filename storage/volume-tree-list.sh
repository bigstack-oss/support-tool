#!/bin/bash

# Check if the main volume argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <main_volume>"
    exit 1
fi

# Source the OpenStack environment
source /etc/admin-openrc.sh

# Function to recursively list snapshots and children volumes
list_snapshots_and_children() {
    local volume=$1
    local indent=$2

    # List snapshots of the current volume
    snapshots=$(rbd snap ls cinder-volumes/$volume | awk 'NR>1 {print $2}')

    for snapshot in $snapshots; do
        # Get children volumes of the current snapshot
        children=$(rbd children cinder-volumes/$volume@$snapshot)
        children_count=$(echo "$children" | grep -v '^$' | wc -l)  # Count non-empty lines
        snapshot_id="${snapshot#snapshot-}"
        snapshot_name=$(openstack volume snapshot show $snapshot_id -c name -f value 2>/dev/null)
        echo "${indent}└── $snapshot ($children_count volume), snapshot name: $snapshot_name"

        for child in $children; do
            volume_id_with_prefix=$(echo $child | awk -F '/' '{print $2}')
            volume_id=$(echo $volume_id_with_prefix | sed 's/^volume-//')
            status=$(openstack volume show $volume_id -c status -f value 2>/dev/null)

            if [ -z "$status" ]; then
                echo "${indent}    └── $volume_id_with_prefix (Volume does not exist)"
                continue
            fi

            echo "${indent}    └── $volume_id_with_prefix ($status)"

            # If the volume is in use, get server details
            if [ "$status" == "in-use" ]; then
                volume_details=$(openstack volume show $volume_id -f json)
                server_id=$(echo $volume_details | jq -r '.attachments[0].server_id')
                server_details=$(openstack server show $server_id -f json)
                hostname=$(echo "$server_details" | jq -r '.hostname')
                project_id=$(echo "$server_details" | jq -r '.project_id')
                project_name=$(openstack project show $project_id -c name -f value)
                echo "${indent}        └── server_id: $server_id($hostname), project_id: $project_id($project_name)"
            fi

            # Recursively list snapshots and children for the child volume
            list_snapshots_and_children $volume_id_with_prefix "${indent}        "
        done
    done
}

# Main volume to start the tree
vid=$1
main_volume=volume-$vid
status=$(openstack volume show $vid -c status -f value 2>/dev/null)

if [ "$status" == "in-use" ]; then
    volume_details=$(openstack volume show $vid -f json)
    server_id=$(echo $volume_details | jq -r '.attachments[0].server_id')
    echo "$main_volume ($status) - server_id: $server_id"
else
    echo "$main_volume ($status)"
fi
# Output the main volume

# Start the recursive listing
list_snapshots_and_children $main_volume ""