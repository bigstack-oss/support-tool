#!/usr/bin/env bash
# set -e is intentionally not used to allow graceful error messages.
set -uo pipefail

LOG_FILE="/var/log/support-set-vm-password.log"
[ -w "$(dirname "$LOG_FILE")" ] || LOG_FILE="./support-set-vm-password.log"

TS() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "[$(TS)] $*" | tee -a "$LOG_FILE" >&2; }

# If you keep your creds in an openrc, source it (optional).
# Edit the path as needed; non-fatal if missing.
[ -f /etc/admin-openrc.sh ] && . /etc/admin-openrc.sh || true

pick_from_list() {
  # Reads "name|id" lines from stdin, presents a numbered menu, and echoes the chosen id.
  # Auto-selects if only one option.
  mapfile -t ITEMS < <(grep -v '^[[:space:]]*$' || true)
  local count=${#ITEMS[@]}
  if (( count == 0 )); then
    log "ERROR: No selectable items found."
    return 1
  elif (( count == 1 )); then
    local name="${ITEMS[0]%%|*}"; local id="${ITEMS[0]#*|}"
    echo "$id"
    log "Auto-selected: ${name} ($id)"
    return 0
  else
    local i=1
    for line in "${ITEMS[@]}"; do
      local name="${line%%|*}"; local id="${line#*|}"
      echo "$i. ${name} (${id})"
      ((i++))
    done
    while true; do
      read -r -p "Enter a number [1-$count]: " sel
      [[ "$sel" =~ ^[0-9]+$ ]] || { echo "Please enter a valid number."; continue; }
      (( sel>=1 && sel<=count )) || { echo "Please choose between 1 and $count."; continue; }
      local chosen="${ITEMS[sel-1]}"
      echo "${chosen#*|}"
      return 0
    done
  fi
}

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

# --- STEP 3: LIST SERVERS IN PROJECT & SELECT --------------------------------
echo
echo "Select Server in project '$PROJECT_NAME':"
SERVERS_JSON=$(openstack server list --project "$PROJECT_ID" -f json)

SERV_COUNT=$(echo "$SERVERS_JSON" | jq 'length')
if (( SERV_COUNT == 0 )); then
  echo "No servers found in project '$PROJECT_NAME'."; exit 1
fi

# Build "ID|Name" lines and present a numbered list
i=1
mapfile -t SERVER_LINES < <(echo "$SERVERS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)"')
for LINE in "${SERVER_LINES[@]}"; do
  IFS='|' read -r SRV_ID SRV_NAME <<< "$LINE"
  printf "%2d. %s (%s)\n" "$i" "$SRV_NAME" "$SRV_ID"
  ((i++))
done

# Prompt until a valid number is chosen
while :; do
  read -rp "Enter server number: " SRV_IDX
  if [[ "$SRV_IDX" =~ ^[0-9]+$ ]] && (( SRV_IDX >= 1 && SRV_IDX <= ${#SERVER_LINES[@]} )); then
    IFS='|' read -r SERVER_ID SERVER_NAME <<< "${SERVER_LINES[$((SRV_IDX-1))]}"
    break
  fi
  echo "Invalid selection."
done
echo "Using server: $SERVER_NAME ($SERVER_ID)"

# --- STEP 3.1: VERIFY VM STATE & OFFER TO POWER ON ---------------------------
echo
echo "This VM must be powered on and have the QEMU guest agent installed."

# Query current state of selected server
SERVER_STATE=$(openstack server show "$SERVER_ID" -f value -c status 2>/dev/null || echo "UNKNOWN")
echo "Current VM state: $SERVER_STATE"

# If not ACTIVE, ask whether to power on
if [[ "$SERVER_STATE" != "ACTIVE" ]]; then
  while :; do
    read -rp "The VM is not ACTIVE. Do you want to power it on now? (YES/NO): " ANSWER
    case "$ANSWER" in
      YES)
        echo "Starting VM '$SERVER_NAME' ($SERVER_ID)..."
        openstack server start "$SERVER_ID"
        echo "Waiting for VM to reach ACTIVE state..."
        for _ in {1..30}; do
          sleep 5
          SERVER_STATE=$(openstack server show "$SERVER_ID" -f value -c status 2>/dev/null || echo "UNKNOWN")
          echo "Status: $SERVER_STATE"
          [[ "$SERVER_STATE" == "ACTIVE" ]] && break
        done
        if [[ "$SERVER_STATE" != "ACTIVE" ]]; then
          echo "ERROR: VM failed to reach ACTIVE state. Aborting."
          exit 1
        fi
        echo "VM is now ACTIVE."
        break
        ;;
      NO)
        echo "User chose not to power on the VM. Exiting."
        exit 0
        ;;
      *)
        echo "Invalid input. Please enter YES or NO in uppercase."
        ;;
    esac
  done
else
  echo "VM is already ACTIVE."
fi

# --- Step 4: Ask VM username ---
read -r -p "Enter the VM username (e.g., root): " VM_USER
if [[ -z "$VM_USER" ]]; then
  log "ERROR: VM username cannot be empty."
  exit 1
fi

# --- Step 5: Ask desired new password (hidden input) ---
read -r -s -p "Enter the NEW password to set: " VM_PASS; echo
if [[ -z "$VM_PASS" ]]; then
  log "ERROR: Password cannot be empty."
  exit 1
fi

# --- Step 6: Get instance_name and compute host; then SSH and virsh ---
log "Fetching server details for $SERVER_ID ..."
SERVER_SHOW=$(openstack server show "$SERVER_ID" -f json 2>>"$LOG_FILE") || { log "ERROR: Failed to get server details."; exit 1; }

INSTANCE_NAME=$(jq -r '."OS-EXT-SRV-ATTR:instance_name"' <<<"$SERVER_SHOW")
COMPUTE_HOST=$(jq -r '."OS-EXT-SRV-ATTR:host"' <<<"$SERVER_SHOW")

if [[ -z "$INSTANCE_NAME" || "$INSTANCE_NAME" == "null" ]]; then
  log "ERROR: Could not determine instance_name from server details."
  exit 1
fi
if [[ -z "$COMPUTE_HOST" || "$COMPUTE_HOST" == "null" ]]; then
  log "ERROR: Could not determine compute host from server details."
  exit 1
fi

SSH_USER="${SSH_USER:-root}"   # Override with: export SSH_USER=ubuntu
SSH_OPTS=${SSH_OPTS:-"-o BatchMode=yes -o StrictHostKeyChecking=accept-new"}

log "About to set user password via libvirt on compute host."
log "Compute host: $COMPUTE_HOST, instance: $INSTANCE_NAME, user: $VM_USER"

# We never echo the password to logs or stdout.
set +o xtrace
ssh $SSH_OPTS "${SSH_USER}@${COMPUTE_HOST}" \
  sudo virsh set-user-password --domain "$INSTANCE_NAME" --user "$VM_USER" --password "$VM_PASS"
RC=$?

if (( RC == 0 )); then
  log "SUCCESS: Password updated for user '$VM_USER' on instance '$INSTANCE_NAME' via host '$COMPUTE_HOST'."
else
  log "ERROR: virsh set-user-password failed with exit code $RC. Check guest-agent status and permissions on $COMPUTE_HOST."
  exit $RC
fi