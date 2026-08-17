#!/usr/bin/env bash

# ============================================================
# VPN Optimizer
# Module: 05-cleanup.sh
# ============================================================
#
# PURPOSE:
#   Finalize the optimizer run for ONE VPN interface.
#
# USAGE:
#
#   sudo ./05-cleanup.sh tun0
#   sudo ./05-cleanup.sh tun1
#
# IMPORTANT:
#   This script is interface-specific.
#
#   If called with "tun0", it ONLY touches:
#
#       /dev/shm/vpn-optimizer/tun0/
#       /opt/router/vpn-optimizer/state/tun0-speed-state.txt
#       /opt/router/vpn-optimizer/state/tun0-endpoint-state.txt
#
#   If called with "tun1", it ONLY touches the corresponding
#   tun1 paths.
#
#   It NEVER removes the complete optimizer temporary directory
#   and NEVER touches the other interface's files.
#
#   Production WireGuard configuration is NEVER deleted:
#
#       /etc/wireguard/tun0.conf
#       /etc/wireguard/tun1.conf
#
# ============================================================

set -u
set -o pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

CONFIG_FILE="/etc/vpn-optimizer.conf"

TEMP_BASE_DIR="/dev/shm/vpn-optimizer"
STATE_DIR="/opt/router/vpn-optimizer/state"

VPN_RESTART_WAIT_SECONDS=5

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

log_info()
{
    echo "[INFO] $*"
}

log_success()
{
    echo "[SUCCESS] $*"
}

log_warn()
{
    echo "[WARN] $*"
}

log_error()
{
    echo "[ERROR] $*" >&2
}

# ------------------------------------------------------------
# Validate interface argument
# ------------------------------------------------------------

validate_interface()
{
    local interface="$1"

    case "$interface" in
        tun0|tun1)
            return 0
            ;;
        *)
            log_error "Invalid interface: $interface"
            log_error "Usage: $0 tun0|tun1"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# Cleanup helper
#
# Missing paths are not errors.
# Failed removal of an existing path is an error.
# ------------------------------------------------------------

remove_path()
{
    local path="$1"

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        log_info "Already absent: $path"
        return 0
    fi

    if rm -rf -- "$path"; then
        log_success "Removed: $path"
        return 0
    fi

    log_error "Failed to remove: $path"
    return 1
}

# ------------------------------------------------------------
# Cleanup interface-specific temporary workspace
# ------------------------------------------------------------

cleanup_interface_workspace()
{
    local interface="$1"
    local interface_dir="$TEMP_BASE_DIR/$interface"
    local interface_tmp_dir="$TEMP_BASE_DIR/${interface}-tmp"
    local failed=0

    log_info "Cleaning temporary workspace for $interface..."

    remove_path "$interface_dir" || failed=1
    remove_path "$interface_tmp_dir" || failed=1

    return "$failed"
}

# ------------------------------------------------------------
# Cleanup interface-specific state
# ------------------------------------------------------------

cleanup_interface_state()
{
    local interface="$1"
    local failed=0

    log_info "Cleaning state files for $interface..."

    remove_path "$STATE_DIR/${interface}-speed-state.txt" || failed=1

    remove_path "$STATE_DIR/${interface}-endpoint-state.txt" || failed=1

    return "$failed"
}

# ------------------------------------------------------------
# Check WireGuard interface
#
# Do not parse the human-readable output of:
#
#     wg show tunX
#
# The command itself returning successfully confirms that
# WireGuard knows about the interface.
# ------------------------------------------------------------

check_wireguard_interface()
{
    local interface="$1"

    if ! wg show "$interface" >/dev/null 2>&1; then
        log_warn "$interface: WireGuard interface is not available."
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Check WireGuard peer endpoint
#
# Machine-readable command:
#
#     wg show tunX endpoints
#
# Expected format:
#
#     <peer-public-key>    <endpoint>
#
# ------------------------------------------------------------

check_wireguard_endpoint()
{
    local interface="$1"
    local endpoint

    endpoint=$(wg show "$interface" endpoints 2>/dev/null |
        awk 'NF >= 2 { print $2; exit }')

    if [ -z "$endpoint" ]; then
        log_warn "$interface: no WireGuard peer endpoint found."
        return 1
    fi

    log_info "$interface: endpoint = $endpoint"

    return 0
}

# ------------------------------------------------------------
# Report handshake
#
# Handshake is informational only.
#
# A missing or old handshake does NOT cause a restart.
# ------------------------------------------------------------

report_wireguard_handshake()
{
    local interface="$1"
    local handshake

    handshake=$(wg show "$interface" latest-handshakes 2>/dev/null |
        awk 'NF >= 2 { print $2; exit }')

    if [ -z "$handshake" ] || [ "$handshake" = "0" ]; then
        log_info "$interface: no handshake information available."
        return 0
    fi

    log_info "$interface: latest handshake timestamp = $handshake"

    return 0
}

# ------------------------------------------------------------
# Verify one VPN
#
# Required:
#
#   1. WireGuard interface exists.
#   2. Peer endpoint exists.
#
# Optional:
#
#   Handshake is reported but not required.
# ------------------------------------------------------------

verify_vpn()
{
    local interface="$1"

    log_info "Checking $interface..."

    if ! check_wireguard_interface "$interface"; then
        return 1
    fi

    if ! check_wireguard_endpoint "$interface"; then
        return 1
    fi

    report_wireguard_handshake "$interface"

    log_success "$interface: WireGuard interface and endpoint are valid."

    return 0
}

# ------------------------------------------------------------
# Restart VPN
#
# Primary:
#
#     systemctl restart wg-quick@tunX.service
#
# Fallback:
#
#     wg-quick down tunX
#     wg-quick up tunX
# ------------------------------------------------------------

restart_vpn()
{
    local interface="$1"
    local service="wg-quick@${interface}.service"

    log_warn "$interface: restarting VPN..."

    if systemctl restart "$service" 2>/dev/null; then
        log_success "$interface: systemd restart completed."
    else
        log_warn "$interface: systemd restart failed."

        if wg-quick down "$interface" >/dev/null 2>&1; then
            log_info "$interface: wg-quick down completed."
        else
            log_info "$interface: wg-quick down was not required or failed."
        fi

        if wg-quick up "$interface" >/dev/null 2>&1; then
            log_success "$interface: wg-quick fallback started the interface."
        else
            log_error "$interface: wg-quick fallback failed."
            return 1
        fi
    fi

    sleep "$VPN_RESTART_WAIT_SECONDS"

    return 0
}

# ------------------------------------------------------------
# Verify and recover one VPN
# ------------------------------------------------------------

verify_and_recover_vpn()
{
    local interface="$1"

    if verify_vpn "$interface"; then
        return 0
    fi

    log_warn "$interface: initial verification failed."

    if ! restart_vpn "$interface"; then
        log_error "$interface: restart failed."
        return 1
    fi

    log_info "$interface: verifying after restart..."

    if verify_vpn "$interface"; then
        log_success "$interface: healthy after restart."
        return 0
    fi

    log_error "$interface: still unhealthy after restart."

    return 1
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main()
{
    local interface
    local failed=0

    # --------------------------------------------------------
    # Require exactly one interface argument.
    # --------------------------------------------------------

    if [ "$#" -ne 1 ]; then
        log_error "Exactly one interface is required."
        log_error "Usage: $0 tun0|tun1"
        exit 1
    fi

    interface="$1"

    if ! validate_interface "$interface"; then
        exit 1
    fi

    log_info "Selected interface: $interface"

    # --------------------------------------------------------
    # Load configuration if available.
    #
    # Script 5 does not depend on the configuration for its
    # interface-specific cleanup paths, so a missing config
    # is not fatal.
    # --------------------------------------------------------

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log_info "Loaded configuration: $CONFIG_FILE"
    else
        log_warn "Configuration file not found: $CONFIG_FILE"
        log_info "Using Script 5 defaults."
    fi

    # --------------------------------------------------------
    # Cleanup ONLY this interface.
    # --------------------------------------------------------

    if ! cleanup_interface_workspace "$interface"; then
        failed=1
    fi

    if ! cleanup_interface_state "$interface"; then
        failed=1
    fi

    # --------------------------------------------------------
    # Verify ONLY this interface.
    # --------------------------------------------------------

    log_info "Performing final verification for $interface..."

    if ! verify_and_recover_vpn "$interface"; then
        failed=1
    fi

    # --------------------------------------------------------
    # Final result.
    # --------------------------------------------------------

    if [ "$failed" -eq 0 ]; then
        log_success "$interface: cleanup and final verification completed successfully."
        exit 0
    fi

    log_error "$interface: cleanup completed with errors."
    exit 1
}

main "$@"