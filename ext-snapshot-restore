#!/bin/bash
source /etc/admin-openrc.sh

# Get the list of project names
projects=($(openstack project list -c Name -f value))

# Display the numbered list
echo "Select a project by number:"
for i in "${!projects[@]}"; do
    echo "$((i+1)). ${projects[i]}"
done

# Read user input
read -p "Enter the number: " choice

# Validate input
if [[ $choice -ge 1 && $choice -le ${#projects[@]} ]]; then
    project_name=(${projects[$((choice-1))]})
    echo "You selected: ${projects[$((choice-1))]}"
else
    echo "Invalid choice. Exiting."
    exit 1
fi
## - End of Project -

# Get the list of servers (Name and ID)
mapfile -t servers < <(openstack server list --project="$project_name" --long -c Name -c ID -f value)

# Check if there are any servers
if [ ${#servers[@]} -eq 0 ]; then
    echo "No servers found for project $project_name."
    exit 1
fi

# Display the numbered list
echo "Select a server by number:"
for i in "${!servers[@]}"; do
    selected_server_id=$(echo "${servers[i]}" | awk '{print $1}')     # Extract server ID
    server_name=$(echo "${servers[i]}" | awk '{$1=""; print $0}' | sed 's/^ *//') # Extract server name
    echo "$((i+1)). $server_name ($selected_server_id)"
done

# Read user input
read -p "Enter the number: " choice

# Validate input
if [[ $choice -ge 1 && $choice -le ${#servers[@]} ]]; then
    selected_server="${servers[$((choice-1))]}"
    selected_server_id=$(echo "$selected_server" | awk '{print $1}')  # Extract server ID
    server_name=$(echo "$selected_server" | awk '{$1=""; print $0}' | sed 's/^ *//') # Extract server name
    echo "You selected: $server_name ($selected_server_id)"
else
    echo "Invalid choice. Exiting."
    exit 1
fi
## - End of Server -

volumes_json=$(openstack server show "$selected_server_id" -c attached_volumes -f json)

# Extract volume IDs
mapfile -t volume_ids < <(echo "$volumes_json" | jq -r '.attached_volumes[].id')

# Check if there are any attached volumes
if [ ${#volume_ids[@]} -eq 0 ]; then
    echo "No attached volumes found for server $selected_server_id."
    exit 1
fi

# Get details of each attached volume
volume_info=()
for volume_id in "${volume_ids[@]}"; do
    volume_json=$(openstack volume show "$volume_id" -c attachments -f json)
    device=$(echo "$volume_json" | jq -r '.attachments[0].device')

    # Store volume info (ID and device)
    volume_info+=("$volume_id $device")
done

# Display numbered list
echo "Select a volume by number:"
for i in "${!volume_info[@]}"; do
    volume_id=$(echo "${volume_info[i]}" | awk '{print $1}')
    device=$(echo "${volume_info[i]}" | awk '{print $2}')
    echo "$((i+1)). $volume_id (Device: $device)"
done

# Get user input
read -p "Enter the number: " choice

# Validate input
if [[ $choice -ge 1 && $choice -le ${#volume_info[@]} ]]; then
    selected_volume_id=$(echo "${volume_info[$((choice-1))]}" | awk '{print $1}')
    echo "You selected volume: $selected_volume_id"
else
    echo "Invalid choice. Exiting."
    exit 1
fi

## - End of Volume -

# Get all snapshots for the project "bigstack"
snapshots_json=$(openstack volume snapshot list --project="$project_name" --long -f json)

# Extract snapshots related to the selected volume
mapfile -t snapshot_info < <(echo "$snapshots_json" | jq -c --arg vol "$selected_volume_id" \
    '.[] | select(.Volume == $vol) | {name: .Name, id: .ID, created_at: .["Created At"]}')

# Check if there are any snapshots
if [ ${#snapshot_info[@]} -eq 0 ]; then
    echo "No snapshots found for volume: $selected_volume_id"
    exit 1
fi

# Convert "Created At" to human-readable format and display options
echo "Select a snapshot by number:"
for i in "${!snapshot_info[@]}"; do
    name=$(echo "${snapshot_info[i]}" | jq -r '.name')        # Extract snapshot name
    id=$(echo "${snapshot_info[i]}" | jq -r '.id')            # Extract snapshot ID
    created_at=$(echo "${snapshot_info[i]}" | jq -r '.created_at')  # Extract Created At

    # Convert to human-readable format
    human_date=$(date -d "$created_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    # If date conversion fails, set a fallback
    if [[ -z "$human_date" ]]; then
        human_date="Invalid Date"
    fi

    echo "$((i+1)). $name - Created: $human_date"
done

# Get user selection
read -p "Enter the number: " choice

# Validate input
if [[ $choice -ge 1 && $choice -le ${#snapshot_info[@]} ]]; then
    selected_snapshot_id=$(echo "${snapshot_info[$((choice-1))]}" | jq -r '.id')  # Extract snapshot ID
    echo "You selected snapshot: $selected_snapshot_id"
else
    echo "Invalid choice. Exiting."
    exit 1
fi

## - End of Snapshot -

# Ask for final confirmation
echo ""
echo "WARNING: This operation will revert the volume ($selected_volume_id) to the selected snapshot ($selected_snapshot_id)."
echo "The associated server will be SHUTDOWN, and all current disk data will be LOST."
echo ""
read -p "Type 'YES' to confirm: " confirmation

# Check if the user entered exactly "YES"
if [[ "$confirmation" != "YES" ]]; then
    echo "Operation canceled. No changes were made."
    exit 1
fi

# Proceed with the revert operation, ensure the server is SHUTOFF before proceeding
echo "Stopping the server ($selected_server_id)..."
openstack server stop "$selected_server_id"

# Wait until the server is fully stopped
echo "Waiting for server ($selected_server_id) to shut down..."
while true; do
    vm_state=$(openstack server show "$selected_server_id" -c vm_state -f value)
    if [[ "$vm_state" == "stopped" ]]; then
        echo "✅ Server is now stopped."
        break
    fi
    echo "⏳ Server is still stopping... checking again in 5 seconds."
    sleep 5
done

echo "Reverting volume $selected_volume_id to snapshot $selected_snapshot_id..."
rbd snap rollback cinder-volumes/volume-"$selected_volume_id"@snapshot-"$selected_snapshot_id"

echo "Revert operation completed successfully."

echo "Starting the server ($selected_server_id)..."
openstack server start "$selected_server_id"

echo "Server started successfully."

