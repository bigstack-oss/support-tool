#!/usr/bin/env bash
# Run INSIDE a Rancher-provisioned RKE2 node (downstream VM) to see where provisioning is and why it fails.
#   sudo bash k8s-status.sh            one pass
#   sudo bash k8s-status.sh --watch    repeat every INTERVAL (5s), print only new lines, Ctrl-C to stop
#   sudo bash k8s-status.sh --missing [FILE]   write images this node failed to pull (default ./missing-images.txt);
#        fix with rancher-operation.sh: --download on an internet host, carry, --upload on the offline site.
#   sudo bash k8s-status.sh --retry    after uploading images: restart pods stuck in ErrImagePull/ImagePullBackOff
#        (server node); on a worker (no kubeconfig): crictl pull the failed images, the kubelet then starts the pods.
#        (the kubelet otherwise retries on its own, with back-off up to 5 min). The only option that changes anything.
#   sudo bash k8s-status.sh --net      only the connectivity check: route, DNS, rke2 proxy, and per registry
#        (docker.io, registry.k8s.io, quay.io, registry.rancher.com, nvcr.io) DNS + HTTPS. NET_URLS overrides the list.
#   sudo bash k8s-status.sh --used [FILE]      write every image this node holds and every image the cluster's pods use
#        (default ./used-images.txt), fully qualified: feed it to rancher-operation.sh --download to pre-seed the next site.
#   sudo env KUBECTL_INSECURE_SKIP_TLS_VERIFY=yes bash k8s-status.sh
#        temporarily skip Kubernetes API certificate verification (insecure; diagnostics only).
# Checks in order: host -> internet -> cloud-init -> rancher-system-agent -> registries -> rke2 service -> image pulls -> node/pods -> cluster agent.
# Read-only. Exit 0 when no [ERROR] in the last pass.
set -uo pipefail

R=${ROOT:-}                       # test hook: prefix for file paths
RKE=$R/var/lib/rancher/rke2
PATH=$PATH:$RKE/bin
KUBECTL_INSECURE_SKIP_TLS_VERIFY=${KUBECTL_INSECURE_SKIP_TLS_VERIFY:-no}
case $KUBECTL_INSECURE_SKIP_TLS_VERIFY in
  no) ;;
  yes) ;;
  *) echo "KUBECTL_INSECURE_SKIP_TLS_VERIFY must be 'yes' or 'no'." >&2; exit 2 ;;
esac
WATCH=no; [[ ${1:-} == --watch ]] && WATCH=yes
declare -A SEEN=()
ERRORS=0
say() {
  local lvl=$1 msg=$2
  [[ $lvl == ERROR ]] && ERRORS=$((ERRORS + 1))
  if [[ $WATCH == yes ]]; then [[ -n ${SEEN[$lvl$msg]:-} ]] && return; SEEN[$lvl$msg]=1; fi
  printf '%s [%-5s] %s\n' "$(date +%H:%M:%S)" "$lvl" "$msg"
}
# Strip journald/klog/logrus timestamps so the same error repeating is printed once.
clean() { sed -E 's/^[IWEF][0-9]{4} [0-9:.]+ +[0-9]+ //; s/time="[^"]*" //; s/^\{"level":"[a-z]+","ts":[^,]*,//'; }
each() { local l; while IFS= read -r l; do say "$1" "$2$l"; done; }   # use with < <(...): a pipe would lose SEEN/ERRORS
present() { CRI_CONFIG_FILE=$RKE/agent/etc/crictl.yaml crictl inspecti "$1" >/dev/null 2>&1; }   # image now in local containerd
kubectl_cmd() {
  local timeout=$1; shift
  if [[ $KUBECTL_INSECURE_SKIP_TLS_VERIFY == yes ]]; then
    "$RKE/bin/kubectl" --kubeconfig "$R/etc/rancher/rke2/rke2.yaml" --request-timeout="$timeout" \
      --insecure-skip-tls-verify=true "$@"
  else
    "$RKE/bin/kubectl" --kubeconfig "$R/etc/rancher/rke2/rke2.yaml" --request-timeout="$timeout" "$@"
  fi
}
kc() { kubectl_cmd 10s "$@"; }
tail_err() { grep -i -E "$1" | grep -v -E "${2:-^$}" | clean | tail -"${3:-5}"; }

check_cloudinit() {
  command -v cloud-init >/dev/null || return
  local s; s=$(cloud-init status 2>/dev/null | awk '/status:/{print $2}')
  case $s in
    done) say OK "cloud-init done" ;;
    running) say INFO "cloud-init still running (agent install comes from userdata)" ;;
    error) say ERROR "cloud-init error; see /var/log/cloud-init-output.log:"
           tail -5 "$R/var/log/cloud-init-output.log" 2>/dev/null | sed 's/^/        /' ;;
  esac
}

check_agent() {
  local info=$R/var/lib/rancher/agent/rancher2_connection_info.json url
  if ! systemctl is-active --quiet rancher-system-agent; then
    say ERROR "rancher-system-agent not running (not installed yet, or registration failed: check cloud-init)"; return 1
  fi
  if [[ ! -s $info ]]; then say WARN "rancher-system-agent running but no connection info yet"; return 1; fi
  url=$(grep -o -E 'server: *https?://[^"\\ ]+' "$info" | head -1 | sed -E 's/server: *//')
  if [[ -n $url ]]; then
    if [[ $(curl -sk -m 5 "${url%/}/ping" 2>/dev/null) == pong ]]; then say OK "agent registered; Rancher $url reachable"
    else say ERROR "agent registered but Rancher $url/ping unreachable from this node (DNS, route, firewall)"; fi
  fi
  each ERROR 'agent: ' < <(journalctl -u rancher-system-agent --since "-${SINCE:-15min}" -o cat --no-pager 2>/dev/null \
    | tail_err 'level=(error|fatal)' 'watch ended|INTERNAL_ERROR|older than the last secret|secret received was too old|for probe')
  return 0
}

check_registries() {
  local f ep n=0
  for f in "$R/etc/rancher/agent/registries.yaml" "$R/etc/rancher/rke2/registries.yaml"; do
    [[ -s $f ]] || continue
    for ep in $(grep -o -E 'https?://[^" ]+' "$f" | sort -u); do
      if curl -s -m 5 -o /dev/null "${ep%/}/v2/"; then say OK "registry $ep reachable (${f#"$R"})"
      else say ERROR "registry $ep in ${f#"$R"} unreachable from this node"; fi
      n=$((n + 1))
    done
  done
  (( n > 0 )) || say WARN "no registry mirror on this node (cluster spec rkeConfig.registries empty): images pull from the internet"
}

check_rke2() {
  local svc v
  if [[ ! -x $RKE/bin/rke2 && ! -x /usr/local/bin/rke2 ]]; then
    say INFO "rke2 not installed yet (waiting for plan / installer image)"; return 1
  fi
  v=$({ "$RKE/bin/rke2" --version 2>/dev/null || /usr/local/bin/rke2 --version 2>/dev/null; } | head -1)
  for svc in rke2-server rke2-agent; do
    systemctl is-enabled --quiet "$svc" 2>/dev/null || continue
    if systemctl is-active --quiet "$svc"; then say OK "$svc active ($v)"
    else say ERROR "$svc not active ($(systemctl show -p ActiveState,SubState --value "$svc" | tr '\n' ' '))"; fi
    each ERROR "$svc: " < <(journalctl -u "$svc" --since "-${SINCE:-15min}" -o cat --no-pager 2>/dev/null \
      | tail_err 'level=(error|fatal)' 'learner management|runtime core not ready|Waiting for|retrying|DesiredSet - Replace Wait|failed to resume job')
    return 0
  done
  say INFO "rke2 installed ($v) but no rke2-server/rke2-agent enabled yet (plan not applied)"
  # Probe "CA cert" errors are filtered above: certs appear only once rke2-server starts. Show plan progress instead.
  each INFO 'plan: ' < <(journalctl -u rancher-system-agent --since "-${SINCE:-15min}" -o cat --no-pager 2>/dev/null \
    | grep -E '\[Applyinator\]|\[K8s\]' | clean | tail -3)
  return 1
}

check_images() {
  local log=$RKE/agent/containerd/containerd.log
  [[ -s $log ]] || return 0
  local ref reason
  # Old failures stay in the log; report only images still absent locally.
  while IFS=$'\t' read -r ref reason; do
    present "$ref" || say ERROR "image pull failed: $ref -- $reason"
  done < <(tail -n 2000 "$log" | grep -E 'PullImage .* failed' \
    | sed -E 's/.*PullImage \\"([^\\]+)\\" failed.*: ([^:]+)"$/\1\t\2/' | sort -t$'\t' -u -k1,1 | tail -15)
}

check_k8s() {
  local kc=$R/etc/rancher/rke2/rke2.yaml kubectl=$RKE/bin/kubectl bad ready
  [[ -s $kc && -x $kubectl ]] || { say INFO "no local kubeconfig (agent-only node or API not up yet)"; return 0; }
  kubectl() { kubectl_cmd 5s "$@"; }
  if ! kubectl get --raw /readyz >/dev/null 2>&1; then say WARN "kube-apiserver not answering yet"; return 0; fi
  ready=$(kubectl get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ $ready == True ]] && say OK "node $(hostname) Ready" || say WARN "node $(hostname) Ready=${ready:-unknown}"
  bad=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" {print $1"/"$2" "$4}')
  [[ -z $bad ]] || while IFS= read -r l; do
    case $l in
      *CrashLoop*|*Error*) say ERROR "pod $l: $(kubectl -n "${l%%/*}" logs "$(cut -d' ' -f1 <<< "${l#*/}")" --tail=2 2>&1 | tr '\n' ' ' | cut -c1-200)";;
      *ImagePull*|*ErrImage*) say ERROR "pod $l (see image pull lines)";;
      *) say INFO "pod $l";;
    esac
  done <<< "$bad"
  if kubectl -n cattle-system get deploy cattle-cluster-agent >/dev/null 2>&1; then
    if [[ $(kubectl -n cattle-system get deploy cattle-cluster-agent -o jsonpath='{.status.availableReplicas}') -ge 1 ]] 2>/dev/null; then
      say OK "cattle-cluster-agent available (connected to Rancher)"
    else
      say WARN "cattle-cluster-agent not available:"
      each ERROR 'cluster-agent: ' < <(kubectl -n cattle-system logs deploy/cattle-cluster-agent --tail=50 2>/dev/null \
        | tail_err 'error|fail|x509|refused|timeout')
    fi
  else
    say INFO "cattle-cluster-agent not deployed yet"
  fi
}

check_host() {
  getent hosts "$(hostname)" >/dev/null || say WARN "hostname $(hostname) not resolvable (add to /etc/hosts; sudo warns)"
  grep -q '^nameserver' "$R/etc/resolv.conf" 2>/dev/null \
    || say WARN "no nameserver in /etc/resolv.conf (subnet has no DNS): names like docker.io fail; mirrors must use IPs"
  local use; use=$(df -P "$R/var/lib" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
  [[ -z $use || $use -lt 90 ]] || say ERROR "/var/lib ${use}% full"
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != no ]] || say WARN "clock not NTP-synchronized (certificates can fail)"
}

# Fully qualify a ref the way containerd does: rancher/x -> docker.io/rancher/x, pause -> docker.io/library/pause.
fq() {
  [[ $1 == */* ]] || { echo "docker.io/library/$1"; return; }   # no slash: no host part (busybox:1 is not host:port)
  case ${1%%/*} in *.*|*:*|localhost) echo "$1" ;; *) echo "docker.io/$1" ;; esac
}

# Fully-qualified refs of images that failed to pull (containerd log + pods in ErrImagePull) and are still absent.
missing_refs() {
  local log=$RKE/agent/containerd/containerd.log kc=$R/etc/rancher/rke2/rke2.yaml ref
  {
    [[ -s $log ]] && grep -E 'PullImage .* failed' "$log" | sed -E 's/.*PullImage \\"([^\\]+)\\" failed.*/\1/'
    [[ -s $kc && -x $RKE/bin/kubectl ]] && kubectl_cmd 5s get pods -A -o json 2>/dev/null \
      | jq -r '.items[].status | (.containerStatuses // []) + (.initContainerStatuses // []) | .[]
               | select((.state.waiting.reason // "") | test("ErrImagePull|ImagePullBackOff")) | .image'
  } | sort -u | while IFS= read -r ref; do
    [[ $ref =~ ^[A-Za-z0-9._/:-]+$ ]] || continue
    ref=$(fq "$ref")
    present "$ref" && continue   # pulled since
    echo "$ref"
  done
}

collect_missing() {
  local out=$1
  missing_refs > "$out"
  echo "$(grep -c . "$out") missing image(s) -> $out"
  [[ ! -s $out ]] || echo "Fix: on an internet CubeCOS host: bash rancher-operation.sh --download $(basename "$out"); carry the folder; on the offline controller: bash rancher-operation.sh --upload"
}

# Images in local containerd plus images referenced by every pod in the cluster (server node). No jq needed.
collect_used() {
  local out=$1 ref
  {
    CRI_CONFIG_FILE=$RKE/agent/etc/crictl.yaml crictl images 2>/dev/null | awk 'NR > 1 && $2 != "<none>" {print $1 ":" $2}'
    [[ -s $R/etc/rancher/rke2/rke2.yaml ]] && kc get pods -A -o \
      jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  } | while IFS= read -r ref; do
    [[ $ref =~ ^[A-Za-z0-9._/:-]+$ ]] || continue   # skips @sha256 digests and blanks
    fq "$ref"
  done | sort -u > "$out"
  echo "$(grep -c . "$out") image(s) in use -> $out"
  [[ ! -s $out ]] || echo "Pre-seed another site: bash rancher-operation.sh --download $(basename "$out") on an internet host; carry; --upload"
}

# Delete pods waiting on an image pull so their controller recreates them and the pull is tried now.
retry_pulls() {
  local ns name ref n=0 failed=0
  if [[ ! -s $R/etc/rancher/rke2/rke2.yaml ]]; then
    # Worker: no API credentials to delete pods. Pull the failed images here (through the node's mirror config);
    # the kubelet finds them at its next back-off retry and starts the pods.
    while IFS= read -r ref; do
      if CRI_CONFIG_FILE=$RKE/agent/etc/crictl.yaml crictl pull "$ref" >/dev/null 2>&1; then echo "pulled $ref"; n=$((n + 1))
      else echo "FAILED $ref (not in the mirror? check: sudo bash $0 --missing)"; failed=$((failed + 1)); fi
    done < <(missing_refs)
    echo "worker node: $n image(s) pulled, $failed failed; pods start at the kubelet's next retry (up to 5 min). Follow: sudo bash $0 --watch"
    (( failed == 0 )); return
  fi
  while read -r ns name; do
    kc -n "$ns" delete pod "$name" --wait=false >/dev/null && { echo "restarted $ns/$name"; n=$((n + 1)); }
  done < <(kc get pods -A --no-headers 2>/dev/null | awk '$4 ~ /ErrImagePull|ImagePullBackOff/ {print $1, $2}')
  echo "$n pod(s) restarted; follow with: sudo bash $0 --watch"
}

# Internet reachability of the registries a cluster pulls from. None reachable is a WARN, not an ERROR:
# an offline site gets everything from the registry mirror (checked in check_registries).
NET_URLS=${NET_URLS:-"https://registry-1.docker.io/v2/ https://registry.k8s.io/v2/ https://quay.io/v2/ https://registry.rancher.com/v2/ https://nvcr.io/v2/"}
NET_DONE=no
check_internet() {
  [[ $NET_DONE == yes ]] && return 0   # once per run: --watch would otherwise curl every INTERVAL
  NET_DONE=yes
  local gw ns px u h r code t ip rip ok=0 n=0
  gw=$(ip route show default 2>/dev/null | awk '{print $3 " (" $5 ")"; exit}')
  ns=$(awk '/^nameserver/ {printf "%s%s", (n++ ? " " : ""), $2}' "$R/etc/resolv.conf" 2>/dev/null)
  px=$(grep -h -i -E '^(HTTPS?|NO)_PROXY=' "$R/etc/default/rke2-server" "$R/etc/default/rke2-agent" 2>/dev/null | sort -u | tr '\n' ' ')
  say INFO "network: default route ${gw:-none}, nameservers ${ns:-none}, rke2 proxy ${px:-none}"
  for u in $NET_URLS; do
    h=${u#*://}; h=${h%%/*}; n=$((n + 1))
    ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z $ip ]]; then say WARN "internet: $h DNS lookup failed"; continue; fi
    r=$(curl -s -o /dev/null -m "${NET_TIMEOUT:-5}" -w '%{http_code} %{time_total} %{remote_ip}' "$u" 2>/dev/null)
    read -r code t rip <<< "$r"
    if [[ -n $code && $code != 000 ]]; then   # any HTTP answer (401 is normal for /v2/) = reachable
      say OK "internet: $h reachable (${rip:-$ip}, HTTP $code, $(printf '%.2f' "${t:-0}")s)"; ok=$((ok + 1))
    else say WARN "internet: $h resolves to $ip but HTTPS fails (firewall, no route, or proxy needed)"; fi
  done
  if (( ok == 0 )); then say WARN "internet: no registry reachable ($n tried): every image must come from the registry mirror"
  else say OK "internet: $ok/$n registries reachable"; fi
}

pass() {
  ERRORS=0
  check_host; check_internet; check_cloudinit
  check_agent && check_registries
  check_rke2 && check_k8s
  check_images   # pulls can fail during install too, before the services exist
}

main() {
  [[ $(id -u) == 0 || -n $R ]] || { echo "Run with sudo." >&2; return 1; }
  [[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n 2,12p "$0"; return 0; }
  [[ $KUBECTL_INSECURE_SKIP_TLS_VERIFY == no ]] || say WARN "kubectl TLS verification disabled; API server identity is not verified"
  if [[ ${1:-} == --retry ]]; then retry_pulls; return; fi
  if [[ ${1:-} == --net ]]; then check_internet; return 0; fi
  if [[ ${1:-} == --used ]]; then collect_used "${2:-used-images.txt}"; return; fi
  if [[ ${1:-} == --missing ]]; then
    command -v jq >/dev/null || echo 'WARN: jq not installed; pod images skipped, containerd log only' >&2
    collect_missing "${2:-missing-images.txt}"; return
  fi
  pass
  if [[ $WATCH == yes ]]; then while sleep "${INTERVAL:-5}"; do pass; done; fi
  (( ERRORS == 0 ))
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
