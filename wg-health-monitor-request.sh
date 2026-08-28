#!/usr/bin/env bash
# /opt/router/wg-optimizer/wg-health-monitor-request.sh

set -u

CONFIG_FILE="/etc/wg-optimizer.conf"
SCRIPT_DIR="/opt/router/wg-optimizer"
HEALTH_MONITOR="$SCRIPT_DIR/wg-health-monitor.sh"

STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$SCRIPT_DIR/wg-health-monitor.state"
LOCK_FILE="${STATE_FILE}.lock"

mkdir -p "$SCRIPT_DIR"
mkdir -p "$STATE_DIR"

# ============================================================
# CONFIGURATION
# ============================================================

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR|Configuration file does not exist: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

COOLDOWN_SECONDS="${VPN_HEALTH_MANUAL_COOLDOWN_SECONDS:-600}"

HEALTH_MONITOR_INTERFACES="${HEALTH_MONITOR_INTERFACES:-tun0 tun1}"

# ============================================================
# REQUIRED FILE VALIDATION
# ============================================================

if [ ! -x "$HEALTH_MONITOR" ]; then
    echo "ERROR|Health monitor is missing or not executable: $HEALTH_MONITOR"
    exit 1
fi

# ============================================================
# INTERFACE STATE
# ============================================================

get_interface_state()
{
    local interface="$1"
    local interface_state_file="$STATE_DIR/${interface}-health.state"

    if [ ! -f "$interface_state_file" ]; then
        echo "unknown"
        return
    fi

    # shellcheck disable=SC1090
    source "$interface_state_file"

    echo "${STATE:-unknown}"
}

# ============================================================
# MAIN REQUEST
# ============================================================

(
    flock -n 9 || {
        echo "BUSY|A VPN health check request is already being processed."
        exit 2
    }

    # --------------------------------------------------------
    # Read previous request information
    # --------------------------------------------------------

    LAST_REQUEST_EPOCH=0
    LAST_SUCCESS_EPOCH=0
    LAST_FAILURE_EPOCH=0

    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi

    CURRENT_EPOCH=$(date +%s)

    ELAPSED=$((CURRENT_EPOCH - LAST_REQUEST_EPOCH))

    if [ "$LAST_REQUEST_EPOCH" -gt 0 ] &&
       [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then

        REMAINING=$((COOLDOWN_SECONDS - ELAPSED))

        echo "COOLDOWN|$REMAINING"
        exit 3
    fi

    # --------------------------------------------------------
    # Record request
    # --------------------------------------------------------

    cat > "$STATE_FILE" <<EOF
LAST_REQUEST_EPOCH=$CURRENT_EPOCH
LAST_SUCCESS_EPOCH=$LAST_SUCCESS_EPOCH
LAST_FAILURE_EPOCH=$LAST_FAILURE_EPOCH
STATUS=testing
MESSAGE="VPN health check running."
EOF

    chmod 644 "$STATE_FILE"

    # >>> NEW: INITIALIZE PENDING STATES FOR THE UI >>>
    for INTERFACE in $HEALTH_MONITOR_INTERFACES
    do
        cat > "$STATE_DIR/${INTERFACE}-health.state" <<EOF
STATE=pending
MESSAGE="Waiting in queue..."
EOF
        chmod 644 "$STATE_DIR/${INTERFACE}-health.state"
    done
    # <<< END NEW <<<

    # --------------------------------------------------------
    # Run configured interfaces
    # --------------------------------------------------------

    FINAL_STATUS=0

    for INTERFACE in $HEALTH_MONITOR_INTERFACES
    do

        cat > "$STATE_DIR/${INTERFACE}-health.state" <<EOF
STATE=testing
MESSAGE="VPN health check running."
EOF

        chmod 644 "$STATE_DIR/${INTERFACE}-health.state"

        # Redirect stdout to /dev/null; wg-health-monitor.sh already writes logs to LOG_FILE
        "$HEALTH_MONITOR" "$INTERFACE" > /dev/null
        INTERFACE_STATUS=$?

        if [ "$INTERFACE_STATUS" -ne 0 ]; then
            FINAL_STATUS=1
        fi

    done
    
    # --------------------------------------------------------
    # Determine final result
    # --------------------------------------------------------

    FINISHED_EPOCH=$(date +%s)

    if [ "$FINAL_STATUS" -eq 0 ]; then
        
        cat > "$STATE_FILE" <<EOF
LAST_REQUEST_EPOCH=$CURRENT_EPOCH
LAST_SUCCESS_EPOCH=$FINISHED_EPOCH
LAST_FAILURE_EPOCH=$LAST_FAILURE_EPOCH
STATUS=success
MESSAGE="VPN health check completed successfully."
EOF

        chmod 644 "$STATE_FILE"

        echo "SUCCESS|$FINISHED_EPOCH"
        exit 0

    fi

    cat > "$STATE_FILE" <<EOF
LAST_REQUEST_EPOCH=$CURRENT_EPOCH
LAST_SUCCESS_EPOCH=$LAST_SUCCESS_EPOCH
LAST_FAILURE_EPOCH=$FINISHED_EPOCH
STATUS=failure
MESSAGE="VPN health check failed."
EOF

    chmod 644 "$STATE_FILE"

    echo "FAILURE|$FINISHED_EPOCH"
    exit 4

) 9>"$LOCK_FILE"