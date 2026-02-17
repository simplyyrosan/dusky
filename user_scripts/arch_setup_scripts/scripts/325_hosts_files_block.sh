#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# FocusForge TUI - Master v2.1.0
# -----------------------------------------------------------------------------
# Engine: Dusky TUI v3.9.5 (Strict Port)
# Target: Arch Linux / Hyprland / UWSM / Wayland
# Purpose: High-performance /etc/hosts manager for deep work focus.
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

declare -r HOSTS_FILE="/etc/hosts"
declare -r BACKUP_FILE="/etc/hosts.backup.focusforge"
declare -r REDIRECT_IP="0.0.0.0"
declare -r APP_TITLE="Dusky Site Blocker"
declare -r APP_VERSION="v2.1.0 (Stable)"

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38
declare -ri ITEM_PADDING=42

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

# Categories (Tabs)
declare -ra TABS=("Social" "Video" "News" "Gambling" "Custom")

# Domain Database (Category Index | Domain Name)
declare -ra DOMAIN_DB=(
    # 0: Social
    "0|facebook.com" "0|twitter.com" "0|x.com" "0|instagram.com" 
    "0|reddit.com" "0|linkedin.com" "0|tiktok.com" "0|pinterest.com"
    "0|tumblr.com" "0|snapchat.com" "0|threads.net" "0|discord.com"

    # 1: Video / Stream
    "1|youtube.com" "1|twitch.tv" "1|netflix.com" "1|hulu.com"
    "1|disneyplus.com" "1|primevideo.com" "1|kick.com" "1|vimeo.com"

    # 2: News / Tabloids
    "2|cnn.com" "2|foxnews.com" "2|bbc.com" "2|nytimes.com"
    "2|buzzfeed.com" "2|dailymail.co.uk" "2|tmz.com" "2|forbes.com"

    # 3: Gambling / Trading
    "3|bet365.com" "3|draftkings.com" "3|pokerstars.com" "3|roobet.com"
    "3|binance.com" "3|coinbase.com" "3|robinhood.com" "3|tradingview.com"
)

# Special Button Constant
declare -r ADD_BUTTON_LABEL="[+] Add New Domain"

# =============================================================================
# ▼ CORE ENGINE (Dusky v3.9.5) ▼
# =============================================================================

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# --- ANSI Constants ---
declare -r C_RESET=$'\033[0m'
declare -r C_CYAN=$'\033[1;36m'
declare -r C_GREEN=$'\033[1;32m'
declare -r C_MAGENTA=$'\033[1;35m'
declare -r C_RED=$'\033[1;31m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_WHITE=$'\033[1;37m'
declare -r C_GREY=$'\033[1;30m'
declare -r C_INVERSE=$'\033[7m'
declare -r CLR_EOL=$'\033[K'
declare -r CLR_EOS=$'\033[J'
declare -r CLR_SCREEN=$'\033[2J'
declare -r CURSOR_HOME=$'\033[H'
declare -r CURSOR_HIDE=$'\033[?25l'
declare -r CURSOR_SHOW=$'\033[?25h'
declare -r MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
declare -r MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

declare -r ESC_READ_TIMEOUT=0.01

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare -i TAB_SCROLL_START=0

# View State
declare -i CURRENT_VIEW=0      # 0=Main List, 1=Input Modal
declare INPUT_BUFFER=""        # For custom domain input

# Temp file global
declare _TMPFILE=""
declare ORIGINAL_STTY=""

# --- Click Zones ---
declare LEFT_ARROW_ZONE=""
declare RIGHT_ARROW_ZONE=""

# --- Data Structures ---
for (( _ti = 0; _ti < TAB_COUNT; _ti++ )); do
    declare -ga "TAB_ITEMS_${_ti}=()"
done
unset _ti

declare -A IS_BLOCKED=()

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
    sleep 2
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    if [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

strip_ansi() {
    local v="$1"
    v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
    REPLY="$v"
}

# =============================================================================
# ▼ LOGIC ENGINE ▼
# =============================================================================

init_db() {
    local entry cat domain
    for entry in "${DOMAIN_DB[@]}"; do
        IFS='|' read -r cat domain <<< "$entry"
        local -n _tab_ref="TAB_ITEMS_${cat}"
        _tab_ref+=("$domain")
    done

    # Initialize Custom Tab with the "Add" button pinned at top
    TAB_ITEMS_4=("$ADD_BUTTON_LABEL")
}

refresh_state() {
    IS_BLOCKED=()
    local domain
    
    while read -r line; do
        if [[ "$line" =~ ^0\.0\.0\.0[[:space:]]+([^[:space:]#]+) ]]; then
            domain="${BASH_REMATCH[1]}"
            IS_BLOCKED["$domain"]=1
            
            # Check standard tabs
            local found=0
            local t d
            for t in {0..3}; do
                local -n _check_tab="TAB_ITEMS_$t"
                for d in "${_check_tab[@]}"; do
                    [[ "$d" == "$domain" ]] && found=1 && break
                done
                (( found )) && break
            done
            
            # If not in standard tabs, add to Custom (Tab 4)
            if (( found == 0 )); then
                local exists_in_custom=0
                for d in "${TAB_ITEMS_4[@]}"; do
                    [[ "$d" == "$domain" ]] && exists_in_custom=1 && break
                done
                if (( exists_in_custom == 0 )); then
                    TAB_ITEMS_4+=("$domain")
                fi
            fi
        fi
    done < "$HOSTS_FILE"
}

toggle_domain() {
    local domain="$1"
    # Safety check: never try to block the button label
    if [[ "$domain" == "$ADD_BUTTON_LABEL" ]]; then return; fi

    local current_state="${IS_BLOCKED["$domain"]:-0}"
    local new_state=$(( 1 - current_state ))

    _TMPFILE=$(mktemp)

    if (( new_state == 1 )); then
        # BLOCKING
        awk -v d="$domain" -v ip="$REDIRECT_IP" '
        { print $0 }
        END { print ip " " d }
        ' "$HOSTS_FILE" > "$_TMPFILE"
    else
        # UNBLOCKING
        awk -v d="$domain" '
        $1 == "0.0.0.0" && $2 == d { next } 
        $1 == "0.0.0.0" && $2 == "www."d { next }
        { print $0 }
        ' "$HOSTS_FILE" > "$_TMPFILE"
    fi

    if [[ ! -s "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE"
        return 1
    fi

    cat "$_TMPFILE" > "$HOSTS_FILE"
    rm -f "$_TMPFILE"
    _TMPFILE=""

    # Handle www. prefix
    if [[ "$domain" != www.* ]]; then
        if (( new_state == 1 )); then
             if ! grep -q "0.0.0.0 www.$domain" "$HOSTS_FILE"; then
                 echo "$REDIRECT_IP www.$domain" >> "$HOSTS_FILE"
             fi
        else
             _TMPFILE=$(mktemp)
             awk -v d="www.$domain" '$1 == "0.0.0.0" && $2 == d { next } { print $0 }' "$HOSTS_FILE" > "$_TMPFILE"
             cat "$_TMPFILE" > "$HOSTS_FILE"
             rm -f "$_TMPFILE"
        fi
    fi

    refresh_state
}

add_custom_domain() {
    local domain="$1"
    if [[ -z "$domain" || "$domain" =~ [^a-zA-Z0-9.-] ]]; then return 1; fi
    
    local exists=0
    for d in "${TAB_ITEMS_4[@]}"; do
        [[ "$d" == "$domain" ]] && exists=1
    done

    if (( exists == 0 )); then
        TAB_ITEMS_4+=("$domain")
        toggle_domain "$domain"
        CURRENT_TAB=4
        # Scroll to bottom to show new entry
        local -i count=${#TAB_ITEMS_4[@]}
        SELECTED_ROW=$(( count - 1 ))
        compute_scroll_window "$count"
    fi
}

# =============================================================================
# ▼ RENDER ENGINE ▼
# =============================================================================

compute_scroll_window() {
    local -i count=$1
    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
        _vis_start=0; _vis_end=0
        return
    fi

    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi

    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi

    local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
    if (( max_scroll < 0 )); then max_scroll=0; fi
    if (( SCROLL_OFFSET > max_scroll )); then SCROLL_OFFSET=$max_scroll; fi

    _vis_start=$SCROLL_OFFSET
    _vis_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    if (( _vis_end > count )); then _vis_end=$count; fi
}

render_scroll_indicator() {
    local -n _rsi_buf=$1
    local position="$2"
    local -i count=$3 boundary=$4

    if [[ "$position" == "above" ]]; then
        if (( SCROLL_OFFSET > 0 )); then
            _rsi_buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
        else
            _rsi_buf+="${CLR_EOL}"$'\n'
        fi
    else
        if (( count > MAX_DISPLAY_ROWS )); then
            local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
            if (( boundary < count )); then
                _rsi_buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
            else
                _rsi_buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
            fi
        else
            _rsi_buf+="${CLR_EOL}"$'\n'
        fi
    fi
}

draw_main_view() {
    local buf="" pad_buf=""
    local -i i current_col=3 zone_start len count pad_needed
    local -i left_pad right_pad vis_len
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    strip_ansi "$APP_TITLE"; local -i t_len=${#REPLY}
    strip_ansi "$APP_VERSION"; local -i v_len=${#REPLY}
    vis_len=$(( t_len + v_len + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # --- Scrollable Tab Rendering ---
    if (( TAB_SCROLL_START > CURRENT_TAB )); then TAB_SCROLL_START=$CURRENT_TAB; fi

    local tab_line
    local -i max_tab_width=$(( BOX_INNER_WIDTH - 6 ))

    LEFT_ARROW_ZONE=""
    RIGHT_ARROW_ZONE=""

    while true; do
        tab_line="${C_MAGENTA}│ "
        current_col=3
        TAB_ZONES=()
        local -i used_len=0

        # Left Arrow
        if (( TAB_SCROLL_START > 0 )); then
            tab_line+="${C_YELLOW}«${C_RESET} "
            LEFT_ARROW_ZONE="$current_col:$((current_col+1))"
            used_len=$(( used_len + 2 ))
            current_col=$(( current_col + 2 ))
        else
            tab_line+="  "
            used_len=$(( used_len + 2 ))
            current_col=$(( current_col + 2 ))
        fi

        for (( i = TAB_SCROLL_START; i < TAB_COUNT; i++ )); do
            local name="${TABS[i]}"
            local t_len=${#name}
            local chunk_len=$(( t_len + 4 ))

            local reserve=0
            if (( i < TAB_COUNT - 1 )); then reserve=2; fi

            if (( used_len + chunk_len + reserve > max_tab_width )); then
                if (( i <= CURRENT_TAB )); then
                    TAB_SCROLL_START=$(( TAB_SCROLL_START + 1 ))
                    continue 2
                fi
                # Right Arrow
                tab_line+="${C_YELLOW}» ${C_RESET}"
                RIGHT_ARROW_ZONE="$current_col:$((current_col+1))"
                used_len=$(( used_len + 2 ))
                break
            fi

            zone_start=$current_col
            if (( i == CURRENT_TAB )); then
                tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
            else
                tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
            fi
            
            TAB_ZONES+=("${zone_start}:$(( zone_start + t_len + 1 ))")
            used_len=$(( used_len + chunk_len ))
            current_col=$(( current_col + chunk_len ))
        done

        local pad=$(( BOX_INNER_WIDTH - used_len - 1 ))
        if (( pad > 0 )); then
            printf -v pad_buf '%*s' "$pad" ''
            tab_line+="$pad_buf"
        fi
        
        tab_line+="${C_MAGENTA}│${C_RESET}"
        break
    done

    buf+="${tab_line}${CLR_EOL}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    # --- Items ---
    local items_var="TAB_ITEMS_${CURRENT_TAB}"
    local -n _draw_items_ref="$items_var"
    count=${#_draw_items_ref[@]}

    compute_scroll_window "$count"
    render_scroll_indicator buf "above" "$count" "$_vis_start"

    # List
    local ri item state display padded_item
    for (( ri = _vis_start; ri < _vis_end; ri++ )); do
        item="${_draw_items_ref[ri]}"
        
        # Check for Special Add Button
        if [[ "$item" == "$ADD_BUTTON_LABEL" ]]; then
            display="" # No blocked status for button
            
            # Special Rendering for Button
            if (( ri == SELECTED_ROW )); then
                # Selected Button
                buf+="${C_CYAN} ➤ ${C_INVERSE}${C_YELLOW}${item}${C_RESET}   ${CLR_EOL}"$'\n'
            else
                # Unselected Button
                buf+="    ${C_YELLOW}${item}${C_RESET}${CLR_EOL}"$'\n'
            fi
            continue
        fi

        state="${IS_BLOCKED["$item"]:-0}"

        if (( state == 1 )); then
            display="${C_RED}BLOCKED ⛔${C_RESET}"
        else
            display="${C_GREEN}ALLOWED ✅${C_RESET}"
        fi

        local max_len=$(( ITEM_PADDING - 1 ))
        if (( ${#item} > ITEM_PADDING )); then
            printf -v padded_item "%-${max_len}s…" "${item:0:max_len}"
        else
            printf -v padded_item "%-${ITEM_PADDING}s" "$item"
        fi

        if (( ri == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    # Fill
    local -i rows_rendered=$(( _vis_end - _vis_start ))
    for (( ri = rows_rendered; ri < MAX_DISPLAY_ROWS; ri++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    render_scroll_indicator buf "below" "$count" "$_vis_end"

    buf+=$'\n'"${C_CYAN} [Tab] Category  [Space/Enter] Toggle  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} System: ${C_WHITE}${HOSTS_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    
    printf '%s' "$buf"
}

draw_input_modal() {
    printf "${CURSOR_HOME}"
    local i
    for ((i=0; i<8; i++)); do printf "\n"; done
    printf "${C_MAGENTA}          ┌──────────────────────────────────────────────────┐${C_RESET}\n"
    printf "${C_MAGENTA}          │ ${C_WHITE}ADD CUSTOM DOMAIN TO BLOCK LIST                  ${C_MAGENTA}│${C_RESET}\n"
    printf "${C_MAGENTA}          │                                                  │${C_RESET}\n"
    printf "${C_MAGENTA}          │ ${C_CYAN}> ${INPUT_BUFFER}_${C_RESET}                                         \n"
    printf "${C_MAGENTA}          │                                                  │${C_RESET}\n"
    printf "${C_MAGENTA}          └──────────────────────────────────────────────────┘${C_RESET}\n"
    printf "${CLR_EOS}"
}

draw_ui() {
    if (( CURRENT_VIEW == 0 )); then draw_main_view; else draw_input_modal; fi
}

# =============================================================================
# ▼ INPUT HANDLING ▼
# =============================================================================

navigate() {
    local -i dir=$1
    local -n _nav_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_nav_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

navigate_end() {
    local -i target=$1
    local -n _nave_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_nave_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
}

switch_tab() {
    local -i dir=${1:-1}
    CURRENT_TAB=$(( (CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
    fi
}

toggle_current() {
    local -n _tog_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    if (( ${#_tog_items_ref[@]} == 0 )); then return; fi
    local item="${_tog_items_ref[SELECTED_ROW]}"

    # CHECK FOR BUTTON CLICK
    if [[ "$item" == "$ADD_BUTTON_LABEL" ]]; then
        CURRENT_VIEW=1
        INPUT_BUFFER=""
        return
    fi
    
    toggle_domain "$item"
}

handle_mouse() {
    local input="$1"
    local -i button x y i start end
    local zone

    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi
    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi
    body="${body%[Mm]}"
    IFS=';' read -r button x y <<< "$body"
    
    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    if [[ "$terminator" != "M" ]]; then return 0; fi

    if (( y == TAB_ROW )); then
        if (( CURRENT_VIEW == 0 )); then
            if [[ -n "$LEFT_ARROW_ZONE" ]]; then
                start="${LEFT_ARROW_ZONE%%:*}"
                end="${LEFT_ARROW_ZONE##*:}"
                if (( x >= start && x <= end )); then switch_tab -1; return 0; fi
            fi
            if [[ -n "$RIGHT_ARROW_ZONE" ]]; then
                start="${RIGHT_ARROW_ZONE%%:*}"
                end="${RIGHT_ARROW_ZONE##*:}"
                if (( x >= start && x <= end )); then switch_tab 1; return 0; fi
            fi

            for (( i = 0; i < TAB_COUNT; i++ )); do
                if [[ -z "${TAB_ZONES[i]:-}" ]]; then continue; fi
                zone="${TAB_ZONES[i]}"
                start="${zone%%:*}"
                end="${zone##*:}"
                if (( x >= start && x <= end )); then set_tab "$(( i + TAB_SCROLL_START ))"; return 0; fi
            done
        fi
    fi

    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - effective_start + SCROLL_OFFSET ))
        local -n _mouse_items_ref="TAB_ITEMS_${CURRENT_TAB}"
        
        if (( clicked_idx >= 0 && clicked_idx < ${#_mouse_items_ref[@]} )); then
            SELECTED_ROW=$clicked_idx
            if (( button == 0 )); then toggle_current; fi
        fi
    fi
}

read_escape_seq() {
    local -n _esc_out=$1
    _esc_out=""
    local char
    if ! IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; then return 1; fi
    _esc_out+="$char"
    if [[ "$char" == '[' || "$char" == 'O' ]]; then
        while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
            _esc_out+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then break; fi
        done
    fi
    return 0
}

# --- Input Router ---
handle_key_main() {
    local key="$1"
    case "$key" in
        '[Z')                switch_tab -1; return ;;
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC')           switch_tab 1; return ;;
        '[D'|'OD')           switch_tab -1; return ;;
        '[H'|'[1~')          navigate_end 0; return ;;
        '[F'|'[4~')          navigate_end 1; return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    case "$key" in
        k|K)            navigate -1 ;;
        j|J)            navigate 1 ;;
        l|L|$'\t')      switch_tab 1 ;;
        h|H)            switch_tab -1 ;;
        g)              navigate_end 0 ;;
        G)              navigate_end 1 ;;
        " "|'')         toggle_current ;; # Space/Enter
        a|A)            CURRENT_VIEW=1; INPUT_BUFFER="" ;;
        q|Q|$'\x03')    exit 0 ;;
    esac
}

handle_key_modal() {
    local key="$1"
    if [[ "$key" == $'\x7f' || "$key" == $'\x08' ]]; then
        INPUT_BUFFER="${INPUT_BUFFER%?}"
    elif [[ "$key" == "" || "$key" == $'\n' ]]; then
        add_custom_domain "$INPUT_BUFFER"
        CURRENT_VIEW=0
    elif [[ "$key" == "ESC" || "$key" == $'\x1b' ]]; then
        CURRENT_VIEW=0
    else
        if [[ "$key" =~ [a-zA-Z0-9.-] ]] && [[ ${#key} -eq 1 ]]; then
            INPUT_BUFFER+="$key"
        fi
    fi
}

handle_input_router() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
        else
            key="ESC"
        fi
    fi

    if (( CURRENT_VIEW == 0 )); then
        handle_key_main "$key"
    else
        handle_key_modal "$key"
    fi
}

# =============================================================================
# ▼ MAIN ▼
# =============================================================================

main() {
    # 0. Root Check
    if [[ $EUID -ne 0 ]]; then
       echo -e "${C_YELLOW}Privileges required. Escalating to sudo...${C_RESET}"
       exec sudo bash "${BASH_SOURCE[0]}" "$@"
    fi

    if [[ ! -f "$HOSTS_FILE" ]]; then touch "$HOSTS_FILE"; fi
    if [[ ! -f "$BACKUP_FILE" ]]; then cp "$HOSTS_FILE" "$BACKUP_FILE"; chmod 644 "$BACKUP_FILE"; fi

    for _dep in awk grep; do
        if ! command -v "$_dep" &>/dev/null; then echo "Missing dependency: $_dep"; exit 1; fi
    done

    init_db
    refresh_state

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null
    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    local key
    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        handle_input_router "$key"
    done
}

main "$@"
