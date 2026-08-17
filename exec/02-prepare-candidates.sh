#!/usr/bin/env bash

# ============================================================
# VPN Optimizer
# Module: 02-prepare-candidates.sh
# ============================================================
#
# PURPOSE
#   Prepare candidate WireGuard configurations for temporary
#   testing.
#
#   The original candidate configurations are never modified.
#
#   For each candidate:
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
#   sudo /opt/router/vpn-optimizer/exec/02-prepare-candidates.sh tun0
#
#   sudo /opt/router/vpn-optimizer/exec/02-prepare-candidates.sh tun1
#
# INPUT
#
#   /dev/shm/vpn-optimizer/tun0/*.conf
#   /dev/shm/vpn-optimizer/tun1/*.conf
#
# OUTPUT
#
#   /dev/shm/vpn-optimizer/tun0-tmp/*.conf
#   /dev/shm/vpn-optimizer/tun1-tmp/*.conf
#
# CONFIGURATION
#
#   /etc/vpn-optimizer.conf
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


CONFIG_FILE="/etc/vpn-optimizer.conf"


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


if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

. "$CONFIG_FILE"


SOURCE_DIR="$TEMP_BASE_DIR/$INTERFACE"
OUTPUT_DIR="$TEMP_BASE_DIR/${INTERFACE}-tmp"


if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Candidate directory not found: $SOURCE_DIR"
    exit 1
fi


rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"


for SOURCE_FILE in "$SOURCE_DIR"/*.conf; do

    if [ ! -f "$SOURCE_FILE" ]; then
        continue
    fi

    FILE_NAME=$(basename "$SOURCE_FILE")
    OUTPUT_FILE="$OUTPUT_DIR/$FILE_NAME"


    awk '
    BEGIN {
        in_interface = 0
        table_written = 0
    }


    /^\[Interface\][[:space:]]*$/ {
        in_interface = 1
        print
        next
    }


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

        systemctl stop "wg-quick@$TEMP_INTERFACE.service" >/dev/null 2>&1 || true

        if ip link show "$TEMP_INTERFACE" >/dev/null 2>&1; then

            log_warn "Interface still exists after systemd stop: $TEMP_INTERFACE"
            log_info "Removing interface with ip command: $TEMP_INTERFACE"

            ip link delete "$TEMP_INTERFACE" >/dev/null 2>&1 || true
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


if [ -z "$TUN0_TEMP_INTERFACE" ]; then
    log_error "TUN0_TEMP_INTERFACE is not set in $CONFIG_FILE"
    exit 1
fi


if [ -z "$TUN1_TEMP_INTERFACE" ]; then
    log_error "TUN1_TEMP_INTERFACE is not set in $CONFIG_FILE"
    exit 1
fi


cleanup_temp_interface "$TUN0_TEMP_INTERFACE"
cleanup_temp_interface "$TUN1_TEMP_INTERFACE"


log_success "Candidate preparation completed."
log_info "Output directory: $OUTPUT_DIR"


