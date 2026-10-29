#!/bin/bash
# Run the app's tests from the command line (macOS host, no simulator).
#
#   export PRIMITIVE_TEST_EMAIL="you+primitivetest-ios@example.com"
#   ./test.sh                          # every test
#   ./test.sh --filter ExampleTests    # anything else is passed to `swift test`
#   ./test.sh --primitive-env prod     # another Primitive environment
#
# The tests sign in as PRIMITIVE_TEST_EMAIL through the server's test-account
# bypass. That needs a one-time setup in the app (whitelist the base address,
# then invite the test address or make the app public): see "Running the
# tests" in docs/README.md.
#
# stdout carries only `swift test`'s output; this script's own lines, the
# resolver's and codegen's go to stderr.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
    cat <<'USAGE'
Usage: ./test.sh [--primitive-env <name>] [swift test arguments...]

Runs the app's tests with `swift test`, signed in as PRIMITIVE_TEST_EMAIL
(a +primitivetest address the app whitelists and admits). One-time setup:
"Running the tests" in docs/README.md.
USAGE
}

# ────────────────────────────────────────────────────────────────────────────
# Arguments
# ────────────────────────────────────────────────────────────────────────────
# `--primitive-env <name>` overrides `primitive env use` for this run, exported
# as PRIMITIVE_ENV so the resolver and codegen see the same choice, and is not
# forwarded. Everything else goes to `swift test` unchanged.
TEST_ARGS=()
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
        *) TEST_ARGS+=("$1"); shift ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# The test account
# ────────────────────────────────────────────────────────────────────────────
if [ -z "${PRIMITIVE_TEST_EMAIL:-}" ] || [ -z "${PRIMITIVE_TEST_EMAIL//[[:space:]]/}" ]; then
    {
        echo "PRIMITIVE_TEST_EMAIL is not set: the tests sign in as that account."
        echo "Set it to a +primitivetest address the app whitelists and admits, e.g."
        echo "  export PRIMITIVE_TEST_EMAIL=\"you+primitivetest-ios@example.com\""
        echo "One-time setup: \"Running the tests\" in docs/README.md."
    } >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# The app's identity, as the app itself resolves it
# ────────────────────────────────────────────────────────────────────────────
bash scripts/resolve-primitive-config.sh >&2
bash scripts/codegen.sh >&2

read_config() {
    python3 -c 'import json, sys; print(json.load(open("primitive.json")).get(sys.argv[1]) or "")' "$1"
}
APP_ID="$(read_config appId)"
API_URL="$(read_config serverUrl)"
case "$API_URL" in
    https://*) WS_URL="wss://${API_URL#https://}" ;;
    http://*) WS_URL="ws://${API_URL#http://}" ;;
    *) WS_URL="$API_URL" ;;
esac

# The names the web template's tests read. A value already exported by the
# caller wins, as it does for the Vite plugin, and is named once.
OVERRIDDEN=()
export_unless_set() {
    if [ -n "${!1:-}" ]; then
        OVERRIDDEN+=("$1")
    else
        export "$1=$2"
    fi
}
export_unless_set VITE_APP_ID "$APP_ID"
export_unless_set VITE_API_URL "$API_URL"
export_unless_set VITE_WS_URL "$WS_URL"
if [ ${#OVERRIDDEN[@]} -gt 0 ]; then
    echo "[test.sh] Overridden by the environment: ${OVERRIDDEN[*]}. Unset it to use primitive.json." >&2
fi

exec swift test ${TEST_ARGS+"${TEST_ARGS[@]}"}
