#!/usr/bin/env bash

set -u

SERVICES=(
    "tun1-watcher.service"
    "vpn-manager.service"
)

OPTIMIZER="/opt/router/vpn-optimizer/vpn-optimizer.sh"

restore_services()
{
    echo "[INFO] Restoring background services"

    for service in "${SERVICES[@]}"; do

        echo "[INFO] Starting $service"

        if systemctl start "$service"; then
            echo "[INFO] $service started successfully"
        else
            echo "[ERROR] Failed to start $service"
        fi

    done
}

trap restore_services EXIT


echo "[INFO] Stopping background VPN services"

for service in "${SERVICES[@]}"; do

    echo "[INFO] Stopping $service"

    if systemctl stop "$service"; then
        echo "[INFO] $service stopped successfully"
    else
        echo "[ERROR] Failed to stop $service"
        exit 1
    fi

done


echo "[INFO] Waiting for services to settle"
sleep 2


echo "[INFO] Starting VPN Optimizer for both interfaces"

if ! "$OPTIMIZER" both; then
    echo "[ERROR] VPN optimization failed"
    exit 1
fi


echo "[INFO] Daily VPN optimization completed successfully"

exit 0