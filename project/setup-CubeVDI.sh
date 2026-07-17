#!/bin/bash
EXTERNAL_NETWORK="$1"
PROJECTS=("VDI" "WS1" "WS2")

# Ensure external network was passed as an argument
if [ -z "$1" ]; then
    echo "Error: Missing external network name argument."
    echo "Usage: $0 <external_network_name>"
    exit 1
fi

# =====================================================================
# STEPS 1: Dynamic User ID Fetching & Project/Role Setup
# =====================================================================
echo "Fetching User IDs from OpenStack..."

USER_IAM_ID=$(openstack user show "admin (IAM)" -f value -c id)
USER_ADMIN_ID=$(openstack user show "admin" -f value -c id)
USER_CLI_ID=$(openstack user show "admin_cli" -f value -c id)

# Verify we found all the users before proceeding
if [ -z "$USER_IAM_ID" ] || [ -z "$USER_ADMIN_ID" ] || [ -z "$USER_CLI_ID" ]; then
    echo "Error: One or more admin users could not be found by name."
    echo "Found IAM: '$USER_IAM_ID', Admin: '$USER_ADMIN_ID', CLI: '$USER_CLI_ID'"
    exit 1
fi

USERS=("$USER_IAM_ID" "$USER_ADMIN_ID" "$USER_CLI_ID")

for proj in "${PROJECTS[@]}"; do
    echo "Creating project: $proj"
    openstack project create --domain default "$proj"
    openstack quota set --cores -1 --ram -1 --instances -1 --volumes -1 --gigabytes -1 --key-pairs -1 "$proj"
    
    for user in "${USERS[@]}"; do
        echo "Assigning admin role to user ID '$user' on project '$proj'..."
        openstack role add --project "$proj" --user "$user" admin
    done
done

# =====================================================================
# STEP 2: Network, Subnet, and Router Setup
# =====================================================================
echo "Creating shared network and subnet on project VDI..."

# Create the internal shared network
openstack network create --project VDI --share vdi-network

# Create the subnet
openstack subnet create --project VDI \
  --network vdi-network \
  --subnet-range 192.168.20.0/24 \
  --gateway 192.168.20.254 \
  --dns-nameserver 8.8.8.8 \
  vdi-subnet

echo "Creating router and linking it to external network '$EXTERNAL_NETWORK'..."

# 1. Create the router inside the VDI project
openstack router create --project VDI vdi-router

# 2. Set the external network as the router's gateway
openstack router set --external-gateway "$EXTERNAL_NETWORK" vdi-router

# 3. Add the internal vdi-subnet interface to the router
openstack router add subnet vdi-router vdi-subnet

# =====================================================================
# STEPS 3: Security Group Rules
# =====================================================================
for proj in "${PROJECTS[@]}"; do
    echo "Configuring Security Group 'vdi-client' for project $proj..."
    openstack security group create --project "$proj" vdi-client
    openstack security group rule create --project "$proj" --protocol icmp --remote-ip 0.0.0.0/0 vdi-client 2>/dev/null || true
    openstack security group rule create --project "$proj" --protocol tcp --dst-port 3389 --remote-ip 0.0.0.0/0 vdi-client 2>/dev/null || true
    openstack security group rule create --project "$proj" --protocol tcp --dst-port 8080 --remote-ip 0.0.0.0/0 vdi-client 2>/dev/null || true
    openstack security group create --project "$proj" vdi-server
    openstack security group rule create --project "$proj" --protocol icmp --remote-ip 0.0.0.0/0 vdi-server 2>/dev/null || true
    openstack security group rule create --project "$proj" --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0 vdi-server 2>/dev/null || true
    openstack security group rule create --project "$proj" --protocol tcp --dst-port 80 --remote-ip 0.0.0.0/0 vdi-server 2>/dev/null || true
    openstack security group rule create --project "$proj" --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0 vdi-server 2>/dev/null || true
    openstack security group rule create --project "$proj" --protocol tcp --dst-port 20001:23000 --remote-ip 0.0.0.0/0 vdi-server 2>/dev/null || true
done

echo "All OpenStack configurations completed successfully!"