#!/bin/bash
# Smoke tests for the iOS Simulator build.
#
# Purpose: catch runtime-only failures that `swift build` and `swift test`
# miss. The class of bug this targets is the SwiftUI / iOS app launch
# crash — `@EnvironmentObject` type-key mismatches, missing Info.plist
# keys, asset failures, etc. — where the build is clean but the app
# quits unexpectedly before the first frame renders.
#
# How it works: each scenario builds (if needed) → installs → launches
# the app on a booted simulator, then asserts something about the
# post-launch state. The launch-and-survive scenario just verifies the
# process is alive after a short window and no new crash report appeared
# in `~/Library/Logs/DiagnosticReports/`.
#
# Usage:
#   ./scripts/smoke-test.sh                  # run all scenarios
#   ./scripts/smoke-test.sh launch_survive   # run one scenario
#   ./scripts/smoke-test.sh --list           # list available scenarios
#
# Add new scenarios by:
#   1. Defining a `scenario_<name>` function below.
#   2. Adding `<name>` to the SCENARIOS array.
# Each scenario must exit non-zero on failure. Use the helpers
# (boot_simulator, install_and_launch, wait_and_assert_alive,
# crash_reports_since) to share infrastructure.

set -euo pipefail
cd "$(dirname "$0")/.."

# ────────────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────────────

PROJECT="PrimitiveAppTemplate.xcodeproj"
SCHEME="PrimitiveAppTemplate_iOS"
APP_NAME="PrimitiveAppTemplate"
SIM_NAME="${PRIMITIVE_SMOKE_SIM:-iPhone 17 Pro}"
LAUNCH_OBSERVATION_SECS="${PRIMITIVE_SMOKE_OBSERVE_SECS:-15}"

read_yml_value() {
    awk -v k="$1" 'BEGIN{FS=":"} $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
        sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2);
        gsub(/^"|"$/, "", $2); print $2; exit
    }' project.yml 2>/dev/null
}
BUNDLE_ID="$(read_yml_value PRODUCT_BUNDLE_IDENTIFIER)"
BUNDLE_ID="${BUNDLE_ID:-com.primitivelabs.PrimitiveAppTemplate}"

# Each entry below is a scenario function name; the runner invokes them
# in array order. Add new scenarios by appending here.
SCENARIOS=(launch_survive)

# ────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────

log()  { printf '[smoke-test] %s\n' "$*" >&2; }
fail() { printf '[smoke-test] FAIL: %s\n' "$*" >&2; return 1; }
pass() { printf '[smoke-test] PASS: %s\n' "$*" >&2; }

# Pick a booted simulator, or boot the configured one. Echoes the UDID.
boot_simulator() {
    local udid
    udid=$(xcrun simctl list devices booted -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
for dl in d['devices'].values():
    for dd in dl:
        if dd['state']=='Booted':
            print(dd['udid']); break
    else:
        continue
    break
")
    if [ -n "${udid:-}" ]; then
        echo "$udid"
        return 0
    fi
    log "No booted simulator; booting '$SIM_NAME'..."
    udid=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
name='$SIM_NAME'
d=json.load(sys.stdin)
for dl in d['devices'].values():
    for dd in dl:
        if dd['name']==name:
            print(dd['udid']); sys.exit(0)
" || true)
    if [ -z "${udid:-}" ]; then
        fail "Simulator '$SIM_NAME' not available. Set PRIMITIVE_SMOKE_SIM or install via Xcode."
        return 1
    fi
    xcrun simctl boot "$udid"
    open -ga Simulator
    echo "$udid"
}

# Build for the booted simulator. Echoes the .app path on success.
build_for_simulator() {
    local udid="$1"
    log "Running swift-bao-codegen..."
    local gen_dir="Sources/PrimitiveAppTemplate/Models/Generated"
    local schema_toml="Sources/PrimitiveAppTemplate/Models/schema.toml"
    mkdir -p "$gen_dir"
    swift run --package-path . swift-bao-codegen \
        --input  "$schema_toml" \
        --output "$gen_dir" >/dev/null

    if command -v xcodegen >/dev/null 2>&1; then
        xcodegen generate --quiet
    fi

    local derived="$PWD/build/smoke"
    log "xcodebuild → $derived ..."
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived" \
        -quiet \
        build >&2
    local app_path
    app_path=$(find "$derived/Build/Products" -name "$APP_NAME.app" -type d | head -1)
    if [ -z "${app_path:-}" ]; then
        fail "Built .app not found under $derived"
        return 1
    fi
    echo "$app_path"
}

# Returns the count of crash reports for $APP_NAME with mtime >= $1
# (epoch seconds). Used to detect "did a new crash report drop during
# this scenario?"
crash_reports_since() {
    local since_epoch="$1"
    find "$HOME/Library/Logs/DiagnosticReports" \
        -name "$APP_NAME-*.ips" \
        -newermt "@$since_epoch" 2>/dev/null | wc -l | tr -d ' '
}

# Returns the PID of $APP_NAME on the booted simulator, or empty if not
# running.
sim_pid() {
    local udid="$1"
    xcrun simctl spawn "$udid" launchctl list 2>/dev/null \
        | awk -v bid="$BUNDLE_ID" '$3 ~ bid {print $1; exit}'
}

# ────────────────────────────────────────────────────────────────────────
# Scenarios
# ────────────────────────────────────────────────────────────────────────

# launch_survive: the bedrock check. Cold-launches the app and asserts
# the process is still alive after LAUNCH_OBSERVATION_SECS, with no new
# crash report. Catches the entire class of "app quit unexpectedly on
# launch" bugs (SwiftUI EnvironmentObject type mismatches, missing
# Info.plist keys, broken xibs, etc.) that compile cleanly but die in
# `main()`.
scenario_launch_survive() {
    local udid="$1"
    local app_path="$2"

    log "Terminating any prior instance..."
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

    log "Installing $app_path..."
    xcrun simctl install "$udid" "$app_path"

    local launch_epoch
    launch_epoch=$(date +%s)
    log "Launching $BUNDLE_ID..."
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null

    log "Observing for ${LAUNCH_OBSERVATION_SECS}s..."
    sleep "$LAUNCH_OBSERVATION_SECS"

    local pid
    pid=$(sim_pid "$udid")
    if [ -z "${pid:-}" ] || [ "$pid" = "0" ]; then
        fail "Process not running after ${LAUNCH_OBSERVATION_SECS}s — app quit"
        # Surface the most recent crash report header if any.
        local recent_crash
        recent_crash=$(find "$HOME/Library/Logs/DiagnosticReports" \
            -name "$APP_NAME-*.ips" -newermt "@$launch_epoch" 2>/dev/null \
            | sort | tail -1)
        if [ -n "${recent_crash:-}" ]; then
            log "Recent crash report: $recent_crash"
            python3 -c "
import json,sys
with open('$recent_crash') as f:
    header = json.loads(f.readline())
print('  bundleID:', header.get('bundleID',''))
print('  os:      ', header.get('os_version',''))
print('  bug_type:', header.get('bug_type',''))
" || true
        fi
        return 1
    fi

    local new_crashes
    new_crashes=$(crash_reports_since "$launch_epoch")
    if [ "$new_crashes" != "0" ]; then
        fail "New crash report(s) appeared during run: $new_crashes"
        return 1
    fi

    log "Terminating PID $pid..."
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    pass "launch_survive (pid=$pid, observed ${LAUNCH_OBSERVATION_SECS}s, 0 new crashes)"
}

# ────────────────────────────────────────────────────────────────────────
# Runner
# ────────────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${SCENARIOS[@]}"
    exit 0
fi

selected=("${SCENARIOS[@]}")
if [ $# -gt 0 ]; then
    selected=("$@")
fi

log "Booting simulator..."
UDID=$(boot_simulator)
log "Using simulator: $UDID"

APP_PATH=$(build_for_simulator "$UDID")
log "Built app: $APP_PATH"

failures=0
for s in "${selected[@]}"; do
    fn="scenario_${s}"
    if ! declare -f "$fn" >/dev/null; then
        fail "Unknown scenario: $s (use --list to see available)"
        failures=$((failures + 1))
        continue
    fi
    log "→ $s"
    if ! "$fn" "$UDID" "$APP_PATH"; then
        failures=$((failures + 1))
    fi
done

if [ "$failures" != "0" ]; then
    log "Done — $failures failure(s)"
    exit 1
fi
log "Done — all scenarios passed"
