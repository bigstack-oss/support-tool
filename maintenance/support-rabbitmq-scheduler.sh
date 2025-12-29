#!/usr/bin/env bash
set -euo pipefail

# ---- Configuration & Environment ----
# Ensure cron has the correct PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SERVICE="rabbitmq"
LOG_FILE="/var/log/support-rabbitmq-scheduler.log"
LOCK_FILE="/var/run/rabbitmq-fix.lock"
MATTERMOST_WEBHOOK="https://matter.nchc.org.tw/hooks/HOOKME"
MY_HOSTNAME=$(hostname)

# ---- Locking Mechanism ----
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date '+%F %T')] Script is already running. Exiting." >> $LOG_FILE
  exit 1
fi

# ---- Functions ----
ts() { date '+%F %T'; }

log() {
  local msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(ts)] $msg" | tee -a "$LOG_FILE" >/dev/null
}

mm_notify() {
  local level="${1:-info}"
  shift
  local message="$*"

  # Skip if curl/jq missing or webhook empty
  [[ -z "$MATTERMOST_WEBHOOK" ]] && return 0

  local emoji
  case "$level" in
    info)    emoji="ℹ️" ;;
    warn)    emoji="⚠️" ;;
    error)   emoji="❌" ;;
    success) emoji="✅" ;;
    *)       emoji="💬" ;;
  esac

  local text
  if [[ "$message" =~ ^\`\`\` ]]; then
    text="$message"
  else
    text="$emoji [$level] $(date '+%F %T') - $message"
  fi

  jq -nc \
    --arg user "$MY_HOSTNAME" \
    --arg text "$text" \
    '{username: $user, text: $text}' \
  | curl -sSf -X POST \
      -H 'Content-type: application/json' \
      --data @- \
      "$MATTERMOST_WEBHOOK" \
      >/dev/null 2>&1 || true
}

# ---- Pre-flight Checks ----
VIP_NODE=$(/usr/sbin/pcs status 2>/dev/null | awk '/vip/ && /Started/ {print $(NF)}' || echo "")

if [[ -z "$VIP_NODE" ]]; then
    log "Error: Could not determine VIP node. Is Pacemaker running?"
    exit 1
fi

if [[ "$MY_HOSTNAME" != "$VIP_NODE" ]]; then
  log "Skip: VIP is on '$VIP_NODE', current host is '$MY_HOSTNAME'."
  exit 0
fi

# ---- Execution ----
log "VIP is running on this host ($MY_HOSTNAME). Starting maintenance."
mm_notify info "vip" "開始定期檢修服務 - RabbitMQ (VIP owner: $MY_HOSTNAME)"

# Step 1: Cluster Clean & Restart
log "step1 Restarting $SERVICE sequence..."
mm_notify info "step1" "清除 RabbitMQ 狀態並重啟服務"

/usr/local/bin/cubectl node -r control exec -p rm -rf /var/lib/rabbitmq/mnesia/*
/usr/local/bin/cubectl node -r control exec -p rm -f /etc/appliance/state/rabbitmq_cluster_done
/usr/local/bin/cubectl node -r control exec -p systemctl stop rabbitmq-server

mapfile -t NODES < <(/usr/local/bin/cubectl node list -r control | awk -F',' '{print $1}')
for node in "${NODES[@]}"; do
    log "Restarting rabbitmq on $node..."
    ssh -n "${node}" "hex_config restart_rabbitmq"
done

# Health Check
mm_notify info "step2" "執行 hex_sdk health_rabbitmq_check"
log "step2 執行 hex_sdk health_rabbitmq_check"

set +e
hex_sdk health_rabbitmq_check
HC_RC=$?
set -e

if [[ "$HC_RC" -ne 0 ]]; then
  log "Health check failed (RC: $HC_RC)"
  mm_notify error "step3" "RabbitMQ health check failed (rc=$HC_RC). Aborting repair."
  log "step3 RabbitMQ health check failed (rc=$HC_RC). Aborting repair."
  exit "$HC_RC"
fi

mm_notify success "step3" "RabbitMQ health check OK"
log "step3 RabbitMQ health check OK"

# Repair & Status Report
mm_notify info "step4" "執行 cluster check_repair"
log "step4 執行 cluster check_repair"
/usr/sbin/hex_cli -c cluster check_repair

CHECK_OUTPUT=$(/usr/sbin/hex_cli -c cluster check 2>&1 || echo "Check command failed")
mm_notify info "\`\`\` $CHECK_OUTPUT \`\`\`"

mm_notify success "done" "RabbitMQ 定期檢修完成"
log "Maintenance completed successfully."