#!/bin/bash

# --- Configuration ---
PROJECTS=("vdi" "WS1" "WS2")
USERS=("admin (IAM)" "admin_cli") # Note: IAM is usually a display name/tag; using ID or Name
ROLE="admin"

echo "### Step 1: Project Creation Check ###"
for PROJ in "${PROJECTS[@]}"; do
    if openstack project show "$PROJ" >/dev/null 2>&1; then
        echo "Project '$PROJ' already exists. Stopping script to prevent conflicts."
        exit 1
    else
        echo "Creating project: $PROJ"
        openstack project create --domain default "$PROJ"
    fi
done

echo -e "\n### Step 2: User Assignment ###"
for PROJ in "${PROJECTS[@]}"; do
    for USERNAME in "${USERS[@]}"; do
        echo "Adding user '$USERNAME' to project '$PROJ' as '$ROLE'..."
        openstack role add --project "$PROJ" --user "$USERNAME" "$ROLE"
    done
done

echo -e "\n### Step 3: Create flavors ###"
openstack flavor create --vcpus 4 --ram 8192 --disk 120 --property hw:cpu_cores=4 --public vdi-client
openstack flavor create --vcpus 8 --ram 8192 --disk 40 --property hw:cpu_cores=8 --public vdi-broker
openstack flavor create --vcpus 8 --ram 8192 --disk 40 --property hw:cpu_cores=8 --public vdi-gateway

echo -e "\n### Step 4: Setting Unlimited Quotas (-1) ###"
for PROJ in "${PROJECTS[@]}"; do
    echo "Updating quotas for $PROJ..."
    
    openstack quota set --force --cores -1 --instances -1 --ram -1 --secgroups -1 "$PROJ"
    
    openstack quota set --force --volumes -1 --snapshots -1 --gigabytes -1 --backups -1 --backup-gigabytes -1 --per-volume-gigabytes -1 "$PROJ"

    openstack quota set --force --networks -1 --subnets -1 --ports -1 --router -1 --floating-ip 50 "$PROJ"
done

echo -e "\n### Step 5: Network and Subnet Creation (Project: vdi) ###"
# Create Network
openstack network create --project vdi vdi-network
# Create Subnet
openstack subnet create --project vdi --network vdi-network \
    --subnet-range 192.168.10.0/24 --gateway 192.168.10.254 \
    --dns-nameserver 8.8.8.8 vdi-subnet

# Share network (RBAC) to WS1 and WS2
for TARGET_PROJ in "WS1" "WS2"; do
    TARGET_ID=$(openstack project show -f value -c id "$TARGET_PROJ")
    echo "Sharing vdi-network with $TARGET_PROJ ($TARGET_ID)..."
    openstack network rbac create --target-project "$TARGET_ID" --action access_as_shared --type network vdi-network
done

echo -e "\n### Step 6: External Router Setup ###"
# List external networks
MAPFILE=()
while IFS= read -r line; do MAPFILE+=("$line"); done < <(openstack network list --external -f value -c Name)

EXT_NET_COUNT=${#MAPFILE[@]}

if [ "$EXT_NET_COUNT" -eq 0 ]; then
    echo "Error: No external networks found."
    exit 1
elif [ "$EXT_NET_COUNT" -eq 1 ]; then
    SELECTED_EXT_NET="${MAPFILE[0]}"
    echo "Automatically selected only external network: $SELECTED_EXT_NET"
else
    echo "Multiple external networks found. Please select one:"
    for i in "${!MAPFILE[@]}"; do
        echo "$((i+1))) ${MAPFILE[$i]}"
    done
    read -p "Enter number (1-$EXT_NET_COUNT): " CHOICE
    SELECTED_EXT_NET="${MAPFILE[$((CHOICE-1))]}"
fi

# Create Router and Link
echo "Creating router 'vdi-router' on project vdi..."
openstack router create --project vdi vdi-router
openstack router set --external-gateway "$SELECTED_EXT_NET" vdi-router
openstack router add subnet vdi-router vdi-subnet

# Create Floating IPs
echo "Creating floating 2x IP on project vdi..."
openstack floating ip create --project vdi "$SELECTED_EXT_NET"
openstack floating ip create --project vdi "$SELECTED_EXT_NET"

echo -e "\n### Step 7: Security Groups ###"
for PROJ in "${PROJECTS[@]}"; do
    echo "Configuring Security Groups for project: $PROJ"
    
    # SG1: vdi-server
    openstack security group create --project "$PROJ" vdi-server
    openstack security group rule create --protocol tcp --dst-port 20001:23000 --remote-ip 0.0.0.0/0 vdi-server
    openstack security group rule create --protocol tcp --dst-port 80 --remote-ip 0.0.0.0/0 vdi-server
    openstack security group rule create --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0 vdi-server
    
    # SG2: vdi-client
    openstack security group create --project "$PROJ" vdi-client
    openstack security group rule create --protocol tcp --dst-port 8080 --remote-ip 0.0.0.0/0 vdi-client
    openstack security group rule create --protocol tcp --dst-port 3389 --remote-ip 0.0.0.0/0 vdi-client
done

echo -e "\n### Setup Complete ###"