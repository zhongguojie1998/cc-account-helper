#!/bin/bash
# Two-line Statusline:
# Line 1: 🐦 {conda_env} {user}@{host}:{cwd} {model}
# Line 2: [progress bar] | ${cost} | 🟢 5h: X% (Xh Xm) | 🟢 7d: X% (Xd Xh)
# Adapted from https://gist.github.com/lexfrei/b70aaee919bdd7164f2e3027dc8c98de for Linux HPC

# If jq, python3, or curl are not on your PATH, add the relevant bin directory here:
# export PATH="/path/to/your/conda/bin:$PATH"

# Cache settings
CACHE_FILE="/tmp/claude-usage-cache-$(id -u).json"
CACHE_TTL=60  # seconds

# Get cached or fresh usage data
get_usage() {
    local now
    now=$(date +%s)

    # Check cache
    if [[ -f "$CACHE_FILE" ]]; then
        local cache_time
        cache_time=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
        if (( now - cache_time < CACHE_TTL )); then
            cat "$CACHE_FILE"
            return
        fi
    fi

    # Get credentials from ~/.claude/.credentials.json (Linux equivalent of macOS Keychain)
    local creds_file="$HOME/.claude/.credentials.json"
    local token
    token=$(python3 -c "import json; d=json.load(open('$creds_file')); print(d['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1

    if [[ -z "$token" ]]; then
        return 1
    fi

    # Fetch usage from API
    local response
    response=$(curl --silent --max-time 5 \
        --header "Authorization: Bearer $token" \
        --header "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    # Cache response
    echo "$response" > "$CACHE_FILE"
    echo "$response"
}

# Calculate time remaining (in minutes) from ISO timestamp (UTC)
# Uses GNU date (-d) instead of BSD date (-j -f)
time_remaining_mins() {
    local reset_at=$1
    local now reset_ts diff

    now=$(date +%s)
    local ts_clean="${reset_at%%.*}"
    ts_clean="${ts_clean//T/ }"
    reset_ts=$(TZ=UTC date -d "$ts_clean" +%s 2>/dev/null) || return 1

    diff=$((reset_ts - now))
    echo $(( diff / 60 ))
}

# Format minutes to human readable
format_time() {
    local mins=$1
    if (( mins <= 0 )); then
        echo "now"
        return
    fi

    local days hours minutes
    days=$((mins / 1440))
    hours=$(((mins % 1440) / 60))
    minutes=$((mins % 60))

    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# Get rate indicator based on usage% vs time elapsed%
rate_indicator() {
    local usage=$1
    local remaining_mins=$2
    local total_mins=$3

    local elapsed_mins=$((total_mins - remaining_mins))
    if (( elapsed_mins < 0 )); then elapsed_mins=0; fi

    local time_pct
    if (( total_mins > 0 )); then
        time_pct=$((elapsed_mins * 100 / total_mins))
    else
        time_pct=0
    fi

    local diff=$((usage - time_pct))

    if (( diff <= 0 )); then
        echo "🟢"
    elif (( diff <= 5 )); then
        echo "🟡"
    elif (( diff <= 15 )); then
        echo "🟠"
    else
        echo "🔴"
    fi
}

# Build a context window progress bar using block characters
# e.g.  ▓▓▓▓▓░░░░░ 42%
build_progress_bar() {
    local used_pct=$1   # integer 0-100, or empty/null
    local BAR_WIDTH=10

    # If no data yet, show empty bar with no label
    if [[ -z "$used_pct" || "$used_pct" == "null" ]]; then
        local empty_bar=""
        local i
        for (( i=0; i<BAR_WIDTH; i++ )); do empty_bar+="░"; done
        printf "%s --" "$empty_bar"
        return
    fi

    # Clamp to 0-100
    (( used_pct < 0 )) && used_pct=0
    (( used_pct > 100 )) && used_pct=100

    local PCT=$used_pct
    local FILLED=$(( PCT * BAR_WIDTH / 100 ))
    local EMPTY=$(( BAR_WIDTH - FILLED ))

    local bar=""
    local i
    for (( i=0; i<FILLED; i++ )); do bar+="▓"; done
    for (( i=0; i<EMPTY;  i++ )); do bar+="░"; done

    printf "%s %d%%" "$bar" "$used_pct"
}

# Main - receives JSON from Claude Code via stdin
main() {
    local input
    input=$(cat)

    # ── Line 1 components ────────────────────────────────────────────────────
    # Conda env name
    local conda_env="${CONDA_DEFAULT_ENV:-base}"

    # user@host:cwd
    local user host cwd
    user=$(whoami)
    host=$(hostname -s)
    cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
    [[ -z "$cwd" ]] && cwd="$PWD"

    # Model: strip "Claude " prefix → "Haiku 4.5"
    local model
    model=$(echo "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
    model="${model#Claude }"
    [[ -z "$model" ]] && model="Claude"

    # ANSI colors
    local C_CYAN="\033[96m"    # bright cyan   — 🐦 conda env
    local C_GREEN="\033[92m"   # bright green  — user@host
    local C_BLUE="\033[94m"    # bright blue   — :path
    local C_LYELLOW="\033[93m" # light yellow  — model name
    local C_YELLOW="\033[33m"  # yellow        — cost + quota
    local C_RESET="\033[0m"

    local line1="${C_CYAN}🐦 ${conda_env}${C_RESET} ${C_GREEN}${user}@${host}${C_RESET}${C_BLUE}:${cwd}${C_RESET} ${C_LYELLOW}${model}${C_RESET}"

    # ── Line 2 components ────────────────────────────────────────────────────
    # Context window progress bar (from Claude Code JSON input)
    local used_pct
    used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
    local progress_bar
    progress_bar=$(build_progress_bar "$used_pct")

    # Session cost
    local session_cost
    session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)
    session_cost=$(printf '%.2f' "$session_cost")

    local line2="${C_YELLOW}${progress_bar} | \$${session_cost}"

    # Quota from API
    local usage
    usage=$(get_usage 2>/dev/null) || usage=""

    local api_error=""
    [[ -n "$usage" ]] && api_error=$(echo "$usage" | jq -r '.error.type // empty' 2>/dev/null)

    if [[ -n "$api_error" ]]; then
        line2+=" | ⚠️ /login needed${C_RESET}"
    elif [[ -n "$usage" ]]; then
        local five_hour five_hour_resets seven_day seven_day_resets
        five_hour=$(echo "$usage" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
        five_hour_resets=$(echo "$usage" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
        seven_day=$(echo "$usage" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
        seven_day_resets=$(echo "$usage" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)

        # 5h first
        if [[ -n "$five_hour" ]]; then
            local fh_int fh_mins fh_ind fh_time
            fh_int=$(printf "%.0f" "$five_hour")
            fh_mins=$(time_remaining_mins "$five_hour_resets" 2>/dev/null) || fh_mins=0
            fh_ind=$(rate_indicator "$fh_int" "$fh_mins" 300)
            fh_time=$(format_time "$fh_mins")
            line2+=" | ${fh_ind} 5h: ${fh_int}% (${fh_time})"
        fi

        # 7d second
        if [[ -n "$seven_day" ]]; then
            local sd_int sd_mins sd_ind sd_time
            sd_int=$(printf "%.0f" "$seven_day")
            sd_mins=$(time_remaining_mins "$seven_day_resets" 2>/dev/null) || sd_mins=0
            sd_ind=$(rate_indicator "$sd_int" "$sd_mins" 10080)
            sd_time=$(format_time "$sd_mins")
            line2+=" | ${sd_ind} 7d: ${sd_int}% (${sd_time})"
        fi

        line2+="${C_RESET}"
    else
        line2+="${C_RESET}"
    fi

    printf "%b\n%b\n" "$line1" "$line2"
}

main
