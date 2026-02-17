#!/usr/bin/env bash
# Dusky Kokoro Trigger V35 (nvidia edition)
# Features: Universal HW, Robust Detection, Cold Boot Fix, Hard Kill

readonly APP_DIR="/home/dusk/contained_apps/uv/dusky_kokoro"
readonly PID_FILE="/tmp/dusky_kokoro.pid"
readonly READY_FILE="/tmp/dusky_kokoro.ready"
readonly FIFO_PATH="/tmp/dusky_kokoro.fifo"
readonly DAEMON_LOG="/tmp/dusky_kokoro.log"
readonly DEBUG_LOG="$APP_DIR/dusky_debug.log"
readonly INSTALL_MODE="nvidia"

# --- Helpers ---

get_libs() {
    # NVIDIA-specific library discovery
    if [[ "$INSTALL_MODE" == "nvidia" ]]; then
        local SITE_PACKAGES
        SITE_PACKAGES=$(find "$APP_DIR/.venv" -type d -name "site-packages" 2>/dev/null | head -n 1)
        if [[ -n "$SITE_PACKAGES" && -d "$SITE_PACKAGES/nvidia" ]]; then
            local libs
            libs=$(find "$SITE_PACKAGES/nvidia" -type d -name "lib" | tr '\n' ':')
            echo "${libs%:}"
        fi
    fi
}

notify() { notify-send "$@" 2>/dev/null || true; }

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            for _ in {1..30}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo ":: Daemon stuck. Force killing..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    fi
    rm -f "$PID_FILE" "$FIFO_PATH" "$READY_FILE"
}

start_daemon() {
    local debug_mode="${1:-false}"

    if ! command -v mpv &>/dev/null; then
        notify "Kokoro Error" "MPV is missing!"
        return 1
    fi

    local EXTRA_LIBS
    EXTRA_LIBS=$(get_libs)
    if [[ -n "$EXTRA_LIBS" ]]; then
        export LD_LIBRARY_PATH="${EXTRA_LIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi

    cd "$APP_DIR"

    if [[ "$debug_mode" == "true" ]]; then
        echo ":: Starting Daemon in FORENSIC DEBUG Mode..."
        export DUSKY_LOG_LEVEL="DEBUG"
        export DUSKY_LOG_FILE="$DEBUG_LOG"
        nohup uv run dusky_main.py --daemon --debug-file "$DEBUG_LOG" > "$DAEMON_LOG" 2>&1 &
    else
        nohup uv run dusky_main.py --daemon > "$DAEMON_LOG" 2>&1 &
    fi

    # IMMEDIATE PID LOCK: Prevents double-start during cold boot
    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"

    # Wait for daemon ready (30s timeout covers cold boot)
    for _ in {1..300}; do
        if [[ -f "$READY_FILE" ]]; then
            if [[ "$debug_mode" == "true" ]]; then
                echo ":: Daemon Ready. Tailing log..."
                tail -f "$DEBUG_LOG"
            fi
            return 0
        fi
        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            echo ":: ERROR: Daemon process died during startup."
            notify "Kokoro Failed" "Daemon crashed during startup."
            return 1
        fi
        sleep 0.1
    done

    echo ":: ERROR: Daemon start timeout (30s)."
    notify "Kokoro Failed" "Daemon start timeout."
    return 1
}

show_help() {
    cat << 'HELP'
Dusky Kokoro TTS — Trigger Script

USAGE:
    trigger.sh              Send clipboard text to TTS (starts daemon if needed)
    trigger.sh [OPTION]

OPTIONS:
    --help, -h       Show this help
    --kill           Stop the daemon
    --restart        Restart the daemon
    --status         Check if daemon is running
    --debug          Restart in debug mode (tails verbose log)
    --logs           Tail the daemon log
HELP
}

# --- CLI Logic ---
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --kill)
        if is_running; then
            stop_daemon
            echo ":: Daemon stopped."
        else
            echo ":: Daemon not running (cleaning stale files)."
            rm -f "$PID_FILE" "$FIFO_PATH" "$READY_FILE"
        fi
        exit 0
        ;;
    --status)
        if is_running; then 
            echo ":: Daemon running (PID: $(cat "$PID_FILE"))"
        else 
            echo ":: Daemon not running."
        fi
        exit 0
        ;;
    --restart)
        echo ":: Restarting daemon..."
        stop_daemon
        start_daemon "false"
        exit $?
        ;;
    --logs)
        if [[ -f "$DAEMON_LOG" ]]; then
            tail -f "$DAEMON_LOG"
        else
            echo ":: No log file at $DAEMON_LOG"
        fi
        exit 0
        ;;
    --debug)
        if is_running; then
            echo ":: Stopping existing daemon..."
            stop_daemon
        fi
        start_daemon "true"
        exit $?
        ;;
    --*)
        echo ":: Unknown flag: $1"
        echo ":: Use '$(basename "$0") --help' for usage."
        exit 1
        ;;
    "")
        ;;
    *)
        echo ":: Unknown argument: $1"
        exit 1
        ;;
esac

# --- Trigger Logic ---

# Ensure running
if ! is_running; then
    rm -f "$FIFO_PATH" "$PID_FILE" "$READY_FILE"
    if ! start_daemon "false"; then exit 1; fi
fi

# Secondary readiness gate
if [[ ! -f "$READY_FILE" ]]; then
    for _ in {1..300}; do
        if [[ -f "$READY_FILE" ]]; then break; fi
        if ! is_running; then
            echo ":: ERROR: Daemon died while waiting for readiness."
            notify "Kokoro Failed" "Daemon died during startup."
            exit 1
        fi
        sleep 0.1
    done
    if [[ ! -f "$READY_FILE" ]]; then
        echo ":: ERROR: Daemon readiness timeout (30s)."
        notify "Kokoro Failed" "Daemon not ready."
        exit 1
    fi
fi

# Send Clipboard
INPUT_TEXT=$(timeout 2 wl-paste 2>/dev/null || true)
if [[ -n "$INPUT_TEXT" ]]; then
    CLEAN_TEXT=$(printf '%s' "$INPUT_TEXT" | tr '\n' ' ')

    printf '%s\n' "$CLEAN_TEXT" > "$FIFO_PATH" &
    WRITE_PID=$!
    
    WRITE_OK=false
    for _ in {1..20}; do
        if ! kill -0 "$WRITE_PID" 2>/dev/null; then
            wait "$WRITE_PID" 2>/dev/null && WRITE_OK=true
            break
        fi
        sleep 0.1
    done
    
    if $WRITE_OK; then
        notify -t 1000 "Kokoro" "Processing..."
    else
        kill "$WRITE_PID" 2>/dev/null || true
        wait "$WRITE_PID" 2>/dev/null || true
        notify "Kokoro Error" "Daemon Unresponsive"
    fi
else
    notify "Kokoro" "Clipboard empty"
fi
