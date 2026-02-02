#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky TUI Engine - Master Template v2.3
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM
# Description: High-performance, robust TUI for config modification.
# Features:
#   - Secure `sed` Injection Prevention
#   - Nested Block Support (Fixes "Range Trap")
#   - Locale Safe (Fixes "Comma Bomb")
#   - Terminal State Preservation (stty)
#   - Scrollable Viewport with Indicators
#   - Mouse Support (SGR 1006)
# -----------------------------------------------------------------------------

set -euo pipefail

# CRITICAL FIX: The "Locale Bomb"
# Force standard C locale for numeric operations.
# This prevents awk from outputting commas (0,5) in non-US locales,
# which would corrupt the config file.
export LC_NUMERIC=C

# =============================================================================
# ▼ USER CONFIGURATION (EDIT THIS SECTION) ▼
# =============================================================================

readonly CONFIG_FILE="${HOME}/.config/hypr/change_me.conf"
readonly APP_TITLE="Dusky Template"
readonly APP_VERSION="v2.3"

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14      # Rows of items to show before scrolling
declare -ri BOX_INNER_WIDTH=76       # Width of the UI box
declare -ri ITEM_START_ROW=5         # Row index where items begin rendering
declare -ri ADJUST_THRESHOLD=40      # X-pos threshold for mouse click adjustment
declare -ri ITEM_PADDING=32          # Text padding for labels

readonly -a TABS=("General" "Input" "Display" "Misc")

# Item Registration
# Syntax: register <tab_idx> "Label" "config_str" "DEFAULT_VALUE"
register_items() {
    register 0 "Enable Logs"    'logs_enabled|bool|general|||'       "true"
    register 0 "Timeout (ms)"   'timeout|int|general|0|1000|50'      "100"
    register 1 "Sensitivity"    'sensitivity|float|input|-1.0|1.0|0.1' "0.0"
    register 2 "Accel Profile"  'accel_profile|cycle|input|flat,adaptive,custom||' "adaptive"
    register 2 "Border Size"    'border_size|int||0|10|1'            "2"
    register 3 "Shadow Color"   'col.shadow|cycle|general|0xee1a1a1a,0xff000000||' "0xee1a1a1a"
}

# =============================================================================
# ▲ END OF USER CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _H_LINE_BUF
printf -v _H_LINE_BUF '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE="${_H_LINE_BUF// /─}"

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# Timeout for reading escape sequences (in seconds)
readonly -r ESC_READ_TIMEOUT=0.02

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()

# Provisioned Tab Containers (0-9) to avoid sparse array errors
# shellcheck disable=SC2034
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()
# shellcheck disable=SC2034
declare -a TAB_ITEMS_5=() TAB_ITEMS_6=() TAB_ITEMS_7=() TAB_ITEMS_8=() TAB_ITEMS_9=()

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$C_MAGENTA" "$C_RESET" "$1" >&2
}

cleanup() {
    # Restore terminal state (Mouse, Cursor, Colors)
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    
    # Robustly restore original stty settings
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    
    printf '\n'
}

# Escape special characters for sed REPLACEMENT string
escape_sed_replacement() {
    local -n __out=$2
    local _s=$1
    # Order matters: backslash first
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}      # Escape delimiter
    _s=${_s//&/\\&}      # Escape backreference
    _s=${_s//$'\n'/\\n}  # Escape newlines
    __out=$_s
}

# Escape special characters for sed PATTERN (Basic Regex)
escape_sed_pattern() {
    local -n __out=$2
    local _s=$1
    # Escape BRE metacharacters: \ . * [ ^ $ AND delimiter |
    _s=${_s//\\/\\\\}
    _s=${_s//|/\\|}      # CRITICAL: Escape delimiter used in sed command
    _s=${_s//./\\.}
    _s=${_s//\*/\\*}
    _s=${_s//\[/\\[}
    _s=${_s//^/\\^}
    _s=${_s//\$/\\\$}
    __out=$_s
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Core Engine ---

register() {
    local -i tab_idx=$1
    local label=$2 config=$3 default_val=${4:-}

    if (( tab_idx < 0 || tab_idx > 9 )); then
        printf '%s[FATAL]%s Tab index %d out of bounds (0-9)\n' \
               "$C_RED" "$C_RESET" "$tab_idx" >&2
        exit 1
    fi

    ITEM_MAP["$label"]=$config
    [[ -n "$default_val" ]] && DEFAULTS["$label"]=$default_val

    # shellcheck disable=SC2178
    local -n tab_ref="TAB_ITEMS_${tab_idx}"
    # shellcheck disable=SC2034
    tab_ref+=("$label")
}

populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part; do
        [[ -z $key_part ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part

        key_name=${key_part%%|*}
        # Fallback: only set if unset (first occurrence wins)
        [[ -z ${CONFIG_CACHE["$key_name|"]:-} ]] && CONFIG_CACHE["$key_name|"]=$value_part
    done < <(awk '
        BEGIN { depth = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/#.*/, "", line)

            if (match(line, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_str = substr(line, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_str)
                depth++
                block_stack[depth] = block_str
            }

            if (line ~ /=/) {
                eq_pos = index(line, "=")
                if (eq_pos > 0) {
                    key = substr(line, 1, eq_pos - 1)
                    val = substr(line, eq_pos + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }

            n = gsub(/\}/, "}", line)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
    ' "$CONFIG_FILE")
}

write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local current_val=${CONFIG_CACHE["$key|$block"]:-}
    
    # Dirty check: skip write if value unchanged
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val safe_key safe_block
    escape_sed_replacement "$new_val" safe_val
    escape_sed_pattern "$key" safe_key

    if [[ -n $block ]]; then
        escape_sed_pattern "$block" safe_block
        
        # CRITICAL FIX: The "Nested Block Range Trap"
        # We cannot rely on sed range /start/,/}/ because it stops at ANY closing brace,
        # breaking nested configs (e.g., editing a key inside decoration{...} that follows blur{...}).
        # Instead, we identify the EXACT start and end lines of the block by counting braces.
        
        local start_line
        # Find the first line where the block starts
        start_line=$(grep -n "^[[:space:]]*${safe_block}[[:space:]]*{" "$CONFIG_FILE" | head -n1 | cut -d: -f1)
        
        if [[ -n $start_line ]]; then
            local end_line_offset
            
            # Count braces starting from the block line to find the matching closing brace
            end_line_offset=$(tail -n "+$start_line" "$CONFIG_FILE" | awk '
                BEGIN { depth=0; found=0 }
                {
                    txt = $0
                    sub(/#.*/, "", txt) # Remove comments to avoid false brace counts

                    # Count occurrences of { and }
                    n_open = gsub(/{/, "&", txt);
                    n_close = gsub(/}/, "&", txt);
                    
                    depth += n_open - n_close;
                    
                    # We are in the block once we process the first line (tail guarantees this)
                    if (NR == 1) found=1
                    
                    if (found && depth <= 0) {
                        print NR
                        exit
                    }
                }
            ')
            
            if [[ -n $end_line_offset ]]; then
                local -i real_end_line=$(( start_line + end_line_offset - 1 ))
                
                # Apply substitution ONLY within the strictly calculated range
                # Robust sed: uses | delimiter, follows symlinks
                sed --follow-symlinks -i \
                    "${start_line},${real_end_line}s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)\([^#]*\)|\1${safe_val} |" \
                    "$CONFIG_FILE"
            fi
        fi
    else
        # Global key update (no block context)
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${safe_key}[[:space:]]*=[[:space:]]*\)\([^#]*\)|\1${safe_val} |" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block"]=$new_val
    [[ -z $block ]] && CONFIG_CACHE["$key|"]=$new_val
}

load_tab_values() {
    # shellcheck disable=SC2178
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        val=${CONFIG_CACHE["$key|$block"]:-}
        VALUE_CACHE["$item"]=${val:-unset}
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP[$label]}"
    current=${VALUE_CACHE[$label]:-}
    [[ $current == "unset" ]] && current=""

    case $type in
        int)
            [[ ! $current =~ ^-?[0-9]+$ ]] && current=${min:-0}
            local -i int_step=${step:-1} int_val=$current
            (( int_val += direction * int_step )) || :
            
            [[ -n $min ]] && (( int_val < min )) && int_val=$min
            [[ -n $max ]] && (( int_val > max )) && int_val=$max
            new_val=$int_val
            ;;
        float)
            [[ ! $current =~ ^-?[0-9]*\.?[0-9]+$ ]] && current=${min:-0.0}
            # Note: LC_NUMERIC=C is set globally, so awk is safe here.
            new_val=$(awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" 'BEGIN {
                val = c + (dir * s)
                if (mn != "" && val < mn) val = mn
                if (mx != "" && val > mx) val = mx
                printf "%.4g", val
            }')
            ;;
        bool)
            [[ $current == "true" ]] && new_val="false" || new_val="true"
            ;;
        cycle)
            local -a opts
            IFS=',' read -r -a opts <<< "$min"
            local -i count=${#opts[@]} idx=0 i
            
            (( count == 0 )) && return 0

            for (( i = 0; i < count; i++ )); do
                [[ "${opts[i]}" == "$current" ]] && { idx=$i; break; }
            done
            
            (( idx += direction )) || :
            (( idx < 0 )) && idx=$(( count - 1 ))
            (( idx >= count )) && idx=0
            new_val=${opts[idx]}
            ;;
        *)
            return 0
            ;;
    esac

    write_value_to_file "$key" "$new_val" "$block"
    VALUE_CACHE["$label"]=$new_val
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block

    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$label]}"
    write_value_to_file "$key" "$new_val" "$block"
    VALUE_CACHE["$label"]=$new_val
}

reset_defaults() {
    # shellcheck disable=SC2178
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val

    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        [[ -n $def_val ]] && set_absolute_value "$item" "$def_val"
    done
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad
    local -i visible_start visible_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    # Header - Dynamic Centering
    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    # Tab bar rendering
    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        len=${#name}
        zone_start=$current_col

        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi

        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 )) || :
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # Items Rendering with scroll support
    # shellcheck disable=SC2178
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    count=${#items_ref[@]}

    # Bounds checking & Scroll Calculation
    if (( count == 0 )); then
        SELECTED_ROW=0
        SCROLL_OFFSET=0
    else
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))

        # Auto-scroll to keep selection visible
        if (( SELECTED_ROW < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$SELECTED_ROW
        elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
        fi

        # Clamp scroll offset
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
        local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
        (( max_scroll < 0 )) && max_scroll=0
        (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    # Top Scroll Indicator
    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Render Visible Items
    for (( i = visible_start; i < visible_end; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-unset}

        case $val in
            true)     display="${C_GREEN}ON${C_RESET}" ;;
            false)    display="${C_RED}OFF${C_RESET}" ;;
            unset)    display="${C_RED}unset${C_RESET}" ;;
            *'$'*)    display="${C_MAGENTA}Dynamic${C_RESET}" ;;
            *)        display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:$ITEM_PADDING}"

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    # Pad remaining rows to maintain stable height
    local -i rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    # Bottom Scroll Indicator
    if (( visible_end < count )); then
        buf+="${C_GREY}    ▼ (more below)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    # shellcheck disable=SC2178
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}

    (( count == 0 )) && return 0
    (( SELECTED_ROW += dir )) || :

    # Wrap selection
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
}

adjust() {
    local -i dir=$1
    # shellcheck disable=SC2178
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"

    (( ${#items_ref[@]} == 0 )) && return 0
    modify_value "${items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}

    (( CURRENT_TAB += dir )) || :
    (( CURRENT_TAB >= TAB_COUNT )) && CURRENT_TAB=0
    (( CURRENT_TAB < 0 )) && CURRENT_TAB=$(( TAB_COUNT - 1 ))

    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    local -i idx=$1

    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end

    # SGR Mouse Mode (1006)
    if [[ $input =~ ^\[\<([0-9]+);([0-9]+);([0-9]+)([Mm])$ ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}

        # Only handle Button Press ('M'), ignore Release ('m')
        [[ $type != "M" ]] && return 0

        # Tab bar click detection (Row 3)
        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}
                start=${zone%%:*}
                end=${zone##*:}
                if (( x >= start && x <= end )); then
                    set_tab "$i"
                    return 0
                fi
            done
        fi

        # Item click detection (accounting for top indicator offset)
        # shellcheck disable=SC2178
        local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#items_ref[@]}
        local -i item_row_start=$(( ITEM_START_ROW + 1 ))

        if (( y >= item_row_start && y < item_row_start + MAX_DISPLAY_ROWS )); then
            local -i clicked_idx=$(( y - item_row_start + SCROLL_OFFSET ))
            if (( clicked_idx >= 0 && clicked_idx < count )); then
                SELECTED_ROW=$clicked_idx
                if (( x > ADJUST_THRESHOLD )); then
                    (( button == 0 )) && adjust 1 || adjust -1
                fi
            fi
        fi
    fi
}

# --- Main ---

main() {
    # 1. Config Validation
    if [[ ! -f $CONFIG_FILE ]]; then
        log_err "Config not found: $CONFIG_FILE"
        exit 1
    fi
    if [[ ! -r $CONFIG_FILE ]]; then
        log_err "Config not readable: $CONFIG_FILE"
        exit 1
    fi
    if [[ ! -w $CONFIG_FILE ]]; then
        log_err "Config not writable: $CONFIG_FILE"
        exit 1
    fi

    # 2. Dependency Check
    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }

    # 3. Initialization
    register_items
    populate_config_cache

    # 4. Save Terminal State
    if command -v stty &>/dev/null; then
        ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    fi

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_tab_values

    local key seq char

    # 5. Event Loop
    while true; do
        draw_ui

        # Safety: break on EOF to prevent 100% CPU loops
        IFS= read -rsn1 key || break

        if [[ $key == $'\x1b' ]]; then
            seq=""
            # Fast timeout for escape sequences
            while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
                seq+="$char"
            done

            case $seq in
                '[Z')          switch_tab -1 ;; # Shift+Tab
                '[A'|'OA')     navigate -1 ;;   # Arrow Up
                '[B'|'OB')     navigate 1 ;;    # Arrow Down
                '[C'|'OC')     adjust 1 ;;      # Arrow Right
                '[D'|'OD')     adjust -1 ;;     # Arrow Left
                '['*'<'*)      handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                l|L)           adjust 1 ;;
                h|H)           adjust -1 ;;
                $'\t')         switch_tab 1 ;;
                r|R)           reset_defaults ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done
}

main "$@"
