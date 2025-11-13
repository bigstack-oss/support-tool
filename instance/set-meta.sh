#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG (adjust if needed) ---
MYSQL_DB_NAME="nova"          # Nova DB name
MYSQL_CMD="mysql"             # mysql client (assumes ~/.my.cnf has creds)

# --- STEP 1: LIST DOMAINS (EXCLUDE 'HEAT') & SELECT (AUTO-PICK IF SINGLE) ----
echo
echo "Select Domain:"
DOMAINS_JSON=$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')

DOM_COUNT=$(echo "$DOMAINS_JSON" | jq 'length')
if (( DOM_COUNT == 0 )); then
  echo "No selectable domains found."
  exit 1
fi

mapfile -t DOMAIN_LINES < <(echo "$DOMAINS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)"')

if (( DOM_COUNT == 1 )); then
  IFS='|' read -r DOMAIN_ID DOMAIN_NAME <<< "${DOMAIN_LINES[0]}"
  echo "Only one domain found."
else
  i=1
  for LINE in "${DOMAIN_LINES[@]}"; do
    IFS='|' read -r DOM_ID DOM_NAME <<< "$LINE"
    printf "%2d. %s (%s)\n" "$i" "$DOM_NAME" "$DOM_ID"
    ((i++))
  done
  while :; do
    read -rp "Enter domain number: " DOM_IDX
    if [[ "$DOM_IDX" =~ ^[0-9]+$ ]] && (( DOM_IDX >= 1 && DOM_IDX <= ${#DOMAIN_LINES[@]} )); then
      IFS='|' read -r DOMAIN_ID DOMAIN_NAME <<< "${DOMAIN_LINES[$((DOM_IDX-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi
echo "Using domain: $DOMAIN_NAME ($DOMAIN_ID)"

# --- STEP 2: LIST PROJECTS IN DOMAIN, EXCLUDE SERVICE -----
echo
echo "Select Project in domain '$DOMAIN_NAME':"
PROJECTS_JSON=$(openstack project list --domain "$DOMAIN_ID" -f json)
PROJECTS_JSON=$(echo "$PROJECTS_JSON" | jq '[.[] | select(.Name != "service")]')

PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')
if (( PROJ_COUNT == 0 )); then
  echo "No selectable projects found in domain '$DOMAIN_NAME'."
  exit 1
fi

i=1
mapfile -t PROJECT_LINES < <(echo "$PROJECTS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)"')
for LINE in "${PROJECT_LINES[@]}"; do
  IFS='|' read -r PROJ_ID PROJ_NAME <<< "$LINE"
  printf "%2d. %s (%s)\n" "$i" "$PROJ_NAME" "$PROJ_ID"
  ((i++))
done

while :; do
  read -rp "Enter project number: " PROJ_IDX
  if [[ "$PROJ_IDX" =~ ^[0-9]+$ ]] && (( PROJ_IDX >= 1 && PROJ_IDX <= ${#PROJECT_LINES[@]} )); then
    IFS='|' read -r PROJECT_ID PROJECT_NAME <<< "${PROJECT_LINES[$((PROJ_IDX-1))]}"
    break
  fi
  echo "Invalid selection."
done
echo "Using project: $PROJECT_NAME ($PROJECT_ID)"

# --- STEP 3: LIST SERVERS & SELECT ----
echo
echo "Select Server in project '$PROJECT_NAME':"

mapfile -t servers < <(
    openstack server list --project "$PROJECT_ID" --long -c ID -c Name -f value
)

if [ ${#servers[@]} -eq 0 ]; then
    echo "No servers found for project $PROJECT_NAME."
    exit 1
fi

echo "Available servers:"
for i in "${!servers[@]}"; do
    sid=$(echo "${servers[i]}" | awk '{print $1}')
    sname=$(echo "${servers[i]}" | sed "s/^$sid[[:space:]]*//")
    echo "$((i+1)). $sname ($sid)"
done

while :; do
    read -rp "Enter server number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#servers[@]} )); then
        selected_server="${servers[$((choice-1))]}"
        selected_server_id=$(echo "$selected_server" | awk '{print $1}')
        selected_server_name=$(echo "$selected_server" | sed "s/^$selected_server_id[[:space:]]*//")
        break
    fi
    echo "Invalid selection."
done

echo "You selected: $selected_server_name ($selected_server_id)"

# --- STEP 4: LIST ATTACHED VOLUMES & SELECT ----
echo
echo "Fetching attached volumes for server $selected_server_name ..."

volumes_json=$(
    openstack server show "$selected_server_id" \
        -c attached_volumes -f json
)

mapfile -t volume_ids < <(
    echo "$volumes_json" | jq -r '.attached_volumes[].id'
)

if [ ${#volume_ids[@]} -eq 0 ]; then
    echo "No attached volumes found for server $selected_server_id."
    exit 1
fi

volume_info=()
for volume_id in "${volume_ids[@]}"; do
    volume_json=$(openstack volume show "$volume_id" -c attachments -f json)
    device=$(echo "$volume_json" | jq -r '.attachments[0].device')
    volume_info+=("$volume_id $device")
done

echo "Select a volume by number:"
for i in "${!volume_info[@]}"; do
    vid=$(echo "${volume_info[i]}" | awk '{print $1}')
    dev=$(echo "${volume_info[i]}" | awk '{print $2}')
    echo "$((i+1)). $vid (Device: $dev)"
done

while :; do
    read -rp "Enter volume number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#volume_info[@]} )); then
        selected_volume_id=$(echo "${volume_info[$((choice-1))]}" | awk '{print $1}')
        break
    fi
    echo "Invalid selection."
done

echo "You selected volume: $selected_volume_id"

# --- STEP 5: OS TYPE SELECTION ----
echo
echo "Select OS type:"
echo "1. windows"
echo "2. linux"
read -rp "Enter option number: " os_type_option

case $os_type_option in
    1) os_type="windows" ;;
    2) os_type="linux" ;;
    *) echo "Invalid option"; exit 1 ;;
esac

echo "Selected os_type: $os_type"

# --- STEP 6: UPDATE METADATA (NOVA DB + CINDER IMAGE-METADATA) ----
echo
echo "===== METADATA SUMMARY ====="
echo "Domain:  $DOMAIN_NAME ($DOMAIN_ID)"
echo "Project: $PROJECT_NAME ($PROJECT_ID)"
echo "Server:  $selected_server_name ($selected_server_id)"
echo "Volume:  $selected_volume_id"
echo "os_type: $os_type"
echo

read -rp "Proceed to update Nova DB and Cinder image-metadata? (YES/NO): " confirm_meta
confirm_meta=${confirm_meta^^}

if [ "$confirm_meta" = "YES" ]; then
    echo "Updating Nova DB (instances.os_type)..."
    $MYSQL_CMD "$MYSQL_DB_NAME" -e \
        "UPDATE instances SET os_type='${os_type}' WHERE uuid='${selected_server_id}';"

    echo "Updating Cinder image-metadata..."
    cinder image-metadata "$selected_volume_id" set os_type="$os_type"

    echo "Metadata update completed."
else
    echo "Metadata update skipped."
fi

# --- STEP 7: OPTIONAL SERVER RESTART ----
echo
read -rp "Do you want to restart the server now? (YES/NO): " answer
answer=${answer^^}

if [ "$answer" = "YES" ]; then
    echo "Stopping server $selected_server_name ($selected_server_id)..."
    openstack server stop "$selected_server_id"

    echo -n "Waiting for server to reach SHUTOFF state"
    while :; do
        status=$(openstack server show "$selected_server_id" -c status -f value)
        if [ "$status" = "SHUTOFF" ]; then
            echo " -> SHUTOFF"
            break
        fi
        echo -n "."
        sleep 5
    done

    echo "Starting server $selected_server_name ($selected_server_id)..."
    openstack server start "$selected_server_id"

    echo -n "Waiting for server to reach ACTIVE state"
    while :; do
        status=$(openstack server show "$selected_server_id" -c status -f value)
        if [ "$status" = "ACTIVE" ]; then
            echo " -> ACTIVE"
            break
        fi
        echo -n "."
        sleep 5
    done

    echo "Server restart completed."
else
    echo "Server restart skipped."
fi

echo
echo "All steps completed."