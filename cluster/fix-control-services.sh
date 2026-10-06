#!/usr/bin/env bash
# Daily-routine fixer for two CubeCOS control-plane incidents (see ./issues/):
#   rabbitmq  RabbitMQ split brain  (one controller clustered alone)
#   mariadb   MariaDB/Galera cluster recovery
#
# DRY-RUN BY DEFAULT: diagnoses and prints every command it would run.
# Nothing changes unless --apply is given.
#
# Host list always comes from:  cubectl node list -r control
# Run as root on any controller. Needs root SSH trust to every controller.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: bash fix-control-services.sh <rabbitmq|mariadb|all> [--apply] [--good NODE]

  rabbitmq   Find controllers outside the majority RabbitMQ partition and
             re-join them: stop_app, reset, join_cluster rabbit@<majority>,
             start_app. One node at a time. Needs a strict majority group.
  mariadb    Galera recovery, you pick the GOOD node.
               no --good : report only (unit, wsrep state, seqno per node).
               --good N  : N is kept and bootstrapped (safe_to_bootstrap=1,
                 galera_new_cluster, start mariadb). The other nodes ALWAYS
                 get /var/lib/mysql moved to /var/lib/mysql-bak-<timestamp>,
                 a fresh empty datadir, then start mariadb (SST from N).
                 Dry-run unless --apply. --apply writes a log file.
  all        rabbitmq then mariadb (mariadb --good must still be given if
             Galera has no Primary).

  --apply      Really execute. Without it, dry-run only.
  --good NODE  mariadb: node whose datadir is kept and bootstrapped.
  Log (apply only): ./fix-control-services-<target>-<timestamp>.log

Datadirs are MOVED to /var/lib/mysql-bak-<timestamp>, never deleted. Delete the
backups yourself once the cluster is verified (each is a full datadir).
Exit: 0 healthy / fixed / dry-run done; 1 refused or error; 2 problem found
      in dry-run.
EOF
}
die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: command failed at line $LINENO. Earlier changes are retained; no rollback attempted." >&2' ERR

target="" apply=0 good=""
while (( $# )); do
    case $1 in
        rabbitmq|mariadb|all) target=$1 ;;
        --apply) apply=1 ;;
        --good)  good=${2:?--good needs a node name}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
    shift
done
[[ -n $target ]] || { usage; exit 1; }
for tool in cubectl ssh jq timeout awk; do
    command -v "$tool" >/dev/null || die "Missing command: $tool"
done
(( EUID == 0 )) || die 'Run as root on a controller.'

if (( apply )); then
    LOG="$PWD/fix-control-services-$target-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG") 2>&1
    echo "Log file: $LOG"
fi

say()  { printf '\n=== %s ===\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
rsh() {  # rsh HOST CMD...
    local ip=${IP[$1]}; shift
    timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=8 "root@$ip" "$@"
}
# act HOST CMD : run on HOST when --apply, else only print.
act() {
    local host=$1 cmd=$2
    if (( apply )); then
        echo "[RUN]     $host: $cmd"
        rsh "$host" "$cmd"
    else
        echo "[DRY-RUN] $host: $cmd"
    fi
}

# ---- host list: always from cubectl ---------------------------------------
declare -A IP
NODES=()
while IFS=, read -r name ip _role; do
    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && $ip =~ ^[0-9.]+$ ]] || continue
    NODES+=("$name"); IP[$name]=$ip
done < <(cubectl node list -r control)
N=${#NODES[@]}
(( N >= 1 )) || die 'cubectl node list -r control returned no nodes.'
say "Control nodes ($N): $(for n in "${NODES[@]}"; do printf '%s(%s) ' "$n" "${IP[$n]}"; done)"
if (( apply )); then echo 'MODE: APPLY'; else echo 'MODE: DRY-RUN (no changes; add --apply to execute)'; fi
problem=0

# ---- rabbitmq --------------------------------------------------------------
rabbit_view() {  # sorted, space-separated running_nodes as seen from $1
    rsh "$1" "hex_config status_rabbitmq | jq -r '.running_nodes[]'" 2>/dev/null \
        | sed 's/^rabbit@//' | sort | tr '\n' ' ' | sed 's/ $//'
}

fix_rabbitmq() {
    say 'RabbitMQ: cluster view per controller'
    local -A view; local n unreachable=0
    for n in "${NODES[@]}"; do
        view[$n]=$(rabbit_view "$n" || true)
        if [[ -z ${view[$n]} ]]; then
            echo "  $n: UNREACHABLE / no answer"; unreachable=1
        else
            echo "  $n: ${view[$n]}"
        fi
    done
    (( ! unreachable )) || die 'a controller gave no RabbitMQ answer; fix that first (node down is not a split brain).'

    # Majority group = the most common identical view.
    local vs best="" bestcount=0 count
    while IFS= read -r vs; do
        count=0
        for n in "${NODES[@]}"; do [[ ${view[$n]} == "$vs" ]] && count=$((count+1)); done
        if (( count > bestcount )); then best=$vs; bestcount=$count; fi
    done < <(printf '%s\n' "${view[@]}" | sort -u)

    if (( bestcount == N )) && [[ $(wc -w <<<"$best") -eq N ]]; then
        echo "RabbitMQ OK: all $N controllers see: $best"; return 0
    fi
    (( bestcount * 2 > N )) || die "no majority RabbitMQ group (best group has $bestcount of $N). Not safe to automate; investigate by hand."
    problem=1
    echo "Majority group ($bestcount/$N): $best"

    local peer=${best%% *} bad=()
    for n in "${NODES[@]}"; do [[ ${view[$n]} == "$best" ]] || bad+=("$n"); done
    echo "Nodes to re-join via rabbit@$peer: ${bad[*]}"

    for n in "${bad[@]}"; do
        say "RabbitMQ: re-join $n"
        act "$n" "rabbitmqctl stop_app"
        act "$n" "rabbitmqctl reset"
        act "$n" "rabbitmqctl join_cluster rabbit@$peer"
        act "$n" "rabbitmqctl start_app"
    done

    if (( apply )); then
        say 'RabbitMQ: verify'
        local ok=1 got
        for n in "${NODES[@]}"; do
            got=$(rabbit_view "$n" || true)
            echo "  $n: $got"
            [[ $(wc -w <<<"$got") -eq $N ]] || ok=0
        done
        (( ok )) || die 'verification failed: not every controller sees all nodes.'
        echo 'RabbitMQ FIXED.'; problem=0
    fi
}

# ---- mariadb / galera ------------------------------------------------------
wsrep() {  # wsrep HOST VARIABLE -> value, or empty
    rsh "$1" "mysql -N -e \"SHOW STATUS LIKE '$2'\"" 2>/dev/null | awk '{print $2}' || true
}
unit_state() { rsh "$1" "systemctl is-active mariadb" 2>/dev/null || true; }

move_datadir() {  # move_datadir HOST TS
    local h=$1 ts=$2
    act "$h" "systemctl stop mariadb || true"
    act "$h" "[ ! -e /var/lib/mysql-bak-$ts ] && mv /var/lib/mysql /var/lib/mysql-bak-$ts"
    act "$h" "mkdir /var/lib/mysql && chown mysql:mysql /var/lib/mysql && chmod 755 /var/lib/mysql"
    act "$h" "command -v restorecon >/dev/null && restorecon -R /var/lib/mysql || true"
}

# Datadir is moved, not copied, but refuse if /var/lib is nearly full
# (kb/cubecos/known-issues/health-mysql-repair-unbounded-datadir-copies.md).
disk_check() {
    local h pct
    for h in "$@"; do
        pct=$(rsh "$h" "df --output=pcent /var/lib | tail -1 | tr -dc 0-9" 2>/dev/null || echo 100)
        (( pct < 90 )) || die "$h: /var/lib is ${pct}% full; free space before a Galera SST."
    done
}

fix_mariadb() {
    local n st size status seq ts; ts=$(date +%Y%m%d-%H%M%S)
    local -A ustate
    say 'MariaDB/Galera: step 1 - report (all control nodes)'
    for n in "${NODES[@]}"; do
        ustate[$n]=$(unit_state "$n")
        st=$(wsrep "$n" wsrep_local_state_comment)
        size=$(wsrep "$n" wsrep_cluster_size)
        status=$(wsrep "$n" wsrep_cluster_status)
        seq=$(rsh "$n" "awk '/^seqno:/{print \$2}' /var/lib/mysql/grastate.dat" 2>/dev/null || echo '?')
        printf '  %-12s unit=%-10s wsrep_state=%-8s cluster_status=%-12s size=%-3s grastate.seqno=%s safe_to_bootstrap=%s\n' \
            "$n" "${ustate[$n]:-?}" "${st:--}" "${status:--}" "${size:--}" "$seq" \
            "$(rsh "$n" "awk '/^safe_to_bootstrap:/{print \$2}' /var/lib/mysql/grastate.dat" 2>/dev/null || echo '?')"
        [[ $st == Synced ]] || problem=1
    done
    if (( ! problem )); then echo "Galera OK: all $N nodes Synced. Nothing to fix."; return 0; fi

    if [[ -z $good ]]; then
        warn 'Galera is not healthy. YOU decide which node is GOOD (newest data / highest seqno; check the mariadb log if unsure).'
        warn "Then run: bash $0 mariadb --good <NODE> [--apply]    (nodes: ${NODES[*]})"
        return 0
    fi
    [[ -n ${IP[$good]:-} ]] || die "--good $good is not a control node (${NODES[*]})."
    for n in "${NODES[@]}"; do
        [[ ${ustate[$n]} != activating ]] || die "$n is 'activating' (probably an SST in progress). Wait; do not interrupt recovery."
    done
    local others=()
    for n in "${NODES[@]}"; do [[ $n == "$good" ]] || others+=("$n"); done
    disk_check "${NODES[@]}"

    say "MariaDB/Galera: step 2 - fix. GOOD=$good  backup+rebuild=${others[*]}  backup suffix=$ts"
    for n in "${others[@]}"; do
        say "Backup + wipe $n  (/var/lib/mysql -> /var/lib/mysql-bak-$ts)"
        move_datadir "$n" "$ts"
    done
    say "Prepare $good"
    act "$good" "systemctl stop mariadb || true"
    act "$good" "sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat"
    act "$good" "grep -E 'seqno|safe_to_bootstrap' /var/lib/mysql/grastate.dat"
    say "Bootstrap $good"
    act "$good" "galera_new_cluster"
    act "$good" "systemctl start mariadb"
    for n in "${others[@]}"; do
        say "Start $n"
        act "$n" "systemctl start mariadb"
    done

    if (( apply )); then
        say 'MariaDB/Galera: step 3 - verify (waiting up to 10 min for SST)'
        local i ok=0
        for i in $(seq 1 60); do
            ok=1
            for n in "${NODES[@]}"; do [[ $(wsrep "$n" wsrep_local_state_comment) == Synced ]] || ok=0; done
            (( ok )) && break
            sleep 10
        done
        for n in "${NODES[@]}"; do echo "  $n: $(wsrep "$n" wsrep_local_state_comment) size=$(wsrep "$n" wsrep_cluster_size)"; done
        (( ok )) || die 'Galera did not reach Synced on all nodes in time. Do NOT re-run blindly; check mariadb logs.'
        echo "Galera FIXED. Backups: ${others[*]} -> /var/lib/mysql-bak-$ts (delete when satisfied)."
        problem=0
    fi
}

case $target in
    rabbitmq) fix_rabbitmq ;;
    mariadb)  fix_mariadb ;;
    all)      fix_rabbitmq; fix_mariadb ;;
esac

if (( problem && ! apply )); then
    say 'Dry-run finished: problem(s) found. Review the plan above, then re-run with --apply.'
    exit 2
fi
exit 0
