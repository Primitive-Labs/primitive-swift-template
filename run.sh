#!/bin/bash
# Build and run the Primitive app template (macOS)
set -euo pipefail
cd "$(dirname "$0")"

# ────────────────────────────────────────────────────────────────────────────
# Which Primitive environment
# ────────────────────────────────────────────────────────────────────────────
# `--primitive-env <name>` overrides `primitive env use` for this run. It is
# exported as PRIMITIVE_ENV so every downstream step sees the same choice, and
# stripped from the arguments forwarded to the app.
APP_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --primitive-env)
            if [ -z "${2:-}" ]; then
                echo "--primitive-env requires an environment name" >&2
                exit 1
            fi
            export PRIMITIVE_ENV="$2"; shift 2 ;;
        --primitive-env=*)
            export PRIMITIVE_ENV="${1#--primitive-env=}"; shift ;;
        *) APP_ARGS+=("$1"); shift ;;
    esac
done

# primitive.json is generated from .primitive/config.json — the one place the
# backend URL and app ID are typed (#2873). build.sh copies it into the bundle;
# `swift run` reads it from the app root.
bash scripts/resolve-primitive-config.sh

# ────────────────────────────────────────────────────────────────────────────
# Codegen — mirror to source tree for SourceKit
# ────────────────────────────────────────────────────────────────────────────
# `swift run` below triggers `swift build`, which runs `JsBaoCodegenPlugin`
# automatically and emits the MODELS into the SPM plugin work dir — fine for
# the compiler. SourceKit (Xcode / VS Code) reads the *source tree* though, so
# without a checked-in `Models/Generated/<Type>.swift`, editor diagnostics
# can't find generated types and surface confusing errors like
# "No such module 'PrimitiveApp'" against companion `+Extensions.swift`
# files. And no build path regenerates the WORKFLOW factories at all. Both
# live in the shared entry point — see its header.
bash scripts/codegen.sh

swift run primitive-app-template ${APP_ARGS+"${APP_ARGS[@]}"}
