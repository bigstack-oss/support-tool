#!/bin/bash
# Replace a VM's floating IP with a chosen address. If NEW_FIP can't be created, the old one is re-attached.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") SERVER_ID NEW_FIP

Replace the floating IP of a server (single port) with NEW_FIP.
  - NEW_FIP is created in the server's project, on the same external network as the old FIP
  - NEW_FIP is tagged RESERVED so the CMP cleanup job won't reap it
  - the old FIP is released (deleted) on success, re-attached on failure

Requires admin openrc (e.g. source /etc/admin-openrc.sh).

Example:
  $(basename "$0") 185f90f3-ace4-4aa1-9e5c-1f33e5eba318 10.32.19.22
EOF
  exit "${1:-0}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[ $# -eq 2 ] || usage 1
SRV=$1 NEW=$2

PORT=$(openstack port list --server "$SRV" -f value -c ID)
[ -n "$PORT" ] && [ "$(echo "$PORT" | wc -l)" -eq 1 ] || { echo "expected 1 port on $SRV, got: $PORT" >&2; exit 1; }
OLD=$(openstack floating ip list --port "$PORT" -f value -c "Floating IP Address")
[ -n "$OLD" ] || { echo "no FIP on port $PORT" >&2; exit 1; }
[ "$OLD" != "$NEW" ] || { echo "already $NEW"; exit 0; }
EXTNET=$(openstack floating ip show "$OLD" -f value -c floating_network_id)
PROJECT=$(openstack server show "$SRV" -f value -c project_id)

echo "$SRV: $OLD -> $NEW (port $PORT, project $PROJECT)"
openstack floating ip set --tag RESERVED "$OLD"   # CMP cleanup job deletes untagged detached FIPs within ~60s
openstack floating ip unset --port "$OLD"
if openstack floating ip create --floating-ip-address "$NEW" --port "$PORT" --project "$PROJECT" "$EXTNET" >/dev/null; then
  openstack floating ip set --tag RESERVED "$NEW"
  openstack floating ip delete "$OLD"
  echo "done: $SRV now $NEW"
else
  echo "create $NEW failed, re-attaching $OLD" >&2
  openstack floating ip set --port "$PORT" "$OLD"
  openstack floating ip unset --tag RESERVED "$OLD"
  exit 1
fi
