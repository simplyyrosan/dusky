#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Monitor Wizard - Hyprland Edition v3.3.0 (Master Template Sync)
# -----------------------------------------------------------------------------
# A pure Bash TUI for Hyprland monitor management.
# LOGIC ORIGIN: Ported from nwg-displays (Python) logic.
# UI ENGINE:    Strictly derived from Dusky TUI v3.3.2 (The Gold Standard).
# FEATURES:     Mouse, Vim Keys, VFR, Resolution List, Tabs, Desc/Name ID.
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# ▼ DEPENDENCY CHECK ▼
# =============================================================================

for _cmd in hyprctl jq awk stty; do
    if ! command -v "$_cmd" &>/dev/null; then
        printf 'FATAL: Required command "%s" not found in PATH.\n' "$_cmd" >&2
        exit 1
    fi
done
unset _cmd

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

readonly APP_TITLE="DUSKY MONITOR WIZARD v3.3"
readonly APP_SUBTITLE="Multi Monitor Edition"
readonly TARGET_CONFIG="${HOME}/.config/hypr/edit_here/source/monitors.conf"
readonly BACKUP_DIR="/tmp/dusky_backups"
readonly DEBUG_LOG="/tmp/dusky_debug.log"

declare -ri BOX_INNER_WIDTH=76
declare -ri MAX_DISPLAY_ROWS=12
declare -ri HEADER_ROWS=3
declare -ri TAB_ROW=2
declare -ri ITEM_START_ROW=5

readonly -a TRANSFORMS=("Normal" "90°" "180°" "270°" "Flipped" "Flipped-90°" "Flipped-180°" "Flipped-270°")
readonly -a ANCHOR_POSITIONS=("Absolute" "Right Of" "Left Of" "Above" "Below" "Mirror")

# =============================================================================
# ▼ ANSI CONSTANTS ▼
# =============================================================================

readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# ANSI stripping regex pattern for Bash parameter expansion
readonly _ESC=$'\033'

# =============================================================================
# ▼ CLEANUP & SAFETY ▼
# =============================================================================

ORIG_STTY=""
_SAVE_TMPFILE=""

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || true
    if [[ -n "${ORIG_STTY:-}" ]]; then
        stty "$ORIG_STTY" 2>/dev/null || true
    fi
    if [[ -n "${_SAVE_TMPFILE:-}" && -f "$_SAVE_TMPFILE" ]]; then
        rm -f -- "$_SAVE_TMPFILE"
    fi
}
trap cleanup EXIT INT TERM HUP

log_debug() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >> "$DEBUG_LOG"
}

log_err() { 
    printf '[ERROR] %s\n' "$1" >> "$DEBUG_LOG"
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

# =============================================================================
# ▼ STATE MANAGEMENT ▼
# =============================================================================

declare -i GLB_VFR=1
declare -i GLB_USE_DESC=0

declare -a MON_LIST=()
declare -A MON_ENABLED=()
declare -A MON_DESC=()
declare -A MON_RES=()
declare -A MON_SCALE=()
declare -A MON_TRANSFORM=()
declare -A MON_X=()
declare -A MON_Y=()
declare -A MON_VRR=()
declare -A MON_BITDEPTH=()
declare -A MON_MIRROR=()

declare -A UI_ANCHOR_TARGET=()
declare -A UI_ANCHOR_MODE=()
declare -A MON_MODES_LIST=()

declare -i CURRENT_TAB=0
declare -i CURRENT_VIEW=0  # 0=MonList, 1=Edit, 2=ResPicker, 3=Globals
declare -i SCROLL_OFFSET=0
declare -i SELECTED_ROW=0
declare -i LIST_SAVED_ROW=0
declare CURRENT_MON=""

declare -a RES_PICKER_LIST=()
declare -i RES_PICKER_SCROLL=0
declare -i RES_PICKER_ROW=0

# Geometry return values (global, set by get_logical_geometry)
declare -i GEO_W=0
declare -i GEO_H=0

# =============================================================================
# ▼ UTILITY FUNCTIONS ▼
# =============================================================================

# Pure-bash visible-length calculation: strip ANSI escapes without sed/external.
strip_ansi() {
    local s="$1"
    local result=""
    while [[ -n "$s" ]]; do
        if [[ "$s" == "${_ESC}"* ]]; then
            # Skip ESC
            s="${s:1}"
            if [[ "$s" == "["* ]]; then
                # CSI sequence: skip until terminating letter
                s="${s:1}"
                while [[ -n "$s" && ! "$s" =~ ^[a-zA-Z] ]]; do
                    s="${s:1}"
                done
                # Skip the terminating letter
                [[ -n "$s" ]] && s="${s:1}"
            else
                # Non-CSI escape (e.g., ESC ] for OSC) — skip next char
                [[ -n "$s" ]] && s="${s:1}"
            fi
        else
            result+="${s:0:1}"
            s="${s:1}"
        fi
    done
    REPLY="$result"
}

# Float comparison via awk (unavoidable for float math in bash)
float_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

float_add() {
    # $1 + $2, result in REPLY
    REPLY=$(awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", a + b }')
}

# =============================================================================
# ▼ BACKEND LOGIC ▼
# =============================================================================

refresh_hardware() {
    log_debug "Refreshing hardware..."
    
    local vfr_status
    vfr_status=$(hyprctl getoption misc:vfr -j 2>/dev/null | jq -r '.int' 2>/dev/null) || vfr_status="1"
    GLB_VFR=$vfr_status
    log_debug "VFR State: $GLB_VFR"

    local json
    json=$(hyprctl monitors all -j 2>/dev/null) || {
        log_err "Failed to query hyprctl monitors."
        exit 1
    }

    MON_LIST=()
    
    local extracted
    extracted=$(printf '%s' "$json" | jq -r '
        .[] | [
            .name,
            .description,
            (.disabled // false | tostring),
            (.width | tostring),
            (.height | tostring),
            (.refreshRate | tostring),
            (.scale | tostring),
            (.transform | tostring),
            (.x | tostring),
            (.y | tostring),
            (.availableModes | join(" "))
        ] | @tsv
    ') || true

    if [[ -z "$extracted" ]]; then
        log_err "No monitors detected from hyprctl."
        exit 1
    fi

    local name desc disabled width height refresh scale transform x y avail_modes
    while IFS=$'\t' read -r name desc disabled width height refresh scale transform x y avail_modes; do
        MON_LIST+=("$name")
        MON_DESC["$name"]="$desc"
        
        if [[ "$disabled" == "true" ]]; then
            MON_ENABLED["$name"]="false"
        else
            MON_ENABLED["$name"]="true"
        fi

        MON_RES["$name"]="${width}x${height}@${refresh}"
        MON_SCALE["$name"]="$scale"
        MON_TRANSFORM["$name"]="$transform"
        MON_X["$name"]="$x"
        MON_Y["$name"]="$y"
        MON_MODES_LIST["$name"]="$avail_modes"

        MON_VRR["$name"]="0"
        MON_BITDEPTH["$name"]="8"
        MON_MIRROR["$name"]=""
        UI_ANCHOR_MODE["$name"]="0"
        UI_ANCHOR_TARGET["$name"]=""
    done <<< "$extracted"
}

get_logical_geometry() {
    local name=$1
    local res_str=${MON_RES["$name"]}
    local width=${res_str%%x*}
    local rest=${res_str#*x}
    local height=${rest%%@*}
    local scale=${MON_SCALE["$name"]}
    local t=${MON_TRANSFORM["$name"]}

    # Rotated transforms swap width/height
    case "$t" in 
        1|3|5|7) 
            local tmp=$width
            width=$height
            height=$tmp
            ;;
    esac

    # Integer division via awk (scale can be float like 1.25)
    GEO_W=$(awk -v w="$width" -v s="$scale" 'BEGIN { printf "%.0f", w / s }')
    GEO_H=$(awk -v h="$height" -v s="$scale" 'BEGIN { printf "%.0f", h / s }')
}

recalc_position() {
    local name=$1
    local mode=${UI_ANCHOR_MODE["$name"]}
    local target=${UI_ANCHOR_TARGET["$name"]}
    
    if (( mode == 0 )); then return; fi
    if [[ -z "$target" || "$target" == "$name" ]]; then 
        UI_ANCHOR_MODE["$name"]=0
        return
    fi

    local -i t_x=${MON_X["$target"]}
    local -i t_y=${MON_Y["$target"]}

    get_logical_geometry "$target"
    local -i t_w=$GEO_W t_h=$GEO_H

    get_logical_geometry "$name"
    local -i s_w=$GEO_W s_h=$GEO_H

    case "$mode" in
        1) MON_X["$name"]=$(( t_x + t_w )); MON_Y["$name"]=$t_y ;;
        2) MON_X["$name"]=$(( t_x - s_w )); MON_Y["$name"]=$t_y ;;
        3) MON_X["$name"]=$t_x; MON_Y["$name"]=$(( t_y - s_h )) ;;
        4) MON_X["$name"]=$t_x; MON_Y["$name"]=$(( t_y + t_h )) ;;
        5) MON_X["$name"]=$t_x; MON_Y["$name"]=$t_y; MON_MIRROR["$name"]="$target" ;;
    esac

    if (( mode != 5 )); then
        MON_MIRROR["$name"]=""
    fi
}

save_config() {
    log_debug "Saving configuration..."
    local config_dir="${TARGET_CONFIG%/*}"
    mkdir -p "$config_dir" "$BACKUP_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [[ -f "$TARGET_CONFIG" ]]; then
        cp -- "$TARGET_CONFIG" "${BACKUP_DIR}/monitors_${timestamp}.conf" 2>/dev/null || true
    fi

    _SAVE_TMPFILE=$(mktemp "${config_dir}/monitors.conf.XXXXXX")
    
    local -a direct_cmds=()

    {
        printf '# Generated by Dusky Monitor Wizard on %s\n' "$timestamp"
        printf '\n# Global Settings\n'
        
        if (( GLB_VFR == 1 )); then
            printf 'misc {\n    vfr = true\n}\n'
            direct_cmds+=("keyword misc:vfr 1")
        else
            printf 'misc {\n    vfr = false\n}\n'
            direct_cmds+=("keyword misc:vfr 0")
        fi

        printf '\n# Monitor Rules\n'
        local name
        for name in "${MON_LIST[@]}"; do
            local identifier="$name"
            if (( GLB_USE_DESC == 1 )); then
                identifier="desc:${MON_DESC["$name"]}"
            fi

            if [[ "${MON_ENABLED["$name"]}" == "false" ]]; then
                printf 'monitor = %s, disable\n' "$identifier"
                direct_cmds+=("keyword monitor ${identifier},disable")
                continue
            fi

            local res=${MON_RES["$name"]}
            local x=${MON_X["$name"]}
            local y=${MON_Y["$name"]}
            local scale=${MON_SCALE["$name"]}
            local transform=${MON_TRANSFORM["$name"]}
            local vrr=${MON_VRR["$name"]}
            local bit=${MON_BITDEPTH["$name"]}
            local mirror=${MON_MIRROR["$name"]}

            local rule_args="${identifier}, ${res}, ${x}x${y}, ${scale}"
            (( transform != 0 )) && rule_args+=", transform, ${transform}"
            [[ -n "$mirror" ]] && rule_args+=", mirror, ${mirror}"
            (( bit == 10 )) && rule_args+=", bitdepth, 10"
            (( vrr > 0 )) && rule_args+=", vrr, ${vrr}"

            printf 'monitor = %s\n' "$rule_args"
            
            # Build clean comma-separated args for hyprctl
            local clean_args="${rule_args//, /,}"
            direct_cmds+=("keyword monitor ${clean_args}")
        done
    } > "$_SAVE_TMPFILE"

    if mv -f -- "$_SAVE_TMPFILE" "$TARGET_CONFIG"; then
        _SAVE_TMPFILE=""  # Successfully moved; nothing to clean up
        printf '\n%sApplying settings...%s\n' "$C_CYAN" "$C_RESET"
        
        # Apply via hyprctl batch where possible
        local cmd
        for cmd in "${direct_cmds[@]}"; do
            # Word-splitting is intentional here for hyprctl's CLI interface
            # shellcheck disable=SC2086
            hyprctl $cmd >/dev/null 2>&1 || true
        done
        log_debug "Saved and applied."
    else
        log_err "Failed to save config file."
        rm -f -- "$_SAVE_TMPFILE"
        _SAVE_TMPFILE=""
    fi
}

# =============================================================================
# ▼ TUI ENGINE (DRAWING) ▼
# =============================================================================

# Width Fix: Box lines extend 2 chars beyond Inner Width to cover the padding spaces
readonly BOX_LINE=$(printf '─%.0s' $(seq 1 $((BOX_INNER_WIDTH + 2))))

draw_box_top() {
    printf '%s┌%s┐%s\n' "$C_MAGENTA" "$BOX_LINE" "$C_RESET"
}

draw_box_bottom() {
    printf '%s└%s┘%s\n' "$C_MAGENTA" "$BOX_LINE" "$C_RESET"
}

draw_separator() {
    printf '%s├%s┤%s\n' "$C_MAGENTA" "$BOX_LINE" "$C_RESET"
}

draw_row() {
    local content="${1:-}"
    strip_ansi "$content"
    local -i vis_len=${#REPLY}
    local -i pad_needed=$(( BOX_INNER_WIDTH - vis_len )) 
    (( pad_needed < 0 )) && pad_needed=0
    
    # Structure: │ SPACE content PADDING SPACE │
    # Total inner chars = 1 + vis + pad + 1 = BOX_INNER_WIDTH + 2
    printf '%s│%s %s%*s %s│%s\n' "$C_MAGENTA" "$C_RESET" "$content" "$pad_needed" "" "$C_MAGENTA" "$C_RESET"
}

draw_header() {
    draw_box_top
    draw_row "${C_WHITE}${C_INVERSE}  ${APP_TITLE}  ${C_RESET} ${C_GREY}${APP_SUBTITLE}${C_RESET}"
}

draw_tabs() {
    local t0 t1
    if (( CURRENT_TAB == 0 )); then
        t0="${C_CYAN}${C_INVERSE} Monitors ${C_RESET}"
        t1="${C_GREY} Globals ${C_RESET}"
    else
        t0="${C_GREY} Monitors ${C_RESET}"
        t1="${C_CYAN}${C_INVERSE} Globals ${C_RESET}"
    fi
    draw_row "  ${t0}  ${t1}"
    draw_separator
}

draw_mon_list() {
    local -i start=$SCROLL_OFFSET
    local -i end=$(( start + MAX_DISPLAY_ROWS ))
    local -i count=${#MON_LIST[@]}
    local -i drawn=0
    
    local -i i
    for (( i = start; i < end && i < count; i++ )); do
        local mon="${MON_LIST[$i]}"
        local state info pos line_str
        
        if [[ "${MON_ENABLED["$mon"]}" == "true" ]]; then
            state="${C_GREEN}ON ${C_RESET}"
        else
            state="${C_RED}OFF${C_RESET}"
        fi
        
        info="${MON_RES["$mon"]} @ ${MON_SCALE["$mon"]}x"
        pos="(${MON_X["$mon"]},${MON_Y["$mon"]})"
        
        if (( i == SELECTED_ROW )); then
            line_str="${C_CYAN}➤ ${mon}${C_RESET} [${state}] ${info} ${C_GREY}${pos}${C_RESET}"
        else
            line_str="  ${mon} [${state}] ${info} ${C_GREY}${pos}${C_RESET}"
        fi
        draw_row "$line_str"
        (( drawn++ ))
    done

    # Fill remaining rows
    local -i filler
    for (( filler = drawn; filler < MAX_DISPLAY_ROWS; filler++ )); do
        draw_row ""
    done

    draw_separator
    if (( SELECTED_ROW == count )); then
        draw_row "${C_CYAN}➤ [Save & Apply Configuration]${C_RESET}"
    else
        draw_row "  [Save & Apply Configuration]"
    fi
}

draw_edit_view() {
    local mon="$CURRENT_MON"
    local enabled="${MON_ENABLED["$mon"]}"
    
    draw_row "${C_YELLOW}Editing: ${mon}${C_RESET}"
    draw_separator

    # Fields array — index 6 is a separator placeholder
    local -a fields=("Enabled" "Resolution" "Scale" "Rotation" "Bitdepth" "VRR" "---" "Anchor Mode" "Anchor Target" "X" "Y")
    local -i drawn=0
    local -i i
    
    for i in "${!fields[@]}"; do
        local label="${fields[$i]}"
        
        if [[ "$label" == "---" ]]; then
            draw_separator
            (( drawn++ ))
            continue
        fi

        local val=""
        case $i in
            0) 
                if [[ "$enabled" == "true" ]]; then
                    val="${C_GREEN}True${C_RESET}"
                else
                    val="${C_RED}False${C_RESET}"
                fi
                ;;
            1) val="${MON_RES["$mon"]}" ;;
            2) val="${MON_SCALE["$mon"]}" ;;
            3) 
                local ti=${MON_TRANSFORM["$mon"]}
                val="${TRANSFORMS[$ti]}" 
                ;;
            4) val="${MON_BITDEPTH["$mon"]}-bit" ;;
            5) 
                case "${MON_VRR["$mon"]}" in 0) val="Off" ;; 1) val="On" ;; 2) val="Full" ;; esac
                ;;
            7) 
                local am=${UI_ANCHOR_MODE["$mon"]}
                val="${ANCHOR_POSITIONS[$am]}"
                ;;
            8) 
                local at="${UI_ANCHOR_TARGET["$mon"]}"
                val="${at:-None}"
                ;;
            9) 
                val="${MON_X["$mon"]}"
                if (( UI_ANCHOR_MODE["$mon"] != 0 )); then
                    val="${C_GREY}(Auto) ${val}${C_RESET}"
                fi
                ;;
            10) 
                val="${MON_Y["$mon"]}"
                if (( UI_ANCHOR_MODE["$mon"] != 0 )); then
                    val="${C_GREY}(Auto) ${val}${C_RESET}"
                fi
                ;;
        esac

        local prefix="  "
        if (( i == SELECTED_ROW )); then
            prefix="${C_CYAN}➤ "
        fi
        draw_row "$(printf '%s%-14s : %s%s' "$prefix" "$label" "$val" "$C_RESET")"
        (( drawn++ ))
    done

    # Fill remaining rows
    local -i k
    for (( k = drawn; k < MAX_DISPLAY_ROWS; k++ )); do
        draw_row ""
    done
    
    draw_separator
    draw_row "${C_CYAN} [Esc] Back  [Enter/Click] Select  [h/l] Adjust  [s] Save${C_RESET}"
}

draw_res_picker() {
    draw_row "${C_YELLOW}Select Resolution for ${CURRENT_MON}${C_RESET}"
    draw_separator

    local -i start=$RES_PICKER_SCROLL
    local -i end=$(( start + MAX_DISPLAY_ROWS ))
    local -i count=${#RES_PICKER_LIST[@]}
    local -i drawn=0
    
    local -i i
    for (( i = start; i < end && i < count; i++ )); do
        local mode="${RES_PICKER_LIST[$i]}"
        if (( i == RES_PICKER_ROW )); then
            draw_row "${C_CYAN}➤ ${mode}${C_RESET}"
        else
            draw_row "  ${mode}"
        fi
        (( drawn++ ))
    done

    local -i f
    for (( f = drawn; f < MAX_DISPLAY_ROWS; f++ )); do
        draw_row ""
    done

    draw_separator
    draw_row "${C_CYAN} [Esc] Cancel  [Enter] Confirm${C_RESET}"
}

draw_globals() {
    local vfr_state desc_state
    
    if (( GLB_VFR == 1 )); then vfr_state="${C_GREEN}Enabled${C_RESET}"; else vfr_state="${C_RED}Disabled${C_RESET}"; fi
    if (( GLB_USE_DESC == 1 )); then desc_state="${C_GREEN}Description${C_RESET}"; else desc_state="${C_YELLOW}Port Name${C_RESET}"; fi
    
    if (( SELECTED_ROW == 0 )); then
        draw_row "${C_CYAN}➤ VFR (Variable Frame Rate)${C_RESET} : ${vfr_state}"
    else
        draw_row "  VFR (Variable Frame Rate) : ${vfr_state}"
    fi

    if (( SELECTED_ROW == 1 )); then
        draw_row "${C_CYAN}➤ Config ID Method${C_RESET}          : ${desc_state}"
    else
        draw_row "  Config ID Method          : ${desc_state}"
    fi

    local -i k
    for (( k = 2; k < MAX_DISPLAY_ROWS; k++ )); do
        draw_row ""
    done
    
    draw_separator
    if (( SELECTED_ROW == 2 )); then
        draw_row "${C_CYAN}➤ [Save & Apply Configuration]${C_RESET}"
    else
        draw_row "  [Save & Apply Configuration]"
    fi
}

draw_ui() {
    printf '%s' "$CURSOR_HOME"
    draw_header
    
    case $CURRENT_VIEW in
        0) # Monitor List
            draw_tabs
            draw_mon_list
            ;;
        1) # Edit
            draw_edit_view
            ;;
        2) # Res Picker
            draw_res_picker
            ;;
        3) # Globals
            draw_tabs
            draw_globals
            ;;
    esac
    
    draw_box_bottom
    printf '%s [Mouse/Vim] Nav  [Enter] Select  [s] Save  [q] Quit%s\n' "$C_GREY" "$C_RESET"
}

# =============================================================================
# ▼ INPUT HANDLING ▼
# =============================================================================

adjust_value() {
    local -i dir=$1
    local mon="$CURRENT_MON"

    case $SELECTED_ROW in
        0)
            if [[ "${MON_ENABLED["$mon"]}" == "true" ]]; then
                MON_ENABLED["$mon"]="false"
            else
                MON_ENABLED["$mon"]="true"
            fi
            ;;
        1)
            # Open resolution picker
            IFS=' ' read -r -a RES_PICKER_LIST <<< "${MON_MODES_LIST[$CURRENT_MON]}"
            RES_PICKER_ROW=0
            RES_PICKER_SCROLL=0
            CURRENT_VIEW=2
            ;;
        2) 
            local current="${MON_SCALE["$mon"]}"
            local step
            step=$(awk -v d="$dir" 'BEGIN { printf "%.2f", d * 0.05 }')
            float_add "$current" "$step"
            local new_val="$REPLY"
            if float_lt "$new_val" "0.25"; then
                new_val="0.25"
            fi
            MON_SCALE["$mon"]="$new_val"
            recalc_position "$mon" 
            ;;
        3) 
            local -i t=${MON_TRANSFORM["$mon"]}
            MON_TRANSFORM["$mon"]=$(( (t + dir + 8) % 8 ))
            recalc_position "$mon"
            ;;
        4) 
            if [[ "${MON_BITDEPTH["$mon"]}" == "8" ]]; then
                MON_BITDEPTH["$mon"]="10"
            else
                MON_BITDEPTH["$mon"]="8"
            fi
            ;;
        5) 
            local -i v=${MON_VRR["$mon"]}
            MON_VRR["$mon"]=$(( (v + dir + 3) % 3 )) 
            ;;
        7) 
            local -i m=${UI_ANCHOR_MODE["$mon"]}
            local -i c=${#ANCHOR_POSITIONS[@]}
            UI_ANCHOR_MODE["$mon"]=$(( (m + dir + c) % c ))
            recalc_position "$mon" 
            ;;
        8)
            local ct="${UI_ANCHOR_TARGET["$mon"]}"
            local -a opts=()
            local m_iter
            for m_iter in "${MON_LIST[@]}"; do
                [[ "$m_iter" != "$mon" ]] && opts+=("$m_iter")
            done
            if (( ${#opts[@]} > 0 )); then
                local -i idx=0
                local -i ii
                for (( ii = 0; ii < ${#opts[@]}; ii++ )); do
                    [[ "${opts[$ii]}" == "$ct" ]] && idx=$ii
                done
                idx=$(( (idx + dir + ${#opts[@]}) % ${#opts[@]} ))
                UI_ANCHOR_TARGET["$mon"]="${opts[$idx]}"
                recalc_position "$mon"
            fi
            ;;
        9) 
            if (( UI_ANCHOR_MODE["$mon"] == 0 )); then
                MON_X["$mon"]=$(( MON_X["$mon"] + (dir * 10) ))
            fi
            ;;
        10) 
            if (( UI_ANCHOR_MODE["$mon"] == 0 )); then
                MON_Y["$mon"]=$(( MON_Y["$mon"] + (dir * 10) ))
            fi
            ;;
    esac
}

do_save_with_prompt() {
    printf '%s%s' "$CLR_SCREEN" "$CURSOR_HOME"
    save_config
    printf 'Done. Press any key.\n'
    IFS= read -rsn1 || true
}

handle_key() {
    local key="$1"
    
    # --- Global shortcuts ---
    case "$key" in
        q|Q)
            cleanup
            exit 0
            ;;
        s|S) 
            do_save_with_prompt
            return
            ;;
        $'\t')
            if (( CURRENT_VIEW == 0 )); then
                CURRENT_TAB=1
                CURRENT_VIEW=3
                SELECTED_ROW=0
            elif (( CURRENT_VIEW == 3 )); then
                CURRENT_TAB=0
                CURRENT_VIEW=0
                SELECTED_ROW=0
            fi
            return
            ;;
    esac

    # --- View-specific input ---
    case $CURRENT_VIEW in
        0) _handle_key_mon_list "$key" ;;
        1) _handle_key_edit "$key" ;;
        2) _handle_key_res_picker "$key" ;;
        3) _handle_key_globals "$key" ;;
    esac
}

_handle_key_mon_list() {
    local key="$1"
    local -i count=${#MON_LIST[@]}

    case "$key" in
        k|K) (( SELECTED_ROW > 0 )) && (( SELECTED_ROW-- )) || true ;;
        j|J) (( SELECTED_ROW < count )) && (( SELECTED_ROW++ )) || true ;;
        g)   SELECTED_ROW=0; SCROLL_OFFSET=0 ;;
        G)   
            SELECTED_ROW=$count
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
            (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
            ;;
        l|L|'')
            if (( SELECTED_ROW == count )); then
                do_save_with_prompt
            elif (( SELECTED_ROW < count )); then
                CURRENT_MON="${MON_LIST[$SELECTED_ROW]}"
                LIST_SAVED_ROW=$SELECTED_ROW
                CURRENT_VIEW=1
                SELECTED_ROW=0
            fi
            ;;
    esac

    # Adjust scroll to keep selection visible
    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi
}

_handle_key_edit() {
    local key="$1"

    case "$key" in
        k|K) 
            (( SELECTED_ROW > 0 )) && (( SELECTED_ROW-- )) || true
            # Skip separator row
            (( SELECTED_ROW == 6 )) && SELECTED_ROW=5
            ;;
        j|J) 
            (( SELECTED_ROW < 10 )) && (( SELECTED_ROW++ )) || true
            (( SELECTED_ROW == 6 )) && SELECTED_ROW=7
            ;;
        h|H) adjust_value -1 ;;
        l|L) adjust_value 1 ;;
        '')  
            if (( SELECTED_ROW == 1 )); then
                # Open resolution picker
                IFS=' ' read -r -a RES_PICKER_LIST <<< "${MON_MODES_LIST[$CURRENT_MON]}"
                RES_PICKER_ROW=0
                RES_PICKER_SCROLL=0
                CURRENT_VIEW=2
            else
                adjust_value 1
            fi 
            ;;
        ESC) 
            CURRENT_VIEW=0
            SELECTED_ROW=$LIST_SAVED_ROW
            ;;
    esac

    # Bounds
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW > 10 )) && SELECTED_ROW=10
}

_handle_key_res_picker() {
    local key="$1"
    local -i count=${#RES_PICKER_LIST[@]}

    case "$key" in
        k|K) 
            (( RES_PICKER_ROW > 0 )) && (( RES_PICKER_ROW-- )) || true
            ;;
        j|J) 
            (( RES_PICKER_ROW < count - 1 )) && (( RES_PICKER_ROW++ )) || true
            ;;
        '') 
            local new_mode="${RES_PICKER_LIST[$RES_PICKER_ROW]}"
            # Parse "WIDTHxHEIGHT@REFRESHHz" format
            local clean="${new_mode%Hz}"
            local w="${clean%%x*}"
            local rest="${clean#*x}"
            local h="${rest%%@*}"
            local r="${rest#*@}"
            MON_RES["$CURRENT_MON"]="${w}x${h}@${r}"
            recalc_position "$CURRENT_MON"
            CURRENT_VIEW=1 
            ;;
        ESC)
            CURRENT_VIEW=1
            ;;
    esac

    # Adjust scroll
    if (( RES_PICKER_ROW < RES_PICKER_SCROLL )); then
        RES_PICKER_SCROLL=$RES_PICKER_ROW
    elif (( RES_PICKER_ROW >= RES_PICKER_SCROLL + MAX_DISPLAY_ROWS )); then
        RES_PICKER_SCROLL=$(( RES_PICKER_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi
}

_handle_key_globals() {
    local key="$1"

    case "$key" in
        k|K) (( SELECTED_ROW > 0 )) && (( SELECTED_ROW-- )) || true ;;
        j|J) (( SELECTED_ROW < 2 )) && (( SELECTED_ROW++ )) || true ;;
        l|L|'')
            case $SELECTED_ROW in
                0) GLB_VFR=$(( 1 - GLB_VFR )) ;;
                1) GLB_USE_DESC=$(( 1 - GLB_USE_DESC )) ;;
                2) do_save_with_prompt ;;
            esac
            ;;
    esac
}

handle_mouse() {
    local seq="$1"
    
    # Parse SGR mouse: ESC [ < Btn ; Col ; Row M/m
    # The sequence arriving here has the leading '[' already included
    # Format: [<btn;col;rowM  or  [<btn;col;rowm
    local inner="${seq#*<}"
    local terminator="${seq: -1}"
    
    local btn col row
    IFS=';' read -r btn col row <<< "${inner%[Mm]}"
    
    # Scroll events are press-only (type M)
    if [[ "$terminator" == "M" ]]; then
        if (( btn == 64 )); then
            handle_key "k"
            return
        elif (( btn == 65 )); then
            handle_key "j"
            return
        fi
    fi

    # Only handle button release for clicks (type m = release in SGR)
    if [[ "$terminator" != "m" ]]; then
        return
    fi

    # Tab row click
    if (( row == TAB_ROW + 1 && (CURRENT_VIEW == 0 || CURRENT_VIEW == 3) )); then
        if (( col < 40 )); then
            CURRENT_TAB=0
            CURRENT_VIEW=0
        else
            CURRENT_TAB=1
            CURRENT_VIEW=3
        fi
        SELECTED_ROW=0
        return
    fi

    # Content area click
    if (( row >= ITEM_START_ROW )); then
        local -i target_idx=$(( row - ITEM_START_ROW ))
        
        case $CURRENT_VIEW in
            0)
                target_idx=$(( target_idx + SCROLL_OFFSET ))
                if (( target_idx <= ${#MON_LIST[@]} )); then
                    SELECTED_ROW=$target_idx
                    handle_key ""
                fi
                ;;
            1)
                # Skip separator row visually at index 6
                if (( target_idx == 6 )); then return; fi
                if (( target_idx > 6 )); then (( target_idx++ )); fi
                if (( target_idx <= 10 )); then
                    SELECTED_ROW=$target_idx
                    handle_key "l"
                fi
                ;;
            2)
                target_idx=$(( target_idx + RES_PICKER_SCROLL ))
                if (( target_idx < ${#RES_PICKER_LIST[@]} )); then
                    RES_PICKER_ROW=$target_idx
                    handle_key ""
                fi
                ;;
            3)
                if (( target_idx <= 2 )); then
                    SELECTED_ROW=$target_idx
                    handle_key ""
                fi
                ;;
        esac
    fi
}

# Read additional characters of an escape sequence after ESC
read_escape_seq() {
    REPLY_SEQ=""
    local char

    # Try to read the next char; if nothing comes, it was a bare ESC
    if ! IFS= read -rsn1 -t 0.05 char; then
        return 1  # bare ESC
    fi

    REPLY_SEQ+="$char"

    if [[ "$char" == '[' ]]; then
        while IFS= read -rsn1 -t 0.05 char; do
            REPLY_SEQ+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then
                break
            fi
        done
    fi
    
    return 0
}

# =============================================================================
# ▼ MAIN ▼
# =============================================================================

main() {
    refresh_hardware

    ORIG_STTY=$(stty -g)
    stty -echo -icanon min 1 time 0

    printf '%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN"
    
    # Handle window resize (WINCH signal)
    trap 'draw_ui' WINCH
    
    # Interactive loop: disable strict error exit for safety
    set +e
    
    local key
    while true; do
        draw_ui
        
        if ! IFS= read -rsn1 key; then
            continue
        fi
        
        if [[ "$key" == $'\x1b' ]]; then
            if read_escape_seq; then
                # We got a full escape sequence
                case "$REPLY_SEQ" in
                    '[A') handle_key "k" ;;
                    '[B') handle_key "j" ;;
                    '[C') handle_key "l" ;;
                    '[D') handle_key "h" ;;
                    '['*'<'*)
                        handle_mouse "$REPLY_SEQ"
                        ;;
                esac
            else
                # Bare ESC keypress
                handle_key "ESC"
            fi
        else
            handle_key "$key"
        fi
    done
}

main "$@"
