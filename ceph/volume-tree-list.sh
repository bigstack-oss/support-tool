#!/bin/bash
set -euo pipefail
source /etc/admin-openrc.sh
# Usage check
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <main_volume_uuid>"
  exit 1
fi

POOL="cinder-volumes"

# Return: "<USED_NUM> <USED_UNIT>"  (e.g. "300 MiB", "2.4 GiB")
get_rbd_used() {
  local rbd_spec="$1"    # e.g. cinder-volumes/volume-xxx or ...@snapshot-yyy
  local match_name="$2"  # e.g. volume-xxx or volume-xxx@snapshot-yyy

  rbd du "$rbd_spec" 2>/dev/null | awk -v name="$match_name" '
    NR > 1 && $1 == name {
      print $(NF-1), $NF
      found=1
      exit
    }
    END { if (!found) exit 1 }
  '
}

#   Disk Size: <TOTAL PROVISIONED>, Total Usage: <TOTAL USED>
print_total_line() {
  local vol_name="$1" 

  local out
  out=$(rbd du "${POOL}/${vol_name}" 2>/dev/null || true)

  local disk_size total_used
  disk_size=$(echo "$out" | awk '$1=="<TOTAL>" {print $(NF-3), $(NF-2)}')
  total_used=$(echo "$out" | awk '$1=="<TOTAL>" {print $(NF-1), $NF}')

  echo "Disk Size: ${disk_size:-N/A}, Total Usage: ${total_used:-N/A}"
}

# Recursive snapshot / child volume tree
list_snapshots_and_children() {
  local volume="$1"   
  local indent="$2"

  local snapshots
  snapshots=$(rbd snap ls "${POOL}/${volume}" 2>/dev/null | awk 'NR>1 {print $2}' || true)

  for snapshot in $snapshots; do
    local snapshot_id snapshot_name children children_count snap_used

    snapshot_id="${snapshot#snapshot-}"
    snapshot_name=$(openstack volume snapshot show "$snapshot_id" -c name -f value 2>/dev/null || echo "N/A")

    children=$(rbd children "${POOL}/${volume}@${snapshot}" 2>/dev/null || true)
    children_count=$(echo "$children" | awk 'NF{c++} END{print c+0}')

    snap_used=$(get_rbd_used \
      "${POOL}/${volume}@${snapshot}" \
      "${volume}@${snapshot}" || echo "N/A")

    echo "${indent}└── ${snapshot} (${children_count} volume), snapshot name: ${snapshot_name}, usage: ${snap_used}"

    for child in $children; do
      local vol_name vol_uuid status vol_used

      vol_name=$(basename "$child")          
      vol_uuid="${vol_name#volume-}"

      status=$(openstack volume show "$vol_uuid" -c status -f value 2>/dev/null || true)
      if [ -z "$status" ]; then
        echo "${indent}    └── ${vol_name} (Volume does not exist)"
        continue
      fi

      vol_used=$(get_rbd_used \
        "${POOL}/${vol_name}" \
        "${vol_name}" || echo "N/A")

      echo "${indent}    └── ${vol_name} (${status}), usage: ${vol_used}"

      if [ "$status" = "in-use" ]; then
        local vol_json server_id server_json server_name server_status project_id project_name

        vol_json=$(openstack volume show "$vol_uuid" -f json)
        server_id=$(echo "$vol_json" | jq -r '.attachments[0].server_id // empty')

        if [ -n "$server_id" ]; then
          server_json=$(openstack server show "$server_id" -f json)
          server_name=$(echo "$server_json" | jq -r '.name')
          server_status=$(echo "$server_json" | jq -r '.status')
          project_id=$(echo "$server_json" | jq -r '.project_id')
          project_name=$(openstack project show "$project_id" -c name -f value 2>/dev/null || echo "N/A")

          echo "${indent}        └── server_id: ${server_id} (${server_name}), server_status: ${server_status}, project_id: ${project_id} (${project_name})"
        fi
      fi

      # recursive dive
      list_snapshots_and_children "$vol_name" "${indent}        "
    done
  done
}

# Main volume
VID="$1"
MAIN_VOL="volume-${VID}"

# Print total (disk size + total usage) based on `rbd du <volume>`
print_total_line "$MAIN_VOL"

main_status=$(openstack volume show "$VID" -c status -f value 2>/dev/null || echo "unknown")
main_used=$(get_rbd_used \
  "${POOL}/${MAIN_VOL}" \
  "${MAIN_VOL}" || echo "N/A")

if [ "$main_status" = "in-use" ]; then
  vol_json=$(openstack volume show "$VID" -f json)
  server_id=$(echo "$vol_json" | jq -r '.attachments[0].server_id // empty')

  if [ -n "$server_id" ]; then
    server_json=$(openstack server show "$server_id" -f json)
    server_name=$(echo "$server_json" | jq -r '.name')
    server_status=$(echo "$server_json" | jq -r '.status')
    project_id=$(echo "$server_json" | jq -r '.project_id')
    project_name=$(openstack project show "$project_id" -c name -f value 2>/dev/null || echo "N/A")

    echo "${MAIN_VOL} (${main_status}), usage: ${main_used} - server_id: ${server_id} (${server_name}), server_status: ${server_status}, project_id: ${project_id} (${project_name})"
  else
    echo "${MAIN_VOL} (${main_status}), usage: ${main_used}"
  fi
else
  echo "${MAIN_VOL} (${main_status}), usage: ${main_used}"
fi

# Start tree
list_snapshots_and_children "$MAIN_VOL" ""