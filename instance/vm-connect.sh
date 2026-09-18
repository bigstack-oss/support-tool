#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

SERVER_ID="$1"

# 1. Validate input
if [ -z "$SERVER_ID" ]; then
    echo "Error: Server ID or name is required."
    echo "Usage: $0 <SERVER_ID>"
    exit 1
fi

echo "Fetching details for server: $SERVER_ID..."

# 2. Query OpenStack CLI formatted as JSON and extract required fields using jq
# Requires: openstack CLI and jq installed
SERVER_INFO=$(openstack server show "$SERVER_ID" -f json)

COMPUTE_HOST=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-SRV-ATTR:host"')
INSTANCE_NAME=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-SRV-ATTR:instance_name"')

# 3. Verify extracted values
if [ -z "$COMPUTE_HOST" ] || [ "$COMPUTE_HOST" == "null" ]; then
    echo "Error: Could not retrieve compute host for server $SERVER_ID."
    exit 1
fi

if [ -z "$INSTANCE_NAME" ] || [ "$INSTANCE_NAME" == "null" ]; then
    echo "Error: Could not retrieve instance name for server $SERVER_ID."
    exit 1
fi

echo "Compute Host : $COMPUTE_HOST"
echo "Instance Name: $INSTANCE_NAME"
echo "Connecting to console..."
echo "----------------------------------------"

# 4. SSH to compute host and open virsh console (-t allocates a pseudo-TTY required for console)
ssh -t "$COMPUTE_HOST" "sudo virsh console $INSTANCE_NAME"