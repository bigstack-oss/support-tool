#!/bin/sh
cubectl node -r control exec -p rm -rf /var/lib/rabbitmq/mnesia/*
cubectl node -r control exec -p rm -f /etc/appliance/state/rabbitmq_cluster_done
mapfile -t NODES < <(cubectl node list -r control | awk -F',' '{print $1}')

for node in "${NODES[@]}"; do
    ssh ${node} systemctl stop rabbitmq-server
done

for node in "${NODES[@]}"; do
    ssh ${node} hex_config restart_rabbitmq
done

hex_cli -c cluster check_repair