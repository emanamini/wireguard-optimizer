#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Module: 01-config-manager.sh
# ============================================================
#
# PURPOSE
#   Prepare WireGuard candidate configurations for one VPN
#   interface and maintain a global domain-to-IPv4 state file.
#
#   The script:
#
#     1. Reads global configuration from:
#          /etc/wg-optimizer.conf
#
#     2. Receives tun0 or tun1 as its only argument.
#
#     3. Derives the source and temporary paths from the
#        selected interface.
#
#     4. Creates a clean temporary workspace for that interface.
#
#     5. Processes WireGuard configurations from BOTH tun0
#        and tun1 directories.
#
#     6. Candidate configurations are created ONLY for the
#        interface supplied as the argument.
#
#     7. If a selected-interface Endpoint is already an IPv4
#        address, the configuration is copied unchanged.
#
#     8. If a selected-interface Endpoint is a domain name,
#        dig obtains its IPv4 addresses.
#
#     9. A candidate configuration is created for every
#        resolved IPv4.
#
#    10. Candidate names use:
#
#          1.2.3.4-51820.conf
#
#        Therefore, the same IPv4/port combination produces
#        one candidate.
#
#    11. Domain-to-IPv4 relationships from BOTH tun0 and tun1
#        are recorded in ONE global state file:
#
#          $STATE_DIR/ip-domain-state.txt
#
#        Format:
#
#          domain.example.com    1.2.3.4
#          domain.example.com    5.6.7.8
#
#        The state file is rebuilt from both interfaces on
#        every execution, regardless of which interface was
#        supplied as the argument.
#
#
# INPUT
#   Global configuration:
#       /etc/wg-optimizer.conf
#
#   Command-line argument:
#       tun0
#       tun1
#
#   Source configurations:
#       $BASE_DIR/tun0/*.conf
#       $BASE_DIR/tun1/*.conf
#
#
# OUTPUT
#   Temporary candidate configurations:
#       $TEMP_BASE_DIR/$INTERFACE/
#
#   Global persistent endpoint state:
#       $STATE_DIR/ip-domain-state.txt
#
# ============================================================


# ------------------------------------------------------------
# Basic Bash settings
# ------------------------------------------------------------

set -u


# ------------------------------------------------------------
# Global configuration file
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


# shellcheck source=/etc/wg-optimizer.conf
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
# Build paths
#
# Candidate paths remain interface-specific.
#
# The endpoint state file is GLOBAL and deliberately does
# NOT depend on the selected interface.
# ------------------------------------------------------------

SOURCE_DIR="$BASE_DIR/$INTERFACE"

TEMP_DIR="$TEMP_BASE_DIR/$INTERFACE"

STATE_FILE="$STATE_DIR/ip-domain-state.txt"


log_info "Candidate source directory: $SOURCE_DIR"
log_info "Temporary candidate directory: $TEMP_DIR"
log_info "Global state file: $STATE_FILE"


# ------------------------------------------------------------
# Check selected source directory
# ------------------------------------------------------------

if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Source directory does not exist: $SOURCE_DIR"
    exit 1
fi


# ------------------------------------------------------------
# Check both interface directories
#
# The state file must always represent BOTH interfaces.
# ------------------------------------------------------------

if [ ! -d "$BASE_DIR/tun0" ]; then
    log_error "Required source directory does not exist: $BASE_DIR/tun0"
    exit 1
fi


if [ ! -d "$BASE_DIR/tun1" ]; then
    log_error "Required source directory does not exist: $BASE_DIR/tun1"
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
# Prepare temporary candidate workspace
#
# ONLY the selected interface's temporary directory is
# touched here.
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
# Rebuild the GLOBAL domain/IP state file
#
# This file represents BOTH tun0 and tun1.
#
# It is deliberately recreated on every execution so that
# stale relationships cannot remain after a configuration
# changes or is removed.
# ------------------------------------------------------------

if [ -f "$STATE_FILE" ]; then
    log_info "Previous global state file exists:"
    log_info "$STATE_FILE"
    log_info "Removing previous global domain/IP state."

    rm -f "$STATE_FILE"

    if [ $? -ne 0 ]; then
        log_error "Could not remove previous global state file."
        exit 1
    fi

    log_success "Previous global state removed."
fi


touch "$STATE_FILE"

if [ $? -ne 0 ]; then
    log_error "Could not create global state file: $STATE_FILE"
    exit 1
fi


log_success "New global state file created: $STATE_FILE"


# ------------------------------------------------------------
# Counters
# ------------------------------------------------------------

CONFIG_COUNT=0
CANDIDATE_COUNT=0
RELATIONSHIP_COUNT=0


# ------------------------------------------------------------
# Process configuration files from BOTH interfaces
#
# Important:
#
#   State collection:
#       tun0 + tun1
#
#   Candidate generation:
#       selected interface ONLY
#
# This keeps the two responsibilities together without
# creating a separate state-processing function.
# ------------------------------------------------------------

for PROCESS_INTERFACE in tun0 tun1; do

    PROCESS_SOURCE_DIR="$BASE_DIR/$PROCESS_INTERFACE"

    log_info "=================================================="
    log_info "Processing interface for global state: $PROCESS_INTERFACE"
    log_info "Source directory: $PROCESS_SOURCE_DIR"
    log_info "=================================================="


    for CONFIG_FILE_PATH in "$PROCESS_SOURCE_DIR"/*.conf; do

        if [ ! -f "$CONFIG_FILE_PATH" ]; then
            continue
        fi


        CONFIG_NAME=$(basename "$CONFIG_FILE_PATH")


        log_info "--------------------------------------------------"
        log_info "Processing configuration: $PROCESS_INTERFACE/$CONFIG_NAME"


        # --------------------------------------------------------
        # Count configurations only for the selected interface.
        #
        # This preserves the original meaning of CONFIG_COUNT.
        # --------------------------------------------------------

        if [ "$PROCESS_INTERFACE" = "$INTERFACE" ]; then
            CONFIG_COUNT=$((CONFIG_COUNT + 1))
        fi


        # --------------------------------------------------------
        # Find Endpoint line
        # --------------------------------------------------------

        ENDPOINT_LINE=$(grep -m 1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "$CONFIG_FILE_PATH")


        if [ -z "$ENDPOINT_LINE" ]; then
            log_error "No Endpoint was found in $CONFIG_NAME."
            log_error "Skipping this configuration."
            continue
        fi


        ENDPOINT=$(echo "$ENDPOINT_LINE" | cut -d '=' -f 2- | tr -d '\r' | xargs)


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


            # ----------------------------------------------------
            # Sanitize endpoint port
            # ----------------------------------------------------

            ENDPOINT_PORT=$(printf '%s' "$ENDPOINT_PORT" | tr -d '\r\n')


            # ----------------------------------------------------
            # Validate endpoint port format
            # ----------------------------------------------------

            if [[ ! "$ENDPOINT_PORT" =~ ^[0-9]+$ ]]; then
                log_error "Invalid endpoint port: [$ENDPOINT_PORT]"
                log_error "Port must contain digits only."
                log_error "Skipping configuration: $CONFIG_NAME"
                continue
            fi


            # ----------------------------------------------------
            # Validate endpoint port range
            # ----------------------------------------------------

            if (( 10#$ENDPOINT_PORT < 1 || 10#$ENDPOINT_PORT > 65535 )); then
                log_error "Invalid endpoint port: [$ENDPOINT_PORT]"
                log_error "Port must be between 1 and 65535."
                log_error "Skipping configuration: $CONFIG_NAME"
                continue
            fi

        else

            log_error "No endpoint port was detected: $ENDPOINT"
            log_error "Skipping configuration: $CONFIG_NAME"
            continue

        fi


        if [ -z "$ENDPOINT_HOST" ]; then
            log_error "Could not determine endpoint host."
            log_error "Skipping $CONFIG_NAME."
            continue
        fi


        log_info "Endpoint host: $ENDPOINT_HOST"
        log_success "Valid endpoint port: $ENDPOINT_PORT"


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
            # Candidate generation ONLY for selected interface.
            #
            # This remains unchanged in behavior.
            # ----------------------------------------------------

            if [ "$PROCESS_INTERFACE" != "$INTERFACE" ]; then
                continue
            fi


            # ----------------------------------------------------
            # Copy the original configuration unchanged
            # ----------------------------------------------------

            OUTPUT_FILE="$TEMP_DIR/${ENDPOINT_IP}-${ENDPOINT_PORT}.conf"

            OUTPUT_BASENAME=$(basename "$OUTPUT_FILE")


            if [[ ! "$OUTPUT_BASENAME" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-[0-9]+\.conf$ ]]; then
                log_error "Generated candidate filename failed validation: [$OUTPUT_BASENAME]"
                log_error "Skipping configuration: $CONFIG_NAME"
                continue
            fi


            if [ -f "$OUTPUT_FILE" ]; then
                log_warn "Candidate already exists: ${ENDPOINT_IP}-${ENDPOINT_PORT}.conf"
                log_warn "Replacing it with configuration: $CONFIG_NAME"
            else
                log_info "Creating candidate: ${ENDPOINT_IP}-${ENDPOINT_PORT}.conf"
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
        #
        # This DNS resolution is performed for BOTH interfaces
        # because the global state file must contain relationships
        # from both interfaces.
        # --------------------------------------------------------

        log_info "Endpoint is not an IPv4 address."
        log_info "Resolving domain with dig: $ENDPOINT_HOST"


        DIG_OUTPUT=$(dig +short +time=3 +tries=1 A "$ENDPOINT_HOST")


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
            # Record GLOBAL domain-to-IP relationship.
            #
            # This happens for BOTH tun0 and tun1.
            #
            # Format:
            #
            #   domain<TAB>IPv4
            # ----------------------------------------------------

            printf '%s\t%s\n' "$ENDPOINT_HOST" "$RESOLVED_IP" >> "$STATE_FILE"


            if [ $? -ne 0 ]; then
                log_error "Could not write to global state file."
                exit 1
            fi


            RELATIONSHIP_COUNT=$((RELATIONSHIP_COUNT + 1))


            # ----------------------------------------------------
            # Candidate generation ONLY for selected interface.
            #
            # The state relationship above is global.
            # Everything below remains interface-specific.
            # ----------------------------------------------------

            if [ "$PROCESS_INTERFACE" != "$INTERFACE" ]; then
                continue
            fi


            # ----------------------------------------------------
            # Create candidate configuration
            # ----------------------------------------------------

            OUTPUT_FILE="$TEMP_DIR/${RESOLVED_IP}-${ENDPOINT_PORT}.conf"

            OUTPUT_BASENAME=$(basename "$OUTPUT_FILE")


            if [[ ! "$OUTPUT_BASENAME" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-[0-9]+\.conf$ ]]; then
                log_error "Generated candidate filename failed validation: [$OUTPUT_BASENAME]"
                log_error "Skipping configuration: $CONFIG_NAME"
                continue
            fi


            if [ -f "$OUTPUT_FILE" ]; then
                log_warn "Candidate already exists: ${RESOLVED_IP}-${ENDPOINT_PORT}.conf"
                log_warn "Replacing it with configuration: $CONFIG_NAME"
            else
                log_info "Creating candidate: ${RESOLVED_IP}-${ENDPOINT_PORT}.conf"
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

done


# ------------------------------------------------------------
# Remove duplicate domain/IP relationships
# ------------------------------------------------------------

if [ -s "$STATE_FILE" ]; then

    log_info "Removing duplicate global domain/IP relationships."


    TEMP_STATE_FILE="${STATE_FILE}.tmp"


    sort -u "$STATE_FILE" > "$TEMP_STATE_FILE"


    if [ $? -ne 0 ]; then
        log_error "Could not sort the global state file."
        rm -f "$TEMP_STATE_FILE"
        exit 1
    fi


    mv "$TEMP_STATE_FILE" "$STATE_FILE"


    if [ $? -ne 0 ]; then
        log_error "Could not replace the global state file."
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
log_info "Selected interface: $INTERFACE"
log_info "Source configurations processed: $CONFIG_COUNT"
log_info "Final unique candidate configurations: $FINAL_CANDIDATE_COUNT"
log_info "Global domain/IP relationships: $RELATIONSHIP_COUNT"
log_info "Temporary candidates: $TEMP_DIR"
log_info "Global persistent state: $STATE_FILE"
log_info "State includes: tun0 + tun1"
log_info "=================================================="


# ------------------------------------------------------------
# Final validation
# ------------------------------------------------------------

if [ "$CONFIG_COUNT" -eq 0 ]; then
    log_error "No WireGuard configuration files were found for $INTERFACE."
    exit 1
fi


if [ "$FINAL_CANDIDATE_COUNT" -eq 0 ]; then
    log_error "No candidate configurations were created for $INTERFACE."
    exit 1
fi


log_success "01-config-manager.sh completed successfully."

exit 0