#!/bin/bash
source /etc/admin-openrc.sh
set -euo pipefail

LOGFILE="/var/log/support-vm-volume-usage.log"
RBD_POOL="cinder-volumes"
EPHEMERAL_POOL="ephemeral-vms"

#-----------------------------------------
# Helpers
#-----------------------------------------
log() {
    echo "$@" | tee -a "$LOGFILE"
}

: > "$LOGFILE"

log "=============================================================================================="
log " Volume Usage Report"
log " Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
log " Cinder pool   : ${RBD_POOL}"
log " Ephemeral pool: ${EPHEMERAL_POOL}"
log "=============================================================================================="

#-----------------------------------------
# Domains (exclude heat)
#-----------------------------------------
openstack domain list -f json \
| jq -c '.[] | select(.Name!="heat")' \
| while read -r domain; do
    domain_id=$(jq -r '.ID'   <<<"$domain")
    domain_name=$(jq -r '.Name' <<<"$domain")

    project_json=$(openstack project list --domain "$domain_id" -f json)

    if [[ $(jq 'length' <<<"$project_json") -gt 0 ]]; then
        log " Domain : ${domain_id} (${domain_name})"
    fi

    #-----------------------------------------
    # Projects (exclude service)
    #-----------------------------------------
    jq -c '.[] | select(.Name!="service")' <<<"$project_json" | while read -r project; do
        project_id=$(jq -r '.ID'   <<<"$project")
        project_name=$(jq -r '.Name' <<<"$project")

        log "=============================================================================================="
        log " Virtual Machines"
        log " Project: ${project_id} (${project_name})"
        log "=============================================================================================="
        log ""

        #-----------------------------------------
        # Servers
        #-----------------------------------------
        openstack server list --project "$project_id" -f json \
        | jq -c '.[]' \
        | while read -r server; do
            server_id=$(jq -r '.ID'     <<<"$server")
            server_name=$(jq -r '.Name' <<<"$server")
            # Older/newer CLIs may differ; prefer Status but fall back if needed
            server_status=$(jq -r '.Status // .status // "UNKNOWN"' <<<"$server")

            # Full server detail
            server_json=$(openstack server show "$server_id" -f json)

            # Handle all variants:
            # - "os-extended-volumes:volumes_attached"
            # - "attached_volumes"
            # - "volumes_attached" (older OpenStack)
            volume_ids=$(
                jq -r '
                  (."os-extended-volumes:volumes_attached"
                   // .attached_volumes
                   // .volumes_attached
                   // []) | map(.id) | .[]?
                ' <<<"$server_json"
            )

            vm_logged=0

            #-----------------------------------------
            # 1) Ephemeral disk first: ephemeral-vms/server_id_disk
            #-----------------------------------------
            ephemeral_image="${server_id}_disk"

            if rbd info "${EPHEMERAL_POOL}/${ephemeral_image}" &>/dev/null; then
                log "VM : ${server_id} (${server_name}, ${server_status})"
                vm_logged=1

                log "└── Volume: ${ephemeral_image}"

                if ! rbd du "${EPHEMERAL_POOL}/${ephemeral_image}" 2>&1 \
                    | sed 's/^/    /' \
                    | tee -a "$LOGFILE"; then
                    log "    (Error: rbd du failed for ${EPHEMERAL_POOL}/${ephemeral_image})"
                fi
            fi

            #-----------------------------------------
            # 2) Cinder volumes
            #-----------------------------------------
            if [[ -n "$volume_ids" ]]; then
                [[ $vm_logged -eq 0 ]] && {
                    log "VM : ${server_id} (${server_name}, ${server_status})"
                    vm_logged=1
                }

                while read -r vol_id; do
                    [[ -z "$vol_id" ]] && continue

                    vol_name=$(openstack volume show "$vol_id" \
                        -f value -c name 2>/dev/null || true)

                    # └── Volume: volume_name (fallback to volume_id)
                    if [[ -n "$vol_name" && "$vol_name" != "None" ]]; then
                        display="$vol_name"
                    else
                        display="$vol_id"
                    fi

                    log "└── Volume: ${display}"

                    if ! rbd du "${RBD_POOL}/volume-${vol_id}" 2>&1 \
                        | sed 's/^/    /' \
                        | tee -a "$LOGFILE"; then
                        log "    (Error: rbd du failed for ${RBD_POOL}/volume-${vol_id})"
                    fi
                done <<< "$volume_ids"
            fi

            [[ $vm_logged -eq 1 ]] && log ""
        done

        #-----------------------------------------
        # 3) Volumes for this project
        #-----------------------------------------
        volumes_json=$(openstack volume list --project "$project_id" -f json)
        if [[ $(jq 'length' <<<"$volumes_json") -gt 0 ]]; then
            log "=============================================================================================="
            log " Volumes not in-use"
            log "=============================================================================================="
            log ""
        fi

        jq -c '.[]' <<<"$volumes_json" | while read -r vol; do
            vol_id=$(jq -r '.ID'   <<<"$vol")
            vol_name=$(jq -r '.Name // ""' <<<"$vol")
            vol_status=$(jq -r '.Status // .status // "UNKNOWN"' <<<"$vol")

            # Only process volumes whose status is NOT "in-use"
            if [[ "$vol_status" == "in-use" ]]; then
                continue
            fi

            # Build display label:
            # └── Volume: volume_id (volume_name, volume_status)
            # If volume_name is empty, show just (volume_status)
            if [[ -n "$vol_name" && "$vol_name" != "None" ]]; then
                vol_label="${vol_id} (${vol_name}, ${vol_status})"
            else
                vol_label="${vol_id} (${vol_status})"
            fi

            # ---- NO Domain / Project here anymore ----
            log "└── Volume: ${vol_label}"

            rbd_image="volume-${vol_id}"

            # rbd du cinder-volumes/volume-VOLUME_ID with indented output
            if ! rbd du "${RBD_POOL}/${rbd_image}" 2>&1 \
                | sed 's/^/    /' \
                | tee -a "$LOGFILE"; then
                log "    (Error: rbd du failed for ${RBD_POOL}/${rbd_image})"
            fi

            log ""   # blank line between volumes
        done
        log "=============================================================================================="
        log " End - Project: ${project_id} (${project_name})"
        log "=============================================================================================="
        log ""
    done
done

log "Report finished at: $(date '+%Y-%m-%d %H:%M:%S')"