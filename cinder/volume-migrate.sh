#!/usr/bin/env bash
# Import a disk image as a Cinder volume on either a Ceph/RBD or NetApp NFS backend.
# Run on a Cinder controller after sourcing the appropriate OpenStack admin RC file.
set -euo pipefail

LOGFILE=/var/log/support-volume-migrate.log
GLANCE_DIR=/mnt/cephfs/glance
DEFAULT_OUTDIR=/mnt/cephfs/glance/output
MANAGE_WAIT_SECONDS=300

log()  { local now; now=$(date '+%F %T'); printf '\033[32m[INFO]\033[0m  %s %s\n' "$now" "$*"; printf '%s [INFO] %s\n' "$now" "$*" >>"$LOGFILE" 2>/dev/null || true; }
warn() { local now; now=$(date '+%F %T'); printf '\033[33m[WARN]\033[0m  %s %s\n' "$now" "$*" >&2; printf '%s [WARN] %s\n' "$now" "$*" >>"$LOGFILE" 2>/dev/null || true; }
fail() { local now; now=$(date '+%F %T'); printf '\033[31m[ERROR]\033[0m %s %s\n' "$now" "$*" >&2; printf '%s [ERROR] %s\n' "$now" "$*" >>"$LOGFILE" 2>/dev/null || true; exit 1; }

usage() {
    cat <<'EOF'
Usage: volume-migrate-by-codex.sh <disk-image-or-list.txt> [<NFS-staging-directory>]

For a .txt list, put one image filename per line.  Each filename is resolved
under /mnt/cephfs/glance; blank lines and lines beginning with # are ignored.
The selected project, Cinder pool, and migration mode apply to every image.

The NetApp-NFS route automatically maps the selected Cinder pool to its local
mount.  The optional second argument is only for an explicit subdirectory on
that same export; it is rejected if it belongs to another NFS export.

Before running, source the OpenStack RC file that supplies OS_AUTH_URL and the
admin credentials.  The script intentionally does not modify project roles.
EOF
}

require_openstack_auth() {
    [[ -n ${OS_AUTH_URL:-} ]] || fail 'OS_AUTH_URL is unset. Source the OpenStack admin RC file first.'
}

choose_domain() {
    local domains selection
    domains=$(openstack domain list -f json) || fail 'Cannot list OpenStack domains.'
    domains=$(jq '[.[] | select(.Name != "heat")]' <<<"$domains") || fail 'Cannot filter OpenStack domains.'
    mapfile -t DOMAIN_IDS < <(jq -r '.[].ID' <<<"$domains")
    mapfile -t DOMAIN_NAMES < <(jq -r '.[].Name' <<<"$domains")
    ((${#DOMAIN_IDS[@]})) || fail 'No domain found.'

    if ((${#DOMAIN_IDS[@]} == 1)); then
        selection=1
        log 'Only one domain available; selecting it automatically.'
    else
        printf 'Available domains:\n'
        local i
        for i in "${!DOMAIN_IDS[@]}"; do
            printf '%d. %s (%s)\n' "$((i + 1))" "${DOMAIN_NAMES[$i]}" "${DOMAIN_IDS[$i]}"
        done
        read -r -p 'Select domain number: ' selection
        [[ $selection =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#DOMAIN_IDS[@]})) || fail 'Invalid domain selection.'
    fi
    SELECTED_DOMAIN_ID=${DOMAIN_IDS[$((selection - 1))]}
    log "Domain → ${DOMAIN_NAMES[$((selection - 1))]} ($SELECTED_DOMAIN_ID)"
}

choose_project() {
    local projects selection
    projects=$(openstack project list --domain "$SELECTED_DOMAIN_ID" -f json) || fail 'Cannot list OpenStack projects.'
    projects=$(jq '[.[] | select(.Name != "service")]' <<<"$projects") || fail 'Cannot filter OpenStack projects.'
    mapfile -t PROJECT_IDS < <(jq -r '.[].ID' <<<"$projects")
    mapfile -t PROJECT_NAMES < <(jq -r '.[].Name' <<<"$projects")
    ((${#PROJECT_IDS[@]})) || fail 'No project found.'

    if ((${#PROJECT_IDS[@]} == 1)); then
        selection=1
        log 'Only one project available; selecting it automatically.'
    else
        printf 'Available projects:\n'
        local i
        for i in "${!PROJECT_IDS[@]}"; do
            printf '%d. %s (%s)\n' "$((i + 1))" "${PROJECT_NAMES[$i]}" "${PROJECT_IDS[$i]}"
        done
        read -r -p 'Select project number: ' selection
        [[ $selection =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#PROJECT_IDS[@]})) || fail 'Invalid project selection.'
    fi
    OS_PROJECT_DOMAIN_ID=$SELECTED_DOMAIN_ID
    unset OS_PROJECT_DOMAIN_NAME
    export OS_PROJECT_DOMAIN_ID OS_PROJECT_NAME=${PROJECT_NAMES[$((selection - 1))]}
    log "Project → $OS_PROJECT_NAME (${PROJECT_IDS[$((selection - 1))]})"
}

choose_pool() {
    local pools selection pool primary_pool=''
    local -a remaining_pools=()
    pools=$(cinder get-pools 2>/dev/null | awk -F'|' '/\|/ && $2 ~ /name/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); if ($3 != "") print $3}')
    [[ -n $pools ]] || fail 'No Cinder pools returned by cinder get-pools.'
    mapfile -t POOLS < <(printf '%s\n' "$pools")
    for pool in "${POOLS[@]}"; do
        if [[ $pool == cube@ceph#ceph ]]; then
            primary_pool=$pool
        else
            remaining_pools+=("$pool")
        fi
    done
    if [[ -n $primary_pool ]]; then
        POOLS=("$primary_pool" "${remaining_pools[@]}")
    else
        POOLS=("${remaining_pools[@]}")
    fi

    if ((${#POOLS[@]} == 1)); then
        selection=1
        log 'Only one Cinder pool available; selecting it automatically.'
    else
        printf 'Available Cinder pools:\n'
        local i
        for i in "${!POOLS[@]}"; do
            printf '%d. %s\n' "$((i + 1))" "${POOLS[$i]}"
        done
        read -r -p 'Select pool number: ' selection
        [[ $selection =~ ^[0-9]+$ ]] && ((selection >= 1 && selection <= ${#POOLS[@]})) || fail 'Invalid pool selection.'
    fi
    POOL=${POOLS[$((selection - 1))]}
    log "Pool → $POOL"
}

set_backend() {
    if [[ $POOL == *netapp-nfs* ]]; then
        BACKEND=nfs
        VOL_TYPE=netapp-nfs
    elif [[ $POOL == cube@*#* ]]; then
        BACKEND=rbd
        # Cube backends normally expose their Ceph pool after '#'.  The legacy
        # primary Cube backend is the exception: cube@ceph#ceph uses the
        # cinder-volumes RBD pool.
        VOL_POOL=${POOL#*#}
        [[ -n $VOL_POOL && $VOL_POOL != "$POOL" ]] || fail "Selected Cube pool '$POOL' has no Ceph pool suffix."
        [[ $POOL == cube@ceph#ceph ]] && VOL_POOL=cinder-volumes
        set_cube_volume_type
    else
        fail "Unsupported pool '$POOL'. This script supports NetApp NFS and CubeStorage RBD only."
    fi
    if [[ $BACKEND == rbd ]]; then
        log "Backend → $BACKEND; Ceph pool → $VOL_POOL; volume type → $VOL_TYPE"
    else
        log "Backend → $BACKEND; volume type → $VOL_TYPE"
    fi
}

set_cube_volume_type() {
    local types type_name type_key type_key_lower candidate candidate_lower
    local -a matches=()

    # The primary Cube backend is intentionally mapped to its established type.
    if [[ $POOL == cube@ceph#ceph ]]; then
        VOL_TYPE=CubeStorage
        return
    fi

    # Derive the type from the selected Ceph-pool suffix, not extra specs:
    # #manila-volumes -> CubeStorage-Manila and
    # #smarthealth-volumes -> CubeStorage-smarthealth.
    type_key=${VOL_POOL%-volumes}
    [[ -n $type_key ]] || fail "Cannot derive a CubeStorage volume type from Ceph pool '$VOL_POOL'."
    type_key_lower=$(tr '[:upper:]' '[:lower:]' <<<"$type_key")
    types=$(openstack volume type list -f json) || fail 'Cannot list Cinder volume types.'
    while IFS= read -r type_name; do
        candidate=${type_name#CubeStorage-}
        candidate_lower=$(tr '[:upper:]' '[:lower:]' <<<"$candidate")
        if [[ $candidate != "$type_name" && $candidate_lower == "$type_key_lower" ]]; then
            matches+=("$type_name")
        fi
    done < <(jq -r '.[].Name' <<<"$types")

    case ${#matches[@]} in
        1) VOL_TYPE=${matches[0]} ;;
        0) fail "No CubeStorage volume type matches selected Ceph pool '$VOL_POOL' (expected CubeStorage-$type_key)." ;;
        *) fail "Multiple CubeStorage volume types match selected Ceph pool '$VOL_POOL': ${matches[*]}." ;;
    esac
}

choose_migration_type() {
    printf 'Select migration type:\n1. v2v (operating-system conversion)\n2. disk (raw disk import)\n'
    read -r -p 'Enter option number: ' answer
    case $answer in
        1) MIGRATION_TYPE=v2v ;;
        2) MIGRATION_TYPE=disk ;;
        *) fail 'Invalid migration type.' ;;
    esac
}

prepare_nfs_stage() {
    local requested=${1:-} expected_share target source real_stage real_target
    expected_share=${POOL#*#}
    [[ $expected_share != "$POOL" && $expected_share == *:* ]] || fail "Selected NFS pool '$POOL' has no export suffix."
    if [[ -z $requested ]]; then
        requested=$(findmnt -rn -t nfs,nfs4 -o TARGET,SOURCE | awk -v share="$expected_share" '$2 == share {print $1; exit}')
        [[ -n $requested ]] || fail "Selected pool export '$expected_share' is not mounted locally."
    fi
    [[ -n $requested && -d $requested ]] || fail 'NFS staging directory does not exist.'
    target=$(findmnt -rn -o TARGET -T "$requested" 2>/dev/null || true)
    source=$(findmnt -rn -o SOURCE -T "$requested" 2>/dev/null || true)
    [[ -n $target && -n $source ]] || fail "'$requested' is not on a mounted filesystem."
    findmnt -rn -t nfs,nfs4 -T "$requested" >/dev/null || fail "'$requested' is not on NFS."
    [[ $source == *:* ]] || fail "Unexpected NFS export source '$source'."
    [[ $source == "$expected_share" ]] || fail "'$requested' belongs to '$source', but the selected pool requires '$expected_share'."
    real_stage=$(readlink -f "$requested")
    real_target=$(readlink -f "$target")
    [[ $real_stage == "$real_target" || $real_stage == "$real_target"/* ]] || fail 'Staging directory is outside the NFS mount target.'
    NFS_STAGE=$real_stage
    NFS_MOUNT_TARGET=$real_target
    NFS_EXPORT=$source
    log "NFS staging path → $NFS_STAGE (automatically mapped from pool export $NFS_EXPORT)"
}

stage_disk_to_nfs() {
    local base=$1 destination
    destination="$NFS_STAGE/${base}-${TS}.raw"
    [[ ! -e $destination ]] || fail "Refusing to overwrite existing file '$destination'."
    if [[ $FILE_FORMAT == raw ]]; then
        # cp --sparse only preserves holes already present in the source.  qemu-img
        # also detects zero-filled extents and writes them as holes in the raw NFS
        # output, reducing physical allocation without changing guest-visible size.
        log "Converting raw disk to sparse raw on the NFS staging path."
        qemu-img convert -p -f raw -O raw -S 4k -- "$SRC_IMG" "$destination"
    else
        log "Converting $FILE_FORMAT disk to raw on NFS staging path."
        qemu-img convert -p -O raw -- "$SRC_IMG" "$destination"
    fi
    STAGED_DISK=$destination
}

run_v2v_to_dir() {
    local output_dir=$1
    log "Converting $(basename "$SRC_IMG") to raw with virt-v2v."
    # -oa sparse is virt-v2v's default, specified here so sparse NFS output is
    # intentional and not altered by a system-wide/default configuration change.
    LIBGUESTFS_BACKEND=direct virt-v2v -i disk "$SRC_IMG" -o local -of raw -oa sparse -os "$output_dir/" || fail 'virt-v2v failed.'
    if [[ $EXTENSION == vhd || $EXTENSION == vhdx ]]; then
        STAGED_DISK="$output_dir/${BASE_NAME}.${EXTENSION}-sda"
        XML="$output_dir/${BASE_NAME}.${EXTENSION}.xml"
    else
        STAGED_DISK="$output_dir/${BASE_NAME}-sda"
        XML="$output_dir/${BASE_NAME}.xml"
    fi
    [[ -f $STAGED_DISK ]] || fail "virt-v2v output missing: $STAGED_DISK"
}

detect_os() {
    local inspect_path=$1
    DISTRO=$(virt-inspector -a "$inspect_path" 2>/dev/null | xmllint --xpath 'normalize-space(//distro)' - 2>/dev/null || true)
}

set_common_metadata() {
    local volume=$1
    cinder image-metadata "$volume" set disk_format=raw hw_machine_type=q35
    if [[ $DISTRO == *windows* ]]; then
        cinder image-metadata "$volume" set os_type=windows
    else
        cinder image-metadata "$volume" set os_type=linux
    fi
    if [[ $MIGRATION_TYPE == v2v ]]; then
        cinder image-metadata "$volume" set hw_qemu_guest_agent=True hw_video_model=vga hw_scsi_model=virtio-scsi hw_vif_model=virtio hw_input_bus=virtio hw_disk_bus=virtio
        if [[ -f ${XML:-} ]] && grep -q "<os firmware='efi'" "$XML"; then
            cinder image-metadata "$volume" set hw_firmware_type=uefi os_secure_boot=optional
        else
            cinder image-metadata "$volume" set hw_firmware_type=bios
        fi
    fi
}

manage_nfs_volume() {
    local relative
    relative=${STAGED_DISK#"$NFS_MOUNT_TARGET"/}
    [[ $relative != "$STAGED_DISK" ]] || fail 'Cannot calculate the NFS export-relative path.'
    NFS_REFERENCE="$NFS_EXPORT/$relative"
    VOL_NAME="${BASE_NAME}-${TS}"
    log "Managing NFS file '$NFS_REFERENCE' as '$VOL_NAME'."
    cinder manage --bootable --volume-type "$VOL_TYPE" --name "$VOL_NAME" "$POOL" "$NFS_REFERENCE" || fail 'Cinder NFS manage failed; the staged file is retained for investigation.'
}

manage_rbd_volume() {
    local rbd_name
    rbd_name="${BASE_NAME}-import-${TS}"
    if [[ $MIGRATION_TYPE == disk && $FILE_FORMAT != raw ]]; then
        log "Converting image directly into RBD: $VOL_POOL/$rbd_name"
        qemu-img convert -p -O raw "$SRC_IMG" "rbd:$VOL_POOL/$rbd_name" || fail 'qemu-img RBD conversion failed.'
    else
        log "Importing raw disk into RBD: $VOL_POOL/$rbd_name"
        rbd --id cinder import "$STAGED_DISK" "$VOL_POOL/$rbd_name" || fail 'RBD import failed.'
    fi
    VOL_NAME="${BASE_NAME}-${TS}"
    log "Managing RBD image as '$VOL_NAME'."
    cinder manage --bootable --volume-type "$VOL_TYPE" --name "$VOL_NAME" "$POOL" "$rbd_name" || fail 'Cinder RBD manage failed.'
}

wait_for_managed_volume() {
    local volume_id=$1 status deadline
    # `cinder manage` only queues an asynchronous request.  For RBD, the Cinder
    # driver renames the source image to volume-<UUID> while processing it.
    deadline=$(( $(date +%s) + MANAGE_WAIT_SECONDS ))
    while :; do
        status=$(openstack volume show "$volume_id" -f value -c status 2>/dev/null || true)
        case $status in
            available)
                log "Managed volume is available."
                return 0
                ;;
            error|error_managing)
                fail "Cinder failed to manage volume $volume_id (status: $status). The source backend object was retained."
                ;;
        esac
        (( $(date +%s) < deadline )) || fail "Timed out after ${MANAGE_WAIT_SECONDS}s waiting for Cinder to manage volume $volume_id (last status: ${status:-unknown})."
        sleep 2
    done
}

load_sources() {
    local requested=$1 entry
    SOURCE_IMAGES=()
    if [[ $requested == *.txt ]]; then
        [[ -f $requested ]] || fail "List file not found: $requested"
        while IFS= read -r entry || [[ -n $entry ]]; do
            entry=${entry%$'\r'}
            [[ -z $entry || $entry == \#* ]] && continue
            [[ $entry != */* && $entry != . && $entry != .. ]] || fail "List entry must be a filename under $GLANCE_DIR: $entry"
            [[ -f $GLANCE_DIR/$entry ]] || fail "Listed image not found: $GLANCE_DIR/$entry"
            SOURCE_IMAGES+=("$GLANCE_DIR/$entry")
        done <"$requested"
        ((${#SOURCE_IMAGES[@]})) || fail "No image filenames found in list: $requested"
        log "Loaded ${#SOURCE_IMAGES[@]} image(s) from $requested."
    else
        [[ -f $requested ]] || fail "File not found: $requested"
        SOURCE_IMAGES=("$requested")
    fi
}

migrate_image() {
    SRC_IMG=$1
    FILE_FORMAT=$(qemu-img info --output=json "$SRC_IMG" | jq -r '.format')
    [[ $FILE_FORMAT != null && -n $FILE_FORMAT ]] || fail "Cannot determine source image format: $SRC_IMG"
    IMG_NAME=$(basename "$SRC_IMG")
    BASE_NAME=${IMG_NAME%.*}; [[ $BASE_NAME != "$IMG_NAME" ]] || BASE_NAME=$IMG_NAME
    EXTENSION=${IMG_NAME##*.}; [[ $EXTENSION != "$IMG_NAME" ]] || EXTENSION=''
    TS=$(date +%Y%m%d-%H%M%S)
    if ((${#SOURCE_IMAGES[@]} > 1)); then TS+="-${MIGRATION_INDEX}"; fi
    log "Source: $SRC_IMG (format $FILE_FORMAT)"

    XML=''
    if [[ $BACKEND == nfs ]]; then
        if [[ $MIGRATION_TYPE == disk ]]; then stage_disk_to_nfs "$BASE_NAME"; else run_v2v_to_dir "$NFS_STAGE"; fi
        detect_os "$STAGED_DISK"
        manage_nfs_volume
    else
        if [[ $MIGRATION_TYPE == disk ]]; then
            STAGED_DISK=$SRC_IMG
        else
            run_v2v_to_dir "$DEFAULT_OUTDIR"
        fi
        detect_os "$STAGED_DISK"
        manage_rbd_volume
    fi

    VOL_ID=$(openstack volume show "$VOL_NAME" -f value -c id) || fail 'Managed volume was created but could not be looked up.'
    wait_for_managed_volume "$VOL_ID"
    set_common_metadata "$VOL_NAME"
    if [[ $BACKEND == rbd ]]; then rbd du "$VOL_POOL/volume-$VOL_ID" || warn 'rbd du failed.'; fi
    openstack volume show "$VOL_NAME" -f json | jq '.volume_image_metadata'
    log "Migration completed: $VOL_NAME (ID: $VOL_ID)"
}

main() {
    local requested_source image
    requested_source=${1:-}
    NFS_ARGUMENT=${2:-}
    [[ -n $requested_source ]] || { usage >&2; exit 2; }
    mkdir -p "$(dirname "$LOGFILE")"; touch "$LOGFILE" 2>/dev/null || warn "Cannot write $LOGFILE"
    require_openstack_auth
    load_sources "$requested_source"

    choose_domain
    choose_project
    choose_pool
    set_backend
    choose_migration_type

    if [[ $BACKEND == nfs ]]; then
        prepare_nfs_stage "$NFS_ARGUMENT"
    else
        if [[ $MIGRATION_TYPE == v2v ]]; then
            mkdir -p "$DEFAULT_OUTDIR"
        fi
    fi

    MIGRATION_INDEX=0
    for image in "${SOURCE_IMAGES[@]}"; do
        ((MIGRATION_INDEX += 1))
        migrate_image "$image"
    done
    log "All ${#SOURCE_IMAGES[@]} migration(s) completed."
}

main "$@"
