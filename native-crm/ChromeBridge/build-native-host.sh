#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
PACKAGE="$REPO_ROOT/native-crm"
mkdir -p "$REPO_ROOT/.work"
SCRATCH="$(mktemp -d "$REPO_ROOT/.work/chrome-native-build.XXXXXX")"
BUILDER_HOME="$REPO_ROOT/.work/chrome-native-home"
SWIFT_CACHE="$REPO_ROOT/.work/swiftpm-cache"
SWIFT_CONFIG="$BUILDER_HOME/.swiftpm"
OUTPUT="$REPO_ROOT/.work/chrome-native-host"
EXPECTED_SWIFT="$(tr -d '[:space:]' < "$PACKAGE/.swift-version")"
ACTUAL_SWIFT="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
if [[ "$ACTUAL_SWIFT" != "$EXPECTED_SWIFT" ]]; then
  echo "Swift $EXPECTED_SWIFT is pinned; found ${ACTUAL_SWIFT:-unknown}." >&2
  exit 1
fi
mkdir -p "$OUTPUT" "$BUILDER_HOME" "$SWIFT_CACHE" "$SWIFT_CONFIG"
HOME="$BUILDER_HOME" swift build --package-path "$PACKAGE" --scratch-path "$SCRATCH" --cache-path "$SWIFT_CACHE" --config-path "$SWIFT_CONFIG" -c release --disable-sandbox
BIN_DIR="$(HOME="$BUILDER_HOME" swift build --package-path "$PACKAGE" --scratch-path "$SCRATCH" --cache-path "$SWIFT_CACHE" --config-path "$SWIFT_CONFIG" -c release --show-bin-path --disable-sandbox)"
RESOURCE_BUNDLE="$BIN_DIR/FollowUpOSNative_FollowUpOSNative.bundle"
if [[ ! -x "$BIN_DIR/FollowUpOSNative" || ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "The ControlWard executable or SwiftPM resource bundle is missing." >&2
  exit 1
fi
install -m 755 "$BIN_DIR/FollowUpOSNative" "$OUTPUT/ControlWardChromeNativeHost"
rm -rf "$OUTPUT/FollowUpOSNative_FollowUpOSNative.bundle"
cp -R "$RESOURCE_BUNDLE" "$OUTPUT/FollowUpOSNative_FollowUpOSNative.bundle"
echo "Built host files in: $OUTPUT"
