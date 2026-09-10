#!/usr/bin/env bash
# Online upgrade of an existing Rancher Helm release while preserving its values.
set -Eeuo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is required"; }
norm() { sed -E 's/^v//; s/[[:space:]].*$//'; }
cli_version() { "$1" --version | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | norm; }
newer() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" && "$1" != "$2" ]]; }
KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}; TIMEOUT=${HELM_TIMEOUT:-15m}; TARGET=${1:-}
# Optional seconds between progress updates while Helm is waiting (default: 10).
WAIT=${WAIT:-10}

show_progress() {
  echo "[$(date '+%F %T')] Rancher upgrade progress:"
  kubectl --kubeconfig "$KUBECONFIG" -n cattle-system get deployment rancher \
    -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas --no-headers 2>/dev/null || true
  kubectl --kubeconfig "$KUBECONFIG" -n cattle-system get pods -l app=rancher \
    -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName --no-headers 2>/dev/null || true
  kubectl --kubeconfig "$KUBECONFIG" -n cattle-system get events --sort-by=.lastTimestamp 2>/dev/null \
    | tail -n 4 | sed 's/^/  event: /' || true
}

run_helm_with_progress() {
  local log_file pid status
  log_file=$(mktemp)
  "$@" >"$log_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    show_progress
    sleep "$WAIT"
  done
  if wait "$pid"; then
    cat "$log_file"
    rm -f "$log_file"
    return 0
  fi
  status=$?
  echo "Helm upgrade failed (exit $status). Helm output:" >&2
  cat "$log_file" >&2
  rm -f "$log_file"
  return "$status"
}

for x in helm kubectl cubectl jq curl tar awk find install; do need "$x"; done
NODE_COUNT=$(cubectl node list | wc -l | tr -d '[:space:]')
[[ "$NODE_COUNT" =~ ^[0-9]+$ && "$NODE_COUNT" -ge 1 ]] || die "could not determine node count from: cubectl node list"
IS_SINGLE_NODE=false
if [[ "$NODE_COUNT" == 1 ]]; then
  IS_SINGLE_NODE=true
  echo "Detected a single-node deployment from cubectl node list."
else
  echo "Detected a $NODE_COUNT-node deployment from cubectl node list."
fi
RELEASE=$(helm --kubeconfig "$KUBECONFIG" -n cattle-system list --filter '^rancher$' -o json)
[[ "$(jq length <<<"$RELEASE")" == 1 ]] || die "existing cattle-system/rancher release not found"
CURRENT=$(jq -r '.[0].app_version' <<<"$RELEASE" | norm); echo "Deployed Rancher Server: v$CURRENT"
CURRENT_VALUES=$(helm --kubeconfig "$KUBECONFIG" -n cattle-system get values rancher --all -o json)
CURRENT_REPLICAS=$(jq -r '.replicas // 1' <<<"$CURRENT_VALUES")
CURRENT_AFFINITY=$(jq -r '.antiAffinity // "preferred"' <<<"$CURRENT_VALUES")
UPGRADE_OVERRIDES=()
if [[ "$CURRENT_REPLICAS" == 1 && "$CURRENT_AFFINITY" == required ]]; then
  if [[ "$IS_SINGLE_NODE" != true ]]; then
    die "one replica with antiAffinity=required cannot perform a rolling upgrade: the new pod cannot coexist with the old pod. Configure at least two replicas or change antiAffinity before upgrading."
  fi
  echo "NOTICE: switching antiAffinity from required to preferred for this single-node upgrade."
  UPGRADE_OVERRIDES+=(--set-string antiAffinity=preferred)
fi
if [[ "$IS_SINGLE_NODE" == true ]]; then
  echo "NOTICE: configuring a single-node rollout (maxUnavailable=1, maxSurge=0). Rancher will be briefly unavailable while its pod is replaced."
  kubectl --kubeconfig "$KUBECONFIG" -n cattle-system patch deployment rancher --type merge \
    -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1,"maxSurge":0}}}}'
fi
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable >/dev/null; helm repo update rancher-stable >/dev/null
if [[ -z "$TARGET" ]]; then
  mapfile -t choices < <(helm search repo rancher-stable/rancher --versions -o json | jq -r '.[].version' | sort -Vu)
  valid=(); for v in "${choices[@]}"; do
    v=$(printf %s "$v" | norm); newer "$CURRENT" "$v" || continue
    app=$(helm show chart rancher-stable/rancher --version "$v" | awk '$1=="appVersion:" {print $2}' | norm)
    curl --fail --silent --head "https://releases.rancher.com/cli2/v$v/rancher-linux-amd64-v$v.tar.gz" >/dev/null && [[ "$app" == "$v" ]] && valid+=("$v")
  done
  [[ ${#valid[@]} -gt 0 ]] || die "no compatible newer releases found"
  for i in "${!valid[@]}"; do echo "$((i+1)). v${valid[i]}"; done
  read -r -p 'Choose target version: ' n; [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le ${#valid[@]} ]] || die "invalid choice"; TARGET=${valid[n-1]}
fi
TARGET=$(printf %s "$TARGET" | norm); [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "target must be x.y.z"; newer "$CURRENT" "$TARGET" || die "target is not newer"
[[ "$(helm show chart rancher-stable/rancher --version "$TARGET" | awk '$1=="appVersion:" {print $2}' | norm)" == "$TARGET" ]] || die "chart and target server version differ"
echo "Upgrading Rancher Server v$CURRENT -> v$TARGET"
run_helm_with_progress helm --kubeconfig "$KUBECONFIG" upgrade rancher rancher-stable/rancher \
  -n cattle-system --version "$TARGET" --reuse-values "${UPGRADE_OVERRIDES[@]}" --atomic --wait --timeout "$TIMEOUT"
kubectl --kubeconfig "$KUBECONFIG" -n cattle-system rollout status deployment/rancher --timeout="$TIMEOUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl --fail --location --proto '=https' --retry 3 -o "$TMP/cli.tgz" "https://releases.rancher.com/cli2/v$TARGET/rancher-linux-amd64-v$TARGET.tar.gz"
tar -xzf "$TMP/cli.tgz" -C "$TMP"; BIN=$(find "$TMP" -type f -name rancher -perm -u+x -print -quit)
[[ -n "$BIN" && "$(cli_version "$BIN")" == "$TARGET" ]] || die "downloaded CLI does not match target"
install -m 0755 "$BIN" /usr/local/bin/rancher
if [[ "$IS_SINGLE_NODE" == true ]]; then
  echo "Skipping Rancher CLI sync because this is a single-node deployment."
else
  cubectl node rsync -r control /usr/local/bin/rancher
fi
echo "Rancher Server and local Rancher CLI are v$TARGET."
