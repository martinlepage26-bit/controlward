#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
EXTENSION_ID="${1:-}"
if [[ ! "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
  echo "Usage: $0 <32-character Chrome extension ID from chrome://extensions>" >&2
  exit 2
fi
"$SCRIPT_DIR/build-native-host.sh"
SOURCE="$REPO_ROOT/.work/chrome-native-host"
HOST_DIR="$HOME/Library/Application Support/ControlWard/ChromeBridge"
REGISTRY_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
HOST_NAME="com.controlward.chrome_bridge"
APP_CONTAINER="$HOME/Library/Containers/com.pharos.contextward/Data"
LEADS_DIR="$APP_CONTAINER/Library/Application Support/ControlWard/leads"
if [[ ! -d "$APP_CONTAINER/Library/Application Support" ]]; then
  echo "The configured ControlWard app container is not present: $APP_CONTAINER" >&2
  exit 1
fi
if [[ -e "$LEADS_DIR" && ! -d "$LEADS_DIR" ]]; then
  echo "The configured Leads path exists but is not a directory: $LEADS_DIR" >&2
  exit 1
fi
mkdir -p "$HOST_DIR" "$REGISTRY_DIR"
chmod 700 "$HOST_DIR" "$REGISTRY_DIR"
install -m 755 "$SOURCE/ControlWardChromeNativeHost" "$HOST_DIR/ControlWardChromeNativeHost"
rm -rf "$HOST_DIR/FollowUpOSNative_FollowUpOSNative.bundle"
cp -R "$SOURCE/FollowUpOSNative_FollowUpOSNative.bundle" "$HOST_DIR/FollowUpOSNative_FollowUpOSNative.bundle"
chmod -R go-rwx "$HOST_DIR/FollowUpOSNative_FollowUpOSNative.bundle"
WRAPPER="$HOST_DIR/ControlWardChromeBridge"
cat > "$WRAPPER" <<EOF
#!/bin/sh
# Keep Chrome’s native helper pointed at the same sandboxed data directory used by ControlWard.app.
export CONTROLWARD_LEADS_DIR="$LEADS_DIR"
exec "$HOST_DIR/ControlWardChromeNativeHost" --controlward-chrome-native-messaging
EOF
chmod 700 "$WRAPPER"
MANIFEST="$REGISTRY_DIR/$HOST_NAME.json"
python3 - "$MANIFEST" "$WRAPPER" "$EXTENSION_ID" <<'PY'
import json, pathlib, sys
path, executable, extension_id = sys.argv[1:]
payload = {
    "name": "com.controlward.chrome_bridge",
    "description": "Local ControlWard capture and review bridge",
    "path": executable,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"]
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
chmod 600 "$MANIFEST"
echo "Registered Chrome Native Messaging host for extension $EXTENSION_ID."
echo "Host manifest: $MANIFEST"
echo "This script does not install or update ControlWard.app; the host and extension are separate user-run components."
