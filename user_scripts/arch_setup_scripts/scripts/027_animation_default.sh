#!/usr/bin/env bash
# set Hyprland animation config to dusky (Default)
# -----------------------------------------------------------------------------
# Purpose: Copy 'dusky.conf' to 'active.conf' & reload Hyprland
# Env:     Arch Linux / Hyprland / UWSM
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
readonly SOURCE_FILE="${HOME}/.config/hypr/source/animations/dusky.conf"
readonly TARGET_FILE="${HOME}/.config/hypr/source/animations/active/active.conf"

# --- Colors ---
readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[1;31m'
readonly C_GREEN=$'\033[1;32m'
readonly C_BLUE=$'\033[1;34m'
readonly C_GREY=$'\033[0;90m'

main() {
    # 1. Validate source exists
    if [[ ! -f "$SOURCE_FILE" ]]; then
        printf "[${C_GREY}%s${C_RESET}] ${C_RED}[ERROR]${C_RESET} Source missing: %s\n" \
            "$(date +%T)" "$SOURCE_FILE" >&2
        exit 1
    fi

    # 2. Ensure target directory exists
    # "${TARGET_FILE%/*}" strips the filename, leaving the directory path
    if ! mkdir -p -- "${TARGET_FILE%/*}"; then
         printf "[${C_GREY}%s${C_RESET}] ${C_RED}[ERROR]${C_RESET} Failed to create directory: %s\n" \
            "$(date +%T)" "${TARGET_FILE%/*}" >&2
        exit 1
    fi

    # 3. Clean up existing file or symlink
    rm -f -- "$TARGET_FILE"

    # 4. Copy the new file
    if cp -- "$SOURCE_FILE" "$TARGET_FILE"; then
        # 5. Reload Hyprland to apply changes immediately
        if command -v hyprctl &>/dev/null; then
            hyprctl reload &>/dev/null
        fi

        printf "[${C_GREY}%s${C_RESET}] ${C_BLUE}[INFO]${C_RESET}  Switched animation to: ${C_GREEN}dusky${C_RESET}\n" \
            "$(date +%T)"
    else
        printf "[${C_GREY}%s${C_RESET}] ${C_RED}[ERROR]${C_RESET} Failed to copy config to: %s\n" \
            "$(date +%T)" "$TARGET_FILE" >&2
        exit 1
    fi
}

main "$@"
