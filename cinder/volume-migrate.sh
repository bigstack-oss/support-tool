#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/support-volume-migrate.log"

# ensure logfile exists (do not truncate)
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE" || {
  echo "[WARN]  Cannot write to $LOGFILE, logging to file will be disabled" >&2
}

log() {
    local msg="$*"
    local dt=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\e[32m[INFO]\e[0m  $dt $msg"
    # log to file (plain text, timestamp)
    echo "$dt [INFO]  $msg" >> "$LOGFILE" 2>/dev/null || true
}

warn() {
    local msg="$*"
    local dt=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\e[33m[WARN]\e[0m  $dt $msg"
    echo "$dt [WARN]  $msg" >> "$LOGFILE" 2>/dev/null || true
}

fail() {
    local msg="$*"
    local dt=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\e[31m[ERROR]\e[0m $dt $msg" >&2
    echo "$dt [ERROR] $msg" >> "$LOGFILE" 2>/dev/null || true
    exit 1
}

SRC_IMG=${1:-}
TMP_DIR=${2:-}
[ -z "$SRC_IMG" ] && fail "Usage: $0 <disk-image> [<temp-dir>]"
[ ! -f "$SRC_IMG" ] && fail "File not found: $SRC_IMG"

# Default output directory
DEFAULT_OUTDIR="/mnt/cephfs/glance/output"

DISK_SIZE=$(qemu-img info "$SRC_IMG" | grep '^virtual size:' | awk '{print $3, $4}')
FILE_FORMAT=$(qemu-img info "$SRC_IMG" | grep "file format" | awk -F': ' '{print $2}')
DISK_USAGE=$(qemu-img info "$SRC_IMG" | grep "disk size" | awk -F': ' '{print $2;exit}')
IMG_NAME=$(basename "$SRC_IMG")
BASE_NAME=${IMG_NAME%.*}
EXTENSION=${IMG_NAME#*.}
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="${TMP_DIR:-$DEFAULT_OUTDIR}"
mkdir -p "$OUTDIR" || fail "Unable to create directory: $OUTDIR"

echo "The disk usage is : $DISK_USAGE"
echo "The partition size is : $DISK_SIZE"
echo "The file format is : $FILE_FORMAT"

log "Fetching OpenStack projects…"
PROJ_JSON=$(openstack project list -f json) || fail "Cannot list projects"
mapfile -t P_IDS   < <(echo "$PROJ_JSON" | jq -r '.[].ID')
mapfile -t P_NAMES < <(echo "$PROJ_JSON" | jq -r '.[].Name')
[ ${#P_IDS[@]} -eq 0 ] && fail "No project found"

echo -e "Available Projects:"
for i in "${!P_IDS[@]}"; do
    echo "$((i+1)). ${P_NAMES[$i]} (${P_IDS[$i]})"
done
read -p "Select project number: " psel
[[ ! $psel =~ ^[0-9]+$ ]] || (( psel<1 || psel>${#P_IDS[@]} )) && fail "Invalid selection"
PROJECT_ID=${P_IDS[$((psel-1))]}
PROJECT_NAME=${P_NAMES[$((psel-1))]}
openstack role add --user admin_cli --project "$PROJECT_ID" admin || warn "role already set"
export OS_PROJECT_NAME="$PROJECT_NAME"
log "Project → $PROJECT_NAME ($PROJECT_ID)"

get_pools() {
    cinder get-pools 2>/dev/null | awk -F'|' '/\|/ && $2 ~ /name/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); if($3!="") print $3}'
}
POOLS=$(get_pools)
[ -z "$POOLS" ] && fail "No volume pools found by cinder get-pools"
mapfile -t POOL_ARR < <(echo "$POOLS")

# --- AUTO-SELECT POOL IF ONLY ONE EXISTS ---
if [ ${#POOL_ARR[@]} -eq 1 ]; then
    POOL=${POOL_ARR[0]}
    log "Only one pool available. Auto-selecting: $POOL"
else
    echo -e "Available Pools:"
    for i in "${!POOL_ARR[@]}"; do
        echo "$((i+1)). ${POOL_ARR[$i]}"
    done
    read -p "Select pool number: " pool_sel
    [[ ! $pool_sel =~ ^[0-9]+$ ]] || (( pool_sel<1 || pool_sel>${#POOL_ARR[@]} )) && fail "Invalid pool selection"
    POOL=${POOL_ARR[$((pool_sel-1))]}
fi
log "Pool → $POOL"

if [[ "$POOL" == *cinder-volumes-ssd* ]]; then
    VOL_POOL="cinder-volumes-ssd"
    VOL_TYPE="CubeStorage-ssd"
else
    VOL_POOL="cinder-volumes"
    VOL_TYPE="CubeStorage"
fi

# migration type selection
echo "Select migration type:"
echo "1. v2v (Operating System)"
echo "2. disk (Raw Disk Import)"

read -p "Enter option number: " migration_type_option

case $migration_type_option in
    1) migration_type="v2v" ;;
    2) migration_type="disk" ;;
    *) fail "Invalid migration type option" ;;
esac

echo "Selected migration type: $migration_type"

if [[ "$migration_type" == "disk" ]]; then
    if [[ "$FILE_FORMAT" != "raw" ]]; then
        # Date/Time handled by log()
        log "Converting $IMG_NAME to $VOL_POOL with RAW format"
        qemu-img convert -p -O raw "$SRC_IMG" "rbd:$VOL_POOL/${BASE_NAME}-converted.raw" || fail "qemu-img convert failed"
    else
        # Date/Time handled by log()
        log "Import $IMG_NAME to $VOL_POOL"
        rbd --id cinder import "$SRC_IMG" "$VOL_POOL/${BASE_NAME}-converted.raw" || fail "RBD import failed"
    fi

    RBD_NAME="${BASE_NAME}-converted.raw"
    VOL_NAME="${BASE_NAME}-${TS}"
    log "Managing volume: $VOL_NAME"
    cinder manage --bootable --volume-type "$VOL_TYPE" --name "$VOL_NAME" "$POOL" "$RBD_NAME" \
      >/dev/null 2>&1 || fail "cinder manage failed"

    cinder image-metadata "$VOL_NAME" set disk_format=raw hw_machine_type=q35

    VOL_ID=$(openstack volume show "$VOL_NAME" -f value -c id)
    rbd du "$VOL_POOL/volume-$VOL_ID" || warn "rbd du failed"

    BLK_ID=$(rbd map --pool "$VOL_POOL" "volume-$VOL_ID")
    DISTRO=$(virt-inspector -a "$BLK_ID" | xmllint --xpath 'normalize-space(//distro)' - 2>/dev/null || echo "")

    if [[ "$DISTRO" == *"windows"* ]]; then
        log "Set os_type=windows"
        cinder image-metadata "$VOL_NAME" set os_type=windows
    else
        log "Set os_type=linux"
        cinder image-metadata "$VOL_NAME" set os_type=linux
    fi

    rbd unmap "$BLK_ID" || warn "rbd unmap failed"

    openstack volume show "$VOL_NAME" -f json | jq '.volume_image_metadata'
    log "✅ Migration completed: $VOL_NAME (ID: $VOL_ID)"
    exit 0
fi

if [[ -n "$EXTENSION" ]] && { [[ "$EXTENSION" = "vhd" ]] || [[ "$EXTENSION" = "vhdx" ]]; }; then
    RAW_DISK="$OUTDIR/${BASE_NAME}.${EXTENSION}-sda"
    XML="$OUTDIR/${BASE_NAME}.${EXTENSION}.xml"
    CONVERTED="$OUTDIR/${BASE_NAME}.${EXTENSION}-sda"
else
    RAW_DISK="$OUTDIR/${BASE_NAME}-sda"
    XML="$OUTDIR/${BASE_NAME}.xml"
    CONVERTED="$OUTDIR/${BASE_NAME}-sda"
fi

log "Converting $IMG_NAME → RAW (virt-v2v)…"
LIBGUESTFS_BACKEND=direct virt-v2v -i disk "$SRC_IMG" -o local -of raw -os "$OUTDIR/" || fail "virt-v2v failed"
[ ! -f "$RAW_DISK" ] && fail "virt-v2v output missing: $RAW_DISK"

RBD_NAME="${BASE_NAME}-import-${TS}"
log "Importing to RBD: $VOL_POOL/$RBD_NAME"
rbd --id cinder import "$RAW_DISK" "$VOL_POOL/$RBD_NAME" || fail "RBD import failed"

VOL_NAME="${BASE_NAME}-${TS}"
log "Managing volume as $VOL_NAME …"
cinder manage --bootable --volume-type "$VOL_TYPE" --name "$VOL_NAME" "$POOL" "$RBD_NAME" \
  >/dev/null 2>&1 || fail "cinder manage failed"

cinder image-metadata "$VOL_NAME" set \
  disk_format=raw \
  hw_qemu_guest_agent=True \
  hw_video_model=vga \
  hw_machine_type=q35 \
  hw_scsi_model=virtio-scsi \
  hw_vif_model=virtio \
  hw_input_bus=virtio \
  hw_disk_bus=virtio

if [[ -f "$XML" && $(grep -c "<os firmware='efi'" "$XML") -gt 0 ]]; then
    cinder image-metadata "$VOL_NAME" set hw_firmware_type=uefi os_secure_boot=optional
else
    cinder image-metadata "$VOL_NAME" set hw_firmware_type=bios
fi

if [[ -f "$XML" && $(grep -ci "microsoft" "$XML") -gt 0 ]]; then
    cinder image-metadata "$VOL_NAME" set os_type=windows
else
    cinder image-metadata "$VOL_NAME" set os_type=linux
fi

rm -f "$CONVERTED"

openstack volume show "$VOL_NAME" -f json | jq '.volume_image_metadata'
VOL_ID=$(openstack volume show "$VOL_NAME" -f value -c id)
rbd du "$VOL_POOL/volume-$VOL_ID" || warn "rbd du failed"
log "✅ Migration completed: $VOL_NAME (ID: $VOL_ID)"