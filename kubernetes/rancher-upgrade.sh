#!/bin/bash

set -e
# update helm
echo "Updating Helm..."
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# Function to get the installed Rancher version
get_installed_version() {
  rancher --version | awk '{print $3}' | sed 's/v//'
}

# Get the installed version
INSTALLED_VERSION=$(get_installed_version)
echo "Current Rancher version: v$INSTALLED_VERSION"

# Fetch available Rancher versions
echo "Fetching available Rancher versions..."
AVAILABLE_VERSIONS=$(helm search repo rancher-stable/rancher --versions | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)

# Filter versions higher than installed version and check if CLI exists
UPGRADE_VERSIONS=()
for version in $AVAILABLE_VERSIONS; do
  CLI_URL="https://releases.rancher.com/cli2/v$version/rancher-linux-amd64-v$version.tar.gz"
  
  # Check if URL exists before adding to list
  if curl --output /dev/null --silent --head --fail "$CLI_URL"; then
    if [[ $(echo -e "$INSTALLED_VERSION\n$version" | sort -V | head -n1) != "$version" ]]; then
      UPGRADE_VERSIONS+=("$version")
    fi
  fi
done

# Check if there are any valid upgrade options
if [[ ${#UPGRADE_VERSIONS[@]} -eq 0 ]]; then
  echo "No newer Rancher versions available for upgrade."
  exit 0
fi

echo "Available versions for upgrade:"
for i in "${!UPGRADE_VERSIONS[@]}"; do
  echo "$((i+1)). v${UPGRADE_VERSIONS[i]}"
done

# Prompt user to select a version with retry mechanism
while true; do
  read -p "Enter the number of the version you want to upgrade to: " CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#UPGRADE_VERSIONS[@]}" ]; then
    break
  else
    echo "Invalid selection. Please enter a valid number."
  fi
done

SELECTED_VERSION=${UPGRADE_VERSIONS[$((CHOICE-1))]}
echo "Upgrading Rancher to v$SELECTED_VERSION..."

# Define Helm values
REPLICAS=$(k3s kubectl get nodes -o go-template='{{len .items}}')
VALUES="
bootstrapPassword: admin
replicas: $REPLICAS
ingress:
  enabled: true
  pathType: ImplementationSpecific
  path: \"/\"
  tls:
    source: secret
tls: external
privateCA: true
useBundledSystemChart: true
antiAffinity: required
"

# Add Rancher repo and update
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable || { echo "Failed to add Rancher repo"; exit 1; }
helm repo update || { echo "Failed to update Rancher repo"; exit 1; }

# Upgrade Rancher
helm --kubeconfig /etc/rancher/k3s/k3s.yaml upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version "$SELECTED_VERSION" \
  --values <(echo "$VALUES") || { echo "Helm upgrade failed"; exit 1; }

# Download and install Rancher CLI if the file exists
CLI_URL="https://releases.rancher.com/cli2/v$SELECTED_VERSION/rancher-linux-amd64-v$SELECTED_VERSION.tar.gz"
echo "Downloading Rancher CLI v$SELECTED_VERSION..."
if curl --output /dev/null --silent --head --fail "$CLI_URL"; then
  wget -qO- --no-check-certificate "$CLI_URL" | tar -xz --strip-components=2 -C /usr/local/bin/
  cubectl node rsync -r control /usr/local/bin/rancher
  echo "Rancher CLI installed successfully."
else
  echo "CLI not found for version $SELECTED_VERSION. Skipping installation."
fi

echo "Rancher upgrade to v$SELECTED_VERSION completed successfully!"

# Get the new installed version
NEW_VERSION=$(get_installed_version)
echo "New Rancher version: v$NEW_VERSION"