#!/usr/bin/env bash
set -o pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/admin-openrc.sh

LOG_FILE="/var/log/support-fix-disk.log"
DATE_FMT="+%F %T"

log() {
    echo "[$(date "$DATE_FMT")] $*" | tee -a "$LOG_FILE"
}

log "===== Start support volume status cleanup ====="

openstack volume list --all-project -f json 2>>"$LOG_FILE" \
| jq -r '
    .[]
    | select(.Status != "available" and .Status != "in-use")
    | [.ID, .Status]
    | @tsv
' \
| while IFS=$'\t' read -r ID STATE; do
    log "Processing volume ID=$ID current_status=$STATE"

    if openstack volume set \
        --state available \
        --description "support-fix-disk-status-${STATE}" \
        "$ID" >>"$LOG_FILE" 2>&1; then
        log "SUCCESS volume ID=$ID fixed from status=$STATE"
    else
        log "ERROR volume ID=$ID failed to update"
    fi
done

log "===== End support volume status cleanup ====="