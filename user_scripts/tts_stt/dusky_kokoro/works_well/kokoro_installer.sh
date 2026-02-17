#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DUSKY KOKORO INSTALLER V31 (Stability Fixes + Cold Boot Optimization)
# ==============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_DIR="$HOME/contained_apps/uv/dusky_kokoro"
readonly MODEL_DIR="$ENV_DIR/models"
readonly TRIGGER_DIR="$HOME/user_scripts/tts_stt/dusky_kokoro"
readonly TARGET_TRIGGER="$TRIGGER_DIR/trigger.sh"

readonly MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files/kokoro-v0_19.onnx"
readonly VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files/voices.bin"

echo ":: [V31] Initializing Dusky Kokoro Setup..."

mkdir -p "$ENV_DIR" "$MODEL_DIR" "$TRIGGER_DIR"

if ! command -v uv &> /dev/null; then
    echo ":: Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    source "$HOME/.cargo/env"
fi

# Ensure the Python script is present before proceeding
if [[ -f "$SCRIPT_DIR/dusky_main.py" ]]; then
    cp "$SCRIPT_DIR/dusky_main.py" "$ENV_DIR/"
    echo ":: dusky_main.py deployed."
else
    echo ":: ERROR: dusky_main.py not found in current directory."
    exit 1
fi

cd "$ENV_DIR"

echo ":: Configuring Python Environment..."
uv init --python 3.12 --no-workspace 2>/dev/null || true

echo ":: Installing Dependencies..."
# Note: uuid is standard lib, no need to add.
uv add "kokoro-onnx[gpu]" "soundfile" "numpy" \
       "nvidia-cuda-runtime-cu12" \
       "nvidia-cublas-cu12" \
       "nvidia-cudnn-cu12" \
       "nvidia-cufft-cu12"

if [[ ! -f "$MODEL_DIR/kokoro-v0_19.onnx" ]]; then
    echo ":: Downloading ONNX Model..."
    curl -L "$MODEL_URL" -o "$MODEL_DIR/kokoro-v0_19.onnx"
fi
if [[ ! -f "$MODEL_DIR/voices.bin" ]]; then
    echo ":: Downloading Voices..."
    curl -L "$VOICES_URL" -o "$MODEL_DIR/voices.bin"
fi

echo ":: Generating V31 Smart Trigger..."
cat << 'EOF' > "$TARGET_TRIGGER"
#!/usr/bin/env bash
# Dusky Kokoro Trigger V31
# Features: Process Verification, Hard Kill, Debug Recovery, Cold Boot Fix

readonly APP_DIR="$HOME/contained_apps/uv/dusky_kokoro"
readonly PID_FILE="/tmp/dusky_kokoro.pid"
readonly READY_FILE="/tmp/dusky_kokoro.ready"
readonly FIFO_PATH="/tmp/dusky_kokoro.fifo"
readonly DAEMON_LOG="/tmp/dusky_kokoro.log"
readonly DEBUG_LOG="$APP_DIR/dusky_debug.log"

# --- Helpers ---

get_libs() {
    local SITE_PACKAGES
    SITE_PACKAGES=$(find "$APP_DIR/.venv" -type d -name "site-packages" 2>/dev/null | head -n 1)
    if [[ -n "$SITE_PACKAGES" && -d "$SITE_PACKAGES/nvidia" ]]; then
        local libs
        libs=$(find "$SITE_PACKAGES/nvidia" -type d -name "lib" | tr '\n' ':')
        echo "${libs%:}"
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
            # Try graceful stop
            kill "$pid" 2>/dev/null || true
            # Wait up to 3 seconds
            for _ in {1..30}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            # Force kill if still alive
            if kill -0 "$pid" 2>/dev/null; then
                echo ":: Daemon stuck. Force killing..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    fi
    # cleanup files
    rm -f "$PID_FILE" "$FIFO_PATH" "$READY_FILE"
}

start_daemon() {
    local debug_mode="${1:-false}"

    if ! command -v mpv &>/dev/null; then
        notify "Kokoro Error" "MPV is missing!"
        echo ":: ERROR: MPV not found in PATH"
        return 1
    fi

    local NV_LIBS
    NV_LIBS=$(get_libs)
    if [[ -n "$NV_LIBS" ]]; then
        export LD_LIBRARY_PATH="${NV_LIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi

    cd "$APP_DIR"

    if [[ "$debug_mode" == "true" ]]; then
        echo ":: Starting Daemon in FORENSIC DEBUG Mode..."
        echo ":: Debug Log: $DEBUG_LOG"
        
        export DUSKY_LOG_LEVEL="DEBUG"
        export DUSKY_LOG_FILE="$DEBUG_LOG"

        # Redirect stdout/stderr to main log to keep debug file pure for python logger
        nohup uv run dusky_main.py --daemon --debug-file "$DEBUG_LOG" > "$DAEMON_LOG" 2>&1 &
    else
        nohup uv run dusky_main.py --daemon > "$DAEMON_LOG" 2>&1 &
    fi

    # IMMEDIATE PID LOCK: Prevents double-start during cold boot
    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"

    # Wait for daemon ready (max 30s for Cold Boot CUDA init)
    for _ in {1..300}; do
        if [[ -f "$READY_FILE" ]]; then
            if [[ "$debug_mode" == "true" ]]; then
                echo ":: Daemon Ready. Tailing debug log (Ctrl+C to detach)..."
                tail -f "$DEBUG_LOG"
            fi
            return 0
        fi
        
        # Fast Fail: If python crashed during import, stop waiting
        if ! kill -0 "$daemon_pid" 2>/dev/null; then
            echo ":: ERROR: Daemon process died during startup. Check: $DAEMON_LOG"
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

# --- Main Logic ---

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
        if start_daemon "false"; then
            echo ":: Daemon restarted."
        else
            exit 1
        fi
        exit 0
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
        ;; # Continue to text processing
    *)
        echo ":: Unknown argument: $1"
        exit 1
        ;;
esac

# Ensure running
if ! is_running; then
    # Clean stale files if process is dead
    rm -f "$FIFO_PATH" "$PID_FILE" "$READY_FILE"
    if ! start_daemon "false"; then
        exit 1
    fi
fi

# SECONDARY GATE: Handle the case where daemon is running but not yet ready
if [[ ! -f "$READY_FILE" ]]; then
    for _ in {1..300}; do
        if [[ -f "$READY_FILE" ]]; then
            break
        fi
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

# Send Clipboard (Increased timeout for system load)
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
EOF

chmod +x "$TARGET_TRIGGER"
echo ":: Setup Complete. Trigger: $TARGET_TRIGGER"
