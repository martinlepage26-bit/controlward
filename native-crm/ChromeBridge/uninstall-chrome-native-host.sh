#!/bin/bash
set -euo pipefail
HOST_NAME="com.controlward.chrome_bridge"
MANIFEST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$HOST_NAME.json"
HOST_DIR="$HOME/Library/Application Support/ControlWard/ChromeBridge"
rm -f "$MANIFEST"
rm -rf "$HOST_DIR"
echo "Removed the Chrome host registration and helper files. ControlWard lead data and pairing state were not removed."
