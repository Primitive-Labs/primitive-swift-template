#!/bin/bash
# Regenerate every piece of generated Swift this app has: the model types, the
# workflow factories and the database types. ONE entry point, the way the Vue
# template funnels `js-bao-codegen-v2` + `primitive databases codegen` +
# `primitive workflows codegen` through a single `pnpm codegen` that `dev`,
# `build` and `test` all depend on.
#
# Why an entry point rather than a call per generator per build script: the
# codegens fire on different paths and that is exactly how the workflow half
# went missing (#2895). `swift build` runs `JsBaoCodegenPlugin` for the models,
# so the SwiftPM path was covered; the Xcode target compiles its own source
# list from `.pbxproj` and never runs the plugin, so `run-ios.sh` called the
# model codegen by hand. Nothing anywhere called `primitive workflows codegen`,
# and because the factories are COMMITTED every build kept compiling whatever
# was in the tree — stale factories against a changed schema or an upgraded CLI
# produced no error at all. With one script, a build path that regenerates
# models cannot skip the rest. The database types (#2911) are the same shape:
# committed output, no build that rewrites them.
#
# Usage:
#   bash scripts/codegen.sh            regenerate models + workflow factories +
#                                      database types
#   bash scripts/codegen.sh --check    fail if the committed workflow factories
#                                      or database types are out of date;
#                                      writes nothing
#
# `--check` is the pre-commit / CI / pre-archive gate. It reads the local
# workflow and database-type TOMLs only — no network, no login, no toolchain —
# so it belongs in an offline hook. It covers the committed output alone: the
# model output is gitignored and rebuilt by every build, so it has no committed
# copy that can drift.
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
DATABASE_GEN_DIR="$APP_SOURCES/Databases/Generated"

# Both CLI-driven halves need the same executable, and either one alone is
# enough to need it. The CLI scaffolded this app, so it is normally on PATH;
# say what to install if it isn't, rather than letting the build die on a bare
# "command not found".
require_cli() {
    if ! command -v primitive >/dev/null 2>&1; then
        echo "Error: this app has synced $1 under .primitive/sync/, but the \`primitive\` CLI is not on PATH." >&2
        echo "  Install it with: pnpm add -g primitive-admin   (or: npm install -g primitive-admin)" >&2
        exit 1
    fi
}

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
# `<project root>/.primitive/sync/<env>/<app>/workflows/*.toml` at all, and
# `primitive workflows codegen` exits non-zero with "No workflows/*.toml files
# found" — which must not fail a build that has nothing to generate. Same guard
# shape the Vue template's `codegen` script uses.
#
# The sync tree sits beside `.primitive/config.json`, which is NOT always this
# directory: one Primitive app can have several clients (this one and a web
# client in a sibling directory), and then the project config and its sync
# export live at the repo root. So walk up for it, the way git finds `.git` and
# the way the CLI resolves the project — a standalone app's nearest ancestor is
# itself, which is the old behavior exactly.
PROJECT_ROOT="$(pwd)"
dir="$PROJECT_ROOT"
while :; do
    if [ -f "$dir/.primitive/config.json" ]; then
        PROJECT_ROOT="$dir"
        break
    fi
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
done

if ls "$PROJECT_ROOT"/.primitive/sync/*/*/workflows/*.toml >/dev/null 2>&1; then
    require_cli "workflows"

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

# ────────────────────────────────────────────────────────────────────────────
# Database types
# ────────────────────────────────────────────────────────────────────────────
# Record structs, per-operation params/result types and the typed ops factory
# for each synced database type. Committed, like the workflow factories, so the
# same silent rot applies: nothing regenerates them and nothing fails when the
# schema they were emitted from has moved on (#2911).
#
# Guarded exactly like the workflow half: with no synced
# `.primitive/sync/<env>/<app>/database-type-configs/*.toml`, `primitive
# databases codegen` exits non-zero with "No database-type-configs/*.toml files
# found", which must not fail a build that has nothing to generate.
if ls "$PROJECT_ROOT"/.primitive/sync/*/*/database-type-configs/*.toml >/dev/null 2>&1; then
    require_cli "database types"

    if [ "$CHECK" = true ]; then
        echo "Checking database types are up to date..."
        primitive databases codegen --lang swift -o "$DATABASE_GEN_DIR" --check
    else
        echo "Running primitive databases codegen..."
        mkdir -p "$DATABASE_GEN_DIR"
        primitive databases codegen --lang swift -o "$DATABASE_GEN_DIR"
    fi
fi
