#!/bin/bash
# Show Ceph OSD df filtered by hostnames

# Function to print OSDs for a given hostname
print_osd_by_host() {
    local host="$1"
    echo "$host"

    # Get OSD IDs for the host
    osd_ids=$(ceph osd tree -f json | jq -r --arg host "$host" '.nodes[] | select(.name==$host) | .children[]?')

    if [ -z "$osd_ids" ]; then
        echo "  No OSDs found for $host"
        return
    fi

    # Filter ceph osd df by OSD IDs
    ceph osd df | awk -v ids="$osd_ids" '
        BEGIN { split(ids, a, " "); for (i in a) osd[a[i]]=1 }
        NR==1 || ( $1 in osd ) { print }'
    echo
}

# Main logic
if [ -n "$1" ]; then
    # User provided a hostname
    print_osd_by_host "$1"
else
    # No hostname input, iterate over all compute hosts
    hosts=$(cubectl node list -r compute | awk -F',' '{print $1}')
    for host in $hosts; do
        print_osd_by_host "$host"
    done
fi