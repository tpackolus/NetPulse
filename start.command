#!/bin/bash
# NetPulse macOS — Launch Standalone Native Application (No Server)

DIR="$(cd "$(dirname "$0")" && pwd)"
open -a "$DIR/NetPulse.app"
