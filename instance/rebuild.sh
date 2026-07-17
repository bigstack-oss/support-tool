#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="/var/log/support-rebuild-vm.log"
[ -w "$(dirname "$LOG_FILE")" ] || LOG_FILE="./support-rebuild-vm.log"

TS() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "[$(TS)] $*" | tee -a "$LOG_FILE" >&2; }

[ -f /etc/admin-openrc.sh ] && . /etc/admin-openrc.sh || true

require_yes_no_cap() {
  local ans
  while :; do
    read -rp "$1 (YES/NO): " ans
    case "$ans" in
      YES|NO) echo "$ans"; return 0 ;;
      *) echo "Please answer YES or NO (uppercase)." ;;
    esac
  done
}

wait_for_status() {
  # $1 = server_id, $2 = wanted_status, $3 = timeout_sec
  local id="$1" want="$2" t="${3:-120}" st
  local start_ts=$(date +%s)
  while :; do
    st=$(openstack server show "$id" -f value -c status 2>/dev/null || true)
    [[ "$st" == "$want" ]] && return 0
    (( $(date +%s) - start_ts >= t )) && return 1
    sleep 2
  done
}

# -------------------- STEP 1: Select Domain (exclude 'heat') ------------------
echo
echo "Select Domain:"
DOMAINS_JSON=$(openstack domain list -f json | jq '[.[] | select(.Name != "heat")]')
DOM_COUNT=$(echo "$DOMAINS_JSON" | jq 'length')
(( DOM_COUNT > 0 )) || { echo "No selectable domains."; exit 1; }

mapfile -t DOMAIN_LINES < <(echo "$DOMAINS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)"')
if (( DOM_COUNT == 1 )); then
  IFS='|' read -r DOMAIN_ID DOMAIN_NAME <<< "${DOMAIN_LINES[0]}"
  echo "Only one domain found."
else
  i=1
  for LINE in "${DOMAIN_LINES[@]}"; do IFS='|' read -r ID NAME <<<"$LINE"; printf "%2d. %s (%s)\n" "$i" "$NAME" "$ID"; ((i++)); done
  while :; do
    read -rp "Enter domain number: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#DOMAIN_LINES[@]} )); then
      IFS='|' read -r DOMAIN_ID DOMAIN_NAME <<< "${DOMAIN_LINES[$((idx-1))]}"
      break
    fi
    echo "Invalid selection."
  done
fi
echo "Using domain: $DOMAIN_NAME ($DOMAIN_ID)"

# -------------------- STEP 2: Select Project (exclude 'service') --------------
echo
echo "Select Project in domain '$DOMAIN_NAME':"
PROJECTS_JSON=$(openstack project list --domain "$DOMAIN_ID" -f json | jq '[.[] | select(.Name != "service")]')
PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')
(( PROJ_COUNT > 0 )) || { echo "No selectable projects."; exit 1; }

i=1
mapfile -t PROJECT_LINES < <(echo "$PROJECTS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)"')
for LINE in "${PROJECT_LINES[@]}"; do IFS='|' read -r ID NAME <<<"$LINE"; printf "%2d. %s (%s)\n" "$i" "$NAME" "$ID"; ((i++)); done
while :; do
  read -rp "Enter project number: " idx
  if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#PROJECT_LINES[@]} )); then
    IFS='|' read -r PROJECT_ID PROJECT_NAME <<< "${PROJECT_LINES[$((idx-1))]}"
    break
  fi
  echo "Invalid selection."
done
echo "Using project: $PROJECT_NAME ($PROJECT_ID)"

# -------------------- STEP 3: Select Server -----------------------------------
echo
echo "Select Server in project '$PROJECT_NAME':"
SERVERS_JSON=$(openstack server list --project "$PROJECT_ID" -f json)
SERV_COUNT=$(echo "$SERVERS_JSON" | jq 'length')
(( SERV_COUNT > 0 )) || { echo "No servers found."; exit 1; }

i=1
mapfile -t SERVER_LINES < <(echo "$SERVERS_JSON" | jq -r '.[] | "\(.ID)|\(.Name)"')
for LINE in "${SERVER_LINES[@]}"; do IFS='|' read -r ID NAME <<<"$LINE"; printf "%2d. %s (%s)\n" "$i" "$NAME" "$ID"; ((i++)); done
while :; do
  read -rp "Enter server number: " idx
  if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#SERVER_LINES[@]} )); then
    IFS='|' read -r SERVER_ID SERVER_NAME <<< "${SERVER_LINES[$((idx-1))]}"
    break
  fi
  echo "Invalid selection."
done
echo "Using server: $SERVER_NAME ($SERVER_ID)"

# 確保日誌保存目錄存在（/var/log/nova），不可寫時改存當前目錄
NOVA_LOG_DIR="/var/log/nova/vm-rebuild"
if ! mkdir -p "$NOVA_LOG_DIR" 2>/dev/null; then
  NOVA_LOG_DIR="."
fi
openstack server show "$SERVER_ID" -f json > "$NOVA_LOG_DIR/$SERVER_ID-$SERVER_NAME.json" 2>/dev/null || true

# -------------------- STEP 3.1: Record current VM status ----------------------
echo
SRV_STATUS=$(openstack server show "$SERVER_ID" -f value -c status 2>/dev/null || echo "UNKNOWN")
log "Current server status: $SRV_STATUS"
# Continue even if the VM is not ACTIVE; rebuild logic will handle stop/delete later

# -------------------- STEP 4: OS TYPE = user input (with hint) ----------------
echo
echo "Select OS type for metadata normalization:"
echo "1) windows"
echo "2) linux"
read -rp "Enter option number: " OS_TYPE_OPTION
case "$OS_TYPE_OPTION" in
  1) OS_TYPE="windows" ;;
  2) OS_TYPE="linux" ;;
  *) echo "Invalid option"; exit 1 ;;
esac
log "Selected os_type=$OS_TYPE"

# -------------------- STEP 5: Stop & Delete server ----------------------------
SRV_STATUS=$(openstack server show "$SERVER_ID" -f value -c status 2>/dev/null || echo "UNKNOWN")

if [[ "$SRV_STATUS" != "SHUTOFF" ]]; then
  ans=$(require_yes_no_cap "The VM is $SRV_STATUS. Do you want to power it off now?")
  if [[ "$ans" == "YES" ]]; then
    log "Stopping server $SERVER_ID ..."
    openstack server stop "$SERVER_ID" || log "WARN: stop failed."
    if ! wait_for_status "$SERVER_ID" "SHUTOFF" 180; then
      log "ERROR: server did not reach SHUTOFF within timeout."; exit 1
    fi
  else
    log "User chose not to stop VM. Aborting."; exit 1
  fi
fi

ans=$(require_yes_no_cap "Proceed to DELETE the server $SERVER_NAME ($SERVER_ID)?")
[[ "$ans" == "YES" ]] || { log "User aborted deletion."; exit 1; }
log "Deleting server $SERVER_ID ..."
openstack server delete "$SERVER_ID" || { log "ERROR: failed to delete server."; exit 1; }

# 等待資源從 Nova 清單消失
for _ in {1..60}; do
  openstack server show "$SERVER_ID" >/dev/null 2>&1 || break
  sleep 2
done
log "Server deleted."

# -------------------- STEP 6: Rebuild inputs from saved server record ---------
NOVA_JSON="$NOVA_LOG_DIR/$SERVER_ID-$SERVER_NAME.json"
[[ -s "$NOVA_JSON" ]] || { log "ERROR: missing server snapshot $NOVA_JSON"; exit 1; }

# ---- Flavor (accept ID or name; handle nested and decorated strings) ----
FLAVOR_SPEC=$(cat $NOVA_JSON |jq -r '.flavor.original_name')
log "Using flavor spec: $FLAVOR_SPEC"

# ---- Availability Zone -------------------------------------------------
AZ=$(cat $NOVA_JSON |jq -r '.availability_zone')

# ---- Key name (optional) ----------------------------------------------
KEY_NAME=$(jq -r '.key_name // empty' "$NOVA_JSON")
KEY_OPT=()
[[ -n "$KEY_NAME" && "$KEY_NAME" != "null" ]] && KEY_OPT=( --key-name "$KEY_NAME" )

# ---- Metadata / properties (object or decorated string) ----------------
PROPERTIES_OPTS=()
if jq -e '.properties? | type=="object"' "$NOVA_JSON" >/dev/null 2>&1; then
  while IFS= read -r kv; do
    k="${kv%%|*}"; v="${kv#*|}"
    PROPERTIES_OPTS+=( --property "$k=$v" )
  done < <(jq -r '.properties | to_entries[] | "\(.key)|\(.value)"' "$NOVA_JSON")
else
  PROP_STR=$(jq -r '.properties // empty' "$NOVA_JSON")
  if [[ -n "$PROP_STR" && "$PROP_STR" != "null" ]]; then
    while IFS= read -r pair; do
      pair="$(echo "$pair" | sed -E "s/^[[:space:]]+//;s/[[:space:]]+$//")"
      [[ -z "$pair" ]] && continue
      k="${pair%%=*}"
      v="${pair#*=}"
      v="${v#\'}"; v="${v%\'}"
      v="${v#\"}"; v="${v%\"}"
      [[ -n "$k" ]] && PROPERTIES_OPTS+=( --property "$k=$v" )
    done < <(echo "$PROP_STR" | tr ',' '\n')
  fi
fi

# ---- Tags (array or string) -------------------------------------------
TAGS_OPTS=()
if jq -e '.tags? | type=="array"' "$NOVA_JSON" >/dev/null 2>&1; then
  while IFS= read -r tag; do
    [[ -n "$tag" && "$tag" != "null" ]] && TAGS_OPTS+=( --tag "$tag" )
  done < <(jq -r '.tags[]?' "$NOVA_JSON")
else
  TAGS_STR=$(jq -r '.tags // empty' "$NOVA_JSON")
  if [[ -n "$TAGS_STR" && "$TAGS_STR" != "null" ]]; then
    IFS=',' read -r -a _tags <<<"$(echo "$TAGS_STR" | tr -s ' ' ',')"
    for tag in "${_tags[@]}"; do
      t="$(echo "$tag" | xargs)"
      [[ -n "$t" ]] && TAGS_OPTS+=( --tag "$t" )
    done
  fi
fi

# ---- Determine boot source: Volume vs Image ----------------------------
mapfile -t ATTACHED_VOLS < <(jq -r '
  (."os-extended-volumes:volumes_attached"? // .volumes_attached? // .attached_volumes? // [])
  | .[]?
  | (.id // .volume_id // .ID // empty)
' "$NOVA_JSON")

BOOT_FROM="volume"
if [[ ${#ATTACHED_VOLS[@]} -eq 0 ]]; then
  BOOT_FROM="image"
fi

BDM_OPTS=()
IMAGE_SPEC=""

if [[ "$BOOT_FROM" == "volume" ]]; then
  BOOT_VOL="${ATTACHED_VOLS[0]}"
  [[ -n "$BOOT_VOL" ]] || { log "ERROR: detected volume-boot but no volume id found"; exit 1; }
  BDM_OPTS=( --block-device "source=volume,id=${BOOT_VOL},dest=volume,bootindex=0,delete_on_termination=false" )
else
  IMAGE_SPEC=$(
    jq -r '
      ( .image? | objects | (.id // .ID // .uuid // .image_id // .name) ) //
      ( .image? // .Image? // empty |
        if type=="string" then
          if test("\\(ID:") then
            capture("\\(ID: (?<id>[^\\)]+)\\)").id
          else . end
        else empty end
      )
    ' "$NOVA_JSON"
  )
  if [[ -z "$IMAGE_SPEC" || "$IMAGE_SPEC" == "null" ]]; then
    log "ERROR: image-boot detected but no image reference found in snapshot."
    log "TIP: ensure 'openstack server show -f json' includes an 'image' field for image-boot VMs."
    exit 1
  fi
fi

# ---- Summary log for debug ---------------------------------------------
if [[ "$BOOT_FROM" == "volume" ]]; then
  log "Step 6 resolved (volume-boot):"
  log "  Flavor          : $FLAVOR_SPEC"
  log "  AZ              : ${AZ:-<default scheduler>}"
  log "  Keypair         : ${KEY_NAME:-<none>}"
  log "  Boot volume     : $BOOT_VOL"
  log "  Extra volumes   : $(( ${#ATTACHED_VOLS[@]} > 1 ? ${#ATTACHED_VOLS[@]}-1 : 0 ))"
  log "  Properties cnt  : ${#PROPERTIES_OPTS[@]}"
  log "  Tags cnt        : ${#TAGS_OPTS[@]}"
else
  log "Step 6 resolved (image-boot):"
  log "  Flavor          : $FLAVOR_SPEC"
  log "  AZ              : ${AZ:-<default scheduler>}"
  log "  Keypair         : ${KEY_NAME:-<none>}"
  log "  Image           : $IMAGE_SPEC"
  log "  Properties cnt  : ${#PROPERTIES_OPTS[@]}"
  log "  Tags cnt        : ${#TAGS_OPTS[@]}"
fi

# -------------------- STEP 7: Ensure ports exist (IDs only; correct keys) -----
# 目標：根據快照中的 addresses 及 security_groups，為每個 (network, ip) 取得/建立 port
# 產出：RECREATED_PORT_IDS[] 供 nic args 使用；同時套用原 SG (by ID)

# 7.1 取出 (network, ip) 配對；若某網段有多個 IP，預設取第一個
mapfile -t NET_IP_PAIRS < <(jq -r '
  .addresses
  | to_entries[]
  | .key as $net
  | (.value | map(.addr // .OS-EXT-IPS:ip // .ip_address // .addr? // .)) as $arr
  | select($arr | length > 0)
  | "\($net)|\($arr[0])"
' "$NOVA_JSON")

if [[ ${#NET_IP_PAIRS[@]} -eq 0 ]]; then
  log "WARN: no addresses found in snapshot; will rely on neutron to allocate ports."
fi

# 7.2 取得原 VM 的 security_groups 名稱清單
mapfile -t SNAPSHOT_SG_NAMES < <(jq -r '.security_groups[]?.name // empty' "$NOVA_JSON")
[[ ${#SNAPSHOT_SG_NAMES[@]} -eq 0 ]] && SNAPSHOT_SG_NAMES=(default)

# 7.3 將 SG 名稱解析為 ID (優先專案範圍)
declare -A SGNAME_TO_ID=()
mapfile -t PROJ_SGS < <(openstack security group list --project "$PROJECT_ID" -f json 2>/dev/null | jq -c '.[]')
for row in "${PROJ_SGS[@]}"; do
  name=$(echo "$row" | jq -r '.Name // .name // empty')
  id=$(echo "$row"   | jq -r '.ID   // .id   // empty')
  [[ -n "$name" && -n "$id" ]] && SGNAME_TO_ID["$name"]="$id"
done

SG_ID_ARGS=()
for sgn in "${SNAPSHOT_SG_NAMES[@]}"; do
  sgid="${SGNAME_TO_ID[$sgn]:-}"
  [[ -z "$sgid" ]] && sgid=$(openstack security group show "$sgn" --project "$PROJECT_ID" -f value -c id 2>/dev/null || true)
  [[ -n "$sgid" ]] && SG_ID_ARGS+=( --security-group "$sgid" )
done
# fallback to default if none found
if [[ ${#SG_ID_ARGS[@]} -eq 0 ]]; then
  DEFAULT_SG_ID="${SGNAME_TO_ID[default]:-}"
  [[ -z "$DEFAULT_SG_ID" ]] && DEFAULT_SG_ID=$(openstack security group show default --project "$PROJECT_ID" -f value -c id 2>/dev/null || true)
  [[ -n "$DEFAULT_SG_ID" ]] && SG_ID_ARGS+=( --security-group "$DEFAULT_SG_ID" )
fi

# 7.4 取得專案可見的 network 列表 (用於名稱->ID, Subnet 解析)
NETWORK_LIST_JSON=$(openstack network list --project "$PROJECT_ID" -f json)
if [[ -z "$NETWORK_LIST_JSON" ]]; then
  log "ERROR: failed to fetch network list for project $PROJECT_ID"; exit 1
fi

# 工具：network 名稱解析出第一個 Subnet ID 與 Network ID
resolve_net_subnet() {
  local net_name="$1"
  # 取第一個 Subnet；對多子網環境可延伸讓使用者選
  echo "$NETWORK_LIST_JSON" | jq -r --arg name "$net_name" '
    .[] | select(.Name == $name)
    | "\(.ID)|\(.Subnets[0] // "")"
  ' | head -n1
}

# 7.5 逐一處理 (network, ip)；若存在相同 IP 的 port 則重用，否則建立
RECREATED_PORT_IDS=()

for pair in "${NET_IP_PAIRS[@]}"; do
  net="${pair%%|*}"
  ip="${pair#*|}"
  [[ -z "$net" || -z "$ip" ]] && continue

  # 解析網路與子網
  ns_line="$(resolve_net_subnet "$net")"
  if [[ -z "$ns_line" ]]; then
    log "WARN: network '$net' not found in project; skipping NIC for $net/$ip"
    continue
  fi
  IFS='|' read -r NET_ID SUBNET_ID <<<"$ns_line"
  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
    log "WARN: network '$net' has no detectable subnet; skipping"
    continue
  fi

  log "Processing NIC => network:'$net' (ID:$NET_ID) subnet:$SUBNET_ID ip:$ip"

  # 尋找既有 port：用 fixed-ip 條件鎖定 subnet 與 IP
  EXISTING_PORT_ID=$(openstack port list \
      --network "$NET_ID" \
      --fixed-ip "subnet=$SUBNET_ID,ip-address=$ip" \
      -f value -c ID | head -n1 || true)

  if [[ -n "$EXISTING_PORT_ID" ]]; then
    log "  Reusing existing port: $EXISTING_PORT_ID"
    RECREATED_PORT_IDS+=( "$EXISTING_PORT_ID" )
    # 確保 SG 套用（有些環境原 SG 不一致）
    if [[ ${#SG_ID_ARGS[@]} -gt 0 ]]; then
      # 讀取目前 SG 列表
      cur_sgs=$(openstack port show "$EXISTING_PORT_ID" -f json | jq -r '.security_group_ids[]?' 2>/dev/null || true)
      need_update=0
      for sg_arg in "${SG_ID_ARGS[@]}"; do
        sgid="${sg_arg##* }"
        if ! grep -qx "$sgid" <<<"$cur_sgs"; then need_update=1; break; fi
      done
      if (( need_update )); then
        log "  Updating security groups on existing port ..."
        openstack port set "$EXISTING_PORT_ID" "${SG_ID_ARGS[@]}" || log "  WARN: failed to update SGs"
      fi
    fi
    continue
  fi

  # 建立新 port（套用 SG、固定 IP），名稱用 server+net+ip 簡單組合
  PORT_NAME="rebuild-${SERVER_NAME}-${net}-${ip}"
  # sanitize name (避免空白/特殊字元)
  PORT_NAME="${PORT_NAME//[^a-zA-Z0-9_.-]/_}"

  log "  Creating new port: $PORT_NAME"
  NEW_PORT_ID=$(openstack port create \
      --project "$PROJECT_ID" \
      --network "$NET_ID" \
      --fixed-ip "subnet=$SUBNET_ID,ip-address=$ip" \
      "${SG_ID_ARGS[@]}" \
      "$PORT_NAME" \
      -f value -c id 2>/dev/null || true)

  if [[ -z "$NEW_PORT_ID" ]]; then
    log "  ERROR: failed to create port for $net/$ip"
    continue
  fi

  log "  New port created: $NEW_PORT_ID"
  RECREATED_PORT_IDS+=( "$NEW_PORT_ID" )
done

if [[ ${#RECREATED_PORT_IDS[@]} -eq 0 ]]; then
  log "WARN: no NICs reconstructed; the instance will be created without explicit --nic (Neutron will pick defaults)."
else
  log "NICs ready: ${RECREATED_PORT_IDS[*]}"
fi

# -------------------- STEP 8: Recreate server & (optionally) re-associate FIPs -
NIC_ARGS=()
for pid in "${RECREATED_PORT_IDS[@]}"; do
  NIC_ARGS+=( --nic "port-id=$pid" )
done

log "Recreating server '$SERVER_NAME' ..."
CREATE_ARGS=(
  --flavor "$FLAVOR_SPEC"
  "${NIC_ARGS[@]}"
  "${KEY_OPT[@]}"
  "${PROPERTIES_OPTS[@]}"
  "${TAGS_OPTS[@]}"
)
[[ -n "$AZ" && "$AZ" != "null" ]] && CREATE_ARGS+=( --availability-zone "$AZ" )

if [[ "$BOOT_FROM" == "volume" ]]; then
  CREATE_ARGS+=( "${BDM_OPTS[@]}" )
else
  CREATE_ARGS+=( --image "$IMAGE_SPEC" )
fi

NEW_SERVER_ID=$(openstack server create "${CREATE_ARGS[@]}" -f value -c id "$SERVER_NAME")
[[ -n "$NEW_SERVER_ID" ]] || { log "ERROR: server create failed"; exit 1; }
log "Server created: $NEW_SERVER_ID"

# Wait for ACTIVE (best-effort)
if wait_for_status "$NEW_SERVER_ID" "ACTIVE" 600; then
  log "Server is ACTIVE."
else
  log "WARN: server did not reach ACTIVE within timeout."
fi