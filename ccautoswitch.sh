#!/usr/bin/env bash

# ccautoswitch - Auto-switch Claude Code accounts based on usage limits
# Integrates with ccswitch.sh for multi-account support
#
# Checks current account usage at a configurable interval (default: 20min).
# When usage approaches the session limit (default: ≥97%), switches to
# the least-used available account.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CCSWITCH="$SCRIPT_DIR/ccswitch.sh"
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly AS_LOG_FILE="$BACKUP_DIR/ccautoswitch.log"
readonly AS_STATE_FILE="$BACKUP_DIR/ccautoswitch-state.json"
readonly USAGE_API="https://api.anthropic.com/api/oauth/usage"

# Defaults (overridable via flags)
AS_INTERVAL=20        # minutes
AS_THRESHOLD=97       # usage % to trigger switch
AS_METRIC="five_hour" # five_hour or seven_day
AS_DRY_RUN=false
AS_LOG_LINES=30

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$AS_LOG_FILE")"
    echo "[$ts] [$level] $msg" >> "$AS_LOG_FILE"
    # Always write to stderr so log output doesn't contaminate
    # stdout when functions are called in $() subshells.
    echo "[$ts] [$level] $msg" >&2
}

check_prereqs() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: 'jq' not found. Install with: apt install jq"
        exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: 'curl' not found."
        exit 1
    fi
    if [[ ! -x "$CCSWITCH" ]]; then
        echo "Error: ccswitch.sh not found at $CCSWITCH"
        exit 1
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts managed. Run: ccswitch.sh --add-account"
        exit 1
    fi
}

# Fetch usage for a given access token. Returns JSON or empty on failure.
fetch_usage() {
    local token="$1"
    local response
    response=$(curl --silent --max-time 10 \
        --header "Authorization: Bearer $token" \
        --header "anthropic-beta: oauth-2025-04-20" \
        "$USAGE_API" 2>/dev/null) || { echo ""; return; }

    # Check for API errors
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        local err_type
        err_type=$(echo "$response" | jq -r '.error.type // empty' 2>/dev/null)
        log_msg WARN "Usage API error: $err_type"
        echo ""
        return
    fi

    echo "$response"
}

# Extract utilization % from usage JSON for the configured metric.
# Returns integer (0-100) or empty.
get_utilization() {
    local usage_json="$1"
    local metric="$2"
    if [[ -z "$usage_json" ]]; then
        echo ""
        return
    fi
    local val
    val=$(echo "$usage_json" | jq -r ".${metric}.utilization // empty" 2>/dev/null)
    if [[ -n "$val" && "$val" != "null" ]]; then
        printf "%.0f" "$val"
    else
        echo ""
    fi
}

# Read access token from a credentials JSON string
get_token_from_creds() {
    local creds="$1"
    echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

# Read credentials for an account (active = live file, others = backup)
read_account_creds() {
    local account_num="$1"
    local email="$2"
    local active_account="$3"

    if [[ "$account_num" == "$active_account" ]]; then
        # Read live credentials
        if [[ -f "$HOME/.claude/.credentials.json" ]]; then
            cat "$HOME/.claude/.credentials.json"
        else
            echo ""
        fi
    else
        local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
        if [[ -f "$cred_file" ]]; then
            cat "$cred_file"
        else
            echo ""
        fi
    fi
}

# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

# Check all accounts and return a JSON array of {num, email, utilization, label}
# sorted by utilization ascending.
collect_all_usage() {
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    local accounts_json
    accounts_json=$(jq -r '.accounts | to_entries[] | "\(.key)\t\(.value.email)\t\(.value.label // "")"' "$SEQUENCE_FILE")

    local results="[]"
    while IFS=$'\t' read -r num email label; do
        [[ -z "$num" ]] && continue

        local creds token usage util
        creds=$(read_account_creds "$num" "$email" "$active_account")
        if [[ -z "$creds" ]]; then
            log_msg WARN "Account-$num ($email): no credentials found, skipping"
            continue
        fi

        token=$(get_token_from_creds "$creds")
        if [[ -z "$token" ]]; then
            log_msg WARN "Account-$num ($email): no access token, skipping"
            continue
        fi

        usage=$(fetch_usage "$token")
        util=$(get_utilization "$usage" "$AS_METRIC")

        if [[ -z "$util" ]]; then
            log_msg WARN "Account-$num ($email): could not fetch usage, skipping"
            continue
        fi

        local display="$email"
        [[ -n "$label" ]] && display="$email [$label]"
        log_msg INFO "Account-$num ($display): ${AS_METRIC} usage = ${util}%"

        results=$(echo "$results" | jq -c \
            --arg n "$num" --arg e "$email" --argjson u "$util" --arg l "$label" \
            '. + [{"num": $n, "email": $e, "utilization": $u, "label": $l}]')
    done <<< "$accounts_json"

    echo "$results"
}

# Main check-and-switch logic
cmd_check() {
    check_prereqs

    local active_account active_email
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    active_email=$(jq -r --arg n "$active_account" '.accounts[$n].email // "unknown"' "$SEQUENCE_FILE")
    local active_label
    active_label=$(jq -r --arg n "$active_account" '.accounts[$n].label // ""' "$SEQUENCE_FILE")
    local active_display="$active_email"
    [[ -n "$active_label" && "$active_label" != "null" ]] && active_display="$active_email [$active_label]"

    log_msg INFO "=== Auto-switch check (metric=$AS_METRIC, threshold=${AS_THRESHOLD}%) ==="
    log_msg INFO "Active: Account-$active_account ($active_display)"

    # Step 1: Check current account usage
    local active_creds active_token active_usage active_util
    active_creds=$(read_account_creds "$active_account" "$active_email" "$active_account")
    if [[ -z "$active_creds" ]]; then
        log_msg ERROR "Cannot read active account credentials"
        return 1
    fi

    active_token=$(get_token_from_creds "$active_creds")
    if [[ -z "$active_token" ]]; then
        log_msg ERROR "No access token for active account"
        return 1
    fi

    active_usage=$(fetch_usage "$active_token")
    active_util=$(get_utilization "$active_usage" "$AS_METRIC")

    if [[ -z "$active_util" ]]; then
        log_msg ERROR "Could not fetch usage for active account"
        return 1
    fi

    log_msg INFO "Current usage: ${active_util}% (threshold: ${AS_THRESHOLD}%)"

    # Step 2: Check if we need to switch
    if (( active_util < AS_THRESHOLD )); then
        log_msg INFO "Usage below threshold. No switch needed."
        update_state "$active_account" "$active_email" "$active_util" "" ""
        return 0
    fi

    log_msg INFO "Usage at/above threshold! Checking other accounts..."

    # Step 3: Collect usage for all accounts
    local all_usage
    all_usage=$(collect_all_usage)

    local count
    count=$(echo "$all_usage" | jq 'length')
    if (( count < 2 )); then
        log_msg WARN "Not enough accounts with usage data to switch."
        update_state "$active_account" "$active_email" "$active_util" "" "no_alternatives"
        return 1
    fi

    # Step 4: Find least-used account (excluding current)
    local best
    best=$(echo "$all_usage" | jq -c \
        --arg current "$active_account" \
        '[.[] | select(.num != $current)] | sort_by(.utilization) | first')

    if [[ -z "$best" || "$best" == "null" ]]; then
        log_msg WARN "No alternative accounts available."
        update_state "$active_account" "$active_email" "$active_util" "" "no_alternatives"
        return 1
    fi

    local best_num best_email best_util best_label
    best_num=$(echo "$best" | jq -r '.num')
    best_email=$(echo "$best" | jq -r '.email')
    best_util=$(echo "$best" | jq -r '.utilization')
    best_label=$(echo "$best" | jq -r '.label // ""')

    local best_display="$best_email"
    [[ -n "$best_label" ]] && best_display="$best_email [$best_label]"

    # Don't switch if the best alternative is also above threshold
    if (( best_util >= AS_THRESHOLD )); then
        log_msg WARN "Best alternative Account-$best_num ($best_display) is also at ${best_util}%. All accounts near limit."
        update_state "$active_account" "$active_email" "$active_util" "$best_num" "all_at_limit"
        return 1
    fi

    log_msg INFO "Best alternative: Account-$best_num ($best_display) at ${best_util}%"

    # Step 5: Perform the switch
    if [[ "$AS_DRY_RUN" == "true" ]]; then
        log_msg INFO "[DRY RUN] Would switch to Account-$best_num ($best_display)"
        update_state "$active_account" "$active_email" "$active_util" "$best_num" "dry_run"
        return 0
    fi

    log_msg INFO "Switching to Account-$best_num ($best_display)..."
    if "$CCSWITCH" --to "$best_num" >> "$AS_LOG_FILE" 2>&1; then
        log_msg INFO "Switched to Account-$best_num ($best_display) [${best_util}% usage]"
        update_state "$best_num" "$best_email" "$best_util" "$active_account" "switched"
    else
        log_msg ERROR "Switch to Account-$best_num failed"
        update_state "$active_account" "$active_email" "$active_util" "$best_num" "switch_failed"
        return 1
    fi
}

update_state() {
    local active_num="$1" active_email="$2" active_util="$3"
    local target_num="$4" action="$5"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local state
    state=$(jq -nc \
        --arg ts "$now" \
        --arg an "$active_num" \
        --arg ae "$active_email" \
        --arg au "$active_util" \
        --arg tn "$target_num" \
        --arg act "$action" \
        --arg metric "$AS_METRIC" \
        --argjson threshold "$AS_THRESHOLD" \
        '{
            lastCheck: $ts,
            activeAccount: $an,
            activeEmail: $ae,
            activeUtilization: ($au | tonumber? // null),
            targetAccount: (if $tn == "" then null else $tn end),
            action: (if $act == "" then "no_switch" else $act end),
            metric: $metric,
            threshold: $threshold
        }')
    echo "$state" > "$AS_STATE_FILE"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
    echo "=== ccautoswitch status ==="
    if [[ -f "$AS_STATE_FILE" ]]; then
        local last_check active_num active_email active_util action
        last_check=$(jq -r '.lastCheck // "never"' "$AS_STATE_FILE")
        active_num=$(jq -r '.activeAccount // "?"' "$AS_STATE_FILE")
        active_email=$(jq -r '.activeEmail // "?"' "$AS_STATE_FILE")
        active_util=$(jq -r '.activeUtilization // "?"' "$AS_STATE_FILE")
        action=$(jq -r '.action // "none"' "$AS_STATE_FILE")
        local threshold metric
        threshold=$(jq -r '.threshold // "?"' "$AS_STATE_FILE")
        metric=$(jq -r '.metric // "?"' "$AS_STATE_FILE")

        echo "Last check:   $last_check"
        echo "Active:       Account-$active_num ($active_email)"
        echo "Usage:        ${active_util}% ($metric)"
        echo "Threshold:    ${threshold}%"
        echo "Last action:  $action"
    else
        echo "No state file yet. Run: ccautoswitch.sh --check"
    fi
    echo ""

    # Show cron status
    if crontab -l 2>/dev/null | grep -qF "# ccautoswitch"; then
        echo "Cron: installed"
        crontab -l 2>/dev/null | grep -F "# ccautoswitch" | grep -v "CRON_TZ"
    else
        echo "Cron: not installed"
    fi
}

cmd_log() {
    if [[ -f "$AS_LOG_FILE" ]]; then
        tail -n "${AS_LOG_LINES}" "$AS_LOG_FILE"
    else
        echo "No log file yet."
    fi
}

cmd_cron_install() {
    local script_path
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    local cron_schedule="*/${AS_INTERVAL} * * * *"
    local cron_cmd="PATH='$PATH' $script_path --check"
    # Forward non-default flags to cron
    if (( AS_THRESHOLD != 97 )); then
        cron_cmd+=" --threshold $AS_THRESHOLD"
    fi
    if [[ "$AS_METRIC" != "five_hour" ]]; then
        cron_cmd+=" --metric $AS_METRIC"
    fi
    cron_cmd+=" >> $AS_LOG_FILE 2>&1"
    local cron_marker="# ccautoswitch"

    if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        echo "Cron job already installed. Use 'cron-remove' to uninstall first."
        crontab -l 2>/dev/null | grep -F "$cron_marker"
        return 0
    fi

    (crontab -l 2>/dev/null; echo "$cron_schedule $cron_cmd $cron_marker") | crontab -
    echo "Installed cron job: every ${AS_INTERVAL} minutes"
    echo "  Threshold: ${AS_THRESHOLD}%"
    echo "  Metric:    ${AS_METRIC}"
    echo "  Log:       $AS_LOG_FILE"
}

cmd_cron_remove() {
    local cron_marker="# ccautoswitch"

    if ! crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        echo "No ccautoswitch cron job found."
        return 0
    fi

    crontab -l 2>/dev/null | grep -vF "$cron_marker" | crontab -
    echo "Removed ccautoswitch cron job."
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

show_usage() {
    cat <<'USAGE'
ccautoswitch - Auto-switch Claude Code accounts based on usage limits

Usage: ccautoswitch.sh [COMMAND] [OPTIONS]

Commands:
  --check              Check usage and switch if needed (cron-friendly)
  --status             Show last check result and cron status
  --log [N]            Show last N log lines (default: 30)
  --cron-install       Install cron job (every INTERVAL minutes)
  --cron-remove        Remove cron job
  --help               Show this help

Options:
  --interval MIN       Cron check interval in minutes (default: 20)
  --threshold PCT      Usage % to trigger switch (default: 97)
  --metric METRIC      Usage metric: five_hour or seven_day (default: five_hour)
  --dry-run            Check but don't actually switch

Examples:
  # One-time check with defaults
  ccautoswitch.sh --check

  # Check with custom threshold
  ccautoswitch.sh --check --threshold 90

  # Install cron (every 15min, switch at 95%)
  ccautoswitch.sh --cron-install --interval 15 --threshold 95

  # Dry run to see what would happen
  ccautoswitch.sh --check --dry-run
USAGE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)    command="check"; shift ;;
            --status)   command="status"; shift ;;
            --log)
                command="log"
                shift
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    AS_LOG_LINES="$1"; shift
                fi
                ;;
            --cron-install)  command="cron-install"; shift ;;
            --cron-remove)   command="cron-remove"; shift ;;
            --interval)
                shift
                if [[ $# -eq 0 || ! "$1" =~ ^[0-9]+$ ]]; then
                    echo "Error: --interval requires a numeric value (minutes)"
                    exit 1
                fi
                AS_INTERVAL="$1"; shift
                ;;
            --threshold)
                shift
                if [[ $# -eq 0 || ! "$1" =~ ^[0-9]+$ ]]; then
                    echo "Error: --threshold requires a numeric value (0-100)"
                    exit 1
                fi
                AS_THRESHOLD="$1"; shift
                ;;
            --metric)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Error: --metric requires a value (five_hour or seven_day)"
                    exit 1
                fi
                if [[ "$1" != "five_hour" && "$1" != "seven_day" ]]; then
                    echo "Error: --metric must be 'five_hour' or 'seven_day'"
                    exit 1
                fi
                AS_METRIC="$1"; shift
                ;;
            --dry-run)  AS_DRY_RUN=true; shift ;;
            --help|-h)  show_usage; exit 0 ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$command" ]]; then
        show_usage
        exit 1
    fi

    case "$command" in
        check)        cmd_check ;;
        status)       cmd_status ;;
        log)          cmd_log ;;
        cron-install) cmd_cron_install ;;
        cron-remove)  cmd_cron_remove ;;
    esac
}

main "$@"
