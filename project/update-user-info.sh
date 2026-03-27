#!/bin/sh
USERS=(admin_cli skyline monasca barbican heat octavia masakari watcher designate neutron cinder heat_domain_admin nova placement cyborg manila glance ironic ironic-inspector senlin)

EXTRA_JSON='{"email": "info@bigstack.co", "phone": "+886 227127199", "real_name": "CubeCOS Service account", "description": "Do not change"}'

for user in "${USERS[@]}"; do
    # Get the ID (suppressing errors if a user doesn't exist)
    USER_ID=$(openstack user show "$user" -c id -f value 2>/dev/null)
    
    if [ -n "$USER_ID" ]; then
        echo "-- Updating user $user (ID: $USER_ID)"
        mysql -u root keystone -e "UPDATE user SET extra='$EXTRA_JSON' WHERE id='$USER_ID';"
    else
        echo "-- User $user not found, skipping."
    fi
done

HORIZON_USER="admin"
HORIZON_USER_ID=$(openstack user show $HORIZON_USER -c id -f value 2>/dev/null)
EXTRA_JSON='{"real_name": "Admin (Local)", "description": "Default local admin user"}'
if [ -n "$HORIZON_USER_ID" ]; then
    echo "-- Updating user $HORIZON_USER (ID: $HORIZON_USER_ID)"
    mysql -u root keystone -e "UPDATE user SET extra='$EXTRA_JSON' WHERE id='$HORIZON_USER_ID';"
fi

KEYCLOAK_USER="admin (IAM)"
KEYCLOAK_USER_ID=$(openstack user show "${KEYCLOAK_USER}" -c id -f value 2>/dev/null)
EXTRA_JSON='{"real_name": "Admin (Keycloak)", "description": "Default SSO admin user"}'
if [ -n "$KEYCLOAK_USER_ID" ]; then
    echo "-- Updating user $KEYCLOAK_USER (ID: $KEYCLOAK_USER_ID)"
    mysql -u root keystone -e "UPDATE user SET extra='$EXTRA_JSON' WHERE id='$KEYCLOAK_USER_ID';"
fi