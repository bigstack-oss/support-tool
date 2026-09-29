#!/usr/bin/env bash
# Upgrade an existing Rancher release from a rancher-download.sh package.
set -Eeuo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is required"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
norm() { sed -E 's/^v//; s/[[:space:]].*$//'; }
cli_version() { "$1" --version | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | norm; }

PACKAGE=${1:-.}; KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
SYSTEM_DEFAULT_REGISTRY=${SYSTEM_DEFAULT_REGISTRY:-}; TIMEOUT=${HELM_TIMEOUT:-15m}
# Set SINGLE_NODE=true for a one-node Rancher installation. This permits the
# required anti-affinity and rollout-strategy changes for an in-place upgrade.
SINGLE_NODE=${SINGLE_NODE:-false}
# Optional seconds between progress updates while Helm is waiting (default: 10).
WAIT=${WAIT:-10}
MANIFEST="$PACKAGE/manifest.tsv"
value() { awk -F '\t' -v k="$1" '$1==k {print substr($0,length(k)+2);exit}' "$MANIFEST"; }
newer() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" && "$1" != "$2" ]]; }

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

for x in helm kubectl cubectl jq tar shasum awk find install; do need "$x"; done
[[ -f "$MANIFEST" ]] || die "package manifest not found"
[[ -n "$SYSTEM_DEFAULT_REGISTRY" ]] || die "set SYSTEM_DEFAULT_REGISTRY to the registry containing package images"
VERSION=$(value version); CHART="$PACKAGE/$(value chart)"; CLI="$PACKAGE/$(value cli)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -f "$CHART" && -f "$CLI" ]] || die "incomplete package"
[[ "$(sha "$CHART")" == "$(value chart_sha256)" ]] || die "chart checksum mismatch"
[[ "$(sha "$CLI")" == "$(value cli_sha256)" ]] || die "CLI checksum mismatch"
for asset in rancher-images.txt rancher-save-images.sh rancher-load-images.sh rancher-images.tar.gz; do
  path="$PACKAGE/images/$asset"; key="image_${asset//./_}"
  [[ -s "$path" && "$(sha "$path")" == "$(value "$key")" ]] || die "image asset checksum mismatch: $asset"
done
[[ "$(helm show chart "$CHART" | awk '$1=="appVersion:" {print $2}' | norm)" == "$VERSION" ]] || die "chart appVersion mismatch"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
tar -xzf "$CLI" -C "$TMP"; BIN=$(find "$TMP" -type f -name rancher -perm -u+x -print -quit)
[[ -n "$BIN" && "$(cli_version "$BIN")" == "$VERSION" ]] || die "CLI package mismatch"
RELEASE=$(helm --kubeconfig "$KUBECONFIG" -n cattle-system list --filter '^rancher$' -o json)
[[ "$(jq length <<<"$RELEASE")" == 1 ]] || die "existing cattle-system/rancher release not found"
CURRENT=$(jq -r '.[0].app_version' <<<"$RELEASE" | norm); newer "$CURRENT" "$VERSION" || die "target v$VERSION is not newer than deployed server v$CURRENT"
CURRENT_VALUES=$(helm --kubeconfig "$KUBECONFIG" -n cattle-system get values rancher --all -o json)
CURRENT_REPLICAS=$(jq -r '.replicas // 1' <<<"$CURRENT_VALUES")
CURRENT_AFFINITY=$(jq -r '.antiAffinity // "preferred"' <<<"$CURRENT_VALUES")
UPGRADE_OVERRIDES=()
if [[ "$CURRENT_REPLICAS" == 1 && "$CURRENT_AFFINITY" == required ]]; then
  if [[ "$SINGLE_NODE" != true ]]; then
    die "one replica with antiAffinity=required cannot perform a rolling upgrade. Re-run with SINGLE_NODE=true to set antiAffinity=preferred for this upgrade."
  fi
  echo "NOTICE: switching antiAffinity from required to preferred for this single-node upgrade."
  UPGRADE_OVERRIDES+=(--set-string antiAffinity=preferred)
fi
if [[ "$SINGLE_NODE" == true ]]; then
  echo "NOTICE: configuring a single-node rollout (maxUnavailable=1, maxSurge=0). Rancher will be briefly unavailable while its pod is replaced."
  kubectl --kubeconfig "$KUBECONFIG" -n cattle-system patch deployment rancher --type merge \
    -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1,"maxSurge":0}}}}'
fi
echo "Upgrading Rancher Server v$CURRENT -> v$VERSION from verified package"
run_helm_with_progress helm --kubeconfig "$KUBECONFIG" upgrade rancher "$CHART" -n cattle-system --reuse-values \
  --set-string "systemDefaultRegistry=$SYSTEM_DEFAULT_REGISTRY" "${UPGRADE_OVERRIDES[@]}" --atomic --wait --timeout "$TIMEOUT"
UPDATED=$(helm --kubeconfig "$KUBECONFIG" -n cattle-system list --filter '^rancher$' -o json | jq -r '.[0].app_version' | norm)
[[ "$UPDATED" == "$VERSION" ]] || die "Helm release reports v$UPDATED after upgrade"
kubectl --kubeconfig "$KUBECONFIG" -n cattle-system rollout status deployment/rancher --timeout="$TIMEOUT"
install -m 0755 "$BIN" /usr/local/bin/rancher
rancher --version | grep -q "v$VERSION" || die "installed CLI version check failed"
if [[ "$SINGLE_NODE" == true ]]; then
  echo "Skipping Rancher CLI sync because SINGLE_NODE=true."
else
  cubectl node rsync -r control /usr/local/bin/rancher
fi
echo "Rancher Server and Rancher CLI are both v$VERSION."
