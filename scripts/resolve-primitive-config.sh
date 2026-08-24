#!/bin/bash
# Generate primitive.json from the selected Primitive environment (#2873).
#
# `primitive.json` is a BUILD PRODUCT, not a tracked file. The backend URL and
# app ID are typed once, in `.primitive/config.json`, and this script writes
# the selected environment's values into the flat shape
# `PrimitiveCredentials.swift` already parses:
#
#   { "primitiveEnv": "...", "appId": "...", "appName": "...", "serverUrl": "..." }
#
# The loader derives the WebSocket URL from serverUrl by scheme swap and
# ignores keys it doesn't know, so the `_generated` marker is harmless.
#
# Which environment (the same order the CLI and the Vue plugin apply):
#   1. --primitive-env <name>
#   2. PRIMITIVE_ENV
#   3. .primitive/local.json      (this machine's `primitive env use`)
#   4. "defaultEnvironment"       (the committed team default)
#   5. the sole environment, if there is exactly one
#
# ── why bash and not the CLI ─────────────────────────────────────────────────
# This runs on Xcode's pre-build path, including Archive and CI. Depending on
# a node binary being installed and on PATH there is a fragility we don't want
# in every scaffolded app. The port is pinned to the CLI's own resolver by a
# parity test (cli/tests/unit/swift-resolve-primitive-config.test.ts) that runs
# both over the same fixtures.
#
# ── the Xcode sandbox ────────────────────────────────────────────────────────
# Xcode's user-script sandbox permits a phase to read the files it declared as
# inputs and write the ones it declared as outputs — nothing else. project.yml
# declares $(SRCROOT)/.primitive/config.json, $(SRCROOT)/.primitive/local.json
# and $(SRCROOT)/primitive.json, so inside that context this script reads ONLY
# those and deliberately ignores PRIMITIVE_PROJECT_CONFIG (whose target is by
# definition undeclared). The shipped template never sets
# ENABLE_USER_SCRIPT_SANDBOXING.
#
# Usage:
#   bash scripts/resolve-primitive-config.sh [--primitive-env <name>]
#
# stdout stays EMPTY — progress and the resolved tuple go to stderr, because
# callers (regenerate-project.sh) capture stdout.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIMITIVE_ENV_FLAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --primitive-env)
            PRIMITIVE_ENV_FLAG="${2:-}"
            shift 2
            ;;
        --primitive-env=*)
            PRIMITIVE_ENV_FLAG="${1#--primitive-env=}"
            shift
            ;;
        *)
            echo "resolve-primitive-config.sh: unknown argument: $1" >&2
            echo "Usage: bash scripts/resolve-primitive-config.sh [--primitive-env <name>]" >&2
            exit 2
            ;;
    esac
done

fail() {
    echo "[primitive-config] error-kind: $1" >&2
    shift
    for line in "$@"; do
        echo "[primitive-config] $line" >&2
    done
    exit 1
}

# Xcode sets these; a shell invocation does not.
IN_XCODE=0
if [ -n "${SRCROOT:-}" ] && { [ -n "${BUILT_PRODUCTS_DIR:-}" ] || [ -n "${XCODE_VERSION_ACTUAL:-}" ]; }; then
    IN_XCODE=1
    APP_ROOT="$SRCROOT"
fi

OUTPUT="$APP_ROOT/primitive.json"

# ── locate .primitive/config.json ────────────────────────────────────────────
CONFIG_PATH=""
if [ "$IN_XCODE" = "1" ]; then
    # Declared inputs only. PRIMITIVE_PROJECT_CONFIG is deliberately not read.
    if [ -f "$APP_ROOT/.primitive/config.json" ]; then
        CONFIG_PATH="$APP_ROOT/.primitive/config.json"
    elif [ -f "$OUTPUT" ]; then
        # This is how a repo gate builds the template tree: the config-less
        # tree already had primitive.json generated (unsandboxed) by
        # regenerate-project.sh from a fixture. Reaching for that fixture here
        # would be an undeclared read.
        echo "[primitive-config] No .primitive/config.json under \$SRCROOT; keeping the" >&2
        echo "[primitive-config] pre-generated primitive.json. Skipping resolution." >&2
        exit 0
    else
        fail "missing-config" \
            "No .primitive/config.json under \$SRCROOT and no pre-generated primitive.json." \
            "Run 'primitive init' in this project, or generate the file first:" \
            "  bash scripts/resolve-primitive-config.sh"
    fi
elif [ -n "${PRIMITIVE_PROJECT_CONFIG:-}" ]; then
    if [ -f "$PRIMITIVE_PROJECT_CONFIG" ]; then
        CONFIG_PATH="$PRIMITIVE_PROJECT_CONFIG"
    else
        fail "missing-config" \
            "PRIMITIVE_PROJECT_CONFIG points at $PRIMITIVE_PROJECT_CONFIG, which does not exist."
    fi
else
    dir="$APP_ROOT"
    while :; do
        if [ -f "$dir/.primitive/config.json" ]; then
            CONFIG_PATH="$dir/.primitive/config.json"
            break
        fi
        parent="$(dirname "$dir")"
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done
    if [ -z "$CONFIG_PATH" ]; then
        fail "missing-config" \
            "No .primitive/config.json in $APP_ROOT or any parent directory." \
            "It is the single source of truth for the backend URL and app ID." \
            "Run 'primitive init' to create one, or 'primitive env add <name> --api-url ... --app-id ...'."
    fi
fi

LOCAL_PATH="$(dirname "$CONFIG_PATH")/local.json"

if ! command -v python3 >/dev/null 2>&1; then
    fail "missing-config" "python3 is required to read .primitive/config.json."
fi

# ── resolve and write ────────────────────────────────────────────────────────
# The JSON work happens in python3 (present on every macOS with the developer
# tools); the shell above only decides WHICH files it may look at.
# NOTE: the heredoc is deliberately NOT inside a `$(...)` capture — bash 3.2,
# which is what /bin/bash still is on macOS, mis-parses that combination. The
# python below therefore does its own reporting to stderr rather than handing a
# line back to the shell.
PRIMITIVE_CONFIG_PATH="$CONFIG_PATH" \
PRIMITIVE_LOCAL_PATH="$LOCAL_PATH" \
PRIMITIVE_OUTPUT_PATH="$OUTPUT" \
PRIMITIVE_ENV_FLAG="$PRIMITIVE_ENV_FLAG" \
PRIMITIVE_ENV_VAR="${PRIMITIVE_ENV:-}" \
python3 - <<'PYTHON'
import json
import os
import sys

CONFIG_VERSION = 1

config_path = os.environ["PRIMITIVE_CONFIG_PATH"]
local_path = os.environ["PRIMITIVE_LOCAL_PATH"]
output_path = os.environ["PRIMITIVE_OUTPUT_PATH"]
flag = os.environ.get("PRIMITIVE_ENV_FLAG") or ""
env_var = os.environ.get("PRIMITIVE_ENV_VAR") or ""


def fail(kind, *lines):
    print("error-kind: %s" % kind, file=sys.stderr)
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


try:
    with open(config_path, "r") as handle:
        config = json.load(handle)
except ValueError as err:
    fail("malformed-config", "Failed to parse %s: %s" % (config_path, err))
except OSError as err:
    fail("malformed-config", "Failed to read %s: %s" % (config_path, err))

if not isinstance(config, dict):
    fail("malformed-config", "%s must contain a JSON object at the top level." % config_path)

version = config.get("version")
if not isinstance(version, int) or isinstance(version, bool):
    fail("malformed-config", '%s is missing required integer field "version".' % config_path)
if version != CONFIG_VERSION:
    fail(
        "unsupported-version",
        "%s has version %s, but this script understands version %d."
        % (config_path, version, CONFIG_VERSION),
        "Upgrade the Primitive CLI and this template together.",
    )

environments = config.get("environments")
if not isinstance(environments, dict):
    fail("malformed-config", '%s is missing required "environments" object.' % config_path)

for name, entry in environments.items():
    if not isinstance(entry, dict):
        fail("malformed-config", 'Environment "%s" must be an object in %s.' % (name, config_path))
    api_url = entry.get("apiUrl")
    if not isinstance(api_url, str) or not api_url:
        fail(
            "malformed-config",
            'Environment "%s" must have a non-empty "apiUrl" string in %s.' % (name, config_path),
        )

# This machine's selection, if any.
local_selection = None
if os.path.exists(local_path):
    try:
        with open(local_path, "r") as handle:
            local = json.load(handle)
    except ValueError as err:
        fail(
            "corrupt-local-state",
            "%s is unreadable: %s." % (local_path, err),
            "Delete the file or re-run 'primitive env use <name>'.",
        )
    if not isinstance(local, dict):
        fail(
            "corrupt-local-state",
            "%s is unreadable: expected a JSON object." % local_path,
            "Delete the file or re-run 'primitive env use <name>'.",
        )
    selected = local.get("selectedEnvironment")
    if selected is not None and not isinstance(selected, str):
        fail(
            "corrupt-local-state",
            '%s is unreadable: "selectedEnvironment" must be a string.' % local_path,
            "Delete the file or re-run 'primitive env use <name>'.",
        )
    local_selection = selected or None

available = sorted(environments.keys())
listing = ", ".join(available) if available else "(none)"


def require_known(name, origin):
    if name not in environments:
        fail(
            "unknown-environment",
            'Environment "%s" is not defined in %s (selected %s). Available: %s'
            % (name, config_path, origin, listing),
        )
    return name


default_environment = config.get("defaultEnvironment") or None

if flag:
    chosen = require_known(flag, "explicitly")
    source = "explicit"
elif env_var:
    chosen = require_known(env_var, "via PRIMITIVE_ENV")
    source = "env-var"
elif local_selection:
    chosen = require_known(local_selection, "in .primitive/local.json")
    source = "local"
elif default_environment:
    chosen = require_known(default_environment, 'as "defaultEnvironment"')
    source = "default"
elif len(available) == 1:
    chosen = available[0]
    source = "sole"
elif not available:
    fail(
        "no-selection",
        "%s has no environments defined. Run 'primitive env add <name>' or 'primitive init'."
        % config_path,
    )
else:
    fail(
        "no-selection",
        "No environment selected. Run 'primitive env use <name>', set "
        '"defaultEnvironment" in %s, or export PRIMITIVE_ENV. Available: %s'
        % (config_path, listing),
    )

entry = environments[chosen]
api_url = entry["apiUrl"].rstrip("/")
# Typed, not merely present — matching the CLI resolver core, which reads a
# non-string "appId"/"appName" as absent rather than writing it into the app's
# runtime config. Without this a numeric or object appId would reach
# PrimitiveCredentials as a JSON value it cannot use.
app_id = entry.get("appId")
if not isinstance(app_id, str):
    app_id = None
app_name = entry.get("appName")
if not isinstance(app_name, str):
    app_name = None

if not app_id:
    fail(
        "missing-app-id",
        'Environment "%s" in %s has no "appId", and the app cannot start without one.'
        % (chosen, config_path),
        "Add it with: primitive env add %s --api-url %s --app-id <id>" % (chosen, api_url),
    )

document = {
    "_generated": "by scripts/resolve-primitive-config.sh — do not edit",
    "primitiveEnv": chosen,
    "appId": app_id,
    "serverUrl": api_url,
}
if app_name:
    document["appName"] = app_name

with open(output_path, "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")

# Every build logs the resolved tuple — a build that cannot be traced back to
# an environment is how a stale bundle goes unnoticed. stderr, so stdout stays
# empty for callers that capture it.
report = [
    "[primitive-config] Primitive environment: %s (selected: %s)" % (chosen, source),
    "[primitive-config]   apiUrl:  %s" % api_url,
    "[primitive-config]   appId:   %s" % app_id,
    "[primitive-config]   appName: %s" % (app_name or "(unset)"),
    "[primitive-config]   config:  %s" % config_path,
    "[primitive-config]   wrote:   %s" % output_path,
]
print("\n".join(report), file=sys.stderr)
PYTHON
