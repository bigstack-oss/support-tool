#!/usr/bin/env bash
# Restore ocf:pacemaker:remote resources that are MISSING from the CIB
# (absent from `pcs resource config`, not merely RemoteOFFLINE).
# For RemoteOFFLINE remotes use support-team-skills repair-pacemaker-remote-offline.
#
# Run as root on a quorate CubeCOS controller, preferably the DC.
# Requires: pcs, cibadmin, crm_mon, crm_node, corosync-quorumtool, ssh, timeout,
#           awk, grep, md5sum. Root SSH trust by hostname to every node.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: bash restore-pacemaker-remote-missing.sh [--check|--apply] [--since TIME] [--ref NODE] [NODE ...]

  --check        Default. Read-only diagnosis; makes no changes.
  --apply        Re-register each NODE as a pacemaker remote, one at a time.
  --since TIME   journalctl window for log forensics (default: today),
                 e.g. --since "2026-10-05 16:00".
  --ref NODE     Healthy existing remote used as the authkey reference
                 (default: first remote resource found in the CIB).
  NODE           Remote resource ID == hostname (default: idc-bs-cs01..03).

Apply, per node: requires quorum and no maintenance mode, and requires the
resource to be absent from the CIB. Starts pacemaker_remote only if it is
inactive. Requires the authkey to match --ref and TCP/3121 to be open. Then runs
`hex_sdk pacemaker_remote_add NODE`, or falls back to `pcs resource create` with
the same parameters as the reference remote if that function is missing. Waits
for RemoteOnline and Started, running one scoped cleanup if needed.

Exit: 0 = all targets ready (check) / restored (apply); 1 = stopped/error;
      2 = check found targets that are not ready.
EOF
}
die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; no rollback attempted." >&2' ERR

mode=check since=today ref="" nodes=()
while (( $# )); do
    case $1 in
        --check) mode=check ;;
        --apply) mode=apply ;;
        --since) since=${2:?--since needs a value}; shift ;;
        --ref)   ref=${2:?--ref needs a value}; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage; die "Unknown option: $1" ;;
        *) nodes+=("$1") ;;
    esac
    shift
done
(( ${#nodes[@]} )) || nodes=(idc-bs-cs01 idc-bs-cs02 idc-bs-cs03)
for n in "${nodes[@]}" ${ref:+"$ref"}; do
    [[ $n =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid node name: $n"
done
for tool in pcs cibadmin crm_mon crm_node corosync-quorumtool ssh timeout awk grep md5sum; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
(( EUID == 0 )) || die 'Run as root on a controller.'

say()    { printf '\n=== %s ===\n' "$*"; }
try()    { "$@" 2>&1 || echo "(exit $?)"; }
remote() {
    local host=$1; shift
    timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=yes "root@$host" "$@"
}
quorate()  { timeout 15 corosync-quorumtool -s >/dev/null 2>&1; }
port_open(){ timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/3121"' _ "$1" 2>/dev/null; }
in_cib()   { cibadmin --query --xpath "//primitive[@id='$1']" >/dev/null 2>&1; }
mon_xml()  { timeout 30 crm_mon -1 --output-as=xml 2>/dev/null || true; }
remote_online() { grep -Eq "<node name=\"$1\"[^>]*online=\"true\"[^>]*type=\"remote\"" <<<"$2"; }
res_started()   { grep -Eq "<resource id=\"$1\"[^>]*role=\"Started\"" <<<"$2"; }
online_count()  { grep -c '<node name="[^"]*"[^>]*online="true"' <<<"$1" || true; }
svc_state()     { remote "$1" 'systemctl is-active pacemaker_remote' 2>/dev/null || true; }
authkey_sum()   { remote "$1" 'md5sum /etc/pacemaker/authkey' 2>/dev/null | awk '{print $1}' || true; }
target_re=$(IFS='|'; echo "${nodes[*]}")

# Existing remote resources in the CIB, and the reference node.
existing=$(cibadmin --query --xpath "//primitive[@class='ocf'][@provider='pacemaker'][@type='remote']" 2>/dev/null \
    | grep -o '<primitive id="[^"]*"' | cut -d'"' -f2 || true)
if [[ -z $ref ]]; then
    ref=$(grep -vxE "$target_re" <<<"$existing" | head -1 || true)
fi
ref_sum=""; [[ -n $ref ]] && ref_sum=$(authkey_sum "$ref")

# Does this CubeCOS build ship hex_sdk pacemaker_remote_add?
hex_has_remote_add() {
    local bin pkg found=""
    bin=$(command -v hex_sdk 2>/dev/null) || return 1
    found=$(grep -ls 'pacemaker_remote_add' "$bin" 2>/dev/null || true)
    if [[ -z $found ]] && pkg=$(rpm -qf "$bin" 2>/dev/null); then
        found=$(rpm -ql "$pkg" 2>/dev/null | xargs -r grep -ls 'pacemaker_remote_add' 2>/dev/null || true)
    fi
    [[ -n $found ]] && { echo "$found" | head -3; return 0; }
    return 1
}

# Parameters of the reference remote, so a pcs fallback matches it exactly.
ref_monitor_args() {
    local cfg interval timeout_
    cfg=$(pcs resource config "$ref" 2>/dev/null || true)
    interval=$(awk '/monitor:/ {m=1; next} m && /interval=/ {for(i=1;i<=NF;i++) if($i~/^interval=/) {sub(/interval=/,"",$i); print $i; exit}}' <<<"$cfg")
    timeout_=$(awk '/monitor:/ {m=1; next} m && /timeout=/ {for(i=1;i<=NF;i++) if($i~/^timeout=/) {sub(/timeout=/,"",$i); print $i; exit}}' <<<"$cfg")
    echo "op monitor interval=${interval:-60s} timeout=${timeout_:-30s}"
}

# ------------------------------------------------------------------ check
check() {
    local result=0 n st tcp sum ctl self
    self=$(hostname -s)
    echo "Host: $(hostname)  Date: $(date)  Mode: $mode  Targets: ${nodes[*]}  Ref: ${ref:-<none>}"

    say "1. Cluster summary"
    try timeout 30 pcs status
    try timeout 15 corosync-quorumtool -s
    try timeout 30 pcs property config | grep -Ei 'maintenance|stop-all|stonith' || true

    say "2. Remote resources in CIB"
    echo "Existing ocf:pacemaker:remote: ${existing:-<none>}" | tr '\n' ' '; echo
    for n in "${nodes[@]}"; do
        if in_cib "$n"; then echo "$n: PRESENT in CIB (use repair-pacemaker-remote-offline instead)"
        else echo "$n: MISSING from CIB"; fi
    done

    say "3. Leftover references to targets (constraints / node_state)"
    try timeout 30 pcs constraint --full | grep -E "$target_re" || echo "(no constraints)"
    try cibadmin --query | grep -E "$target_re" | head -40 || echo "(no CIB references)"

    say "4. Per-node sync state (/etc/revision, etcd-watch, pacemaker_remote)"
    local all
    all=$( { timeout 20 cubectl node list 2>/dev/null | cut -d, -f1; crm_node -l 2>/dev/null | awk '{print $2}'; \
             printf '%s\n' "${nodes[@]}" $existing; } | awk 'NF && !seen[$0]++' )
    for n in $all; do
        printf '%-20s rev=%-8s etcd-watch=%-10s pacemaker_remote=%s\n' "$n" \
            "$(remote "$n" cat /etc/revision 2>/dev/null || echo '?')" \
            "$(remote "$n" systemctl is-active etcd-watch 2>/dev/null || echo '?')" \
            "$(svc_state "$n" || echo '?')"
    done

    say "5. Target readiness (service, TCP/3121, authkey vs ${ref:-<none>}=${ref_sum:-?})"
    for n in "${nodes[@]}"; do
        st=$(svc_state "$n"); [[ -n $st ]] || st=unreachable
        tcp=closed; port_open "$n" && tcp=open
        sum=$(authkey_sum "$n")
        printf '%-20s pacemaker_remote=%-12s TCP/3121=%-7s authkey=%s\n' "$n" "$st" "$tcp" \
            "$( [[ -z $sum ]] && echo MISSING || { [[ $sum == "$ref_sum" ]] && echo match || echo MISMATCH; } )"
        if [[ $st != active || $tcp != open || -z $sum || $sum != "$ref_sum" ]] || in_cib "$n"; then result=2; fi
    done

    say "6. Logs on $self since '$since'"
    try grep -E "$target_re" /var/log/pacemaker/pacemaker.log 2>/dev/null \
        | grep -iE 'cib|delete|remove|Diff|--' | tail -40 || true
    try journalctl --since "$since" --no-pager 2>/dev/null \
        | grep -iE 'pacemaker_remote_(add|del|remove)|cluster_map_update' | tail -40 || true

    say "7. Who changed the CIB: other controllers since '$since'"
    for ctl in $(crm_node -l 2>/dev/null | awk '{print $2}'); do
        [[ $ctl == "$self" || $ctl == "$(hostname)" ]] && continue
        echo "--- $ctl"
        remote "$ctl" "journalctl --since '$since' --no-pager | grep -E 'pcs |crm_|cibadmin|hex_sdk|cubectl|pacemaker_remote' | tail -30; \
                       echo '- bash_history:'; grep -E 'pcs |crm |cibadmin|hex_sdk|cubectl' /root/.bash_history | tail -20" \
            2>&1 || echo "(unreachable)"
    done

    say "8. ovndb constraints (new remotes may get an ovndb instance, as cs04 has)"
    try timeout 30 pcs constraint --full | grep -i ovndb || echo "(no ovndb constraints)"

    say "9. Registration method"
    if hex_has_remote_add; then echo "hex_sdk pacemaker_remote_add: available (above)"
    else echo "hex_sdk pacemaker_remote_add: NOT found; apply will use: pcs resource create <n> ocf:pacemaker:remote server=<n> $(ref_monitor_args)"; fi

    say "Result"
    (( result == 0 )) && echo "All targets ready for --apply." || echo "Some targets not ready (see sections 2 and 5). result=$result"
    return "$result"
}

# ------------------------------------------------------------------ apply
apply_one() {
    local n=$1 st sum before_online xml waited=0 cleaned=false use_hex=$2
    say "Restoring $n"
    quorate || die 'Controller does not have quorum.'
    timeout 30 pcs property config | grep -Eq '(maintenance-mode|stop-all-resources)=(true|yes|1)' \
        && die 'Cluster maintenance or stop-all mode is enabled.'
    if in_cib "$n"; then echo "$n already in CIB; skipping (use repair-pacemaker-remote-offline if it is offline)."; return 0; fi

    st=$(svc_state "$n")
    case $st in
        active) ;;
        inactive|failed) echo "Starting pacemaker_remote on $n"; remote "$n" 'systemctl start pacemaker_remote' ;;
        *) die "$n: cannot inspect pacemaker_remote over SSH (state='$st')." ;;
    esac

    sum=$(authkey_sum "$n")
    [[ -n $ref_sum ]] || die "No reference authkey (ref=${ref:-none}); pass --ref <healthy remote>."
    [[ -n $sum ]] || die "$n: /etc/pacemaker/authkey missing; copy it from $ref first."
    [[ $sum == "$ref_sum" ]] || die "$n: authkey differs from $ref; fix before adding."

    for ((i=0; i<10; i++)); do port_open "$n" && break; sleep 2; done
    port_open "$n" || die "$n: TCP/3121 still closed; not adding resource."
    remote "$n" 'systemctl is-active --quiet pacemaker_remote' || die "$n: pacemaker_remote did not stay active."

    xml=$(mon_xml); before_online=$(online_count "$xml")
    if [[ $use_hex == true ]]; then
        echo "Running: hex_sdk pacemaker_remote_add $n"
        hex_sdk pacemaker_remote_add "$n"
    else
        echo "Running: pcs resource create $n ocf:pacemaker:remote server=$n $(ref_monitor_args)"
        # shellcheck disable=SC2046  # word-split op args on purpose
        pcs resource create "$n" ocf:pacemaker:remote server="$n" $(ref_monitor_args)
    fi
    sleep 3
    in_cib "$n" || die "$n: resource still not in CIB after add; inspect manually."

    while (( waited < 180 )); do
        xml=$(mon_xml)
        if remote_online "$n" "$xml" && res_started "$n" "$xml"; then
            echo "$n: RemoteOnline and Started after ${waited}s"; break
        fi
        if (( waited == 120 )) && [[ $cleaned == false ]]; then
            echo "$n not online after 120s; scoped cleanup"; timeout 60 pcs resource cleanup "$n"; cleaned=true
        fi
        sleep 5; waited=$((waited+5))
    done
    remote_online "$n" "$xml" && res_started "$n" "$xml" || die "$n did not come online within 180s."
    (( $(online_count "$xml") > before_online )) || die "Online node count did not increase; another node may have dropped."
}

if [[ $mode == check ]]; then
    rc=0; check || rc=$?
    echo; echo "Check complete; no changes made."
    exit "$rc"
fi

quorate || die 'Controller does not have quorum.'
use_hex=false
if hex_has_remote_add >/dev/null; then use_hex=true; fi
echo "Registration method: $( [[ $use_hex == true ]] && echo 'hex_sdk pacemaker_remote_add' || echo 'pcs resource create (fallback)' )"
for n in "${nodes[@]}"; do apply_one "$n" "$use_hex"; done

say "Final state"
timeout 30 pcs status
timeout 30 pcs resource failcount show --full || true
echo
echo "Restored: ${nodes[*]}"
echo "Follow-ups, not changed by this script:"
echo " - Any OFFLINE corosync controller (e.g. idc-bs-mgmt01): find the 16:17 change first, then 'cubectl this-node start' on it."
echo " - Check that ovndb_servers instances on the new remotes are intended (pcs constraint --full | grep ovndb)."
echo " - If the remotes disappear again, find what removed them in the --check logs (sections 6-7)."
grep -Eq 'Failed Resource Actions:|OFFLINE|UNCLEAN' <<<"$(timeout 30 pcs status)" && exit 2
exit 0
