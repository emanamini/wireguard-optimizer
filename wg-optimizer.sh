#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Master Script
# ============================================================
#
# USAGE:
#
#   sudo ./wg-optimizer.sh tun0
#       Run optimizer for tun0.
#
#   sudo ./wg-optimizer.sh tun1
#       Run optimizer for tun1.
#
#   sudo ./wg-optimizer.sh both
#       Run optimizer for tun0 and tun1.
#
# WORKFLOW:
#
#   00-endpoint-route.sh
#       Runs once per optimizer invocation.
#
#   For each selected interface:
#
#       01-config-manager.sh
#       02-candidate-conflict-filter.sh
#       03-prepare-candidates.sh
#       04-test-candidates.sh
#       05-deploy-winner.sh
#       06-cleanup.sh
#
# ============================================================

set -u
set -o pipefail

# ============================================================
# Configuration
# ============================================================

SCRIPT_DIR="/opt/router/wg-optimizer/exec"

SLEEP_BETWEEN_SCRIPTS=2

CONFIG_FILE="/etc/wg-optimizer.conf"

# ============================================================
# Logging
# ============================================================

log_info()
{
    echo "[INFO] $*"
}

log_success()
{
    echo "[SUCCESS] $*"
}

log_error()
{
    echo "[ERROR] $*" >&2
}

# ============================================================
# Usage
# ============================================================

usage()
{
    echo
    echo "Usage:"
    echo "  sudo $0 tun0"
    echo "  sudo $0 tun1"
    echo "  sudo $0 both"
    echo
}

# ============================================================
# Basic validation
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

if [[ "$#" -ne 1 ]]; then
    log_error "An interface argument is required."
    usage
    exit 1
fi

case "$1" in

    tun0)
        INTERFACES=("tun0")
        ;;

    tun1)
        INTERFACES=("tun1")
        ;;

    both)
        INTERFACES=("tun0" "tun1")
        ;;

    *)
        log_error "Invalid argument: $1"
        usage
        exit 1
        ;;

esac

# ============================================================
# Load configuration
# ============================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file does not exist: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ============================================================
# Concurrent connection protection
# ============================================================

VPN_MANAGER_SERVICE="vpn-manager.service"
TUN1_WATCHER_SERVICE="tun1-watcher.service"

VPN_MANAGER_WAS_ACTIVE=0
TUN1_WATCHER_WAS_ACTIVE=0

SERVICES_STATE_CAPTURED=0
SERVICES_STATE_RESTORED=0

# ============================================================
# Validate configuration variables
# ============================================================

if [[ -z "${ALLOW_CONCURRENT_CONNECTIONS:-}" ]]; then
    log_error "ALLOW_CONCURRENT_CONNECTIONS is missing from $CONFIG_FILE"
    exit 1
fi

# ============================================================
# Validate endpoint route scope
# ============================================================

if [[ -z "${ENDPOINT_ROUTE_SCOPE:-}" ]]; then
    log_error "ENDPOINT_ROUTE_SCOPE is missing from $CONFIG_FILE"
    exit 1
fi

case "$ENDPOINT_ROUTE_SCOPE" in

    both)
        ENDPOINT_ROUTE_ARGUMENT=""
        ;;

    tun0)
        ENDPOINT_ROUTE_ARGUMENT="tun0"
        ;;

    tun1)
        ENDPOINT_ROUTE_ARGUMENT="tun1"
        ;;

    *)
        log_error "Invalid ENDPOINT_ROUTE_SCOPE: $ENDPOINT_ROUTE_SCOPE"
        log_error "Allowed values: both, tun0, tun1"
        exit 1
        ;;

esac

# ============================================================
# Validate script directory
# ============================================================

if [[ ! -d "$SCRIPT_DIR" ]]; then
    log_error "Script directory does not exist: $SCRIPT_DIR"
    exit 1
fi

# ============================================================
# Capture service state
#
# The original active/inactive state is captured exactly once.
# ============================================================

capture_service_state()
{
    if [[ "$ALLOW_CONCURRENT_CONNECTIONS" != "no" ]]; then
        log_info "Concurrent connections are allowed."
        log_info "VPN services will not be modified."
        return 0
    fi

    log_info "Concurrent connections are disabled."
    log_info "Capturing current service state..."

    if systemctl is-active --quiet "$VPN_MANAGER_SERVICE"; then
        VPN_MANAGER_WAS_ACTIVE=1
        log_info "$VPN_MANAGER_SERVICE is active."
    else
        VPN_MANAGER_WAS_ACTIVE=0
        log_info "$VPN_MANAGER_SERVICE is inactive."
    fi

    if systemctl is-active --quiet "$TUN1_WATCHER_SERVICE"; then
        TUN1_WATCHER_WAS_ACTIVE=1
        log_info "$TUN1_WATCHER_SERVICE is active."
    else
        TUN1_WATCHER_WAS_ACTIVE=0
        log_info "$TUN1_WATCHER_SERVICE is inactive."
    fi

    SERVICES_STATE_CAPTURED=1
}

# ============================================================
# Stop services that were active before the optimizer started
# ============================================================

stop_concurrent_services()
{
    if [[ "$ALLOW_CONCURRENT_CONNECTIONS" != "no" ]]; then
        return 0
    fi

    if [[ "$SERVICES_STATE_CAPTURED" -ne 1 ]]; then
        log_error "Service state has not been captured."
        return 1
    fi

    echo
    log_info "Stopping services that were active before the optimizer started..."

    if [[ "$VPN_MANAGER_WAS_ACTIVE" -eq 1 ]]; then
        log_info "Stopping $VPN_MANAGER_SERVICE..."

        if ! systemctl stop "$VPN_MANAGER_SERVICE"; then
            log_error "Failed to stop $VPN_MANAGER_SERVICE."
            return 1
        fi

        log_success "Stopped $VPN_MANAGER_SERVICE"
    else
        log_info "$VPN_MANAGER_SERVICE was already inactive. Leaving it stopped."
    fi

    if [[ "$TUN1_WATCHER_WAS_ACTIVE" -eq 1 ]]; then
        log_info "Stopping $TUN1_WATCHER_SERVICE..."

        if ! systemctl stop "$TUN1_WATCHER_SERVICE"; then
            log_error "Failed to stop $TUN1_WATCHER_SERVICE."
            return 1
        fi

        log_success "Stopped $TUN1_WATCHER_SERVICE"
    else
        log_info "$TUN1_WATCHER_SERVICE was already inactive. Leaving it stopped."
    fi
}

# ============================================================
# Restore original service state
#
# This function is safe to call from the EXIT trap.
# Both services are restored independently.
# ============================================================

restore_concurrent_services()
{
    if [[ "$ALLOW_CONCURRENT_CONNECTIONS" != "no" ]]; then
        return 0
    fi

    if [[ "$SERVICES_STATE_CAPTURED" -ne 1 ]]; then
        return 0
    fi

    if [[ "$SERVICES_STATE_RESTORED" -eq 1 ]]; then
        return 0
    fi

    SERVICES_STATE_RESTORED=1

    echo
    echo "============================================================"
    log_info "Restoring original VPN service state..."
    echo "============================================================"

    # --------------------------------------------------------
    # Restore vpn-manager.service
    # --------------------------------------------------------

    if [[ "$VPN_MANAGER_WAS_ACTIVE" -eq 1 ]]; then

        log_info "Original state: $VPN_MANAGER_SERVICE active."
        log_info "Starting $VPN_MANAGER_SERVICE..."

        if systemctl start "$VPN_MANAGER_SERVICE"; then
            log_success "Restored: $VPN_MANAGER_SERVICE active."
        else
            log_error "FAILED to restore $VPN_MANAGER_SERVICE to active state."
        fi

    else

        log_info "Original state: $VPN_MANAGER_SERVICE inactive."
        log_info "Ensuring $VPN_MANAGER_SERVICE is stopped..."

        if systemctl stop "$VPN_MANAGER_SERVICE"; then
            log_success "Restored: $VPN_MANAGER_SERVICE inactive."
        else
            log_error "FAILED to restore $VPN_MANAGER_SERVICE to inactive state."
        fi

    fi

    # --------------------------------------------------------
    # Restore tun1-watcher.service
    # --------------------------------------------------------

    if [[ "$TUN1_WATCHER_WAS_ACTIVE" -eq 1 ]]; then

        log_info "Original state: $TUN1_WATCHER_SERVICE active."
        log_info "Starting $TUN1_WATCHER_SERVICE..."

        if systemctl start "$TUN1_WATCHER_SERVICE"; then
            log_success "Restored: $TUN1_WATCHER_SERVICE active."
        else
            log_error "FAILED to restore $TUN1_WATCHER_SERVICE to active state."
        fi

    else

        log_info "Original state: $TUN1_WATCHER_SERVICE inactive."
        log_info "Ensuring $TUN1_WATCHER_SERVICE is stopped..."

        if systemctl stop "$TUN1_WATCHER_SERVICE"; then
            log_success "Restored: $TUN1_WATCHER_SERVICE inactive."
        else
            log_error "FAILED to restore $TUN1_WATCHER_SERVICE to inactive state."
        fi

    fi

    echo "============================================================"
}

# ============================================================
# Always restore service state when the master exits
# ============================================================

trap 'restore_concurrent_services' EXIT

# ============================================================
# Run Script 00
#
# This runs exactly ONCE per master invocation.
# ============================================================

run_endpoint_route()
{
    local script="00-endpoint-route.sh"
    local script_path="$SCRIPT_DIR/$script"

    if [[ ! -f "$script_path" ]]; then
        log_error "Missing module: $script_path"
        exit 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_error "Module is not executable: $script_path"
        exit 1
    fi

    echo
    echo "============================================================"
    echo "[00] Starting: $script"
    echo "Endpoint route scope: $ENDPOINT_ROUTE_SCOPE"
    echo "============================================================"

    case "$ENDPOINT_ROUTE_SCOPE" in

        both)

            # No argument means tun0 + tun1.
            if ! "$script_path"; then
                log_error "Module failed: $script"
                log_error "WireGuard Optimizer stopped."
                exit 1
            fi
            ;;

        tun0)

            if ! "$script_path" tun0; then
                log_error "Module failed: $script"
                log_error "WireGuard Optimizer stopped."
                exit 1
            fi
            ;;

        tun1)

            if ! "$script_path" tun1; then
                log_error "Module failed: $script"
                log_error "WireGuard Optimizer stopped."
                exit 1
            fi
            ;;

    esac

    echo
    log_success "Module completed: $script"
    log_info "Sleeping ${SLEEP_BETWEEN_SCRIPTS}s..."

    sleep "$SLEEP_BETWEEN_SCRIPTS"
}

# ============================================================
# Run normal optimizer module
# ============================================================

run_module()
{
    local number="$1"
    local script="$2"
    local interface="$3"

    local script_path="$SCRIPT_DIR/$script"

    if [[ ! -f "$script_path" ]]; then
        log_error "Missing module: $script_path"
        exit 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_error "Module is not executable: $script_path"
        exit 1
    fi

    echo
    echo "============================================================"
    echo "[$number] Starting: $script"
    echo "Interface: $interface"
    echo "============================================================"

    if ! "$script_path" "$interface"; then

        echo
        echo "============================================================"
        log_error "Module failed: $script"
        log_error "Interface: $interface"
        log_error "WireGuard Optimizer stopped."
        echo "============================================================"

        exit 1
    fi

    echo
    log_success "Module completed: $script"
    log_info "Sleeping ${SLEEP_BETWEEN_SCRIPTS}s..."

    sleep "$SLEEP_BETWEEN_SCRIPTS"
}

# ============================================================
# Run complete workflow for one interface
# ============================================================

run_interface()
{
    local interface="$1"

    echo
    echo "############################################################"
    echo "# WireGuard Optimizer"
    echo "# Interface: $interface"
    echo "############################################################"
    echo

    log_info "Starting workflow for $interface"

    # --------------------------------------------------------
    # Script 01
    # --------------------------------------------------------

    run_module \
        "01" \
        "01-config-manager.sh" \
        "$interface"

    # --------------------------------------------------------
    # Script 02
    # --------------------------------------------------------

    run_module \
        "02" \
        "02-candidate-conflict-filter.sh" \
        "$interface"

    # --------------------------------------------------------
    # Script 03
    # --------------------------------------------------------

    run_module \
        "03" \
        "03-prepare-candidates.sh" \
        "$interface"

    # --------------------------------------------------------
    # Script 04
    # --------------------------------------------------------

    run_module \
        "04" \
        "04-test-candidates.sh" \
        "$interface"

    # --------------------------------------------------------
    # Script 05
    # --------------------------------------------------------

    run_module \
        "05" \
        "05-deploy-winner.sh" \
        "$interface"

    # --------------------------------------------------------
    # Script 06
    #
    # Final cleanup and verification.
    #
    # Script 06 removes only interface-specific temporary
    # workspace.
    #
    # Persistent speed and endpoint state files are NOT
    # deleted by Script 06.
    # --------------------------------------------------------

    run_module \
        "06" \
        "06-cleanup.sh" \
        "$interface"

    log_success "Workflow completed for $interface"
}

# ============================================================
# Remove interface-specific speed state
# ============================================================

cleanup_speed_state()
{
    local interface="$1"
    local state_file="$STATE_DIR/${interface}-speed-state.txt"

    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"
        log_success "Removed: $state_file"
    else
        log_info "Not found: $state_file"
    fi
}

# ============================================================
# Remove global run state
# ============================================================

for interface in "${INTERFACES[@]}"; do
    cleanup_speed_state "$interface"
done

if [[ -f "$STATE_DIR/ip-domain-state.txt" ]]; then
    rm -f "$STATE_DIR/ip-domain-state.txt"
    log_success "Removed: $STATE_DIR/ip-domain-state.txt"
else
    log_info "Not found: $STATE_DIR/ip-domain-state.txt"
fi

# ============================================================
# Main
# ============================================================

echo
echo "============================================================"
echo " WireGuard Optimizer Master"
echo "============================================================"

log_info "Run mode: $1"
log_info "Endpoint route scope: $ENDPOINT_ROUTE_SCOPE"
log_info "Sleep between modules: ${SLEEP_BETWEEN_SCRIPTS}s"

# ============================================================
# Protect against concurrent VPN management
# ============================================================

capture_service_state

if [[ "$ALLOW_CONCURRENT_CONNECTIONS" == "no" ]]; then

    if ! stop_concurrent_services; then
        log_error "Could not safely stop required VPN services."
        log_error "WireGuard Optimizer will not start."
        exit 1
    fi

fi

# ============================================================
# Script 00
#
# Runs exactly ONCE.
# ============================================================

run_endpoint_route

# ============================================================
# Interface-specific workflows
#
# Script 00 is NOT called from here.
# ============================================================

for interface in "${INTERFACES[@]}"; do
    run_interface "$interface"
done

# ============================================================
# Final result
# ============================================================

echo
echo "============================================================"
log_success "WireGuard Optimizer completed successfully."
log_success "Run mode: $1"
echo "============================================================"
echo