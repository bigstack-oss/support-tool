#!/bin/bash

# enable MIG mode
nvidia-smi -i 0 -mig 1

# virtualize GPU 0
lspci -nn | grep -i nvidia | while read -r line; do
    pci_id=$(echo "$line" | awk '{print $1}')
    /usr/lib/nvidia/sriov-manage -e "0000:$pci_id"
done

# create 4 MIG devices with 35g profile
nvidia-smi mig -i 0 -cgi 15,15,15,15 -C

# set vGPU type to 1431 for all 4 MIG devices
for vf in 0000:82:00.2 0000:82:00.3 0000:82:00.4 0000:82:00.5; 
    do echo 1431 > /sys/bus/pci/devices/$vf/nvidia/current_vgpu_type; 
done
for vf in 0000:82:00.2 0000:82:00.3 0000:82:00.4 0000:82:00.5; 
    do echo "== $vf =="; cat /sys/bus/pci/devices/$vf/nvidia/current_vgpu_type; 
done

# show MIG devices
nvidia-smi -L

# restart nova
cubectl node -r compute exec -p hex_config restart_nova

# check nova profile devices
mysql nova -e "SELECT address,status,deleted FROM pci_devices WHERE deleted=0 ORDER BY address;"
