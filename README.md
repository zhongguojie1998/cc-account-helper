# Multi-Account Switcher for Claude Code

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL. Includes an auto-renewal daemon to start 5-hour usage windows on a schedule.

## Features

- **Multi-account management**: Add, remove, and list Claude Code accounts
- **Quick switching**: Switch between accounts with simple commands
- **Auto-renewal**: Automatically start 5-hour usage windows at scheduled times across all accounts
- **Cross-platform**: Works on macOS, Linux, and WSL
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation**: Only switches authentication - your themes, settings, and preferences remain unchanged

## Installation

Download the scripts directly:

```bash
curl -O https://raw.githubusercontent.com/zhongguojie1998/cc-account-helper/main/ccswitch.sh
curl -O https://raw.githubusercontent.com/zhongguojie1998/cc-account-helper/main/ccautorenew.sh
chmod +x ccswitch.sh ccautorenew.sh
```

## Usage

### Basic Commands

```bash
# Add current account to managed accounts
./ccswitch.sh --add-account

# List all managed accounts
./ccswitch.sh --list

# Switch to next account in sequence
./ccswitch.sh --switch

# Switch to specific account by number or email
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com

# Remove an account
./ccswitch.sh --remove-account user2@example.com

# Show help
./ccswitch.sh --help
```

### Auto-Renewal (ccautorenew)

Claude Code grants usage in 5-hour blocks starting from your first message. `ccautorenew.sh` automatically sends a minimal message (`"hi"` using the cheapest model) to start each account's 5-hour window at a predictable time.

```bash
# Test: ping all accounts once immediately
./ccautorenew.sh --once

# Start daemon: first ping at 9 AM, then every 5 hours
./ccautorenew.sh --start --at 09:00

# Only ping specific accounts
./ccautorenew.sh --start --at 09:00 --accounts 1,2

# Custom interval (every 4 hours instead of 5)
./ccautorenew.sh --start --interval 4

# Check daemon status and last ping results
./ccautorenew.sh --status

# View recent log entries
./ccautorenew.sh --log

# Stop the daemon
./ccautorenew.sh --stop
```

| Option | Description |
|---|---|
| `--once` | Ping all accounts once (good for testing) |
| `--start` | Start the background daemon |
| `--stop` | Stop the daemon |
| `--status` | Show daemon and last-ping status |
| `--log [N]` | Show last N log lines (default: 20) |
| `--at HH:MM` | Schedule first ping at a specific time |
| `--accounts all\|1,2,3` | Which accounts to ping (default: all) |
| `--interval HOURS` | Hours between pings (default: 5) |
| `--model MODEL` | Model for the ping (default: haiku) |
| `--message MSG` | Message to send (default: hi) |

The daemon iterates through each account, switches credentials via `ccswitch.sh`, sends the ping, then restores the original active account when done.

### First Time Setup

1. **Log into Claude Code** with your first account (make sure you're actively logged in)
2. Run `./ccswitch.sh --add-account` to add it to managed accounts
3. **Log out** and log into Claude Code with your second account
4. Run `./ccswitch.sh --add-account` again
5. Now you can switch between accounts with `./ccswitch.sh --switch`
6. **Important**: After each switch, restart Claude Code to use the new authentication

> **What gets switched:** Only your authentication credentials change. Your themes, settings, preferences, and chat history remain exactly the same.

## Requirements

- Bash 4.4+
- `jq` (JSON processor)

### Installing Dependencies

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions

When switching accounts, it:

1. Backs up the current account's authentication data
2. Restores the target account's authentication data
3. Updates Claude Code's authentication files

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `./ccswitch.sh --list`
- Verify Claude Code is closed before switching
- Try switching back to your original account

### If you can't add an account

- Make sure you're logged into Claude Code first
- Check that you have `jq` installed
- Verify you have write permissions to your home directory

### If Claude Code doesn't recognize the new account

- Make sure you restarted Claude Code after switching
- Check the current account: `./ccswitch.sh --list` (look for "(active)")

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Stop the auto-renewal daemon if running: `./ccautorenew.sh --stop`
2. Note your current active account: `./ccswitch.sh --list`
3. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
4. Delete the scripts: `rm ccswitch.sh ccautorenew.sh`

Your current Claude Code login will remain active.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- The tool requires Claude Code to be closed during account switches

## License

MIT License - see LICENSE file for details
