#!/bin/bash
set -e

# ContextWard Build and Acceptance Test Script
# Usage: bash BUILD-AND-TEST.sh

PROJECT_DIR="/Users/pharos_ai/agent-work/contextward/native-crm"
XCODE_PATH="/Applications/Xcode.app"
SCHEME="FollowUpOSNative"
WORKSPACE="FollowUpOSNative.xcworkspace"

echo "=========================================="
echo "ContextWard: Build & Acceptance Test"
echo "=========================================="
echo ""

# Check Xcode installation
echo "[1/4] Checking Xcode installation..."
if [ ! -d "$XCODE_PATH" ]; then
    echo "❌ Xcode not found at $XCODE_PATH"
    echo ""
    echo "Install Xcode using one of these methods:"
    echo "  1. App Store: Open App Store, search 'Xcode', click Install"
    echo "  2. CLI: mas install 497799835 (requires mas: brew install mas)"
    echo "  3. Manual: https://developer.apple.com/download"
    echo ""
    echo "Then run this script again."
    exit 1
fi
echo "✓ Xcode found at $XCODE_PATH"
echo ""

# Verify Xcode version
echo "[2/4] Verifying Xcode tools..."
xcodebuild -version
echo "✓ Xcode tools available"
echo ""

# Build the app
echo "[3/4] Building FollowUpOSNative..."
cd "$PROJECT_DIR"
if xcodebuild -scheme "$SCHEME" -workspace "$WORKSPACE" -configuration Release build; then
    echo "✓ Build successful"
    BUILD_PATH="$(find "$PROJECT_DIR/build/Release" -name "*.app" -type d | head -1)"
    if [ -n "$BUILD_PATH" ]; then
        echo "  App built at: $BUILD_PATH"
    fi
else
    echo "❌ Build failed"
    exit 1
fi
echo ""

# Launch the app
echo "[4/4] Launching app..."
if [ -n "$BUILD_PATH" ]; then
    open "$BUILD_PATH"
    echo "✓ App launched"
    echo ""
    echo "=========================================="
    echo "Next: Run the 27-step acceptance test"
    echo "=========================================="
    echo ""
    echo "Follow the steps in ACCEPTANCE-TEST-PLAN-20261014.md:"
    echo "  - Create company, contact, lead"
    echo "  - Link relationships"
    echo "  - Create notes, opportunity, task"
    echo "  - Verify persistence after quit/reopen"
    echo ""
    echo "Report results when complete."
else
    echo "⚠ Could not locate built app"
    exit 1
fi
