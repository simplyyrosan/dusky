#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# UWSM Clipboard Persistence Manager - v1.1.0 (Hardened)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Wayland
#
# Description: Toggles cliphist persistence in ~/.config/uwsm/env
#              by commenting/uncommenting the CLIPHIST_DB_PATH export.
#
# v1.1.0 CHANGELOG:
#   - CRITICAL: Replaced sed -i with atomic awk + cat to preserve symlinks.
#   - FIX: Proper cleanup trap function instead of inline trap.
#   - FIX: Consistent ANSI constant declarations (declare -r).
#   - FIX: Added Bash version check (5.0+ required).
#   - FIX: Added TTY check for interactive read.
#   - FIX: Added dependency checks (awk, grep).
#   - FIX: Added file writability check.
#   - FIX: Secure temp file creation and cleanup.
#   - STYLE: Aligned with Dusky TUI Engine master template v3.9.1.
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# ANSI Constants
# =============================================================================
declare -r C_RESET=$'\033[0m'
declare -r C_RED=$'\033[0;31m'
declare -r C_GREEN=$'\033[0;32m'
declare -r C_BLUE=$'\033[0;34m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_BOLD=$'\033[1m'

# =============================================================================
# Configuration
# =============================================================================
declare -r CONFIG_DIR="${HOME}/.config/uwsm"
declare -r CONFIG_FILE="${CONFIG_DIR}/env"
declare -r TARGET_LINE='export CLIPHIST_DB_PATH="${XDG_RUNTIME_DIR}/cliphist.db"'

# =============================================================================
# Temp File Global (for cleanup safety)
# =============================================================================
declare _TMPFILE=""

# =============================================================================
# Logging
# =============================================================================
log_info()    { printf '%s[INFO]%s %s\n'    "$C_BLUE"   "$C_RESET" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn()    { printf '%s[WARN]%s %s\n'    "$C_YELLOW" "$C_RESET" "$1"; }
log_err()     { printf '%s[ERROR]%s %s\n'   "$C_RED"    "$C_RESET" "$1" >&2; }

# =============================================================================
# Cleanup & Traps
# =============================================================================
cleanup() {
    # Secure temp file cleanup
    if [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Bash version gate
if (( BASH_VERSINFO[0] < 5 )); then
    log_err "Bash 5.0+ required."
    exit 1
fi

# TTY check (we need interactive input)
if [[ ! -t 0 ]]; then
    log_err "Interactive TTY required."
    exit 1
fi

# Root guard — editing ~/.config as root breaks file ownership
if [[ $EUID -eq 0 ]]; then
    log_err "Do NOT run this script as root/sudo."
    log_err "This script modifies your personal user configuration (~/.config)."
    log_err "Please run again as your normal user."
    exit 1
fi

# Dependency checks
declare _dep
for _dep in awk grep; do
    if ! command -v "$_dep" &>/dev/null; then
        log_err "Missing dependency: ${_dep}"
        exit 1
    fi
done
unset _dep

# Config file existence and writability
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_err "Configuration file not found at: ${CONFIG_FILE}"
    log_info "Please ensure UWSM is initialized and the path is correct."
    exit 1
fi

if [[ ! -w "$CONFIG_FILE" ]]; then
    log_err "Configuration file not writable: ${CONFIG_FILE}"
    exit 1
fi

# =============================================================================
# Core Logic — Atomic File Write (Symlink-Safe)
# =============================================================================
# CRITICAL: Uses awk + cat > target instead of sed -i.
# sed -i replaces the inode (breaks symlinks). cat > preserves them.

update_config() {
    local mode="$1"

    if [[ "$mode" == "ephemeral" ]]; then
        # Check if already uncommented (active)
        if grep -q "^${TARGET_LINE}" "$CONFIG_FILE"; then
            log_info "Config is already set to Ephemeral."
            return 0
        fi

        # Verify the commented version exists before attempting modification
        if ! grep -q '^\s*#\s*export CLIPHIST_DB_PATH=' "$CONFIG_FILE"; then
            log_err "Could not find CLIPHIST_DB_PATH line (commented or uncommented) in config."
            return 1
        fi

        _TMPFILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXXXXXX")

        LC_ALL=C awk -v target="$TARGET_LINE" '
        /^[[:space:]]*#[[:space:]]*export[[:space:]]+CLIPHIST_DB_PATH=/ {
            print target
            next
        }
        { print }
        ' "$CONFIG_FILE" > "$_TMPFILE"

        # Preserve symlinks: write content back, do NOT mv
        cat "$_TMPFILE" > "$CONFIG_FILE"
        rm -f "$_TMPFILE"
        _TMPFILE=""

        log_success "Set to Ephemeral. (Line uncommented)."

    elif [[ "$mode" == "persistent" ]]; then
        # Check if already commented (inactive)
        if grep -q '^\s*#\s*export CLIPHIST_DB_PATH=' "$CONFIG_FILE"; then
            log_info "Config is already set to Persistent."
            return 0
        fi

        # Verify the uncommented version exists before attempting modification
        if ! grep -q '^export CLIPHIST_DB_PATH=' "$CONFIG_FILE"; then
            log_err "Could not find an active CLIPHIST_DB_PATH line in config."
            return 1
        fi

        _TMPFILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXXXXXX")

        LC_ALL=C awk -v target="$TARGET_LINE" '
        /^export[[:space:]]+CLIPHIST_DB_PATH=/ {
            print "# " target
            next
        }
        { print }
        ' "$CONFIG_FILE" > "$_TMPFILE"

        # Preserve symlinks: write content back, do NOT mv
        cat "$_TMPFILE" > "$CONFIG_FILE"
        rm -f "$_TMPFILE"
        _TMPFILE=""

        log_success "Set to Persistent. (Line commented out)."
    fi

    return 0
}

# =============================================================================
# User Interface
# =============================================================================
clear
printf '%sUWSM Clipboard Persistence Manager%s\n' "$C_BOLD" "$C_RESET"
printf 'Target: %s\n\n' "$CONFIG_FILE"

printf '%sWhich mode do you prefer?%s\n\n' "$C_BOLD" "$C_RESET"

printf '  %s1) Ephemeral (RAM-based)%s\n' "$C_BOLD" "$C_RESET"
printf '     - Clipboard history is stored in RAM.\n'
printf '     - It %sdisappears%s when you reboot or shutdown.\n' "$C_RED" "$C_RESET"
printf '     - Good for privacy and saving disk writes.\n\n'

printf '  %s2) Persistent (Disk-based)%s\n' "$C_BOLD" "$C_RESET"
printf '     - Clipboard history is stored on your hard drive.\n'
printf '     - Your history %sstays available%s even after you reboot.\n' "$C_GREEN" "$C_RESET"
printf '     - Standard behavior for most users.\n\n'

read -rp "Select option [1/2] (default: 1): " choice
choice="${choice:-1}"

case "$choice" in
    1)
        log_info "Applying Ephemeral settings..."
        update_config "ephemeral"
        ;;
    2)
        log_info "Applying Persistent settings..."
        update_config "persistent"
        ;;
    *)
        log_err "Invalid selection. Exiting."
        exit 1
        ;;
esac

# =============================================================================
# Post-Process
# =============================================================================
if command -v uwsm >/dev/null 2>&1; then
    printf '\n'
    log_info "Changes saved."
    log_info "To apply changes immediately, log out and back in, or restart at a later time."
else
    log_warn "uwsm command not found in PATH. Ensure you are in a UWSM session."
fi

exit 0
