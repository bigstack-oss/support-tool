#!/usr/bin/env bash

# Generate one concise, read-only Ceph capacity report.
# Requires: ceph, rbd, jq

set -u
set -o pipefail

timestamp=$(date '+%Y%m%d-%H%M%S')
report=${1:-"ceph-storage-summary-${timestamp}.txt"}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ceph-storage.XXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

for command_name in ceph rbd jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "$command_name" >&2
        exit 1
    fi
done

run_json() {
    destination=$1
    shift
    if ! "$@" -f json-pretty >"$destination"; then
        printf 'ERROR: command failed: %s\n' "$*" >&2
        exit 1
    fi
}

run_json "$work_dir/osd-tree.json"       ceph osd tree
run_json "$work_dir/osd-df-tree.json"    ceph osd df tree
run_json "$work_dir/pools.json"          ceph osd pool ls detail
run_json "$work_dir/df.json"             ceph df
run_json "$work_dir/crush-rules.json"    ceph osd crush rule dump

root_for_rule() {
    rule_id=$1
    jq -r --argjson rule_id "$rule_id" '
      .[] | select(.rule_id == $rule_id)
      | ([.steps[] | select(.op == "take") | .item_name][0] // "unknown")
    ' "$work_dir/crush-rules.json"
}

parent_root_for_rule() {
    rule_id=$1
    rule_target=$(root_for_rule "$rule_id")
    # Device-class shadow roots are named root~class (for example,
    # default~hdd). Their physical usage belongs to the parent root.
    printf '%s\n' "${rule_target%%~*}"
}

pool_field() {
    pool=$1
    field=$2
    jq -r --arg pool "$pool" --arg field "$field" '
      .[] | select(.pool_name == $pool) | .[$field]
    ' "$work_dir/pools.json"
}

human_bytes() {
    awk -v bytes="$1" 'BEGIN {
      split("B KiB MiB GiB TiB PiB", unit, " "); n=1;
      while (bytes >= 1024 && n < 6) { bytes /= 1024; n++ }
      if (n == 1) printf "%.0f %s", bytes, unit[n];
      else printf "%.2f %s", bytes, unit[n]
    }'
}

{
    printf 'CEPH STORAGE SUMMARY\n'
    printf 'Generated: %s\n' "$(date -Is)"
    printf 'Host: %s\n\n' "$(hostname -f 2>/dev/null || hostname)"

    printf 'CRUSH ROOT LAYOUT\n'
    printf '=================\n'

    for root in default computessd computehdd; do
        root_id=$(jq -r --arg root "$root" '.nodes[] | select(.type == "root" and .name == $root) | .id' "$work_dir/osd-tree.json")
        if [[ -z "$root_id" ]]; then
            printf '%s: not found\n\n' "$root"
            continue
        fi

        printf '%s\n' "$root"
        jq -r --arg root_id "$root_id" '
          .nodes as $nodes
          | $nodes[]
          | select(.type == "host" and ((.id) as $id
              | any($nodes[]; .id == ($root_id | tonumber) and ((.children // []) | index($id)))))
          | . as $host
          | "  └── \($host.name)",
            ([ $host.children[] as $osd_id
               | $nodes[] | select(.id == $osd_id) ]
             | sort_by(.device_class // "unknown", .id)
             | group_by(.device_class // "unknown")
             | .[]
             | "        └── " + ((.[0].device_class // "unknown") | ascii_upcase) +
               " osds_id:(" + ([.[].id | tostring] | join(",")) + ")")
        ' "$work_dir/osd-tree.json"
        printf '\n'
    done

    printf 'RBD BACKEND IMAGE COUNTS\n'
    printf '========================\n'
    printf '%-20s %12s   %s\n' 'POOL' 'IMAGE COUNT' 'NODEGROUP'

    for pool in cinder-volumes ephemeral-vms manila-volumes glance-images; do
        if ! rbd ls "$pool" >"$work_dir/rbd-${pool}.txt"; then
            printf '%-20s %12s   %s\n' "$pool" 'ERROR' 'unknown'
            continue
        fi

        if [[ "$pool" == "ephemeral-vms" ]]; then
            count=$(awk 'NF && $0 !~ /\.config$/ { count++ } END { print count+0 }' "$work_dir/rbd-${pool}.txt")
        else
            count=$(awk 'NF { count++ } END { print count+0 }' "$work_dir/rbd-${pool}.txt")
        fi

        rule_id=$(pool_field "$pool" crush_rule)
        nodegroup=$(root_for_rule "$rule_id")
        printf '%-20s %12s   %s\n' "$pool" "$count" "$nodegroup"
    done

    printf '\nALL POOLS\n'
    printf '=========\n'
    printf '%-45s  %-14s  %-18s  %s\n' 'POOL' 'STORED' 'NODEGROUP' 'POLICY'

    jq -r '.pools[]
      | [.name, (.stats.stored // 0)] | @tsv
    ' "$work_dir/df.json" |
    while IFS=$'\t' read -r pool stored; do
        detail=$(jq -r --arg pool "$pool" '
          .[] | select(.pool_name == $pool)
          | [.type, (.size // "-"), .crush_rule, (.erasure_code_profile // "-")] | @tsv
        ' "$work_dir/pools.json")
        IFS=$'\t' read -r pool_type size rule_id ec_profile <<<"$detail"
        nodegroup=$(root_for_rule "$rule_id")
        if [[ "$pool_type" == "1" || "$pool_type" == "replicated" ]]; then
            policy="replica-${size}"
        else
            policy="EC:${ec_profile}"
        fi
        printf '%-45s  %-14s  %-18s  %s\n' \
            "$pool" "$(human_bytes "$stored")" "$nodegroup" "$policy"
    done

    printf '\nRAW USAGE RECONCILIATION\n'
    printf '========================\n'
    printf '%-12s %14s %14s %14s %14s %14s %14s %10s %14s %14s %8s\n' \
        'ROOT' 'TOTAL SIZE' 'RAW USED' 'RESERVED' 'METADATA' 'ACTUAL DATA' 'AVAILABLE' 'REPLICATE' 'THEORETICAL' 'CEPH MAX AVAIL' 'USED%'

    total_size=0
    total_raw=0
    total_reserved=0
    total_metadata=0
    total_actual=0
    total_available=0
    total_theoretical=0
    total_ceph_max=0

    for root in computehdd default computessd; do
        root_usage=$(jq -r --arg root "$root" '
          .nodes[] | select(.type == "root" and .name == $root)
          | [((.kb // 0) * 1024), ((.kb_used // 0) * 1024),
             ((.kb_used_meta // 0) * 1024), ((.kb_avail // 0) * 1024),
             (.utilization // 0)]
          | @tsv
        ' "$work_dir/osd-df-tree.json")
        if [[ -n "$root_usage" ]]; then
            IFS=$'\t' read -r size_bytes raw_bytes metadata_bytes available_bytes utilization <<<"$root_usage"
        else
            size_bytes=0
            raw_bytes=0
            metadata_bytes=0
            available_bytes=0
            utilization=0
        fi

        actual_bytes=0
        while IFS=$'\t' read -r pool rule_id pool_used; do
            [[ -n "$pool" ]] || continue
            pool_root=$(parent_root_for_rule "$rule_id")
            [[ "$pool_root" == "$root" ]] || continue
            actual_bytes=$(awk -v a="$actual_bytes" -v b="$pool_used" 'BEGIN { printf "%.0f", a+b }')
        done < <(jq -r --slurpfile details "$work_dir/pools.json" '
          .pools[] as $usage
          | ($details[0][] | select(.pool_name == $usage.name)) as $detail
          | [$usage.name, $detail.crush_rule,
             ($usage.stats.bytes_used // 0)]
          | @tsv
        ' "$work_dir/df.json")

        reserved_bytes=$(awk -v raw="$raw_bytes" -v actual="$actual_bytes" '
          BEGIN { difference=raw-actual; if (difference < 0) difference=0; printf "%.0f", difference }
        ')

        case "$root" in
            default)    reference_pool=cinder-volumes ;;
            computessd) reference_pool=ephemeral-vms ;;
            computehdd) reference_pool=manila-volumes ;;
        esac
        replicate=$(jq -r --arg pool "$reference_pool" '
          .[] | select(.pool_name == $pool) | (.size // "-")
        ' "$work_dir/pools.json")
        [[ -n "$replicate" ]] || replicate='-'
        if [[ "$replicate" =~ ^[1-9][0-9]*$ ]]; then
            theoretical_bytes=$(awk -v available="$available_bytes" -v copies="$replicate" '
              BEGIN { printf "%.0f", available/copies }
            ')
        else
            theoretical_bytes=0
        fi
        ceph_max_bytes=$(jq -r --arg pool "$reference_pool" '
          .pools[] | select(.name == $pool) | (.stats.max_avail // 0)
        ' "$work_dir/df.json")
        [[ -n "$ceph_max_bytes" ]] || ceph_max_bytes=0

        printf '%-12s %14s %14s %14s %14s %14s %14s %10s %14s %14s %7.2f%%\n' "$root" \
            "$(human_bytes "$size_bytes")" "$(human_bytes "$raw_bytes")" \
            "$(human_bytes "$reserved_bytes")" "$(human_bytes "$metadata_bytes")" \
            "$(human_bytes "$actual_bytes")" \
            "$(human_bytes "$available_bytes")" "$replicate" \
            "$(human_bytes "$theoretical_bytes")" "$(human_bytes "$ceph_max_bytes")" "$utilization"

        total_size=$(awk -v a="$total_size" -v b="$size_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_raw=$(awk -v a="$total_raw" -v b="$raw_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_reserved=$(awk -v a="$total_reserved" -v b="$reserved_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_metadata=$(awk -v a="$total_metadata" -v b="$metadata_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_actual=$(awk -v a="$total_actual" -v b="$actual_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_available=$(awk -v a="$total_available" -v b="$available_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_theoretical=$(awk -v a="$total_theoretical" -v b="$theoretical_bytes" 'BEGIN { printf "%.0f", a+b }')
        total_ceph_max=$(awk -v a="$total_ceph_max" -v b="$ceph_max_bytes" 'BEGIN { printf "%.0f", a+b }')
    done

    total_utilization=$(awk -v used="$total_raw" -v size="$total_size" '
      BEGIN { if (size > 0) printf "%.2f", used*100/size; else print "0.00" }
    ')
    printf '%-12s %14s %14s %14s %14s %14s %14s %10s %14s %14s %7.2f%%\n' 'TOTAL' \
        "$(human_bytes "$total_size")" "$(human_bytes "$total_raw")" \
        "$(human_bytes "$total_reserved")" "$(human_bytes "$total_metadata")" \
        "$(human_bytes "$total_actual")" \
        "$(human_bytes "$total_available")" '-' "$(human_bytes "$total_theoretical")" \
        "$(human_bytes "$total_ceph_max")" "$total_utilization"
    printf '\nFormulas:\n'
    printf '  RAW USED - RESERVED = ACTUAL DATA\n'
    printf '  TOTAL SIZE - RAW USED = AVAILABLE\n'
    printf '  AVAILABLE / REPLICATE = THEORETICAL\n'
    printf 'Reserved is raw OSD usage not attributed to pools by bytes_used.\n'
    printf 'METADATA is Ceph-reported OSD metadata and is included within RESERVED.\n'
    printf 'CEPH MAX AVAIL is the representative backend pool max_avail from ceph df.\n'
} >"$report"

printf 'Report written to: %s\n' "$report"
