#!/usr/bin/env bash
set -euo pipefail

target_router="${1:-}"

count=0
echo "---------------------------------------------------------------------------"
# Use process substitution to avoid a subshell
while read -r router; do
    router_id=$(echo "$router" | jq -r '.ID')
    router_name=$(echo "$router" | jq -r '.Name')

    if [[ -n "$target_router" && "$router_name" != "$target_router" ]]; then
        continue
    fi

    project_id=$(echo "$router" | jq -r '.Project')
    ip_address=$(echo "$router" | jq -r '.["External gateway info"].external_fixed_ips[0].ip_address')
    network_id=$(echo "$router" | jq -r '.["External gateway info"].network_id')

    if [[ "$network_id" == "null" ]]; then
        network_name="N/A"
    else
        network_name=$(openstack network show "$network_id" -c name -f value 2>/dev/null || echo "unknown")
    fi

    project_name=$(openstack project show "$project_id" -c name -f value 2>/dev/null || echo "unknown")
    echo
    echo "Project: $project_name ($project_id)"
    echo "Router Name : $router_name ($router_id)"
    echo "IP Address : ${ip_address:-N/A}"
    echo "External Network: $network_name ($network_id)"
    echo
    echo "---------------------------------------------------------------------------"

    # Now the count variable will be updated in the main shell
    count=$((count + 1))
done < <(openstack router list --long -f json | jq -c '.[]')

echo "Total routers: $count"