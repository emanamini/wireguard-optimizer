#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Module: 02-candidate-conflict-filter.sh
# ============================================================
#
# PURPOSE
#
# Remove candidate configurations that conflict with the
# endpoint currently used by the OTHER production interface.
#
# The conflict rule is controlled by:
#
#     /etc/wg-optimizer.conf
#
#     CANDIDATE_CONFLICT_MODE
#
# Supported modes:
#
#     ip
#         Same endpoint IP = conflict, regardless of port.
#
#     ip-port
#         Same endpoint IP AND port = conflict.
#
#     domain
#         Same VPN domain = conflict.
#         The domain/IP relationships are read from:
#
#         $STATE_DIR/ip-domain-state.txt
#
# ============================================================


set -u


# ------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------

CONFIG_FILE="/etc/wg-optimizer.conf"


# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

log_info()
{
    echo "[INFO] $1"
}

log_warn()
{
    echo "[WARN] $1"
}

log_error()
{
    echo "[ERROR] $1"
}

log_success()
{
    echo "[SUCCESS] $1"
}


# ------------------------------------------------------------
# Check argument
# ------------------------------------------------------------

if [ "$#" -ne 1 ]; then
    log_error "Exactly one interface argument is required."
    log_error "Usage: $0 tun0"
    log_error "Usage: $0 tun1"
    exit 1
fi

INTERFACE="$1"


# ------------------------------------------------------------
# Validate interface
# ------------------------------------------------------------

if [ "$INTERFACE" != "tun0" ] && [ "$INTERFACE" != "tun1" ]; then
    log_error "Invalid interface: $INTERFACE"
    log_error "The interface must be tun0 or tun1."
    exit 1
fi


# ------------------------------------------------------------
# Determine the other production interface
# ------------------------------------------------------------

if [ "$INTERFACE" = "tun0" ]; then
    OTHER_INTERFACE="tun1"
else
    OTHER_INTERFACE="tun0"
fi


# ------------------------------------------------------------
# Read global configuration
# ------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file does not exist: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"


# ------------------------------------------------------------
# Check required configuration
# ------------------------------------------------------------

if [ -z "${BASE_DIR:-}" ]; then
    log_error "BASE_DIR is not defined."
    exit 1
fi

if [ -z "${TEMP_BASE_DIR:-}" ]; then
    log_error "TEMP_BASE_DIR is not defined."
    exit 1
fi

if [ -z "${STATE_DIR:-}" ]; then
    log_error "STATE_DIR is not defined."
    exit 1
fi

if [ -z "${CANDIDATE_CONFLICT_MODE:-}" ]; then
    log_error "CANDIDATE_CONFLICT_MODE is not defined."
    exit 1
fi


# ------------------------------------------------------------
# Validate conflict mode
# ------------------------------------------------------------

case "$CANDIDATE_CONFLICT_MODE" in

    ip)
        ;;

    ip-port)
        ;;

    domain)
        ;;

    *)
        log_error "Invalid CANDIDATE_CONFLICT_MODE: $CANDIDATE_CONFLICT_MODE"
        log_error "Allowed values: ip, ip-port, domain"
        exit 1
        ;;

esac


# ------------------------------------------------------------
# Build paths
# ------------------------------------------------------------

CANDIDATE_DIR="$TEMP_BASE_DIR/$INTERFACE"
OTHER_CONFIG="/etc/wireguard/${OTHER_INTERFACE}.conf"
STATE_FILE="$STATE_DIR/ip-domain-state.txt"


# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

if [ ! -d "$CANDIDATE_DIR" ]; then
    log_error "Candidate directory does not exist: $CANDIDATE_DIR"
    exit 1
fi

if [ ! -f "$OTHER_CONFIG" ]; then
    log_warn "Other production configuration does not exist: $OTHER_CONFIG"
    log_info "No other production interface configuration is available."
    log_info "No conflicts can exist. All candidates remain valid."
    exit 0
fi


# ------------------------------------------------------------
# Find Endpoint in the other production configuration
# ------------------------------------------------------------

ENDPOINT_LINE=$(grep -m 1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "$OTHER_CONFIG")

if [ -z "$ENDPOINT_LINE" ]; then
    log_error "No Endpoint was found in $OTHER_CONFIG"
    exit 1
fi

OTHER_ENDPOINT=$(printf '%s\n' "$ENDPOINT_LINE" | cut -d '=' -f 2- | tr -d '\r' | xargs)

if [ -z "$OTHER_ENDPOINT" ]; then
    log_error "The Endpoint in $OTHER_CONFIG is empty."
    exit 1
fi


# ------------------------------------------------------------
# Separate endpoint host and port
# ------------------------------------------------------------

OTHER_HOST="$OTHER_ENDPOINT"
OTHER_PORT=""

if [[ "$OTHER_ENDPOINT" == *:* ]]; then
    OTHER_PORT="${OTHER_ENDPOINT##*:}"
    OTHER_HOST="${OTHER_ENDPOINT%:*}"
fi

if [ -z "$OTHER_HOST" ]; then
    log_error "Could not determine the other endpoint host."
    exit 1
fi


# ------------------------------------------------------------
# Determine whether the other endpoint is IPv4
# ------------------------------------------------------------

OTHER_IS_IPV4=false

if [[ "$OTHER_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    OTHER_IS_IPV4=true
fi


# ============================================================
# IP MODE
# ============================================================
#
# State file is NOT used.
#
# Remove every candidate whose filename starts with:
#
#     OTHER_HOST-
#
# Example:
#
#     Other endpoint:
#         94.139.180.250:51861
#
# Remove:
#
#     94.139.180.250-51820.conf
#     94.139.180.250-51860.conf
#     94.139.180.250-51861.conf
#
# ============================================================

if [ "$CANDIDATE_CONFLICT_MODE" = "ip" ]; then

    if [ "$OTHER_IS_IPV4" = false ]; then
        log_info "Other production endpoint is a domain."
        log_info "IP conflict mode ignores domain endpoints."
        log_info "No candidates will be removed."
        exit 0
    fi

    log_info "Conflict mode: ip"
    log_info "Other production interface: $OTHER_INTERFACE"
    log_info "Other production endpoint: $OTHER_ENDPOINT"
    log_info "Conflicting IP: $OTHER_HOST"

    REMOVED_COUNT=0

    for CANDIDATE_FILE in "$CANDIDATE_DIR"/*.conf; do

        [ -f "$CANDIDATE_FILE" ] || continue

        CANDIDATE_NAME=$(basename "$CANDIDATE_FILE")

        if [[ "$CANDIDATE_NAME" == "$OTHER_HOST-"* ]]; then

            log_info "Removing conflicting candidate: $CANDIDATE_NAME"

            rm -f "$CANDIDATE_FILE"

            if [ $? -ne 0 ]; then
                log_error "Failed to remove: $CANDIDATE_FILE"
                exit 1
            fi

            REMOVED_COUNT=$((REMOVED_COUNT + 1))
        fi

    done

    log_success "IP conflict filtering completed."
    log_info "Candidates removed: $REMOVED_COUNT"

    exit 0
fi


# ============================================================
# IP-PORT MODE
# ============================================================
#
# State file is NOT used.
#
# Remove only the candidate whose filename exactly matches:
#
#     IP-PORT.conf
#
# ============================================================

if [ "$CANDIDATE_CONFLICT_MODE" = "ip-port" ]; then

    if [ "$OTHER_IS_IPV4" = false ]; then
        log_info "Other production endpoint is a domain."
        log_info "IP-port conflict mode ignores domain endpoints."
        log_info "No candidates will be removed."
        exit 0
    fi

    if [ -z "$OTHER_PORT" ]; then
        log_error "No endpoint port was found in $OTHER_CONFIG"
        exit 1
    fi

    CANDIDATE_FILE="$CANDIDATE_DIR/${OTHER_HOST}-${OTHER_PORT}.conf"

    log_info "Conflict mode: ip-port"
    log_info "Other production interface: $OTHER_INTERFACE"
    log_info "Other production endpoint: $OTHER_ENDPOINT"
    log_info "Conflicting candidate: $(basename "$CANDIDATE_FILE")"

    if [ -f "$CANDIDATE_FILE" ]; then

        log_info "Removing conflicting candidate."

        rm -f "$CANDIDATE_FILE"

        if [ $? -ne 0 ]; then
            log_error "Failed to remove: $CANDIDATE_FILE"
            exit 1
        fi

        log_success "Conflicting candidate removed."
    else
        log_info "No conflicting candidate exists."
    fi

    exit 0
fi


# ============================================================
# DOMAIN MODE
# ============================================================
#
# The state file is used ONLY in this mode.
#
# Case 1:
#
# Other endpoint is a domain.
#
#     domain
#         |
#         +-- state file
#                 |
#                 +-- all IPs belonging to domain
#
# Case 2:
#
# Other endpoint is already an IPv4.
#
#     IP
#      |
#      +-- state file
#              |
#              +-- find domain belonging to IP
#                      |
#                      +-- all IPs belonging to domain
#
# All candidate files using those IPs are removed,
# regardless of their ports.
#
# ============================================================

if [ "$CANDIDATE_CONFLICT_MODE" = "domain" ]; then

    if [ ! -f "$STATE_FILE" ]; then
        log_info "Global state file does not exist."
        log_info "No domain/IP relationship is available."
        log_info "No candidates will be removed."
        exit 0
    fi

    log_info "Conflict mode: domain"
    log_info "Other production interface: $OTHER_INTERFACE"
    log_info "Other production endpoint: $OTHER_ENDPOINT"

    CONFLICT_DOMAIN=""

    # --------------------------------------------------------
    # Other endpoint is already a domain.
    # --------------------------------------------------------

    if [ "$OTHER_IS_IPV4" = false ]; then

        CONFLICT_DOMAIN="$OTHER_HOST"

        log_info "Other endpoint is a domain: $CONFLICT_DOMAIN"

    # --------------------------------------------------------
    # Other endpoint is an IPv4.
    #
    # Find which domain owns this IP in the state file.
    # --------------------------------------------------------

    else

        log_info "Other endpoint is an IPv4: $OTHER_HOST"
        log_info "Searching state file for its domain."

        CONFLICT_DOMAIN=$(awk -v ip="$OTHER_HOST" '
            $2 == ip {
                print $1
                exit
            }
        ' "$STATE_FILE")

        if [ -z "$CONFLICT_DOMAIN" ]; then
            log_info "No domain relationship found for $OTHER_HOST."
            log_info "No candidates will be removed."
            exit 0
        fi

        log_info "IP belongs to domain: $CONFLICT_DOMAIN"
    fi


    # --------------------------------------------------------
    # Find every IP belonging to the conflict domain.
    # --------------------------------------------------------

    CONFLICT_IPS=$(awk -v domain="$CONFLICT_DOMAIN" '
        $1 == domain {
            print $2
        }
    ' "$STATE_FILE" | sort -u)


    if [ -z "$CONFLICT_IPS" ]; then
        log_info "No IP addresses are associated with $CONFLICT_DOMAIN."
        log_info "No candidates will be removed."
        exit 0
    fi


    log_info "IP addresses belonging to $CONFLICT_DOMAIN:"

    while IFS= read -r CONFLICT_IP; do
        [ -n "$CONFLICT_IP" ] || continue
        log_info "  $CONFLICT_IP"
    done <<< "$CONFLICT_IPS"


    # --------------------------------------------------------
    # Remove every candidate using any of those IPs.
    # Port does not matter in domain mode.
    # --------------------------------------------------------

    REMOVED_COUNT=0

    for CANDIDATE_FILE in "$CANDIDATE_DIR"/*.conf; do

        [ -f "$CANDIDATE_FILE" ] || continue

        CANDIDATE_NAME=$(basename "$CANDIDATE_FILE")

        for CONFLICT_IP in $CONFLICT_IPS; do

            if [[ "$CANDIDATE_NAME" == "$CONFLICT_IP-"* ]]; then

                log_info "Removing conflicting candidate: $CANDIDATE_NAME"

                rm -f "$CANDIDATE_FILE"

                if [ $? -ne 0 ]; then
                    log_error "Failed to remove: $CANDIDATE_FILE"
                    exit 1
                fi

                REMOVED_COUNT=$((REMOVED_COUNT + 1))

                break
            fi

        done

    done


    # --------------------------------------------------------
    # Final result
    # --------------------------------------------------------

    log_success "Domain conflict filtering completed."
    log_info "Conflict domain: $CONFLICT_DOMAIN"
    log_info "Candidates removed: $REMOVED_COUNT"

    exit 0
fi


# ------------------------------------------------------------
# This point should never be reached.
# ------------------------------------------------------------

log_error "Unexpected execution path."
exit 1