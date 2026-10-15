#!/usr/bin/env bash
# Run as root on a quorate controller (FET: 192.168.84.100).
# Requires Bash, pcs, corosync-quorumtool, ssh, timeout, awk, grep.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: bash repair-pacemaker-remote.sh [--check|--apply] NODE [NODE ...]

Run locally as root on 192.168.84.100 (or another cluster controller).
NODE must be both the remote resource ID and its SSH hostname.
Check-only is the default. --apply starts inactive/failed pacemaker_remote
services, checks TCP/3121, and clears failures only for the named resources.
Requires existing hostname SSH trust and root authorized_keys.

Examples:
  bash repair-pacemaker-remote.sh --check ak-coscp02p ak-coscp03p ak-coscp51p
  bash repair-pacemaker-remote.sh --apply ak-coscp02p ak-coscp03p ak-coscp51p

Exit: 0 = targets healthy; 1 = stopped/error; 2 = unhealthy check or remaining
cluster failures/offline nodes/orphan warnings. Review printed pcs warnings.
EOF
}
die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; no broad cleanup or rollback attempted." >&2' ERR
mode=check
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --apply) mode=apply; shift ;;
    --check) shift ;;
esac
(( $# > 0 )) || { usage; exit 1; }
nodes=("$@")
for node in "${nodes[@]}"; do
    [[ $node =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid node: $node"
done
for tool in pcs corosync-quorumtool ssh timeout awk grep; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
(( EUID == 0 )) || die 'Run as root on the controller.'
remote() {
    local host=$1; shift
    timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=yes "root@$host" "$@"
}
quorum() { timeout 15 corosync-quorumtool -s >/dev/null || die 'Controller does not have quorum.'; }
status() { timeout 30 pcs status --full; }
port_open() { timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/3121"' _ "$1" 2>/dev/null; }
online() {
    awk -v n="$1" '$1=="*" && $2=="RemoteNode" && $3==n":" && $4=="online" {found=1} END {exit !found}' <<<"$2"
}
started() {
    awk -v n="$1" '$1=="*" && $2==n && $3=="(ocf:pacemaker:remote):" && $4=="Started" {found=1} END {exit !found}' <<<"$2"
}
clean_target() {
    local n=$1 text=$2
    online "$n" "$text" && started "$n" "$text" || return 1
    # Scope failure/history matching to the exact resource ID.
    ! awk -v n="$n" '$1=="*" && (($2==n":" && /fail-count=[1-9]/) || index($2,n"_")==1) {bad=1} END {exit !bad}' <<<"$text"
}
online_names() {
    awk '$1=="*" && $2=="RemoteNode" && $4=="online" {sub(/:$/,"",$3); print $3}
         $1=="*" && $2=="Node" && /: online/ {print $3}' <<<"$1"
}

quorum
before=$(status)
printf '%s\n' "$before"
# Fail closed if this pcs version does not expose the expected full node format.
grep -q 'RemoteNode ' <<<"$before" || die 'Unsupported pcs full-status format; inspect manually.'
props=$(timeout 30 pcs property config)
if [[ $mode == apply ]] && grep -Eq '(maintenance-mode|stop-all-resources)=(true|yes|1)' <<<"$props"; then
    die 'Cluster maintenance or stop-all mode is enabled.'
fi
states=()
for node in "${nodes[@]}"; do
    cfg=$(timeout 30 pcs resource config "$node")
    grep -Fq "Resource: $node (class=ocf provider=pacemaker type=remote)" <<<"$cfg" || die "$node is not an ocf:pacemaker:remote resource."
    server=$(awk '/^[[:space:]]*server=/ {sub(/^[[:space:]]*server=/,""); print; exit}' <<<"$cfg")
    [[ -z $server || $server == "$node" ]] || die "$node uses server=$server; this script requires matching resource ID and hostname."
    port=$(awk '/^[[:space:]]*port=/ {sub(/^[[:space:]]*port=/,""); print; exit}' <<<"$cfg")
    [[ -z $port || $port == 3121 ]] || die "$node uses nonstandard port $port; inspect manually."
    if [[ $mode == apply ]]; then
        grep -Eiq '(target-role=Stopped|is-managed=false|maintenance=true)' <<<"$cfg" && die "$node is administratively stopped/unmanaged." 
        line=$(awk -v n="$node" '$2=="RemoteNode" && $3==n":" {print}' <<<"$before")
        [[ -n $line ]] || die "$node missing from node status."
        grep -Eiq 'standby|maintenance|UNCLEAN|unmanaged' <<<"$line" && die "$node is standby, in maintenance, or unclean."
    fi
    # Suppress is-active's expected nonzero status, but propagate SSH failures.
    state=$(remote "$node" 'systemctl is-active pacemaker_remote || test "$?" -eq 3') || die "Cannot inspect $node over SSH."
    case "$state" in active|inactive|failed) ;; *) die "$node: unexpected service state: $state" ;; esac
    states+=("$state")
    tcp=closed; if port_open "$node"; then tcp=open; fi
    echo "$node: pacemaker_remote=$state TCP/3121=$tcp"
    if [[ $mode == apply && $state == active && $tcp != open ]]; then
        die "$node: active service but inaccessible port; diagnose networking/authentication first."
    fi
done
if [[ $mode == check ]]; then
    result=0
    for i in "${!nodes[@]}"; do
        node=${nodes[$i]}
        if [[ ${states[$i]} != active ]] || ! port_open "$node" || ! clean_target "$node" "$before"; then result=2; fi
    done
    echo "Check complete; no changes made. Target result=$result."
    exit "$result"
fi

for i in "${!nodes[@]}"; do
    node=${nodes[$i]}
    quorum
    if [[ ${states[$i]} != active ]]; then
        echo "Starting pacemaker_remote on $node"
        remote "$node" 'systemctl start pacemaker_remote'
    fi
    listening=false
    for ((attempt=0; attempt<10; attempt++)); do
        if port_open "$node"; then listening=true; break; fi
        sleep 2
    done
    [[ $listening == true ]] || die "$node: TCP/3121 still closed; cleanup skipped."
    remote "$node" 'systemctl is-active --quiet pacemaker_remote' || die "$node service did not stay active."
    quorum
    timeout 60 pcs resource cleanup "$node"
done

# Require 75 continuous healthy seconds: exceeds the incident's 60s monitor.
stable=0
for ((poll=0; poll<36; poll++)); do
    quorum
    current=$(status)
    while IFS= read -r name; do
        [[ -z $name ]] && continue
        online_names "$current" | grep -Fxq "$name" || die "Previously online node $name went offline."
    done < <(online_names "$before")
    if ! grep -q 'Failed Resource Actions:' <<<"$before" && grep -q 'Failed Resource Actions:' <<<"$current"; then
        die 'New failed resource actions appeared; inspect pcs status.'
    fi
    healthy=true
    for node in "${nodes[@]}"; do
        clean_target "$node" "$current" || healthy=false
    done
    if [[ $healthy == true ]]; then
        if (( stable >= 75 )); then break; fi
        stable=$((stable+5))
    else
        stable=0
    fi
    echo "Observing recovery: targets healthy=$healthy; stable observation=$stable/75 seconds"
    sleep 5
done
[[ $healthy == true && $stable -ge 75 ]] || die 'Recovery did not stabilize within the bounded observation window.'
printf '%s\n' "$current"
for node in "${nodes[@]}"; do
    remote "$node" 'systemctl is-active pacemaker_remote; systemctl --failed --no-legend --no-pager'
done
echo 'Named remote resources recovered and observed through a full monitor cycle.'
if grep -Eq 'Failed Resource Actions:|ORPHANED|OFFLINE|UNCLEAN' <<<"$current"; then
    echo 'Remaining cluster issues are shown above; they were not automatically changed.'
    exit 2
fi
echo 'Review any Corosync naming or feature/version warnings separately.'
