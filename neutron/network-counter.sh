#!/bin/bash
set -euo pipefail

source /etc/admin-openrc.sh

# 只挑 VLAN 網路
networks=$(openstack network list --long -f json | jq -c '.[] | select(.["Network Type"] == "vlan")')

echo "------------------------------------------------"

# 逐一處理每個 VLAN 網路
echo "$networks" | while read -r network; do
    # 基本欄位
    network_name=$(echo "$network" | jq -r '.Name')
    network_id=$(echo "$network" | jq -r '.ID')
    subnet_id=$(echo "$network" | jq -r '.Subnets[0]')

    # 使用中的 port 數（你原本稱為 Used IPs）
    used_ips=$(openstack port list --network "$network_id" --long -f json | jq '. | length')

    # VLAN Segmentation ID
    vlan_segmentation_id=$(openstack network show "$network_id" -f json | jq -r '.["provider:segmentation_id"]')

    # 子網資訊
    json_output=$(openstack subnet show "$subnet_id" -f json)
    subnet_name=$(echo "$json_output" | jq -r '.name')
    gateway_ip=$(echo "$json_output" | jq -r '.gateway_ip')
    cidr=$(echo "$json_output" | jq -r '.cidr')

    # 取 allocation pool 的第一段作為可用 IP 計算（若有多段可自行延伸總和）
    start_ip=$(echo "$json_output" | jq -r '.allocation_pools[0].start')
    end_ip=$(echo "$json_output" | jq -r '.allocation_pools[0].end')

    ip_to_int() {
        local IFS=.
        read -r i1 i2 i3 i4 <<< "$1"
        echo $((i1 * 256**3 + i2 * 256**2 + i3 * 256 + i4))
    }

    start_int=$(ip_to_int "$start_ip")
    end_int=$(ip_to_int "$end_ip")
    available_ips=$((end_int - start_int + 1))

    # 取 routes，處理無資料
    routes=$(echo "$json_output" | jq -r '.host_routes[]? | "- \(.destination),\(.nexthop)"')
    if [[ -z "$routes" || "$routes" == "null" ]]; then
        routes="- N/A"
    fi

    # ───────── Device Owner 分組統計 ─────────
    # 取出每個 Device Owner 的數量（null → "Unassigned"）
    owners_json=$(
        openstack port list --network "$network_id" --long -f json \
        | jq 'map(."Device Owner" // "Unassigned")
              | group_by(.)
              | map({owner: .[0], count: length})'
    )

    # 轉成關聯陣列 owner_counts["owner"]=count
    declare -A owner_counts=()
    while IFS=$'\t' read -r owner count; do
        [[ -z "${owner:-}" ]] && continue
        owner_counts["$owner"]="$count"
    done < <(echo "$owners_json" | jq -r '.[] | "\(.owner)\t\(.count)"')

    # 預先列出你關心的幾個 owner（沒有就顯示 0）
    count_compute_nova=${owner_counts["compute:nova"]:-0}
    count_cube_mgr=${owner_counts["cube:mgr"]:-0}
    count_network_distributed=${owner_counts["network:distributed"]:-0}
    count_network_fip=${owner_counts["network:floatingip"]:-0}
    count_network_router_gw=${owner_counts["network:router_gateway"]:-0}

    # 輸出
    echo "Network: $network_name ($network_id)"
    echo "Subnet: $subnet_name ($subnet_id)"
    echo "VLAN ID: $vlan_segmentation_id"
    echo "IP range: $start_ip to $end_ip"
    echo "CIDR: $cidr"
    echo "Route:"
    echo "$routes"
    echo "Gateway IP: $gateway_ip"
    echo "Used IPs: $used_ips"
    echo "Max IPs: $available_ips"
    echo "NIC: $count_compute_nova"
    echo "Manager : $count_cube_mgr"
    echo "SNAT : $count_network_distributed"
    echo "FIP : $count_network_fip"
    echo "Gateway : $count_network_router_gw"
    other_printed=false
    for k in "${!owner_counts[@]}"; do
        case "$k" in
            "compute:nova"|"cube:mgr"|"network:distributed"|"network:floatingip"|"network:router_gateway")
                continue
                ;;
            *)
                if [[ $other_printed == false ]]; then
                    echo "--- Others ---"
                    other_printed=true
                fi
                echo "$k : ${owner_counts[$k]}"
                ;;
        esac
    done

    echo "------------------------------------------------"
done