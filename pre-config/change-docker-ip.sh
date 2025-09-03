#!/bin/bash

# Step 1: Copy daemon.json
cp ./daemon.json /etc/docker/daemon.json || {
    echo "❌ Failed to copy daemon.json"
    exit 1
}

# Step 2: Start Docker
systemctl start docker || {
    echo "❌ Failed to start Docker"
    exit 1
}

# Step 3: Wait for docker0 to be created
sleep 3

# Step 4: Compare docker0 IP with daemon.json "bip"
docker_ip=$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
config_ip=$(jq -r '.bip' /etc/docker/daemon.json 2>/dev/null | cut -d/ -f1)

if [[ -z "$docker_ip" ]]; then
    echo "❌ docker0 interface not found or has no IP."
    exit 1
fi

ip a show docker0

if [[ "$docker_ip" == "$config_ip" ]]; then
    echo "✅ docker0 IP ($docker_ip) matches configured bip ($config_ip)."
else
    echo "⚠️ docker0 IP ($docker_ip) does NOT match configured bip ($config_ip)."
fi

# Step 5: Stop docker.socket (optional, if active)
systemctl stop docker.socket 2>/dev/null || true

# Step 6: Done
echo "✔ Ready. You may start cluster setup."