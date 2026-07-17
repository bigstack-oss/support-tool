#!/bin/bash

# Define formatting for a clean output table
printf "%-45s | %-15s | %-12s\n" "vGPU Profile Name" "Profile ID" "FB Memory"
printf "%s\n" "--------------------------------------------------------------------------------"

# Fetch, parse, and format the nvidia-smi vgpu output block by block
nvidia-smi vgpu -i 0 -s -v | awk '
    /Name/ {
        name=$0; 
        sub(/^[ \t]*Name[ \t]*:[ \t]*/, "", name);
    }
    /GPU Instance Profile ID/ {
        id=$0; 
        sub(/^[ \t]*GPU Instance Profile ID[ \t]*:[ \t]*/, "", id);
    }
    /FB Memory/ {
        fb=$0; 
        sub(/^[ \t]*FB Memory[ \t]*:[ \t]*/, "", fb);
        printf "%-45s | %-15s | %-12s\n", name, id, fb;
    }
'