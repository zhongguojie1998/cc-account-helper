#!/usr/bin/env bash

# cxautorenew - Auto-renewal for Codex (ChatGPT) 5-hour sessions
#
# Sends a minimal message ("hi") using a cheap reasoning effort to the
# currently logged-in Codex account, starting the 5-hour usage window at
# a predictable time.
#
# Single-account: pings the account currently authenticated in ~/.codex.
# (No multi-account switching - Codex has no ccswitch equivalent.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
readonly AUTH_FILE="$CODEX_HOME/auth.json"
readonly STATE_DIR="$HOME/.codex-autorenew"
readonly AR_PID_FILE="$STATE_DIR/cxautorenew.pid"
readonly AR_LOG_FILE="$STATE_DIR/cxautorenew.log"
readonly AR_STATE_FILE="$STATE_DIR/cxautorenew-state.json"

# Defaults (overridable via flags)
AR_INTERVAL_HOURS="${AR_INTERVAL_HOURS:-5}"
AR_MODEL="${AR_MODEL:-gpt-5.4-mini}"  # smallest Codex model for a cheap ping
AR_REASONING="${AR_REASONING:-low}"   # cheap reasoning effort for the ping
AR_MESSAGE="${AR_MESSAGE:-hi}"
AR_AT_TIME="${AR_AT_TIME:-}"
AR_LOG_LINES="${AR_LOG_LINES:-20}"

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
    if ! command -v codex >/dev/null 2>&1; then
        echo "Error: 'codex' command not found in PATH"
        exit 1
    fi
    if [[ ! -f "$AUTH_FILE" ]]; then
        echo "Error: No Codex auth found at $AUTH_FILE. Run 'codex login' first."
        exit 1
    fi
}

# Pretty display name for the logged-in account (best effort)
account_display() {
    local id="unknown"
    if command -v jq >/dev/null 2>&1; then
        id=$(jq -r '.tokens.account_id // .auth_mode // "unknown"' "$AUTH_FILE" 2>/dev/null || echo "unknown")
    fi
    echo "Codex ($id)"
}

# ---------------------------------------------------------------------------
# Core: ping the account
# ---------------------------------------------------------------------------

ping_account() {
    local display
    display=$(account_display)

    log_msg "INFO" "Pinging $display ..."

    # Build codex exec invocation
    local -a cmd=(codex exec "$AR_MESSAGE"
        --skip-git-repo-check
        --sandbox read-only
        --color never)
    [[ -n "$AR_MODEL" ]] && cmd+=(--model "$AR_MODEL")
    [[ -n "$AR_REASONING" ]] && cmd+=(-c "model_reasoning_effort=\"$AR_REASONING\"")

    local output exit_code=0
    output=$(timeout 120 "${cmd[@]}" </dev/null 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_msg "INFO" "Successfully pinged $display"
        return 0
    else
        log_msg "ERROR" "Failed to ping $display (exit=$exit_code): ${output:0:200}"
        return 1
    fi
}

run_ping() {
    local success=0 failed=0
    if ping_account; then
        success=1
    else
        failed=1
    fi

    log_msg "INFO" "Ping complete: $success succeeded, $failed failed"

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
    log_msg "INFO" "=== cxautorenew daemon started (PID $$) ==="
    log_msg "INFO" "Interval: ${AR_INTERVAL_HOURS}h | Model: ${AR_MODEL:-<default>} | Effort: $AR_REASONING"

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
        run_ping || true

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
    mkdir -p "$STATE_DIR"

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

    echo "Starting cxautorenew daemon..."
    echo "  Account  : $(account_display)"
    echo "  Interval : ${AR_INTERVAL_HOURS}h"
    echo "  Model    : ${AR_MODEL:-<codex default>}"
    echo "  Effort   : $AR_REASONING"
    echo "  Message  : $AR_MESSAGE"
    [[ -n "$AR_AT_TIME" ]] && echo "  First at : $AR_AT_TIME"
    echo "  Log      : $AR_LOG_FILE"

    # Launch daemon detached from terminal
    nohup bash -c "
        export AR_INTERVAL_HOURS='$AR_INTERVAL_HOURS'
        export AR_MODEL='$AR_MODEL'
        export AR_REASONING='$AR_REASONING'
        export AR_MESSAGE='$AR_MESSAGE'
        export AR_AT_TIME='$AR_AT_TIME'
        source '$SCRIPT_DIR/cxautorenew.sh' --_run-daemon
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
    echo "=== cxautorenew status ==="

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
    if [[ -f "$AR_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
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
    mkdir -p "$STATE_DIR"
    echo "Running one-time ping (model: ${AR_MODEL:-<codex default>}, effort: $AR_REASONING) ..."
    run_ping
}

cmd_log() {
    if [[ -f "$AR_LOG_FILE" ]]; then
        tail -n "${AR_LOG_LINES}" "$AR_LOG_FILE"
    else
        echo "No log file yet."
    fi
}

cmd_cron_install() {
    local script_path
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    local cron_schedule="0 6,11,16,21 * * *"
    local cron_cmd="PATH='$PATH' $script_path --once >> $AR_LOG_FILE 2>&1"
    local cron_marker="# cxautorenew"

    if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        echo "Cron job already installed. Use 'cron-remove' to uninstall first."
        crontab -l 2>/dev/null | grep -F "$cron_marker"
        return 0
    fi

    (crontab -l 2>/dev/null; echo "CRON_TZ=America/New_York $cron_marker-tz"; echo "$cron_schedule $cron_cmd $cron_marker") | crontab -
    echo "Installed cron job: $cron_schedule (America/New_York)"
    echo "Auto-renew will run at 06:00, 11:00, 16:00, 21:00 ET daily."
    echo "Log: $AR_LOG_FILE"
}

cmd_cron_remove() {
    local cron_marker="# cxautorenew"

    if ! crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        echo "No cxautorenew cron job found."
        return 0
    fi

    crontab -l 2>/dev/null | grep -vF "$cron_marker" | crontab -
    echo "Removed cxautorenew cron job."
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

show_usage() {
    cat <<'USAGE'
cxautorenew - Auto-renewal for Codex (ChatGPT) 5-hour sessions

Usage: cxautorenew.sh [COMMAND] [OPTIONS]

Commands:
  --once               Ping the logged-in Codex account once (cron-friendly)
  --start              Start the background daemon
  --stop               Stop the daemon
  --status             Show daemon / last-ping status
  --log [N]            Show last N log lines (default: 20)
  --cron-install       Install cron job (06:00, 11:00, 16:00, 21:00 ET)
  --cron-remove        Remove cron job
  --help               Show this help

Options (for --start and --once):
  --at HH:MM           Schedule first ping at a specific time
  --interval HOURS     Hours between pings (default: 5)
  --model MODEL        Model for the ping (default: gpt-5.4-mini)
  --effort EFFORT      Reasoning effort: minimal|low|medium|high|xhigh (default: low)
  --message MSG        Message to send (default: hi)

Examples:
  cxautorenew.sh --once                            # test: ping now
  cxautorenew.sh --cron-install                    # cron: 06:00,11:00,16:00,21:00 ET
  cxautorenew.sh --cron-remove                     # remove cron job
  cxautorenew.sh --start --at 09:00                # daemon: first ping at 9 AM
  cxautorenew.sh --start --interval 4              # daemon: every 4 hours
  cxautorenew.sh --start --model gpt-5.5           # daemon: specific model
  cxautorenew.sh --status                          # check status
  cxautorenew.sh --stop                            # stop daemon
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
            --cron-install|cron-install)  command="cron-install";  shift ;;
            --cron-remove|cron-remove)    command="cron-remove";   shift ;;
            --at)              AR_AT_TIME="$2";          shift 2 ;;
            --interval)        AR_INTERVAL_HOURS="$2";   shift 2 ;;
            --model)           AR_MODEL="$2";            shift 2 ;;
            --effort)          AR_REASONING="$2";        shift 2 ;;
            --message)         AR_MESSAGE="$2";          shift 2 ;;
            --help|-h)         show_usage; exit 0 ;;
            # Internal: called by nohup wrapper to enter daemon loop
            --_run-daemon)
                AR_INTERVAL_HOURS="${AR_INTERVAL_HOURS:-5}"
                AR_MODEL="${AR_MODEL:-}"
                AR_REASONING="${AR_REASONING:-low}"
                AR_MESSAGE="${AR_MESSAGE:-hi}"
                AR_AT_TIME="${AR_AT_TIME:-}"
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
        once)         cmd_once         ;;
        start)        cmd_start        ;;
        stop)         cmd_stop         ;;
        status)       cmd_status       ;;
        log)          cmd_log          ;;
        cron-install) cmd_cron_install ;;
        cron-remove)  cmd_cron_remove  ;;
    esac
}

# Allow sourcing for the nohup wrapper
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${1:-}" == "--_run-daemon" ]]; then
    main "$@"
fi
