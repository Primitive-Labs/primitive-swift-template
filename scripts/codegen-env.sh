#!/bin/bash
# Which Primitive environment (and app slot) a codegen run belongs to.
#
# Prints two lines on stdout — the environment name, then the app id — and
# nothing at all when no single environment can be resolved. Always exits 0:
# "cannot tell" is an answer the caller acts on, not a failure.
#
# WHY this exists (#3078). `scripts/codegen.sh` guards each CLI-driven codegen
# on whether this app has that artifact class synced. The guard used to glob
# EVERY environment (`.primitive/sync/*/*/workflows/*.toml`) while the CLI it
# then invokes resolves exactly ONE and errors when that one's directory is
# empty. An app with workflows synced under `alpha` while `dev` is selected
# therefore invoked the CLI for `dev` and failed. That was survivable while
# codegen ran only on paths a developer chose; now it runs on every build path,
# including Xcode's Run button, so the guard has to ask the same question the
# CLI will.
#
# The selection order is the CLI's own, and the same one
# `scripts/resolve-primitive-config.sh` implements for `primitive.json`:
#
#   1. PRIMITIVE_ENV              (exported by --primitive-env, or by hand)
#   2. .primitive/local.json      (this machine's `primitive env use`)
#   3. "defaultEnvironment"       (the committed team default)
#   4. the sole environment       (when exactly one is defined)
#
# There is no `--env` step: a build script that takes `--primitive-env` exports
# PRIMITIVE_ENV, which is step 1.
#
# Usage:
#   bash scripts/codegen-env.sh <config.json> [<local.json>]
#
# The JSON work happens in python3, which this template already depends on for
# the same reason (resolve-primitive-config.sh).
set -euo pipefail

CONFIG_PATH="${1:-}"
LOCAL_PATH="${2:-}"

[ -n "$CONFIG_PATH" ] || exit 0
[ -f "$CONFIG_PATH" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

PRIMITIVE_CONFIG_PATH="$CONFIG_PATH" \
PRIMITIVE_LOCAL_PATH="$LOCAL_PATH" \
PRIMITIVE_ENV_VAR="${PRIMITIVE_ENV:-}" \
python3 - <<'PYTHON'
import json
import os
import sys


def load(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except Exception:
        return None
    return value if isinstance(value, dict) else None


config = load(os.environ["PRIMITIVE_CONFIG_PATH"])
if config is None:
    # An unreadable config is not this script's error to report: the resolve
    # step says so properly, with the path and the fix.
    sys.exit(0)

environments = config.get("environments")
if not isinstance(environments, dict):
    sys.exit(0)
environments = {
    name: entry for name, entry in environments.items() if isinstance(entry, dict)
}

env_var = os.environ.get("PRIMITIVE_ENV_VAR") or ""
local = load(os.environ.get("PRIMITIVE_LOCAL_PATH") or "") or {}
selected = local.get("selectedEnvironment")
local_selection = selected if isinstance(selected, str) and selected else None
default_environment = config.get("defaultEnvironment") or None

chosen = None
for candidate in (env_var, local_selection, default_environment):
    if candidate:
        # A selection naming an environment that is not defined is an error the
        # resolve step reports in full. Here it is simply not a resolution, so
        # the caller falls back to letting the CLI speak.
        chosen = candidate if candidate in environments else None
        break
else:
    if len(environments) == 1:
        chosen = next(iter(environments))

if not chosen:
    sys.exit(0)

app_id = environments[chosen].get("appId")
print(chosen)
# An environment with no usable appId still scopes the guard to that
# environment; the caller then accepts any app slot inside it.
print(app_id if isinstance(app_id, str) else "")
PYTHON
