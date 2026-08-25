#!/usr/bin/env bash

# ============================================================
# VPN Optimizer
# Script 3: Candidate Testing
# ============================================================
#
# PURPOSE
#   Test every prepared candidate for tun0 or tun1.
#
#   Testing order:
#       1. Deploy temporary candidate
#       2. Ping test
#       3. Early 5 MB download test
#       4. Final 20 MB download test
#       5. Record passing candidate and final speed
#       6. Remove temporary interface
#
#   If concurrent connections are NOT allowed:
#       - Stop the production interface before testing.
#       - Leave it stopped when this script finishes.
#       - Script 4 is responsible for starting it again.
#
#   If concurrent connections ARE allowed:
#       - Leave the production interface untouched.
#
# IMPORTANT
#   This script does NOT:
#       - select the final winner
#       - modify tun0.conf or tun1.conf
#       - deploy a candidate permanently
#       - start a production VPN after testing
#
# USAGE
#   sudo /opt/router/vpn-optimizer/exec/03-test-candidates.sh tun0
#   sudo /opt/router/vpn-optimizer/exec/03-test-candidates.sh tun1
#
# ============================================================

set -u

# ============================================================
# 1. CONSTANTS AND GLOBAL VARIABLES
# ============================================================

CONFIG_FILE="/etc/vpn-optimizer.conf"

BASE_DIR="/opt/router/vpn-optimizer"
STATE_DIR="$BASE_DIR/state"
LOG_DIR="$BASE_DIR/log"

WG_DIR="/etc/wireguard"

SOURCE_INTERFACE=""
TEMP_INTERFACE=""
CANDIDATE_DIR=""
PRODUCTION_CONFIG=""

PING_COUNT=""
MAX_PACKET_LOSS=""
MAX_AVERAGE_LATENCY=""
PING_TEST_DESTINATION=""
PING_TIMEOUT_SECONDS=""

DOWNLOAD_URL=""
EARLY_SIZE_MB=""
EARLY_MIN_MBPS=""
FINAL_SIZE_MB=""
FINAL_MIN_MBPS=""
EARLY_MAX_SECONDS=""
FINAL_MAX_SECONDS=""

ALLOW_CONCURRENT_CONNECTIONS=""
VPN_PRODUCTION_COOLDOWN_SECONDS=""
VPN_TEST_COOLDOWN_SECONDS=""

RUN_RESULTS_FILE=""
TEMP_DOWNLOAD_FILE=""

CURRENT_CANDIDATE=""
CURRENT_CANDIDATE_FILE=""

GOOD_COUNT=0
PING_REJECT_COUNT=0
EARLY_REJECT_COUNT=0
FINAL_REJECT_COUNT=0
DEPLOY_REJECT_COUNT=0

# ============================================================
# 2. LOGGING
# ============================================================

LOG_FILE="$LOG_DIR/vpn-optimizer.log"

log()
{
    level="$1"
    message="$2"

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$LOG_DIR"

    printf '%s [%s] %s\n' \
        "$timestamp" \
        "$level" \
        "$message" | tee -a "$LOG_FILE"
}

info()
{
    log "INFO" "$1"
}

warn()
{
    log "WARN" "$1"
}

error()
{
    log "ERROR" "$1"
}

debug()
{
    log "DEBUG" "$1"
}

# ============================================================
# 3. CONFIGURATION
# ============================================================

load_config()
{
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Configuration file does not exist: $CONFIG_FILE"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    info "Configuration loaded from $CONFIG_FILE"
}

select_interface_settings()
{
    case "$SOURCE_INTERFACE" in

        tun0)
            TEMP_INTERFACE="${TUN0_TEMP_INTERFACE:-}"
            PING_COUNT="${TUN0_PING_COUNT:-}"
            MAX_PACKET_LOSS="${TUN0_MAX_PACKET_LOSS:-}"
            MAX_AVERAGE_LATENCY="${TUN0_MAX_AVERAGE_LATENCY:-}"

            CANDIDATE_DIR="/dev/shm/vpn-optimizer/tun0-tmp"
            PRODUCTION_CONFIG="$WG_DIR/tun0.conf"
            ;;

        tun1)
            TEMP_INTERFACE="${TUN1_TEMP_INTERFACE:-}"
            PING_COUNT="${TUN1_PING_COUNT:-}"
            MAX_PACKET_LOSS="${TUN1_MAX_PACKET_LOSS:-}"
            MAX_AVERAGE_LATENCY="${TUN1_MAX_AVERAGE_LATENCY:-}"

            CANDIDATE_DIR="/dev/shm/vpn-optimizer/tun1-tmp"
            PRODUCTION_CONFIG="$WG_DIR/tun1.conf"
            ;;

        *)
            error "Invalid interface: $SOURCE_INTERFACE"
            error "Expected tun0 or tun1"
            exit 1
            ;;
    esac
    PING_TEST_DESTINATION="${PING_TEST_DESTINATION:-}"
    PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-}"
    DOWNLOAD_URL="${DOWNLOAD_TEST_URL:-}"
    EARLY_SIZE_MB="${DOWNLOAD_EARLY_SIZE_MB:-5}"
    EARLY_MIN_MBPS="${DOWNLOAD_EARLY_MIN_MBPS:-5}"
    EARLY_MAX_SECONDS="${DOWNLOAD_EARLY_MAX_SECONDS:-10}"
    FINAL_SIZE_MB="${DOWNLOAD_FINAL_SIZE_MB:-20}"
    FINAL_MIN_MBPS="${DOWNLOAD_FINAL_MIN_MBPS:-30}"
    FINAL_MAX_SECONDS="${DOWNLOAD_FINAL_MAX_SECONDS:-10}"

    ALLOW_CONCURRENT_CONNECTIONS="${ALLOW_CONCURRENT_CONNECTIONS:-no}"
    VPN_PRODUCTION_COOLDOWN_SECONDS="${VPN_PRODUCTION_COOLDOWN_SECONDS:-5}"
    VPN_TEST_COOLDOWN_SECONDS="${VPN_TEST_COOLDOWN_SECONDS:-2}"

    info "Production interface: $SOURCE_INTERFACE"
    info "Temporary interface: $TEMP_INTERFACE"
    info "Candidate directory: $CANDIDATE_DIR"
    info "Concurrent connections: $ALLOW_CONCURRENT_CONNECTIONS"
    info "Production VPN cooldown: $VPN_PRODUCTION_COOLDOWN_SECONDS seconds"
    info "Test VPN cooldown: $VPN_TEST_COOLDOWN_SECONDS seconds"
}

validate_configuration()
{
    if [ -z "$TEMP_INTERFACE" ]; then
        error "Temporary interface is not configured for $SOURCE_INTERFACE"
        exit 1
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        error "DOWNLOAD_TEST_URL is not configured"
        exit 1
    fi

    if [ ! -d "$CANDIDATE_DIR" ]; then
        error "Candidate directory does not exist: $CANDIDATE_DIR"
        exit 1
    fi

    if ! [[ "$PING_COUNT" =~ ^[0-9]+$ ]] || [ "$PING_COUNT" -lt 1 ]; then
        error "Invalid ping count: $PING_COUNT"
        exit 1
    fi

    if ! [[ "$EARLY_MAX_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    error "Invalid early download timeout: $EARLY_MAX_SECONDS"
    exit 1
    fi

    if ! [[ "$FINAL_MAX_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "Invalid final download timeout: $FINAL_MAX_SECONDS"
        exit 1
    fi

    if ! [[ "$MAX_PACKET_LOSS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "Invalid packet-loss threshold: $MAX_PACKET_LOSS"
        exit 1
    fi

    if ! [[ "$MAX_AVERAGE_LATENCY" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "Invalid latency threshold: $MAX_AVERAGE_LATENCY"
        exit 1
    fi

    if [ -z "$PING_TEST_DESTINATION" ]; then
    error "PING_TEST_DESTINATION is not configured"
    exit 1
    fi

    if ! [[ "$PING_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "Invalid ping timeout: $PING_TIMEOUT_SECONDS"
        exit 1
    fi

    if ! [[ "$ALLOW_CONCURRENT_CONNECTIONS" == "yes" ||
            "$ALLOW_CONCURRENT_CONNECTIONS" == "no" ]]; then
        error "ALLOW_CONCURRENT_CONNECTIONS must be yes or no"
        exit 1
    fi

    if ! [[ "$VPN_PRODUCTION_COOLDOWN_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "Invalid VPN production cooldown: $VPN_PRODUCTION_COOLDOWN_SECONDS"
        exit 1
    fi

    if ! [[ "$VPN_TEST_COOLDOWN_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "Invalid VPN test cooldown: $VPN_TEST_COOLDOWN_SECONDS"
        exit 1
    fi

    info "Configuration validation passed"
}

# ============================================================
# 4. PRODUCTION VPN MANAGEMENT
# ============================================================

stop_production_interface()
{
    if [ "$ALLOW_CONCURRENT_CONNECTIONS" = "yes" ]; then
        info "Concurrent connections allowed; leaving $SOURCE_INTERFACE running"
        return 0
    fi

    info "Concurrent connections not allowed; stopping $SOURCE_INTERFACE"

    if systemctl is-active --quiet "wg-quick@$SOURCE_INTERFACE"; then
        systemctl stop "wg-quick@$SOURCE_INTERFACE"

        if [ $? -ne 0 ]; then
            error "Failed to stop wg-quick@$SOURCE_INTERFACE"
            exit 1
        fi

        info "$SOURCE_INTERFACE stopped"
    else
        info "$SOURCE_INTERFACE was already stopped"
    fi

    info "Waiting $VPN_PRODUCTION_COOLDOWN_SECONDS seconds before candidate testing"
    sleep "$VPN_PRODUCTION_COOLDOWN_SECONDS"
}

# ============================================================
# 5. TEMPORARY CANDIDATE DEPLOYMENT
# ============================================================

deploy_candidate()
{
    candidate_file="$1"

    CURRENT_CANDIDATE_FILE="$candidate_file"
    CURRENT_CANDIDATE=$(basename "$candidate_file")

    temporary_config="$WG_DIR/$TEMP_INTERFACE.conf"

    info "Preparing temporary interface: $TEMP_INTERFACE"
    info "Candidate: $CURRENT_CANDIDATE"

    # --------------------------------------------------------
    # Check whether the temporary interface already exists
    # --------------------------------------------------------

    if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then
        info "Temporary interface $TEMP_INTERFACE exists"

        if systemctl is-active --quiet "wg-quick@$TEMP_INTERFACE"; then
            warn "Temporary interface $TEMP_INTERFACE is already active"
            info "Stopping wg-quick@$TEMP_INTERFACE"

            if ! systemctl stop "wg-quick@$TEMP_INTERFACE"; then
                error "Failed to stop wg-quick@$TEMP_INTERFACE"
                DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
                return 1
            fi

        info "Waiting $VPN_TEST_COOLDOWN_SECONDS seconds for temporary interface teardown"
        sleep "$VPN_TEST_COOLDOWN_SECONDS"

            if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then
                error "Temporary interface $TEMP_INTERFACE is still present after stop"
                DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
                return 1
            fi

            info "Confirmed $TEMP_INTERFACE is down"

        else
            info "Temporary interface $TEMP_INTERFACE exists but wg-quick service is not active"
            info "Removing stale interface $TEMP_INTERFACE"

            ip link delete "$TEMP_INTERFACE" 2>/dev/null || true

            if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then
                error "Could not remove stale interface $TEMP_INTERFACE"
                DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
                return 1
            fi

            info "Confirmed stale interface $TEMP_INTERFACE was removed"
        fi

    else
        info "Temporary interface $TEMP_INTERFACE is not running"
    fi


    # --------------------------------------------------------
    # Install candidate configuration
    # --------------------------------------------------------

    info "Installing candidate: $CURRENT_CANDIDATE"
    debug "Copying $candidate_file to $temporary_config"

    if ! cp "$candidate_file" "$temporary_config"; then
        error "Failed to copy candidate to $temporary_config"
        DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
        return 1
    fi

    info "Candidate copied to $temporary_config"


    # --------------------------------------------------------
    # Start temporary WireGuard interface
    # --------------------------------------------------------

    info "Starting wg-quick@$TEMP_INTERFACE"

    if ! systemctl start "wg-quick@$TEMP_INTERFACE"; then
        error "Failed to start wg-quick@$TEMP_INTERFACE"
        rm -f "$temporary_config"
        DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
        return 1
    fi


    # --------------------------------------------------------
    # Verify WireGuard service
    # --------------------------------------------------------

    if ! systemctl is-active --quiet "wg-quick@$TEMP_INTERFACE"; then
        error "wg-quick@$TEMP_INTERFACE is not active after start"
        systemctl stop "wg-quick@$TEMP_INTERFACE" >/dev/null 2>&1
        rm -f "$temporary_config"
        DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
        return 1
    fi

    info "wg-quick@$TEMP_INTERFACE is active"


    # --------------------------------------------------------
    # Verify WireGuard interface
    # --------------------------------------------------------

    if ! ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then
        error "WireGuard interface $TEMP_INTERFACE does not exist after start"
        systemctl stop "wg-quick@$TEMP_INTERFACE" >/dev/null 2>&1
        rm -f "$temporary_config"
        DEPLOY_REJECT_COUNT=$((DEPLOY_REJECT_COUNT + 1))
        return 1
    fi

    info "WireGuard interface $TEMP_INTERFACE is UP"

    info "Waiting $VPN_TEST_COOLDOWN_SECONDS seconds for WireGuard connection to settle"
    sleep "$VPN_TEST_COOLDOWN_SECONDS"

    return 0
}

# ============================================================
# 6. PING TEST
# ============================================================

ping_test()
{
    info "Running ping test for $CURRENT_CANDIDATE"

    ping_output=$(ping \
        -I "$TEMP_INTERFACE" \
        -c "$PING_COUNT" \
        -W "$PING_TIMEOUT_SECONDS" \
        "$PING_TEST_DESTINATION" 2>&1)

    if [ $? -ne 0 ]; then
        warn "Ping test failed completely"
        PING_REJECT_COUNT=$((PING_REJECT_COUNT + 1))
        return 1
    fi

    debug "Ping output:"
    debug "$ping_output"

    packet_loss=$(printf '%s\n' "$ping_output" |
        awk -F',' '/packet loss/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /packet loss/) {
                    gsub(/[^0-9.]/, "", $i)
                    print $i
                    exit
                }
            }
        }')

    average_latency=$(printf '%s\n' "$ping_output" |
        awk -F'=' '/rtt|round-trip/ {
            split($2, a, "/")
            print a[2]
            exit
        }')

    if [ -z "$packet_loss" ]; then
        warn "Could not determine packet loss"
        PING_REJECT_COUNT=$((PING_REJECT_COUNT + 1))
        return 1
    fi

    if [ -z "$average_latency" ]; then
        warn "Could not determine average latency"
        PING_REJECT_COUNT=$((PING_REJECT_COUNT + 1))
        return 1
    fi

    info "Ping result: Packet loss=${packet_loss}%"
    info "Ping result: Average latency=${average_latency} ms"

    if awk "BEGIN {exit !($packet_loss <= $MAX_PACKET_LOSS)}"; then
        :
    else
        warn "Ping rejected: packet loss ${packet_loss}% > ${MAX_PACKET_LOSS}%"
        PING_REJECT_COUNT=$((PING_REJECT_COUNT + 1))
        return 1
    fi

    if awk "BEGIN {exit !($average_latency <= $MAX_AVERAGE_LATENCY)}"; then
        :
    else
        warn "Ping rejected: latency ${average_latency} ms > ${MAX_AVERAGE_LATENCY} ms"
        PING_REJECT_COUNT=$((PING_REJECT_COUNT + 1))
        return 1
    fi

    info "Ping test PASSED"

    return 0
}

# ============================================================
# 7. DOWNLOAD TEST
# ============================================================

download_bytes_for_mb()
{
    mb="$1"

    echo $((mb * 1024 * 1024))
}

download_test()
{
    info "Starting download test for $CURRENT_CANDIDATE"

    TEMP_DOWNLOAD_FILE="/dev/shm/vpn-optimizer/${TEMP_INTERFACE}-download.tmp"

    early_bytes=$(download_bytes_for_mb "$EARLY_SIZE_MB")
    final_bytes=$(download_bytes_for_mb "$FINAL_SIZE_MB")

    # --------------------------------------------------------
    # 7A. EARLY DOWNLOAD TEST
    # --------------------------------------------------------

    info "Early download test: first ${EARLY_SIZE_MB} MB"
    info "Early download timeout: ${EARLY_MAX_SECONDS} seconds"

    rm -f "$TEMP_DOWNLOAD_FILE"

    start_time=$(date +%s.%N)

    curl \
        --silent \
        --show-error \
        --fail \
        --interface "$TEMP_INTERFACE" \
        --range "0-$((early_bytes - 1))" \
        --max-time "$EARLY_MAX_SECONDS" \
        --output "$TEMP_DOWNLOAD_FILE" \
        "$DOWNLOAD_URL"

    curl_status=$?

    end_time=$(date +%s.%N)

    early_seconds=$(awk \
        -v start="$start_time" \
        -v end="$end_time" \
        'BEGIN {print end-start}')

    if [ $curl_status -ne 0 ]; then

        if awk "BEGIN {exit !($early_seconds >= $EARLY_MAX_SECONDS)}"; then
            warn "Early download timed out after ${EARLY_MAX_SECONDS} seconds"
        else
            warn "Early download failed"
        fi

        EARLY_REJECT_COUNT=$((EARLY_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    early_size=$(stat -c '%s' "$TEMP_DOWNLOAD_FILE")

    if [ "$early_size" -lt "$early_bytes" ]; then
        warn "Early download incomplete: received $early_size bytes, expected at least $early_bytes bytes"
        EARLY_REJECT_COUNT=$((EARLY_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    if [ "$early_size" -le 0 ]; then
        warn "Early download produced no data"
        EARLY_REJECT_COUNT=$((EARLY_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    early_mbps=$(awk \
        -v bytes="$early_size" \
        -v seconds="$early_seconds" \
        'BEGIN {print (bytes * 8) / seconds / 1000000}')

    info "Early download speed: ${early_mbps} Mbps"

    if awk "BEGIN {exit !($early_mbps >= $EARLY_MIN_MBPS)}"; then
        info "Early download test PASSED"
    else
        warn "Early download rejected: ${early_mbps} Mbps < ${EARLY_MIN_MBPS} Mbps"
        EARLY_REJECT_COUNT=$((EARLY_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    # --------------------------------------------------------
    # 7B. FINAL 20 MB TEST
    # --------------------------------------------------------

    info "Final download test: first ${FINAL_SIZE_MB} MB"
    info "Final download timeout: ${FINAL_MAX_SECONDS} seconds"
    
    rm -f "$TEMP_DOWNLOAD_FILE"

    start_time=$(date +%s.%N)

    curl \
        --silent \
        --show-error \
        --fail \
        --interface "$TEMP_INTERFACE" \
        --range "0-$((final_bytes - 1))" \
        --max-time "$FINAL_MAX_SECONDS" \
        --output "$TEMP_DOWNLOAD_FILE" \
        "$DOWNLOAD_URL"

    curl_status=$?

    end_time=$(date +%s.%N)

    if [ $curl_status -ne 0 ]; then
        warn "Final download failed"
        FINAL_REJECT_COUNT=$((FINAL_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    final_seconds=$(awk \
        -v start="$start_time" \
        -v end="$end_time" \
        'BEGIN {print end-start}')

    final_size=$(stat -c '%s' "$TEMP_DOWNLOAD_FILE")


    if [ "$final_size" -lt "$final_bytes" ]; then
        warn "Final download incomplete: received $final_size bytes, expected at least $final_bytes bytes"
        FINAL_REJECT_COUNT=$((FINAL_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    if [ "$final_size" -le 0 ]; then
        warn "Final download produced no data"
        FINAL_REJECT_COUNT=$((FINAL_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    final_mbps=$(awk \
        -v bytes="$final_size" \
        -v seconds="$final_seconds" \
        'BEGIN {print (bytes * 8) / seconds / 1000000}')

    info "Final download speed: ${final_mbps} Mbps"

    if awk "BEGIN {exit !($final_mbps >= $FINAL_MIN_MBPS)}"; then
        info "Final download test PASSED"
    else
        warn "Final download rejected: ${final_mbps} Mbps < ${FINAL_MIN_MBPS} Mbps"
        FINAL_REJECT_COUNT=$((FINAL_REJECT_COUNT + 1))
        rm -f "$TEMP_DOWNLOAD_FILE"
        return 1
    fi

    rm -f "$TEMP_DOWNLOAD_FILE"

    # Store the result for the result-recording section.
    CURRENT_SPEED="$final_mbps"

    return 0
}

# ============================================================
# 8. RESULT RECORDING
# ============================================================

record_result()
{
    candidate="$1"
    speed="$2"

    printf '%s\t%s\t%s\n' \
        "$candidate" \
        "$speed" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        >> "$RUN_RESULTS_FILE"

    GOOD_COUNT=$((GOOD_COUNT + 1))

    info "Recorded GOOD candidate: $candidate (${speed} Mbps)"
}

# ============================================================
# 9. CLEANUP
# ============================================================

cleanup_candidate()
{
    info "Stopping temporary interface $TEMP_INTERFACE"

    systemctl stop "wg-quick@$TEMP_INTERFACE" >/dev/null 2>&1

    rm -f "$WG_DIR/$TEMP_INTERFACE.conf"
    rm -f "$TEMP_DOWNLOAD_FILE"

    if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then
        warn "Temporary interface $TEMP_INTERFACE still exists after cleanup"
    else
        debug "Temporary interface $TEMP_INTERFACE removed"
    fi

    info "Waiting $VPN_TEST_COOLDOWN_SECONDS seconds before next candidate"
    sleep "$VPN_TEST_COOLDOWN_SECONDS"
}

# ============================================================
# 10. ATOMIC RESULT STATE
# ============================================================

prepare_result_state()
{
    mkdir -p "$STATE_DIR"

    RUN_RESULTS_FILE="/dev/shm/vpn-optimizer/${SOURCE_INTERFACE}-speed-state.tmp"

    rm -f "$RUN_RESULTS_FILE"

    rm -f "$STATE_DIR/${SOURCE_INTERFACE}-speed-state.txt"

    info "Previous speed state cleared for $SOURCE_INTERFACE"
    info "Temporary result file: $RUN_RESULTS_FILE"
}

commit_result_state()
{
    final_state="$STATE_DIR/${SOURCE_INTERFACE}-speed-state.txt"

    if [ ! -f "$RUN_RESULTS_FILE" ]; then
        warn "No result file was created"
        return 0
    fi

    mv -f "$RUN_RESULTS_FILE" "$final_state"

    if [ $? -ne 0 ]; then
        error "Failed to commit result state"
        return 1
    fi

    info "Committed speed state: $final_state"
}

# ============================================================
# 11. CANDIDATE LOOP
# ============================================================

test_all_candidates()
{
    candidate_count=0

    for candidate_file in "$CANDIDATE_DIR"/*.conf; do

        if [ ! -f "$candidate_file" ]; then
            continue
        fi

        candidate_count=$((candidate_count + 1))

        CURRENT_CANDIDATE=""
        CURRENT_SPEED=""

        info "----------------------------------------------------"
        info "Testing candidate $candidate_count: $(basename "$candidate_file")"
        info "----------------------------------------------------"

        if ! deploy_candidate "$candidate_file"; then
            warn "Candidate rejected during deployment"
            cleanup_candidate
            continue
        fi

        if ! ping_test; then
            warn "Candidate rejected by ping test"
            cleanup_candidate
            continue
        fi

        if ! download_test; then
            warn "Candidate rejected by download test"
            cleanup_candidate
            continue
        fi

        record_result "$CURRENT_CANDIDATE" "$CURRENT_SPEED"

        cleanup_candidate
    done

    if [ "$candidate_count" -eq 0 ]; then
        warn "No candidate configuration files found"
        return 1
    fi

    info "Candidate testing complete"
    info "Candidates tested: $candidate_count"
    info "Good candidates: $GOOD_COUNT"
    info "Ping rejected: $PING_REJECT_COUNT"
    info "Early download rejected: $EARLY_REJECT_COUNT"
    info "Final download rejected: $FINAL_REJECT_COUNT"
    info "Deployment rejected: $DEPLOY_REJECT_COUNT"

    return 0
}

# ============================================================
# 12. RESTORATION POLICY
# ============================================================

finish_production_state()
{
    if [ "$ALLOW_CONCURRENT_CONNECTIONS" = "yes" ]; then
        info "Concurrent connections allowed"
        info "Production interface $SOURCE_INTERFACE was left untouched"
        return 0
    fi

    info "Concurrent connections not allowed"
    info "Leaving $SOURCE_INTERFACE DOWN for Script 4"

    info "Script 4 is responsible for the final production decision"
}

# ============================================================
# 13. MAIN
# ============================================================

main()
{
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 tun0|tun1"
        exit 1
    fi

    SOURCE_INTERFACE="$1"

    load_config
    select_interface_settings
    validate_configuration

    prepare_result_state

    stop_production_interface

    info "===================================================="
    info "Starting candidate testing for $SOURCE_INTERFACE"
    info "===================================================="

    test_all_candidates

    test_status=$?

    finish_production_state

    if [ $test_status -ne 0 ]; then
        warn "Candidate testing finished with warnings"
    fi

    commit_result_state

    info "===================================================="
    info "Script 3 finished for $SOURCE_INTERFACE"
    info "===================================================="
}

main "$@"

