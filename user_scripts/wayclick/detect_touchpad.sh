#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ARCH/HYPRLAND TOUCHPAD DETECTOR (IDEMPOTENT WRAPPER)
# -----------------------------------------------------------------------------
# This script automatically bootstraps a Python 3.14 environment if needed.
# It is idempotent: checks for 'evdev' before attempting install.
# -----------------------------------------------------------------------------

set -e

# Configuration: Use XDG Cache to keep your user_scripts dir clean
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/wayclick"
VENV_DIR="$CACHE_DIR/venv-py3.14"
PYTHON_BIN="python3.14"

# 1. Ensure Python 3.14 exists
if ! command -v "$PYTHON_BIN" &> /dev/null; then
    echo "Error: $PYTHON_BIN not found in PATH."
    exit 1
fi

# 2. Idempotent Environment Creation
# Only create venv if the directory doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo ":: Initializing venv in $VENV_DIR..."
    mkdir -p "$CACHE_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

# 3. Idempotent Dependency Check
# Try to import evdev. If it works, skip pip entirely (Instant execution).
if ! "$VENV_DIR/bin/python" -c "import evdev" &> /dev/null; then
    echo ":: 'evdev' missing. Installing..."
    "$VENV_DIR/bin/pip" install evdev --quiet --disable-pip-version-check
fi

# 4. Execute Payload
# Pass the script to the venv interpreter
"$VENV_DIR/bin/python" - << 'EOF'
import evdev
import sys
import os

# ANSI Colors
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
RESET = "\033[0m"

try:
    # ---------------------------------------------------------
    # PERMISSION CHECK
    # evdev requires read access to /dev/input/*
    # ---------------------------------------------------------
    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
    
    print(f"{'NAME':<40} | {'PHYS':<20} | {'TYPE GUESS'}")
    print("-" * 90)

    for dev in devices:
        caps = dev.capabilities()
        
        # EV_KEY=1, EV_ABS=3
        has_keys = 1 in caps
        has_abs = 3 in caps
        
        # Heuristic Logic
        if has_keys and has_abs:
            color = YELLOW
            guess = "TRACKPAD/TABLET"
        elif has_keys and not has_abs:
            color = RED
            guess = "KEYBOARD"
        else:
            color = GREEN
            guess = "OTHER/MOUSE"
            
        # Clean up names for display
        name = dev.name[:40]
        phys = dev.phys[:20] if dev.phys else "N/A"
        
        print(f"{color}{name:<40}{RESET} | {phys:<20} | {guess}")

except OSError as e:
    if e.errno == 13: # Permission Denied
        print(f"{RED}ERROR: Permission Denied{RESET}")
        print(f"You need to be in the 'input' group to read /dev/input/ devices.")
        print(f"Run this command: {YELLOW}sudo usermod -aG input $USER{RESET}")
        print("Then log out and log back in.")
        sys.exit(1)
    else:
        raise e
EOF
