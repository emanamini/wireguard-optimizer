#!/usr/bin/env bash

# ============================================================
# WireGuard Optimizer
# Module: 00-endpoint-route.sh
# ============================================================
#
# PURPOSE:
#   Discover IPv4 addresses used by WireGuard endpoints and
#   route those endpoint IPs through the IRTR routing table.
#
# USAGE:
#   ./00-endpoint-route.sh
#       Scan both tun0 and tun1.
#
#   ./00-endpoint-route.sh tun0
#       Scan only tun0.
#
#   ./00-endpoint-route.sh tun1
#       Scan only tun1.
#
# OWNED IP RULE PRIORITIES:
#   800-999 only.
#
#   Rules with priority >= 1000 are NEVER touched.
#
# PERSISTENT OUTPUT:
#   $STATE_DIR/endpoint-ips.txt
#
# FAILURE REPORT:
#   $STATE_DIR/endpoint-route-report.txt
#
# ============================================================

set -u
set -o pipefail

# ============================================================
# Constants
# ============================================================

CONFIG_FILE="/etc/wg-optimizer.conf"

CONFIG_FILE="/etc/wg-optimizer.conf"

STATE_DIR=""

ENDPOINT_IPS_FILE=""
REPORT_FILE=""

TEMP_DIR="/dev/shm/wg-optimizer-endpoint-route"

INTERFACE="wan"
TABLE_NAME="irtr"

MIN_PRIORITY=800
MAX_PRIORITY=999
MAX_ENDPOINTS=200

DNS_TIMEOUT=3
DNS_TRIES=1

# ============================================================
# Runtime state
# ============================================================

SELECTED_INTERFACE=""
SCAN_DIRS=()

TEMP_ENDPOINT_IPS=""
TEMP_REPORT=""
BACKUP_RULES=""

ERROR_MESSAGE=""

RULES_CHANGED="no"
ROUTE_CHANGED="no"

# ============================================================
# Logging
# ============================================================

log_info()
{
    echo "[INFO] $*"
}

log_success()
{
    echo "[SUCCESS] $*"
}

log_warn()
{
    echo "[WARN] $*"
}

log_error()
{
    echo "[ERROR] $*" >&2
}

# ============================================================
# Failure report
# ============================================================

REPORT_LINES=()

report()
{
    REPORT_LINES+=("$*")
}

write_failure_report()
{
    local line

    mkdir -p "$STATE_DIR" 2>/dev/null || true

    : > "$TEMP_REPORT" 2>/dev/null || true

    {
        echo "WireGuard Optimizer - Endpoint Route Report"
        echo "======================================"
        echo
        echo "Status: FAILED"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Script: 00-endpoint-route.sh"
        echo
        echo "Selected interface:"
        if [[ -n "$SELECTED_INTERFACE" ]]; then
            echo "  $SELECTED_INTERFACE"
        else
            echo "  both"
        fi
        echo
        echo "Scan directories:"
        for line in "${SCAN_DIRS[@]}"; do
            echo "  $line"
        done
        echo
        echo "Routing:"
        echo "  Interface: $INTERFACE"
        echo "  Table: $TABLE_NAME"
        echo "  Owned priorities: $MAX_PRIORITY-$MIN_PRIORITY"
        echo
        echo "Endpoint result:"
        if [[ -f "$TEMP_ENDPOINT_IPS" ]]; then
            cat "$TEMP_ENDPOINT_IPS"
        else
            echo "  No temporary endpoint result available."
        fi
        echo
        echo "Details:"
        for line in "${REPORT_LINES[@]}"; do
            echo "$line"
        done
        echo
        echo "Error:"
        echo "  $ERROR_MESSAGE"
    } > "$TEMP_REPORT"

    if [[ -s "$TEMP_REPORT" ]]; then
        mv -f "$TEMP_REPORT" "$REPORT_FILE"
    fi
}

fail()
{
    ERROR_MESSAGE="$*"
    log_error "$ERROR_MESSAGE"

    report "ERROR: $ERROR_MESSAGE"

    write_failure_report

    exit 1
}

# ============================================================
# Cleanup
# ============================================================

cleanup()
{
    local exit_code=$?

    rm -f "$TEMP_ENDPOINT_IPS" 2>/dev/null || true
    rm -f "$TEMP_REPORT" 2>/dev/null || true
    rm -f "$BACKUP_RULES" 2>/dev/null || true

    rmdir "$TEMP_DIR" 2>/dev/null || true

    return "$exit_code"
}

trap cleanup EXIT

# ============================================================
# Rollback
# ============================================================

rollback_rules()
{
    local line
    local priority
    local rule_text

    [[ "$RULES_CHANGED" == "yes" ]] || return 0
    [[ -f "$BACKUP_RULES" ]] || return 0

    log_warn "Attempting to restore previous IRTR rules..."

    while IFS=$'\t' read -r priority rule_text; do
        [[ -n "$priority" ]] || continue
        [[ -n "$rule_text" ]] || continue

        if ip rule show | grep -qE "^${priority}:"; then
            continue
        fi

        if ip rule add priority "$priority" $rule_text 2>/dev/null; then
            log_info "Restored rule at priority $priority"
        else
            log_error "Could not restore rule at priority $priority"
            report "ROLLBACK ERROR: Could not restore priority $priority: $rule_text"
        fi
    done < "$BACKUP_RULES"

    RULES_CHANGED="no"
}

# ============================================================
# Basic validation
# ============================================================

require_root()
{
    if [[ "$EUID" -ne 0 ]]; then
        fail "This script must be run as root."
    fi
}

require_command()
{
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "Required command not found: $command_name"
    fi
}


load_configuration()
{
    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "Configuration file does not exist: $CONFIG_FILE"
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [[ -z "${BASE_DIR:-}" ]]; then
        fail "BASE_DIR is not defined in $CONFIG_FILE"
    fi

    if [[ -z "${STATE_DIR:-}" ]]; then
        fail "STATE_DIR is not defined in $CONFIG_FILE"
    fi

    ENDPOINT_IPS_FILE="$STATE_DIR/endpoint-ips.txt"
    REPORT_FILE="$STATE_DIR/endpoint-route-report.txt"
}

validate_environment()
{
    require_root

    require_command ip
    require_command dig
    require_command awk
    require_command grep
    require_command sed
    require_command sort
    require_command mv
    require_command mkdir
    require_command date

    load_configuration

    if [[ ! -d "$BASE_DIR" ]]; then
        fail "BASE_DIR does not exist: $BASE_DIR"
    fi

    mkdir -p "$STATE_DIR" || fail "Could not create state directory: $STATE_DIR"
    mkdir -p "$TEMP_DIR" || fail "Could not create temporary directory: $TEMP_DIR"

    TEMP_ENDPOINT_IPS="$TEMP_DIR/endpoint-ips.txt"
    TEMP_REPORT="$TEMP_DIR/endpoint-route-report.txt"
    BACKUP_RULES="$TEMP_DIR/previous-irtr-rules.txt"

    # Remove any report from a previous run.
    rm -f "$REPORT_FILE" || fail "Could not remove old failure report."

    # Validate WAN interface.
    if ! ip link show dev "$INTERFACE" >/dev/null 2>&1; then
        fail "WAN interface does not exist: $INTERFACE"
    fi

    # Validate routing table name.
    if ! grep -Eq "[[:space:]]${TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
        fail "Routing table '$TABLE_NAME' is not defined in /etc/iproute2/rt_tables"
    fi
}

# ============================================================
# Argument handling
# ============================================================

select_scan_directories()
{
    case "${1:-}" in
        "")
            SELECTED_INTERFACE=""
            SCAN_DIRS=(
                "$BASE_DIR/tun0"
                "$BASE_DIR/tun1"
            )
            ;;

        tun0)
            SELECTED_INTERFACE="tun0"
            SCAN_DIRS=(
                "$BASE_DIR/tun0"
            )
            ;;

        tun1)
            SELECTED_INTERFACE="tun1"
            SCAN_DIRS=(
                "$BASE_DIR/tun1"
            )
            ;;

        *)
            fail "Invalid interface '$1'. Use tun0, tun1, or no argument."
            ;;
    esac

    report "Selected interface: ${SELECTED_INTERFACE:-both}"

    log_info "Scan mode: ${SELECTED_INTERFACE:-tun0 + tun1}"
}

# ============================================================
# Endpoint extraction
# ============================================================

is_ipv4()
{
    local ip="$1"
    local a b c d

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS='.' read -r a b c d <<< "$ip"

    (( a <= 255 )) &&
    (( b <= 255 )) &&
    (( c <= 255 )) &&
    (( d <= 255 ))
}

extract_endpoint_host()
{
    local endpoint="$1"

    # IPv4:port
    if [[ "$endpoint" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # Hostname:port
    if [[ "$endpoint" =~ ^([^:]+):[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

resolve_hostname()
{
    local hostname="$1"
    local result

    log_info "Resolving hostname: $hostname" >&2
    report "DNS lookup: $hostname"

    result="$(
        dig \
            +short \
            +time="$DNS_TIMEOUT" \
            +tries="$DNS_TRIES" \
            A "$hostname" 2>/dev/null
    )"

    if [[ -z "$result" ]]; then
        report "DNS resolution returned no A records for: $hostname"
        return 1
    fi

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue

        if is_ipv4 "$ip"; then
            echo "$ip"
            report "  $hostname -> $ip"
        fi
    done <<< "$result"
}

collect_endpoint_ips()
{
    local conf
    local endpoint_line
    local endpoint
    local host
    local resolved
    local found_files=0
    local found_endpoints=0
    local resolution_failed=0

    : > "$TEMP_ENDPOINT_IPS" ||
        fail "Could not create temporary endpoint IP file."

    for scan_dir in "${SCAN_DIRS[@]}"; do

        if [[ ! -d "$scan_dir" ]]; then
            fail "Required scan directory does not exist: $scan_dir"
        fi

        log_info "Scanning: $scan_dir"
        report "Scanning directory: $scan_dir"

        while IFS= read -r -d '' conf; do

            found_files=$((found_files + 1))

            log_info "Reading: $conf"
            report "Configuration: $conf"

            while IFS= read -r endpoint_line; do

                [[ -z "$endpoint_line" ]] && continue

                endpoint="$(
                    sed \
                        -E \
                        's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//; s/[[:space:]#].*$//' \
                        <<< "$endpoint_line"
                )"

                [[ -z "$endpoint" ]] && continue

                found_endpoints=$((found_endpoints + 1))

                host="$(extract_endpoint_host "$endpoint")" ||
                    fail "Could not parse WireGuard endpoint '$endpoint' in $conf"

                report "  Endpoint: $endpoint"

                if is_ipv4 "$host"; then

                    log_info "Endpoint IPv4: $host"
                    report "  IPv4 endpoint: $host"

                    echo "$host" >> "$TEMP_ENDPOINT_IPS"

                else

                    resolved="$(resolve_hostname "$host")" || {
                        log_error "Could not resolve endpoint hostname '$host'"
                        report "  DNS resolution FAILED: $host"
                        resolution_failed=1
                        continue
                    }

                    while IFS= read -r ip; do
                        [[ -z "$ip" ]] && continue
                        echo "$ip" >> "$TEMP_ENDPOINT_IPS"
                    done <<< "$resolved"

                fi

            done < <(
                grep -E \
                    '^[[:space:]]*Endpoint[[:space:]]*=' \
                    "$conf" 2>/dev/null
            )

        done < <(
            find "$scan_dir" \
                -maxdepth 1 \
                -type f \
                -name '*.conf' \
                -print0
        )
    done

    if (( found_files == 0 )); then
        fail "No WireGuard configuration files were found."
    fi

    if (( found_endpoints == 0 )); then
        fail "No WireGuard endpoints were found."
    fi

    if (( resolution_failed != 0 )); then
        fail "At least one endpoint hostname could not be resolved."
    fi

    if [[ ! -s "$TEMP_ENDPOINT_IPS" ]]; then
        fail "Endpoint discovery produced no IPv4 addresses."
    fi
}

# ============================================================
# Deduplicate and validate endpoint IPs
# ============================================================

deduplicate_endpoint_ips()
{
    local count

    sort -u "$TEMP_ENDPOINT_IPS" > "${TEMP_ENDPOINT_IPS}.sorted" ||
        fail "Could not sort endpoint IPs."

    mv -f "${TEMP_ENDPOINT_IPS}.sorted" "$TEMP_ENDPOINT_IPS" ||
        fail "Could not finalize deduplicated endpoint IP list."

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue

        if ! is_ipv4 "$ip"; then
            fail "Invalid IPv4 address in endpoint list: $ip"
        fi
    done < "$TEMP_ENDPOINT_IPS"

    count="$(wc -l < "$TEMP_ENDPOINT_IPS")"

    report "Unique endpoint IPv4 count: $count"

    log_info "Unique endpoint IPv4 addresses: $count"

    if (( count > MAX_ENDPOINTS )); then
        fail "Found $count unique endpoint IPv4 addresses. Maximum allowed is $MAX_ENDPOINTS."
    fi

    if (( count == 0 )); then
        fail "No unique endpoint IPv4 addresses remain after deduplication."
    fi
}

# ============================================================
# WAN gateway
# ============================================================

get_wan_gateway()
{
    wanGateway="$(
        ip route show dev "$INTERFACE" |
        grep -oP 'default via \K\S+' |
        head -n 1
    )"

    if [[ -z "$wanGateway" ]]; then
        fail "Could not determine default WAN gateway on $INTERFACE."
    fi

    if ! is_ipv4 "$wanGateway"; then
        fail "WAN gateway is not a valid IPv4 address: $wanGateway"
    fi

    log_info "WAN gateway: $wanGateway"

    report "WAN gateway: $wanGateway"
}

# ============================================================
# Existing owned rules
# ============================================================

collect_owned_rules()
{
    local priority
    local line
    local rule_text

    : > "$BACKUP_RULES" ||
        fail "Could not create routing rule backup."

    log_info "Checking owned rule range $MAX_PRIORITY-$MIN_PRIORITY..."

    while IFS= read -r line; do

        priority="$(awk '{print $1}' <<< "$line" | tr -d ':')"

        [[ "$priority" =~ ^[0-9]+$ ]] || continue

        if (( priority < MIN_PRIORITY || priority > MAX_PRIORITY )); then
            continue
        fi

        # Only our IRTR lookup rules are owned.
        if grep -Eq '[[:space:]]lookup[[:space:]]+irtr([[:space:]]|$)' <<< "$line"; then

            rule_text="$(
                sed -E \
                    's/^[0-9]+:[[:space:]]*//' \
                    <<< "$line"
            )"

            printf '%s\t%s\n' "$priority" "$rule_text" >> "$BACKUP_RULES"

            log_info "Owned existing rule: $line"
            report "Existing owned rule: $line"
        fi

    done < <(ip rule show)

    # Sort by priority so rollback is deterministic.
    sort -n -k1,1 "$BACKUP_RULES" -o "$BACKUP_RULES"
}

# ============================================================
# Remove owned rules
# ============================================================

remove_owned_rules()
{
    local priority

    if [[ ! -s "$BACKUP_RULES" ]]; then
        log_info "No existing owned endpoint rules found."
        report "No existing rules found in owned range $MAX_PRIORITY-$MIN_PRIORITY."
        return 0
    fi

    while IFS=$'\t' read -r priority rule_text; do

        [[ -n "$priority" ]] || continue

        if ip rule del priority "$priority"; then
            log_info "Removed priority $priority"
            report "Removed priority $priority: $rule_text"
        else
            fail "Could not remove existing IRTR rule at priority $priority."
        fi

    done < "$BACKUP_RULES"

    RULES_CHANGED="yes"
}

# ============================================================
# Ensure IRTR default route
# ============================================================

ensure_irtr_default_route()
{
    local exact_route

    exact_route="$(
        ip route show table "$TABLE_NAME" |
        grep -F "default via $wanGateway dev $INTERFACE" |
        head -n 1
    )"

    if [[ -n "$exact_route" ]]; then
        log_info "IRTR default route already exists."
        report "IRTR default route already exists: $exact_route"
        return 0
    fi

    # Do not silently replace an unexpected default route.
    if ip route show table "$TABLE_NAME" | grep -qE '^default[[:space:]]'; then
        fail "IRTR table contains a different default route. Refusing to replace it automatically."
    fi

    if ip route add default via "$wanGateway" dev "$INTERFACE" table "$TABLE_NAME"; then
        log_success "Route for default added."
        report "Added IRTR default route: default via $wanGateway dev $INTERFACE"
        ROUTE_CHANGED="yes"
    else
        fail "Could not add IRTR default route."
    fi
}

# ============================================================
# Add endpoint rules
# ============================================================

add_endpoint_rules()
{
    local priority="$MAX_PRIORITY"
    local ip

    while IFS= read -r ip; do

        [[ -z "$ip" ]] && continue

        if (( priority < MIN_PRIORITY )); then
            fail "Priority range exhausted while adding endpoint rules."
        fi

        log_info "Adding: $priority: to $ip lookup $TABLE_NAME"

        if ! ip rule add priority "$priority" to "$ip" lookup "$TABLE_NAME"; then
            fail "Could not add endpoint rule for $ip at priority $priority."
        fi

        report "Added: $priority: to $ip lookup $TABLE_NAME"

        priority=$((priority - 1))

    done < "$TEMP_ENDPOINT_IPS"

    RULES_CHANGED="yes"
}

# ============================================================
# Verify routing
# ============================================================

verify_irtr_default_route()
{
    if ! ip route show table "$TABLE_NAME" |
        grep -qF "default via $wanGateway dev $INTERFACE"; then

        fail "Verification failed: IRTR default route is missing."
    fi

    log_success "IRTR default route verified."
}

verify_endpoint_rules()
{
    local priority="$MAX_PRIORITY"
    local ip
    local rule

    while IFS= read -r ip; do

        [[ -z "$ip" ]] && continue

        rule="$(ip rule show priority "$priority")"

        if [[ -z "$rule" ]]; then
            fail "Verification failed: no rule exists at priority $priority for $ip."
        fi

        if ! grep -qE "[[:space:]]to[[:space:]]+$ip(/32)?([[:space:]]|$)" <<< "$rule"; then
            fail "Verification failed: priority $priority does not point to $ip. Actual rule: $rule"
        fi

        if ! grep -qE "[[:space:]]lookup[[:space:]]+$TABLE_NAME([[:space:]]|$)" <<< "$rule"; then
            fail "Verification failed: priority $priority does not use table $TABLE_NAME. Actual rule: $rule"
        fi

        log_success "Verified: $priority: to $ip lookup $TABLE_NAME"

        priority=$((priority - 1))

    done < "$TEMP_ENDPOINT_IPS"

    log_success "All endpoint routing rules verified."
}

verify_no_duplicate_endpoint_ips()
{
    local total unique

    total="$(wc -l < "$TEMP_ENDPOINT_IPS")"
    unique="$(sort -u "$TEMP_ENDPOINT_IPS" | wc -l)"

    if [[ "$total" -ne "$unique" ]]; then
        fail "Verification failed: duplicate endpoint IP addresses detected."
    fi

    log_success "Endpoint IP list contains only unique addresses."
}

# ============================================================
# Publish endpoint-ips.txt
# ============================================================

publish_endpoint_ips()
{
    local temp_publish="$TEMP_DIR/endpoint-ips.publish"

    cp "$TEMP_ENDPOINT_IPS" "$temp_publish" ||
        fail "Could not prepare endpoint-ips.txt for atomic replacement."

    # Final uniqueness check before publication.
    if [[ "$(wc -l < "$temp_publish")" -ne "$(sort -u "$temp_publish" | wc -l)" ]]; then
        fail "Final endpoint IP file failed uniqueness validation."
    fi

    mv -f "$temp_publish" "$ENDPOINT_IPS_FILE" ||
        fail "Could not atomically replace $ENDPOINT_IPS_FILE."

    log_success "Published endpoint IP list: $ENDPOINT_IPS_FILE"
    report "Published endpoint IP list: $ENDPOINT_IPS_FILE"
}

# ============================================================
# Main
# ============================================================

main()
{
    validate_environment

    select_scan_directories "${1:-}"

    log_info "Starting endpoint route preparation..."

    # --------------------------------------------------------
    # Phase 1: Discover everything before changing routing.
    # --------------------------------------------------------

    collect_endpoint_ips
    deduplicate_endpoint_ips
    verify_no_duplicate_endpoint_ips

    get_wan_gateway

    # --------------------------------------------------------
    # Phase 2: Snapshot and clean ONLY our owned rule range.
    # --------------------------------------------------------

    collect_owned_rules
    remove_owned_rules

    # --------------------------------------------------------
    # Phase 3: Ensure IRTR has the correct WAN default route.
    # --------------------------------------------------------

    ensure_irtr_default_route

    # --------------------------------------------------------
    # Phase 4: Install fresh endpoint rules.
    # --------------------------------------------------------

    add_endpoint_rules

    # --------------------------------------------------------
    # Phase 5: Verify the complete result.
    # --------------------------------------------------------

    verify_irtr_default_route
    verify_endpoint_rules
    verify_no_duplicate_endpoint_ips

    # --------------------------------------------------------
    # Phase 6: Publish persistent endpoint state atomically.
    # --------------------------------------------------------

    publish_endpoint_ips

    # --------------------------------------------------------
    # Successful run.
    # --------------------------------------------------------

    rm -f "$REPORT_FILE" ||
        fail "Could not remove stale failure report after successful run."

    log_success "Endpoint route preparation completed successfully."
    log_success "Owned priority range: $MAX_PRIORITY-$MIN_PRIORITY"
    log_success "Existing rules at priority >= 1000 were not touched."
    log_success "Endpoint IP file contains unique IPv4 addresses only."

    return 0
}

# ============================================================
# Entry point
# ============================================================

main "$@"
exit $?