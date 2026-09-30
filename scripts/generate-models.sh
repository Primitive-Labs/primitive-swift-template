#!/bin/bash
# Regenerate Models/Generated/*.swift from Models/models.toml.
#
# `swift build` runs the codegen itself through the SwiftPM
# `JsBaoCodegenPlugin`. The Xcode app target compiles its own source list out
# of `.pbxproj`, so the plugin never fires there — this script is what the
# target's "Generate models from models.toml" pre-build phase runs, and what
# `run-ios.sh` runs before it regenerates the project (#2886).
#
# Before this was a build phase, codegen on the Xcode path lived in
# `run-ios.sh` alone: entering through Xcode's Run button or a bare
# `xcodebuild` (including from CI) compiled the PREVIOUS structs, with nothing
# naming `models.toml` — the schema on disk and the schema compiled in
# silently diverged.
#
# Usage:
#   bash scripts/generate-models.sh [--verify-project]
#
# --print-schema resolves the schema and the app's source directory, prints them
# on two lines and generates nothing. `scripts/codegen.sh` uses it to name the
# schema in the build phase's declared input list (#3078) rather than repeating
# the resolution and letting the two drift.
#
# --verify-project additionally fails when the Xcode source list and the
# emitted files disagree, in either direction. Codegen can refresh a CHANGED
# model in place, but ADDING one emits a file the `.pbxproj` does not compile,
# and REMOVING one sweeps a file the `.pbxproj` still compiles; only `xcodegen
# generate` moves that list. Inside a build phase there is no regenerating the
# project we are already building, so the build stops with the fix rather than
# compiling an app quietly missing the type (added) or dying on a "build input
# file cannot be found" that names a path and not the schema (removed). Call
# sites that regenerate the project right after (`run-ios.sh`) leave the flag
# off.
#
# The app root is resolved from this script's own path, not the caller's
# working directory: Xcode runs build phases from wherever it likes.
#
# Progress goes to stderr, so a caller capturing stdout gets nothing from here.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERIFY_PROJECT=false
PRINT_SCHEMA=false
while [ $# -gt 0 ]; do
    case "$1" in
        --verify-project) VERIFY_PROJECT=true; shift ;;
        --print-schema) PRINT_SCHEMA=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# The app's source directory is whichever one holds the schema, so a renamed
# app (`primitive init` scaffolds under your own name) needs no edit here.
#
# A `bao-codegen.json` beside the app's sources names a schema OUTSIDE the
# target and replaces the scan — that is how one Primitive app with several
# clients keeps a single `models.toml` at the repository root, shared with a
# web client, without a copy or a symlink. Same file, same key, same resolution
# the SwiftPM plugin uses (`{"input": "../../../models/models.toml"}`, resolved
# against the app's source directory).
APP_SOURCES=""
SCHEMA_TOML=""
for candidate in Sources/*/bao-codegen.json; do
    [ -f "$candidate" ] || continue
    APP_SOURCES="$(dirname "$candidate")"
    CONFIGURED_INPUT="$(sed -n 's/.*"input"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$candidate" | head -1)"
    if [ -z "$CONFIGURED_INPUT" ]; then
        echo "error: $candidate has no \"input\" — remove the file to scan the target's own sources." >&2
        exit 1
    fi
    case "$CONFIGURED_INPUT" in
        /*) SCHEMA_TOML="$CONFIGURED_INPUT" ;;
        *)  SCHEMA_TOML="$APP_SOURCES/$CONFIGURED_INPUT" ;;
    esac
    if [ ! -f "$SCHEMA_TOML" ]; then
        echo "error: $candidate names $CONFIGURED_INPUT, which does not exist." >&2
        exit 1
    fi
    break
done

if [ -z "$SCHEMA_TOML" ]; then
    for candidate in Sources/*/Models/models.toml; do
        [ -f "$candidate" ] || continue
        SCHEMA_TOML="$candidate"
        APP_SOURCES="$(dirname "$(dirname "$candidate")")"
        break
    done
fi
if [ -z "$SCHEMA_TOML" ]; then
    echo "error: no models.toml found under Sources/<App>/Models/ (and no Sources/<App>/bao-codegen.json naming one) — codegen has no schema to read." >&2
    exit 1
fi
# Always the app's own directory: the generated types belong to this target
# even when the schema they come from lives outside it.
GEN_DIR="$APP_SOURCES/Models/Generated"

if [ "$PRINT_SCHEMA" = true ]; then
    echo "$SCHEMA_TOML"
    echo "$APP_SOURCES"
    exit 0
fi

mkdir -p "$GEN_DIR"

# Xcode exports the target's SDK into every script phase. `swift run` builds
# the codegen tool for the *host*, so inheriting the iOS simulator SDK makes
# it fail to build (or, worse, build something that cannot run here).
unset SDKROOT PLATFORM_NAME MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET

echo "Running swift-bao-codegen..." >&2
swift run --package-path . swift-bao-codegen \
    --input  "$SCHEMA_TOML" \
    --output "$GEN_DIR" >&2

if [ "$VERIFY_PROJECT" = true ]; then
    # The check itself lives in its own script (#3078): `scripts/codegen.sh`
    # runs it across all three generated directories at once, after every
    # generator has emitted, so one class's project mismatch cannot stop
    # another class from regenerating. This flag keeps working for a caller
    # that wants the model half alone.
    bash scripts/verify-generated-project.sh --label "$SCHEMA_TOML" "$GEN_DIR"
fi

# The phase declares this stamp as its output file, so Xcode skips the whole
# phase while models.toml is untouched. Writing it last keeps a failed codegen
# from marking the phase up to date.
if [ -n "${DERIVED_FILE_DIR:-}" ]; then
    mkdir -p "$DERIVED_FILE_DIR"
    touch "$DERIVED_FILE_DIR/models-codegen.stamp"
fi
