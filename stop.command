#!/bin/bash
# NetPulse macOS — Stop Script

echo "[STOP] Zastavujem NetPulse macOS..."
pkill -f "NetPulse.app" 2>/dev/null
pkill -f "NetPulseMenuBar" 2>/dev/null
pkill -f "server.py" 2>/dev/null
echo "[OK] Vsetky procesy NetPulse boli ukoncene."
