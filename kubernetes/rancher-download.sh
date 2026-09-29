#!/usr/bin/env bash
# Interactively build one verified Rancher air-gap package compatible with the
# installed Rancher Server.
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is required"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
norm() { sed -E 's/^v//; s/[[:space:]].*$//'; }
cli_version() { "$1" --version | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | norm; }
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
[[ $# == 1 ]] || die "Usage: $0 <package-directory>"
OUTPUT_DIR=$1
for command in helm jq curl tar shasum awk find docker; do need "$command"; done

release=$(helm --kubeconfig "$KUBECONFIG" -n cattle-system list --filter '^rancher$' -o json)
[[ "$(jq length <<<"$release")" == 1 ]] || die "existing cattle-system/rancher Helm release not found"
CURRENT_VERSION=$(jq -r '.[0].app_version' <<<"$release" | norm)
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine deployed Rancher Server version"
echo "Deployed Rancher Server: v$CURRENT_VERSION"

helm repo add rancher-stable https://releases.rancher.com/server-charts/stable >/dev/null
helm repo update rancher-stable >/dev/null
mkdir -p "$OUTPUT_DIR"

download_one() {
  local version package chart cli app_version cli_version base asset tmp bin
  version=$1
  package="$OUTPUT_DIR/rancher-offline-v$version"
  chart="$package/charts/rancher-$version.tgz"
  cli="$package/cli/rancher-linux-amd64-v$version.tar.gz"

  if [[ -f "$package/manifest.tsv" ]]; then
    echo "v$version: package already exists; skipping $package"
    return 0
  fi
  mkdir -p "$package/charts" "$package/cli" "$package/images"
  # A previous interrupted run may have partial chart/CLI downloads. Rebuild
  # those two artifacts; a manifest is only written after full verification.
  rm -f "$chart" "$cli"

  helm pull rancher-stable/rancher --version "$version" --destination "$package/charts"
  [[ -f "$chart" ]] || { echo "v$version: chart was not downloaded" >&2; return 1; }
  app_version=$(helm show chart "$chart" | awk '$1 == "appVersion:" {print $2}' | norm)
  [[ "$app_version" == "$version" ]] || { echo "v$version: chart appVersion is v$app_version; skipping incompatible chart" >&2; return 1; }

  curl --fail --location --proto '=https' --retry 3 -o "$cli" \
    "https://releases.rancher.com/cli2/v$version/rancher-linux-amd64-v$version.tar.gz"
  tmp=$(mktemp -d)
  tar -xzf "$cli" -C "$tmp"
  bin=$(find "$tmp" -type f -name rancher -perm -u+x -print -quit)
  if [[ -z "$bin" ]]; then rm -rf "$tmp"; echo "v$version: CLI archive is invalid" >&2; return 1; fi
  cli_version=$(cli_version "$bin")
  rm -rf "$tmp"
  [[ "$cli_version" == "$version" ]] || { echo "v$version: CLI reports v$cli_version; skipping mismatch" >&2; return 1; }

  base="https://github.com/rancher/rancher/releases/download/v$version"
  for asset in rancher-images.txt rancher-save-images.sh rancher-load-images.sh; do
    curl --fail --location --proto '=https' --retry 3 -o "$package/images/$asset" "$base/$asset"
  done
  chmod +x "$package/images/rancher-save-images.sh" "$package/images/rancher-load-images.sh"
  echo "v$version: saving Rancher images (this can take several minutes)..."
  (cd "$package/images" && ./rancher-save-images.sh --image-list rancher-images.txt --images rancher-images.tar.gz)
  [[ -s "$package/images/rancher-images.tar.gz" ]] || { echo "v$version: Rancher image archive was not created" >&2; return 1; }

  {
    printf 'format\t1\nversion\t%s\nchart\tcharts/%s\nchart_sha256\t%s\nchart_app_version\t%s\n' "$version" "$(basename "$chart")" "$(sha "$chart")" "$app_version"
    printf 'cli\tcli/%s\ncli_sha256\t%s\ncli_version\t%s\n' "$(basename "$cli")" "$(sha "$cli")" "$cli_version"
    for asset in rancher-images.txt rancher-save-images.sh rancher-load-images.sh rancher-images.tar.gz; do
      printf 'image_%s\t%s\n' "${asset//./_}" "$(sha "$package/images/$asset")"
    done
  } > "$package/manifest.tsv"
  echo "v$version: verified package created: $package"
}

mapfile -t all_versions < <(helm search repo rancher-stable/rancher --versions -o json | jq -r '.[].version' | sort -Vu)
selected=()
for version in "${all_versions[@]}"; do
  version=$(printf '%s' "$version" | norm)
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_ge "$version" "$CURRENT_VERSION" && selected+=("$version")
done
[[ ${#selected[@]} -gt 0 ]] || die "no stable Rancher chart versions equal to or newer than v$CURRENT_VERSION"

for i in "${!selected[@]}"; do
  printf '%d. v%s\n' "$((i + 1))" "${selected[i]}"
done

read -r -p 'Choose target version: ' choice
[[ "$choice" =~ ^[0-9]+$ ]] || die "selection must be a number"
(( choice >= 1 && choice <= ${#selected[@]} )) || die "selection is out of range"
TARGET_VERSION=${selected[choice - 1]}

echo "Building Rancher offline package v$TARGET_VERSION in: $OUTPUT_DIR"
download_one "$TARGET_VERSION" || die "v$TARGET_VERSION: package build failed; inspect the messages above"
echo "Rancher offline package is in: $OUTPUT_DIR/rancher-offline-v$TARGET_VERSION"
