#!/usr/bin/env bash
set -euo pipefail

source /etc/admin-openrc.sh

# --- Flavor helper -----------------------------------------------------------
ensure_flavor() {
  local name="$1"
  shift
  if openstack flavor show "$name" >/dev/null 2>&1; then
    local vcpus ram
    vcpus=$(openstack flavor show "$name" -c vcpus -f value)
    ram=$(openstack flavor show "$name" -c ram -f value)
    echo "Flavor '$name' : ${vcpus} vCPUs, ${ram}MB RAM"
  else
    echo "Creating flavor '$name'..."
    openstack flavor create "$name" "$@"
  fi
}

# --- Step 1: list domains (exclude 'heat') & select --------------------------
echo "Select Domain:"
domains_json=$(openstack domain list -f json)
# filter out domain named 'heat'
domains_json=$(echo "$domains_json" | jq '[.[] | select(.Name != "heat")]')

if [[ "$(echo "$domains_json" | jq 'length')" -eq 0 ]]; then
  echo "No selectable domains found."; exit 1
fi

# show numbered menu
i=1
mapfile -t domain_lines < <(echo "$domains_json" | jq -r '.[] | "\(.ID)|\(.Name)"')
for line in "${domain_lines[@]}"; do
  IFS='|' read -r dom_id dom_name <<< "$line"
  printf "%2d. %s (%s)\n" "$i" "$dom_name" "$dom_id"
  ((i++))
done

read -rp "Enter domain number: " dom_idx
if ! [[ "$dom_idx" =~ ^[0-9]+$ ]] || (( dom_idx < 1 || dom_idx > ${#domain_lines[@]} )); then
  echo "Invalid selection."; exit 1
fi
IFS='|' read -r domain_id domain_name <<< "${domain_lines[$((dom_idx-1))]}"

# --- Step 2: list projects in domain, exclude admin/_diagnostics/service -----
echo
echo "Select Project in domain '$domain_name':"
projects_json=$(openstack project list --domain "$domain_id" -f json)
projects_json=$(echo "$projects_json" | jq '[.[] | select(.Name != "admin" and .Name != "_diagnostics" and .Name != "service")]')

if [[ "$(echo "$projects_json" | jq 'length')" -eq 0 ]]; then
  echo "No selectable projects found in domain '$domain_name'."; exit 1
fi

i=1
mapfile -t project_lines < <(echo "$projects_json" | jq -r '.[] | "\(.ID)|\(.Name)"')
for line in "${project_lines[@]}"; do
  IFS='|' read -r proj_id proj_name <<< "$line"
  printf "%2d. %s (%s)\n" "$i" "$proj_name" "$proj_id"
  ((i++))
done

read -rp "Enter project number: " proj_idx
if ! [[ "$proj_idx" =~ ^[0-9]+$ ]] || (( proj_idx < 1 || proj_idx > ${#project_lines[@]} )); then
  echo "Invalid selection."; exit 1
fi
IFS='|' read -r project_id project_name <<< "${project_lines[$((proj_idx-1))]}"

# --- Step 3: select network 'private-k8s' in the project ---------------------
echo
networks_json=$(openstack network list --project "$project_id" -f json)
network_id=$(echo "$networks_json" | jq -r '.[] | select(.Name=="private-k8s") | .ID' | head -n1)
if [[ -z "${network_id:-}" ]]; then
  echo "ERROR: Network named 'private-k8s' not found in project '$project_name'."; exit 1
fi
echo "netId: $network_id"

router_ports_id=$(openstack port list --network "$network_id" --long -f json | jq -r '.[] | select(."Device Owner"=="network:router_interface") | .ID')
router_id=$(openstack port show "$router_ports_id" -f json | jq -r '.device_id')
external_network_id=$(openstack router show "$router_id" -f json | jq -r '.external_gateway_info.network_id')
external_network_name=$(openstack network show "$external_network_id" -c name -f value)
echo "floatingPool: $external_network_name ($external_network_id)"

echo 
echo "Available images:"
openstack image list -f json | jq -r '.[] | select(.Name | startswith("ubuntu")) | "- \(.Name) (\(.ID))"'
image_name=$(openstack image list -f json | jq -r '[.[] | select(.Name | startswith("ubuntu"))] | sort_by(.Name) | last | .Name')

# --- Step 4: get user id by project name (best-effort heuristics) ------------
user_id=""
# Try direct: user name equals project name
if openstack user show "$project_name" >/dev/null 2>&1; then
  user_id=$(openstack user show "$project_name" -c id -f value)
else
  # Fallback: list users with role in this project and pick one matching name first, otherwise first enabled
  users_json=$(openstack user list --project "$project_id" -f json || echo '[]')
  user_id=$(echo "$users_json" | jq -r --arg pn "$project_name" '
      ([.[] | select(.Name==$pn) | .ID] // [])[0] // 
      ([.[] | select(.Enabled=="True") | .ID] // [])[0] // empty
  ')
fi

if [[ -z "${user_id:-}" ]]; then
  echo "WARNING: Could not determine a user in project '$project_name'. Leaving user_id empty."
fi

# --- Step 5: generate user password from project name ------------------------
USER_PASS=$(echo -n "$project_name" | openssl dgst -sha1 -hmac cube2022 | awk '{print $2}')

# --- Step 6: ensure flavors exist -------------------------------------------
echo
echo "Available flavors:"
ensure_flavor appfw.medium --vcpus 8  --ram 8192  --disk 200 --property hw:cpu_cores=8  --public
ensure_flavor appfw.large  --vcpus 12 --ram 12288 --disk 200 --property hw:cpu_cores=12 --public
ensure_flavor appfw.xlarge --vcpus 16 --ram 16384 --disk 200 --property hw:cpu_cores=16 --public



# --- Step 7: output configuration & save to file (ASCII box, fixed order) ---
echo
outfile="${project_name}-rke2-config.txt"

# Ordered config (parallel arrays)
keys=(
  "password"
  "activeTimeout"
  "authUrl"
  "endpointType"
  "flavorName"
  "floatingPool"
  "imageName"
  "insecure"
  "ipVersion"
  "netId"
  "secGroup"
  "sshPort"
  "sshUser"
  "tenantId"
  "userId"
)

values=(
  "$USER_PASS"
  "200"
  "${OS_AUTH_URL:-}"
  "publicURL"
  "appfw.medium"
  "$external_network_name"
  "$image_name"
  "[v] checked"
  "4"
  "$network_id"
  "default,default-k8s"
  "22"
  "ubuntu"
  "$project_id"
  "$user_id"
)

# Calculate max widths
max_key=0
max_val=0
for i in "${!keys[@]}"; do
  (( ${#keys[$i]} > max_key )) && max_key=${#keys[$i]}
  (( ${#values[$i]} > max_val )) && max_val=${#values[$i]}
done

border="+-$(printf '%*s' "$max_key" '' | tr ' ' '-')-+-$(printf '%*s' "$max_val" '' | tr ' ' '-')-+"

{
  echo "$border"
  printf "| %-*s | %-*s |\n" $max_key "Key" $max_val "Value"
  echo "$border"
  for i in "${!keys[@]}"; do
    printf "| %-*s | %-*s |\n" $max_key "${keys[$i]}" $max_val "${values[$i]}"
  done
  echo "$border"
} | tee "$outfile"

echo
echo "Config written to: $outfile"