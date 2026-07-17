#!/bin/bash
nvidia-smi mig -dci
nvidia-smi mig -dgi
gpu_count=$(lspci -nn | grep -i nvidia | wc -l)
for ((i=0; i<gpu_count; i++)); do
    echo "Disable MIG on GPU $i..."
    nvidia-smi -i $i -mig 0
    echo "Enabling MIG on GPU $i..."
    nvidia-smi -i $i -mig 1
done

lspci -nn | grep -i nvidia | while read -r line; do
    pci_id=$(echo "$line" | awk '{print $1}')
    /usr/lib/nvidia/sriov-manage -d "0000:$pci_id"
    /usr/lib/nvidia/sriov-manage -e "0000:$pci_id"
done