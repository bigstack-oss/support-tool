#!/usr/bin/env bash
set -euo pipefail
# ssh host / IP of target Ceph cluster
DST_HOST="10.32.10.190"
SRC_POOL="glance-images"
DST_POOL="glance-images"
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=6"

echo "=== Start RBD streaming migration ==="
echo "Source pool: $SRC_POOL"
echo "Target host: $DST_HOST"
echo "Target pool: $DST_POOL"
echo
for IMG in $(rbd ls "$SRC_POOL"); do
  echo ">>> Processing image: $IMG"
  if ! rbd snap ls "$SRC_POOL/$IMG" >/dev/null 2>&1; then
    echo "WARN: $IMG has no snapshots (still migrating)"
  fi
  if ssh $SSH_OPTS "$DST_HOST" "rbd ls $DST_POOL | grep -qx '$IMG'"; then
    echo "ERROR: $DST_POOL/$IMG already exists on $DST_HOST"
    echo "       Please remove it first to preserve snapshots"
    exit 1
  fi

  echo "Streaming export/import for $IMG ..."
  rbd export \
    --export-format 2 \
    "$SRC_POOL/$IMG" \
    - \
  | ssh $SSH_OPTS "$DST_HOST" \
    "rbd import --export-format 2 --image-format 2 - $DST_POOL/$IMG"

  echo "OK: $IMG migrated"
  echo
done

echo "=== All images completed successfully ==="