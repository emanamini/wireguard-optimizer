#!/usr/bin/env bash

# ============================================================
# VPN Optimizer
# Module: 04-deploy-winner.sh
# ============================================================
#
# PURPOSE
#   Select the fastest valid VPN candidate and deploy it to the
#   requested production WireGuard interface.
#
# USAGE
#   ./04-deploy-winner.sh tun0
#   ./04-deploy-winner.sh tun1
#
# INPUTS
#
#   /etc/vpn-optimizer.conf
#
#   /dev/shm/vpn-optimizer/tunX/*.conf
#
#   /opt/router/vpn-optimizer/state/tunX-speed-state.txt
#
#       config<TAB>speed<TAB>timestamp
#
#   /opt/router/vpn-optimizer/state/tunX-endpoint-state.txt
#
#       domain<TAB>ip
#
# PRODUCTION CONFIG
#
#   /etc/wireguard/tun0.conf
#   /etc/wireguard/tun1.conf
#
# IMPORTANT
#
#   Script 4 does not perform VPN health verification.
#   Script 5 performs the final verification.
#
#   If no winner exists, the production configuration is left
#   untouched and the existing VPN is brought back UP.
#
#   Operational failures do not stop the master workflow.
#
# ============================================================

set -u

# ============================================================
# PATHS
# ============================================================

CONFIG_FILE="/etc/vpn-optimizer.conf"

BASE_DIR="/dev/shm/vpn-optimizer"
STATE_DIR="/opt/router/vpn-optimizer/state"
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

if [[ "$INTERFACE" == "tun0" ]]; then
    OTHER_INTERFACE="tun1"
else
    OTHER_INTERFACE="tun0"
fi

CANDIDATE_DIR="$BASE_DIR/$INTERFACE"

SPEED_STATE_FILE="$STATE_DIR/${INTERFACE}-speed-state.txt"

ENDPOINT_STATE_FILE="$STATE_DIR/${INTERFACE}-endpoint-state.txt"

OTHER_ENDPOINT_STATE_FILE="$STATE_DIR/${OTHER_INTERFACE}-endpoint-state.txt"

PRODUCTION_CONFIG="$WIREGUARD_DIR/${INTERFACE}.conf"

SYSTEMD_UNIT="wg-quick@${INTERFACE}.service"

# ============================================================
# RESULT
# ============================================================

WINNER=""
WINNER_SPEED=""

# ============================================================
# LOGGING
# ============================================================

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*"
}

log_error() {
    echo "[ERROR] $*"
}

# ============================================================
# LOAD CONFIGURATION
# ============================================================

load_configuration() {

    if [[ -f "$CONFIG_FILE" ]]; then

        # shellcheck disable=SC1090
        source "$CONFIG_FILE"

    else

        log_warn "Configuration file not found: $CONFIG_FILE"

    fi

    CANDIDATE_CONFLICT_MODE="${CANDIDATE_CONFLICT_MODE:-domain}"

    VPN_PRODUCTION_COOLDOWN_SECONDS="${VPN_PRODUCTION_COOLDOWN_SECONDS:-5}"
    VPN_TEST_COOLDOWN_SECONDS="${VPN_TEST_COOLDOWN_SECONDS:-2}"
}

# ============================================================
# CHECK INTERFACE EXISTS
# ============================================================

interface_exists() {

    ip link show "$INTERFACE" >/dev/null 2>&1
}

interface_exists_for() {

    local iface="$1"

    ip link show "$iface" >/dev/null 2>&1
}

# ============================================================
# CHECK INTERFACE UP
#
# WireGuard may report:
#
#   state UNKNOWN
#
# while the interface has the UP flag:
#
#   <POINTOPOINT,NOARP,UP,LOWER_UP>
#
# Therefore we check the UP flag, not "state UP".
# ============================================================

interface_is_up() {

    ip link show "$INTERFACE" 2>/dev/null |
        grep -q '<[^>]*UP[^>]*>'
}

interface_is_up_for() {

    local iface="$1"

    ip link show "$iface" 2>/dev/null |
        grep -q '<[^>]*UP[^>]*>'
}

# ============================================================
# GET LIVE WIREGUARD ENDPOINT
# ============================================================

get_live_endpoint_ip() {

    local iface="$1"
    local endpoint=""

    if ! interface_exists_for "$iface"; then
        return 0
    fi

    endpoint=$(
        wg show "$iface" endpoints 2>/dev/null |
        awk 'NF >= 2 {
            print $2
            exit
        }'
    )

    [[ -z "$endpoint" ]] && return 0

    if [[ "$endpoint" == \[*\]:* ]]; then

        endpoint="${endpoint#\[}"
        endpoint="${endpoint%\]:*}"

    else

        endpoint="${endpoint%:*}"

    fi

    printf '%s\n' "$endpoint"
}

# ============================================================
# GET DOMAIN FOR IP
#
# State file:
#
#   domain<TAB>ip
# ============================================================

get_domain_for_ip() {

    local state_file="$1"
    local target_ip="$2"

    [[ -f "$state_file" ]] || return 1

    awk -F '\t' -v ip="$target_ip" '
        $2 == ip {
            print $1
            exit
        }
    ' "$state_file"
}

# ============================================================
# CHECK CANDIDATE CONFLICT
#
# 0 = conflict
# 1 = no conflict
# ============================================================

candidate_conflicts() {

    local candidate_ip="$1"
    local other_ip="$2"

    # --------------------------------------------------------
    # No endpoint on the other interface.
    # --------------------------------------------------------

    if [[ -z "$other_ip" ]]; then
        return 1
    fi

    # ========================================================
    # IP MODE
    # ========================================================

    if [[ "$CANDIDATE_CONFLICT_MODE" == "ip" ]]; then

        if [[ "$candidate_ip" == "$other_ip" ]]; then

            log_info "Conflict: same endpoint IP"

            return 0
        fi

        return 1
    fi

    # ========================================================
    # DOMAIN MODE
    # ========================================================

    if [[ "$CANDIDATE_CONFLICT_MODE" == "domain" ]]; then

        local candidate_domain=""
        local other_domain=""

        candidate_domain="$(
            get_domain_for_ip \
                "$ENDPOINT_STATE_FILE" \
                "$candidate_ip"
        )"

        other_domain="$(
            get_domain_for_ip \
                "$OTHER_ENDPOINT_STATE_FILE" \
                "$other_ip"
        )"

        if [[ -z "$candidate_domain" ]]; then

            log_warn "Candidate domain not found for $candidate_ip"

            return 0
        fi

        if [[ -z "$other_domain" ]]; then

            log_warn "Other domain not found for $other_ip"

            return 0
        fi

        log_info "Candidate domain: $candidate_domain"
        log_info "Other domain:     $other_domain"

        if [[ "$candidate_domain" == "$other_domain" ]]; then

            log_info "Conflict: same domain"

            return 0
        fi

        return 1
    fi

    log_error "Unknown CANDIDATE_CONFLICT_MODE: $CANDIDATE_CONFLICT_MODE"

    return 0
}

# ============================================================
# SELECT WINNER
# ============================================================

select_winner() {

    if [[ ! -f "$SPEED_STATE_FILE" ]]; then

        log_error "Speed state file not found:"
        log_error "$SPEED_STATE_FILE"

        return 1
    fi

    if [[ ! -d "$CANDIDATE_DIR" ]]; then

        log_error "Candidate directory not found:"
        log_error "$CANDIDATE_DIR"

        return 1
    fi

    local other_ip=""

    other_ip="$(get_live_endpoint_ip "$OTHER_INTERFACE")"

    log_info "Other interface: $OTHER_INTERFACE"

    if [[ -n "$other_ip" ]]; then

        log_info "Other live endpoint: $other_ip"

    else

        log_info "Other interface has no live endpoint"

    fi

    log_info "Conflict mode: $CANDIDATE_CONFLICT_MODE"

    # --------------------------------------------------------
    # Speed state is TAB separated:
    #
    # config<TAB>speed<TAB>timestamp
    #
    # Fastest candidate first.
    # --------------------------------------------------------

    while IFS=$'\t' read -r config speed timestamp; do

        [[ -z "$config" ]] && continue

        local candidate_file="$CANDIDATE_DIR/$config"
        local candidate_ip="${config%.conf}"

        log_info "--------------------------------------------"
        log_info "Candidate: $config"
        log_info "Speed:     $speed"
        log_info "Timestamp: $timestamp"
        log_info "Endpoint:  $candidate_ip"

        # ----------------------------------------------------
        # Candidate file must exist.
        # ----------------------------------------------------

        if [[ ! -f "$candidate_file" ]]; then

            log_warn "Candidate configuration missing"

            continue
        fi

        # ----------------------------------------------------
        # Check conflict.
        # ----------------------------------------------------

        if candidate_conflicts "$candidate_ip" "$other_ip"; then

            log_info "Candidate rejected"

            continue
        fi

        # ----------------------------------------------------
        # First valid candidate wins.
        # ----------------------------------------------------

        WINNER="$config"
        WINNER_SPEED="$speed"

        log_info "Candidate accepted"
        log_info "Winner: $WINNER"
        log_info "Winner speed: $WINNER_SPEED"

        return 0

    done < <(
        sort -t $'\t' -k2,2nr "$SPEED_STATE_FILE"
    )

    log_info "No valid winner found"

    return 1
}

# ============================================================
# STOP PRODUCTION INTERFACE
#
# Normal shutdown order:
#
#   1. systemd stop
#   2. check whether interface still exists
#   3. wg-quick down if necessary
#
# We deliberately do NOT use:
#
#   ip link delete
#
# as a normal recovery method.
# ============================================================

stop_interface() {

    log_info "Stopping $INTERFACE"

    # --------------------------------------------------------
    # First ask systemd to stop the WireGuard service.
    # --------------------------------------------------------

    if systemctl stop "$SYSTEMD_UNIT"; then

        log_info "systemd stopped $SYSTEMD_UNIT"

    else

        log_warn "systemd stop failed for $SYSTEMD_UNIT"

    fi

    # --------------------------------------------------------
    # If the interface disappeared, shutdown is complete.
    # --------------------------------------------------------

    if ! interface_exists; then

        log_info "$INTERFACE no longer exists"

    sleep "$VPN_PRODUCTION_COOLDOWN_SECONDS"
    
        return 0
    fi

    # --------------------------------------------------------
    # systemd did not remove the device.
    #
    # Ask wg-quick to perform its normal cleanup.
    # --------------------------------------------------------

    log_info "$INTERFACE still exists"
    log_info "Attempting: wg-quick down $INTERFACE"

    if wg-quick down "$INTERFACE"; then

        log_info "wg-quick down completed"

    else

        log_error "wg-quick down failed"

        return 1
    fi

    # --------------------------------------------------------
    # Confirm the interface disappeared.
    # --------------------------------------------------------

    if interface_exists; then

        log_error "$INTERFACE still exists after shutdown"

        return 1
    fi

    # --------------------------------------------------------
    # Required cooldown after stopping production VPN.
    # --------------------------------------------------------

    log_info "Waiting ${VPN_PRODUCTION_COOLDOWN_SECONDS}s after stopping production VPN"

    sleep "$VPN_PRODUCTION_COOLDOWN_SECONDS"

        return 0
    }

# ============================================================
# START PRODUCTION INTERFACE
#
# Normal method:
#
#   systemctl start wg-quick@tunX.service
#
# Fallback:
#
#   wg-quick up tunX
# ============================================================

start_interface() {

    log_info "Starting $INTERFACE"

    # --------------------------------------------------------
    # Prefer systemd.
    # --------------------------------------------------------

    if systemctl start "$SYSTEMD_UNIT"; then

        log_info "systemd started $SYSTEMD_UNIT"

        return 0
    fi

    # --------------------------------------------------------
    # Fallback to wg-quick.
    # --------------------------------------------------------

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
# INSTALL WINNER CONFIGURATION
#
# This function ONLY replaces the production configuration.
# ============================================================

install_winner_config() {

    local winner_file="$CANDIDATE_DIR/$WINNER"
    local temporary_config="${PRODUCTION_CONFIG}.optimizer-new"

    if [[ ! -f "$winner_file" ]]; then

        log_error "Winner configuration not found:"
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

    log_info "Winner configuration installed"

    return 0
}

# ============================================================
# DEPLOY WINNER
#
# If interface exists:
#
#   stop
#   cooldown
#
# If interface does not exist:
#
#   no stop required
#
# Then:
#
#   install winner
#   cooldown
#   start
# ============================================================

deploy_winner() {

    if [[ -z "$WINNER" ]]; then
        return 1
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
    # Cooldown after configuration replacement.
    # --------------------------------------------------------

    sleep "$VPN_TEST_COOLDOWN_SECONDS"

    # --------------------------------------------------------
    # Start production VPN.
    # --------------------------------------------------------

    if ! start_interface; then

        log_error "Winner could not be started"

        return 1
    fi

    # --------------------------------------------------------
    # Allow WireGuard to settle before final state check.
    # --------------------------------------------------------

    log_info "Waiting ${VPN_TEST_COOLDOWN_SECONDS}s for WireGuard to settle"

    sleep "$VPN_TEST_COOLDOWN_SECONDS"

    log_info "Winner deployment completed"

    return 0
}

# ============================================================
# RESTORE EXISTING PRODUCTION VPN
#
# Used when:
#
#   - no winner exists
#   - winner selection fails
#   - deployment fails before configuration replacement
#
# The production configuration is NOT changed.
# ============================================================

restore_existing_interface() {

    log_info "Restoring existing production VPN"

    # --------------------------------------------------------
    # If interface is already UP, leave it alone.
    # --------------------------------------------------------

    if interface_is_up; then

        log_info "$INTERFACE is already UP"

        return 0
    fi

    # --------------------------------------------------------
    # If the interface exists but is DOWN, cleanly remove it
    # before starting the existing production configuration.
    # --------------------------------------------------------

    if interface_exists; then

        log_info "$INTERFACE exists but is DOWN"

        if ! stop_interface; then

            log_error "Could not cleanly reset $INTERFACE"

            return 1
        fi

    else

        log_info "$INTERFACE does not currently exist"

    fi

    # --------------------------------------------------------
    # Start the existing production configuration.
    # --------------------------------------------------------

    if start_interface; then

        log_info "Waiting ${VPN_TEST_COOLDOWN_SECONDS}s for WireGuard to settle"

        sleep "$VPN_TEST_COOLDOWN_SECONDS"

        log_info "Existing production VPN restored"

        return 0
    fi

    log_error "Could not restore existing production VPN"

    return 1
}

# ============================================================
# FINAL REPORT
# ============================================================

print_final_report() {

    echo

    log_info "============================================"
    log_info "VPN Optimizer - Script 4 Result"
    log_info "============================================"

    log_info "Interface: $INTERFACE"

    if [[ -n "$WINNER" ]]; then

        log_info "Winner:    $WINNER"
        log_info "Speed:     $WINNER_SPEED"

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
log_info "VPN Optimizer - Winner Deployment"
log_info "Interface: $INTERFACE"
log_info "============================================"

# ============================================================
# LOAD CONFIGURATION
# ============================================================

load_configuration

log_info "Conflict mode: $CANDIDATE_CONFLICT_MODE"
log_info "Cooldown:      ${VPN_TEST_COOLDOWN_SECONDS}s"

# ============================================================
# CONFIGURATION VALIDATION
# ============================================================

if [[ "$CANDIDATE_CONFLICT_MODE" != "ip" &&
      "$CANDIDATE_CONFLICT_MODE" != "domain" ]]; then

    log_error "Invalid CANDIDATE_CONFLICT_MODE:"
    log_error "$CANDIDATE_CONFLICT_MODE"

    restore_existing_interface || true

else

    # ========================================================
    # SELECT WINNER
    # ========================================================

    if select_winner; then

        log_info "Winner selection completed"

        # ====================================================
        # DEPLOY WINNER
        # ====================================================

        if deploy_winner; then

            log_info "Winner deployment completed"

        else

            log_error "Winner deployment failed"

            # ------------------------------------------------
            # Try to leave production VPN running.
            # ------------------------------------------------

            restore_existing_interface || true

        fi

    else

        # ====================================================
        # NO WINNER
        #
        # Existing production config remains untouched.
        # ====================================================

        log_info "No winner will be deployed"
        log_info "Existing production configuration remains untouched"

        restore_existing_interface || true

    fi

fi

# ============================================================
# FINAL REPORT
# ============================================================

print_final_report

# ============================================================
# MASTER WORKFLOW
#
# Script 4 always returns success to the master workflow.
# Script 5 performs final health verification.
# ============================================================

exit 0