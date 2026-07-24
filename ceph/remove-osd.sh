#!/bin/bash

# 1. Get IDs of all OSDs with STATUS = down
down_osds=($(ceph osd df | awk '$NF=="down" {print $1}'))

# Check if any down OSDs were found
if [ ${#down_osds[@]} -eq 0 ]; then
    echo "No 'down' OSDs found in the cluster."
    exit 0
fi

echo "=========================================="
echo " Found 'down' OSDs:"
echo "=========================================="

# 2. Display available options
for i in "${!down_osds[@]}"; do
    echo " [$((i+1))] OSD ID: ${down_osds[$i]}"
done
echo " [A] All 'down' OSDs (${down_osds[*]})"
echo " [Q] Quit without changes"
echo "=========================================="

# 3. Prompt user for selection
read -p "Select an option to purge (e.g., 1, A, or Q): " choice

selected_osds=()

case "$choice" in
    [aA])
        selected_osds=("${down_osds[@]}")
        ;;
    [qQ])
        echo "Aborted."
        exit 0
        ;;
    *)
        # Verify if numeric choice is valid
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#down_osds[@]}" ]; then
            selected_osds=("${down_osds[$((choice-1))]}")
        else
            echo "Invalid selection. Exiting."
            exit 1
        fi
        ;;
esac

echo ""
echo "Selected OSDs for removal: ${selected_osds[*]}"
read -p "Are you sure you want to proceed? (y/N): " confirm

if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

# 4. Perform purging and cleanup loop
for osd_id in "${selected_osds[@]}"; do
    echo "------------------------------------------"
    echo "Processing OSD $osd_id..."
    
    # Try purging first (Modern Ceph)
    echo "Running purge for OSD $osd_id..."
    if ! ceph osd purge "$osd_id" --yes-i-really-mean-it; then
        echo "Purge command failed or unsupported. Running manual steps..."
        ceph osd crush remove "osd.$osd_id"
        ceph auth del "osd.$osd_id"
        ceph osd rm "$osd_id"
    fi
    
    echo "OSD $osd_id cleanup complete."
done

echo "------------------------------------------"
echo "All actions completed!"