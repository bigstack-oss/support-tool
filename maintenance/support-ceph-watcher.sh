#!/usr/bin/env bash
set -o pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG_FILE="/var/log/support-ceph-watcher.log"
DATE_FMT="+%F %T"

log() {
    echo "[$(date "$DATE_FMT")] $*" | tee -a "$LOG_FILE"
}

HOST="${HOSTNAME:-$(hostname -s)}"

# 要監控的 Ceph services
SERVICES=(
  "ceph-mgr@${HOST}.service"
  "ceph-mon@${HOST}.service"
  "ceph-mds@${HOST}.service"
)

check_and_fix_service() {
    local svc="$1"

    state="$(systemctl is-active "$svc" 2>>"$LOG_FILE" || true)"
    
    if [[ "$state" == "active" ]]; then
        log "INFO: ${svc} is ${state}"
        return 0
    else
        log "WARN: ${svc} is NOT active. Restarting..."
    fi

    systemctl restart "$svc" >>"$LOG_FILE" 2>&1 || log "ERROR: restart command failed for ${svc}"

    # wait + recheck（最多 5 次，每次 2 秒）
    for i in {1..5}; do
        sleep 5
        state2="$(systemctl is-active "$svc" 2>>"$LOG_FILE" || true)"
        log "Recheck ${svc} #$i: ${state2}"
        if [[ "$state2" == "active" ]]; then
            log "SUCCESS: ${svc} is active after restart."
            return 0
        fi
    done

    log "ERROR: ${svc} still NOT active after restart attempts."
    systemctl status "$svc" --no-pager >>"$LOG_FILE" 2>&1 || true
    journalctl -u "$svc" -n 80 --no-pager >>"$LOG_FILE" 2>&1 || true
    return 1
}

for svc in "${SERVICES[@]}"; do
    check_and_fix_service "$svc"
done