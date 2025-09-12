#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
LOGFILE="/var/log/support-change-router-ip.log"

error_exit() {
  local msg="${1:-Unknown error}"
  echo "Error: $msg" >&2
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $msg" >> "$LOGFILE"
  exit 1
}

log_info() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: $1" >> "$LOGFILE"
}

# Log unexpected errors with line number
trap 'error_exit "Unexpected error at line $LINENO"' ERR

validate_ip() {
  local ip=$1
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  [[ $a -le 255 && $b -le 255 && $c -le 255 && $d -le 255 ]]
}

# Function to convert IP to integer
ip_to_int() {
  local IFS=. i1 i2 i3 i4
  read -r i1 i2 i3 i4 <<< "$1"
  let "ip_int = (i1 << 24) + (i2 << 16) + (i3 << 8) + i4"
  echo "$ip_int"
}

# Function to convert integer back to IP
int_to_ip() {
  local int=$1
  printf '%d.%d.%d.%d\n' \
    $(( (int >> 24) & 255 )) \
    $(( (int >> 16) & 255 )) \
    $(( (int >> 8) & 255 )) \
    $(( int & 255 ))
}

# ------------------------------------------------------------
# Fetch data
# ------------------------------------------------------------
log_info "Fetching routers and projects..."
routers_json="$(openstack router list --long -f json)"
projects_json="$(openstack project list -f json)"

# Build a combined table (one entry per external_fixed_ip)
combined_json="$(jq -n \
  --argjson routers "$routers_json" \
  --argjson projects "$projects_json" '
  ($projects | INDEX(.[]; .ID)) as $pmap
  |
  [ $routers[] as $r
    | ($r["External gateway info"].external_fixed_ips // [])[]
    | {
        router_id:   $r.ID,
        router_name: $r.Name,
        project_id:  $r.Project,
        project_name: ($pmap[$r.Project].Name // "UNKNOWN"),
        network_id:  $r["External gateway info"].network_id,
        subnet_id:   .subnet_id,
        ip:          .ip_address
      }
  ]' )"

if [[ "$(jq 'length' <<<"$combined_json")" -eq 0 ]]; then
  error_exit "No routers with external_fixed_ips found."
fi

count_entries="$(jq 'length' <<<"$combined_json")"
log_info "Found $count_entries router external IP entries."

# ------------------------------------------------------------
# Step 1: Show numbered list
# ------------------------------------------------------------
echo "Which router IP do you want to change?"
menu="$(jq -r 'to_entries[] | "\(.key+1). \(.value.ip), \(.value.router_name), \(.value.project_name)(\(.value.project_id))"' <<<"$combined_json")"
echo "$menu"

# ------------------------------------------------------------
# Step 2: Ask for number or IP address to change
# ------------------------------------------------------------
read -rp "Enter the NUMBER or IP address you want to change: " selection

length="$(jq 'length' <<<"$combined_json")"

if [[ "$selection" =~ ^[0-9]+$ ]]; then
  # User chose by number
  idx=$((selection-1))
  if (( idx < 0 || idx >= length )); then
    error_exit "Selection $selection is out of range (1..$length)."
  fi
  match="$(jq --argjson i "$idx" '.[ $i ]' <<<"$combined_json")"
  target_ip="$(jq -r '.ip' <<<"$match")"
  log_info "Selected by index: $selection -> IP $target_ip"
else
  # User entered an IP
  target_ip="$selection"
  if ! validate_ip "$target_ip"; then
    error_exit "Invalid IP format: $target_ip"
  fi
  match="$(jq --arg ip "$target_ip" 'map(select(.ip == $ip)) | .[0] // {}' <<<"$combined_json")"
  log_info "Selected by IP: $target_ip"
fi

if [[ "$(jq 'length' <<<"$match")" -eq 0 ]]; then
  error_exit "Could not find a router entry for '$selection'."
fi

router_name="$(jq -r '.router_name' <<<"$match")"
project_name="$(jq -r '.project_name' <<<"$match")"
project_id="$(jq -r '.project_id' <<<"$match")"
network_id="$(jq -r '.network_id' <<<"$match")"
subnet_id="$(jq -r '.subnet_id' <<<"$match")"
router_id="$(jq -r '.router_id' <<<"$match")"

echo "Selected: $target_ip, $router_name, $project_name($project_id)"
echo "Network: $network_id  Subnet: $subnet_id"
log_info "Target entry: router=$router_name($router_id), project=$project_name($project_id), network=$network_id, subnet=$subnet_id, ip=$target_ip"

# ------------------------------------------------------------
# Step 3: Print available IPs in the subnet
# ------------------------------------------------------------
echo "Checking available IPs in subnet $subnet_id..."
log_info "Fetching allocation pools and used IPs for subnet $subnet_id"

# Get allocation pool start/end
subnet_json="$(openstack subnet show "$subnet_id" -f json)"
pool_start="$(jq -r '.allocation_pools[0].start' <<<"$subnet_json")"
pool_end="$(jq -r '.allocation_pools[0].end' <<<"$subnet_json")"

if [[ -z "${pool_start:-}" || -z "${pool_end:-}" || "$pool_start" == "null" || "$pool_end" == "null" ]]; then
  error_exit "Unable to determine allocation pool for subnet $subnet_id"
fi

# Collect used IPs from this subnet
used_ips="$(openstack port list --network "$network_id" -c "Fixed IP Addresses" -f json \
  | jq -r --arg subnet "$subnet_id" '
      .[]
      | .["Fixed IP Addresses"][]?
      | select(.subnet_id == $subnet)
      | .ip_address
  ' | sort -V)"

start_int=$(ip_to_int "$pool_start")
end_int=$(ip_to_int "$pool_end")

# Build set of used IPs as integers
declare -A used_map=()
while IFS= read -r ip; do
  [[ -n "$ip" ]] && used_map[$(ip_to_int "$ip")]=1
done <<<"$used_ips"

# Iterate over pool range, collect available IPs
available_ips=()
for ((i=start_int; i<=end_int; i++)); do
  if [[ -z "${used_map[$i]:-}" ]]; then
    available_ips+=("$(int_to_ip "$i")")
  fi
done

# Print available IPs as a numbered list in 4 columns
if [[ ${#available_ips[@]} -eq 0 ]]; then
  log_info "No available IPs in subnet $subnet_id"
  echo "No available IPs in subnet $subnet_id"
else
  echo "Available IPs:"
  cols=4
  for i in "${!available_ips[@]}"; do
    num=$((i+1))
    printf "%-4s %-18s" "$num." "${available_ips[$i]}"
    # newline after every 4th item
    if (( (num % cols) == 0 )); then
      echo
    fi
  done
  # final newline if not already ended cleanly
  (( ${#available_ips[@]} % cols )) && echo
  log_info "Available IPs count: ${#available_ips[@]}"
fi

# ------------------------------------------------------------
# Find the port on the external network with this fixed IP
# ------------------------------------------------------------
log_info "Looking up port on network $network_id for IP $target_ip"
ports_json="$(openstack port list --long --network "$network_id" -f json)"

port_id="$(jq -r --arg ip "$target_ip" '
  .[] | select(."Fixed IP Addresses"[]?.ip_address == $ip) | .ID' <<<"$ports_json" | head -n1)"

if [[ -z "${port_id:-}" ]]; then
  error_exit "No port found on network $network_id with IP $target_ip"
fi
echo "Matched Port ID: $port_id"
log_info "Matched port: $port_id for IP $target_ip"

# ------------------------------------------------------------
# Ask for new IP and validate / conflict-check
# ------------------------------------------------------------
read -rp "Enter the NEW IP address to assign (same subnet $subnet_id): " new_ip
if ! validate_ip "$new_ip"; then
  error_exit "Invalid IP format: $new_ip"
fi
if [[ "$new_ip" == "$target_ip" ]]; then
  error_exit "New IP is the same as the current IP."
fi

# Check if new_ip already used by another port on the same network
in_use="$(jq -r --arg ip "$new_ip" '
  .[] | select(."Fixed IP Addresses"[]?.ip_address == $ip) | .ID' <<<"$ports_json" | head -n1)"
if [[ -n "$in_use" ]]; then
  error_exit "IP $new_ip is already in use by port $in_use on network $network_id."
fi
log_info "New IP $new_ip validated as free."

# ------------------------------------------------------------
# Apply: add new fixed IP first, then remove the old one
# ------------------------------------------------------------
echo "Adding $new_ip to port $port_id..."
log_info "Adding new IP $new_ip to port $port_id (subnet $subnet_id)"
openstack port set --fixed-ip "subnet=$subnet_id,ip-address=$new_ip" "$port_id"

echo "Removing old IP $target_ip from port $port_id..."
log_info "Removing old IP $target_ip from port $port_id (subnet $subnet_id)"
openstack port unset --fixed-ip "subnet=$subnet_id,ip-address=$target_ip" "$port_id"

# ------------------------------------------------------------
# Print the final result
# ------------------------------------------------------------
log_info "Change complete. Fetching final router state for $router_id"
openstack router show "$router_id" -f json | jq '{name, external_gateway_info}'