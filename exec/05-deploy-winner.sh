#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Module: 05-deploy-winner.sh
# ============================================================
#
# PURPOSE
#
#   Select the fastest candidate recorded by Script 04 and
#   deploy it to the requested production WireGuard interface.
#
#   Candidate conflict detection is NOT performed here.
#
#   Script 02 is responsible for candidate conflict detection.
#
#   Script 04 is responsible for testing candidates and
#   recording their measured speeds.
#
#   Script 05 is responsible only for:
#
#       1. Selecting the fastest tested candidate.
#       2. Replacing the production configuration.
#       3. Starting the production interface.
#       4. Rolling back if deployment fails.
#
#   Script 06 performs the final health verification.
#
# USAGE
#
#   ./05-deploy-winner.sh tun0
#   ./05-deploy-winner.sh tun1
#
# INPUTS
#
#   /etc/wg-optimizer.conf
#
#   /dev/shm/wg-optimizer/tunX-tmp/*.conf
#
#   /opt/router/wg-optimizer/state/tunX-speed-state.txt
#
#       config<TAB>speed<TAB>timestamp
#
# PRODUCTION CONFIGURATION
#
#   /etc/wireguard/tun0.conf
#   /etc/wireguard/tun1.conf
#
# ============================================================

set -u

# ============================================================
# PATHS
# ============================================================

CONFIG_FILE="/etc/wg-optimizer.conf"

STATE_DIR="/opt/router/wg-optimizer/state"
TEMP_BASE_DIR="/dev/shm/wg-optimizer"
WIREGUARD_DIR="/etc/wireguard"

# ============================================================
# ARGUMENT
# ============================================================

INTERFACE="${1:-}"

if [[ "$INTERFACE" != "tun0" && "$INTERFACE" != "tun1" ]]; then
    echo "[ERROR] Usage: $0 tun0|tun1"
    exit 0
fi

# ============================================================
# INTERFACE PATHS
# ============================================================

TEST_CANDIDATE_DIR="$TEMP_BASE_DIR/${INTERFACE}-tmp"
PRODUCTION_CANDIDATE_DIR="$TEMP_BASE_DIR/${INTERFACE}"

SPEED_STATE_FILE="$STATE_DIR/${INTERFACE}-speed-state.txt"

PRODUCTION_CONFIG="$WIREGUARD_DIR/${INTERFACE}.conf"

BACKUP_CONFIG="${PRODUCTION_CONFIG}.optimizer-backup"

SYSTEMD_UNIT="wg-quick@${INTERFACE}.service"

# ============================================================
# RESULT
# ============================================================

WINNER=""
WINNER_SPEED=""

# ============================================================
# LOGGING
# ============================================================

log_info()
{
    echo "[INFO] $*"
}

log_warn()
{
    echo "[WARN] $*"
}

log_error()
{
    echo "[ERROR] $*"
}

log_success()
{
    echo "[SUCCESS] $*"
}

# ============================================================
# LOAD CONFIGURATION
# ============================================================

load_configuration()
{
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found:"
        log_error "$CONFIG_FILE"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    VPN_PRODUCTION_COOLDOWN_SECONDS="${VPN_PRODUCTION_COOLDOWN_SECONDS:-5}"
    VPN_TEST_COOLDOWN_SECONDS="${VPN_TEST_COOLDOWN_SECONDS:-2}"

    return 0
}

# ============================================================
# INTERFACE EXISTS
# ============================================================

interface_exists()
{
    ip link show "$INTERFACE" >/dev/null 2>&1
}

# ============================================================
# INTERFACE IS UP
# ============================================================

interface_is_up()
{
    ip link show "$INTERFACE" 2>/dev/null |
        grep -q '<[^>]*UP[^>]*>'
}

# ============================================================
# SELECT WINNER
# ============================================================
#
# Script 04 has already tested the candidates.
#
# Script 05 simply selects the fastest candidate recorded
# in the speed state file.
#
# No conflict checking is performed here.
#
# ============================================================

select_winner()
{
    if [[ ! -f "$SPEED_STATE_FILE" ]]; then
        log_error "Speed state file not found:"
        log_error "$SPEED_STATE_FILE"
        return 1
    fi

    if [[ ! -d "$TEST_CANDIDATE_DIR" ]]; then
        log_error "Tested candidate directory not found:"
        log_error "$TEST_CANDIDATE_DIR"
        return 1
    fi

    while IFS=$'\t' read -r config speed timestamp; do

        [[ -z "$config" ]] && continue

        log_info "--------------------------------------------"
        log_info "Candidate: $config"
        log_info "Speed:     $speed"
        log_info "Timestamp: $timestamp"

        local candidate_file="$TEST_CANDIDATE_DIR/$config"

        if [[ ! -f "$candidate_file" ]]; then
            log_warn "Tested candidate configuration is missing:"
            log_warn "$candidate_file"
            continue
        fi

        WINNER="$config"
        WINNER_SPEED="$speed"

        log_success "Winner selected: $WINNER"
        log_success "Winner speed: $WINNER_SPEED Mbps"

        return 0

    done < <(
        sort -t $'\t' -k2,2nr "$SPEED_STATE_FILE"
    )

    log_warn "No valid tested candidate is available."

    return 1
}

# ============================================================
# STOP PRODUCTION INTERFACE
# ============================================================

stop_interface()
{
    log_info "Stopping $INTERFACE"

    if systemctl stop "$SYSTEMD_UNIT"; then
        log_info "systemd stopped $SYSTEMD_UNIT"
    else
        log_warn "systemd stop failed for $SYSTEMD_UNIT"
    fi

    if ! interface_exists; then
        log_info "$INTERFACE no longer exists"

        log_info \
            "Waiting ${VPN_PRODUCTION_COOLDOWN_SECONDS}s after stopping production VPN"

        sleep "$VPN_PRODUCTION_COOLDOWN_SECONDS"

        return 0
    fi

    log_info "$INTERFACE still exists"

    log_info "Attempting: wg-quick down $INTERFACE"

    if wg-quick down "$INTERFACE"; then
        log_info "wg-quick down completed"
    else
        log_error "wg-quick down failed"
        return 1
    fi

    if interface_exists; then
        log_error "$INTERFACE still exists after shutdown"
        return 1
    fi

    log_info \
        "Waiting ${VPN_PRODUCTION_COOLDOWN_SECONDS}s after stopping production VPN"

    sleep "$VPN_PRODUCTION_COOLDOWN_SECONDS"

    return 0
}

# ============================================================
# START PRODUCTION INTERFACE
# ============================================================

start_interface()
{
    log_info "Starting $INTERFACE"

    if systemctl start "$SYSTEMD_UNIT"; then
        log_info "systemd started $SYSTEMD_UNIT"
        return 0
    fi

    log_warn "systemd start failed"

    log_info "Attempting: wg-quick up $INTERFACE"

    if wg-quick up "$INTERFACE"; then
        log_info "wg-quick successfully started $INTERFACE"
        return 0
    fi

    log_error "Could not start $INTERFACE"

    return 1
}

# ============================================================
# BACKUP PRODUCTION CONFIGURATION
# ============================================================

backup_production_config()
{
    if [[ ! -f "$PRODUCTION_CONFIG" ]]; then
        log_warn "Production configuration does not exist:"
        log_warn "$PRODUCTION_CONFIG"
        return 1
    fi

    log_info "Creating production configuration backup"
    log_info "Source:      $PRODUCTION_CONFIG"
    log_info "Backup:      $BACKUP_CONFIG"

    if ! cp -f "$PRODUCTION_CONFIG" "$BACKUP_CONFIG"; then
        log_error "Could not create production configuration backup"
        return 1
    fi

    chmod 600 "$BACKUP_CONFIG" 2>/dev/null || true

    log_success "Production configuration backup created"

    return 0
}

# ============================================================
# RESTORE PRODUCTION CONFIGURATION
# ============================================================

restore_production_config()
{
    if [[ ! -f "$BACKUP_CONFIG" ]]; then
        log_error "Production configuration backup not found:"
        log_error "$BACKUP_CONFIG"
        return 1
    fi

    log_warn "Restoring previous production configuration"

    if ! cp -f "$BACKUP_CONFIG" "$PRODUCTION_CONFIG"; then
        log_error "Could not restore production configuration"
        return 1
    fi

    chmod 600 "$PRODUCTION_CONFIG" 2>/dev/null || true

    log_success "Previous production configuration restored"

    return 0
}

# ============================================================
# INSTALL WINNER CONFIGURATION
# ============================================================

install_winner_config()
{
    local winner_file="$PRODUCTION_CANDIDATE_DIR/$WINNER"
    local temporary_config="${PRODUCTION_CONFIG}.optimizer-new"

    if [[ ! -f "$winner_file" ]]; then
        log_error "Production candidate configuration not found:"
        log_error "$winner_file"
        return 1
    fi

    log_info "Installing winner configuration"
    log_info "Source:      $winner_file"
    log_info "Destination: $PRODUCTION_CONFIG"

    rm -f "$temporary_config"

    if ! cp "$winner_file" "$temporary_config"; then
        log_error "Could not copy winner configuration"
        rm -f "$temporary_config"
        return 1
    fi

    chmod 600 "$temporary_config" 2>/dev/null || true

    if ! mv -f "$temporary_config" "$PRODUCTION_CONFIG"; then
        log_error "Could not install winner configuration"
        rm -f "$temporary_config"
        return 1
    fi

    log_success "Winner configuration installed"

    return 0
}

# ============================================================
# DEPLOY WINNER
# ============================================================

deploy_winner()
{
    if [[ -z "$WINNER" ]]; then
        log_error "No winner selected"
        return 1
    fi

    # --------------------------------------------------------
    # Backup existing production configuration.
    # --------------------------------------------------------

    if [[ -f "$PRODUCTION_CONFIG" ]]; then

        if ! backup_production_config; then
            log_error "Cannot safely deploy without configuration backup"
            return 1
        fi

    else
        log_warn "No existing production configuration to back up"
    fi

    # --------------------------------------------------------
    # Stop existing production interface.
    # --------------------------------------------------------

    if interface_exists; then

        if ! stop_interface; then
            log_error "Could not safely stop $INTERFACE"
            return 1
        fi

    else
        log_info "$INTERFACE does not currently exist"
    fi

    # --------------------------------------------------------
    # Install winner.
    # --------------------------------------------------------

    if ! install_winner_config; then

        log_error "Winner installation failed"

        return 1
    fi

    # --------------------------------------------------------
    # Short cooldown after configuration replacement.
    # --------------------------------------------------------

    log_info \
        "Waiting ${VPN_TEST_COOLDOWN_SECONDS}s before starting production VPN"

    sleep "$VPN_TEST_COOLDOWN_SECONDS"

    # --------------------------------------------------------
    # Start production VPN.
    # --------------------------------------------------------

    if ! start_interface; then

        log_error "Winner could not be started"

        # ----------------------------------------------------
        # The new configuration is unusable.
        #
        # Restore the configuration that existed before
        # deployment.
        # ----------------------------------------------------

        if [[ -f "$BACKUP_CONFIG" ]]; then

            if restore_production_config; then

                log_info "Attempting to restore previous VPN"

                if ! start_interface; then
                    log_error "Previous production VPN could not be restarted"
                    return 1
                fi

                log_success "Previous production VPN restored"

            else

                log_error "Could not restore previous configuration"
                return 1

            fi

        else

            log_error "No backup available for rollback"
            return 1
        fi

        return 1
    fi

    # --------------------------------------------------------
    # Allow WireGuard to settle.
    # --------------------------------------------------------

    log_info \
        "Waiting ${VPN_TEST_COOLDOWN_SECONDS}s for WireGuard to settle"

    sleep "$VPN_TEST_COOLDOWN_SECONDS"

    log_success "Winner deployment completed"

    return 0
}

# ============================================================
# RESTORE EXISTING PRODUCTION VPN
# ============================================================

restore_existing_interface()
{
    log_info "Restoring existing production VPN"

    if interface_is_up; then
        log_info "$INTERFACE is already UP"
        return 0
    fi

    if interface_exists; then

        log_info "$INTERFACE exists but is DOWN"

        if ! stop_interface; then
            log_error "Could not cleanly reset $INTERFACE"
            return 1
        fi

    else
        log_info "$INTERFACE does not currently exist"
    fi

    if start_interface; then

        log_info \
            "Waiting ${VPN_TEST_COOLDOWN_SECONDS}s for WireGuard to settle"

        sleep "$VPN_TEST_COOLDOWN_SECONDS"

        log_success "Existing production VPN restored"

        return 0
    fi

    log_error "Could not restore existing production VPN"

    return 1
}

# ============================================================
# FINAL REPORT
# ============================================================

print_final_report()
{
    echo

    log_info "============================================"
    log_info "WireGuard Optimizer - Script 5 Result"
    log_info "============================================"

    log_info "Interface: $INTERFACE"

    if [[ -n "$WINNER" ]]; then
        log_info "Winner:    $WINNER"
        log_info "Speed:     $WINNER_SPEED Mbps"
    else
        log_info "Winner:    NONE"
    fi

    if interface_is_up; then
        log_info "Interface: UP"
    else
        log_warn "Interface: DOWN"
    fi

    log_info "============================================"
}

# ============================================================
# MAIN
# ============================================================

log_info "============================================"
log_info "WireGuard Optimizer - Winner Deployment"
log_info "Interface: $INTERFACE"
log_info "============================================"

# ============================================================
# LOAD CONFIGURATION
# ============================================================

if ! load_configuration; then
    print_final_report
    exit 0
fi

log_info \
    "Production cooldown: ${VPN_PRODUCTION_COOLDOWN_SECONDS}s"

log_info \
    "Test cooldown:        ${VPN_TEST_COOLDOWN_SECONDS}s"

log_info "Test candidate directory:       $TEST_CANDIDATE_DIR"
log_info "Production candidate directory: $PRODUCTION_CANDIDATE_DIR"

log_info "Speed state file:     $SPEED_STATE_FILE"

# ============================================================
# SELECT WINNER
# ============================================================

if select_winner; then

    log_info "Winner selection completed"

else

    log_info "No winner will be deployed"

    log_info "Existing production configuration remains untouched"

    restore_existing_interface || true

    print_final_report

    exit 0
fi

# ============================================================
# DEPLOY WINNER
# ============================================================

if deploy_winner; then

    log_success "Winner deployment completed"

else

    log_error "Winner deployment failed"

    # --------------------------------------------------------
    # If deployment failed, attempt to leave the production
    # interface running.
    # --------------------------------------------------------

    if [[ -f "$BACKUP_CONFIG" ]]; then

        log_info "Deployment failed; attempting configuration rollback"

        if interface_exists; then
            stop_interface || true
        fi

        if restore_production_config; then
            restore_existing_interface || true
        else
            log_error "Rollback failed"
        fi

    else

        restore_existing_interface || true

    fi

fi

# ============================================================
# FINAL REPORT
# ============================================================

print_final_report

# ============================================================
# MASTER WORKFLOW
# ============================================================
#
# Script 05 does not perform final health verification.
#
# Script 06 is responsible for final health verification.
#
# Operational failures do not stop the master workflow.
#
# ============================================================

exit 0