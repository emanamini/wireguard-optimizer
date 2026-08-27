#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Module: 03-prepare-candidates.sh
# ============================================================
#
# PURPOSE
#
#   Prepare candidate WireGuard configurations for temporary
#   testing.
#
#   The original candidate configurations are never modified.
#
#   Candidate identity is:
#
#       IPv4 + PORT
#
#   Therefore every valid candidate filename MUST be:
#
#       IPv4-PORT.conf
#
#   Example:
#
#       94.139.180.250-51860.conf
#
#   For each valid candidate:
#
#     1. Comment active DNS directives.
#     2. Comment active PostUp directives.
#     3. Comment active PostDown directives.
#     4. Set Table = off inside [Interface].
#
#   This prevents a temporary WireGuard candidate from:
#
#     - configuring DNS
#     - running PostUp commands
#     - running PostDown commands
#     - installing routes into the system routing table
#
# USAGE
#
#   sudo /opt/router/wg-optimizer/exec/02-prepare-candidates.sh tun0
#
#   sudo /opt/router/wg-optimizer/exec/02-prepare-candidates.sh tun1
#
# INPUT
#
#   /dev/shm/wg-optimizer/tun0/*.conf
#   /dev/shm/wg-optimizer/tun1/*.conf
#
#   Every candidate filename MUST be:
#
#       IPv4-PORT.conf
#
# OUTPUT
#
#   /dev/shm/wg-optimizer/tun0-tmp/*.conf
#   /dev/shm/wg-optimizer/tun1-tmp/*.conf
#
# CONFIGURATION
#
#   /etc/wg-optimizer.conf
#
# ============================================================

set -e


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
# Configuration
# ------------------------------------------------------------

CONFIG_FILE="/etc/wg-optimizer.conf"


# ------------------------------------------------------------
# Validate arguments
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
# Load configuration
# ------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

. "$CONFIG_FILE"


# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------

SOURCE_DIR="$TEMP_BASE_DIR/$INTERFACE"
OUTPUT_DIR="$TEMP_BASE_DIR/${INTERFACE}-tmp"


if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Candidate directory not found: $SOURCE_DIR"
    exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"


# ------------------------------------------------------------
# Validate candidate filename
#
# Required format:
#
#     IPv4-PORT.conf
#
# Example:
#
#     94.139.180.250-51860.conf
# ------------------------------------------------------------

validate_candidate_filename()
{
    local filename="$1"
    local identity
    local ip
    local port
    local octet
    local octets
    local value

    # Must end in .conf.
    case "$filename" in
        *.conf)
            ;;
        *)
            return 1
            ;;
    esac

    identity="${filename%.conf}"

    # Must contain exactly one final "-".
    case "$identity" in
        *-*)
            ;;
        *)
            return 1
            ;;
    esac

    ip="${identity%-*}"
    port="${identity##*-}"

    # IP and port must both exist.
    if [ -z "$ip" ] || [ -z "$port" ]; then
        return 1
    fi

    # --------------------------------------------------------
    # Validate IPv4
    # --------------------------------------------------------

    # IPv4 must contain exactly four decimal octets.
    IFS='.' read -r -a octets <<< "$ip"

    if [ "${#octets[@]}" -ne 4 ]; then
        return 1
    fi

    for octet in "${octets[@]}"; do

        # Empty octet.
        if [ -z "$octet" ]; then
            return 1
        fi

        # Digits only.
        case "$octet" in
            *[!0-9]*)
                return 1
                ;;
        esac

        # No leading "+" or "-" is possible because of the
        # digits-only check above.

        value=$((10#$octet))

        if [ "$value" -gt 255 ]; then
            return 1
        fi
    done


    # --------------------------------------------------------
    # Validate port
    # --------------------------------------------------------

    # Port must contain digits only.
    case "$port" in
        *[!0-9]*)
            return 1
            ;;
    esac

    # Port must not be empty.
    if [ -z "$port" ]; then
        return 1
    fi

    # Prevent arithmetic issues with unusual values.
    # The filename has already been restricted to digits.
    value=$((10#$port))

    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        return 1
    fi

    return 0
}


# ------------------------------------------------------------
# Prepare candidates
# ------------------------------------------------------------

for SOURCE_FILE in "$SOURCE_DIR"/*.conf; do

    if [ ! -f "$SOURCE_FILE" ]; then
        continue
    fi

    FILE_NAME=$(basename "$SOURCE_FILE")

    # --------------------------------------------------------
    # Candidate filename is now part of candidate identity.
    #
    # Do not allow malformed candidates into the temporary
    # testing directory.
    # --------------------------------------------------------

    if ! validate_candidate_filename "$FILE_NAME"; then
        log_warn "Skipping malformed candidate filename: $FILE_NAME"
        continue
    fi

    OUTPUT_FILE="$OUTPUT_DIR/$FILE_NAME"


    # --------------------------------------------------------
    # Prepare temporary WireGuard configuration.
    #
    # The source configuration is NEVER modified.
    # --------------------------------------------------------

    awk '

    BEGIN {
        in_interface = 0
        table_written = 0
    }


    # --------------------------------------------------------
    # [Interface] section
    # --------------------------------------------------------

    /^\[Interface\][[:space:]]*$/ {
        in_interface = 1
        print
        next
    }


    # --------------------------------------------------------
    # Any other section
    # --------------------------------------------------------

    /^\[[^]]+\][[:space:]]*$/ {
        in_interface = 0
        print
        next
    }


    {
        if (in_interface) {

            # ------------------------------------------------
            # Disable active DNS directives.
            # ------------------------------------------------

            if ($0 ~ /^[[:space:]]*DNS[[:space:]]*=/) {
                print "# " $0
                next
            }


            # ------------------------------------------------
            # Disable active PostUp directives.
            # ------------------------------------------------

            if ($0 ~ /^[[:space:]]*PostUp[[:space:]]*=/) {
                print "# " $0
                next
            }


            # ------------------------------------------------
            # Disable active PostDown directives.
            # ------------------------------------------------

            if ($0 ~ /^[[:space:]]*PostDown[[:space:]]*=/) {
                print "# " $0
                next
            }


            # ------------------------------------------------
            # Handle active Table directive.
            # ------------------------------------------------

            if ($0 ~ /^[[:space:]]*Table[[:space:]]*=/) {

                if (!table_written) {
                    print "Table = off"
                    table_written = 1
                }

                next
            }


            # ------------------------------------------------
            # Handle commented Table directive.
            # ------------------------------------------------

            if ($0 ~ /^[[:space:]]*#[[:space:]]*Table[[:space:]]*=/) {

                if (!table_written) {
                    print "Table = off"
                    table_written = 1
                }

                next
            }


            # ------------------------------------------------
            # Add Table = off immediately after Address.
            # ------------------------------------------------

            if ($0 ~ /^[[:space:]]*Address[[:space:]]*=/) {

                print

                if (!table_written) {
                    print "Table = off"
                    table_written = 1
                }

                next
            }
        }

        print
    }

    ' "$SOURCE_FILE" > "$OUTPUT_FILE"


    # --------------------------------------------------------
    # Final output validation.
    #
    # Make absolutely sure the temporary filename still
    # represents a valid IPv4 + port candidate.
    # --------------------------------------------------------

    if [ ! -f "$OUTPUT_FILE" ]; then
        log_error "Failed to create temporary candidate: $FILE_NAME"
        exit 1
    fi

    if [ "$(basename "$OUTPUT_FILE")" != "$FILE_NAME" ]; then
        log_error "Temporary candidate filename mismatch: $FILE_NAME"
        rm -f "$OUTPUT_FILE"
        continue
    fi

    log_info "Prepared: $FILE_NAME"

done


# ------------------------------------------------------------
# Clean up temporary WireGuard interfaces
# ------------------------------------------------------------

cleanup_temp_interface()
{
    TEMP_INTERFACE="$1"

    if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then

        log_warn "Temporary interface exists: $TEMP_INTERFACE"

        log_info "Stopping wg-quick service: wg-quick@$TEMP_INTERFACE.service"

        systemctl stop "wg-quick@$TEMP_INTERFACE.service" \
            >/dev/null 2>&1 || true

        if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then

            log_warn "Interface still exists after systemd stop: $TEMP_INTERFACE"

            log_info "Removing interface with ip command: $TEMP_INTERFACE"

            ip link delete "$TEMP_INTERFACE" \
                >/dev/null 2>&1 || true
        fi

        if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then

            log_error "Failed to remove temporary interface: $TEMP_INTERFACE"

            return 1
        fi

        log_success "Temporary interface removed: $TEMP_INTERFACE"

    else

        log_info "Temporary interface is already free: $TEMP_INTERFACE"

    fi
}


# ------------------------------------------------------------
# Validate temporary interface configuration
# ------------------------------------------------------------

if [ -z "$TUN0_TEMP_INTERFACE" ]; then
    log_error "TUN0_TEMP_INTERFACE is not set in $CONFIG_FILE"
    exit 1
fi

if [ -z "$TUN1_TEMP_INTERFACE" ]; then
    log_error "TUN1_TEMP_INTERFACE is not set in $CONFIG_FILE"
    exit 1
fi


# ------------------------------------------------------------
# Clean up both temporary interfaces
# ------------------------------------------------------------

cleanup_temp_interface "$TUN0_TEMP_INTERFACE"

cleanup_temp_interface "$TUN1_TEMP_INTERFACE"


# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------

log_success "Candidate preparation completed."
log_info "Input directory:  $SOURCE_DIR"
log_info "Output directory: $OUTPUT_DIR"