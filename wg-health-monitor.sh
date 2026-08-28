#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Module: wg-health-monitor.sh
# ============================================================
#
# PURPOSE
#   Check the health of a running production WireGuard interface.
#
#   Health consists of:
#
#       1. Download speed
#       2. Optional ping reliability
#
#   A single bad health check does NOT trigger optimization.
#
#   The complete health test is repeated HEALTH_RETRY_COUNT
#   times when the interface is unhealthy.
#
#   Only when every health attempt is unhealthy is the optimizer
#   started.
#
# ============================================================

set -u

# ============================================================
# CONFIGURATION
# ============================================================

CONFIG_FILE="/etc/wg-optimizer.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    printf '[ERROR] Configuration file does not exist: %s\n' "$CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ============================================================
# PATHS
# ============================================================
#
# All project paths come from wg-optimizer.conf.
#
# BASE_DIR
# LOG_DIR
# TEMP_BASE_DIR
#
# ============================================================

OPTIMIZER="$BASE_DIR/wg-optimizer.sh"
LOG_FILE="$LOG_DIR/wg-health-monitor.log"
DOWNLOAD_TEST_DIR="$TEMP_BASE_DIR"

STATE_DIR="$BASE_DIR/state"

# ============================================================
# LOGGING
# ============================================================

log()
{
    local level="$1"
    local message="$2"

    mkdir -p "$LOG_DIR"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    printf '%s [%s] %s\n' \
        "$timestamp" \
        "$level" \
        "$message" |
        tee -a "$LOG_FILE"
}

log_info()
{
    log "INFO" "$1"
}

log_warn()
{
    log "WARN" "$1"
}

log_error()
{
    log "ERROR" "$1"
}

log_info "Loaded configuration: $CONFIG_FILE"

# ============================================================
# INTERFACE
# ============================================================

INTERFACE="${1:-}"

if [ -z "$INTERFACE" ]; then
    log_error "Usage: $0 tun0|tun1"
    exit 1
fi

case "$INTERFACE" in

    tun0|tun1)
        ;;

    *)
        log_error "Invalid interface: $INTERFACE"
        log_error "Usage: $0 tun0|tun1"
        exit 1
        ;;

esac

# ============================================================
# STATE
# ============================================================

STATE_FILE="$STATE_DIR/${INTERFACE}-health.state"

write_state()
{
    local state="$1"
    local message="$2"

    mkdir -p "$STATE_DIR"

    cat > "$STATE_FILE" <<EOF
STATE=$state
MESSAGE="$message"
UPDATED_EPOCH=$(date +%s)
EOF

    chmod 644 "$STATE_FILE"
}

# ============================================================
# REQUIRED PATH VALIDATION
# ============================================================

if [ -z "${BASE_DIR:-}" ]; then
    log_error "BASE_DIR is not configured"
    exit 1
fi

if [ -z "${LOG_DIR:-}" ]; then
    log_error "LOG_DIR is not configured"
    exit 1
fi

if [ -z "${TEMP_BASE_DIR:-}" ]; then
    log_error "TEMP_BASE_DIR is not configured"
    exit 1
fi

if [ ! -x "$OPTIMIZER" ]; then
    log_error "Optimizer is missing or not executable: $OPTIMIZER"
    exit 1
fi

# ============================================================
# HEALTH CHECK PING SWITCH
# ============================================================

PING_ENABLED="no"

case "${HEALTH_CHECK_PING:-}" in

    y|Y|yes|Yes|YES)
        PING_ENABLED="yes"
        ;;

    *)
        PING_ENABLED="no"
        ;;

esac

# ============================================================
# CONFIGURATION VALIDATION
# ============================================================

if [ -z "${HEALTH_MIN_SPEED_MBPS:-}" ]; then
    log_error "HEALTH_MIN_SPEED_MBPS is not configured"
    exit 1
fi

if [ -z "${HEALTH_TEST_SIZE_MB:-}" ]; then
    log_error "HEALTH_TEST_SIZE_MB is not configured"
    exit 1
fi

if [ -z "${HEALTH_RETRY_COUNT:-}" ]; then
    log_error "HEALTH_RETRY_COUNT is not configured"
    exit 1
fi

if [ -z "${HEALTH_RETRY_DELAY_SECONDS:-}" ]; then
    log_error "HEALTH_RETRY_DELAY_SECONDS is not configured"
    exit 1
fi

if [ -z "${HEALTH_MAX_DOWNLOAD_SECONDS:-}" ]; then
    log_error "HEALTH_MAX_DOWNLOAD_SECONDS is not configured"
    exit 1
fi

if [ -z "${DOWNLOAD_TEST_URL:-}" ]; then
    log_error "DOWNLOAD_TEST_URL is not configured"
    exit 1
fi

if ! [[ "$HEALTH_MIN_SPEED_MBPS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log_error "Invalid HEALTH_MIN_SPEED_MBPS: $HEALTH_MIN_SPEED_MBPS"
    exit 1
fi

if ! [[ "$HEALTH_TEST_SIZE_MB" =~ ^[0-9]+$ ]] ||
   [ "$HEALTH_TEST_SIZE_MB" -lt 1 ]; then

    log_error "Invalid HEALTH_TEST_SIZE_MB: $HEALTH_TEST_SIZE_MB"
    exit 1
fi

if ! [[ "$HEALTH_RETRY_COUNT" =~ ^[0-9]+$ ]] ||
   [ "$HEALTH_RETRY_COUNT" -lt 1 ]; then

    log_error "Invalid HEALTH_RETRY_COUNT: $HEALTH_RETRY_COUNT"
    exit 1
fi

if ! [[ "$HEALTH_RETRY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log_error \
        "Invalid HEALTH_RETRY_DELAY_SECONDS: $HEALTH_RETRY_DELAY_SECONDS"
    exit 1
fi

if ! [[ "$HEALTH_MAX_DOWNLOAD_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    log_error \
        "Invalid HEALTH_MAX_DOWNLOAD_SECONDS: $HEALTH_MAX_DOWNLOAD_SECONDS"
    exit 1
fi

# ============================================================
# PING CONFIGURATION VALIDATION
# ============================================================

if [ "$PING_ENABLED" = "yes" ]; then

    if [ -z "${HEALTH_PING_DESTINATION:-}" ]; then
        log_error "HEALTH_PING_DESTINATION is not configured"
        exit 1
    fi

    if [ -z "${HEALTH_PING_COUNT:-}" ]; then
        log_error "HEALTH_PING_COUNT is not configured"
        exit 1
    fi

    if [ -z "${HEALTH_PING_TIMEOUT_SECONDS:-}" ]; then
        log_error "HEALTH_PING_TIMEOUT_SECONDS is not configured"
        exit 1
    fi

    if [ -z "${HEALTH_MAX_PACKET_LOSS_PERCENT:-}" ]; then
        log_error "HEALTH_MAX_PACKET_LOSS_PERCENT is not configured"
        exit 1
    fi

    if [ -z "${HEALTH_MAX_AVERAGE_LATENCY_MS:-}" ]; then
        log_error "HEALTH_MAX_AVERAGE_LATENCY_MS is not configured"
        exit 1
    fi

    if ! [[ "$HEALTH_PING_COUNT" =~ ^[0-9]+$ ]] ||
       [ "$HEALTH_PING_COUNT" -lt 1 ]; then

        log_error "Invalid HEALTH_PING_COUNT: $HEALTH_PING_COUNT"
        exit 1
    fi

    if ! [[ "$HEALTH_PING_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_error \
            "Invalid HEALTH_PING_TIMEOUT_SECONDS: $HEALTH_PING_TIMEOUT_SECONDS"
        exit 1
    fi

    if ! [[ "$HEALTH_MAX_PACKET_LOSS_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_error \
            "Invalid HEALTH_MAX_PACKET_LOSS_PERCENT: $HEALTH_MAX_PACKET_LOSS_PERCENT"
        exit 1
    fi

    if ! [[ "$HEALTH_MAX_AVERAGE_LATENCY_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_error \
            "Invalid HEALTH_MAX_AVERAGE_LATENCY_MS: $HEALTH_MAX_AVERAGE_LATENCY_MS"
        exit 1
    fi

fi

# ============================================================
# CONFIGURATION SUMMARY
# ============================================================

log_info "Health monitor interface: $INTERFACE"
log_info "Minimum speed: ${HEALTH_MIN_SPEED_MBPS} Mbps"
log_info "Download test size: ${HEALTH_TEST_SIZE_MB} MB"
log_info "Download timeout: ${HEALTH_MAX_DOWNLOAD_SECONDS} seconds"
log_info "Retry count: $HEALTH_RETRY_COUNT"
log_info "Retry delay: $HEALTH_RETRY_DELAY_SECONDS seconds"

if [ "$PING_ENABLED" = "yes" ]; then

    log_info "Ping health check: ENABLED"
    log_info "Ping destination: $HEALTH_PING_DESTINATION"
    log_info "Ping count: $HEALTH_PING_COUNT"
    log_info "Maximum packet loss: ${HEALTH_MAX_PACKET_LOSS_PERCENT}%"
    log_info "Maximum average latency: ${HEALTH_MAX_AVERAGE_LATENCY_MS} ms"

else

    log_info "Ping health check: DISABLED"

fi

# ============================================================
# TEMPORARY FILE
# ============================================================

mkdir -p "$DOWNLOAD_TEST_DIR"

TEMP_DOWNLOAD_FILE="$DOWNLOAD_TEST_DIR/${INTERFACE}-health-download.tmp"

rm -f "$TEMP_DOWNLOAD_FILE"

# ============================================================
# CLEANUP
# ============================================================

cleanup()
{
    rm -f "$TEMP_DOWNLOAD_FILE"
}

trap cleanup EXIT

# ============================================================
# PING TEST
# ============================================================

run_ping_test()
{
    local ping_output
    local packet_loss
    local average_latency

    ping_output=""

    if ! ping_output=$(ping \
        -I "$INTERFACE" \
        -c "$HEALTH_PING_COUNT" \
        -W "$HEALTH_PING_TIMEOUT_SECONDS" \
        "$HEALTH_PING_DESTINATION" 2>&1); then

        log_warn "$INTERFACE: ping command failed"
        return 1
    fi

    packet_loss=$(printf '%s\n' "$ping_output" |
        awk -F',' '
            /packet loss/ {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /packet loss/) {
                        gsub(/[^0-9.]/, "", $i)
                        print $i
                        exit
                    }
                }
            }
        ')

    average_latency=$(printf '%s\n' "$ping_output" |
        awk -F'=' '
            /rtt|round-trip/ {
                split($2, values, "/")
                print values[2]
                exit
            }
        ')

    if [ -z "$packet_loss" ]; then
        log_warn "$INTERFACE: could not determine packet loss"
        return 1
    fi

    if [ -z "$average_latency" ]; then
        log_warn "$INTERFACE: could not determine average latency"
        return 1
    fi

    log_info "$INTERFACE: ping packet loss ${packet_loss}%"
    log_info "$INTERFACE: ping average latency ${average_latency} ms"

    if ! awk \
        "BEGIN {exit !($packet_loss <= $HEALTH_MAX_PACKET_LOSS_PERCENT)}"
    then
        log_warn \
            "$INTERFACE: ping unhealthy - packet loss ${packet_loss}% > ${HEALTH_MAX_PACKET_LOSS_PERCENT}%"
        return 1
    fi

    if ! awk \
        "BEGIN {exit !($average_latency <= $HEALTH_MAX_AVERAGE_LATENCY_MS)}"
    then
        log_warn \
            "$INTERFACE: ping unhealthy - latency ${average_latency} ms > ${HEALTH_MAX_AVERAGE_LATENCY_MS} ms"
        return 1
    fi

    log_info "$INTERFACE: ping health check passed"

    return 0
}

# ============================================================
# DOWNLOAD TEST
# ============================================================

run_download_test()
{
    local test_bytes
    local start_time
    local end_time
    local elapsed_seconds
    local curl_status
    local downloaded_bytes
    local speed

    test_bytes=$((HEALTH_TEST_SIZE_MB * 1024 * 1024))

    rm -f "$TEMP_DOWNLOAD_FILE"

    start_time=$(date +%s.%N)

    if curl \
        --silent \
        --show-error \
        --fail \
        --interface "$INTERFACE" \
        --range "0-$((test_bytes - 1))" \
        --max-time "$HEALTH_MAX_DOWNLOAD_SECONDS" \
        --output "$TEMP_DOWNLOAD_FILE" \
        "$DOWNLOAD_TEST_URL"
    then
        curl_status=0
    else
        curl_status=$?
    fi

    end_time=$(date +%s.%N)

    elapsed_seconds=$(awk \
        -v start="$start_time" \
        -v end="$end_time" \
        'BEGIN {print end - start}')

    if [ "$curl_status" -ne 0 ]; then
        log_warn "$INTERFACE: download test failed"
        return 1
    fi

    if ! [[ "$elapsed_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_warn \
            "$INTERFACE: invalid download elapsed time: $elapsed_seconds"
        return 1
    fi

    if ! awk "BEGIN {exit !($elapsed_seconds > 0)}"; then
        log_warn "$INTERFACE: download elapsed time is zero"
        return 1
    fi

    downloaded_bytes=$(stat -c '%s' "$TEMP_DOWNLOAD_FILE" 2>/dev/null || echo 0)

    if ! [[ "$downloaded_bytes" =~ ^[0-9]+$ ]] ||
       [ "$downloaded_bytes" -le 0 ]; then

        log_warn "$INTERFACE: download test produced no data"
        return 1
    fi

    speed=$(awk \
        -v bytes="$downloaded_bytes" \
        -v seconds="$elapsed_seconds" \
        'BEGIN {
            print (bytes * 8) / seconds / 1000000
        }')

    if ! [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_warn \
            "$INTERFACE: invalid calculated speed: $speed"
        return 1
    fi

    log_info "$INTERFACE: download speed ${speed} Mbps"

    if awk "BEGIN {exit !($speed >= $HEALTH_MIN_SPEED_MBPS)}"; then

        log_info "$INTERFACE: speed health check passed"
        return 0

    fi

    log_warn \
        "$INTERFACE: speed unhealthy - ${speed} Mbps < ${HEALTH_MIN_SPEED_MBPS} Mbps"

    return 1
}

# ============================================================
# COMPLETE HEALTH TEST
# ============================================================

run_health_test()
{
    log_info "----------------------------------------------------"
    log_info "$INTERFACE: starting health test"
    log_info "----------------------------------------------------"

    if [ "$PING_ENABLED" = "yes" ]; then

        if ! run_ping_test; then
            log_warn "$INTERFACE: health test FAILED at ping stage"
            return 1
        fi

    else

        log_info "$INTERFACE: ping test skipped"

    fi

    if ! run_download_test; then
        log_warn "$INTERFACE: health test FAILED at download stage"
        return 1
    fi

    log_info "$INTERFACE: COMPLETE HEALTH TEST PASSED"

    return 0
}

# ============================================================
# HEALTH MONITOR
# ============================================================

main()
{
    log_info "===================================================="
    log_info "Starting WireGuard health monitor for $INTERFACE"
    log_info "===================================================="
write_state \
    "testing" \
    "VPN health check running."
    
    for ((attempt=1; attempt<=HEALTH_RETRY_COUNT; attempt++))
    do

        log_info \
            "$INTERFACE: health attempt $attempt/$HEALTH_RETRY_COUNT"

        if run_health_test; then

    log_info \
        "$INTERFACE: HEALTHY - optimizer not required"

    write_state \
        "healthy" \
        "VPN health check successful."

    exit 0
fi


        log_warn \
            "$INTERFACE: health attempt $attempt/$HEALTH_RETRY_COUNT FAILED"

        if [ "$attempt" -lt "$HEALTH_RETRY_COUNT" ]; then

            log_info \
                "$INTERFACE: waiting ${HEALTH_RETRY_DELAY_SECONDS} seconds before next health attempt"

            sleep "$HEALTH_RETRY_DELAY_SECONDS"

        fi

    done

    # ========================================================
    # ALL HEALTH ATTEMPTS FAILED
    # ========================================================

    log_warn \
        "$INTERFACE: all $HEALTH_RETRY_COUNT health attempts failed"

    log_warn \
        "$INTERFACE: starting WireGuard optimizer"
write_state \
    "optimizer_running" \
    "VPN unhealthy - optimizer running."
    
    "$OPTIMIZER" "$INTERFACE"

    optimizer_status=$?

    if [ "$optimizer_status" -eq 0 ]; then

    log_info \
        "$INTERFACE: optimizer completed successfully"

    write_state \
        "optimizer_success" \
        "VPN optimized successfully."

    exit 0
fi

    log_error \
    "$INTERFACE: optimizer failed with exit status $optimizer_status"

write_state \
    "optimizer_failed" \
    "VPN optimizer failed."

exit "$optimizer_status"
}

main