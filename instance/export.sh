#!/bin/bash
set -o errexit
set -o pipefail
set -o nounset

# Load credentials
if [[ -f /etc/admin-openrc.sh ]]; then
    source /etc/admin-openrc.sh
else
    echo "Error: /etc/admin-openrc.sh not found."; exit 1
fi

# --- Step 0: list regions & select ------------------------------------------
echo "--- Region Selection ---"
regions_json=$(openstack region list -c Region -f json)
region_count=$(echo "$regions_json" | jq 'length')

if (( region_count == 0 )); then
  echo "No regions returned by OpenStack."; exit 1
fi

mapfile -t region_names < <(echo "$regions_json" | jq -r '.[].Region')

if (( region_count == 1 )); then
  region_name="${region_names[0]}"
  echo "Only one region found: $region_name"
else
  i=1
  for rn in "${region_names[@]}"; do
    printf "%2d. %s\n" "$i" "$rn"
    ((i++))
  done
  while :; do
    read -rp "Enter region number: " ridx
    if [[ "$ridx" =~ ^[0-9]+$ ]] && (( ridx >= 1 && ridx <= ${#region_names[@]} )); then
      region_name="${region_names[$((ridx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi

export OS_REGION_NAME="$region_name"

# --- Step 1: list domains (exclude 'heat') ----------------------------------
echo -e "\n--- Domain Selection ---"
domains_json=$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')
dom_count=$(echo "$domains_json" | jq 'length')

if (( dom_count == 0 )); then
  echo "No selectable domains found."; exit 1
fi

mapfile -t domain_lines < <(echo "$domains_json" | jq -r '.[] | "\(.ID)|\(.Name)"')

if (( dom_count == 1 )); then
  IFS='|' read -r domain_id domain_name <<< "${domain_lines[0]}"
  echo "Only one domain found: $domain_name"
else
  i=1
  for line in "${domain_lines[@]}"; do
    IFS='|' read -r d_id d_name <<< "$line"
    printf "%2d. %s (%s)\n" "$i" "$d_name" "$d_id"
    ((i++))
  done
  while :; do
    read -rp "Enter domain number: " dom_idx
    if [[ "$dom_idx" =~ ^[0-9]+$ ]] && (( dom_idx >= 1 && dom_idx <= ${#domain_lines[@]} )); then
      IFS='|' read -r domain_id domain_name <<< "${domain_lines[$((dom_idx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi

# --- Step 2: list projects --------------------------------------------------
echo -e "\n--- Project Selection (Domain: $domain_name) ---"
projects_json=$(openstack project list --domain "$domain_id" -f json | jq '[.[] | select(.Name != "_diagnostics" and .Name != "service")]')
proj_count=$(echo "$projects_json" | jq 'length')

if (( proj_count == 0 )); then
  echo "No selectable projects found in domain '$domain_name'."; exit 1
fi

mapfile -t project_lines < <(echo "$projects_json" | jq -r '.[] | "\(.ID)|\(.Name)"')
for i in "${!project_lines[@]}"; do
  IFS='|' read -r p_id p_name <<< "${project_lines[i]}"
  printf "%2d. %s (%s)\n" "$((i+1))" "$p_name" "$p_id"
done

read -rp "Enter project number: " proj_idx
if ! [[ "$proj_idx" =~ ^[0-9]+$ ]] || (( proj_idx < 1 || proj_idx > ${#project_lines[@]} )); then
  echo "Invalid selection."; exit 1
fi
IFS='|' read -r project_id project_name <<< "${project_lines[$((proj_idx-1))]}"

# --- Step 3: Select Server --------------------------------------------------
echo -e "\n--- Server Selection (Project: $project_name) ---"
servers_json=$(openstack server list --project "$project_id" -f json)
server_count=$(echo "$servers_json" | jq 'length')

if (( server_count == 0 )); then
    echo "No servers found."; exit 1
fi

mapfile -t server_lines < <(echo "$servers_json" | jq -r '.[] | "\(.ID)|\(.Name)"')
for i in "${!server_lines[@]}"; do
    IFS='|' read -r s_id s_name <<< "${server_lines[i]}"
    printf "%2d. %s (%s)\n" "$((i+1))" "$s_name" "$s_id"
done

read -rp "Enter server number: " sidx
if ! [[ "$sidx" =~ ^[0-9]+$ ]] || (( sidx < 1 || sidx > ${#server_lines[@]} )); then
    echo "Invalid selection."; exit 1
fi
IFS='|' read -r selected_server_id selected_server_name <<< "${server_lines[$((sidx-1))]}"

# --- Step 4: Power Management ---
server_details=$(openstack server show "$selected_server_id" -f json)
status=$(echo "$server_details" | jq -r '.status')

if [[ "$status" == "ACTIVE" ]]; then
    echo -e "\n[WARNING] Server is currently ACTIVE."
    read -rp "Type YES to power off and continue: " confirm
    if [[ "$confirm" == "YES" ]]; then
        openstack server stop "$selected_server_id"
        while [[ "$(openstack server show "$selected_server_id" -c status -f value)" != "SHUTOFF" ]]; do
            echo "Waiting for SHUTOFF..." ; sleep 5
        done
    else
        echo "Aborting."; exit 0
    fi
fi

# --- Step 5: RBD Export & Conversion (UPDATED FOR ATTACHED_VOLUMES) ---
echo "Searching for attached volumes..."

# We check both 'volumes_attached' and 'attached_volumes' to cover all API versions
vol_ids=$(echo "$server_details" | jq -r '( .attached_volumes[]?.id, .volumes_attached[]?.id ) // empty' | sort -u)

if [[ -z "$vol_ids" ]]; then
    echo -e "\n[ERROR] No volumes found attached to this server."
    echo "Check JSON output: server might be using ephemeral local storage."
    exit 1
fi

echo "Found Volume IDs:"
echo "$vol_ids"

for vol_id in $vol_ids; do
    # Get volume details for device path mapping
    vol_info=$(openstack volume show "$vol_id" -f json)
    
    # Extract device (e.g. /dev/sda) specifically for this server
    device_full=$(echo "$vol_info" | jq -r ".attachments[] | select(.server_id == \"$selected_server_id\") | .device" | head -n 1)
    
    # Fallback if device name is null/empty
    if [[ -z "$device_full" || "$device_full" == "null" ]]; then
        device_short="disk-$(echo "$vol_id" | cut -c1-4)"
    else
        device_short=$(basename "$device_full") # /dev/sda -> sda
    fi

    rbd_img="volume-$vol_id"
    raw_file="/mnt/cephfs/glance/${selected_server_name}-${device_short}.raw"
    vmdk_file="/mnt/cephfs/glance/${selected_server_name}-${device_short}.vmdk"

    echo -e "\n--- Processing Volume: $vol_id ($device_short) ---"
    
    echo "Exporting RBD to RAW..."
    # Ensure you have 'cinder' user permissions or run as root/ceph-admin
    rbd --id cinder -p cinder-volumes export "$rbd_img" "$raw_file"

    echo "Converting RAW to VMDK..."
    qemu-img convert -p -f raw -O vmdk "$raw_file" "$vmdk_file"

    echo "Cleaning up RAW file..."
    rm "$raw_file"

    echo "Done: $vmdk_file"
    qemu-img info "$vmdk_file"
done

echo -e "\nExport process complete."