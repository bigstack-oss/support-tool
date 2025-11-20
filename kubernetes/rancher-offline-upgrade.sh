#!/bin/bash
set -e

# -----------------------------
# Configurable variables
# -----------------------------
OFFLINE_CHART_DIR="./charts"
OFFLINE_CLI_DIR="./cli"

# If you have a private registry, put it here, e.g. "registry.local:5000"
# If you preloaded images manually, leave it empty.
SYSTEM_DEFAULT_REGISTRY="${SYSTEM_DEFAULT_REGISTRY:-}"

# -----------------------------
# Helper functions
# -----------------------------
get_installed_version() {
  rancher --version | awk '{print $3}' | sed 's/^v//'
}

# -----------------------------
# 1. Detect current version
# -----------------------------
INSTALLED_VERSION=$(get_installed_version || echo "0.0.0")
echo "Current Rancher CLI version: v$INSTALLED_VERSION"

# -----------------------------
# 2. Discover available local chart versions
#    Expect files like: rancher-2.9.2.tgz
# -----------------------------
if [[ ! -d "$OFFLINE_CHART_DIR" ]]; then
  echo "ERROR: $OFFLINE_CHART_DIR does not exist. Please copy rancher-<version>.tgz files here."
  exit 1
fi

AVAILABLE_VERSIONS=$(
  find "$OFFLINE_CHART_DIR" -maxdepth 1 -type f -name 'rancher-*.tgz' \
  | sed -E 's|.*/rancher-([0-9]+\.[0-9]+\.[0-9]+)\.tgz|\1|' \
  | sort -V | uniq
)

if [[ -z "$AVAILABLE_VERSIONS" ]]; then
  echo "No local Rancher chart files found in $OFFLINE_CHART_DIR"
  exit 1
fi

# Filter versions higher than installed version
UPGRADE_VERSIONS=()
for version in $AVAILABLE_VERSIONS; do
  # Compare "INSTALLED_VERSION < version" using sort -V
  if [[ "$(printf '%s\n' "$INSTALLED_VERSION" "$version" | sort -V | head -n1)" == "$INSTALLED_VERSION" ]] \
     && [[ "$version" != "$INSTALLED_VERSION" ]]; then
    UPGRADE_VERSIONS+=("$version")
  fi
done

if [[ ${#UPGRADE_VERSIONS[@]} -eq 0 ]]; then
  echo "No newer Rancher versions available in local offline directory."
  exit 0
fi

echo "Available versions for offline upgrade (from local charts):"
for i in "${!UPGRADE_VERSIONS[@]}"; do
  echo "$((i+1)). v${UPGRADE_VERSIONS[i]}"
done

# -----------------------------
# 3. Let user pick a target version
# -----------------------------
while true; do
  read -p "Enter the number of the version you want to upgrade to: " CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && \
     [ "$CHOICE" -ge 1 ] && \
     [ "$CHOICE" -le "${#UPGRADE_VERSIONS[@]}" ]; then
    break
  else
    echo "Invalid selection. Please enter a valid number."
  fi
done

SELECTED_VERSION=${UPGRADE_VERSIONS[$((CHOICE-1))]}
SELECTED_CHART="$OFFLINE_CHART_DIR/rancher-$SELECTED_VERSION.tgz"

if [[ ! -f "$SELECTED_CHART" ]]; then
  echo "ERROR: Chart file not found: $SELECTED_CHART"
  exit 1
fi

echo "Upgrading Rancher to v$SELECTED_VERSION using chart: $SELECTED_CHART"

# -----------------------------
# 4. Prepare Helm values
# -----------------------------
REPLICAS=$(k3s kubectl get nodes -o go-template='{{len .items}}')

VALUES=$(cat <<EOF
bootstrapPassword: admin
replicas: $REPLICAS
ingress:
  enabled: true
  pathType: ImplementationSpecific
  path: "/"
  tls:
    source: secret
tls: external
privateCA: true
useBundledSystemChart: true
antiAffinity: required
EOF
)

# Add systemDefaultRegistry if specified
if [[ -n "$SYSTEM_DEFAULT_REGISTRY" ]]; then
  VALUES=$(cat <<EOF
systemDefaultRegistry: "$SYSTEM_DEFAULT_REGISTRY"
$VALUES
EOF
)
fi

# -----------------------------
# 5. Offline Helm upgrade using local chart file
# -----------------------------
echo "Running Helm upgrade (offline)..."
helm --kubeconfig /etc/rancher/k3s/k3s.yaml upgrade --install rancher "$SELECTED_CHART" \
  --namespace cattle-system \
  --create-namespace \
  --values <(echo "$VALUES")

echo "Helm upgrade finished."

# -----------------------------
# 6. Install Rancher CLI from local tarball (if available)
# -----------------------------
CLI_TARBALL="$OFFLINE_CLI_DIR/rancher-linux-amd64-v$SELECTED_VERSION.tar.gz"
echo "Checking for local Rancher CLI tarball: $CLI_TARBALL"

if [[ -f "$CLI_TARBALL" ]]; then
  echo "Installing Rancher CLI v$SELECTED_VERSION from local file..."
  # Ensure dir exists
  mkdir -p /usr/local/bin

  # Extract only the 'rancher' binary (strip components like original script)
  tar -xz -f "$CLI_TARBALL" --strip-components=2 -C /usr/local/bin/

  # Your custom sync to other nodes (unchanged)
   cubectl node rsync -r control /usr/local/bin/rancher

  echo "Rancher CLI installed successfully from offline package."
else
  echo "Local CLI tarball not found for v$SELECTED_VERSION. Skipping CLI installation."
fi

# -----------------------------
# 7. Show new version (CLI)
# -----------------------------
NEW_VERSION=$(get_installed_version || echo "unknown")
echo "Rancher upgrade completed. Current Rancher CLI version: v$NEW_VERSION"