#!/usr/bin/env bash
#
# host-traits.sh
#   從 cubectl 取得 compute host，為每台 host 的 placement root RP
#   加上 CUSTOM_HOST_<HOSTNAME> trait（保留原有 trait），並檢查結果。
#
# 用法:
#   ./create-host-trait.sh            建立 + 檢查
#   ./create-host-trait.sh --check    只檢查
#   ./create-host-trait.sh --dry-run  只顯示會做什麼，不修改
#
# 前置條件: 已 source admin openrc
#
# openstack flavor create --vcpus 2 --ram 2048 --disk 100  --property trait:CUSTOM_HOST_SKY143=required sky143-2c2g
# +----------------------------+--------------------------------------+
# | Field                      | Value                                |
# +----------------------------+--------------------------------------+
# | OS-FLV-DISABLED:disabled   | False                                |
# | OS-FLV-EXT-DATA:ephemeral  | 0                                    |
# | description                | None                                 |
# | disk                       | 100                                  |
# | id                         | 19d09821-90c3-4017-ba93-e75b036112f5 |
# | name                       | sky143-2c2g                          |
# | os-flavor-access:is_public | True                                 |
# | properties                 | trait:CUSTOM_HOST_SKY143='required'  |
# | ram                        | 2048                                 |
# | rxtx_factor                | 1.0                                  |
# | swap                       |                                      |
# | vcpus                      | 2                                    |
# +----------------------------+--------------------------------------+

set -uo pipefail

PLACEMENT_VER=1.18
PREFIX="CUSTOM_HOST_"
MAX_RETRY=3
MODE="apply"

OSC=(openstack --os-placement-api-version "${PLACEMENT_VER}")
ERRF=$(mktemp)
trap 'rm -f "$ERRF"' EXIT

case "${1:-}" in
  --check)   MODE="check" ;;
  --dry-run) MODE="dry-run" ;;
  "")        ;;
  *) echo "Usage: $0 [--check|--dry-run]"; exit 1 ;;
esac

# ---------- helpers ----------
to_trait() {
  # bs-ai-01.example.com -> CUSTOM_HOST_BS_AI_01
  local short="${1%%.*}"
  echo "${PREFIX}$(echo "$short" | tr 'a-z.-' 'A-Z__')"
}

get_hosts() {
  cubectl node list -r compute | awk -F, 'NF>=2 { gsub(/[[:space:]]/, "", $1); if ($1 != "") print $1 }'
}

get_rp() {
  "${OSC[@]}" resource provider list --name "$1" -f value -c uuid 2>/dev/null
}

get_traits() {
  "${OSC[@]}" resource provider trait list "$1" -f value 2>/dev/null
}

add_trait() {
  local rp=$1 trait=$2 i cur before after
  local -a args
  for ((i = 1; i <= MAX_RETRY; i++)); do
    cur=$(get_traits "$rp") || { echo "  [ERR] 無法讀取 trait"; return 1; }

    if grep -qx "$trait" <<<"$cur"; then
      echo "  [SKIP] 已存在 $trait"
      return 0
    fi

    before=$(grep -c . <<<"$cur")
    args=()
    while read -r t; do [[ -n "$t" ]] && args+=(--trait "$t"); done <<<"$cur"
    args+=(--trait "$trait")

    if [[ "$MODE" == "dry-run" ]]; then
      echo "  [DRY-RUN] 會加入 $trait（目前 $before 個 trait，完成後 $((before + 1)) 個）"
      return 0
    fi

    if "${OSC[@]}" resource provider trait set "${args[@]}" "$rp" >/dev/null 2>"$ERRF"; then
      after=$(get_traits "$rp" | grep -c .)
      echo "  [OK] 已加入 $trait（$before -> $after 個 trait）"
      return 0
    fi

    if grep -qiE "conflict|409|generation" "$ERRF"; then
      echo "  [RETRY $i/$MAX_RETRY] RP generation 衝突，重試中..."
      sleep 2
      continue
    fi

    echo "  [ERR] trait set 失敗:"; sed 's/^/    /' "$ERRF"
    return 1
  done
  echo "  [ERR] 重試 $MAX_RETRY 次仍失敗"
  return 1
}

# ---------- pre-check ----------
for cmd in cubectl openstack; do
  command -v "$cmd" >/dev/null || { echo "找不到指令: $cmd"; exit 1; }
done
if ! openstack token issue -f value -c id >/dev/null 2>&1; then
  echo "無法取得 OpenStack token，請先 source admin openrc"; exit 1
fi

mapfile -t HOSTS < <(get_hosts)
if ((${#HOSTS[@]} == 0)); then
  echo "cubectl 沒有回傳任何 compute host"; exit 1
fi
echo "Compute hosts: ${HOSTS[*]}"

# ---------- apply ----------
if [[ "$MODE" != "check" ]]; then
  echo
  echo "===== 建立 / 加入 trait ($MODE) ====="
  for h in "${HOSTS[@]}"; do
    trait=$(to_trait "$h")
    rp=$(get_rp "$h")
    echo "== $h -> $trait (RP: ${rp:-N/A})"

    if [[ -z "$rp" ]]; then
      echo "  [ERR] placement 找不到名稱為 $h 的 resource provider"
      continue
    fi

    if [[ "$MODE" == "apply" ]]; then
      "${OSC[@]}" trait create "$trait" >/dev/null 2>"$ERRF" \
        || { echo "  [ERR] trait create 失敗:"; sed 's/^/    /' "$ERRF"; continue; }
    fi

    add_trait "$rp" "$trait"
  done
fi

[[ "$MODE" == "dry-run" ]] && exit 0

# ---------- check ----------
echo
echo "===== 檢查結果 ====="
FAIL=0
printf "%-12s %-26s %-38s %-7s %s\n" "HOST" "TRAIT" "RP_UUID" "TRAITS" "STATUS"

for h in "${HOSTS[@]}"; do
  trait=$(to_trait "$h")
  rp=$(get_rp "$h")
  status=()

  if [[ -z "$rp" ]]; then
    printf "%-12s %-26s %-38s %-7s %s\n" "$h" "$trait" "N/A" "-" "FAIL: 找不到 RP"
    FAIL=1; continue
  fi

  traits=$(get_traits "$rp")
  count=$(grep -c . <<<"$traits")

  # 1. trait 在這台 host 上
  grep -qx "$trait" <<<"$traits" || status+=("缺少 $trait")

  # 2. 原有系統 trait 沒被清掉
  grep -qx "COMPUTE_NODE" <<<"$traits" || status+=("缺少 COMPUTE_NODE（系統 trait 可能被覆寫）")

  # 3. trait 只對應到這一台
  owners=$("${OSC[@]}" resource provider list --required "$trait" -f value -c uuid 2>/dev/null)
  n=$(grep -c . <<<"$owners")
  if [[ "$n" -ne 1 || "$owners" != "$rp" ]]; then
    status+=("trait 對應到 $n 個 RP")
  fi

  if ((${#status[@]} == 0)); then
    s="OK"
  else
    s="FAIL: $(printf '%s; ' "${status[@]}")"; s="${s%; }"; FAIL=1
  fi
  printf "%-12s %-26s %-38s %-7s %s\n" "$h" "$trait" "$rp" "$count" "$s"
done

echo
if ((FAIL)); then
  echo "結果: 有項目未通過，請檢查上方 FAIL 訊息"
  exit 1
fi
echo "結果: 全部通過"