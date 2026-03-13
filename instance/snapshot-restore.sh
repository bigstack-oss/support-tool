#!/bin/bash
set -o errexit
set -o pipefail
set -o nounset

source /etc/admin-openrc.sh

# -----------------------------
# Helper functions
# -----------------------------
prompt_choice() {
    local max="$1"
    local prompt="${2:-Enter the number: }"
    local choice

    while true; do
        read -r -p "$prompt" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max )); then
            echo "$choice"
            return 0
        fi
        echo "Invalid choice. Please enter a number between 1 and $max."
    done
}

confirm_yes() {
    local prompt="${1:-Type 'YES' to confirm: }"
    local input
    read -r -p "$prompt" input
    [[ "$input" == "YES" ]]
}

is_selected_volume() {
    local vol_id="$1"
    shift || true

    local selected
    for selected in "$@"; do
        if [[ "$selected" == "$vol_id" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------
# Step 0: list regions & select
# -----------------------------
echo "Select Region:"
regions_json="$(openstack region list -c Region -f json)"

region_count="$(echo "$regions_json" | jq 'length')"
if (( region_count == 0 )); then
    echo "No regions returned by OpenStack."
    exit 1
fi

mapfile -t region_names < <(echo "$regions_json" | jq -r '.[].Region')

if (( region_count == 1 )); then
    region_name="${region_names[0]}"
    echo "Only one region found."
else
    i=1
    for rn in "${region_names[@]}"; do
        printf "%2d. %s\n" "$i" "$rn"
        ((i++))
    done
    while :; do
        read -r -p "Enter region number: " ridx
        if [[ "$ridx" =~ ^[0-9]+$ ]] && (( ridx >= 1 && ridx <= ${#region_names[@]} )); then
            region_name="${region_names[$((ridx-1))]}"
            break
        fi
        echo "Invalid selection."
    done
fi

export OS_REGION_NAME="$region_name"
echo "Using region: $OS_REGION_NAME"

# -----------------------------
# Step 1: list domains & select
# -----------------------------
echo
echo "Select Domain:"
domains_json="$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')"

dom_count="$(echo "$domains_json" | jq 'length')"
if (( dom_count == 0 )); then
    echo "No selectable domains found."
    exit 1
fi

mapfile -t domain_lines < <(echo "$domains_json" | jq -r '.[] | "\(.ID)|\(.Name)"')

if (( dom_count == 1 )); then
    IFS='|' read -r domain_id domain_name <<< "${domain_lines[0]}"
    echo "Only one domain found."
else
    i=1
    for line in "${domain_lines[@]}"; do
        IFS='|' read -r dom_id dom_name <<< "$line"
        printf "%2d. %s (%s)\n" "$i" "$dom_name" "$dom_id"
        ((i++))
    done
    while :; do
        read -r -p "Enter domain number: " dom_idx
        if [[ "$dom_idx" =~ ^[0-9]+$ ]] && (( dom_idx >= 1 && dom_idx <= ${#domain_lines[@]} )); then
            IFS='|' read -r domain_id domain_name <<< "${domain_lines[$((dom_idx-1))]}"
            break
        fi
        echo "Invalid selection."
    done
fi
echo "Using domain: $domain_name ($domain_id)"

# -----------------------------
# Step 2: list projects & select
# -----------------------------
echo
echo "Select Project in domain '$domain_name':"
projects_json="$(openstack project list --domain "$domain_id" -f json)"
projects_json="$(echo "$projects_json" | jq '[.[] | select(.Name != "admin" and .Name != "_diagnostics" and .Name != "service")]')"

project_count="$(echo "$projects_json" | jq 'length')"
if (( project_count == 0 )); then
    echo "No selectable projects found in domain '$domain_name'."
    exit 1
fi

mapfile -t project_lines < <(echo "$projects_json" | jq -r '.[] | "\(.ID)|\(.Name)"')

if (( project_count == 1 )); then
    IFS='|' read -r project_id project_name <<< "${project_lines[0]}"
    echo "Only one project found."
else
    i=1
    for line in "${project_lines[@]}"; do
        IFS='|' read -r proj_id proj_name <<< "$line"
        printf "%2d. %s (%s)\n" "$i" "$proj_name" "$proj_id"
        ((i++))
    done
    choice="$(prompt_choice "${#project_lines[@]}" "Enter project number: ")"
    IFS='|' read -r project_id project_name <<< "${project_lines[$((choice-1))]}"
fi

echo "Using project: $project_name ($project_id)"

# -----------------------------
# Select server
# -----------------------------
echo
servers_json="$(openstack server list --project "$project_id" --long -f json)"

server_count="$(echo "$servers_json" | jq 'length')"
if (( server_count == 0 )); then
    echo "No servers found for project $project_name ($project_id)."
    exit 1
fi

mapfile -t server_lines < <(
    echo "$servers_json" | jq -r '.[] | "\(.ID)|\(.Name)"'
)

echo "Select a server by number:"
for i in "${!server_lines[@]}"; do
    IFS='|' read -r server_id server_name <<< "${server_lines[i]}"
    echo "$((i+1)). $server_name ($server_id)"
done

choice="$(prompt_choice "${#server_lines[@]}")"
IFS='|' read -r selected_server_id server_name <<< "${server_lines[$((choice-1))]}"

echo "You selected: $server_name ($selected_server_id)"

# -----------------------------
# Get attached volumes
# -----------------------------
volumes_json="$(openstack server show "$selected_server_id" -c attached_volumes -f json)"
mapfile -t volume_ids < <(echo "$volumes_json" | jq -r '.attached_volumes[].id')

if [[ ${#volume_ids[@]} -eq 0 ]]; then
    echo "No attached volumes found for server $selected_server_id."
    exit 1
fi

volume_info=()
for volume_id in "${volume_ids[@]}"; do
    volume_json="$(openstack volume show "$volume_id" -f json)"

    device="$(echo "$volume_json" | jq -r '.attachments[0].device // "unknown"')"
    volume_name="$(echo "$volume_json" | jq -r '.name // empty')"

    if [[ -z "$volume_name" || "$volume_name" == "null" ]]; then
        volume_name="unnamed"
    fi

    volume_info+=("$volume_id|$device|$volume_name")
done

# Optional: sort so root disk-like devices appear first
mapfile -t volume_info < <(
    printf '%s\n' "${volume_info[@]}" | awk -F'|' '
        $2 == "/dev/vda" || $2 == "/dev/sda" {print "0|" $0; next}
        {print "1|" $0}
    ' | sort | cut -d'|' -f2-
)

# -----------------------------
# Load snapshot list once
# -----------------------------
snapshots_json="$(openstack volume snapshot list --project "$project_id" --long -f json 2>/dev/null)" || {
    echo "Failed to retrieve snapshot list."
    exit 1
}

if [[ -z "$snapshots_json" ]]; then
    echo "Failed to retrieve snapshot list."
    exit 1
fi

# -----------------------------
# Select volume -> snapshot -> ask next
# -----------------------------
declare -a selected_volumes
declare -a restore_pairs

while true; do
    echo
    echo "Select a volume by number:"

    remaining_indexes=()
    remaining_count=0

    for i in "${!volume_info[@]}"; do
        IFS='|' read -r volume_id device volume_name <<< "${volume_info[i]}"

        if ! is_selected_volume "$volume_id" "${selected_volumes[@]:-}"; then
            remaining_indexes+=("$i")
            remaining_count=$((remaining_count + 1))
            echo "$remaining_count. $volume_id (Device: $device, Name: $volume_name)"
        fi
    done

    if (( remaining_count == 0 )); then
        echo "No more unselected volumes available."
        break
    fi

    choice="$(prompt_choice "$remaining_count")"
    actual_index="${remaining_indexes[$((choice-1))]}"

    IFS='|' read -r selected_volume_id selected_device selected_volume_name <<< "${volume_info[$actual_index]}"

    selected_volumes+=("$selected_volume_id")
    echo "You selected volume: $selected_volume_id (Device: $selected_device, Name: $selected_volume_name)"

    echo
    echo "--------------------------------------------------"
    echo "Checking snapshots for volume: $selected_volume_id"

    mapfile -t snapshot_info < <(
        echo "$snapshots_json" | jq -c --arg vol "$selected_volume_id" \
        '.[] | select(.Volume == $vol) | {name: .Name, id: .ID, created_at: .["Created At"]}'
    )

    if [[ ${#snapshot_info[@]} -eq 0 ]]; then
        echo "There were no snapshots found for volume $selected_volume_id."
        echo "Skipping restore for this volume."
    else
        echo "Select a snapshot by number:"
        for i in "${!snapshot_info[@]}"; do
            name="$(echo "${snapshot_info[i]}" | jq -r '.name')"
            id="$(echo "${snapshot_info[i]}" | jq -r '.id')"
            created_at="$(echo "${snapshot_info[i]}" | jq -r '.created_at')"

            human_date="$(date -d "$created_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
            [[ -n "$human_date" ]] || human_date="Invalid Date"

            echo "$((i+1)). $name ($id) - Created: $human_date"
        done

        snap_choice="$(prompt_choice "${#snapshot_info[@]}")"
        selected_snapshot_id="$(echo "${snapshot_info[$((snap_choice-1))]}" | jq -r '.id')"

        echo "You selected snapshot: $selected_snapshot_id"
        restore_pairs+=("$selected_volume_id|$selected_snapshot_id|$selected_device|$selected_volume_name")
    fi

    unselected_left=0
    for i in "${!volume_info[@]}"; do
        IFS='|' read -r volume_id _device _volume_name <<< "${volume_info[i]}"
        if ! is_selected_volume "$volume_id" "${selected_volumes[@]}"; then
            unselected_left=1
            break
        fi
    done

    if (( unselected_left == 0 )); then
        echo "All attached volumes have been checked."
        break
    fi

    echo
    read -r -p 'Do you want to restore another? type "YES" to restore other, Enter for skip: ' more_restore

    if [[ -z "$more_restore" ]]; then
        echo "Skip selecting additional volumes."
        break
    fi

    if [[ "$more_restore" != "YES" ]]; then
        echo 'Invalid input. Treating as skip.'
        break
    fi
done

if [[ ${#restore_pairs[@]} -eq 0 ]]; then
    echo
    echo "No snapshots available for any selected volumes."
    echo "Nothing to restore. Exiting."
    exit 1
fi

# -----------------------------
# Final confirmation
# -----------------------------
echo
echo "WARNING: This operation will revert the following volume(s):"
for pair in "${restore_pairs[@]}"; do
    IFS='|' read -r volume_id snapshot_id device volume_name <<< "$pair"
    echo "  - Volume: $volume_id (Device: $device, Name: $volume_name) --> Snapshot: $snapshot_id"
done
echo
echo "The associated server will be SHUTDOWN, and all current disk data on the selected volume(s) will be LOST."
echo

if ! confirm_yes "Type 'YES' to confirm: "; then
    echo "Operation canceled. No changes were made."
    exit 1
fi

# -----------------------------
# Stop server
# -----------------------------
echo "Stopping the server ($selected_server_id)..."
openstack server stop "$selected_server_id"

echo "Waiting for server ($selected_server_id) to shut down..."
while true; do
    vm_state="$(openstack server show "$selected_server_id" -c vm_state -f value)"
    if [[ "$vm_state" == "stopped" ]]; then
        echo "✅ Server is now stopped."
        break
    fi
    echo "⏳ Server is still stopping... checking again in 5 seconds."
    sleep 5
done

# -----------------------------
# Restore selected volumes
# -----------------------------
for pair in "${restore_pairs[@]}"; do
    IFS='|' read -r volume_id snapshot_id device volume_name <<< "$pair"

    echo "Reverting volume $volume_id (Device: $device, Name: $volume_name) to snapshot $snapshot_id..."
    rbd snap rollback "cinder-volumes/volume-$volume_id@snapshot-$snapshot_id"
    echo "✅ Reverted volume $volume_id successfully."
done

echo "All selected volume restore operations completed successfully."

# -----------------------------
# Ask whether to start server
# -----------------------------
echo
read -r -p "Do you want to start the server ($selected_server_id)? Type 'YES' to confirm, Enter for skip: " start_confirm

if [[ "$start_confirm" == "YES" ]]; then
    echo "Starting the server ($selected_server_id)..."
    openstack server start "$selected_server_id"
    echo "✅ Server started successfully."
else
    echo "Server start skipped. The server remains SHUTOFF."
fi