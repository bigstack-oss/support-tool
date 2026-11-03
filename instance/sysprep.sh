#!/usr/bin/env bash
# path: /usr/local/bin/sysprep
# Clean this VM for golden-image capture, then power off.
set -Eeuo pipefail

USER_TO_CLEAN="ubuntu"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

# authorized_keys are deleted and the password locked, so login on the next boot depends on cloud-init key injection
if ! command -v cloud-init >/dev/null 2>&1; then
    echo "ERROR: cloud-init not installed; the image would have no way to inject SSH keys." >&2
    exit 1
fi

echo "This will clean this VM for imaging and power it off. Ensure OpenStack key injection works."
read -r -p 'Type YES to continue: ' confirmation
if [[ "${confirmation}" != "YES" ]]; then
    echo "Cancelled."
    exit 1
fi

echo "==> Locking existing password for ${USER_TO_CLEAN}"
if id "${USER_TO_CLEAN}" >/dev/null 2>&1; then
    passwd -l "${USER_TO_CLEAN}" || true
fi

echo "==> Cleaning cloud-init state and machine-id"
if cloud-init clean --help 2>&1 | grep -q -- '--machine-id'; then
    cloud-init clean --logs --machine-id --seed
else
    # Older cloud-init versions
    cloud-init clean --logs --seed
    truncate -s 0 /etc/machine-id
    rm -f /var/lib/dbus/machine-id
fi

echo "==> Removing SSH host keys and authorized_keys"
rm -f /etc/ssh/ssh_host_*
find /root /home -type f -path '*/.ssh/authorized_keys' -delete

echo "==> Clearing shell histories"
find /root /home -type f \( -name .bash_history -o -name .zsh_history \) \
    -exec truncate -s 0 {} +

echo "==> Cleaning temporary files"
rm -rf /tmp/* /var/tmp/*

echo "==> Cleaning package cache"
if command -v apt-get >/dev/null 2>&1; then
    apt-get clean
fi

echo "==> Cleaning machine-specific DHCP leases"
rm -f /var/lib/dhcp/*.leases /var/lib/NetworkManager/*.lease 2>/dev/null || true

echo "==> Cleaning systemd journal and logs"
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true

sync
echo "==> Sysprep complete. Powering off; capture this VM as an image afterwards."
poweroff
