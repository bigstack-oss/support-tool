#!/bin/bash
source /etc/admin-openrc.sh

# Get the load balancer ID (argument 1)
loadbalancer_id="$1"

if [ -z "$loadbalancer_id" ]; then
    echo "Usage: $0 <loadbalancer_id>"
    exit 1
fi

# Fetch amphora data
amphora_data=$(openstack loadbalancer amphora list --long -c loadbalancer_id -c lb_network_ip -c compute_id -f value | grep -w "$loadbalancer_id")
lb_network_ip=$(echo "$amphora_data" | awk '{print $2}')
compute_id=$(echo "$amphora_data" | awk '{print $3}')

# Check if amphora data is found
if [ -z "$lb_network_ip" ] || [ -z "$compute_id" ]; then
    echo "Amphora data not found for Loadbalancer ID: $loadbalancer_id"
    exit 1
fi

# LB data
loadbalancer_data=$(openstack loadbalancer show "$loadbalancer_id" -c project_id -c name -c provisioning_status -c vip_port_id -f value)
loadbalancer_name=$(echo "$loadbalancer_data" | awk 'NR==1')
project_id=$(echo "$loadbalancer_data" | awk 'NR==2')
provisioning_status=$(echo "$loadbalancer_data" | awk 'NR==3')
loadbalancer_vip_port_id=$(echo "$loadbalancer_data" | awk 'NR==4')

# Get the project name, default to "unknown" if not found
project_name=$(openstack project show "$project_id" -c name -f value)
if [ -z "$project_name" ]; then
    project_name="unknown"
    state="(PROJECT DELETED)"
else
    state=""
fi

# VM data
vm_data=$(openstack server show "$compute_id" -c name -c image -c created -f value)
vm_create_date=$(echo "$vm_data" | awk 'NR==1')
glance_image=$(echo "$vm_data" | awk 'NR==2')
compute_name=$(echo "$vm_data" | awk 'NR==3')

if [ -z "$compute_name" ]; then
    compute_name="N/A"
    glance_image="N/A"
    vm_create_date="N/A"
fi

# Get floating VIP
loadbalancer_vip=$(openstack floating ip list --port "$loadbalancer_vip_port_id" -c "Floating IP Address" -f value)
if [ -z "$loadbalancer_vip" ]; then
    loadbalancer_vip="N/A"
fi

# Print the result
echo "---------------------------------------------"
echo "Loadbalancer ID: $loadbalancer_id"
echo "Loadbalancer Name: $loadbalancer_name"
echo "Project: $state $project_name ($project_id)"
echo "Provision status: $provisioning_status"
echo "Admin VM name: $compute_name"
echo "Admin VM ID: $compute_id"
echo "Admin VM Image: $glance_image"
echo "Admin VM create on: $vm_create_date"
echo "lb-mgmt-net IP: $lb_network_ip"
echo "Floating IP: $loadbalancer_vip"
echo "---------------------------------------------"
exit 0