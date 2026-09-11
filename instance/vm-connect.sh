#!/usr/bin/env bash

# Exit immediately on unhandled errors
set -e

SERVER_ID="$1"
NEWPASS="$2"

# 1. Validate SERVER_ID input
if [ -z "$SERVER_ID" ]; then
    echo "Error: Server ID or name is required."
    echo "Usage: $0 <SERVER_ID> [NEWPASS]"
    exit 1
fi

# 2. Prompt for password if NEWPASS was not provided as an argument
if [ -z "$NEWPASS" ]; then
    # Read password without echoing characters to screen (-s)
    read -rsp "Enter new password for root: " NEWPASS
    echo "" # Print newline after hidden input
    
    read -rsp "Confirm new password: " NEWPASS_CONFIRM
    echo ""

    if [ "$NEWPASS" != "$NEWPASS_CONFIRM" ]; then
        echo "Error: Passwords do not match."
        exit 1
    fi
fi

# Ensure password is not empty
if [ -z "$NEWPASS" ]; then
    echo "Error: Password cannot be blank."
    exit 1
fi

echo "Fetching details for server: $SERVER_ID..."

# 3. Query OpenStack server details in JSON format and extract fields using jq
SERVER_INFO=$(openstack server show "$SERVER_ID" -f json)

COMPUTE_HOST=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-SRV-ATTR:host"')
INSTANCE_NAME=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-SRV-ATTR:instance_name"')

# 4. Verify retrieved values
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
echo "Setting root password..."

# 5. SSH into compute host and execute virsh set-user-password
ssh -t "$COMPUTE_HOST" "sudo virsh set-user-password --password '$NEWPASS' --user root --domain '$INSTANCE_NAME'"

echo "Password successfully set for root on instance $INSTANCE_NAME."