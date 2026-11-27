#!/usr/bin/env bash
# Rancher downstream-cluster operations on CubeCOS (watch, registry mirrors, offline images). See usage().
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: bash rancher-operation.sh <--watch|--cleanup|--connect|--node-cmd|--repo|--download|--upload|--verify> [args]

  --watch [CLUSTER] [--once]
             Run on a controller. Follow provisioning like the UI log:
             condition changes, machine phases, plan failures (failed-output),
             failed machine-provision jobs. No CLUSTER: list all clusters and
             ask for a number. --once: one pass instead of following.
             Exit: 0 Ready, 1 timeout / not ready, 2 cluster not found.
  --cleanup [CLUSTER] [--yes]
             Run on a controller, after fixing a machine pool in the Rancher UI.
             Lists MachineSets still on an old template (they keep re-creating
             machines with the old, broken settings), shows what changed
             (old -> new, secrets masked), and deletes the ones none of whose
             machines ever joined the cluster. Sets with joined machines are a
             normal rolling update and are kept. Then lists Rancher
             helm-operation-* pods in the cluster whose helm container ended
             (>120s) while the proxy sidecar runs on (Running 1/2 forever;
             blocks appctl "waiting for all pods to be ready"): exit code,
             last helm output, the release's status now; deletes them.
             Asks first; --yes skips it.
  --connect [CLUSTER] [MACHINE] [-- COMMAND...]
             Run on a controller. SSH into a VM of the cluster: no CLUSTER /
             MACHINE: list and ask for a number. Takes the machine's SSH key
             (secret <machine>-machine-state, as the UI "Download SSH Key") to
             KEY_DIR/<machine>-id_rsa (600, KEY_DIR private), the VM's floating IP (openstack
             server by its ID from machine-state; none: the IP Rancher
             uses), sshUser/sshPort of its OpenstackMachine (format-checked). Host key pinned on
             first connect in KEY_DIR/<machine>-known_hosts. k8s-status.sh (next
             to this script, K8S_STATUS overrides) is copied to the VM's home
             first. COMMAND after --
             runs instead of a login shell, e.g.
               --connect runai runai-gpu-g4lj9-5j7fc -- sudo bash k8s-status.sh
             Not tee'd to a run log (interactive); one line per connection in
             LOG_DIR/rancher-node-connect.log.
  --node-cmd [CLUSTER] [MACHINE...|all] -- COMMAND
  --node-cmd [CLUSTER] [MACHINE...|all] --bash SCRIPT [ARG...]
             Run on a controller. Run COMMAND (or a local SCRIPT as root:
             sent over ssh stdin to "sudo bash -s", nothing left on the
             node) on one, several or all machines
             of the cluster (all = every machine that joined it), one after
             another, same SSH key / IP / user as --connect (k8s-status.sh not
             copied). Output indented under "== <machine>"; ends with "3/4 ok"
             and the failed machines (exit 1 if any failed). Anything left out
             is asked for: cluster list, machine list (numbers or a = all),
             the command, then a confirmation.
               --node-cmd cmp-test2 all -- "sudo ip r replace 10.32.0.0/16 via 192.168.1.254; ip r get 10.32.2.49 | head -1"
               --node-cmd cmp-test2 all --bash fix-route.sh 10.32.0.0/16
  --repo [CLUSTER] [check|update|reset]
             Run on a controller. Registry mirrors of a downstream cluster
             (spec.rkeConfig.registries). No args: list RKE2/K3s clusters,
             pick one, pick an action.
               check  : the spec, and the mirrors each node's plan carries.
               update : pick the registries to mirror (Enter = 1 ALL):
                          1) ALL  2) docker.io  3) index.docker.io  4) quay.io
                          5) registry-1.docker.io  6) registry.k8s.io
                          7) registry.rancher.com  8) nvcr.io (NVIDIA GPU Operator)
                        then the mirror URL (Enter = http://<cubesys.control.vip>:5080;
                        several allowed). Other mirrors/configs kept.
               reset  : remove all mirrors and configs (registries = {}):
                        nodes pull straight from the internet again.
             The previous value is printed (and kept in the run log).
             Rancher rolls the change out node by node; re-run check.
  --download LIST [DIR]
             On a host with internet (e.g. cc141). Save every image of LIST to
             DIR (default ./offline-images) as oci-archive + images.tsv +
             SHA256SUMS. Resumes; lists failures at the end.
  --upload [DIR]
             On the offline controller. Push DIR to every controller's :5080
             (cubesys.control.addrs), under the path the containerd mirror
             asks for (registry host dropped).
  --verify LIST [OUT]
             Is each image of LIST in the registry behind the VIP? Prints
             MISSING image:tag lines and "10/12 ok"; OUT gets the missing list,
             ready for --download.

  LIST: one image per line (registry.k8s.io/x:tag, rancher/y:tag), '#'
        comments; e.g. k8s-status.sh --missing / --used, or an RKE2
        release rke2-images-*.txt.

Env:
  NS=fleet-default  KUBECTL="k3s kubectl"  INTERVAL=5  TIMEOUT=3600
  ENDPOINTS="http://a:5080 ..."   --repo update mirror URL(s), skips the URL prompt
  MIRROR_HOSTS="docker.io quay.io"  --repo update registries, skips the menu
  LOG_DIR=/var/log/kubernetes      run log of every option (rancher-operation-<option>-<time>.log)
  KEY_DIR=/tmp/rancher-keys-<uid>  --connect SSH keys and known_hosts (mode 700, must be yours)
  OPENRC=/etc/admin-openrc.sh      --connect: sourced when OS_AUTH_URL is not set
  REGISTRY_HOSTS="ip1 ip2"        --upload targets instead of settings.txt
  REGISTRY_URL=http://ip:5080     --verify registry instead of the VIP
  REGISTRY_PORT=5080
Exit: 0 ok; 1 error, not ready, or images missing; 2 cluster not found (--watch).
EOF
}

NS=${NS:-fleet-default}
LOG_DIR=${LOG_DIR:-/var/log/kubernetes}   # run logs
# Copy everything this run prints to $LOG_DIR/<NAME>-<what>-<timestamp>.log; warn and go on if not writable.
start_log() {
  { mkdir -p "$LOG_DIR" && touch "$LOG_DIR/.w" && rm -f "$LOG_DIR/.w"; } 2>/dev/null \
    || { echo "WARN: $LOG_DIR not writable; no log file" >&2; return 0; }
  LOG_FILE=$LOG_DIR/rancher-operation-$1-$(date +%Y%m%d-%H%M%S).log
  ( umask 077; : >> "$LOG_FILE" )                     # logs hold cluster details: owner-only
  exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)   # stderr stays stderr
  echo "log: $LOG_FILE"
}
k() { ${KUBECTL:-k3s kubectl} "$@"; }   # word splitting intended for "k3s kubectl"
die() { echo "ERROR: $*" >&2; exit 1; }
need() { local c; for c; do command -v "$c" >/dev/null || die "$c required"; done; }
setting() { awk -F= -v k="$1" '{key = $1; gsub(/ /, "", key)} key == k {v = $2; gsub(/ /, "", v); print v}' "${SETTINGS:-/etc/settings.txt}" 2>/dev/null; }
# Every controller's own IP: cubesys.control.addrs (HA), else cubesys.controller.ip (single node), else cubectl.
controllers() {
  local a; a=$(setting cubesys.control.addrs); [[ -n $a ]] || a=$(setting cubesys.controller.ip)
  if [[ -n $a ]]; then tr ',' '\n' <<< "$a" | grep .; return; fi
  cubectl node list -r control | awk -F, '$3 ~ /^control/ {print $2}'
}

# ============================================================ --watch
say() { printf '%s [%-5s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
declare -A SEEN=()
first() { [[ -z ${SEEN[$1]:-} ]] && SEEN[$1]=1; }   # true only the first time a key is seen
LAST=

# One poll. Returns 0 when Ready, 1 to keep waiting, 2 when the cluster is missing.
step() {
  local c=$1 cj ready msg lvl mj m phase fail sj cs pods p old new rdy joined rel st
  cj=$(k -n "$NS" get clusters.provisioning.cattle.io "$c" -o json 2>/dev/null) || { say ERROR "cluster $NS/$c not found"; return 2; }
  ready=$(jq -r '.status.conditions[]? | select(.type=="Ready") | .status' <<< "$cj")
  # Same message the UI shows: first non-empty of Updated / Provisioned / Ready.
  msg=$(jq -r '[.status.conditions[]? | select(.type=="Updated" or .type=="Provisioned" or .type=="Ready")
               | .message // empty | select(. != "")][0] // empty' <<< "$cj")

  mj=$(k -n "$NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$c" -o json 2>/dev/null || echo '{"items":[]}')
  while IFS=$'\t' read -r m phase fail; do
    [[ -n $m ]] || continue
    first "phase:$m:$phase" && say INFO "machine $m: $phase"
    [[ -z $fail ]] || { first "mfail:$m:$fail" && say ERROR "machine $m: $fail"; }
    # Plan failure: the node agent writes the failing step's output back to <machine>-machine-plan.
    sj=$(k -n "$NS" get secret "$m-machine-plan" -o json 2>/dev/null) || continue
    cs=$(jq -r '.data["failed-checksum"] // empty' <<< "$sj" | base64 -d 2>/dev/null)
    if [[ -n $cs ]] && first "plan:$m:$cs"; then
      say ERROR "machine $m: plan failed (failures $(jq -r '.data["failure-count"] // empty' <<< "$sj" | base64 -d 2>/dev/null)); output:"
      jq -r '.data["failed-output"] // empty' <<< "$sj" | base64 -d 2>/dev/null | { gunzip 2>/dev/null || cat; } | tail -15 | sed 's/^/        /'
    fi
  done < <(jq -r '.items[] | [.metadata.name, (.status.phase // "Pending"), (.status.failureMessage // "")] | @tsv' <<< "$mj")

  # VM creation/deletion jobs (OpenStack auth, quota, flavor, network errors land here).
  pods=$(k -n "$NS" get pods -o json 2>/dev/null | jq -r --arg c "$c-" '.items[]
          | select((.metadata.name | startswith($c)) and (.metadata.name | contains("machine-provision")) and .status.phase=="Failed")
          | .metadata.name')
  for p in $pods; do
    first "pod:$p" || continue
    say ERROR "provision job $p failed:"
    k -n "$NS" logs "$p" --tail=40 2>/dev/null | grep -i -E 'error|fail|denied|quota|not found|timeout' | tail -5 | sed 's/^/        /'
  done

  # A pool edited in the UI gets a new MachineSet; the old one keeps building machines from the old template.
  while IFS=$'\t' read -r p _ _ old new rdy joined; do
    [[ -n $p ]] && first "stale:$p" || continue
    if (( rdy + joined == 0 )); then say WARN "MachineSet $p still builds machines from old template $old (current $new); remove it: bash $0 --cleanup $c"
    else say INFO "MachineSet $p on old template $old is being rolled out to $new"; fi
  done < <(stale_sets "$c" 2>/dev/null)

  while IFS=$'\t' read -r _ p _ _ rel _ st; do
    [[ -n $p ]] && first "helmop:$p" || continue
    say WARN "helm operation $p ($rel) is over but its proxy sidecar keeps it Running 1/2, blocking appctl 'waiting for all pods to be ready'; release now: $st; remove: bash $0 --cleanup $c"
  done < <(stuck_ops "$c" 2>/dev/null)

  if [[ $ready == True ]]; then say DONE "cluster $c is Ready"; return 0; fi
  if [[ -n $msg && $msg != "$LAST" ]]; then
    lvl=INFO; [[ $msg == *rror* || $msg == *ailed* ]] && lvl=ERROR
    say "$lvl" "$msg"; LAST=$msg
  fi
  return 1
}

watch_main() {
  local c=${1:-} once=${2:-} rc deadline
  [[ $c == -* ]] && { once=$c; c=; }   # --watch --once: pick the cluster first
  need jq
  if [[ -z $c ]]; then pick_cluster all; c=$PICKED; fi
  if [[ $once == --once ]]; then step "$c"; return; fi
  deadline=$(( SECONDS + ${TIMEOUT:-3600} ))
  while (( SECONDS < deadline )); do
    step "$c"; rc=$?
    (( rc == 1 )) || return "$rc"
    sleep "${INTERVAL:-5}"
  done
  say ERROR "timeout after ${TIMEOUT:-3600}s; last status: ${LAST:-none}"; return 1
}

# ============================================================ --cleanup
# MachineSets whose template is no longer their MachineDeployment's. TSV:
# set, deployment, template kind.group, old template, current template, ready replicas, machines that joined (nodeRef).
# Refs: CAPI v1beta1 has apiVersion "group/v1", v1beta2 (Rancher 2.15+) has apiGroup.
stale_sets() {
  local c=$1 l="cluster.x-k8s.io/cluster-name=$1" mds mss ms
  mds=$(k -n "$NS" get machinedeployments.cluster.x-k8s.io -l "$l" -o json) || return 1
  mss=$(k -n "$NS" get machinesets.cluster.x-k8s.io -l "$l" -o json) || return 1
  ms=$(k -n "$NS" get machines.cluster.x-k8s.io -l "$l" -o json) || return 1
  jq -rn --argjson d "$mds" --argjson s "$mss" --argjson m "$ms" '
    ($d.items | map({key: .metadata.name, value: .spec.template.spec.infrastructureRef.name}) | from_entries) as $cur
    | $s.items[] | .metadata.labels["cluster.x-k8s.io/deployment-name"] as $dep | .metadata.name as $set
    | .spec.template.spec.infrastructureRef as $ref
    | select($cur[$dep] != null and $ref.name != $cur[$dep])
    | [$set, $dep, $ref.kind + "." + ($ref.apiGroup // ($ref.apiVersion // "" | split("/")[0])), $ref.name, $cur[$dep], (.status.readyReplicas // 0),
       ([$m.items[] | select(.metadata.labels["cluster.x-k8s.io/set-name"] == $set and .status.nodeRef != null)] | length)] | @tsv'
}

# "key: old -> new" for every template field that differs; credentials, certificates and user data masked.
template_diff() {
  local kind=$1 a b
  a=$(k -n "$NS" get "$kind" "$2" -o json) && b=$(k -n "$NS" get "$kind" "$3" -o json) || { echo "(cannot read templates)"; return 0; }
  jq -rn --argjson a "$a" --argjson b "$b" '($a.spec.template.spec // {}) as $o | ($b.spec.template.spec // {}) as $n
    | ([$o, $n] | map(keys) | add | unique)[] as $k | select($o[$k] != $n[$k])
    | if ($k | test("password|secret|token|cred|cert|privatekey|userdata"; "i")) then "\($k): *** -> ***"
      else "\($k): \($o[$k] | tojson) -> \($n[$k] | tojson)" end'
}

# Ask before deleting; $2 == --yes skips. No terminal and no --yes: say how to re-run, delete nothing.
confirm() {
  local ans
  [[ $2 == --yes ]] && return 0
  [[ -t 0 ]] || { echo "Not a terminal: re-run with --yes to $1"; return 1; }
  read -rp "${1^}? [y/N] " ans
  [[ $ans == [yY]* ]] || { echo "Nothing deleted."; return 1; }
}

# kubectl against the downstream cluster, through Rancher (fleet-default/<cluster>-kubeconfig).
down() {
  local c=$1 kc rc; shift
  kc=$(mktemp) || return 1   # holds a Rancher token: mktemp is 600, removed below
  k -n "$NS" get secret "$c-kubeconfig" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > "$kc" 2>/dev/null
  [[ -s $kc ]] || { rm -f "$kc"; return 1; }
  k --kubeconfig "$kc" --request-timeout=10s "$@"; rc=$?
  rm -f "$kc"; return "$rc"
}

# Rancher helm-operation pods whose helm container ended >120s ago while the proxy sidecar runs on:
# Running 1/2 forever, which blocks appctl's "waiting for all pods to be ready" (60 min, then create fails).
# Seen when two operations race on one release ("another operation ... is in progress").
# TSV: namespace, pod, helm exit code, finished at, release, release namespace, release status now.
stuck_ops() {
  local c=$1 pods ops ns p ex fin rel rns st
  pods=$(down "$c" get pods -A -o json 2>/dev/null) || return 1
  ops=$(down "$c" get operations.catalog.cattle.io -A -o json 2>/dev/null) || ops='{"items":[]}'
  while IFS=$'\t' read -r ns p ex fin; do
    [[ -n $p ]] || continue
    IFS=$'\t' read -r rel rns < <(jq -r --arg p "$p" '[.items[] | select(.status.podName == $p)][0].status // {}
                                   | [.releaseName // "", .namespace // ""] | @tsv' <<< "$ops")
    st=
    [[ -n $rel ]] && st=$(down "$c" -n "$rns" get secrets -l "owner=helm,name=$rel" \
      -o jsonpath='{range .items[*]}{.metadata.labels.version} {.metadata.labels.status}{"\n"}{end}' 2>/dev/null \
      | sort -n | tail -1 | awk '{print $2 " (revision " $1 ")"}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ns" "$p" "$ex" "$fin" "${rel:--}" "${rns:--}" "${st:-not found}"
  done < <(jq -r '.items[] | select((.metadata.name | startswith("helm-operation-")) and .status.phase == "Running")
      | (.status.containerStatuses // []) as $cs
      | ([$cs[] | select(.name == "helm") | .state.terminated][0]) as $t
      | select($t != null and $t.finishedAt != null and (now - ($t.finishedAt | fromdateiso8601)) > 120
               and any($cs[]; .name != "helm" and .state.running != null))
      | [.metadata.namespace, .metadata.name, ($t.exitCode | tostring), $t.finishedAt] | @tsv' <<< "$pods")
}

cleanup_ops() {
  local c=$1 yes=$2 rows=() del=() l ns p ex fin rel rns st
  while IFS= read -r l; do rows+=("$l"); done < <(stuck_ops "$c")
  (( ${#rows[@]} )) || { echo "No stuck helm-operation pods in $c."; return 0; }
  for l in "${rows[@]}"; do
    IFS=$'\t' read -r ns p ex fin rel rns st <<< "$l"
    echo "== helm operation $ns/$p: helm exited $ex at $fin, proxy sidecar still running (Running 1/2)"
    echo "     release $rel ($rns) is now: $st"
    echo "     last helm output:"
    down "$c" -n "$ns" logs "$p" -c helm --tail=3 2>/dev/null | sed 's/^/        /'
    echo "   DELETE the operation is over; only the sidecar keeps the pod alive (blocks appctl 'waiting for all pods to be ready')."
    [[ $st == deployed* ]] || echo "   WARN   release $rel is not deployed: deleting the pod does not fix it; redo it in Rancher Apps after."
    del+=("$ns/$p")
  done
  confirm "delete ${#del[@]} stuck helm-operation pod(s): ${del[*]}" "$yes" || return 0
  for l in "${del[@]}"; do
    down "$c" -n "${l%%/*}" delete pod "${l#*/}" --wait=false || die "delete $l failed"
  done
  echo "Deleted. appctl's pod wait checks every 10s and goes on by itself."
}

cleanup_main() {
  local c=${1:-} yes=${2:-}
  [[ $c == --yes ]] && { yes=$c; c=; }
  need jq
  if [[ -z $c ]]; then pick_cluster; c=$PICKED; fi
  cluster_json "$c" >/dev/null
  cleanup_sets "$c" "$yes"
  cleanup_ops "$c" "$yes"
}

cleanup_sets() {
  local c=$1 yes=$2 rows=() del=() l set dep kind old new rdy joined
  while IFS= read -r l; do rows+=("$l"); done < <(stale_sets "$c")
  (( ${#rows[@]} )) || { echo "No stale MachineSets in $c: every pool builds from its current template."; return 0; }
  for l in "${rows[@]}"; do
    IFS=$'\t' read -r set dep kind old new rdy joined <<< "$l"
    echo "== MachineSet $set (pool $dep): template $old, current $new"
    template_diff "$kind" "$old" "$new" | sed 's/^/     /'
    if (( rdy + joined > 0 )); then
      echo "   KEEP   $rdy ready, $joined joined the cluster: normal rolling update, Rancher scales it down itself."
    else
      echo "   DELETE none of its machines ever joined the cluster (nothing to lose; it only re-creates failing machines)."
      del+=("$set")
    fi
  done
  (( ${#del[@]} )) || return 0
  confirm "delete ${#del[@]} stale MachineSet(s): ${del[*]}" "$yes" || return 0
  for set in "${del[@]}"; do
    k -n "$NS" delete machinesets.cluster.x-k8s.io "$set" --wait=false || die "delete $set failed"
  done
  echo "Deleted. The MachineDeployment builds the remaining replicas from the current template; follow: bash $0 --watch $c"
}

# ============================================================ --connect
KEY_DIR=${KEY_DIR:-/tmp/rancher-keys-$(id -u)}   # private per user: /tmp itself is shared

# Print the machine table of a cluster, read a number, set PICKED.
# $2 == multi: read several numbers or a (= every machine that joined), set PICKS.
pick_machine() {
  local rows=() l i n ph nd ans
  while IFS= read -r l; do rows+=("$l"); done < <(k -n "$NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$1" -o json \
    | jq -r '.items[] | [.metadata.name, (.status.phase // "-"), (.status.nodeRef.name // "no node")] | @tsv')
  (( ${#rows[@]} )) || die "no machines in cluster $1"
  printf '%3s  %-45s %-14s %s\n' '#' MACHINE PHASE NODE
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r n ph nd <<< "${rows[$i]}"
    printf '%3d  %-45s %-14s %s\n' $((i + 1)) "$n" "$ph" "$nd"
  done
  if [[ ${2:-} == multi ]]; then
    printf '%3s  %s\n' a 'ALL machines that joined the cluster'
    read -rp "Machine number(s), space separated, or a: " ans
    PICKS=()
    if [[ $ans == a || $ans == all ]]; then
      for l in "${rows[@]}"; do [[ ${l##*$'\t'} == "no node" ]] || PICKS+=("${l%%$'\t'*}"); done
    else
      for i in $ans; do
        [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#rows[@]} )) || die "invalid choice: $i"
        PICKS+=("${rows[$((i - 1))]%%$'\t'*}")
      done
    fi
    (( ${#PICKS[@]} )) || die "no machine chosen"
    return
  fi
  read -rp "Machine number: " i
  [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#rows[@]} )) || die "invalid choice: $i"
  PICKED=${rows[$((i - 1))]%%$'\t'*}
}

# config.json or id_rsa out of the docker-machine directory Rancher keeps in <machine>-machine-state.
machine_file() {
  k -n "$NS" get secret "$1-machine-state" -o jsonpath='{.data.extractedConfig}' 2>/dev/null | base64 -d 2>/dev/null \
    | tar xzO --wildcards "*/machines/$1/$2" 2>/dev/null
}

# Floating IP of the machine's OpenStack server. $1 = server ID (Driver.MachineId), $2 = machine name,
# $3 = project (Driver.TenantId). By ID when known; a name search must match exactly one server.
floating_ip() {
  local id=${1:-} p ids n
  if [[ -z ${OS_AUTH_URL:-} && -r ${OPENRC:-/etc/admin-openrc.sh} ]]; then source "${OPENRC:-/etc/admin-openrc.sh}"; fi
  command -v openstack >/dev/null || return 0
  if [[ -z $id ]]; then
    ids=$(openstack server list --all-projects ${3:+--project "$3"} --name "^$2\$" -f value -c ID 2>/dev/null)
    n=$(grep -c . <<< "$ids")
    if (( n != 1 )); then echo "WARN: $n OpenStack servers named $2${3:+ in project $3}; not guessing the floating IP" >&2; return 0; fi
    id=$ids
  fi
  for p in $(openstack port list --server "$id" -f value -c ID 2>/dev/null); do
    openstack floating ip list --port "$p" -f value -c "Floating IP Address" 2>/dev/null
  done | head -1
}

connect_main() {
  local pos=() c m key tmp cfg ref user port ip st dest
  while (( $# )) && [[ $1 != -- ]]; do pos+=("$1"); shift; done   # CLUSTER MACHINE
  [[ ${1:-} == -- ]] && shift                                      # the rest is the remote command
  c=${pos[0]:-}; m=${pos[1]:-}
  need jq tar ssh
  if [[ -z $c ]]; then pick_cluster; c=$PICKED; fi
  cluster_json "$c" >/dev/null
  if [[ -z $m ]]; then pick_machine "$c"; m=$PICKED; fi

  # Refuse a KEY_DIR another user could have planted (symlink, foreign owner); write the key via mktemp + mv.
  mkdir -p -m 700 "$KEY_DIR" 2>/dev/null
  [[ -d $KEY_DIR && ! -L $KEY_DIR && -O $KEY_DIR ]] && chmod 700 "$KEY_DIR" || die "KEY_DIR $KEY_DIR is not a private directory of $(id -un)"
  key=$KEY_DIR/$m-id_rsa
  tmp=$(mktemp "$KEY_DIR/.key.XXXXXX") || die "cannot create a file in $KEY_DIR"
  machine_file "$m" id_rsa > "$tmp"
  [[ -s $tmp ]] || { rm -f "$tmp"; die "no SSH key in secret $NS/$m-machine-state (not a node-driver machine, or not created yet)"; }
  mv -f "$tmp" "$key" || die "cannot write $key"

  cfg=$(machine_file "$m" config.json)
  ref=$(k -n "$NS" get machines.cluster.x-k8s.io "$m" -o json 2>/dev/null \
    | jq -r '.spec.infrastructureRef | "\(.kind).\(.apiGroup // (.apiVersion // "" | split("/")[0])) \(.name)"')   # v1beta2: apiGroup
  user=$(k -n "$NS" get $ref -o jsonpath='{.spec.sshUser}' 2>/dev/null)
  port=$(k -n "$NS" get $ref -o jsonpath='{.spec.sshPort}' 2>/dev/null)
  [[ -n $user ]] || user=$(jq -r '.Driver.SSHUser // empty' <<< "$cfg" 2>/dev/null)
  [[ -n $port ]] || port=$(jq -r '.Driver.SSHPort // empty' <<< "$cfg" 2>/dev/null)
  user=${user:-root}; port=${port:-22}

  ip=$(floating_ip "$(jq -r '.Driver.MachineId // empty' <<< "$cfg" 2>/dev/null)" "$m" \
    "$(jq -r '.Driver.TenantId // empty' <<< "$cfg" 2>/dev/null)")
  if [[ -z $ip ]]; then
    ip=$(jq -r '.Driver.IPAddress // empty' <<< "$cfg" 2>/dev/null)
    [[ -n $ip ]] && echo "No floating IP found for $m; using the IP Rancher uses: $ip" >&2
  fi
  [[ -n $ip ]] || die "no IP for $m (no floating IP, no driver IPAddress)"
  # These come from cluster objects: never let them turn into ssh options.
  [[ $user =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "refusing sshUser '$user' for $m"
  [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "refusing sshPort '$port' for $m"
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $ip =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]*$ ]] || die "refusing IP '$ip' for $m"
  dest=$ip; [[ $ip == *:* ]] && dest="[$ip]"         # IPv6 needs brackets in scp's host:path

  echo "$m: $user@$ip:$port  key $key"
  # Ship the node check so it is ready on the VM (sudo bash k8s-status.sh); a failed copy does not block the login.
  st=${K8S_STATUS:-$(dirname "${BASH_SOURCE[0]}")/k8s-status.sh}
  if [[ -n ${NODE_CMD:-} ]]; then :                  # --node-cmd: one command per node, no copy
  elif [[ ! -r $st ]]; then echo "WARN: $st not found; not copied to the VM" >&2
  elif scp -q -i "$key" -P "$port" -o User="$user" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KEY_DIR/$m-known_hosts" \
      -- "$st" "$dest:k8s-status.sh"; then echo "copied k8s-status.sh to ~$user/ (run: sudo bash k8s-status.sh)"
  else echo "WARN: scp of $st to $user@$ip failed; connecting anyway" >&2; fi
  { mkdir -p "$LOG_DIR" && echo "$(date '+%F %T') $(id -un) $c $m $user@$ip:$port $*" >> "$LOG_DIR/rancher-node-connect.log"; } 2>/dev/null
  # Host key: trusted on first use, pinned per machine. A rebuilt VM is a new machine name (new file), so only a key
  # change on the same VM fails, as it should.
  exec ssh -i "$key" -p "$port" -l "$user" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KEY_DIR/$m-known_hosts" -- "$ip" "$@"
}

# ============================================================ --node-cmd
node_cmd_main() {
  local pos=() ms=() failed=() c m rc ok=0 script=/dev/null line ans asked=
  local usage="Usage: bash $0 --node-cmd [CLUSTER] [MACHINE...|all] [-- COMMAND | --bash SCRIPT [ARG...]]"
  while (( $# )) && [[ $1 != -- && $1 != --bash ]]; do pos+=("$1"); shift; done   # CLUSTER [MACHINE...|all]
  need jq
  # Anything left out is asked for: cluster, machines, command. Not a terminal: all must be given.
  [[ -t 0 ]] || { [[ -n ${pos[0]:-} && -n ${pos[1]:-} ]] && (( $# )) || die "$usage"; }
  c=${pos[0]:-}
  if [[ -z $c ]]; then pick_cluster; c=$PICKED; fi
  cluster_json "$c" >/dev/null
  ms=("${pos[@]:1}")
  if [[ ${ms[*]} == all ]]; then   # every machine that joined the cluster
    mapfile -t ms < <(k -n "$NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$c" -o json \
      | jq -r '.items[] | select(.status.nodeRef != null) | .metadata.name')
    (( ${#ms[@]} )) || die "no machines in $c have joined the cluster"
  elif (( ! ${#ms[@]} )); then pick_machine "$c" multi; ms=("${PICKS[@]}"); fi
  if (( ! $# )); then
    echo "Runs as the machine's ssh user: prefix sudo for root. Or: --bash SCRIPT [ARG...] (runs as root)."
    read -rp "Command: " line
    [[ -n ${line// } ]] || die "no command given"
    if [[ $line == --bash\ * ]]; then read -ra pos <<< "$line"; set -- "${pos[@]}"; else set -- -- "$line"; fi
    asked=1
  fi
  if [[ ${1:-} == --bash ]]; then
    script=${2:-}; [[ -f $script && -r $script ]] || die "--bash needs a readable local script: '${script}'"
    shift 2
    # The script goes over ssh stdin; its arguments are quoted for the remote shell.
    set -- "sudo bash -s --$( (( $# )) && printf ' %q' "$@")"
  else
    [[ ${1:-} == -- ]] && shift
  fi
  (( $# )) || die "$usage"
  if [[ -n $asked ]]; then   # typed at the prompt: show what will run where, then ask
    echo "Cluster $c, ${#ms[@]} machine(s): ${ms[*]}"
    echo "Run: $*"
    [[ $script == /dev/null ]] || echo "Script: $script"
    read -rp "Proceed? [y/N] " ans
    [[ $ans == [yY]* ]] || { echo "Nothing run."; return 0; }
  fi
  for m in "${ms[@]}"; do
    echo "== $m"
    # subshell: connect_main's exec ssh (or die) ends only this node's run
    ( NODE_CMD=1 connect_main "$c" "$m" -- "$@" ) < "$script" 2>&1 | sed 's/^/   /'
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then ok=$((ok + 1)); else failed+=("$m (rc $rc)"); fi
  done
  echo "$ok/${#ms[@]} ok"
  (( ${#failed[@]} == 0 )) || { printf 'FAILED: %s\n' "${failed[@]}"; return 1; }
}

# ============================================================ --repo
ALL_HOSTS="docker.io index.docker.io quay.io registry-1.docker.io registry.k8s.io registry.rancher.com nvcr.io"   # nvcr.io: NVIDIA GPU Operator

# "2 4,6" -> the matching registries of the menu (1 = ALL). Empty = ALL.
hosts_from_choice() {
  local list=($ALL_HOSTS) i out=()
  for i in ${1//,/ }; do
    [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#list[@]} + 1 )) || die "invalid choice: $i"
    (( i == 1 )) && { echo "$ALL_HOSTS"; return; }
    out+=("${list[$((i - 2))]}")
  done
  (( ${#out[@]} )) || { echo "$ALL_HOSTS"; return; }
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++' | paste -sd' ' -
}

# MIRROR_HOSTS env wins; otherwise ask on a terminal (Enter = ALL), ALL when not interactive.
pick_hosts() {
  local list=($ALL_HOSTS) i ans
  if [[ -n ${MIRROR_HOSTS:-} ]]; then echo "$MIRROR_HOSTS"; return; fi
  [[ -t 0 ]] || { echo "$ALL_HOSTS"; return; }
  { echo "Registries to mirror:"; echo "  1) ALL"
    for i in "${!list[@]}"; do echo "  $((i + 2))) ${list[$i]}"; done; } >&2
  read -rp "Select, several allowed (e.g. 2 4 6) [1]: " ans
  hosts_from_choice "$ans"
}

# Default mirror: the CubeCOS control VIP (HA), else the controller IP (single node).
default_endpoint() {
  local ip
  ip=$(setting cubesys.control.vip); [[ -n $ip ]] || ip=$(setting cubesys.controller.ip)
  [[ -z $ip ]] || echo "http://$ip:5080"
}

# host -> http://host:5080; keeps an explicit scheme or port. Several URLs separated by spaces.
normalize_urls() {
  local u out=()
  for u in $1; do
    [[ $u == *://* ]] || u=http://$u
    [[ $u =~ ://[^/]+:[0-9]+ ]] || u=${u%/}:5080
    out+=("${u%/}")
  done
  echo "${out[*]:-}"
}

# ENDPOINTS env wins; otherwise ask on a terminal (Enter = default), use the default when not interactive.
endpoints() {
  local def ans
  if [[ -n ${ENDPOINTS:-} ]]; then normalize_urls "$ENDPOINTS"; return; fi
  def=$(default_endpoint)
  if [[ -t 0 ]]; then
    read -rp "Mirror URL(s), space-separated [${def:-none}]: " ans
    ans=${ans:-$def}
  else ans=$def; fi
  normalize_urls "$ans"
}

# name, version, mirrors, Ready. "all" also lists imported/hosted clusters (no rkeConfig).
list_clusters() {
  k -n "$NS" get clusters.provisioning.cattle.io -o json | jq -r --argjson all "$([[ ${1:-} == all ]] && echo true || echo false)" '
    .items[] | select($all or .spec.rkeConfig) |
    [.metadata.name, (.spec.kubernetesVersion // "-"),
     (if .spec.rkeConfig then ((.spec.rkeConfig.registries.mirrors // {}) | keys | join(",") | if . == "" then "NONE" else . end) else "-" end),
     ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "-")] | @tsv'
}

# Print the cluster table, read a number, set PICKED. $1 is passed to list_clusters.
pick_cluster() {
  local rows=() l i n v m r
  while IFS= read -r l; do rows+=("$l"); done < <(list_clusters "${1:-}")
  (( ${#rows[@]} )) || die "no clusters in $NS"
  printf '%3s  %-30s %-22s %-8s %s\n' '#' CLUSTER VERSION READY MIRRORS
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r n v m r <<< "${rows[$i]}"
    printf '%3d  %-30s %-22s %-8s %s\n' $((i + 1)) "$n" "$v" "$r" "$m"
  done
  read -rp "Cluster number: " i
  [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#rows[@]} )) || die "invalid choice: $i"
  PICKED=${rows[$((i - 1))]%%$'\t'*}
}

cluster_json() { k -n "$NS" get clusters.provisioning.cattle.io "$1" -o json 2>/dev/null || die "cluster $NS/$1 not found"; }

check() {
  local c=$1 m s cj want pending=0
  cj=$(cluster_json "$c")
  echo "== spec.rkeConfig.registries of $c"
  jq '.spec.rkeConfig.registries // {}' <<< "$cj"
  want=$(jq -r '.spec.rkeConfig.registries.mirrors // {} | keys | join(",")' <<< "$cj")
  echo "== mirrors in each node's plan (what lands in /etc/rancher/*/registries.yaml)"
  for m in $(k -n "$NS" get machines.cluster.x-k8s.io -l "cluster.x-k8s.io/cluster-name=$c" -o jsonpath='{.items[*].metadata.name}'); do
    s=$(k -n "$NS" get secret "$m-machine-plan" -o jsonpath='{.data.plan}' 2>/dev/null | base64 -d 2>/dev/null)
    if [[ -z $s ]]; then printf '  %-45s %s\n' "$m" "(no plan yet)"; continue; fi
    s=$(jq -r '[.files[]? | select(.path | test("registries")) | .content | @base64d | fromjson? | .mirrors // {} | keys[]]
               | unique | join(",")' <<< "$s" 2>/dev/null)
    if [[ $s == "$want" ]]; then printf '  %-45s %s\n' "$m" "${s:-NO MIRROR}"
    else printf '  %-45s %s   <- old plan, not rolled out yet\n' "$m" "${s:-NO MIRROR}"; pending=$((pending + 1)); fi
  done
  (( pending == 0 )) || echo "$pending node(s) pending: Rancher rolls plans node by node (upgradeStrategy concurrency, default 1); re-check in a few minutes."
}

repo_update() {
  local c=$1 hosts eps ep cur want
  hosts=$(pick_hosts) || exit 1
  eps=$(endpoints); [[ -n $eps ]] || die "no mirror URL (no cubesys.control.vip in /etc/settings.txt); set ENDPOINTS='http://<ip>:5080'"
  for ep in $eps; do curl -s -m 5 -o /dev/null "$ep/v2/" || die "registry $ep not reachable from here"; done
  cur=$(cluster_json "$c" | jq -c '.spec.rkeConfig.registries // {}')
  want=$(jq -cn --arg e "$eps" --arg h "$hosts" '($e | split(" ")) as $e
    | [$h | split(" ")[] | {key: ., value: {endpoint: $e}}] | from_entries')
  if jq -e --argjson w "$want" '(.mirrors // {}) as $m | $w | to_entries | all($m[.key].endpoint == .value.endpoint)' <<< "$cur" >/dev/null; then
    echo "Already up to date: $c mirrors $hosts point to $eps"; return 0
  fi
  echo "previous registries of $c: $cur"
  k -n "$NS" patch clusters.provisioning.cattle.io "$c" --type merge \
    -p "$(jq -cn --argjson w "$want" '{spec: {rkeConfig: {registries: {mirrors: $w}}}}')" || die "update failed"
  echo "Updated $c: $hosts -> $eps. Rancher pushes new plans node by node; re-check: bash $0 --repo $c check"
}

# Drop every mirror and config: the cluster pulls from the internet again.
repo_reset() {
  local c=$1 cur
  cur=$(cluster_json "$c" | jq -c '.spec.rkeConfig.registries // {}')
  if [[ $cur == '{}' ]]; then echo "Nothing to reset: $c has no registries settings"; return 0; fi
  echo "previous registries of $c: $cur"
  k -n "$NS" patch clusters.provisioning.cattle.io "$c" --type json \
    -p '[{"op":"add","path":"/spec/rkeConfig/registries","value":{}}]' || die "reset failed"
  echo "Reset $c: registries = {}. Offline sites cannot pull new images until update. Re-check: bash $0 --repo $c check"
}

repo_main() {
  local c=${1:-} a=${2:-}
  need jq
  if [[ -z $c ]]; then pick_cluster; c=$PICKED; fi
  check "$c"
  if [[ -z $a ]]; then
    echo; echo "1) update   2) reset   q) quit"; read -rp "Action: " a
    case $a in 1) a=update ;; 2) a=reset ;; *) return 0 ;; esac
  fi
  case $a in
    check) ;;
    update) repo_update "$c" ;;
    reset) repo_reset "$c" ;;
    *) die "unknown action: $a (check|update|reset)" ;;
  esac
}

# ============================================================ --download / --upload
# registry.k8s.io/sig-storage/x:1 -> registry.k8s.io/sig-storage/x:1 (source) and sig-storage/x:1 (path in :5080)
source_ref() { case ${1%%/*} in *.*|*:*|localhost) [[ $1 == */* ]] && { echo "$1"; return; };; esac; [[ $1 == */* ]] && echo "docker.io/$1" || echo "docker.io/library/$1"; }
dest_path() { local s; s=$(source_ref "$1"); s=${s#*/}; echo "$s"; }

# Valid name:tag refs from a list file; comments, blanks and digests skipped.
list_refs() {
  local ref
  while IFS= read -r ref; do
    ref=${ref%%#*}; ref=${ref//[[:space:]]/}; [[ -n $ref ]] || continue
    [[ $ref =~ ^[A-Za-z0-9._/:-]+:[A-Za-z0-9._-]+$ ]] || { echo "skip (need name:tag): $ref" >&2; continue; }
    echo "$ref"
  done < "$1"
}

download() {
  local list=$1 dir=$2 ref src dest file n=0 failed=()
  [[ -s $list ]] || die "List $list is empty or missing."
  need skopeo sha256sum
  mkdir -p "$dir/images" || die "cannot create $dir"; : > "$dir/images.tsv.part"
  while IFS= read -r ref; do
    src=$(source_ref "$ref"); dest=$(dest_path "$ref"); file="images/${dest//[\/:]/_}.tar"
    if [[ -s $dir/$file ]] || { skopeo copy --quiet --retry-times 3 --override-os linux --override-arch amd64 \
        "docker://$src" "oci-archive:$dir/$file.part:$dest" && mv "$dir/$file.part" "$dir/$file"; }; then
      printf '%s\t%s\n' "$dest" "$file" >> "$dir/images.tsv.part"; n=$((n + 1)); echo "[$n] $src"
    else
      rm -f "$dir/$file.part"; failed+=("$src"); echo "FAILED $src" >&2
    fi
  done < <(list_refs "$list")
  sort -u "$dir/images.tsv.part" > "$dir/images.tsv" && rm -f "$dir/images.tsv.part" || die "cannot write $dir/images.tsv"
  (cd "$dir" && sha256sum images.tsv $(cut -f2 images.tsv) > SHA256SUMS) || die "cannot write $dir/SHA256SUMS"
  echo "Package: $dir ($n images, $(du -sh "$dir" | cut -f1)). Carry the folder; offline: bash rancher-operation.sh --upload $(basename "$dir")"
  (( ${#failed[@]} == 0 )) || die "${#failed[@]} image(s) failed: ${failed[*]}"
}

# Is every image of the list in the registry behind the VIP? Missing refs printed (and written to OUT) for --download.
verify() {
  local list=$1 out=${2:-} url ref dest code n=0 ok=0 missing=()
  [[ -s $list ]] || die "List $list is empty or missing."
  url=${REGISTRY_URL:-$(default_endpoint)}; url=$(normalize_urls "$url")
  [[ -n $url ]] || die "no registry URL (no cubesys.control.vip in /etc/settings.txt); set REGISTRY_URL=http://<ip>:5080"
  curl -s -m 5 -o /dev/null "$url/v2/" || die "registry $url not reachable"
  while IFS= read -r ref; do
    dest=$(dest_path "$ref"); n=$((n + 1))
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -I \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
      "$url/v2/${dest%:*}/manifests/${dest##*:}")
    if [[ $code == 200 ]]; then ok=$((ok + 1)); else missing+=("$(source_ref "$ref")"); echo "MISSING $(source_ref "$ref")  (HTTP $code)"; fi
  done < <(list_refs "$list")
  echo "$ok/$n ok on $url"
  if [[ -n $out ]]; then printf '%s\n' "${missing[@]:+${missing[@]}}" | grep . > "$out"; echo "missing list -> $out (feed to --download)"; fi
  (( ${#missing[@]} == 0 ))
}

upload() {
  local dir=$1 ip dest file hosts n
  [[ -s $dir/images.tsv ]] || die "No $dir/images.tsv (run --download first; if 'getcwd' errors appear, cd again by absolute path)."
  need skopeo
  # Each controller runs its own registry:2 on local disk: push to every one, never only the VIP.
  if [[ -n ${REGISTRY_HOSTS:-} ]]; then hosts=$REGISTRY_HOSTS
  else hosts=$(controllers) || die 'controller discovery failed (settings.txt / cubectl); set REGISTRY_HOSTS.'; fi
  [[ -n $hosts ]] || die 'No controllers found.'
  for ip in $hosts; do
    n=0
    while IFS=$'\t' read -r dest file; do
      skopeo copy --quiet --retry-times 3 --dest-tls-verify=false "oci-archive:$dir/$file" "docker://$ip:${REGISTRY_PORT:-5080}/$dest" \
        || die "push $dest to $ip failed"
      n=$((n + 1))
    done < "$dir/images.tsv"
    echo "$ip:${REGISTRY_PORT:-5080}: $n image(s) pushed."
  done
  echo 'Done. On the node: sudo bash k8s-status.sh --retry (or wait for back-off), then --watch.'
}

# ============================================================
main() {
  local op=${1:-}; shift || true
  local what=${1:-}; what=${what##*/}; [[ -z $what || $what == -* ]] && what= || what=-$what   # cluster or list name
  case $op in --watch|--cleanup|--node-cmd|--repo|--download|--upload|--verify) start_log "${op#--}$what" ;; esac
  case $op in
    --watch) watch_main "$@" ;;
    --cleanup) cleanup_main "$@" ;;
    --connect) connect_main "$@" ;;   # no start_log: an interactive ssh must not go through tee
    --node-cmd) node_cmd_main "$@" ;;
    --repo) repo_main "$@" ;;
    --download) [[ -n ${1:-} ]] || die "Usage: bash $0 --download LIST [DIR]"; download "$1" "${2:-offline-images}" ;;
    --upload) upload "${1:-offline-images}" ;;
    --verify) [[ -n ${1:-} ]] || die "Usage: bash $0 --verify LIST [OUT]"; verify "$1" "${2:-}" ;;
    -h|--help) usage ;;
    *) usage; return 1 ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
