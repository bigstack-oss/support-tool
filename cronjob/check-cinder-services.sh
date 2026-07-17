#!/usr/bin/env bash
set -euo pipefail
source /etc/admin-openrc.sh

# ---- Configuration & Environment ----
# Ensure cron has the correct PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG_FILE="/var/log/support-cinder-scheduler.log"
LOCK_FILE="/var/lock/support-cinder-scheduler.lock"

# ----------------------------
# Logging helpers
# ----------------------------
ts() { date "+%F %T"; }

log()  { echo "[$(ts)] [INFO]  $*" | tee -a "$LOG_FILE" >&2; }
warn() { echo "[$(ts)] [WARN]  $*" | tee -a "$LOG_FILE" >&2; }
err()  { echo "[$(ts)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

run() {
  log "RUN: $*"
  # shellcheck disable=SC2090
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

# ----------------------------
# Ensure log file exists
# ----------------------------
touch "$LOG_FILE" 2>/dev/null || {
  echo "Cannot write to $LOG_FILE (need permission). Try sudo." >&2
  exit 1
}

# ----------------------------
# Single-instance lock (avoid cron overlap)
# ----------------------------
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "Another instance is running; exiting."
  exit 0
fi

HOST_SHORT="$(hostname -s)"

# Track created volume IDs for cleanup on exit
CREATED_VOLUME_IDS=()

cleanup() {
  # Best-effort cleanup of any created volumes if still around
  for vid in "${CREATED_VOLUME_IDS[@]:-}"; do
    if openstack volume show "$vid" >/dev/null 2>&1; then
      warn "Cleanup: deleting leftover volume $vid"
      openstack volume delete --force "$vid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

# ----------------------------
# Step 1: Check pcs status
# ----------------------------
log "===== Cinder scheduler hourly check START (host=$HOST_SHORT) ====="

PCS_OUT="$(pcs status 2>&1 || true)"

CINDER_NODE="$(echo "$PCS_OUT" | awk '/cinder-volume[[:space:]]*\(/ && /Started/ {print $NF; exit}')"

if [[ -z "${CINDER_NODE:-}" ]]; then
  err "Could not find 'cinder-volume ... Started <node>' in pcs status. Stop."
  exit 3
fi

log "pcs reports cinder-volume started on: $CINDER_NODE"
if [[ "$CINDER_NODE" != "$HOST_SHORT" ]]; then
  log "cinder-volume is not on this host ($HOST_SHORT). Stop."
  log "===== END (not on this host) ====="
  exit 0
fi

log "cinder-volume is on this host; continue."

# ----------------------------
# Helpers: create, status check, delete, force-available
# ----------------------------
create_volume() {
  local vname="support-check-cinder-$(date +%Y%m%d%H%M%S)"
  log "Creating volume: name=$vname size=1GiB"

  local vid
  vid="$(openstack volume create --size 1 "$vname" -c id -f value 2>>"$LOG_FILE" | tr -d '\r' | tail -n 1)"

  if [[ -z "${vid:-}" ]]; then
    err "Failed to create volume (no id returned)."
    return 1
  fi

  log "Created volume id=$vid"
  CREATED_VOLUME_IDS+=("$vid")

  # IMPORTANT: stdout must be ONLY the id for command substitution
  printf '%s\n' "$vid"
}

get_status() {
  local vid="$1"
  openstack volume show "$vid" -c status -f value 2>>"$LOG_FILE" | tr -d '\r' | tail -n 1
}

delete_volume() {
  local vid="$1"
  log "Deleting volume $vid"
  # best-effort force delete
  openstack volume delete --force "$vid" 2>&1 | tee -a "$LOG_FILE" || true
}

force_set_available() {
  local vid="$1"
  warn "Force setting volume state to available: $vid"
  # Requires admin perms / policy allowing state reset
  openstack volume set --state available "$vid" 2>&1 | tee -a "$LOG_FILE"
}

wait_available_or_creating_timeout() {
  local vid="$1"
  local tries=3
  local sleep_s=10

  for i in $(seq 1 "$tries"); do
    local st
    st="$(get_status "$vid")"
    log "Volume $vid status check ($i/$tries): $st"

    if [[ "$st" == "available" ]]; then
      return 0
    fi

    if [[ "$st" == "creating" ]]; then
      if [[ "$i" -lt "$tries" ]]; then
        log "Status is creating; sleep ${sleep_s}s then retry..."
        sleep "$sleep_s"
        continue
      fi
      # still creating after retries
      return 1
    fi

    warn "Unexpected status '$st' (not available/creating). Treat as failure."
    return 2
  done

  return 1
}

restart_cinder_volume_service() {
  warn "Restarting openstack-cinder-volume service"
  run systemctl restart openstack-cinder-volume

  local st
  st="$(systemctl is-active openstack-cinder-volume 2>>"$LOG_FILE" || true)"
  log "systemctl is-active openstack-cinder-volume => $st"
  [[ "$st" == "active" ]]
}

# ----------------------------
# Step 2 + 3: Create + check
# ----------------------------
VOL1_ID="$(create_volume)"
log "Check volume status for $VOL1_ID (up to 3 retries x 10s if creating)"

if wait_available_or_creating_timeout "$VOL1_ID"; then
  log "Volume $VOL1_ID became available. Checking complete."
  delete_volume "$VOL1_ID"
  log "===== END (OK) ====="
  exit 0
fi

warn "Volume $VOL1_ID is still creating after retries; proceed to Step 4."

# ----------------------------
# Step 4: Restart service and re-check
# ----------------------------
if ! restart_cinder_volume_service; then
  err "openstack-cinder-volume did not become active after restart."
  exit 4
fi

# 4.1 Force set volume1 to available then delete (best effort)
# If policy denies, log will show it; we still try delete.
if force_set_available "$VOL1_ID"; then
  log "Force set succeeded for $VOL1_ID"
else
  warn "Force set failed for $VOL1_ID (likely policy/permission). Continue."
fi
delete_volume "$VOL1_ID"

# 4.2 Repeat step 2 and validate again
VOL2_ID="$(create_volume)"
log "Re-check new volume $VOL2_ID status (up to 3 retries x 10s if creating)"

if wait_available_or_creating_timeout "$VOL2_ID"; then
  log "New volume $VOL2_ID became available. Checking complete."
  delete_volume "$VOL2_ID"
  log "===== END (OK after restart) ====="
  exit 0
fi

err "New volume $VOL2_ID did NOT become available after restart + retries."
warn "Leaving script with failure (volumes will be cleaned up best-effort)."
exit 5