#!/usr/bin/env bash

# ============================================================
# VPN Optimizer
# Module: 01-config-manager.sh
# ============================================================
#
# PURPOSE
#   Prepare WireGuard candidate configurations for one VPN
#   interface.
#
#   The script:
#
#     1. Reads global configuration from:
#          /etc/vpn-optimizer.conf
#
#     2. Receives tun0 or tun1 as its only argument.
#
#     3. Derives the source, temporary, and state paths from
#        the selected interface.
#
#     4. Creates a clean temporary workspace for that interface.
#
#     5. Reads each WireGuard configuration from the interface's
#        source directory.
#
#     6. Extracts the Endpoint.
#
#     7. If the Endpoint is already an IPv4 address, copies the
#        configuration unchanged.
#
#     8. If the Endpoint is a domain name, runs dig and obtains
#        its IPv4 addresses.
#
#     9. Creates one candidate configuration for every IPv4.
#
#    10. Names every candidate after its IPv4 address:
#
#          1.2.3.4.conf
#
#        Therefore, duplicate endpoint IPs automatically result
#        in one candidate file.
#
#    11. Records domain-to-IP relationships in a permanent,
#        interface-specific state file.
#
#
# INPUT
#   Global configuration:
#       /etc/vpn-optimizer.conf
#
#   Command-line argument:
#       tun0
#       tun1
#
#   Source configurations:
#       $BASE_DIR/$INTERFACE/*.conf
#
#
# OUTPUT
#   Temporary candidate configurations:
#       $TEMP_BASE_DIR/$INTERFACE/
#
#   Persistent endpoint state:
#       $STATE_DIR/${INTERFACE}-endpoint-state.txt
#
# ============================================================


# ------------------------------------------------------------
# Basic Bash settings
# ------------------------------------------------------------

set -u


# ------------------------------------------------------------
# Global configuration file
# ------------------------------------------------------------

CONFIG_FILE="/etc/vpn-optimizer.conf"


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
# Check command-line arguments
# ------------------------------------------------------------

if [ "$#" -eq 0 ]; then
    log_error "An interface argument is required."
    log_error "This script must be run with tun0 or tun1."
    log_error "Usage: $0 tun0"
    log_error "Usage: $0 tun1"
    exit 1
fi


if [ "$#" -ne 1 ]; then
    log_error "This script accepts exactly one argument."
    log_error "The argument must be tun0 or tun1."
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
    log_error "This script can only run with tun0 or tun1."
    log_error "Usage: $0 tun0"
    log_error "Usage: $0 tun1"
    exit 1
fi


log_info "Selected interface: $INTERFACE"


# ------------------------------------------------------------
# Read global configuration
# ------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file does not exist: $CONFIG_FILE"
    exit 1
fi


log_info "Reading global configuration from: $CONFIG_FILE"


# shellcheck source=/etc/vpn-optimizer.conf
source "$CONFIG_FILE"


# ------------------------------------------------------------
# Check required configuration values
# ------------------------------------------------------------

if [ -z "${BASE_DIR:-}" ]; then
    log_error "BASE_DIR is not defined in $CONFIG_FILE"
    exit 1
fi


if [ -z "${TEMP_BASE_DIR:-}" ]; then
    log_error "TEMP_BASE_DIR is not defined in $CONFIG_FILE"
    exit 1
fi


if [ -z "${STATE_DIR:-}" ]; then
    log_error "STATE_DIR is not defined in $CONFIG_FILE"
    exit 1
fi


log_info "BASE_DIR: $BASE_DIR"
log_info "TEMP_BASE_DIR: $TEMP_BASE_DIR"
log_info "STATE_DIR: $STATE_DIR"


# ------------------------------------------------------------
# Build interface-specific paths
#
# These paths are deliberately NOT stored in the global
# configuration file. They are derived from the interface
# supplied to this script.
# ------------------------------------------------------------

SOURCE_DIR="$BASE_DIR/$INTERFACE"

TEMP_DIR="$TEMP_BASE_DIR/$INTERFACE"

STATE_FILE="$STATE_DIR/${INTERFACE}-endpoint-state.txt"


log_info "Source directory: $SOURCE_DIR"
log_info "Temporary directory: $TEMP_DIR"
log_info "State file: $STATE_FILE"


# ------------------------------------------------------------
# Check source directory
# ------------------------------------------------------------

if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Source directory does not exist: $SOURCE_DIR"
    exit 1
fi


# ------------------------------------------------------------
# Check required commands
# ------------------------------------------------------------

if ! command -v dig >/dev/null 2>&1; then
    log_error "The 'dig' command is not installed or not in PATH."
    exit 1
fi


# ------------------------------------------------------------
# Prepare temporary workspace
# ------------------------------------------------------------

log_info "Preparing temporary workspace."


if [ -d "$TEMP_DIR" ]; then
    log_info "Previous temporary workspace exists."
    log_info "Removing: $TEMP_DIR"

    rm -rf "$TEMP_DIR"

    if [ $? -ne 0 ]; then
        log_error "Could not remove previous temporary workspace."
        exit 1
    fi

    log_success "Previous temporary workspace removed."
fi


mkdir -p "$TEMP_DIR"

if [ $? -ne 0 ]; then
    log_error "Could not create temporary workspace: $TEMP_DIR"
    exit 1
fi


log_success "Temporary workspace created: $TEMP_DIR"


# ------------------------------------------------------------
# Prepare permanent state directory
# ------------------------------------------------------------

if [ ! -d "$STATE_DIR" ]; then
    log_info "State directory does not exist."
    log_info "Creating: $STATE_DIR"

    mkdir -p "$STATE_DIR"

    if [ $? -ne 0 ]; then
        log_error "Could not create state directory: $STATE_DIR"
        exit 1
    fi

    log_success "State directory created."
fi


# ------------------------------------------------------------
# Remove only the previous state belonging to this interface
# ------------------------------------------------------------

if [ -f "$STATE_FILE" ]; then
    log_info "Previous state file exists:"
    log_info "$STATE_FILE"

    log_info "Removing previous $INTERFACE state."

    rm -f "$STATE_FILE"

    if [ $? -ne 0 ]; then
        log_error "Could not remove previous state file."
        exit 1
    fi

    log_success "Previous $INTERFACE state removed."
fi


touch "$STATE_FILE"

if [ $? -ne 0 ]; then
    log_error "Could not create state file: $STATE_FILE"
    exit 1
fi


log_success "New state file created: $STATE_FILE"


# ------------------------------------------------------------
# Counters
# ------------------------------------------------------------

CONFIG_COUNT=0
CANDIDATE_COUNT=0
RELATIONSHIP_COUNT=0


# ------------------------------------------------------------
# Process configuration files
# ------------------------------------------------------------

log_info "Searching for WireGuard configuration files."
log_info "Source directory: $SOURCE_DIR"


for CONFIG_FILE_PATH in "$SOURCE_DIR"/*.conf; do

    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        continue
    fi


    CONFIG_COUNT=$((CONFIG_COUNT + 1))

    CONFIG_NAME=$(basename "$CONFIG_FILE_PATH")


    log_info "--------------------------------------------------"
    log_info "Processing configuration: $CONFIG_NAME"


    # --------------------------------------------------------
    # Find Endpoint line
    # --------------------------------------------------------

    ENDPOINT_LINE=$(grep -m 1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "$CONFIG_FILE_PATH")


    if [ -z "$ENDPOINT_LINE" ]; then
        log_error "No Endpoint was found in $CONFIG_NAME."
        log_error "Skipping this configuration."
        continue
    fi


    ENDPOINT=$(echo "$ENDPOINT_LINE" | cut -d '=' -f 2- | xargs)


    if [ -z "$ENDPOINT" ]; then
        log_error "Endpoint is empty in $CONFIG_NAME."
        log_error "Skipping this configuration."
        continue
    fi


    log_info "Endpoint: $ENDPOINT"


    # --------------------------------------------------------
    # Separate endpoint host and port
    # --------------------------------------------------------

    ENDPOINT_HOST="$ENDPOINT"
    ENDPOINT_PORT=""


    if [[ "$ENDPOINT" == *:* ]]; then
        ENDPOINT_PORT="${ENDPOINT##*:}"
        ENDPOINT_HOST="${ENDPOINT%:*}"
    fi


    if [ -z "$ENDPOINT_HOST" ]; then
        log_error "Could not determine endpoint host."
        log_error "Skipping $CONFIG_NAME."
        continue
    fi


    log_info "Endpoint host: $ENDPOINT_HOST"


    if [ -n "$ENDPOINT_PORT" ]; then
        log_info "Endpoint port: $ENDPOINT_PORT"
    else
        log_warn "No endpoint port was detected."
    fi


    # --------------------------------------------------------
    # Check whether endpoint is already an IPv4 address
    # --------------------------------------------------------

    if [[ "$ENDPOINT_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

        log_info "Endpoint is already an IPv4 address."


        ENDPOINT_IP="$ENDPOINT_HOST"


        # ----------------------------------------------------
        # Validate IPv4 octets
        # ----------------------------------------------------

        VALID_IPV4=true


        IFS='.' read -r OCTET1 OCTET2 OCTET3 OCTET4 <<< "$ENDPOINT_IP"


        for OCTET in "$OCTET1" "$OCTET2" "$OCTET3" "$OCTET4"; do

            if [ "$OCTET" -gt 255 ]; then
                VALID_IPV4=false
            fi

        done


        if [ "$VALID_IPV4" = false ]; then
            log_error "Invalid IPv4 address: $ENDPOINT_IP"
            log_error "Skipping $CONFIG_NAME."
            continue
        fi


        log_success "Valid IPv4 endpoint: $ENDPOINT_IP"


        # ----------------------------------------------------
        # Copy the original configuration unchanged
        # ----------------------------------------------------

        OUTPUT_FILE="$TEMP_DIR/${ENDPOINT_IP}.conf"


        if [ -f "$OUTPUT_FILE" ]; then
            log_warn "Candidate already exists: ${ENDPOINT_IP}.conf"
            log_warn "Replacing it with configuration: $CONFIG_NAME"
        else
            log_info "Creating candidate: ${ENDPOINT_IP}.conf"
        fi


        cp "$CONFIG_FILE_PATH" "$OUTPUT_FILE"


        if [ $? -ne 0 ]; then
            log_error "Failed to copy $CONFIG_NAME."
            continue
        fi


        CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))


        log_success "Candidate created: $OUTPUT_FILE"


        continue
    fi


    # --------------------------------------------------------
    # Endpoint is a domain name
    # --------------------------------------------------------

    log_info "Endpoint is not an IPv4 address."
    log_info "Resolving domain with dig: $ENDPOINT_HOST"


    DIG_OUTPUT=$(dig +short A "$ENDPOINT_HOST")


    if [ $? -ne 0 ]; then
        log_error "dig failed for: $ENDPOINT_HOST"
        log_error "Skipping $CONFIG_NAME."
        continue
    fi


    FOUND_IPV4=false


    # --------------------------------------------------------
    # Process every IPv4 returned by dig
    # --------------------------------------------------------

    while IFS= read -r RESOLVED_IP; do

        if [ -z "$RESOLVED_IP" ]; then
            continue
        fi


        # ----------------------------------------------------
        # Verify IPv4 format
        # ----------------------------------------------------

        if [[ ! "$RESOLVED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            log_warn "Ignoring non-IPv4 DNS result: $RESOLVED_IP"
            continue
        fi


        VALID_IPV4=true


        IFS='.' read -r OCTET1 OCTET2 OCTET3 OCTET4 <<< "$RESOLVED_IP"


        for OCTET in "$OCTET1" "$OCTET2" "$OCTET3" "$OCTET4"; do

            if [ "$OCTET" -gt 255 ]; then
                VALID_IPV4=false
            fi

        done


        if [ "$VALID_IPV4" = false ]; then
            log_warn "Ignoring invalid IPv4 result: $RESOLVED_IP"
            continue
        fi


        FOUND_IPV4=true


        log_success "Domain $ENDPOINT_HOST resolved to IPv4: $RESOLVED_IP"


        # ----------------------------------------------------
        # Record domain-to-IP relationship
        # ----------------------------------------------------

        printf '%s\t%s\n' "$ENDPOINT_HOST" "$RESOLVED_IP" >> "$STATE_FILE"


        if [ $? -ne 0 ]; then
            log_error "Could not write to state file."
            exit 1
        fi


        RELATIONSHIP_COUNT=$((RELATIONSHIP_COUNT + 1))


        # ----------------------------------------------------
        # Create candidate configuration
        # ----------------------------------------------------

        OUTPUT_FILE="$TEMP_DIR/${RESOLVED_IP}.conf"


        if [ -f "$OUTPUT_FILE" ]; then
            log_warn "Candidate already exists: ${RESOLVED_IP}.conf"
            log_warn "Replacing it with configuration: $CONFIG_NAME"
        else
            log_info "Creating candidate: ${RESOLVED_IP}.conf"
        fi


        NEW_ENDPOINT="${RESOLVED_IP}:${ENDPOINT_PORT}"


        sed "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = $NEW_ENDPOINT|" \
            "$CONFIG_FILE_PATH" > "$OUTPUT_FILE"


        if [ $? -ne 0 ]; then
            log_error "Failed to create candidate for $RESOLVED_IP."

            rm -f "$OUTPUT_FILE"

            continue
        fi


        CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))


        log_success "Candidate created: $OUTPUT_FILE"


    done <<< "$DIG_OUTPUT"


    # --------------------------------------------------------
    # Check whether DNS produced any usable IPv4 addresses
    # --------------------------------------------------------

    if [ "$FOUND_IPV4" = false ]; then
        log_error "No valid IPv4 address was found for: $ENDPOINT_HOST"
        log_error "Skipping $CONFIG_NAME."
    fi

done


# ------------------------------------------------------------
# Remove duplicate domain/IP relationships
# ------------------------------------------------------------

if [ -s "$STATE_FILE" ]; then

    log_info "Removing duplicate domain/IP relationships."


    TEMP_STATE_FILE="${STATE_FILE}.tmp"


    sort -u "$STATE_FILE" > "$TEMP_STATE_FILE"


    if [ $? -ne 0 ]; then
        log_error "Could not sort the state file."
        rm -f "$TEMP_STATE_FILE"
        exit 1
    fi


    mv "$TEMP_STATE_FILE" "$STATE_FILE"


    if [ $? -ne 0 ]; then
        log_error "Could not replace the state file."
        exit 1
    fi


    RELATIONSHIP_COUNT=$(wc -l < "$STATE_FILE")

fi


# ------------------------------------------------------------
# Count final candidate files
# ------------------------------------------------------------

FINAL_CANDIDATE_COUNT=$(find "$TEMP_DIR" -maxdepth 1 -type f -name '*.conf' | wc -l)


# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

log_info "=================================================="
log_info "Configuration preparation completed."
log_info "Interface: $INTERFACE"
log_info "Source configurations processed: $CONFIG_COUNT"
log_info "Final unique candidate configurations: $FINAL_CANDIDATE_COUNT"
log_info "Domain/IP relationships recorded: $RELATIONSHIP_COUNT"
log_info "Temporary candidates: $TEMP_DIR"
log_info "Persistent state: $STATE_FILE"
log_info "=================================================="


# ------------------------------------------------------------
# Final validation
# ------------------------------------------------------------

if [ "$CONFIG_COUNT" -eq 0 ]; then
    log_error "No WireGuard configuration files were found."
    exit 1
fi


if [ "$FINAL_CANDIDATE_COUNT" -eq 0 ]; then
    log_error "No candidate configurations were created."
    exit 1
fi


log_success "01-config-manager.sh completed successfully."

exit 0