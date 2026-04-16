#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# OAuth token refresh
readonly OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
_CACHED_CLIENT_ID=""

# Extract OAuth client ID from Claude Code binary or env var
get_oauth_client_id() {
    if [[ -n "$_CACHED_CLIENT_ID" ]]; then
        echo "$_CACHED_CLIENT_ID"
        return
    fi

    # Check env var first (Claude Code supports this)
    if [[ -n "${CLAUDE_CODE_OAUTH_CLIENT_ID:-}" ]]; then
        _CACHED_CLIENT_ID="$CLAUDE_CODE_OAUTH_CLIENT_ID"
        echo "$_CACHED_CLIENT_ID"
        return
    fi

    # Try to extract from Claude Code binary
    local claude_bin
    claude_bin=$(which claude 2>/dev/null || true)
    if [[ -n "$claude_bin" ]]; then
        local client_id
        # Extract CLIENT_ID from the config block that also contains TOKEN_URL
        client_id=$(strings "$claude_bin" 2>/dev/null | grep -oP 'TOKEN_URL:"[^"]*"[^}]*CLIENT_ID:"\K[^"]*' | head -1 || true)
        if [[ -z "$client_id" ]]; then
            # Fallback: get the last UUID-format CLIENT_ID (skip deprecated ones)
            client_id=$(strings "$claude_bin" 2>/dev/null | grep -oE 'CLIENT_ID:"[0-9a-f-]{36}"' | tail -1 | grep -oE '"[^"]*"' | tr -d '"' || true)
        fi
        if [[ -n "$client_id" ]]; then
            _CACHED_CLIENT_ID="$client_id"
            echo "$_CACHED_CLIENT_ID"
            return
        fi
    fi

    echo "Error: Cannot determine OAuth client ID. Set CLAUDE_CODE_OAUTH_CLIENT_ID env var." >&2
    return 1
}

# Refresh OAuth token using refresh_token grant
# Input: credentials JSON string
# Output: updated credentials JSON string (empty on failure)
refresh_oauth_token() {
    local creds="$1"
    local refresh_token
    refresh_token=$(echo "$creds" | jq -r '.claudeAiOauth.refreshToken // empty')

    if [[ -z "$refresh_token" ]]; then
        echo ""
        return
    fi

    local client_id
    client_id=$(get_oauth_client_id) || { echo ""; return; }

    # Extract scopes from credentials for the refresh request
    local scopes
    scopes=$(echo "$creds" | jq -r '.claudeAiOauth.scopes // [] | join(" ")')

    local json_body
    json_body=$(jq -nc \
        --arg gt "refresh_token" \
        --arg rt "$refresh_token" \
        --arg ci "$client_id" \
        --arg sc "$scopes" \
        '{grant_type: $gt, refresh_token: $rt, client_id: $ci, scope: $sc}')

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$OAUTH_TOKEN_URL" \
        -H "Content-Type: application/json" \
        -d "$json_body" 2>/dev/null) || { echo ""; return; }

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        local error
        error=$(echo "$body" | jq -r '.error // empty' 2>/dev/null)
        if [[ "$error" == "invalid_grant" ]]; then
            echo "  Token refresh failed: invalid_grant (refresh token revoked)" >&2
        else
            echo "  Token refresh failed: HTTP $http_code" >&2
        fi
        echo ""
        return
    fi

    # Extract new tokens from response
    local new_access new_refresh expires_in
    new_access=$(echo "$body" | jq -r '.access_token // empty')
    new_refresh=$(echo "$body" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$body" | jq -r '.expires_in // empty')

    if [[ -z "$new_access" || -z "$new_refresh" ]]; then
        echo "  Token refresh failed: missing tokens in response" >&2
        echo ""
        return
    fi

    # Calculate new expiresAt (current time in ms + expires_in * 1000)
    local now_ms expires_at
    now_ms=$(date +%s)000
    if [[ -n "$expires_in" ]]; then
        expires_at=$(( ${now_ms%000} * 1000 + expires_in * 1000 ))
    else
        # Default 8 hours
        expires_at=$(( ${now_ms%000} * 1000 + 28800 * 1000 ))
    fi

    # Extract scopes from response if present
    local new_scopes
    new_scopes=$(echo "$body" | jq -r '.scope // empty')

    # Update credentials JSON preserving all other fields
    local updated_creds
    if [[ -n "$new_scopes" ]]; then
        # Convert space-separated scopes to JSON array
        local scopes_json
        scopes_json=$(echo "$new_scopes" | tr ' ' '\n' | jq -R . | jq -sc .)
        updated_creds=$(echo "$creds" | jq -c \
            --arg at "$new_access" \
            --arg rt "$new_refresh" \
            --argjson ea "$expires_at" \
            --argjson sc "$scopes_json" \
            '.claudeAiOauth.accessToken = $at |
             .claudeAiOauth.refreshToken = $rt |
             .claudeAiOauth.expiresAt = $ea |
             .claudeAiOauth.scopes = $sc')
    else
        updated_creds=$(echo "$creds" | jq -c \
            --arg at "$new_access" \
            --arg rt "$new_refresh" \
            --argjson ea "$expires_at" \
            '.claudeAiOauth.accessToken = $at |
             .claudeAiOauth.refreshToken = $rt |
             .claudeAiOauth.expiresAt = $ea')
    fi

    echo "$updated_creds"
}

# Check if access token is expired (by expiresAt field)
is_token_expired() {
    local creds="$1"
    local expires_at
    expires_at=$(echo "$creds" | jq -r '.claudeAiOauth.expiresAt // 0')

    if [[ "$expires_at" == "0" || "$expires_at" == "null" ]]; then
        return 0  # Treat missing expiresAt as expired
    fi

    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))

    if (( now_ms >= expires_at )); then
        return 0  # Expired
    fi
    return 1  # Still valid
}

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
            # Claude Code stores credentials in ~/.claude/.credentials.json on all platforms
            # Fall back to keychain for older Claude Code versions
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            fi
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

    # Always write to file — Claude Code reads from ~/.claude/.credentials.json
    mkdir -p "$HOME/.claude"
    printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
    chmod 600 "$HOME/.claude/.credentials.json"

    # On macOS, also update keychain for older Claude Code versions
    if [[ "$platform" == "macos" ]]; then
        security delete-generic-password -s "Claude Code-credentials" 2>/dev/null || true
        security add-generic-password -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null || true
    fi
}

# Read account credentials from backup (always file-based)
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
    if [[ -f "$cred_file" ]]; then
        cat "$cred_file"
    else
        echo ""
    fi
}

# Write account credentials to backup (always file-based)
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    mkdir -p "$BACKUP_DIR/credentials"
    local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
    printf '%s' "$credentials" > "$cred_file"
    chmod 600 "$cred_file"
}

# Sync live credentials back to the active account's backup
sync_current_credentials() {
    local active_account active_email
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    if [[ -z "$active_account" || "$active_account" == "null" ]]; then
        echo "Error: No active account found in sequence file" >&2
        return 1
    fi
    active_email=$(jq -r --arg num "$active_account" '.accounts[$num].email' "$SEQUENCE_FILE")

    local live_creds
    live_creds=$(read_credentials)
    if [[ -z "$live_creds" ]]; then
        echo "Error: Could not read live credentials" >&2
        return 1
    fi

    write_account_credentials "$active_account" "$active_email" "$live_creds"
    write_account_config "$active_account" "$active_email" "$(cat "$(get_claude_config_path)")"
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
    rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
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

# Sync live credentials to active account's backup
cmd_sync() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    sync_current_credentials
    local active email
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    email=$(jq -r --arg n "$active" '.accounts[$n].email' "$SEQUENCE_FILE")
    echo "Synced: Account-$active ($email) credentials updated from live state"
}

# Switch to account, launch claude, sync credentials on exit
cmd_run() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet" >&2
        exit 1
    fi

    local target_account=""

    # If first arg is a number, treat it as account number
    if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
        target_account="$1"
        shift

        local account_info
        account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")
        if [[ -z "$account_info" ]]; then
            echo "Error: Account-$target_account does not exist" >&2
            exit 1
        fi

        perform_switch "$target_account"
    else
        # No account number — use active account, no switch needed
        target_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        if [[ -z "$target_account" || "$target_account" == "null" ]]; then
            echo "Error: No active account found" >&2
            exit 1
        fi
    fi

    echo "Launching Claude Code for Account-$target_account..."
    local exit_code=0
    claude "$@" || exit_code=$?
    echo "Claude exited. Syncing credentials..."
    sync_current_credentials
    echo "Credentials synced. Account-$target_account backup is up to date."
    exit "$exit_code"
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

    # Auto-refresh if token is expired
    if is_token_expired "$target_creds"; then
        echo "Access token expired for Account-$target_account. Refreshing..."
        local refreshed_creds
        refreshed_creds=$(refresh_oauth_token "$target_creds")
        if [[ -n "$refreshed_creds" ]]; then
            target_creds="$refreshed_creds"
            # Persist refreshed credentials to backup atomically
            write_account_credentials "$target_account" "$target_email" "$target_creds"
            echo "Token refreshed successfully."
        else
            echo "Warning: Token refresh failed for Account-$target_account." >&2
            echo "         After restarting Claude Code, run: /login" >&2
        fi
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

# Refresh tokens for all managed accounts
cmd_refresh_all() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    local sequence
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))

    local total=${#sequence[@]} refreshed=0 failed=0 skipped=0

    for account_num in "${sequence[@]}"; do
        local email
        email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")
        local label
        label=$(jq -r --arg num "$account_num" '.accounts[$num].label // empty' "$SEQUENCE_FILE")
        local display="Account-$account_num ($email${label:+ [$label]})"

        local creds
        if [[ "$account_num" == "$active_account" ]]; then
            # For active account, read live credentials
            creds=$(read_credentials)
        else
            creds=$(read_account_credentials "$account_num" "$email")
        fi

        if [[ -z "$creds" ]]; then
            echo "  $display: SKIP (no credentials)"
            skipped=$((skipped + 1))
            continue
        fi

        if ! is_token_expired "$creds"; then
            echo "  $display: OK (token still valid)"
            skipped=$((skipped + 1))
            continue
        fi

        echo -n "  $display: refreshing... "
        local refreshed_creds
        refreshed_creds=$(refresh_oauth_token "$creds")

        if [[ -n "$refreshed_creds" ]]; then
            # Write back to backup
            write_account_credentials "$account_num" "$email" "$refreshed_creds"
            # If active account, also update live credentials
            if [[ "$account_num" == "$active_account" ]]; then
                write_credentials "$refreshed_creds"
            fi
            echo "REFRESHED"
            refreshed=$((refreshed + 1))
        else
            echo "FAILED"
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "Summary: $refreshed refreshed, $skipped skipped, $failed failed (out of $total accounts)"
}

# Refresh token for a single account
cmd_refresh() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local target_account
    if [[ $# -gt 0 ]]; then
        local identifier="$1"
        if [[ "$identifier" =~ ^[0-9]+$ ]]; then
            target_account="$identifier"
        else
            target_account=$(resolve_account_identifier "$identifier")
            if [[ -z "$target_account" ]]; then
                echo "Error: No account found: $identifier"
                exit 1
            fi
            if [[ "$target_account" == AMBIGUOUS:* ]]; then
                show_ambiguous_accounts "$identifier"
                exit 1
            fi
        fi
    else
        target_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    fi

    local email
    email=$(jq -r --arg num "$target_account" '.accounts[$num].email // empty' "$SEQUENCE_FILE")
    if [[ -z "$email" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    local creds
    if [[ "$target_account" == "$active_account" ]]; then
        creds=$(read_credentials)
    else
        creds=$(read_account_credentials "$target_account" "$email")
    fi

    if [[ -z "$creds" ]]; then
        echo "Error: No credentials found for Account-$target_account"
        exit 1
    fi

    if ! is_token_expired "$creds"; then
        echo "Account-$target_account ($email): token still valid, no refresh needed."
        return 0
    fi

    echo -n "Refreshing Account-$target_account ($email)... "
    local refreshed_creds
    refreshed_creds=$(refresh_oauth_token "$creds")

    if [[ -n "$refreshed_creds" ]]; then
        write_account_credentials "$target_account" "$email" "$refreshed_creds"
        if [[ "$target_account" == "$active_account" ]]; then
            write_credentials "$refreshed_creds"
        fi
        echo "done."
    else
        echo "failed. Account may need /login."
        exit 1
    fi
}

# Install cron job for periodic token refresh
cmd_cron_install() {
    local script_path
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    local cron_schedule="0 5,10,15,20,0 * * *"
    local cron_cmd="$script_path refresh-all >> /tmp/ccswitch-refresh.log 2>&1"
    local cron_marker="# ccswitch-refresh-all"

    # Check if already installed
    if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        echo "Cron job already installed. Use 'cron-remove' to uninstall first."
        crontab -l 2>/dev/null | grep -F "$cron_marker"
        return 0
    fi

    # Append to existing crontab
    (crontab -l 2>/dev/null; echo "$cron_schedule $cron_cmd $cron_marker") | crontab -
    echo "Installed cron job: $cron_schedule"
    echo "Tokens will be refreshed at 00:00, 05:00, 10:00, 15:00, 20:00 daily."
    echo "Log: /tmp/ccswitch-refresh.log"
}

# Remove cron job for periodic token refresh
cmd_cron_remove() {
    local cron_marker="# ccswitch-refresh-all"

    if ! crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        echo "No ccswitch cron job found."
        return 0
    fi

    crontab -l 2>/dev/null | grep -vF "$cron_marker" | crontab -
    echo "Removed ccswitch refresh cron job."
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
    echo "  run [num] [claude args...]         Switch to account (or use active), launch claude, sync on exit"
    echo "  sync                               Sync live credentials to active account backup"
    echo "  refresh [num|email]                Refresh OAuth token for one account (default: active)"
    echo "  refresh-all                        Refresh OAuth tokens for all managed accounts"
    echo "  cron-install                       Install cron job for periodic token refresh"
    echo "  cron-remove                        Remove cron job for periodic token refresh"
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
    echo "  $0 run 2                          # switch to account 2, launch claude, auto-sync on exit"
    echo "  $0 sync                           # manually sync live credentials to backup"
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
        --sync|sync)
            cmd_sync
            ;;
        --run|run)
            shift
            cmd_run "$@"
            ;;
        --refresh|refresh)
            shift
            cmd_refresh "$@"
            ;;
        --refresh-all|refresh-all)
            cmd_refresh_all
            ;;
        --cron-install|cron-install)
            cmd_cron_install
            ;;
        --cron-remove|cron-remove)
            cmd_cron_remove
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
