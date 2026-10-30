#!/bin/bash
# Run the XCUITest suite (UITests/) on this app's dedicated UI simulator.
#
#   export PRIMITIVE_TEST_EMAIL="you+primitivetest-ios-ui@example.com"
#   ./ui-test.sh                              # every UI test
#   ./ui-test.sh --primitive-env prod         # another Primitive environment
#   ./ui-test.sh -only-testing:PrimitiveAppTemplateUITests/LaunchSmokeUITests
#                                             # anything else goes to xcodebuild
#
# The tests drive the real app against the real backend: they sign in as
# PRIMITIVE_TEST_EMAIL with the test-account code, so that address needs the
# same one-time setup as ./test.sh ("Running the tests" in docs/README.md).
# Its first sign-in creates the account, which is what puts the onboarding
# screens in front of the test; use an address that has never signed in.
#
# PRIMITIVE_TEST_INVITE_TOKEN, when set, is a pending invitation's token: the
# invite test opens `<scheme>://invite/accept?inviteToken=<token>` in the app.
# Unset, that test is skipped.
#
# The simulator is dedicated to this app (`UI — <bundle id>`), created on first
# use and reused after. Override the name with PRIMITIVE_UI_SIM and the device
# type it is created from with PRIMITIVE_UI_SIM_BASE. The app is uninstalled
# before each run, so every run starts signed out.
#
# A failed test's screenshot lands in the run's result bundle,
# build/ui/UITests-<timestamp>.xcresult (open it in Xcode).
#
# stdout carries only xcodebuild's output and the exit status is xcodebuild's
# (or, when it has to be stopped, the one "The run" below gives); this
# script's own lines, the resolver's and codegen's go to stderr.
#
# On a machine that cannot run the suite (no iOS simulator runtime, or no
# xcodegen) it changes nothing and exits 77 after a `[ui-test] SKIP: <reason>`
# line on stderr, so a caller can tell "not run here" from a failure.
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="PrimitiveAppTemplate.xcodeproj"
# The UI suite's own iOS scheme (project.yml says why it is not the app's).
SCHEME="PrimitiveAppTemplateUITests"
UI_TARGET="PrimitiveAppTemplateUITests"
# The exit status of a run this host cannot do (the usual "skipped" status).
SKIP_STATUS=77

log()  { printf '[ui-test] %s\n' "$*" >&2; }
fail() { printf '[ui-test] FAIL: %s\n' "$*" >&2; return 1; }

usage() {
    cat <<'USAGE'
Usage: ./ui-test.sh [--primitive-env <name>] [xcodebuild arguments...]

Runs the XCUITest suite on this app's dedicated simulator, signed in as
PRIMITIVE_TEST_EMAIL (a +primitivetest address the app whitelists and admits,
that has never signed in). One-time setup: "Running the tests" in
docs/README.md.
USAGE
}

# ────────────────────────────────────────────────────────────────────────────
# Arguments
# ────────────────────────────────────────────────────────────────────────────
# `--primitive-env <name>` overrides `primitive env use` for this run, exported
# as PRIMITIVE_ENV so the resolver and codegen see the same choice, and is not
# forwarded. Everything else goes to `xcodebuild test` after the defaults.
XCODEBUILD_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0 ;;
        --primitive-env)
            if [ -z "${2:-}" ]; then
                echo "--primitive-env requires an environment name" >&2
                exit 1
            fi
            export PRIMITIVE_ENV="$2"; shift 2 ;;
        --primitive-env=*)
            export PRIMITIVE_ENV="${1#--primitive-env=}"; shift ;;
        *) XCODEBUILD_ARGS+=("$1"); shift ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# The test account, before anything slow runs
# ────────────────────────────────────────────────────────────────────────────
if [ -z "${PRIMITIVE_TEST_EMAIL:-}" ] || [ -z "${PRIMITIVE_TEST_EMAIL//[[:space:]]/}" ]; then
    {
        echo "PRIMITIVE_TEST_EMAIL is not set: the UI tests sign in as that account."
        echo "Set it to a +primitivetest address the app whitelists and admits, e.g."
        echo "  export PRIMITIVE_TEST_EMAIL=\"you+primitivetest-ios-ui@example.com\""
        echo "One-time setup: \"Running the tests\" in docs/README.md."
    } >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# The app's identity
# ────────────────────────────────────────────────────────────────────────────
read_yml_value() {
    awk -v k="$1" 'BEGIN{FS=":"} $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
        sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2);
        gsub(/^"|"$/, "", $2); print $2; exit
    }' project.yml 2>/dev/null
}
BUNDLE_ID="$(read_yml_value PRODUCT_BUNDLE_IDENTIFIER)"
BUNDLE_ID="${BUNDLE_ID:-com.primitivelabs.PrimitiveAppTemplate}"

# The custom URL scheme `primitive init` stamped into Info-Partial.plist: the
# invite link the test opens has to be one this app is registered for.
URL_SCHEME="$(python3 -c '
import plistlib, sys
with open("Info-Partial.plist", "rb") as handle:
    plist = plistlib.load(handle)
for url_type in plist.get("CFBundleURLTypes", []):
    for scheme in url_type.get("CFBundleURLSchemes", []):
        print(scheme)
        sys.exit(0)
' 2>/dev/null || true)"
if [ -z "$URL_SCHEME" ]; then
    fail "Info-Partial.plist registers no URL scheme (CFBundleURLTypes → CFBundleURLSchemes)."
    exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# A host that can run the suite
# ────────────────────────────────────────────────────────────────────────────
# Without an iOS simulator runtime or xcodegen the suite cannot run here at all,
# which is not a test failure: say why on a SKIP line and exit SKIP_STATUS
# before anything is regenerated or booted.
skip() {
    printf '[ui-test] SKIP: %s\n' "$1" >&2
    exit "$SKIP_STATUS"
}

HAS_IOS_RUNTIME="$(xcrun simctl list runtimes -j 2>/dev/null | python3 -c '
import json, sys
runtimes = json.load(sys.stdin).get("runtimes", [])
print(any(r.get("platform") == "iOS" and r.get("isAvailable", True) for r in runtimes))
' 2>/dev/null || true)"
if [ "$HAS_IOS_RUNTIME" != "True" ]; then
    log "Install one with: xcodebuild -downloadPlatform iOS"
    skip "no iOS simulator runtime on this host"
fi
if ! command -v xcodegen >/dev/null 2>&1; then
    log "xcodegen is not installed, and the Xcode project is generated from project.yml."
    log "  Install it with: brew install xcodegen"
    skip "xcodegen not installed"
fi

# ────────────────────────────────────────────────────────────────────────────
# Project, then simulator
# ────────────────────────────────────────────────────────────────────────────
# Resolves primitive.json for the selected environment, runs codegen and
# regenerates the .xcodeproj; fails with install instructions when xcodegen is
# missing, before any simulator is touched.
bash scripts/regenerate-project.sh "$PROJECT"

# shellcheck source=scripts/simulator.sh
source "scripts/simulator.sh"
SIM_NAME="${PRIMITIVE_UI_SIM:-UI — ${BUNDLE_ID}}"
SIM_BASE_DEVICE="${PRIMITIVE_UI_SIM_BASE:-iPhone 17 Pro}"
UDID="$(boot_simulator "$SIM_NAME" "$SIM_BASE_DEVICE" PRIMITIVE_UI_SIM_BASE)" || exit 1

# A previous run's keychain session would skip the sign-in under test.
# Uninstalling an app that is not installed is not an error worth reporting.
log "Uninstalling $BUNDLE_ID from '$SIM_NAME' so the run starts signed out..."
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# ────────────────────────────────────────────────────────────────────────────
# The run
# ────────────────────────────────────────────────────────────────────────────
# xcodebuild hands a `TEST_RUNNER_<NAME>` variable in its own environment to
# the test runner as `<NAME>`; a build-setting argument of that name does not.
export TEST_RUNNER_PRIMITIVE_TEST_EMAIL="$PRIMITIVE_TEST_EMAIL"
if [ -n "${PRIMITIVE_TEST_INVITE_TOKEN:-}" ]; then
    export TEST_RUNNER_PRIMITIVE_TEST_INVITE_URL="${URL_SCHEME}://invite/accept?inviteToken=${PRIMITIVE_TEST_INVITE_TOKEN}"
else
    unset TEST_RUNNER_PRIMITIVE_TEST_INVITE_URL
fi

# The whole UI target unless the caller narrowed it: `-only-testing` values
# are a union, so the default would swallow a narrower one.
ONLY_TESTING=(-only-testing:"$UI_TARGET")
# No diagnostics collection unless the caller asks for it. A failing UI test
# ends the runner process, and for each such "unexpected exit" xcodebuild runs
# `simctl diagnose` on the simulator before it finishes the result bundle. That
# diagnose intermittently stalls, and xcodebuild waits for it, silent, up to its
# 600 s timeout (#4930). The failure screenshots and logs stay in the bundle.
DIAGNOSTICS=(-collect-test-diagnostics never)
for arg in ${XCODEBUILD_ARGS+"${XCODEBUILD_ARGS[@]}"}; do
    case "$arg" in
        -only-testing*) ONLY_TESTING=() ;;
        -collect-test-diagnostics) DIAGNOSTICS=() ;;
    esac
done

log "Running $UI_TARGET on '$SIM_NAME' ($UDID) as $PRIMITIVE_TEST_EMAIL..."

# xcodebuild runs under a watcher rather than being exec'd, so that a run that
# stalls anyway (the diagnose above, or the runner installed and no test ever
# started) ends in bounded time (#4930). The watcher copies xcodebuild's stdout
# through untouched and stops it, and every process it started, when:
#   - it has not exited PRIMITIVE_UI_EXIT_GRACE seconds (default 60) after its
#     verdict: `** TEST SUCCEEDED **` / `** TEST FAILED **`, or the summary of
#     the top-level suite. The exit status is then the verdict's (0 or 65, as
#     xcodebuild's own would have been);
#   - its stdout has been silent for PRIMITIVE_UI_STALL_TIMEOUT seconds
#     (default 300) before any verdict. Exit status 124.
# Otherwise the exit status is xcodebuild's. SIGINT/SIGTERM/SIGHUP reach it.
RESULT_BUNDLE="build/ui/UITests-$(date +%Y%m%d-%H%M%S).xcresult"
exec python3 - "${PRIMITIVE_UI_EXIT_GRACE:-60}" "${PRIMITIVE_UI_STALL_TIMEOUT:-300}" \
    xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    ${ONLY_TESTING+"${ONLY_TESTING[@]}"} \
    ${DIAGNOSTICS+"${DIAGNOSTICS[@]}"} \
    -derivedDataPath build/ui \
    -resultBundlePath "$RESULT_BUNDLE" \
    ${XCODEBUILD_ARGS+"${XCODEBUILD_ARGS[@]}"} <<'PY'
import os, re, selectors, signal, subprocess, sys, time

grace, stall, argv = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3:]

def log(message):
    sys.stderr.write("[ui-test] %s\n" % message)
    sys.stderr.flush()

VERDICT = re.compile(rb"^\*\* TEST (SUCCEEDED|FAILED) \*\*")
TOP_SUITE = re.compile(rb"^Test Suite '(All tests|Selected tests)' (passed|failed)")
SUMMARY = re.compile(rb"^\s*Executed \d+ tests?, with (\d+) failures?")
CASE_STARTED = re.compile(rb"^Test Case '.*' started\.")
CASE_FAILED = re.compile(rb"^Test Case '.*' failed")

child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)

def descendants(pid):
    # xcodebuild's children, such as `simctl diagnose`, run in process groups
    # of their own and outlive it, so they are found by parentage instead.
    table = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for row in table.splitlines():
        fields = row.split()
        if len(fields) == 2:
            children.setdefault(int(fields[1]), []).append(int(fields[0]))
    found, queue = [], [pid]
    while queue:
        for kid in children.get(queue.pop(), []):
            found.append(kid)
            queue.append(kid)
    return found

def stop():
    # TERM first so xcodebuild can close the result bundle; KILL if it will not.
    if child.poll() is None:
        others = descendants(child.pid)
        child.send_signal(signal.SIGTERM)
        try:
            child.wait(10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        for pid in others:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass

def forward(signum, _frame):
    stop()
    sys.exit(128 + signum)

for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, forward)

out = sys.stdout.buffer
selector = selectors.DefaultSelector()
selector.register(child.stdout, selectors.EVENT_READ)
pending = b""
verdict = None          # 0 or 65 once xcodebuild has said how the run went
verdict_at = None
final = False           # the verdict is xcodebuild's own `** TEST … **` line
failures = False        # a test failed in any of the runner's launches
top_suite_status = None
case_started = False
last_output = time.monotonic()
last_case = None

def scan(line):
    global verdict, verdict_at, final, failures, top_suite_status, case_started, last_case
    m = VERDICT.match(line)
    if m:
        verdict = 0 if m.group(1) == b"SUCCEEDED" else 65
        verdict_at = time.monotonic()
        final = True
        return
    m = TOP_SUITE.match(line)
    if m:
        top_suite_status = m.group(2)
        return
    m = SUMMARY.match(line)
    if m and top_suite_status is not None:
        # The runner exits after a failing test and xcodebuild relaunches it
        # for the rest, so this summary may be a last, empty launch's: the
        # verdict counts the failures of every launch.
        failures = failures or top_suite_status == b"failed" or int(m.group(1)) > 0
        if not final:
            verdict = 65 if failures else 0
            verdict_at = time.monotonic()
        top_suite_status = None
        return
    if CASE_FAILED.match(line):
        failures = True
        return
    if CASE_STARTED.match(line):
        case_started = True
        last_case = line.decode("utf-8", "replace").strip()
        # A retry or another iteration: the earlier summary was not the last.
        if not final:
            verdict = verdict_at = None

eof = False
while not eof:
    now = time.monotonic()
    if verdict is not None:
        wait = verdict_at + grace - now
    else:
        wait = last_output + stall - now
    if wait <= 0:
        if verdict is not None:
            log("xcodebuild has not exited %ds after the test verdict; stopping it (#4930). "
                "Exit status %d is the verdict's." % (grace, verdict))
            stop()
            sys.exit(verdict)
        where = ("after %s" % last_case) if case_started else "and no test case has started"
        log("FAIL: xcodebuild printed nothing for %ds %s; stopping it (#4930)." % (stall, where))
        stop()
        sys.exit(124)
    for _key, _mask in selector.select(timeout=min(wait, 1.0)):
        chunk = os.read(child.stdout.fileno(), 65536)
        if not chunk:
            eof = True
            break
        out.write(chunk)
        out.flush()
        last_output = time.monotonic()
        pending += chunk
        *lines, pending = pending.split(b"\n")
        for line in lines:
            scan(line)
if pending:
    scan(pending)

# stdout closed: xcodebuild is exiting (or has closed it and hangs anyway).
deadline = time.monotonic() + (grace if verdict is not None else stall)
while child.poll() is None and time.monotonic() < deadline:
    time.sleep(0.2)
if child.poll() is None:
    if verdict is not None:
        log("xcodebuild has not exited %ds after the test verdict; stopping it (#4930). "
            "Exit status %d is the verdict's." % (grace, verdict))
        stop()
        sys.exit(verdict)
    log("FAIL: xcodebuild closed its output but did not exit; stopping it (#4930).")
    stop()
    sys.exit(124)
code = child.returncode
sys.exit(128 - code if code < 0 else code)
PY
