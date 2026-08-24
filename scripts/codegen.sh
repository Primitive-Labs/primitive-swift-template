#!/bin/bash
# Regenerate every piece of generated Swift this app has: the model types and
# the workflow factories. ONE entry point, the way the Vue template funnels
# `js-bao-codegen-v2` + `primitive workflows codegen` through a single `pnpm
# codegen` that `dev`, `build` and `test` all depend on.
#
# Why an entry point rather than two calls per build script: the two codegens
# fire on different paths and that is exactly how the workflow half went
# missing (#2895). `swift build` runs `JsBaoCodegenPlugin` for the models, so
# the SwiftPM path was covered; the Xcode target compiles its own source list
# from `.pbxproj` and never runs the plugin, so `run-ios.sh` called the model
# codegen by hand. Nothing anywhere called `primitive workflows codegen`, and
# because the factories are COMMITTED every build kept compiling whatever was
# in the tree — stale factories against a changed schema or an upgraded CLI
# produced no error at all. With one script, a build path that regenerates
# models cannot skip the workflows.
#
# Usage:
#   bash scripts/codegen.sh            regenerate models + workflow factories
#   bash scripts/codegen.sh --check    fail if the committed workflow factories
#                                      are out of date; writes nothing
#
# `--check` is the pre-commit / CI gate. It reads the local workflow TOMLs
# only — no network, no login, no toolchain — so it belongs in an offline
# hook. It covers the workflow factories alone: the model output is gitignored
# and rebuilt by every build, so it has no committed copy that can drift.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=false
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=true; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--check]" >&2
            exit 1 ;;
    esac
done

APP_SOURCES="Sources/PrimitiveAppTemplate"
WORKFLOW_GEN_DIR="$APP_SOURCES/Workflows/Generated"

# ────────────────────────────────────────────────────────────────────────────
# Models
# ────────────────────────────────────────────────────────────────────────────
# Emitted into the source tree (not just the SPM plugin work dir) so SourceKit
# — Xcode and VS Code both read the tree, not the build graph — can resolve the
# generated types, and so xcodegen scans them into the .pbxproj.
#
# Skipped under `--check`: the gate must not write, and the model output is
# gitignored anyway, so there is nothing here for a commit to have missed.
#
# Delegated to `scripts/generate-models.sh` rather than invoking the codegen
# tool here, so this path and the Xcode target's pre-build phase (#2886) share
# one implementation — including clearing the iOS SDK environment Xcode
# exports, and finding the app directory from wherever the schema actually is
# rather than assuming the template's own name.
#
# `--verify-project` is deliberately off: it fails when the .xcodeproj does not
# list a generated file yet, and every caller of this script regenerates the
# project right after. The pre-build phase, which cannot, passes it.
if [ "$CHECK" = false ]; then
    bash scripts/generate-models.sh
fi

# ────────────────────────────────────────────────────────────────────────────
# Workflow factories
# ────────────────────────────────────────────────────────────────────────────
# Only when this app has synced workflows: a freshly scaffolded app has no
# `.primitive/sync/<env>/<app>/workflows/*.toml` at all, and `primitive
# workflows codegen` exits non-zero with "No workflows/*.toml files found" —
# which must not fail a build that has nothing to generate. Same guard shape
# the Vue template's `codegen` script uses.
if ls .primitive/sync/*/*/workflows/*.toml >/dev/null 2>&1; then
    # The CLI scaffolded this app, so it is normally on PATH. Say what to
    # install if it isn't, rather than letting the build die on a bare
    # "command not found".
    if ! command -v primitive >/dev/null 2>&1; then
        echo "Error: this app has synced workflows under .primitive/sync/, but the \`primitive\` CLI is not on PATH." >&2
        echo "  Install it with: pnpm add -g primitive-admin   (or: npm install -g primitive-admin)" >&2
        exit 1
    fi

    if [ "$CHECK" = true ]; then
        # Byte-for-byte against the CLI's own emission, so a schema edit AND a
        # CLI upgrade that changes the emitted API surface both fail here.
        echo "Checking workflow factories are up to date..."
        primitive workflows codegen --lang swift -o "$WORKFLOW_GEN_DIR" --check
    else
        echo "Running primitive workflows codegen..."
        mkdir -p "$WORKFLOW_GEN_DIR"
        primitive workflows codegen --lang swift -o "$WORKFLOW_GEN_DIR"
    fi
fi
