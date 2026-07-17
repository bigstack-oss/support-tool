#!/bin/bash

TEMP_FILE=$(mktemp)

# Headers
echo -e "uuid\tname\ttrait" > "$TEMP_FILE"

# Gather data
openstack resource provider list -f value -c uuid -c name | while read -r uuid name; do
    trait=$(openstack resource provider trait list "$uuid" -f value | grep "CUSTOM_GPU_PRODUCT_ID_")
    if [ -n "$trait" ]; then
        echo -e "${uuid}\t${name}\t${trait}" >> "$TEMP_FILE"
    fi
done

# Format using awk with removed middle dividers
awk -F'\t' '
NR==1 {
    h1=$1; h2=$2; h3=$3
}
NR>1 {
    u[NR]=$1; n[NR]=$2; t[NR]=$3
}
END {
    w1 = length(h1); w2 = length(h2); w3 = length(t[1] ? t[1] : h3)
    for (i=2; i<=NR; i++) {
        if (length(u[i]) > w1) w1 = length(u[i])
        if (length(n[i]) > w2) w2 = length(n[i])
        if (length(t[i]) > w3) w3 = length(t[i])
    }
    
    border = "+" sprintf("%*s", w1+2, "") "+" sprintf("%*s", w2+2, "") "+" sprintf("%*s", w3+2, "") "+"
    gsub(/ /, "-", border)
    
    # Top border and Header
    print border
    printf "| %-*s | %-*s | %-*s |\n", w1, h1, w2, h2, w3, h3
    print border
    
    # Rows (No dividers between data rows)
    for (i=2; i<=NR; i++) {
        if (u[i] != "") {
            printf "| %-*s | %-*s | %-*s |\n", w1, u[i], w2, n[i], w3, t[i]
        }
    }
    
    # Bottom border
    print border
}' "$TEMP_FILE"

rm -f "$TEMP_FILE"