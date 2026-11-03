#!/bin/bash
# ==============================================================================
# NetPulse macOS — One-Click Universal macOS Installer (Apple Silicon + Intel)
# Installs NetPulse.app to /Applications, clears macOS Gatekeeper quarantine,
# and launches the application.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NetPulse.app"
SOURCE_APP="$SCRIPT_DIR/$APP_NAME"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"

echo "===================================================="
echo " Installing NetPulse for macOS (Universal Binary)"
echo "===================================================="

if [ ! -d "$SOURCE_APP" ]; then
    echo "[ERROR] $APP_NAME was not found in directory: $SCRIPT_DIR"
    exit 1
fi

# 1. Stop any running instance of NetPulse
pkill -f "NetPulse.app/Contents/MacOS/NetPulse" 2>/dev/null || true

# 2. Copy to /Applications (or ~/Applications if user lacks write permission)
if [ -w "$TARGET_DIR" ]; then
    echo "[1/3] Copying $APP_NAME to $TARGET_DIR..."
    rm -rf "$TARGET_APP"
    cp -R "$SOURCE_APP" "$TARGET_APP"
else
    TARGET_DIR="$HOME/Applications"
    TARGET_APP="$TARGET_DIR/$APP_NAME"
    mkdir -p "$TARGET_DIR"
    echo "[1/3] Copying $APP_NAME to $TARGET_DIR..."
    rm -rf "$TARGET_APP"
    cp -R "$SOURCE_APP" "$TARGET_APP"
fi

# 3. Remove Gatekeeper quarantine attribute so it opens cleanly on any Mac
echo "[2/3] Configuring permissions and clearing macOS Gatekeeper quarantine..."
xattr -cr "$TARGET_APP" 2>/dev/null || true
chmod +x "$TARGET_APP/Contents/MacOS/NetPulse"

# 4. Launch the installed application
echo "[3/3] Launching NetPulse..."
open -a "$TARGET_APP"

echo "===================================================="
echo " SUCCESS! NetPulse has been installed to:"
echo " $TARGET_APP"
echo "===================================================="
