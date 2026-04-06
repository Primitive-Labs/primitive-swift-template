#!/bin/bash
# Build and run on iOS Simulator (no Xcode GUI needed)
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="PrimitiveAppTemplate.xcodeproj"
SCHEME="PrimitiveAppTemplate_iOS"
BUNDLE_ID="com.primitivelabs.PrimitiveAppTemplate"

# Pick a simulator -- use first booted, or default to latest iPhone
BOOTED_UDID=$(xcrun simctl list devices booted -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d['state'] == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)

if [ -z "$BOOTED_UDID" ]; then
    echo "No simulator booted. Starting one..."
    # Find latest iPhone simulator
    SIM_UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime in sorted(data.get('devices', {}).keys(), reverse=True):
    if 'iOS' not in runtime: continue
    for d in data['devices'][runtime]:
        if 'iPhone' in d['name'] and d['isAvailable']:
            print(d['udid'])
            sys.exit(0)
print('', end='')
")
    if [ -z "$SIM_UDID" ]; then
        echo "Error: No available iPhone simulator found."
        exit 1
    fi
    xcrun simctl boot "$SIM_UDID"
    BOOTED_UDID="$SIM_UDID"
    # Open Simulator.app so you can see it
    open -a Simulator
fi

SIM_NAME=$(xcrun simctl list devices -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for devices in data.get('devices', {}).values():
    for d in devices:
        if d['udid'] == '$BOOTED_UDID':
            print(d['name'])
            sys.exit(0)
")
echo "Using simulator: $SIM_NAME ($BOOTED_UDID)"

echo "Building for iOS Simulator..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$BOOTED_UDID" \
    -quiet \
    2>&1

# Find the built .app
BUILD_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$BOOTED_UDID" -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR" | awk '{print $3}')
APP_PATH="$BUILD_DIR/PrimitiveAppTemplate.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build succeeded but can't find $APP_PATH"
    exit 1
fi

echo "Installing..."
xcrun simctl install "$BOOTED_UDID" "$APP_PATH"

echo "Launching..."
xcrun simctl launch "$BOOTED_UDID" "$BUNDLE_ID"

echo "Running on $SIM_NAME -- streaming logs (Ctrl+C to stop)"
echo "─────────────────────────────────────────────────────────"

if [ "${1:-}" = "--verbose" ]; then
    # All logs from the process (includes Apple framework noise)
    xcrun simctl spawn "$BOOTED_UDID" log stream \
        --predicate "process == \"PrimitiveAppTemplate\"" \
        --level debug \
        --style compact
else
    # Only our app's logs (PrimitiveApp library + NSLog/print output)
    xcrun simctl spawn "$BOOTED_UDID" log stream \
        --predicate "subsystem BEGINSWITH \"com.primitivelabs\" OR (process == \"PrimitiveAppTemplate\" AND subsystem == \"\")" \
        --level debug \
        --style compact
fi
