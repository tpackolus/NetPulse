#!/bin/bash
# ==============================================================================
# NetPulse macOS — Automatický inštalátor pre kolegov (Universal macOS App)
# Nainštaluje NetPulse.app do /Applications, odstráni macOS Gatekeeper karanténu
# a spustí aplikáciu.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NetPulse.app"
SOURCE_APP="$SCRIPT_DIR/$APP_NAME"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"

echo "===================================================="
echo " Inštalácia aplikácie NetPulse pre macOS"
echo "===================================================="

if [ ! -d "$SOURCE_APP" ]; then
    echo "[CHYBA] Súbor $APP_NAME sa nenašiel v priečinku: $SCRIPT_DIR"
    exit 1
fi

# 1. Ukončiť predchádzajúcu verziu, ak beží
pkill -f "NetPulse.app/Contents/MacOS/NetPulse" 2>/dev/null || true

# 2. Skopírovať do /Applications (alebo ~/Applications ak používateľ nemá práva do /Applications)
if [ -w "$TARGET_DIR" ]; then
    echo "[1/3] Kopírujem $APP_NAME do $TARGET_DIR..."
    rm -rf "$TARGET_APP"
    cp -R "$SOURCE_APP" "$TARGET_APP"
else
    TARGET_DIR="$HOME/Applications"
    TARGET_APP="$TARGET_DIR/$APP_NAME"
    mkdir -p "$TARGET_DIR"
    echo "[1/3] Kopírujem $APP_NAME do $TARGET_DIR..."
    rm -rf "$TARGET_APP"
    cp -R "$SOURCE_APP" "$TARGET_APP"
fi

# 3. Odstrániť Gatekeeper karanténu (aby sa na cudzom Macu nepýtalo na neovereného vývojára)
echo "[2/3] Nastavujem povolenia a odstraňujem macOS karanténu..."
xattr -cr "$TARGET_APP" 2>/dev/null || true
chmod +x "$TARGET_APP/Contents/MacOS/NetPulse"

# 4. Spustiť nainštalovanú aplikáciu
echo "[3/3] Spúšťam NetPulse..."
open -a "$TARGET_APP"

echo "===================================================="
echo " HOTOVO! Aplikácia NetPulse je nainštalovaná v:"
echo " $TARGET_APP"
echo "===================================================="
