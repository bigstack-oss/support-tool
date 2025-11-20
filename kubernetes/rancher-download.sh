mkdir -p ./charts
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# Example: download specific version(s)
TARGET_VERSIONS="2.8.4 2.9.2 2.10.1 2.11.3 2.12.3"

for v in $TARGET_VERSIONS; do
  helm pull rancher-stable/rancher \
    --version "$v" \
    --destination ./charts
done

mkdir -p ./cli
for v in $TARGET_VERSIONS; do
  curl -fL \
    -o "./cli/rancher-linux-amd64-v${v}.tar.gz" \
    "https://releases.rancher.com/cli2/v${v}/rancher-linux-amd64-v${v}.tar.gz"
done
