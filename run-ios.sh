#!/bin/bash
# Build and run on iOS Simulator (default) or a connected physical device (--device).
#
# Usage:
#   ./run-ios.sh                build & run on simulator
#   ./run-ios.sh --device       build & run on first paired iPhone
#   ./run-ios.sh --verbose      stream all process logs (simulator only)
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="PrimitiveAppTemplate.xcodeproj"
SCHEME="PrimitiveAppTemplate_iOS"
APP_NAME="PrimitiveAppTemplate"
# Bundle ID is read from project.yml (xcodegen source of truth) so the
# CLI's per-user slugging (`primitive init --platform apple`) flows
# through without needing to edit this script too. Fallback only kicks in
# if project.yml is missing or unparseable.
read_yml_value() {
    local key="$1"
    awk -v k="$key" 'BEGIN{FS=":"} $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
        sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2);
        gsub(/^"|"$/, "", $2); print $2; exit
    }' project.yml 2>/dev/null
}
BUNDLE_ID="$(read_yml_value PRODUCT_BUNDLE_IDENTIFIER)"
BUNDLE_ID="${BUNDLE_ID:-com.primitivelabs.PrimitiveAppTemplate}"

USE_DEVICE=false
VERBOSE=false
SIM_TARGET=""
# Args: --device, --verbose, --sim <name-or-udid>. We hand-roll the
# parser (no getopt on macOS by default) so a positional value can
# follow `--sim` without the user quoting it.
while [ $# -gt 0 ]; do
    case "$1" in
        --device)  USE_DEVICE=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --sim)
            if [ -z "${2:-}" ]; then
                echo "--sim requires a simulator name or UDID, e.g. --sim \"iPhone 15\"" >&2
                exit 1
            fi
            SIM_TARGET="$2"; shift 2 ;;
        --sim=*)
            SIM_TARGET="${1#--sim=}"; shift ;;
        *) echo "Unknown argument: $1"; echo "Usage: $0 [--device] [--verbose] [--sim <name-or-udid>]"; exit 1 ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# Model codegen (Xcode build path)
# ────────────────────────────────────────────────────────────────────────────
# `swift build` runs `JsBaoCodegenPlugin` automatically. The Xcode app
# target compiles its own source list from `.pbxproj` though, so the
# SPM plugin never fires on the iOS path — run the codegen tool by hand
# here, writing into a checked-out `Generated/` directory that xcodegen
# picks up below.
GEN_DIR="Sources/PrimitiveAppTemplate/Models/Generated"
SCHEMA_TOML="Sources/PrimitiveAppTemplate/Models/models.toml"
mkdir -p "$GEN_DIR"
echo "Running swift-bao-codegen..."
swift run --package-path . swift-bao-codegen \
    --input  "$SCHEMA_TOML" \
    --output "$GEN_DIR"

# Regenerate the xcodeproj from project.yml so that newly added source
# files (including freshly-codegen'd `Generated/*.swift`) get picked up.
# xcodegen is idempotent + fast; skip silently if not installed (users
# can still build if their xcodeproj is up to date).
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
else
    echo "Warning: xcodegen not installed — xcodeproj may be stale if files were added/removed."
    echo "  Install with: brew install xcodegen"
fi

# ────────────────────────────────────────────────────────────────────────────
# Physical device path (--device)
# ────────────────────────────────────────────────────────────────────────────
if [ "$USE_DEVICE" = true ]; then
    # devicectl prints a harmless "Failed to load provisioning paramter list"
    # warning to stderr on every invocation (it's about the unrelated `devicectl
    # manage create` subcommand). Filter it out so real errors stand out.
    DEVICECTL_NOISE='(^Failed to load provisioning paramter list|^`devicectl manage create` may support)'
    filter_devicectl_stderr() { grep -E -v "$DEVICECTL_NOISE" >&2 || true; }

    DEVICES_JSON=$(mktemp -t devicectl.XXXXXX.json)
    trap 'rm -f "$DEVICES_JSON"' EXIT
    xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2> >(filter_devicectl_stderr) || true

    DEVICE_UDID=$(python3 -c "
import json
with open('$DEVICES_JSON') as f:
    data = json.load(f)
for d in data.get('result', {}).get('devices', []):
    hw = d.get('hardwareProperties', {})
    conn = d.get('connectionProperties', {})
    if hw.get('platform') == 'iOS' and conn.get('pairingState') == 'paired':
        print(d.get('identifier', ''))
        break
")
    if [ -z "$DEVICE_UDID" ]; then
        echo "Error: No paired iPhone found."
        echo "  Connect your device via USB, trust this Mac, and verify with:"
        echo "  xcrun devicectl list devices"
        exit 1
    fi

    DEVICE_NAME=$(python3 -c "
import json
with open('$DEVICES_JSON') as f:
    data = json.load(f)
for d in data.get('result', {}).get('devices', []):
    if d.get('identifier') == '$DEVICE_UDID':
        print(d.get('deviceProperties', {}).get('name', 'iPhone'))
        break
")
    echo "Using device: $DEVICE_NAME ($DEVICE_UDID)"

    echo "Building for iOS device..."
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "id=$DEVICE_UDID" \
        -allowProvisioningUpdates \
        -quiet \
        2>&1

    BUILD_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$DEVICE_UDID" -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR" | awk '{print $3}')
    APP_PATH="$BUILD_DIR/${APP_NAME}.app"

    if [ ! -d "$APP_PATH" ]; then
        echo "Error: Build succeeded but can't find $APP_PATH"
        exit 1
    fi

    echo "Installing on $DEVICE_NAME..."
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" \
        2> >(filter_devicectl_stderr)

    echo "Launching on $DEVICE_NAME -- streaming console (Ctrl+C to stop)"
    echo "─────────────────────────────────────────────────────────"
    # --console attaches stdout/stderr from the launched process (print / NSLog).
    # For full os_log streaming, open Console.app and select the device.
    xcrun devicectl device process launch \
        --console \
        --terminate-existing \
        --device "$DEVICE_UDID" \
        "$BUNDLE_ID" \
        2> >(filter_devicectl_stderr)
    exit 0
fi

# ────────────────────────────────────────────────────────────────────────────
# Simulator path (default)
# ────────────────────────────────────────────────────────────────────────────
# Pick a simulator. Order of preference:
#   1. --sim <name-or-udid>  (explicit)
#   2. first booted simulator
#   3. latest iPhone available
# Names match case-insensitively; UDIDs match exactly. If `--sim` is
# given and matches a simulator that isn't booted yet, boot it.
BOOTED_UDID=""

if [ -n "$SIM_TARGET" ]; then
    BOOTED_UDID=$(SIM_TARGET="$SIM_TARGET" xcrun simctl list devices available -j | SIM_TARGET="$SIM_TARGET" python3 -c "
import json, os, sys
target = os.environ.get('SIM_TARGET', '').strip()
target_lower = target.lower()
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if not d.get('isAvailable', False): continue
        if d.get('udid') == target or d.get('name', '').lower() == target_lower:
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)
    if [ -z "$BOOTED_UDID" ]; then
        echo "Error: --sim '$SIM_TARGET' did not match any available simulator." >&2
        echo "  Available simulators: xcrun simctl list devices available" >&2
        exit 1
    fi
    # Boot it if it isn't already.
    STATE=$(xcrun simctl list devices -j | BOOTED_UDID="$BOOTED_UDID" python3 -c "
import json, os, sys
needle = os.environ['BOOTED_UDID']
data = json.load(sys.stdin)
for devices in data.get('devices', {}).values():
    for d in devices:
        if d.get('udid') == needle:
            print(d.get('state', ''))
            sys.exit(0)
")
    if [ "$STATE" != "Booted" ]; then
        echo "Booting requested simulator..."
        xcrun simctl boot "$BOOTED_UDID"
        open -a Simulator
    fi
else
    BOOTED_UDID=$(xcrun simctl list devices booted -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d['state'] == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)
fi

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

if [ "$VERBOSE" = true ]; then
    # All logs from the process (includes Apple framework noise)
    xcrun simctl spawn "$BOOTED_UDID" log stream \
        --predicate "process == \"$APP_NAME\"" \
        --level debug \
        --style compact
else
    # Only our app's logs (PrimitiveApp library + NSLog/print output)
    xcrun simctl spawn "$BOOTED_UDID" log stream \
        --predicate "subsystem BEGINSWITH \"com.primitivelabs\" OR (process == \"$APP_NAME\" AND subsystem == \"\")" \
        --level debug \
        --style compact
fi
