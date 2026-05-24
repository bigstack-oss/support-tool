#!/bin/bash
sudo cloud-init clean --logs --seed
sudo truncate -s 0 /etc/machine-id
sudo rm /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo rm /etc/ssh/ssh_host_*
sudo rm -rf /home/ubuntu/.ssh/authorized_keys
sudo rm -f /etc/netplan/*.yaml
# Clear logs
sudo find /var/log -type f -exec truncate -s 0 {} \;
# Clear bash history
rm /home/ubuntu/self-sysprep.sh
history -c && history -w
sudo sync
sudo poweroff