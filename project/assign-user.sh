#!/usr/bin/env bash
set -euo pipefail

USER_NAME='admin (IAM)'
ROLE_NAME='admin'
# If you want to exclude multiple project names, separate them with commas (e.g., EXCLUDE_NAMES='service,admin')
EXCLUDE_NAMES='service'

echo "Fetching user ID ..."
USER_ID="$(openstack user show "$USER_NAME" -f value -c id)"

# Optional: also resolve role ID (if role exists by name)
ROLE_ID="$(openstack role show "$ROLE_NAME" -f value -c id 2>/dev/null || true)"
ROLE_ARG="${ROLE_ID:-$ROLE_NAME}"

# Convert exclude list to array
IFS=',' read -r -a EXCLUDES <<<"$EXCLUDE_NAMES"

echo "Listing projects and excluding: ${EXCLUDES[*]} ..."
PROJECT_JSON="$(openstack project list -f json)"

# Filter out projects with names in the exclude list
mapfile -t PROJECT_IDS < <(
  jq -r --argjson excludes "$(printf '%s\n' "${EXCLUDES[@]}" | jq -R . | jq -s .)" '
    .[] | select(.Name as $n | ($excludes | index($n)) | not) | .ID
  ' <<<"$PROJECT_JSON"
)

echo "Assigning user '$USER_NAME' with role '$ROLE_NAME' on all selected projects ..."
for PID in "${PROJECT_IDS[@]}"; do
  # Check if the role is already assigned (skip if yes)
  if openstack role assignment list \
        --user "$USER_ID" \
        --project "$PID" \
        --role "$ROLE_ARG" \
        -f json | jq -e 'length>0' >/dev/null; then
    echo "Skipping (already assigned): project=$PID"
    continue
  fi

  # Assign the role (using role ID if available, otherwise name)
  openstack role add --user "$USER_ID" --project "$PID" "$ROLE_ARG"
  echo "Assigned: user='$USER_NAME' project=$PID role='$ROLE_NAME'"
done

echo "Done."