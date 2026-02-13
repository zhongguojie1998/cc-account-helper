#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier resolution function
# Returns account number, or prints error and returns empty string for ambiguous matches
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Look up account number(s) by email
        local matches
        matches=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)

        local count
        count=$(echo "$matches" | grep -c . 2>/dev/null || echo "0")

        if [[ "$count" -eq 0 || -z "$matches" ]]; then
            echo ""
        elif [[ "$count" -eq 1 ]]; then
            echo "$matches"
        else
            # Multiple accounts with same email - ambiguous
            echo "AMBIGUOUS:$matches"
        fi
    fi
}

# Display disambiguation list for accounts with the same email
show_ambiguous_accounts() {
    local email="$1"
    echo "Multiple accounts found with email '$email':"
    jq -r --arg email "$email" '
        .accounts | to_entries[] | select(.value.email == $email) |
        "  \(.key): \(.value.email)" +
        (if .value.label then " [\(.value.label)]"
         elif .value.organizationName then " [\(.value.organizationName)]"
         else "" end)
    ' "$SEQUENCE_FILE"
    echo "Please use the account number instead."
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Get current account UUID from .claude.json
get_current_account_uuid() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi

    local uuid
    uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${uuid:-none}"
}

# Get current organization UUID from .claude.json
get_current_org_uuid() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi

    local org_uuid
    org_uuid=$(jq -r '.oauthAccount.organizationUuid // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${org_uuid:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by UUID + org UUID (the true unique identity)
account_exists_by_uuid() {
    local uuid="$1"
    local org_uuid="${2:-}"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    if [[ -n "$org_uuid" && "$org_uuid" != "none" ]]; then
        jq -e --arg uuid "$uuid" --arg org "$org_uuid" '.accounts[] | select(.uuid == $uuid and .organizationUuid == $org)' "$SEQUENCE_FILE" >/dev/null 2>&1
    else
        jq -e --arg uuid "$uuid" '.accounts[] | select(.uuid == $uuid and (has("organizationUuid") | not))' "$SEQUENCE_FILE" >/dev/null 2>&1
    fi
}

# Check if account exists by email (backward compat for switch auto-add)
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Find account numbers matching an email (may return multiple for same-email accounts)
find_accounts_by_email() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return
    fi

    jq -r --arg email "$email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null
}

# Find account number by UUID + org UUID
find_account_by_uuid() {
    local uuid="$1"
    local org_uuid="${2:-}"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return
    fi

    if [[ -n "$org_uuid" && "$org_uuid" != "none" ]]; then
        jq -r --arg uuid "$uuid" --arg org "$org_uuid" '.accounts | to_entries[] | select(.value.uuid == $uuid and .value.organizationUuid == $org) | .key' "$SEQUENCE_FILE" 2>/dev/null
    else
        jq -r --arg uuid "$uuid" '.accounts | to_entries[] | select(.value.uuid == $uuid and (.value | has("organizationUuid") | not)) | .key' "$SEQUENCE_FILE" 2>/dev/null
    fi
}

# Try to auto-detect a label for the account (Personal vs Team/Org)
auto_detect_label() {
    local config_path="$1"

    # Check for organization-related fields in oauthAccount
    local org_name
    org_name=$(jq -r '.oauthAccount.organizationName // .oauthAccount.orgName // empty' "$config_path" 2>/dev/null)
    if [[ -n "$org_name" ]]; then
        echo "$org_name"
        return
    fi

    # Check if organizationUuid exists (team account indicator)
    local org_uuid
    org_uuid=$(jq -r '.oauthAccount.organizationUuid // .oauthAccount.orgUuid // empty' "$config_path" 2>/dev/null)
    if [[ -n "$org_uuid" ]]; then
        echo "Team"
        return
    fi

    echo ""
}

# Add account
cmd_add_account() {
    local label=""

    # Parse optional arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --label)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --label requires a value"
                    exit 1
                fi
                label="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option for --add-account: $1"
                echo "Usage: $0 --add-account [--label \"label\"]"
                exit 1
                ;;
        esac
    done

    setup_directories
    init_sequence_file

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    # Get account UUID and organization UUID
    local account_uuid org_uuid org_name
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")
    org_uuid=$(get_current_org_uuid)
    org_name=$(jq -r '.oauthAccount.organizationName // empty' "$(get_claude_config_path)")

    # Check by UUID + org UUID (the true unique identity)
    if account_exists_by_uuid "$account_uuid" "$org_uuid"; then
        local existing_num
        existing_num=$(find_account_by_uuid "$account_uuid" "$org_uuid")

        # If --label was provided, update the label on the existing account
        if [[ -n "$label" ]]; then
            local updated
            updated=$(jq --arg num "$existing_num" --arg lbl "$label" '
                .accounts[$num].label = $lbl
            ' "$SEQUENCE_FILE")
            write_json "$SEQUENCE_FILE" "$updated"
            echo "Updated label for Account-$existing_num ($current_email) to [$label]."
            exit 0
        fi

        echo "This account ($current_email, org: ${org_name:-personal}) is already managed as Account-$existing_num."
        echo "Tip: Use --label to set a label: $0 --add-account --label \"Personal\""
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    # Auto-detect label if not provided
    if [[ -z "$label" ]]; then
        label=$(auto_detect_label "$(get_claude_config_path)")
    fi

    # If same email already exists and no label, prompt for one
    local existing_emails
    existing_emails=$(find_accounts_by_email "$current_email")
    if [[ -n "$existing_emails" && -z "$label" ]]; then
        echo "An account with email '$current_email' is already managed."
        echo "To distinguish this account, please provide a label (e.g., 'Personal', 'Team', org name)."
        echo -n "Label for this account: "
        read -r label
        if [[ -z "$label" ]]; then
            echo "Error: A label is required when adding multiple accounts with the same email."
            exit 1
        fi

        # Also check if existing accounts with same email need labels
        for existing_num in $existing_emails; do
            local existing_label
            existing_label=$(jq -r --arg num "$existing_num" '.accounts[$num].label // empty' "$SEQUENCE_FILE")
            if [[ -z "$existing_label" ]]; then
                echo -n "The existing Account-$existing_num ($current_email) has no label. Enter a label for it: "
                read -r existing_label
                if [[ -n "$existing_label" ]]; then
                    local updated
                    updated=$(jq --arg num "$existing_num" --arg lbl "$existing_label" '
                        .accounts[$num].label = $lbl
                    ' "$SEQUENCE_FILE")
                    write_json "$SEQUENCE_FILE" "$updated"
                fi
            fi
        done
    fi

    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"

    # Build the account entry with all available fields
    local jq_expr='
        .accounts[$num] = ({
            email: $email,
            uuid: $uuid,
            added: $now
        }
        + (if $org_uuid != "" and $org_uuid != "none" then {organizationUuid: $org_uuid} else {} end)
        + (if $org_name != "" then {organizationName: $org_name} else {} end)
        + (if $label != "" then {label: $label} else {} end)
        ) |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    '

    local updated_sequence
    updated_sequence=$(jq \
        --arg num "$account_num" \
        --arg email "$current_email" \
        --arg uuid "$account_uuid" \
        --arg org_uuid "$org_uuid" \
        --arg org_name "$org_name" \
        --arg label "$label" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$jq_expr" "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    if [[ -n "$label" ]]; then
        echo "Added Account $account_num: $current_email [$label]"
    else
        echo "Added Account $account_num: $current_email"
    fi
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local account_num
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi

        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
        if [[ "$account_num" == AMBIGUOUS:* ]]; then
            show_ambiguous_accounts "$identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')
    local label
    label=$(echo "$account_info" | jq -r '.label // empty')
    
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    
    local display_name="$email"
    if [[ -n "$label" ]]; then
        display_name="$email [$label]"
    fi

    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($display_name) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove Account-$account_num ($display_name)? [y/N] "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi
    
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Account-$account_num ($display_name) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi
    
    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi
    
    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    # Get current active account UUID + org UUID from .claude.json for accurate matching
    local current_uuid current_org_uuid
    current_uuid=$(get_current_account_uuid)
    current_org_uuid=$(get_current_org_uuid)

    # Find which account number corresponds to the current UUID + org
    local active_account_num=""
    if [[ "$current_uuid" != "none" ]]; then
        active_account_num=$(find_account_by_uuid "$current_uuid" "$current_org_uuid")
    fi

    # Fallback to activeAccountNumber from sequence.json if UUID match fails
    if [[ -z "$active_account_num" ]]; then
        active_account_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null)
    fi

    echo "Accounts:"
    jq -r --arg active "${active_account_num:-}" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        (if .label then " [\(.label)]"
         elif .organizationName then " [\(.organizationName)]"
         else "" end) as $label_str |
        if "\($num)" == $active then
            "  \($num): \(.email)\($label_str) (active)"
        else
            "  \($num): \(.email)\($label_str)"
        end
    ' "$SEQUENCE_FILE"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email current_uuid current_org_uuid
    current_email=$(get_current_account)
    current_uuid=$(get_current_account_uuid)
    current_org_uuid=$(get_current_org_uuid)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi

    # Check if current account is managed (by UUID+org first, then email fallback)
    local is_managed=false
    if [[ "$current_uuid" != "none" ]] && account_exists_by_uuid "$current_uuid" "$current_org_uuid"; then
        is_managed=true
    elif account_exists "$current_email"; then
        is_managed=true
    fi

    if [[ "$is_managed" == "false" ]]; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi

    # wait_for_claude_close

    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    # If activeAccountNumber doesn't match current UUID+org, try to find by UUID+org
    if [[ "$current_uuid" != "none" ]]; then
        local uuid_account
        uuid_account=$(find_account_by_uuid "$current_uuid" "$current_org_uuid")
        if [[ -n "$uuid_account" ]]; then
            active_account="$uuid_account"
        fi
    fi

    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))

    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done

    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"

    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi

    local identifier="$1"
    local target_account

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        target_account="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi

        # Resolve email to account number
        target_account=$(resolve_account_identifier "$identifier")
        if [[ -z "$target_account" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
        if [[ "$target_account" == AMBIGUOUS:* ]]; then
            show_ambiguous_accounts "$identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    # wait_for_claude_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    
    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)
    
    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    
    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi
    
    # Step 3: Activate target account
    write_credentials "$target_creds"
    
    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi
    
    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi
    
    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    
    # Step 4: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    # Get label for display
    local target_label
    target_label=$(jq -r --arg num "$target_account" '.accounts[$num].label // empty' "$SEQUENCE_FILE")
    if [[ -n "$target_label" ]]; then
        echo "Switched to Account-$target_account ($target_email [$target_label])"
    else
        echo "Switched to Account-$target_account ($target_email)"
    fi
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""
    
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account [--label \"label\"]   Add current account to managed accounts"
    echo "  --remove-account <num|email>      Remove account by number or email"
    echo "  --list                             List all managed accounts"
    echo "  --switch                           Rotate to next account in sequence"
    echo "  --switch-to <num|email>            Switch to specific account number or email"
    echo "  --help                             Show this help message"
    echo ""
    echo "Same-email accounts (personal + team):"
    echo "  When adding multiple accounts with the same email, use --label to"
    echo "  distinguish them, or you will be prompted for a label."
    echo ""
    echo "Examples:"
    echo "  $0 --add-account"
    echo "  $0 --add-account --label \"Personal\""
    echo "  $0 --add-account --label \"Team\""
    echo "  $0 --list"
    echo "  $0 --switch"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --remove-account user@example.com"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    
    check_bash_version
    check_dependencies
    
    case "${1:-}" in
        --add-account)
            shift
            cmd_add_account "$@"
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --help)
            show_usage
            ;;
        "")
            cmd_switch
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
