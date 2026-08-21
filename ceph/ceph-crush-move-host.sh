#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 HOSTNAME DESTINATION_CRUSH" >&2
  echo "Example: $0 ak-coscp51p smarthealth" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage

crush_host=$1
destination_root=$2

for value in "$crush_host" "$destination_root"; do
  if [[ ! $value =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid host or CRUSH root name: $value" >&2
    exit 2
  fi
done

command -v ceph >/dev/null || {
  echo "ceph CLI is required." >&2
  exit 1
}

echo "Checking CRUSH host and destination root..."
crush_tree=$(ceph osd crush tree)

grep -Eq "host[[:space:]]+${crush_host}([[:space:]]|$)" <<<"$crush_tree" || {
  echo "CRUSH host not found: $crush_host" >&2
  exit 1
}

grep -Eq "root[[:space:]]+${destination_root}([[:space:]]|$)" <<<"$crush_tree" || {
  echo "Destination CRUSH root not found: $destination_root" >&2
  exit 1
}

echo
echo "OSDs under host ${crush_host}:"
awk -v host="$crush_host" '
  $0 ~ "host[[:space:]]+" host "([[:space:]]|$)" { found=1; print; next }
  found && $0 ~ /host|root/ { exit }
  found { print }
' <<<"$crush_tree"

echo
ceph -s
echo
read -r -p "Move ${crush_host} to root=${destination_root}? [y/N] " answer
[[ $answer == y || $answer == Y ]] || {
  echo "Cancelled."
  exit 0
}

ceph osd crush move "$crush_host" "root=${destination_root}"

echo
echo "Move completed. Verifying CRUSH tree and cluster health..."
ceph osd crush tree
ceph -s