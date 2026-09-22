#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

SERVER_ID="$1"
NEWPASS="$2"

# 1. Validate SERVER_ID input
if [ -z "$SERVER_ID" ]; then
    echo "Error: Server ID or name is required."
    echo "Usage: $0 <SERVER_ID> [NEWPASS]"
    exit 1
fi

echo "Fetching details for server: $SERVER_ID..."

# 2. Query OpenStack server details
SERVER_INFO=$(openstack server show "$SERVER_ID" -f json)

COMPUTE_HOST=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-SRV-ATTR:host"')
INSTANCE_NAME=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-SRV-ATTR:instance_name"')
VM_STATE=$(echo "$SERVER_INFO" | jq -r '."OS-EXT-STS:vm_state"')

# 3. Verify retrieved values
if [ -z "$COMPUTE_HOST" ] || [ "$COMPUTE_HOST" == "null" ]; then
    echo "Error: Could not retrieve compute host for server $SERVER_ID."
    exit 1
fi

if [ -z "$INSTANCE_NAME" ] || [ "$INSTANCE_NAME" == "null" ]; then
    echo "Error: Could not retrieve instance name for server $SERVER_ID."
    exit 1
fi

# 4. Strict vm_state check
if [ "$VM_STATE" != "active" ]; then
    echo "Error: Server $SERVER_ID is not active (current state: '$VM_STATE')."
    echo "Please start the instance before proceeding."
    exit 1
fi

echo "Compute Host : $COMPUTE_HOST"
echo "Instance Name: $INSTANCE_NAME"
echo "VM State     : $VM_STATE"

# 5. Determine whether to reset password
RESET_PASS=false

if [ -n "$NEWPASS" ]; then
    RESET_PASS=true
else
    read -rp "Do you want to reset root password? [YES/no]: " CONFIRM_RESET
    if [ "$CONFIRM_RESET" == "YES" ] || [ "$CONFIRM_RESET" == "yes" ] || [ "$CONFIRM_RESET" == "y" ]; then
        RESET_PASS=true
        read -rsp "Enter new password for root: " NEWPASS
        echo ""
        read -rsp "Confirm new password: " NEWPASS_CONFIRM
        echo ""

        if [ "$NEWPASS" != "$NEWPASS_CONFIRM" ]; then
            echo "Error: Passwords do not match."
            exit 1
        fi

        if [ -z "$NEWPASS" ]; then
            echo "Error: Password cannot be blank."
            exit 1
        fi
    fi
fi

# 6. Execute password reset if requested
if [ "$RESET_PASS" = true ]; then
    echo "Resetting root password..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "$COMPUTE_HOST" \
      "sudo virsh set-user-password --password '$NEWPASS' --user root --domain '$INSTANCE_NAME'"
    echo "Password successfully set for root."
fi

# Get active local window dimensions
LOCAL_COLS=$(tput cols 2>/dev/null || echo 120)
LOCAL_ROWS=$(tput lines 2>/dev/null || echo 40)

# 7. Connect to console and pass current terminal settings
echo "Connecting to console..."
echo "----------------------------------------"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "$COMPUTE_HOST" \
  "stty cols $LOCAL_COLS rows $LOCAL_ROWS && sudo virsh console --force '$INSTANCE_NAME'"

# 8. Restore local terminal state after exit
stty sane