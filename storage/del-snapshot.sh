#!/usr/bin/env bash
set -euo pipefail

POOL="cinder-volumes"
CONFIRM_WORD="YES"
WAIT_INTERVAL=5
WAIT_SERVER_STOP_TIMEOUT=600
LOG_FILE="/var/log/support-volume-snapshot.log"

mkdir -p "$(dirname "$LOG_FILE")"

# --- Preserve console fds BEFORE redirecting logs ---
exec 3>&1 4>&2                   # FD3 = original stdout (terminal), FD4 = original stderr (terminal)

# --- Redirect all stdout/stderr to logfile ONLY ---
exec >"$LOG_FILE" 2>&1

ts() { date +'%F %T'; }
log() { printf "[%s] %s\n" "$(ts)" "$*"; }     # goes to log file
step() { printf "%s\n" "$*" >&3; }             # goes to terminal via FD3
errstep() { printf "%s\n" "$*" >&4; }          # if you ever want terminal stderr

die() {
  log "ERROR: $*"
  printf "❌ %s\n" "$*" >&3
  exit 1
}

SNAPSHOT_ID="${1:-}"
[[ -n "$SNAPSHOT_ID" ]] || die "Usage: $0 <SNAPSHOT_ID>"

#---------------------------
# Step 1: Snapshot & Volume
#---------------------------
SNAPSHOT_JSON="$(openstack volume snapshot show "$SNAPSHOT_ID" -f json 2>/dev/null || true)"
[[ -n "$SNAPSHOT_JSON" ]] || die "Snapshot $SNAPSHOT_ID not found."

SNAPSHOT_NAME="$(echo "$SNAPSHOT_JSON" | jq -r '.name // empty')"
VOLUME_ID="$(echo "$SNAPSHOT_JSON" | jq -r '.volume_id')"
[[ -n "$VOLUME_ID" && "$VOLUME_ID" != "null" ]] || die "Failed to extract volume_id from snapshot $SNAPSHOT_ID"

PARENT_VOL_NAME="$(openstack volume show "$VOLUME_ID" -f value -c name 2>/dev/null || true)"

log "Step 1: Resolve volume_id from snapshot: $SNAPSHOT_ID"
SNAP_SPEC="${POOL}/volume-${VOLUME_ID}@snapshot-${SNAPSHOT_ID}"
log "Resolved snapshot spec: $SNAP_SPEC"

# Terminal
step "Step 1: Resolve volume_id from snapshot: ${SNAPSHOT_NAME:-N/A}(${SNAPSHOT_ID})"

#---------------------------
# Step 2: Children
#---------------------------
log "Step 2: Query RBD children of snapshot"
CHILDREN_RAW="$(rbd children "$SNAP_SPEC" 2>/dev/null || true)"
mapfile -t CHILDREN <<<"$(printf "%s\n" "$CHILDREN_RAW" | sed '/^\s*$/d')"
CHILD_COUNT="${#CHILDREN[@]}"
log "Found $CHILD_COUNT child(ren)."
log "Children exist; processing each child…"

step "Step 2: Query RBD children of snapshot"

declare -A SERVER_TO_RESTART=()  # id -> name

#---------------------------
# Step 3–5: For each child
#---------------------------
for child in "${CHILDREN[@]}"; do
  CHILD_IMAGE_WITH_PREFIX="$(echo "$child" | awk -F'/' '{print $2}')"
  CHILD_VOLUME_ID="$(echo "$CHILD_IMAGE_WITH_PREFIX" | sed 's/^volume-//')"

  log "Step 3: Inspect child volume $CHILD_VOLUME_ID"
  CHILD_VOL_JSON="$(openstack volume show "$CHILD_VOLUME_ID" -f json)"
  CHILD_VOLUME_NAME="$(echo "$CHILD_VOL_JSON" | jq -r '.name // empty')"
  CHILD_STATUS="$(echo "$CHILD_VOL_JSON" | jq -r '.status // empty')"

  step "Step 3: Inspect child volume ${CHILD_VOLUME_NAME:-N/A}(${CHILD_VOLUME_ID})"
  log "Child volume status: ${CHILD_STATUS:-unknown}"

  if [[ "$CHILD_STATUS" == "in-use" ]]; then
    log "Step 4: Locate server attached to $CHILD_VOLUME_ID"
    SERVER_ID="$(echo "$CHILD_VOL_JSON" | jq -r '.attachments[0].server_id // empty')"
    [[ -n "$SERVER_ID" ]] || die "No server_id found for child $CHILD_VOLUME_ID"

    SERVER_JSON="$(openstack server show "$SERVER_ID" -f json)"
    SERVER_NAME="$(echo "$SERVER_JSON" | jq -r '.name // empty')"
    SERVER_STATUS="$(echo "$SERVER_JSON" | jq -r '.status // empty')"

    log "Server $SERVER_ID status: ${SERVER_STATUS:-unknown}"
    step "Step 4: Locate server attached to ${SERVER_NAME:-N/A}(${SERVER_ID})"

    case "$SERVER_STATUS" in
      SHUTOFF)
        log "Server is SHUTOFF. Needs no stop."
        ;;
      ACTIVE)
        log "Server is ACTIVE. Needs stop before cleanup."
        # Print the prompt to terminal, but also log the fact we're asking
        printf "Type %s to stop %s and proceed: " "$CONFIRM_WORD" "$SERVER_NAME" >&3
        log "Type ${CONFIRM_WORD} to stop ${SERVER_NAME} and proceed:"
        ANSWER=""
        # Read from keyboard (not from redirected stdin)
        # shellcheck disable=SC2162
        read ANSWER </dev/tty
        log "User input: ${ANSWER}"
        [[ "$ANSWER" == "$CONFIRM_WORD" ]] || die "Aborted by user."

        openstack server stop "$SERVER_ID"

        # Wait for SHUTOFF with periodic log lines
        while :; do
          log "Waiting for ${SERVER_ID} to stop…"
          sleep "$WAIT_INTERVAL"
          CUR_STATUS="$(openstack server show "$SERVER_ID" -c status -f value)"
          [[ "$CUR_STATUS" == "SHUTOFF" ]] && break
        done

        SERVER_TO_RESTART["$SERVER_ID"]="${SERVER_NAME:-}"
        ;;
      *)
        die "Unexpected server state: ${SERVER_STATUS:-unknown}"
        ;;
    esac
  fi

  log "Step 5 (child): Flattening child volume $CHILD_VOLUME_ID"
  step "Step 5 (child): Flattening child volume ${CHILD_VOLUME_NAME:-N/A}(${CHILD_VOLUME_ID})"
  rbd flatten "${POOL}/volume-${CHILD_VOLUME_ID}"
done

#---------------------------
# Step 6–7: Delete snapshot
#---------------------------
log "Step 6: Unprotect and delete snapshot: $SNAP_SPEC"
step "Step 6: Unprotect and delete snapshot"

if ! rbd snap unprotect "$SNAP_SPEC" 2>/dev/null; then
  log "Snapshot may already be unprotected."
fi
rbd snap rm "$SNAP_SPEC"
openstack volume snapshot delete "$SNAPSHOT_ID"

log "Snapshot $SNAPSHOT_ID removed successfully."
step "Step 7: Snapshot ${SNAPSHOT_NAME:-N/A}(${SNAPSHOT_ID}) removed successfully."

#---------------------------
# Restart servers if needed
#---------------------------
if (( ${#SERVER_TO_RESTART[@]} > 0 )); then
  for sid in "${!SERVER_TO_RESTART[@]}"; do
    sname="${SERVER_TO_RESTART[$sid]}"
    log "Restarting server $sid"
    step "Restarting server ${sname:-N/A}(${sid})"
    openstack server start "$sid"
  done
fi

log "Cleanup finished successfully."
step "Cleanup finished successfully."