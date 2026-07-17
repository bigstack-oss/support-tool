#!/usr/bin/env bash
set -euo pipefail

source /etc/admin-openrc.sh


# --- Step 0: list regions & select (auto-pick if single) ---------------------
echo "Select Region:"
regions_json=$(openstack region list -c Region -f json)

region_count=$(echo "$regions_json" | jq 'length')
if (( region_count == 0 )); then
  echo "No regions returned by OpenStack."; exit 1
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
    read -rp "Enter region number: " ridx
    if [[ "$ridx" =~ ^[0-9]+$ ]] && (( ridx >= 1 && ridx <= ${#region_names[@]} )); then
      region_name="${region_names[$((ridx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi

# Export so downstream OpenStack CLIs respect it
export OS_REGION_NAME="$region_name"
echo "Using region: $OS_REGION_NAME"

# --- Step 1: list domains (exclude 'heat') & select (auto-pick if single) ----
echo
echo "Select Domain:"
domains_json=$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')

dom_count=$(echo "$domains_json" | jq 'length')
if (( dom_count == 0 )); then
  echo "No selectable domains found."; exit 1
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
    read -rp "Enter domain number: " dom_idx
    if [[ "$dom_idx" =~ ^[0-9]+$ ]] && (( dom_idx >= 1 && dom_idx <= ${#domain_lines[@]} )); then
      IFS='|' read -r domain_id domain_name <<< "${domain_lines[$((dom_idx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi
echo "Using domain: $domain_name ($domain_id)"

# --- Step 2: list projects in domain, exclude admin/_diagnostics/service -----
echo
echo "Select Project in domain '$domain_name':"
projects_json=$(openstack project list --domain "$domain_id" -f json)
projects_json=$(echo "$projects_json" | jq '[.[] | select(.Name != "admin" and .Name != "_diagnostics" and .Name != "service")]')

if [[ "$(echo "$projects_json" | jq 'length')" -eq 0 ]]; then
  echo "No selectable projects found in domain '$domain_name'."; exit 1
fi

i=1
mapfile -t project_lines < <(echo "$projects_json" | jq -r '.[] | "\(.ID)|\(.Name)"')
for line in "${project_lines[@]}"; do
  IFS='|' read -r proj_id proj_name <<< "$line"
  printf "%2d. %s (%s)\n" "$i" "$proj_name" "$proj_id"
  ((i++))
done

read -rp "Enter project number: " proj_idx
if ! [[ "$proj_idx" =~ ^[0-9]+$ ]] || (( proj_idx < 1 || proj_idx > ${#project_lines[@]} )); then
  echo "Invalid selection."; exit 1
fi
IFS='|' read -r project_id project_name <<< "${project_lines[$((proj_idx-1))]}"

# Assign 'admin' role to user 'admin (IAM)' in the selected project
user_id=$(openstack user list -f json | jq -r '.[] | select(.Name=="admin (IAM)") | .ID')
openstack role add --user "$user_id" --project "$project_id" admin
openstack role add --user admin_cli --project "$project_id" admin

# --- Step 3: List volumes with status 'in-use' in the selected project ---
echo
echo "Volumes currently 'in-use' in project '$project_name':"

# Fetching volumes for the specific project
volumes_json=$(openstack volume list --project "$project_id" --status "in-use" -f json)

vol_count=$(echo "$volumes_json" | jq 'length')
if (( vol_count == 0 )); then
  echo "No 'in-use' volumes found in this project."; exit 0
fi

# Map details for display: Name, ID, Size, and the Server ID it's attached to
# Note: jq handles cases where Name might be null by using ID instead
mapfile -t vol_lines < <(echo "$volumes_json" | jq -r '.[] | "\(.ID)|\(.Name // .ID)|\(.Size)|\(.Attached_to[0].server_id // "N/A")"')

i=1
for line in "${vol_lines[@]}"; do
  IFS='|' read -r v_id v_name v_size v_server <<< "$line"
  printf "%2d. Name: %-30s | ID: %s | Size: %3dGB | Attached to: %s\n" "$i" "$v_name" "$v_id" "$v_size" "$v_server"
  ((i++))
done

# --- Step 4: User selection and Ghost Attachment Cleanup ---
read -rp "Enter volume number to inspect/clean: " vol_idx

if ! [[ "$vol_idx" =~ ^[0-9]+$ ]] || (( vol_idx < 1 || vol_idx > ${#vol_lines[@]} )); then
  echo "Invalid selection."; exit 1
fi

IFS='|' read -r VOL_ID VOL_NAME VOL_SIZE VOL_SERVER_ID <<< "${vol_lines[$((vol_idx-1))]}"

echo "Inspecting Volume: $VOL_NAME ($VOL_ID)"

# Get detailed JSON for the specific volume
vol_details=$(openstack volume show "$VOL_ID" -f json)
ATTACH_ID=$(echo "$vol_details" | jq -r '.attachments[0].attachment_id // empty')
SERVER_ID=$(echo "$vol_details" | jq -r '.attachments[0].server_id // empty')

if [[ -z "$SERVER_ID" ]]; then
    echo "Error: Volume status is 'in-use' but no server attachment was found in Cinder metadata."
    exit 1
fi

echo "Checking if Server $SERVER_ID actually recognizes this volume..."

# Check if the server still thinks it has this volume attached
# We check the server's 'os-extended-volumes:volumes_attached' list
server_check=$(openstack server show "$SERVER_ID" -f json | jq -r '."os-extended-volumes:volumes_attached"[]?.id' | grep "$VOL_ID" || true)

if [[ -n "$server_check" ]]; then
    echo "Verification STOPPED: The compute service (Nova) still shows this volume as active on Server $SERVER_ID."
    echo "Please detach the volume normally via 'openstack server remove volume'."
else
    echo "Ghost attachment detected! Nova does not see this volume, but Cinder shows 'in-use'."
    echo "Proceeding with forced database cleanup..."

    # 1. Reset Cinder State
    openstack volume set --state available "$VOL_ID"
    
    # 2. Database Cleanup
    # Note: Replace 'cinder' with your actual DB name/credentials if different
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    
    echo "Updating volume_attachment in database for ID: $ATTACH_ID"
    
    mysql -e "UPDATE cinder.volume_attachment SET attach_status = 'detached', detach_time = '$CURRENT_TIME', deleted = 1, deleted_at = '$CURRENT_TIME' WHERE id = '$ATTACH_ID';"

    echo "Cleanup complete. Volume $VOL_ID should now be available."
fi
