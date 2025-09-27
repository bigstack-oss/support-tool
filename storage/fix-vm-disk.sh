#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenStack VM Root Filesystem Repairer (Ceph RBD backend)
# Logs to: /var/log/support-fix-vm-disk.log
# ============================================================

LOGFILE="/var/log/support-fix-vm-disk.log"

# -------------------------
# Helpers 
# -------------------------
log() {
  local msg="$1"
  echo "$msg"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOGFILE"
}

get_vm_state() {
  openstack server show "$SERVER_ID" -f json | jq -r '."OS-EXT-STS:vm_state" // empty'
}

get_power_status() {
  openstack server show "$SERVER_ID" -f json | jq -r '.status // empty'
}

wait_for_stopped() {
  local timeout_sec="${1:-900}" interval_sec="${2:-5}" elapsed=0
  log "Waiting for VM to stop (up to ${timeout_sec}s)..."
  while true; do
    local vm_state status
    vm_state=$(get_vm_state)
    status=$(get_power_status)
    log "  vm_state=${vm_state:-unknown}, status=${status:-unknown}"
    if [[ "$vm_state" == "stopped" ]] || [[ "$status" == "SHUTOFF" ]]; then
      log "VM is stopped."
      return 0
    fi
    if (( elapsed >= timeout_sec )); then
      log "Error: Timed out waiting for VM to stop."
      return 1
    fi
    sleep "$interval_sec"; ((elapsed+=interval_sec))
  done
}

wait_for_active() {
  local timeout_sec="${1:-900}" interval_sec="${2:-5}" elapsed=0
  log "Waiting for VM to become ACTIVE (up to ${timeout_sec}s)..."
  while true; do
    local vm_state status
    vm_state=$(get_vm_state)
    status=$(get_power_status)
    log "  vm_state=${vm_state:-unknown}, status=${status:-unknown}"
    if [[ "$vm_state" == "active" ]] || [[ "$status" == "ACTIVE" ]]; then
      log "VM is ACTIVE."
      return 0
    fi
    if (( elapsed >= timeout_sec )); then
      log "Error: Timed out waiting for VM to become ACTIVE."
      return 1
    fi
    sleep "$interval_sec"; ((elapsed+=interval_sec))
  done
}

map_rbd_image() {
  local pool="$1"
  local image="$2"
  log "Mapping RBD image: pool='${pool}', image='${image}' ..."
  if DEV_ID=$(rbd map --pool "$pool" "$image" 2>/dev/null); then
    :
  else
    log "rbd map failed; trying to find existing mapping..."
    DEV_ID=$(rbd showmapped | awk -v p="$pool" -v img="$image" '$2==p && $3==img {print $5}' | head -n1 || true)
    if [[ -z "$DEV_ID" ]]; then
      log "Error: Could not map or find mapped device for ${pool}/${image}."
      exit 1
    fi
  fi
  log "-> Mapped device: $DEV_ID"
}

cleanup() {
  if [[ -n "${DEV_ID:-}" ]]; then
    if rbd showmapped | awk '{print $5}' | grep -qx "$DEV_ID"; then
      log "Cleanup: unmapping $DEV_ID"
      rbd unmap "$DEV_ID" || true
    fi
  fi
}

# -------------------------
# Preconditions & setup
# -------------------------
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 600 "$LOGFILE" || true

DEV_ID=""
SERVER_ID=""
cur_vm_state=""
cur_status=""

trap cleanup EXIT

echo "==========================================="
echo " OpenStack RBD Root Filesystem Repairer"
echo "==========================================="

# -------------------------
# Step 1: List projects
# -------------------------
log "[1/8] Fetching OpenStack projects..."
projects_json=$(openstack project list -f json)
mapfile -t proj_lines < <(echo "$projects_json" | jq -r '.[] | "\(.Name) \(.ID)"')
if ((${#proj_lines[@]}==0)); then
  log "No projects found."
  exit 1
fi

echo
log "Select a project:"
i=1
for line in "${proj_lines[@]}"; do
  pname=${line% *}
  pid=${line##* }
  printf "%2d) %s (%s)\n" "$i" "$pname" "$pid"
  ((i++))
done
read -rp "Enter number: " sel
if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#proj_lines[@]} )); then
  log "Invalid project selection."
  exit 1
fi
selected_line="${proj_lines[$((sel-1))]}"
PROJECT_NAME=${selected_line% *}
PROJECT_ID=${selected_line##* }
log "-> Project selected: $PROJECT_NAME ($PROJECT_ID)"

# -------------------------
# Step 2: List servers
# -------------------------
log "[2/8] Fetching servers for project..."
servers_json=$(openstack server list --project "$PROJECT_ID" -f json)
mapfile -t srv_lines < <(echo "$servers_json" | jq -r '.[] | "\(.Name) \(.ID)"')
if ((${#srv_lines[@]}==0)); then
  log "No servers found in this project."
  exit 1
fi

echo
log "Select a server:"
i=1
for line in "${srv_lines[@]}"; do
  sname=${line% *}
  sid=${line##* }
  printf "%2d) %s (%s)\n" "$i" "$sname" "$sid"
  ((i++))
done
read -rp "Enter number: " ssel
if ! [[ "$ssel" =~ ^[0-9]+$ ]] || (( ssel < 1 || ssel > ${#srv_lines[@]} )); then
  log "Invalid server selection."
  exit 1
fi
srv_line="${srv_lines[$((ssel-1))]}"
SERVER_NAME=${srv_line% *}
SERVER_ID=${srv_line##* }
log "-> Server selected: $SERVER_NAME ($SERVER_ID)"

# -------------------------
# Step 3: Ensure VM stopped
# -------------------------
log "[3/8] Checking VM state..."
cur_vm_state=$(get_vm_state)
cur_status=$(get_power_status)
log "Current: vm_state=${cur_vm_state:-unknown}, status=${cur_status:-unknown}"

if [[ "$cur_vm_state" != "stopped" && "$cur_status" != "SHUTOFF" ]]; then
  log "VM is not stopped."
  read -rp 'Type "YES" to stop the VM now: ' STOP_CONFIRM
  if [[ "$STOP_CONFIRM" != "YES" ]]; then
    log "User canceled stop. Exiting."
    exit 1
  fi
  log "Stopping VM..."
  openstack server stop "$SERVER_ID"
  wait_for_stopped 900 5
fi

# -------------------------
# Step 4: Inspect boot source & map RBD
# -------------------------
log "[4/8] Inspecting server boot source..."
srv_show_json=$(openstack server show "$SERVER_ID" -f json)
image_field=$(echo "$srv_show_json" | jq -r '.image')
vol_id=$(echo "$srv_show_json" | jq -r '.attached_volumes[0]?.id // empty')

if [[ "$image_field" == "N/A (booted from volume)" ]] && [[ -n "$vol_id" ]]; then
  map_rbd_image "cinder-volumes" "volume-$vol_id"
else
  map_rbd_image "ephemeral-vms" "${SERVER_ID}_disk"
fi

# -------------------------
# Step 5: Largest partition & filesystem
# -------------------------
log "[5/8] Detecting largest partition..."
PART_ID=$(lsblk -bnro PATH,TYPE,SIZE "$DEV_ID" \
  | awk '$2=="part"{print $1, $3}' \
  | sort -k2 -n | tail -1 | awk '{print $1}')

if [[ -z "$PART_ID" ]]; then
  log "Error: No partitions found on $DEV_ID."
  exit 1
fi

log "Largest partition: $PART_ID"
lsblk "$PART_ID" | tee -a "$LOGFILE" >/dev/null
lsblk "$PART_ID"

part_type=$(blkid -o value -s TYPE "$PART_ID" || true)
if [[ -z "$part_type" ]]; then
  sig=$(file -s "$PART_ID")
  case "$sig" in
    *"XFS"*) part_type="xfs" ;;
    *"ext2 filesystem"*) part_type="ext2" ;;
    *"ext3 filesystem"*) part_type="ext3" ;;
    *"ext4 filesystem"*) part_type="ext4" ;;
    *) part_type="" ;;
  esac
fi
if [[ -z "$part_type" ]]; then
  log "Warning: Could not auto-detect filesystem. 'file -s' says:"
  file -s "$PART_ID" | tee -a "$LOGFILE" >/dev/null
  file -s "$PART_ID"
  read -rp "Enter filesystem type manually (ext4/xfs/ext3/ext2), or leave blank to abort: " manual_fs
  if [[ -z "$manual_fs" ]]; then
    log "Aborting per user input."
    exit 1
  fi
  part_type="$manual_fs"
fi
log "Detected filesystem: $part_type"

if grep -qE "[[:space:]]$PART_ID[[:space:]]" /proc/mounts; then
  log "Error: $PART_ID appears to be mounted. Unmount before repair."
  exit 1
fi

# -------------------------
# Step 6: Confirm & repair
# -------------------------
log "[6/8] Confirm repair"
log "This will attempt to repair filesystem on: $PART_ID ($part_type)"
read -rp 'Type "YES" to proceed: ' CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  log "User canceled repair. Exiting."
  exit 1
fi

log "Repairing filesystem on $PART_ID..."
case "$part_type" in
  ext4|ext3|ext2)
    fsck -y "$PART_ID" | tee -a "$LOGFILE" >/dev/null
    fsck -y "$PART_ID"
    ;;
  xfs)
    if ! command -v xfs_repair &>/dev/null; then
      log "Error: xfs_repair not available."
      exit 1
    fi
    xfs_repair -L "$PART_ID" | tee -a "$LOGFILE" >/dev/null
    xfs_repair -L "$PART_ID"
    ;;
  *)
    log "Error: Unsupported or unknown filesystem '$part_type'."
    exit 1
    ;;
esac
log "Filesystem repair completed."

# -------------------------
# Step 7: Unmap RBD
# -------------------------
log "[7/8] Unmapping RBD..."
rbd unmap "$DEV_ID" || true
DEV_ID=""
log "RBD unmapped."

# -------------------------
# Step 8: Optionally start VM (with polling)
# -------------------------
echo
log "[8/8] Previous VM status was: vm_state=${cur_vm_state:-unknown}, status=${cur_status:-unknown}"
read -rp 'Do you want to start the VM again? Type "YES" to confirm: ' START_CONFIRM
if [[ "$START_CONFIRM" == "YES" ]]; then
  log "User confirmed start. Starting VM..."
  openstack server start "$SERVER_ID"
  wait_for_active 900 5
  log "Start sequence finished."
else
  log "User declined start. Leaving VM stopped."
fi

log "Done."