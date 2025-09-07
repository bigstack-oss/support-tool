#!/usr/bin/env bash
set -euo pipefail
# --- Timestamped log file ---
LOGDIR="/var/log"
LOGFILE="$LOGDIR/support-fip-list-$(date +%Y%m%d-%H%M%S).log"

# Redirect all stdout + stderr to the logfile
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== Floating IP Report generated at $(date) ==="
echo "Logfile: $LOGFILE"
echo

# --- Helper caches ---
declare -A NET_NAME_CACHE

get_network_name() {
  local net_id="$1"
  if [[ -z "${NET_NAME_CACHE[$net_id]+x}" ]]; then
    NET_NAME_CACHE["$net_id"]="$(openstack network show "$net_id" -c name -f value 2>/dev/null || echo "<unknown>")"
  fi
  printf '%s' "${NET_NAME_CACHE[$net_id]}"
}

# --- Step 1: collect unique Project IDs that have at least one Floating IP ---
readarray -t PROJECT_IDS < <(openstack floating ip list -f json \
  | jq -r '.[].Project' | sort -u)

# --- Iterate per Project ---
for PROJECT_ID in "${PROJECT_IDS[@]}"; do
  PROJECT_NAME="$(openstack project show "$PROJECT_ID" -c name -f value 2>/dev/null || echo "<unknown>")"

  FIP_JSON="$(openstack floating ip list --project="$PROJECT_ID" -f json)"
  TOTAL_FIPS="$(jq 'length' <<<"$FIP_JSON")"

  printf 'Project: %s (%s) Total Floating IPs allocated: %s\n' "$PROJECT_NAME" "$PROJECT_ID" "$TOTAL_FIPS"

  readarray -t NET_IDS < <(jq -r '.[]."Floating Network"' <<<"$FIP_JSON" | sort -u | awk 'NF')

  if [[ "${#NET_IDS[@]}" -eq 0 ]]; then
    echo "  (No Floating IPs)"
    echo
    continue
  fi

  for NET_ID in "${NET_IDS[@]}"; do
    COUNT_IN_NET="$(jq --arg net "$NET_ID" '[.[] | select(."Floating Network"==$net)] | length' <<<"$FIP_JSON")"
    NET_NAME="$(get_network_name "$NET_ID")"

    printf '  Network: %s (%s) Floating IPs allocated: %s\n' "$NET_NAME" "$NET_ID" "$COUNT_IN_NET"

    IFS=$'\n' read -r -d '' -a FIP_LINES < <(jq -r --arg net "$NET_ID" \
      '.[] | select(."Floating Network"==$net)
       | "\(.["Floating IP Address"] // "")|\(.ID // "")|\(.["Fixed IP Address"] // "")"' \
      <<<"$FIP_JSON" && printf '\0')

    idx=1
    for line in "${FIP_LINES[@]}"; do
      IFS='|' read -r FIP_ADDR FIP_ID FIXED_IP <<<"$line"
      if [[ -n "${FIXED_IP// }" ]]; then
        printf '    %d. %s (%s) attached to %s\n' "$idx" "$FIP_ADDR" "$FIP_ID" "$FIXED_IP"
      else
        printf '    %d. %s (%s) detached\n' "$idx" "$FIP_ADDR" "$FIP_ID"
      fi
      idx=$((idx+1))
    done
  done

  echo
done