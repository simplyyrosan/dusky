#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Git Checker & TUI Viewer (v5.4 - Fix Command Substitution)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / Bare Git Repo
# Requires: Bash 5.0+, git, coreutils (timeout)
# -----------------------------------------------------------------------------

set -euo pipefail
export LC_NUMERIC=C LC_COLLATE=C

# =============================================================================
# CONFIGURATION
# =============================================================================

declare -r GIT_DIR="${HOME}/dusky/"
declare -r WORK_TREE="${HOME}"
declare -r STATE_FILE="${HOME}/.config/dusky/settings/dusky_update_behind_commit"
declare -r STATE_DIR="${STATE_FILE%/*}"

declare -ri NOTIFY_THRESHOLD=30
declare -ri TIMEOUT_SEC=15

# TUI Settings
declare -r APP_TITLE="Dusky Updates"
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ITEM_PADDING=14
# Row where commit list starts (1-indexed for mouse calculation)
declare -ri ITEM_START_ROW=5

# Debug mode (can be set via environment or --debug flag)
declare -i DEBUG=${DEBUG:-0}

# Refspec for bare repo fetch (ensures refs/remotes/origin/* is updated)
declare -r FETCH_REFSPEC='+refs/heads/*:refs/remotes/origin/*'

# Git Command Array
declare -ra GIT_CMD=(/usr/bin/git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE")

# =============================================================================
# UTILITIES
# =============================================================================

_debug() {
    (( DEBUG )) || return 0
    printf '[DEBUG] %s\n' "$*" >&2
}

# Pure-bash sleep alternative using read timeout
_sleep() {
    local -r seconds="${1:-1}"
    read -rt "$seconds" <> <(:) 2>/dev/null || true
}

# Strip ANSI codes using Namerefs
# Usage: _strip_ansi "input_string" output_variable_name
_strip_ansi() {
    local str="$1"
    local -n _out_ref=$2
    _out_ref=""
    while [[ "$str" =~ ^([^$'\e']*)\e\[[0-9\;]*m(.*)$ ]]; do
        _out_ref+="${BASH_REMATCH[1]}"
        str="${BASH_REMATCH[2]}"
    done
    _out_ref+="$str"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_environment() {
    if (( BASH_VERSINFO[0] < 5 )); then
        printf 'ERROR: Bash 5.0+ required (found %s)\n' "$BASH_VERSION" >&2
        return 1
    fi

    if [[ ! -d "$GIT_DIR" ]]; then
        printf 'ERROR: Git directory not found: %s\n' "$GIT_DIR" >&2
        return 1
    fi

    if [[ ! -f "${GIT_DIR}/HEAD" ]]; then
        printf 'ERROR: Not a valid git directory: %s\n' "$GIT_DIR" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# ROBUST FETCH LOGIC
# =============================================================================

declare FETCH_INFO=""

robust_fetch() {
    FETCH_INFO=""

    # FIX: Added $() wrapper to execute the command and capture output
    local origin_url
    if ! origin_url=$("${GIT_CMD[@]}" remote get-url origin 2>/dev/null); then
        FETCH_INFO="No 'origin' remote configured"
        _debug "No origin remote found"
        return 1
    fi
    _debug "Origin URL: $origin_url"

    # Attempt 1: Fetch via configured remote
    _debug "Trying: git fetch origin with refspec"
    # NOTE: timeout executes the command directly, so no $() needed here.
    if timeout "$TIMEOUT_SEC" "${GIT_CMD[@]}" fetch --quiet origin "$FETCH_REFSPEC" 2>/dev/null; then
        FETCH_INFO="Fetched via origin"
        _debug "Fetch succeeded"
        return 0
    fi
    _debug "Primary fetch failed, attempting HTTPS fallback"

    # Attempt 2: HTTPS Fallback
    local https_url=""

    if [[ "$origin_url" =~ ^git@([^:]+):(.+)$ ]]; then
        https_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$origin_url" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
        https_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$origin_url" =~ ^https:// ]]; then
        https_url="$origin_url"
    else
        FETCH_INFO="Cannot parse URL: ${origin_url:0:40}"
        _debug "URL format not recognized"
        return 1
    fi

    https_url="${https_url%.git}"
    _debug "HTTPS URL: $https_url"

    if timeout "$TIMEOUT_SEC" "${GIT_CMD[@]}" fetch --quiet "$https_url" "$FETCH_REFSPEC" 2>/dev/null; then
        FETCH_INFO="Fetched via HTTPS fallback"
        _debug "HTTPS fetch succeeded"
        return 0
    fi

    FETCH_INFO="All fetch methods failed"
    _debug "All fetch attempts exhausted"
    return 1
}

# =============================================================================
# UPSTREAM DETECTION
# =============================================================================

get_upstream_ref() {
    # FIX: Added $() wrapper
    local tracking
    if tracking=$("${GIT_CMD[@]}" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) && [[ -n "$tracking" ]]; then
        printf '%s' "$tracking"
        return 0
    fi

    local ref
    for ref in origin/main origin/master; do
        if "${GIT_CMD[@]}" rev-parse --verify --quiet "$ref" &>/dev/null; then
            printf '%s' "$ref"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# BACKGROUND MODE (--num)
# =============================================================================

run_background_check() {
    [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"

    if ! robust_fetch; then
        _debug "Fetch failed, writing -1"
        printf -- '%d\n' -1 > "$STATE_FILE"
        exit 0
    fi

    local upstream
    if ! upstream=$(get_upstream_ref); then
        _debug "No upstream found, writing -2"
        printf -- '%d\n' -2 > "$STATE_FILE"
        exit 0
    fi
    _debug "Upstream: $upstream"

    local -i count=0
    # FIX: Added $() wrapper
    count=$("${GIT_CMD[@]}" rev-list --count "HEAD..${upstream}" 2>/dev/null) || count=0
    _debug "Commits behind: $count"

    printf -- '%d\n' "$count" > "$STATE_FILE"

    if (( count >= NOTIFY_THRESHOLD )) && command -v notify-send &>/dev/null; then
        notify-send -u normal -t 5000 -i software-update-available \
            "Dusky Dotfiles" \
            "Update Available: Your system is ${count} commits behind."
    fi

    exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --num)
                run_background_check
                ;;
            --debug)
                DEBUG=1
                _debug "Debug mode enabled"
                shift
                ;;
            --fix-config)
                printf 'Adding fetch refspec to git config...\n'
                "${GIT_CMD[@]}" config remote.origin.fetch "$FETCH_REFSPEC"
                printf 'Done. Current value:\n'
                "${GIT_CMD[@]}" config --get remote.origin.fetch
                exit 0
                ;;
            --help|-h)
                printf 'Usage: %s [OPTIONS]\n\n' "${0##*/}"
                printf 'Options:\n'
                printf '  --num        Output commit count to state file (for Waybar)\n'
                printf '  --debug      Enable debug output\n'
                printf '  --fix-config Add fetch refspec to git config\n'
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                exit 1
                ;;
        esac
    done
}

parse_arguments "$@"

# =============================================================================
# ANSI ESCAPE CODES
# =============================================================================

declare _hbuf
printf -v _hbuf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_hbuf// /─}"
unset _hbuf

declare -r C_RESET=$'\e[0m'     C_CYAN=$'\e[1;36m'    C_GREEN=$'\e[1;32m'
declare -r C_YELLOW=$'\e[1;33m' C_MAGENTA=$'\e[1;35m' C_WHITE=$'\e[1;37m'
declare -r C_GREY=$'\e[1;30m'   C_RED=$'\e[1;31m'     C_INVERSE=$'\e[7m'

declare -r CLR_EOL=$'\e[K'      CLR_EOS=$'\e[J'       CLR_SCREEN=$'\e[2J'
declare -r CUR_HOME=$'\e[H'     CUR_HIDE=$'\e[?25l'   CUR_SHOW=$'\e[?25h'
declare -r MOUSE_ON=$'\e[?1000h\e[?1002h\e[?1006h'
declare -r MOUSE_OFF=$'\e[?1000l\e[?1002l\e[?1006l'

# =============================================================================
# TUI STATE
# =============================================================================

declare -i SELECTED_ROW=0 SCROLL_OFFSET=0
declare -i TOTAL_COMMITS=0 LOCAL_REV=0 REMOTE_REV=0
declare -a COMMIT_HASHES=() COMMIT_MSGS=()
declare ORIGINAL_STTY="" FETCH_STATUS="OK"

cleanup() {
    printf '%s%s%s\n' "$MOUSE_OFF" "$CUR_SHOW" "$C_RESET"
    [[ -n "${ORIGINAL_STTY:-}" ]] && stty "$ORIGINAL_STTY" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# =============================================================================
# DATA LOADING
# =============================================================================

load_commits() {
    COMMIT_HASHES=()
    COMMIT_MSGS=()

    local upstream
    if ! upstream=$(get_upstream_ref); then
        COMMIT_HASHES=("ERR")
        COMMIT_MSGS=("No upstream branch found (try: git branch -u origin/main)")
        TOTAL_COMMITS=1
        FETCH_STATUS="NO_UPSTREAM"
        LOCAL_REV=0
        REMOTE_REV=0
        return
    fi

    # FIX: Added $() wrappers here
    LOCAL_REV=$("${GIT_CMD[@]}" rev-list --count HEAD 2>/dev/null) || LOCAL_REV=0
    REMOTE_REV=$("${GIT_CMD[@]}" rev-list --count "$upstream" 2>/dev/null) || REMOTE_REV=0

    local -i count=0
    count=$("${GIT_CMD[@]}" rev-list --count "HEAD..${upstream}" 2>/dev/null) || count=0

    _debug "load_commits: HEAD=$LOCAL_REV, upstream=$REMOTE_REV, behind=$count"

    if (( count == 0 )); then
        if [[ "$FETCH_STATUS" == "FAIL" ]]; then
            COMMIT_HASHES=("ERR")
            COMMIT_MSGS=("Fetch failed - cannot verify status")
            TOTAL_COMMITS=1
            return
        fi
        COMMIT_HASHES=("HEAD")
        COMMIT_MSGS=("Dusky is up to date!")
        TOTAL_COMMITS=1
        return
    fi

    local -ri max_len=$(( BOX_INNER_WIDTH - ITEM_PADDING - 6 ))
    local hash msg

    # FIX: Added $() wrapper for process substitution
    while IFS='|' read -r hash msg; do
        [[ -z "$hash" ]] && continue
        COMMIT_HASHES+=("$hash")
        if (( ${#msg} > max_len )); then
            msg="${msg:0:max_len-1}…"
        fi
        COMMIT_MSGS+=("$msg")
    done < <("${GIT_CMD[@]}" --no-pager log "HEAD..${upstream}" --no-color --pretty=format:'%h|%s' 2>/dev/null)

    TOTAL_COMMITS=${#COMMIT_HASHES[@]}

    # Safety: if rev-list said N commits but log returned empty
    if (( TOTAL_COMMITS == 0 )); then
        COMMIT_HASHES=("WARN")
        COMMIT_MSGS=("Detected $count updates but log was empty")
        TOTAL_COMMITS=1
    fi
}

# =============================================================================
# UI ENGINE
# =============================================================================

draw_ui() {
    local buf="" pad_buf=""
    local -i visible_len left_pad right_pad
    local -i vstart vend i

    buf+="$CUR_HOME"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    # -------------------------------------------------------------------------
    # TITLE LINE - using dusky_tui.sh template dynamic centering logic
    # -------------------------------------------------------------------------
    local plain_title="${APP_TITLE} Local: #${LOCAL_REV} vs Remote: #${REMOTE_REV}"
    visible_len=${#plain_title}
    
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    # Safety clamp for padding
    (( left_pad < 0 )) && left_pad=0
    
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))
    (( right_pad < 0 )) && right_pad=0

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_GREY}Local: #${LOCAL_REV} vs Remote: #${REMOTE_REV}"
    
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}${C_MAGENTA}│${C_RESET}"$'\n'

    # -------------------------------------------------------------------------
    # STATUS LINE - FIXED: Manual length calculation for pixel-perfect alignment
    # -------------------------------------------------------------------------
    local stats="" plain_stats=""
    case "$FETCH_STATUS" in
        FAIL)
            stats="${C_RED}Fetch Failed: ${FETCH_INFO:0:45}${C_RESET}"
            plain_stats="Fetch Failed: ${FETCH_INFO:0:45}"
            ;;
        NO_UPSTREAM)
            stats="${C_RED}Status: No Upstream Branch${C_RESET}"
            plain_stats="Status: No Upstream Branch"
            ;;
        *)
            case "${COMMIT_HASHES[0]:-}" in
                HEAD) 
                    stats="${C_GREEN}Status: Up to date${C_RESET}" 
                    plain_stats="Status: Up to date"
                    ;;
                WARN) 
                    stats="${C_YELLOW}Status: Log Error${C_RESET}" 
                    plain_stats="Status: Log Error"
                    ;;
                ERR)  
                    stats="${C_RED}Status: Error${C_RESET}" 
                    plain_stats="Status: Error"
                    ;;
                *)    
                    stats="${C_YELLOW}Commits Behind: ${TOTAL_COMMITS}${C_RESET}" 
                    plain_stats="Commits Behind: ${TOTAL_COMMITS}"
                    ;;
            esac
            ;;
    esac

    # Calculate right padding based on explicit plain text length
    # The visible content is " " + plain_stats
    visible_len=$(( ${#plain_stats} + 1 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len ))
    (( right_pad < 0 )) && right_pad=0

    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${C_MAGENTA}│ ${stats}${pad_buf}${C_MAGENTA}│${C_RESET}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # -------------------------------------------------------------------------
    # SCROLL BOUNDS & INDICATORS
    # -------------------------------------------------------------------------
    if (( TOTAL_COMMITS > 0 )); then
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= TOTAL_COMMITS )) && SELECTED_ROW=$(( TOTAL_COMMITS - 1 ))
        (( SELECTED_ROW < SCROLL_OFFSET )) && SCROLL_OFFSET=$SELECTED_ROW
        (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )) && \
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    else
        SELECTED_ROW=0
        SCROLL_OFFSET=0
    fi

    vstart=$SCROLL_OFFSET
    vend=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( vend > TOTAL_COMMITS )) && vend=$TOTAL_COMMITS

    # "More above" indicator
    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Commit list
    for (( i = vstart; i < vend; i++ )); do
        local h="${COMMIT_HASHES[i]}" m="${COMMIT_MSGS[i]}" ph
        printf -v ph "%-${ITEM_PADDING}s" "$h"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${ph}${C_RESET} : ${C_WHITE}${m}${C_RESET}${CLR_EOL}"$'\n'
        else
            buf+="    ${C_GREY}${ph}${C_RESET} : ${C_GREY}${m}${C_RESET}${CLR_EOL}"$'\n'
        fi
    done

    # Fill remaining rows
    for (( i = vend - vstart; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    # "More below" indicator
    if (( TOTAL_COMMITS > MAX_DISPLAY_ROWS )); then
        local pos="[$(( SELECTED_ROW + 1 ))/${TOTAL_COMMITS}]"
        if (( vend < TOTAL_COMMITS )); then
            buf+="${C_GREY}    ▼ (more below) ${pos}${CLR_EOL}${C_RESET}"$'\n'
        else
            buf+="${C_GREY}                   ${pos}${CLR_EOL}${C_RESET}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Help footer
    buf+=$'\n'"${C_CYAN} [↑↓/jk] Move  [PgUp/Dn] Page  [g/G] Start/End  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} Repo: ${C_WHITE}${GIT_DIR}${C_RESET}${CLR_EOL}${CLR_EOS}"
    printf '%s' "$buf"
}

# =============================================================================
# NAVIGATION
# =============================================================================

nav_step() {
    local -i d=$1
    (( TOTAL_COMMITS == 0 )) && return
    SELECTED_ROW=$(( (SELECTED_ROW + d + TOTAL_COMMITS) % TOTAL_COMMITS ))
}

nav_page() {
    local -i d=$1
    (( TOTAL_COMMITS == 0 )) && return
    SELECTED_ROW=$(( SELECTED_ROW + d * MAX_DISPLAY_ROWS ))
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= TOTAL_COMMITS )) && SELECTED_ROW=$(( TOTAL_COMMITS - 1 ))
}

nav_edge() {
    (( TOTAL_COMMITS == 0 )) && return
    case $1 in
        home) SELECTED_ROW=0 ;;
        end)  SELECTED_ROW=$(( TOTAL_COMMITS - 1 )) ;;
    esac
}

handle_mouse() {
    local seq=$1
    local re='^\[<([0-9]+);[0-9]+;([0-9]+)([Mm])$'
    [[ $seq =~ $re ]] || return 0

    local -i btn=${BASH_REMATCH[1]} row=${BASH_REMATCH[2]}
    local act=${BASH_REMATCH[3]}

    case $btn in
        64) nav_step -1; return ;;
        65) nav_step 1; return ;;
    esac

    [[ $act == M ]] || return
    local -i idx=$(( row - ITEM_START_ROW - 1 + SCROLL_OFFSET ))
    (( idx >= 0 && idx < TOTAL_COMMITS )) && SELECTED_ROW=$idx
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    validate_environment || exit 1

    printf '\n%sFetching updates from origin...%s\n' "$C_CYAN" "$C_RESET"

    if ! robust_fetch; then
        printf '%s[WARNING] Fetch failed: %s%s\n' "$C_YELLOW" "$FETCH_INFO" "$C_RESET"
        FETCH_STATUS="FAIL"
        _sleep 2
    else
        printf '%s[OK] %s%s\n' "$C_GREEN" "$FETCH_INFO" "$C_RESET"
        _sleep 1
    fi

    load_commits

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || true
    printf '%s%s%s%s' "$MOUSE_ON" "$CUR_HIDE" "$CLR_SCREEN" "$CUR_HOME"

    local key seq ch
    while true; do
        draw_ui
        IFS= read -rsn1 key || break

        if [[ $key == $'\e' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.05 ch; do
                seq+="$ch"
            done
            case $seq in
                '')          break ;;
                '[A'|OA)     nav_step -1 ;;
                '[B'|OB)     nav_step 1 ;;
                '[5~')       nav_page -1 ;;
                '[6~')       nav_page 1 ;;
                '[H'|'[1~')  nav_edge home ;;
                '[F'|'[4~')  nav_edge end ;;
                '['*'<'*)    handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)         nav_step -1 ;;
                j|J)         nav_step 1 ;;
                g)           nav_edge home ;;
                G)           nav_edge end ;;
                q|Q|$'\x03') break ;;
            esac
        fi
    done
}

main
