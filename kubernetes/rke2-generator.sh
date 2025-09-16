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
    echo "- $name : ${vcpus} vCPUs, ${ram}MB RAM"
  else
    echo "Creating flavor '$name'..."
    openstack flavor create "$name" "$@"
  fi
}

# --- Step 0: list regions & select (auto-pick if single) ---------------------
echo "Select Region:"
regions_json=$(openstack region list -c Region -f json)

region_count=$(echo "$regions_json" | jq 'length')
if (( region_count == 0 )); then
  echo "No regions returned by OpenStack."; exit 1
fi

mapfile -t region_names < <(echo "$regions_json" | jq -r '.[].Region')

if (( region_count == 1 )); then
  region_name="${region_names[0]}"
  echo "Only one region found."
else
  i=1
  for rn in "${region_names[@]}"; do
    printf "%2d. %s\n" "$i" "$rn"
    ((i++))
  done
  while :; do
    read -rp "Enter region number: " ridx
    if [[ "$ridx" =~ ^[0-9]+$ ]] && (( ridx >= 1 && ridx <= ${#region_names[@]} )); then
      region_name="${region_names[$((ridx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi

# Export so downstream OpenStack CLIs respect it
export OS_REGION_NAME="$region_name"
echo "Using region: $OS_REGION_NAME"

# --- Step 1: list domains (exclude 'heat') & select (auto-pick if single) ----
echo
echo "Select Domain:"
domains_json=$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')

dom_count=$(echo "$domains_json" | jq 'length')
if (( dom_count == 0 )); then
  echo "No selectable domains found."; exit 1
fi

mapfile -t domain_lines < <(echo "$domains_json" | jq -r '.[] | "\(.ID)|\(.Name)"')

if (( dom_count == 1 )); then
  IFS='|' read -r domain_id domain_name <<< "${domain_lines[0]}"
  echo "Only one domain found."
else
  i=1
  for line in "${domain_lines[@]}"; do
    IFS='|' read -r dom_id dom_name <<< "$line"
    printf "%2d. %s (%s)\n" "$i" "$dom_name" "$dom_id"
    ((i++))
  done
  while :; do
    read -rp "Enter domain number: " dom_idx
    if [[ "$dom_idx" =~ ^[0-9]+$ ]] && (( dom_idx >= 1 && dom_idx <= ${#domain_lines[@]} )); then
      IFS='|' read -r domain_id domain_name <<< "${domain_lines[$((dom_idx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi
echo "Using domain: $domain_name ($domain_id)"

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

# Assign 'admin' role to user 'admin (IAM)' in the selected project
user_id=$(openstack user list -f json | jq -r '.[] | select(.Name=="admin (IAM)") | .ID')
openstack role add --user "$user_id" --project "$project_id" admin

# --- Step 3: select network 'private-k8s' in the project ---------------------
echo
networks_json=$(openstack network list --project "$project_id" -f json)
network_id=$(echo "$networks_json" | jq -r '.[] | select(.Name=="private-k8s") | .ID' | head -n1)
network_subnet_id=$(openstack network show $network_id -f json | jq -r '.subnets[0]')
if [[ -z "${network_id:-}" ]]; then
  echo "ERROR: Network named 'private-k8s' not found in project '$project_name'."; exit 1
fi
echo "netId: $network_id"


# Get all router-interface ports on this network
mapfile -t router_ports_ids < <(
  openstack port list --network "$network_id" --long -f json \
    | jq -r '.[] | select(."Device Owner"=="network:router_interface") | .ID'
)

if (( ${#router_ports_ids[@]} == 0 )); then
  echo "ERROR: No router interface ports found on network '$network_id'."
  exit 1
fi

# Collect external networks reachable via routers on this network.
# Use an associative array to dedupe by external network id.
declare -A ext_net_name_by_id=()
declare -a ext_net_ids=()

echo "floatingPool(s) discovered:"
for pid in "${router_ports_ids[@]}"; do
  rid=$(openstack port show "$pid" -f json | jq -r '.device_id // empty')
  [[ -z "$rid" ]] && continue

  ext_id=$(openstack router show "$rid" -f json | jq -r '.external_gateway_info.network_id // empty')
  [[ -z "$ext_id" ]] && continue

  # Deduplicate by external network id; remember first time we see it
  if [[ -z "${ext_net_name_by_id[$ext_id]+x}" ]]; then
    ext_name=$(openstack network show "$ext_id" -c name -f value)
    ext_net_name_by_id["$ext_id"]="$ext_name"
    ext_net_ids+=("$ext_id")
  fi

  # Print each router→external mapping (informational)
  echo "- via router $rid -> ${ext_net_name_by_id[$ext_id]} ($ext_id)"
done

if (( ${#ext_net_ids[@]} == 0 )); then
  echo "ERROR: Routers on this network have no external gateway configured."
  exit 1
fi

# Pick the first discovered external network as the default for downstream use
external_network_id="${ext_net_ids[0]}"
external_network_name="${ext_net_name_by_id[$external_network_id]}"
echo "Using floatingPool: $external_network_name ($external_network_id)"

echo 
echo "Available images:"
openstack image list -f json | jq -r '.[] | select((.Name | ascii_downcase) | startswith("ubuntu")) | "- \(.Name) (\(.ID))"'
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
outfile="${project_name}-01-rke2-config.txt"

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

# --- Step 8: ensure Manila share network for 'private-k8s' -------------------
sn_name="${project_name}-private-k8s"

# Try to read existing share network ID (empty if not found)
shareNetworkID="$(openstack share network show "$sn_name" -c id -f value 2>/dev/null || true)"

if [[ -z "${shareNetworkID:-}" ]]; then
  echo "Manila share network '$sn_name' not found. Creating..."

  # Per request: try specific network UUID first
  subnet_id=$(openstack network show $network_id -f json | jq -r '.subnets[0]')

  if [[ -z "${subnet_id:-}" ]]; then
    echo "WARNING: Provided network UUID returned no subnet. Falling back to selected netId: $network_id"
    subnet_id="$( openstack network show "$network_id" -f json 2>/dev/null | jq -r '.subnets[0] // empty' )"
  fi

  if [[ -z "${subnet_id:-}" ]]; then
    echo "ERROR: Could not determine a subnet_id for Manila share network creation."
    exit 1
  fi

  # Use the target project context
  export OS_PROJECT_NAME="$project_name"

  # Create the Manila share network
  openstack share network create --neutron-net-id "$network_id" --neutron-subnet-id "$subnet_id" --name "$sn_name"

  # Read back the ID
  shareNetworkID="$(openstack share network show "$sn_name" -c id -f value)"
else
  echo "Manila share network already exists: $sn_name ($shareNetworkID)"
fi

if [[ -z "${shareNetworkID:-}" ]]; then
  echo "ERROR: Failed to obtain shareNetworkID for '$sn_name'."
  exit 1
fi

cloud_config="${project_name}-02-cloud-config.yaml"
cat > "$cloud_config" <<CC
secret:
  create: true
  name: cloud-config
cloudConfig:
  global:
    auth-url: "${OS_AUTH_URL:-}"
    tenant-name: "${project_name}"
    username: "${project_name}"
    password: "${USER_PASS}"
    region: "${region_name}"
    domain-name: "${domain_name}"
    tls-insecure: "true"
  loadBalancer:
    floating-network-id: "${external_network_id}"
    subnet-id: "${network_subnet_id}"
  blockStorage:
    ignore-volume-az: true
CC

sc_cinder="${project_name}-03-storage-class-cinder-csi.yaml"
cat > "$sc_cinder" <<CCSI
secret:
  enabled: true
  name: cloud-config
storageClass:
  enabled: false
  custom: |-
    ---
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
      name: csi-cinder
    provisioner: cinder.csi.openstack.org
    allowVolumeExpansion: true
    ---
    apiVersion: snapshot.storage.k8s.io/v1
    kind: VolumeSnapshotClass
    metadata:
      name: csi-cinder-snapclass
    driver: cinder.csi.openstack.org
    deletionPolicy: Delete
CCSI

sc_driver_nfs="${project_name}-04-csi-driver-nfs.yaml"
cat > "$sc_driver_nfs" <<SDN
externalSnapshotter:
  enabled: false
SDN

manila_secrets="${project_name}-05-manila-csi-secret.yaml"
cat > "$manila_secrets" <<CMSS
apiVersion: v1
kind: Secret
metadata:
  name: csi-manila-secrets
  namespace: kube-system
stringData:
  os-authURL: "${OS_AUTH_URL:-}"
  os-region: "${region_name}"
  os-domainName: "${domain_name}"
  os-userName: "${project_name}"
  os-password: "${USER_PASS}"
  os-projectName: "${project_name}"
  os-TLSInsecure: "true"
CMSS

sc_manila="${project_name}-06-csi-manila-nfs.yaml"
cat > "$sc_manila" <<YAML
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-manila-nfs
parameters:
  csi.storage.k8s.io/controller-expand-secret-name: csi-manila-secrets
  csi.storage.k8s.io/controller-expand-secret-namespace: kube-system
  csi.storage.k8s.io/node-publish-secret-name: csi-manila-secrets
  csi.storage.k8s.io/node-publish-secret-namespace: kube-system
  csi.storage.k8s.io/node-stage-secret-name: csi-manila-secrets
  csi.storage.k8s.io/node-stage-secret-namespace: kube-system
  csi.storage.k8s.io/provisioner-secret-name: csi-manila-secrets
  csi.storage.k8s.io/provisioner-secret-namespace: kube-system
  shareNetworkID: "${shareNetworkID}"
  type: tenant_share_type
provisioner: nfs.manila.csi.openstack.org
reclaimPolicy: Delete
volumeBindingMode: Immediate
YAML

echo
echo "Config files written:"
echo "- $outfile"
echo "- $cloud_config"
echo "- $sc_cinder"
echo "- $sc_driver_nfs"
echo "- $manila_secrets"
echo "- $sc_manila"