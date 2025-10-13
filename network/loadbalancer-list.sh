#!/bin/bash
source /etc/admin-openrc.sh
# Step 1: Fetch OpenStack projects
echo "Fetching OpenStack projects..."
projects=$(openstack project list -f json) || echo "Failed to fetch projects."
project_ids=($(echo "$projects" | jq -r '.[].ID'))
project_names=($(echo "$projects" | jq -r '.[].Name'))

if [ ${#project_ids[@]} -eq 0 ]; then
    echo "No projects found."
fi

# Display project list
echo "Available Projects:"
for i in "${!project_ids[@]}"; do
    echo "$((i + 1)). ${project_names[$i]} - ${project_ids[$i]}"
done

# User selects a project
read -p "Select a project by number: " selection
selected_index=$((selection - 1))

if [ -z "${project_ids[$selected_index]}" ]; then
    echo "Invalid selection."
fi

selected_project_id="${project_ids[$selected_index]}"
selected_project_name="${project_names[$selected_index]}"


# Step 2: Fetch Load Balancers for the selected project
echo "Fetching Load Balancers for project: $selected_project_name..."
loadbalancers=$(openstack loadbalancer list --project "$selected_project_id" -f json) || echo "Failed to fetch load balancers."

lb_ids=($(echo "$loadbalancers" | jq -r '.[].id'))
lb_names=($(echo "$loadbalancers" | jq -r '.[].name'))
lb_vips=($(echo "$loadbalancers" | jq -r '.[].vip_address'))

if [ ${#lb_ids[@]} -eq 0 ]; then
    echo "No load balancers found for this project."
    exit 0
fi

# Step 3: Fetch Amphora Data
amphora_data=$(openstack loadbalancer amphora list --long -c loadbalancer_id -c lb_network_ip -c compute_id -f json) || echo "Failed to fetch amphora data."

# Step 4: Loop through the load balancers and display details
for i in "${!lb_ids[@]}"; do
    lb_id="${lb_ids[$i]}"
    lb_name="${lb_names[$i]}"
    lb_vip="${lb_vips[$i]}"

    amphora_entry=$(echo "$amphora_data" | jq -r --arg lb_id "$lb_id" '.[] | select(.loadbalancer_id == $lb_id)')
    lb_network_ip=$(echo "$amphora_entry" | jq -r '.lb_network_ip')
    compute_id=$(echo "$amphora_entry" | jq -r '.compute_id')

    # LB data
    loadbalancer_data=$(openstack loadbalancer show "$lb_id" -c project_id -c name -c provisioning_status -c vip_port_id -f value)
    loadbalancer_name=$(echo "$loadbalancer_data" | awk 'NR==1')
    project_id=$(echo "$loadbalancer_data" | awk 'NR==2')
    provisioning_status=$(echo "$loadbalancer_data" | awk 'NR==3')
    loadbalancer_vip_port_id=$(echo "$loadbalancer_data" | awk 'NR==4')

    # VM data
    if [ -n "$compute_id" ]; then
        vm_data=$(   "$compute_id" -c name -c image -c created -f value)
        vm_create_date=$(echo "$vm_data" | awk 'NR==1')
        glance_image=$(echo "$vm_data" | awk 'NR==2')
        compute_name=$(echo "$vm_data" | awk 'NR==3')
    else
        vm_create_date="N/A"
        glance_image="N/A"
        compute_name="N/A"
    fi

    # Get floating VIP
    loadbalancer_vip=$(openstack floating ip list --port "$loadbalancer_vip_port_id" -c "Floating IP Address" -f value)
    if [ -z "$loadbalancer_vip" ]; then
        loadbalancer_vip="N/A"
    fi

    # Print the result with number indexing
    echo "---------------------------------------------"
    echo "No: $((i + 1))"
    echo "Loadbalancer ID: $lb_id"
    echo "Loadbalancer Name: $lb_name"
    echo "Provision status: $provisioning_status"
    echo "Floating IP: $loadbalancer_vip"
    echo "IP Address: $lb_vip"
    echo "Admin VM name: $compute_name"
    echo "Admin VM ID: $compute_id"
    echo "Admin VM MGMT IP: $lb_network_ip"
    echo "Admin VM Image: $glance_image"
    echo "Admin VM create on: $vm_create_date"
    
done
    echo "---------------------------------------------"
exit 0