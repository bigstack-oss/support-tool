#!/bin/bash

# Load OpenStack environment
source /etc/admin-openrc.sh

# Get list of projects
projects=$(openstack project list -f value -c ID -c Name)

# Convert to array
IFS=$'\n' read -d '' -r -a project_array <<< "$projects"

echo "Select a project:"
for i in "${!project_array[@]}"; do
    pid=$(echo "${project_array[$i]}" | awk '{print $1}')
    pname=$(echo "${project_array[$i]}" | cut -d' ' -f2-)
    echo "$((i+1)). $pid ($pname)"
done

read -p "Enter project number: " project_index
project_index=$((project_index-1))

selected_project_line="${project_array[$project_index]}"
project_id=$(echo "$selected_project_line" | awk '{print $1}')
project_name=$(echo "$selected_project_line" | awk '{print $2}')

echo "Selected project name: $project_name"

# Get volumes for selected project
volumes=$(openstack volume list --project "$project_id" -f value -c ID -c Name)

IFS=$'\n' read -d '' -r -a volume_array <<< "$volumes"

echo "Select a volume:"
for i in "${!volume_array[@]}"; do
    vid=$(echo "${volume_array[$i]}" | awk '{print $1}')
    vname=$(echo "${volume_array[$i]}" | cut -d' ' -f2-)
    echo "$((i+1)). $vid ($vname)"
done

read -p "Enter volume number: " volume_index
volume_index=$((volume_index-1))

selected_volume_line="${volume_array[$volume_index]}"
volume_name=$(echo "$selected_volume_line" | cut -d' ' -f2-)
volume_id=$(echo "$selected_volume_line" | awk '{print $1}')

echo "Selected volume name: $volume_name"

# os type selection
echo "Select os type:"
echo "1. windows"
echo "2. linux"
read -p "Enter option number: " os_type_option

case $os_type_option in
    1) os_type="windows" ;;
    2) os_type="linux" ;;
    *) echo "Invalid option"; exit 1 ;;
esac

echo "Selected os type: $os_type"

# Boot mode selection
echo "Select boot mode:"
echo "1. legacy"
echo "2. UEFI"
read -p "Enter option number: " boot_mode_option

case $boot_mode_option in
    1) boot_mode="legacy" ;;
    2) boot_mode="UEFI" ;;
    *) echo "Invalid option"; exit 1 ;;
esac

echo "Selected boot mode: $boot_mode"

# Disk selection
echo "Select disk type:"
echo "1. sata"
echo "2. scsi"
echo "3. virtio"
read -p "Enter option number: " disk_type_option

case $disk_type_option in
    1) disk_type="sata" ;;
    2) disk_type="scsi" ;;
    3) disk_type="virtio" ;;
    *) echo "Invalid option"; exit 1 ;;
esac

echo "Selected disk driver: $disk_type"

# Network card selection
echo "Select network type:"
echo "1. rtl8139"
echo "2. e1000"
echo "3. virtio"
read -p "Enter option number: " network_type_option

case $network_type_option in
    1) network_type="rtl8139" ;;
    2) network_type="e1000" ;;
    3) network_type="virtio" ;;
    *) echo "Invalid option"; exit 1 ;;
esac

echo "Selected network driver: $network_type"

# Get all keys from volume_image_metadata
keys=$(openstack volume show "$volume_id" -f json | jq -r '.volume_image_metadata | keys[]')

# Loop through each key and unset it
echo "Reset volume: $volume_name..."
for key in $keys; do
    cinder image-metadata "$volume_id" unset "$key"
done
cinder image-metadata $volume_id set disk_format=raw
cinder image-metadata $volume_id set hw_qemu_guest_agent=True
cinder image-metadata $volume_id set hw_video_model=vga
cinder image-metadata $volume_id set os_type=$os_type

# Set image metadata if boot mode is UEFI
if [[ "$boot_mode" == "UEFI" ]]; then
    echo "Setting UEFI on volume: $volume_name..."
    cinder image-metadata $volume_id set hw_firmware_type=uefi
    cinder image-metadata $volume_id set hw_machine_type=q35
    cinder image-metadata $volume_id set os_secure_boot=optional
fi

# Set image metadata if boot mode is legacy
if [[ "$boot_mode" == "legacy" ]]; then
    echo "Setting legacy on volume: $volume_name..."
fi
# Set image metadata if boot mode is default
if [[ "$disk_type" == "sata" ]]; then
    echo "Setting sata disk on volume: $volume_name..."
    cinder image-metadata $volume_id set hw_disk_bus=sata
fi

if [[ "$disk_type" == "scsi" ]]; then
    echo "Setting scsi disk on volume: $volume_name..."
    cinder image-metadata $volume_id set hw_disk_bus=scsi
    cinder image-metadata $volume_id set hw_scsi_model=virtio-scsi
fi
if [[ "$disk_type" == "virtio" ]]; then
    echo "Setting virtio disk on volume: $volume_name..."
    cinder image-metadata $volume_id set hw_disk_bus=virtio
    cinder image-metadata $volume_id set hw_scsi_model=virtio-scsi
fi
echo "Setting network type on volume: $volume_name..."
cinder image-metadata $volume_id set hw_vif_model=$network_type

openstack volume show $volume_id -f json | jq '.volume_image_metadata'
