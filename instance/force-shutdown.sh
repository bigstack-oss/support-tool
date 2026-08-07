#!/usr/bin/env bash
# set -e is intentionally not used to allow graceful error messages.
set -uo pipefail

LOG_FILE="/var/log/support-change-vm-state.log"
[ -w "$(dirname "$LOG_FILE")" ] || LOG_FILE="./support-change-vm-state.log"

TS() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "[$(TS)] $*" | tee -a "$LOG_FILE" >&2; }

# If you keep your creds in an openrc, source it (optional).
# Edit the path as needed; non-fatal if missing.
[ -f /etc/admin-openrc.sh ] && . /etc/admin-openrc.sh || true

# --- STEP 1: LIST DOMAINS (EXCLUDE 'HEAT') & SELECT (AUTO-PICK IF SINGLE) ----
echo
echo "Select Domain:"
DOMAINS_JSON=$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')

DOM_COUNT=$(echo "$DOMAINS_JSON" | jq 'length')
if (( DOM_COUNT == 0 )); then
  echo "No selectable domains found."; exit 1
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
  echo "No selectable projects found in domain '$DOMAIN_NAME'."; exit 1
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

# --- STEP 3: LIST ALL SERVERS IN PROJECT & SELECT ---
echo
echo "Select Server in project '$PROJECT_NAME':"
SERVERS_JSON=$(openstack server list --project "$PROJECT_ID" -f json)

SERV_COUNT=$(echo "$SERVERS_JSON" | jq 'length')
if (( SERV_COUNT == 0 )); then
  echo "No servers found in project '$PROJECT_NAME'."; exit 0
fi

# Build "ID|Name|Status" lines
mapfile -t SERVER_LINES < <(echo "$SERVERS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)|\(.Status)"')

# Output numbered server list
i=1
for LINE in "${SERVER_LINES[@]}"; do
  IFS='|' read -r SRV_ID SRV_NAME SRV_STATUS <<< "$LINE"
  printf "%2d. %s (%s) - %s\n" "$i" "$SRV_NAME" "$SRV_ID" "$SRV_STATUS"
  ((i++))
done

# ALL SERVERS option as the last entry
ALL_IDX=$((SERV_COUNT + 1))
printf "%2d. ALL SERVERS (Process all %d servers)\n" "$ALL_IDX" "$SERV_COUNT"

# Prompt until a valid number is chosen
TARGET_SERVERS=()
while :; do
  read -rp "Enter server number [1-$ALL_IDX]: " SRV_IDX
  if [[ "$SRV_IDX" =~ ^[0-9]+$ ]]; then
    if (( SRV_IDX == ALL_IDX )); then
      TARGET_SERVERS=("${SERVER_LINES[@]}")
      echo "Selected: ALL servers"
      break
    elif (( SRV_IDX >= 1 && SRV_IDX <= SERV_COUNT )); then
      TARGET_SERVERS=("${SERVER_LINES[$((SRV_IDX-1))]}")
      IFS='|' read -r S_ID S_NAME _ <<< "${TARGET_SERVERS[0]}"
      echo "Target server: $S_NAME ($S_ID)"
      break
    fi
  fi
  echo "Invalid selection."
done

# --- STEP 4: PROCESS SELECTED SERVER(S) ---
SSH_USER="${SSH_USER:-root}" 
SSH_OPTS=${SSH_OPTS:-"-o BatchMode=yes -o StrictHostKeyChecking=accept-new"}

for ENTRY in "${TARGET_SERVERS[@]}"; do
  IFS='|' read -r SERVER_ID SERVER_NAME SERVER_STATUS <<< "$ENTRY"
  echo
  log "------------------------------------------------------------"
  
  # Skip processing if the server status is SHUTOFF
  if [[ "$SERVER_STATUS" == "SHUTOFF" ]]; then
    log "Skipping server: $SERVER_NAME ($SERVER_ID) [Status is SHUTOFF]"
    continue
  fi

  log "Processing server: $SERVER_NAME ($SERVER_ID) [Current Status: $SERVER_STATUS]"

  SERVER_SHOW=$(openstack server show "$SERVER_ID" -f json 2>>"$LOG_FILE") || { 
    log "ERROR: Failed to get server details for $SERVER_ID. Skipping."
    continue
  }

  INSTANCE_NAME=$(jq -r '."OS-EXT-SRV-ATTR:instance_name"' <<<"$SERVER_SHOW")
  COMPUTE_HOST=$(jq -r '."OS-EXT-SRV-ATTR:host"' <<<"$SERVER_SHOW")

  if [[ -z "$INSTANCE_NAME" || "$INSTANCE_NAME" == "null" ]]; then
    log "ERROR: Could not determine instance_name for $SERVER_NAME ($SERVER_ID). Skipping."
    continue
  fi
  if [[ -z "$COMPUTE_HOST" || "$COMPUTE_HOST" == "null" ]]; then
    log "ERROR: Could not determine compute host for $SERVER_NAME ($SERVER_ID). Skipping."
    continue
  fi

  log "Forced shutdown of instance '$INSTANCE_NAME' on compute host '$COMPUTE_HOST' ..."
  if ssh $SSH_OPTS "${SSH_USER}@${COMPUTE_HOST}" "virsh destroy '$INSTANCE_NAME'"; then
    log "Successfully destroyed domain $INSTANCE_NAME on $COMPUTE_HOST."
  else
    log "WARNING: 'virsh destroy' exited with non-zero status. Proceeding with DB update."
  fi

  log "Updating database to reflect stopped state for server '$SERVER_ID' ..."
  mysql nova -e "UPDATE instances SET vm_state = 'stopped', power_state = 4, task_state = NULL WHERE uuid = '$SERVER_ID';"

  openstack server show "$SERVER_ID" -c compute_host -c hostname -c status -c power_state -c task_state -c vm_state -f json
done

log "All operations complete."