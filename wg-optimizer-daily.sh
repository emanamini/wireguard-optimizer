#!/usr/bin/env bash

set -u

CONFIG_FILE="/etc/wg-optimizer.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Configuration file does not exist: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

SERVICES=(
    "tun1-watcher.service"
    "vpn-manager.service"
)

OPTIMIZER="$BASE_DIR/wg-optimizer.sh"

restore_services()
{
    echo "[INFO] Restoring background WireGuard services"

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


MODE="${1:-both}"

if [[ "$MODE" != "tun0" && "$MODE" != "tun1" && "$MODE" != "both" ]]; then
    echo "[ERROR] Invalid mode: $MODE"
    echo "Usage: $0 {tun0|tun1|both}"
    exit 1
fi


echo "[INFO] Stopping background WireGuard services"

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


echo "[INFO] Starting WireGuard Optimizer for $MODE"

if ! "$OPTIMIZER" "$MODE"; then
    echo "[ERROR] WireGuard optimization failed"
    exit 1
fi


echo "[INFO] WireGuard optimization for $MODE completed successfully"

exit 0
