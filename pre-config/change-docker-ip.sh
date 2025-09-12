#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
LOGFILE="/var/log/support-change-docker-ip.log"

error_exit() {
  local msg="${1:-Unknown error}"
  echo "❌ $msg" >&2
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $msg" >> "$LOGFILE"
  exit 1
}

log_info() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: $1" >> "$LOGFILE"
}

trap 'error_exit "Unexpected error at line $LINENO"' ERR

# ------------------------------------------------------------
# Step 1: Copy daemon.json
# ------------------------------------------------------------
log_info "Copying daemon.json to /etc/docker/daemon.json"
cp ./daemon.json /etc/docker/daemon.json || error_exit "Failed to copy daemon.json"

# ------------------------------------------------------------
# Step 2: Start Docker
# ------------------------------------------------------------
log_info "Starting Docker service"
systemctl start docker || error_exit "Failed to start Docker"

# ------------------------------------------------------------
# Step 3: Wait for docker0
# ------------------------------------------------------------
log_info "Waiting for docker0 interface"
sleep 3

# ------------------------------------------------------------
# Step 4: Compare docker0 IP with configured bip
# ------------------------------------------------------------
docker_ip=$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
config_ip=$(jq -r '.bip' /etc/docker/daemon.json 2>/dev/null | cut -d/ -f1)

if [[ -z "$docker_ip" ]]; then
  error_exit "docker0 interface not found or has no IP."
fi

ip a show docker0

if [[ "$docker_ip" == "$config_ip" ]]; then
  echo "✅ docker0 IP ($docker_ip) matches configured bip ($config_ip)."
  log_info "docker0 IP ($docker_ip) matches configured bip ($config_ip)"
else
  echo "⚠️ docker0 IP ($docker_ip) does NOT match configured bip ($config_ip)."
  log_info "docker0 IP ($docker_ip) does NOT match configured bip ($config_ip)"
fi

# ------------------------------------------------------------
# Step 5: Stop docker.socket
# ------------------------------------------------------------
log_info "Stopping docker.socket (if active)"
systemctl stop docker.socket 2>/dev/null || true

# ------------------------------------------------------------
# Step 6: Done
# ------------------------------------------------------------
echo "✔ Ready. You may start cluster setup."