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
#   ./scripts/smoke-test.sh                  # run the default scenarios
#   ./scripts/smoke-test.sh launch_survive   # run one scenario
#   ./scripts/smoke-test.sh ui_signin        # run the idb UI sign-in scenario
#   ./scripts/smoke-test.sh --list           # list available scenarios
#
#   PRIMITIVE_SMOKE_PREFLIGHT_ONLY=1 ./scripts/smoke-test.sh ui_signin
#       run only the selected scenarios' preflight checks (no boot, no build)
#       to confirm the machine and app settings are set up for them.
#
# Scenarios are split into two arrays:
#   - AVAILABLE_SCENARIOS — everything `--list` shows and you can run by name.
#   - DEFAULT_SCENARIOS   — what a bare `./scripts/smoke-test.sh` runs.
# `ui_signin` is available but NOT default, so the zero-dependency default
# run (`pnpm swift:smoke`) needs no idb/companion installed. Select it
# explicitly to opt into the idb-driven UI test.
#
# Add new scenarios by:
#   1. Defining a `scenario_<name>` function below.
#   2. Adding `<name>` to AVAILABLE_SCENARIOS (and DEFAULT_SCENARIOS if it
#      should run by default).
#   3. Optionally defining a `preflight_<name>` function — the runner calls
#      it BEFORE the slow boot/build so a missing prerequisite fails fast.
# Each scenario must exit non-zero on failure. Use the helpers
# (boot_simulator, build_for_simulator, sim_pid, crash_reports_since, and
# the idb_* helpers) to share infrastructure.

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

# ui_signin knobs.
#   PRIMITIVE_SMOKE_TEST_EMAIL  — a whitelisted +primitivetest address to sign
#                                 in as (REQUIRED for ui_signin; see preflight).
#   PRIMITIVE_SMOKE_SUCCESS_ID  — accessibility identifier the scenario asserts
#                                 renders after sign-in. Defaults to the
#                                 unmodified template's Home screen; override it
#                                 when you replace the post-login UI.
#   PRIMITIVE_IDB_COMPANION     — host:port of a caller-managed idb companion.
#                                 When set, the scenario talks to it instead of
#                                 starting/stopping its own.
#   PRIMITIVE_SMOKE_TEST_EMAIL_INVITED
#                               — set to 1 when the app's signup mode is
#                                 invite-only and PRIMITIVE_SMOKE_TEST_EMAIL has
#                                 already been invited. The preflight can read
#                                 the mode but not the app's invitations, so
#                                 this is how you tell it the address is
#                                 admitted.
TEST_EMAIL="${PRIMITIVE_SMOKE_TEST_EMAIL:-}"
SUCCESS_ID="${PRIMITIVE_SMOKE_SUCCESS_ID:-primitive.template.home}"

# idb companion state (set by start_idb_companion, torn down on exit).
IDB_TARGET=""
IDB_PORT=""
IDB_COMPANION_PID=""

read_yml_value() {
    awk -v k="$1" 'BEGIN{FS=":"} $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
        sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2);
        gsub(/^"|"$/, "", $2); print $2; exit
    }' project.yml 2>/dev/null
}
BUNDLE_ID="$(read_yml_value PRODUCT_BUNDLE_IDENTIFIER)"
BUNDLE_ID="${BUNDLE_ID:-com.primitivelabs.PrimitiveAppTemplate}"

# Every runnable scenario (drives `--list`). Each name has a matching
# `scenario_<name>` function below.
AVAILABLE_SCENARIOS=(launch_survive ui_signin)
# What a bare `./scripts/smoke-test.sh` runs. Kept to the zero-dependency
# scenarios so `pnpm swift:smoke` never needs idb installed.
DEFAULT_SCENARIOS=(launch_survive)

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
    # Checked explicitly: this function runs inside a command substitution,
    # which does not inherit `set -e`, so a failed boot would otherwise fall
    # through and echo a UDID nothing is running on.
    if ! xcrun simctl boot "$udid"; then
        fail "Could not boot simulator '$SIM_NAME' ($udid)."
        return 1
    fi
    open -ga Simulator
    echo "$udid"
}

# Build for the booted simulator. Sets $APP_PATH to the built .app on success.
#
# This deliberately reports through a variable instead of echoing the path,
# so callers can run it as a plain command. Under `APP_PATH=$(build_for_simulator …)`
# the whole build ran in a command-substitution subshell, which does not
# inherit `set -e` (bash has no `inherit_errexit`): a failed xcodebuild did
# not stop the function, the `find` below still matched the partial bundle
# xcodebuild copies resources into before compiling, and the run went on to
# install an app with no executable — burying the compile error under
# unrelated install/launch errors (#2582).
build_for_simulator() {
    local udid="$1"
    APP_PATH=""
    log "Running swift-bao-codegen..."
    local gen_dir="Sources/PrimitiveAppTemplate/Models/Generated"
    local schema_toml="Sources/PrimitiveAppTemplate/Models/models.toml"
    mkdir -p "$gen_dir"
    swift run --package-path . swift-bao-codegen \
        --input  "$schema_toml" \
        --output "$gen_dir" >/dev/null

    # Regenerate the project so the sources codegen just wrote are in it, then
    # re-copy the app's package pin into the container that regeneration
    # rewrote — otherwise the build below could use a different revision than
    # the codegen above just ran. See scripts/regenerate-project.sh.
    bash scripts/regenerate-project.sh "$PROJECT"

    local derived="$PWD/build/smoke"
    log "xcodebuild → $derived ..."
    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$derived" \
        -quiet \
        build >&2
    then
        fail "xcodebuild failed — see the build output above."
        return 1
    fi
    local app_path
    app_path=$(find "$derived/Build/Products" -name "$APP_NAME.app" -type d | head -1)
    if [ -z "${app_path:-}" ]; then
        fail "Built .app not found under $derived"
        return 1
    fi
    APP_PATH="$app_path"
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
# idb helpers (used by ui_signin)
# ────────────────────────────────────────────────────────────────────────
#
# idb (Facebook's iOS Debug Bridge) is the only tool that can drive the
# app's SwiftUI UI headlessly — `xcrun simctl` has no tap/text input, and
# macOS accessibility can't reach a SwiftUI surface. The scenario locates
# controls by their `.accessibilityIdentifier` (stable across copy
# changes), reading the AX tree from `idb ui describe-all`. Coordinates are
# in POINTS, which is exactly what describe-all reports, so there is no
# pixel/point conversion.

# Echoes a free localhost TCP port.
find_free_port() {
    python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}

# Run an idb subcommand against the active companion.
idb_cmd() { idb --companion "$IDB_TARGET" "$@"; }

# Start an idb companion for $1 (UDID) on a free port and wait until it
# answers. When PRIMITIVE_IDB_COMPANION is set, use that instead and start
# nothing. Registers teardown on script exit.
start_idb_companion() {
    local udid="$1"
    if [ -n "${PRIMITIVE_IDB_COMPANION:-}" ]; then
        IDB_TARGET="$PRIMITIVE_IDB_COMPANION"
        log "Using caller-managed idb companion at $IDB_TARGET"
        return 0
    fi
    trap stop_idb_companion EXIT
    mkdir -p "$PWD/build/smoke"
    IDB_PORT=$(find_free_port)
    IDB_TARGET="localhost:$IDB_PORT"
    log "Starting idb companion for $udid on $IDB_TARGET..."
    idb_companion --udid "$udid" --grpc-port "$IDB_PORT" \
        >"$PWD/build/smoke/idb-companion-$IDB_PORT.log" 2>&1 &
    IDB_COMPANION_PID=$!
    local tries=0
    until idb_cmd ui describe-all >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -gt 40 ]; then
            fail "idb companion did not become ready on $IDB_TARGET (see build/smoke/idb-companion-$IDB_PORT.log)"
            return 1
        fi
        sleep 0.5
    done
}

# Stop the companion we started (idempotent; no-op for a caller-managed one).
stop_idb_companion() {
    if [ -n "${IDB_COMPANION_PID:-}" ]; then
        kill "$IDB_COMPANION_PID" >/dev/null 2>&1 || true
        IDB_COMPANION_PID=""
    fi
}

# Echo "X Y" (the center, in integer points) of the element whose accessibility
# identifier is $1, or return non-zero if it's not currently in the AX tree.
# `idb ui describe-all` surfaces a SwiftUI `.accessibilityIdentifier` under the
# `AXUniqueId` key (not `AXIdentifier`, which idb does not emit). Coordinates are
# rounded to integers because `idb ui tap` rejects non-integer X/Y arguments.
idb_center_of() {
    idb_cmd ui describe-all 2>/dev/null | python3 -c "
import json, sys
tid = '$1'
try:
    els = json.load(sys.stdin)
except Exception:
    sys.exit(2)
for e in els:
    if e.get('AXUniqueId') == tid:
        f = e.get('frame') or {}
        print('%d %d' % (round(f.get('x', 0) + f.get('width', 0) / 2),
                         round(f.get('y', 0) + f.get('height', 0) / 2)))
        sys.exit(0)
sys.exit(1)
"
}

# Poll describe-all until the element with accessibility identifier $1 appears,
# up to $2 seconds (default 20). Returns non-zero on timeout.
idb_wait_id() {
    local target_id="$1"
    local timeout="${2:-20}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if idb_center_of "$target_id" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Tap the center of the element with accessibility identifier $1. Returns
# non-zero if it isn't present.
idb_tap_id() {
    local coords
    coords=$(idb_center_of "$1") || return 1
    [ -n "$coords" ] || return 1
    # Word-splitting of "X Y" into two tap args is intentional.
    # shellcheck disable=SC2086
    idb_cmd ui tap $coords
}

# On failure, capture a screenshot and dump the AX tree the scenario was
# matching against, so a missed identifier is diagnosable without a re-run.
dump_ui_state() {
    local udid="$1"
    local tag="${2:-failure}"
    local shot="$PWD/build/smoke/ui_signin-$tag.png"
    if xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1; then
        log "Screenshot: $shot"
    fi
    log "AX tree (idb ui describe-all):"
    idb_cmd ui describe-all 2>/dev/null | python3 -m json.tool >&2 2>/dev/null || true
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

# preflight_ui_signin: check ui_signin's prerequisites BEFORE the slow
# boot/build so a missing one fails fast with actionable instructions
# (never a silent green skip — this scenario is opt-in, so if you ask for
# it and it can't run, that's an error). Checks, in order: the test email,
# idb + companion presence and runnability, and the app's server settings
# (test-email whitelist, otpEnabled, and a signup mode that admits the
# address).
preflight_ui_signin() {
    local ok=1

    # 1. A whitelisted +primitivetest address to sign in as.
    if [ -z "$TEST_EMAIL" ]; then
        fail "ui_signin requires PRIMITIVE_SMOKE_TEST_EMAIL (a whitelisted +primitivetest address)."
        cat >&2 <<'EOF'
[smoke-test]   ui_signin signs in end-to-end through the +primitivetest OTP bypass,
[smoke-test]   so it needs a whitelisted test address:
[smoke-test]     1. Add a base email to your app's testAccountBaseEmails, e.g. in app.toml:
[smoke-test]          [app]
[smoke-test]          testAccountBaseEmails = ["you@example.com"]
[smoke-test]        then apply it:  primitive settings push
[smoke-test]     2. export PRIMITIVE_SMOKE_TEST_EMAIL="you+primitivetest-smoke@example.com"
[smoke-test]   See the DevTools agent guide (idb section) and the Authentication guide's
[smoke-test]   "Test User Sign-In" section for the full contract.
EOF
        ok=0
    fi

    # 2. idb client + companion installed and runnable. The Python `idb` client
    # is always required. The native `idb_companion` binary is only needed when
    # the scenario starts its own; a caller-managed remote companion
    # (PRIMITIVE_IDB_COMPANION) supplies it, so don't demand the local binary in
    # that configuration.
    local need_local_companion=1
    [ -n "${PRIMITIVE_IDB_COMPANION:-}" ] && need_local_companion=0
    if ! command -v idb >/dev/null 2>&1 \
       || { [ "$need_local_companion" = "1" ] && ! command -v idb_companion >/dev/null 2>&1; }; then
        if [ "$need_local_companion" = "1" ]; then
            fail "ui_signin requires idb (the fb-idb client) and idb_companion."
        else
            fail "ui_signin requires idb (the fb-idb client) on PATH."
        fi
        cat >&2 <<'EOF'
[smoke-test]   Install both:
[smoke-test]     brew install facebook/fb/idb-companion
[smoke-test]     python3.12 -m venv idbenv && ./idbenv/bin/pip install fb-idb
[smoke-test]     export PATH="$PWD/idbenv/bin:$PATH"   # so `idb` is on PATH
[smoke-test]   Note: fb-idb needs Python 3.12 — it breaks on 3.14 (asyncio.get_event_loop
[smoke-test]   was removed). Use a 3.12 venv as shown above.
EOF
        ok=0
    elif ! idb --help >/dev/null 2>&1; then
        fail "idb is installed but not runnable — likely the Python 3.14 fb-idb breakage."
        cat >&2 <<'EOF'
[smoke-test]   fb-idb depends on asyncio.get_event_loop, removed in Python 3.14.
[smoke-test]   Reinstall it into a Python 3.12 venv:
[smoke-test]     python3.12 -m venv idbenv && ./idbenv/bin/pip install fb-idb
[smoke-test]     export PATH="$PWD/idbenv/bin:$PATH"
EOF
        ok=0
    fi

    # 3. Server settings: the test email's base must be whitelisted, OTP must
    # be enabled (with OTP off, the same button sends a magic link instead of
    # prompting for a code, so ui_signin can't complete), and the app's signup
    # mode must admit the test address. The +primitivetest bypass does NOT
    # skip the signup gate — the server runs the invite-only/domain access
    # check before it looks at the whitelist — so on a freshly scaffolded app
    # (mode = invite-only by default) the first run fails at OTP request with
    # "This app is invite-only. You've been added to the waitlist." Uses the
    # CLI's effective-settings view — no bash config parsing.
    if [ "$ok" = "1" ]; then
        if ! command -v primitive >/dev/null 2>&1; then
            fail "ui_signin's settings preflight needs the 'primitive' CLI on PATH (install it and 'primitive login')."
            ok=0
        else
            # Values reach Python through the environment, never through
            # string interpolation: an apostrophe in the address (o'brien@…)
            # would otherwise raise a SyntaxError, and the empty output would
            # read as "no problem" — a silently passing preflight.
            local base_email problem settings_json settings_err
            base_email=$(SMOKE_TEST_EMAIL="$TEST_EMAIL" python3 -c "
import os
e = os.environ['SMOKE_TEST_EMAIL']
local, _, domain = e.partition('@')
print(local.split('+', 1)[0] + '@' + domain)
") || base_email=""
            if [ -z "$base_email" ]; then
                # Returns instead of setting ok=0 like the checks around it:
                # every remaining check needs $base_email, so continuing would
                # only add misleading "not in testAccountBaseEmails []" noise
                # on top of the real problem.
                fail "ui_signin prerequisite not met: could not derive the base address from $TEST_EMAIL (is python3 on PATH?)"
                return 1
            fi
            # Capture the CLI's output and status explicitly. Letting the
            # failure flow through a pipeline would abort the whole script
            # under `set -euo pipefail` before this preflight can print the
            # actionable message it exists to print.
            # The CLI's own stderr is kept (in a temp file, so the command
            # substitution still captures only stdout) and echoed under the
            # guidance below: "could not read settings" alone is rarely
            # enough to act on, but the CLI usually says exactly what is
            # wrong.
            local settings_err_file
            settings_err_file=$(mktemp)
            settings_json=$(primitive settings show --json 2>"$settings_err_file") || settings_json=""
            settings_err=$(cat "$settings_err_file")
            rm -f "$settings_err_file"
            problem=$(SMOKE_SETTINGS_JSON="$settings_json" \
                      SMOKE_BASE_EMAIL="$base_email" \
                      SMOKE_TEST_EMAIL="$TEST_EMAIL" \
                      SMOKE_INVITED_ACK="${PRIMITIVE_SMOKE_TEST_EMAIL_INVITED:-}" \
                      python3 -c "
import json, os, sys
base = os.environ['SMOKE_BASE_EMAIL']
try:
    s = json.loads(os.environ['SMOKE_SETTINGS_JSON'])
    if not isinstance(s, dict):
        raise ValueError('settings is not an object')
except Exception:
    print('could not read settings (is the CLI logged in and pointed at this app?)'); sys.exit(0)
email = os.environ['SMOKE_TEST_EMAIL']
invited_ack = os.environ['SMOKE_INVITED_ACK']
bases = s.get('testAccountBaseEmails') or []
if base not in bases:
    print('base address ' + base + ' is not in testAccountBaseEmails ' + json.dumps(bases)); sys.exit(0)
if not s.get('otpEnabled'):
    print('otpEnabled is false — enable OTP so the email button prompts for a code, not a magic link'); sys.exit(0)
mode = s.get('mode') or '(unset)'
if mode == 'domain':
    domain = email.rpartition('@')[2].lower()
    allowed = [d.lower() for d in (s.get('allowedDomains') or [])]
    if domain not in allowed:
        print('signup mode is domain and ' + domain + ' is not in allowedDomains '
              + json.dumps(allowed) + ' — the +primitivetest bypass does not skip the '
              'signup gate, so OTP request is rejected before the bypass applies. Either '
              'set mode to public, or add the domain to allowedDomains.'); sys.exit(0)
elif mode != 'public' and not invited_ack:
    print('signup mode is ' + mode + ' — the +primitivetest bypass does not skip the '
          'signup gate, so ' + email + ' must already be admitted to the app or OTP '
          'request fails with: This app is invite-only. You have been added to the '
          'waitlist. Either set mode to public in app.toml and run primitive settings '
          'push, or invite that exact address (the full +primitivetest string, lowercase '
          '— an invitation for the base address does not cover it; role member) and '
          're-run with PRIMITIVE_SMOKE_TEST_EMAIL_INVITED=1. Invite-only does work with '
          'a pre-invited address; this check just cannot see invitations.'); sys.exit(0)
print('')
") || problem="the settings preflight could not run (python3 exited non-zero)"
            if [ -n "$problem" ]; then
                fail "ui_signin prerequisite not met: $problem"
                if [ -n "$settings_err" ]; then
                    echo "[smoke-test]   The CLI said:" >&2
                    printf '%s\n' "$settings_err" | sed 's/^/[smoke-test]     /' >&2
                fi
                cat >&2 <<EOF
[smoke-test]   Fix it via the current settings workflow, e.g. in app.toml:
[smoke-test]     [app]
[smoke-test]     mode = "public"
[smoke-test]     testAccountBaseEmails = ["$base_email"]
[smoke-test]     [auth]
[smoke-test]     otpEnabled = true
[smoke-test]   then:  primitive settings push
[smoke-test]   A freshly scaffolded app defaults to mode = "invite-only", which rejects
[smoke-test]   an uninvited address at OTP request — the +primitivetest bypass runs
[smoke-test]   after that gate, not instead of it. To stay invite-only, invite
[smoke-test]   $TEST_EMAIL (that exact address, role member) and re-run with
[smoke-test]   PRIMITIVE_SMOKE_TEST_EMAIL_INVITED=1.
EOF
                ok=0
            fi
        fi
    fi

    [ "$ok" = "1" ] || return 1
}

# ui_signin: the idb-driven UI smoke test. Signs in end-to-end through the
# +primitivetest OTP bypass and asserts the post-login screen renders.
# This closes the gap the plain `launch_survive` can't reach: driving the
# app's SwiftUI form (tap, type, submit), which needs idb. It complements
# the Debug Inspector — idb drives the UI, the Inspector asserts state.
scenario_ui_signin() {
    local udid="$1"
    local app_path="$2"

    log "Terminating any prior instance..."
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

    # Uninstall before installing so a rerun starts unauthenticated. The client
    # persists its session (JWT) in an on-disk SQLite store inside the app
    # container; `simctl install` alone preserves that container, so without the
    # uninstall a second run restores the session and AuthGateView skips the
    # login screen this scenario drives. Uninstalling clears the container.
    log "Uninstalling any prior install (clears persisted auth so the login screen shows)..."
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    log "Installing $app_path..."
    xcrun simctl install "$udid" "$app_path"

    start_idb_companion "$udid" || { fail "could not start idb companion"; return 1; }

    # Launch with the Debug Inspector disabled. In a Debug build it starts a
    # Bonjour listener, which triggers the first-launch iOS Local Network
    # permission alert on a clean simulator — a system alert that would cover
    # the login form before the scenario can reach it. ui_signin drives the UI
    # directly and doesn't need the inspector. `SIMCTL_CHILD_<VAR>` passes VAR
    # into the launched app's environment; the app reads PRIMITIVE_DEBUG_INSPECTOR.
    log "Launching $BUNDLE_ID (debug inspector disabled)..."
    SIMCTL_CHILD_PRIMITIVE_DEBUG_INSPECTOR=0 \
        xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null

    # 1. Login screen — the email field renders.
    if ! idb_wait_id "primitive.login.emailField" 30; then
        fail "login email field did not render"; dump_ui_state "$udid" login; return 1
    fi
    log "Typing test email..."
    idb_tap_id "primitive.login.emailField" || { fail "could not tap email field"; dump_ui_state "$udid" email; return 1; }
    idb_cmd ui text "$TEST_EMAIL"
    idb_tap_id "primitive.login.emailSubmit" || { fail "could not tap email submit"; dump_ui_state "$udid" submit; return 1; }

    # 2. OTP screen — enter the fixed bypass code.
    if ! idb_wait_id "primitive.login.otpField" 30; then
        fail "OTP entry did not appear (check the whitelist and otpEnabled)"; dump_ui_state "$udid" otp; return 1
    fi
    log "Entering OTP bypass code..."
    idb_tap_id "primitive.login.otpField" || { fail "could not tap OTP field"; dump_ui_state "$udid" otp-tap; return 1; }
    idb_cmd ui text "000000"
    idb_tap_id "primitive.login.otpVerify" || { fail "could not tap verify"; dump_ui_state "$udid" verify; return 1; }

    # 3. Passkey-enrollment sheet may appear after OTP sign-in — dismiss it.
    if idb_wait_id "primitive.passkey.notNow" 8; then
        log "Dismissing passkey-enrollment sheet..."
        idb_tap_id "primitive.passkey.notNow" || true
    fi

    # 4. Post-login screen renders.
    log "Waiting for post-login element '$SUCCESS_ID'..."
    if ! idb_wait_id "$SUCCESS_ID" 30; then
        fail "post-login element '$SUCCESS_ID' did not render after sign-in"
        dump_ui_state "$udid" postlogin
        return 1
    fi

    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    stop_idb_companion
    pass "ui_signin (signed in as $TEST_EMAIL, '$SUCCESS_ID' rendered)"
}

# ────────────────────────────────────────────────────────────────────────
# Runner
# ────────────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${AVAILABLE_SCENARIOS[@]}"
    exit 0
fi

selected=("${DEFAULT_SCENARIOS[@]}")
if [ $# -gt 0 ]; then
    selected=("$@")
fi

# Validate the selected names first. This has to happen before both the
# preflight loop and the boot/build: a typo would otherwise exit 0 under
# PRIMITIVE_SMOKE_PREFLIGHT_ONLY (nothing was checked, yet the run reports
# green), and on a normal run it would only be reported after a multi-minute
# build.
for s in "${selected[@]}"; do
    if ! declare -f "scenario_${s}" >/dev/null; then
        fail "Unknown scenario: $s (use --list to see available)"
        exit 1
    fi
done

# Fail-fast preflight: for each selected scenario that declares a
# `preflight_<name>`, run it BEFORE the slow boot/build so a missing
# prerequisite (idb, test email, server settings) reports immediately
# rather than after a multi-minute build.
for s in "${selected[@]}"; do
    pf="preflight_${s}"
    if declare -f "$pf" >/dev/null; then
        log "Preflight: $s"
        if ! "$pf"; then
            log "Preflight failed for $s — aborting before build."
            exit 1
        fi
    fi
done

# Check prerequisites and stop, without the multi-minute boot/build. Handy for
# confirming a machine is set up for ui_signin.
if [ -n "${PRIMITIVE_SMOKE_PREFLIGHT_ONLY:-}" ]; then
    log "Preflight only (PRIMITIVE_SMOKE_PREFLIGHT_ONLY set) — skipping boot/build."
    exit 0
fi

log "Booting simulator..."
UDID=$(boot_simulator)
log "Using simulator: $UDID"

# Not a command substitution: `set -e` has to reach every command the build
# runs, so a failed codegen/pin-sync/xcodebuild stops the run here rather than
# falling through to install a partial bundle (#2582).
APP_PATH=""
build_for_simulator "$UDID"
log "Built app: $APP_PATH"

failures=0
for s in "${selected[@]}"; do
    # Names were validated above, before the preflight loop.
    fn="scenario_${s}"
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
