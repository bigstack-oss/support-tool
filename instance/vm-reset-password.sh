#!/usr/bin/env bash

# Exit immediately on unhandled errors
set -e

SERVER_ID="$1"
NEWPASS="$2"
SSH_PASSWORD_AUTH="${3:-keep}"

# 1. Validate SERVER_ID input
if [ -z "$SERVER_ID" ]; then
    echo "Error: Server ID or name is required."
    echo "Usage: $0 <SERVER_ID> [NEWPASS] [enable|disable|keep]"
    echo 'Use an empty NEWPASS ("") to prompt securely. Default: keep SSH settings.'
    exit 1
fi

case "$SSH_PASSWORD_AUTH" in
    enable|disable|keep) ;;
    *) echo "Error: SSH password authentication must be enable, disable, or keep."; exit 1 ;;
esac
if [ "$#" -gt 3 ]; then
    echo "Error: Too many arguments."
    exit 1
fi

# Quote arguments for the compute host's POSIX shell, including embedded quotes.
shell_quote() {
    local escaped="'\\''"
    printf "'%s'" "${1//\'/$escaped}"
}

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
ssh -t "$COMPUTE_HOST" "sudo virsh set-user-password --password $(shell_quote "$NEWPASS") --user root --domain $(shell_quote "$INSTANCE_NAME")"

echo "Password successfully set for root on instance $INSTANCE_NAME."

if [ "$SSH_PASSWORD_AUTH" = keep ]; then
    exit 0
fi

# Linux guests need QEMU guest-exec enabled, OpenSSH, and systemd.
# PasswordAuthentication applies to all users. Disabling also closes PAM's
# keyboard-interactive password path. Existing Match policies remain in force.
GUEST_SCRIPT=$(cat <<'GUEST'
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mode="$1"
config=/etc/ssh/sshd_config
# Guest-agent execution bypasses systemd's RuntimeDirectory setup.
# Debian/Ubuntu sshd needs this directory even for configuration validation.
if [ ! -d /run/sshd ]; then
    install -d -m 0755 -o root -g root /run/sshd
fi
sshd -t
if systemctl is-active --quiet sshd; then
    unit=sshd
elif systemctl is-active --quiet ssh; then
    unit=ssh
else
    echo 'Error: No active sshd/ssh systemd service.' >&2
    exit 1
fi
backup=$(mktemp /etc/ssh/sshd_config.vm-reset.XXXXXX)
cp -p "$config" "$backup"
rollback() {
    result=$?
    trap - EXIT
    if [ "$result" -ne 0 ]; then
        cp -p "$backup" "$config"
        systemctl reload "$unit" || true
        echo "SSH change failed; restored $backup. Root password was already reset." >&2
    fi
    exit "$result"
}
trap rollback EXIT
{
    echo '# BEGIN vm-reset-password SSH settings'
    if [ "$mode" = enable ]; then
        echo 'PasswordAuthentication yes'
        echo 'PermitRootLogin yes'
    else
        echo 'PasswordAuthentication no'
        echo 'KbdInteractiveAuthentication no'
        echo 'ChallengeResponseAuthentication no'
        echo 'PermitRootLogin prohibit-password'
    fi
    echo '# END vm-reset-password SSH settings'
    sed '/^# BEGIN vm-reset-password SSH settings$/,/^# END vm-reset-password SSH settings$/d' "$backup"
} > "$config"
sshd -t
systemctl reload "$unit"
echo "SSH global password authentication: $mode (backup: $backup)."
echo 'Existing Match, Allow/Deny, PAM, and AuthenticationMethods policies still apply.'
GUEST
)

agent_command() {
    ssh "$COMPUTE_HOST" "sudo -n virsh qemu-agent-command $(shell_quote "$INSTANCE_NAME") $(shell_quote "$1")"
}

echo "Updating guest SSH password authentication: $SSH_PASSWORD_AUTH..."
REQUEST=$(jq -n --arg script "$GUEST_SCRIPT" --arg mode "$SSH_PASSWORD_AUTH" \
    '{execute:"guest-exec",arguments:{path:"/bin/sh",arg:["-c",$script,"vm-reset-password",$mode],"capture-output":true}}')
RESPONSE=$(agent_command "$REQUEST")
PID=$(printf '%s' "$RESPONSE" | jq -er '.return.pid') || {
    echo "Error: guest-exec failed: $RESPONSE" >&2
    exit 1
}
for ((attempt=0; attempt<60; attempt++)); do
    REQUEST=$(jq -n --argjson pid "$PID" '{execute:"guest-exec-status",arguments:{pid:$pid}}')
    RESPONSE=$(agent_command "$REQUEST")
    printf '%s' "$RESPONSE" | jq -e '.return | has("exited")' >/dev/null || {
        echo "Error: Unable to query guest execution: $RESPONSE" >&2
        exit 1
    }
    if [ "$(printf '%s' "$RESPONSE" | jq -r '.return.exited')" = true ]; then
        printf '%s' "$RESPONSE" | jq -r '.return | (."out-data" // ""), (."err-data" // "") | @base64d'
        if [ "$(printf '%s' "$RESPONSE" | jq -r '.return.exitcode')" != 0 ]; then
            echo 'Error: Guest SSH update failed. Root password was already reset.' >&2
            exit 1
        fi
        exit 0
    fi
    sleep 1
done
echo "Error: Guest command $PID is still running; SSH outcome is unknown. Root password was already reset." >&2
exit 1
