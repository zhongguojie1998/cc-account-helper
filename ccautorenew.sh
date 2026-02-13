#!/usr/bin/env bash

# ccautorenew - Auto-renewal for Claude Code 5-hour sessions
# Integrates with ccswitch.sh for multi-account support
#
# Sends a minimal message ("hi") using the cheapest model (haiku)
# to each managed account, starting the 5-hour usage window at
# a predictable time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CCSWITCH="$SCRIPT_DIR/ccswitch.sh"
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly AR_PID_FILE="$BACKUP_DIR/ccautorenew.pid"
readonly AR_LOG_FILE="$BACKUP_DIR/ccautorenew.log"
readonly AR_STATE_FILE="$BACKUP_DIR/ccautorenew-state.json"

# Defaults (overridable via flags)
AR_INTERVAL_HOURS=5
AR_MODEL="haiku"
AR_MESSAGE="hi"
AR_AT_TIME=""
AR_ACCOUNTS="all"
AR_LOG_LINES=20

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$AR_LOG_FILE"
    if [[ "$level" == "ERROR" ]]; then
        echo "[$ts] [$level] $msg" >&2
    else
        echo "[$ts] [$level] $msg"
    fi
}

check_prereqs() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: 'jq' not found. Install with: apt install jq"
        exit 1
    fi
    if ! command -v claude >/dev/null 2>&1; then
        echo "Error: 'claude' command not found in PATH"
        exit 1
    fi
    if [[ ! -x "$CCSWITCH" ]]; then
        echo "Error: ccswitch.sh not found at $CCSWITCH"
        exit 1
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts found. Run '$CCSWITCH --add-account' first."
        exit 1
    fi
    local count
    count=$(jq '.sequence | length' "$SEQUENCE_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo "Error: No accounts in sequence. Run '$CCSWITCH --add-account' first."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Account helpers
# ---------------------------------------------------------------------------

# Return the list of account numbers to process
get_target_accounts() {
    if [[ "$AR_ACCOUNTS" == "all" ]]; then
        jq -r '.sequence[]' "$SEQUENCE_FILE"
    else
        echo "$AR_ACCOUNTS" | tr ',' '\n'
    fi
}

# Pretty display name for an account
account_display() {
    local num="$1"
    local email label
    email=$(jq -r --arg n "$num" '.accounts[$n].email // "unknown"' "$SEQUENCE_FILE")
    label=$(jq -r --arg n "$num" '.accounts[$n].label // empty' "$SEQUENCE_FILE")
    if [[ -n "$label" ]]; then
        echo "Account-$num ($email [$label])"
    else
        echo "Account-$num ($email)"
    fi
}

# ---------------------------------------------------------------------------
# Core: ping one account
# ---------------------------------------------------------------------------

ping_account() {
    local account_num="$1"
    local display
    display=$(account_display "$account_num")

    log_msg "INFO" "Pinging $display ..."

    # Switch to the target account
    if ! "$CCSWITCH" --switch-to "$account_num" >/dev/null 2>&1; then
        log_msg "ERROR" "Failed to switch to $display"
        return 1
    fi

    sleep 2  # let credentials settle

    # Send the minimal ping (unset CLAUDECODE to allow nested invocation)
    local output exit_code=0
    output=$(CLAUDECODE= timeout 120 claude -p "$AR_MESSAGE" --model "$AR_MODEL" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_msg "INFO" "Successfully pinged $display"
        return 0
    else
        log_msg "ERROR" "Failed to ping $display (exit=$exit_code): ${output:0:200}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Core: ping all target accounts
# ---------------------------------------------------------------------------

ping_all_accounts() {
    # Remember where we started so we can switch back
    local original_account
    original_account=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null)

    local accounts
    accounts=$(get_target_accounts)

    if [[ -z "$accounts" ]]; then
        log_msg "ERROR" "No accounts to ping"
        return 1
    fi

    local success=0 failed=0

    while IFS= read -r num; do
        [[ -z "$num" ]] && continue
        if ping_account "$num"; then
            ((success++))
        else
            ((failed++))
        fi
        sleep 3  # brief pause between accounts
    done <<< "$accounts"

    # Restore the original account
    if [[ -n "$original_account" ]]; then
        log_msg "INFO" "Restoring original Account-$original_account"
        "$CCSWITCH" --switch-to "$original_account" >/dev/null 2>&1 || true
    fi

    log_msg "INFO" "Ping round complete: $success succeeded, $failed failed"

    # Persist state
    local now next
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    next=$(date -u -d "+${AR_INTERVAL_HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
    cat > "$AR_STATE_FILE" <<EOF
{
  "lastPing": "$now",
  "nextPing": "$next",
  "successCount": $success,
  "failedCount": $failed
}
EOF

    [[ $failed -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

seconds_until() {
    local target="$1"  # HH:MM
    local hour min now_epoch target_epoch
    hour=${target%%:*}
    min=${target##*:}

    now_epoch=$(date +%s)
    target_epoch=$(date -d "today ${hour}:${min}" +%s 2>/dev/null) || {
        echo "Error: cannot parse time '$target' (use HH:MM)" >&2
        return 1
    }

    # If the target already passed today, schedule for tomorrow
    if [[ $target_epoch -le $now_epoch ]]; then
        target_epoch=$((target_epoch + 86400))
    fi

    echo $((target_epoch - now_epoch))
}

# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------

run_daemon() {
    log_msg "INFO" "=== ccautorenew daemon started (PID $$) ==="
    log_msg "INFO" "Interval: ${AR_INTERVAL_HOURS}h | Model: $AR_MODEL | Accounts: $AR_ACCOUNTS"

    # Optional: wait until --at time
    if [[ -n "$AR_AT_TIME" ]]; then
        local wait_secs
        wait_secs=$(seconds_until "$AR_AT_TIME")
        local when
        when=$(date -d "+${wait_secs} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$AR_AT_TIME")
        log_msg "INFO" "Waiting until $when (${wait_secs}s) ..."
        sleep "$wait_secs"
    fi

    # Main loop
    while true; do
        ping_all_accounts || true

        local sleep_secs=$((AR_INTERVAL_HOURS * 3600))
        local next
        next=$(date -d "+${sleep_secs} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "in ${AR_INTERVAL_HOURS}h")
        log_msg "INFO" "Next ping at $next (sleeping ${AR_INTERVAL_HOURS}h)"
        sleep "$sleep_secs"
    done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
    check_prereqs
    mkdir -p "$BACKUP_DIR"

    # Guard against duplicate daemons
    if [[ -f "$AR_PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$AR_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Daemon already running (PID $old_pid). Stop it first with --stop."
            exit 1
        fi
        rm -f "$AR_PID_FILE"
    fi

    local account_count
    account_count=$(jq '.sequence | length' "$SEQUENCE_FILE")

    echo "Starting ccautorenew daemon..."
    echo "  Accounts : $AR_ACCOUNTS ($account_count managed)"
    echo "  Interval : ${AR_INTERVAL_HOURS}h"
    echo "  Model    : $AR_MODEL"
    echo "  Message  : $AR_MESSAGE"
    [[ -n "$AR_AT_TIME" ]] && echo "  First at : $AR_AT_TIME"
    echo "  Log      : $AR_LOG_FILE"

    # Launch daemon detached from terminal
    nohup bash -c "
        export AR_INTERVAL_HOURS='$AR_INTERVAL_HOURS'
        export AR_MODEL='$AR_MODEL'
        export AR_MESSAGE='$AR_MESSAGE'
        export AR_AT_TIME='$AR_AT_TIME'
        export AR_ACCOUNTS='$AR_ACCOUNTS'
        source '$SCRIPT_DIR/ccautorenew.sh' --_run-daemon
    " >> "$AR_LOG_FILE" 2>&1 &
    local pid=$!
    disown "$pid"
    echo "$pid" > "$AR_PID_FILE"

    echo "Daemon started (PID $pid)"
    echo "  --status  to check | --stop  to stop | --log  to view log"
}

cmd_stop() {
    if [[ ! -f "$AR_PID_FILE" ]]; then
        echo "No daemon PID file found."
        exit 1
    fi

    local pid
    pid=$(cat "$AR_PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        # Kill the whole process group
        kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        # Also kill children
        pkill -P "$pid" 2>/dev/null || true
        rm -f "$AR_PID_FILE"
        log_msg "INFO" "Daemon stopped (PID $pid)"
        echo "Daemon stopped (PID $pid)"
    else
        rm -f "$AR_PID_FILE"
        echo "Daemon was not running (stale PID removed)."
    fi
}

cmd_status() {
    echo "=== ccautorenew status ==="

    # Daemon
    if [[ -f "$AR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$AR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Daemon  : RUNNING (PID $pid)"
        else
            echo "Daemon  : STOPPED (stale PID file)"
        fi
    else
        echo "Daemon  : STOPPED"
    fi

    # State
    if [[ -f "$AR_STATE_FILE" ]]; then
        echo ""
        echo "Last ping:"
        echo "  Time    : $(jq -r '.lastPing // "never"' "$AR_STATE_FILE")"
        echo "  Results : $(jq -r '.successCount // 0' "$AR_STATE_FILE") ok, $(jq -r '.failedCount // 0' "$AR_STATE_FILE") failed"
        echo "  Next    : $(jq -r '.nextPing // "unknown"' "$AR_STATE_FILE")"
    fi

    # Log tail
    if [[ -f "$AR_LOG_FILE" ]]; then
        echo ""
        echo "Recent log:"
        tail -5 "$AR_LOG_FILE" | sed 's/^/  /'
    fi
}

cmd_once() {
    check_prereqs
    mkdir -p "$BACKUP_DIR"
    echo "Running one-time ping (accounts: $AR_ACCOUNTS, model: $AR_MODEL) ..."
    ping_all_accounts
}

cmd_log() {
    if [[ -f "$AR_LOG_FILE" ]]; then
        tail -n "${AR_LOG_LINES}" "$AR_LOG_FILE"
    else
        echo "No log file yet."
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

show_usage() {
    cat <<'USAGE'
ccautorenew - Auto-renewal for Claude Code 5-hour sessions
Integrates with ccswitch.sh for multi-account support

Usage: ccautorenew.sh [COMMAND] [OPTIONS]

Commands:
  --once               Ping all accounts once (good for testing)
  --start              Start the background daemon
  --stop               Stop the daemon
  --status             Show daemon / last-ping status
  --log [N]            Show last N log lines (default: 20)
  --help               Show this help

Options (for --start and --once):
  --at HH:MM           Schedule first ping at a specific time
  --accounts all|1,2,3 Which accounts to ping (default: all)
  --interval HOURS     Hours between pings (default: 5)
  --model MODEL        Model for the ping (default: haiku)
  --message MSG        Message to send (default: hi)

Examples:
  ccautorenew.sh --once                            # test: ping all accounts now
  ccautorenew.sh --once --accounts 1,2             # test: ping accounts 1 & 2
  ccautorenew.sh --start --at 09:00                # daemon: first ping at 9 AM
  ccautorenew.sh --start --at 09:00 --accounts 1   # daemon: only account 1
  ccautorenew.sh --start --interval 4              # daemon: every 4 hours
  ccautorenew.sh --status                          # check status
  ccautorenew.sh --stop                            # stop daemon
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --once)            command="once";   shift ;;
            --start)           command="start";  shift ;;
            --stop)            command="stop";   shift ;;
            --status)          command="status"; shift ;;
            --log)
                command="log"; shift
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    AR_LOG_LINES="$1"; shift
                fi
                ;;
            --at)              AR_AT_TIME="$2";          shift 2 ;;
            --accounts)        AR_ACCOUNTS="$2";         shift 2 ;;
            --interval)        AR_INTERVAL_HOURS="$2";   shift 2 ;;
            --model)           AR_MODEL="$2";            shift 2 ;;
            --message)         AR_MESSAGE="$2";          shift 2 ;;
            --help|-h)         show_usage; exit 0 ;;
            # Internal: called by nohup wrapper to enter daemon loop
            --_run-daemon)
                AR_INTERVAL_HOURS="${AR_INTERVAL_HOURS:-5}"
                AR_MODEL="${AR_MODEL:-haiku}"
                AR_MESSAGE="${AR_MESSAGE:-hi}"
                AR_AT_TIME="${AR_AT_TIME:-}"
                AR_ACCOUNTS="${AR_ACCOUNTS:-all}"
                run_daemon
                exit 0
                ;;
            *)
                echo "Error: Unknown option '$1'"
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
        once)   cmd_once   ;;
        start)  cmd_start  ;;
        stop)   cmd_stop   ;;
        status) cmd_status ;;
        log)    cmd_log    ;;
    esac
}

# Allow sourcing for the nohup wrapper
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${1:-}" == "--_run-daemon" ]]; then
    main "$@"
fi
