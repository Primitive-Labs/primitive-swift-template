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
# GENERATED CODE IS CODE (#3078). All three classes are committed, reviewed and
# tested like any other source, and this script runs on every build path — the
# app build, every Xcode entry point, the test run — so a schema change shows up
# as a working-tree diff the developer commits with the change. There is no
# drift gate any more: the `--check` mode this script used to carry, and the
# release-time refusal `archive.sh` built on it, are removed rather than
# relocated. Enforcement is the loop itself.
#
# Usage:
#   bash scripts/codegen.sh                    regenerate models + workflow
#                                              factories + database types
#   bash scripts/codegen.sh --verify-project   …and then fail if the committed
#                                              .xcodeproj does not compile
#                                              exactly what was emitted
#
# The order is generate-all-three, refresh the declared file lists, verify all
# three, stamp. Verification LAST is deliberate (#3078): a class whose project
# entry is missing must not stop another class from regenerating, and a failing
# check must still leave the regenerated output in the working tree — that diff
# is what the developer reviews and commits.
#
# Progress goes to stderr, so a caller capturing stdout gets nothing from here:
# `scripts/regenerate-project.sh` runs this script and is itself run inside a
# command substitution by `scripts/smoke-test.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

VERIFY_PROJECT=false
while [ $# -gt 0 ]; do
    case "$1" in
        --verify-project) VERIFY_PROJECT=true; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--verify-project]" >&2
            exit 1 ;;
    esac
done

APP_SOURCES="Sources/PrimitiveAppTemplate"
WORKFLOW_GEN_DIR="$APP_SOURCES/Workflows/Generated"
DATABASE_GEN_DIR="$APP_SOURCES/Databases/Generated"
MODELS_GEN_DIR="$APP_SOURCES/Models/Generated"

# The build phase's declared inputs and outputs. Committed, and rewritten by
# this script: the set of files a codegen reads and writes depends on the app's
# configuration, which no static declaration in `project.yml` can name. They lag
# one build behind by construction — Xcode reads them before it launches the
# phase — which is harmless here because the phase is always-run and
# regeneration is byte-stable, so a list only changes when the schema did.
INPUTS_LIST="scripts/codegen-inputs.xcfilelist"
OUTPUTS_LIST="scripts/codegen-outputs.xcfilelist"

# ────────────────────────────────────────────────────────────────────────────
# Finding the CLI
# ────────────────────────────────────────────────────────────────────────────
# This script runs from an Xcode pre-build phase now, on EVERY Xcode entry
# point including the Run button (#3078). Xcode's GUI build phases run with a
# minimal PATH that carries neither the `primitive` CLI nor node, so
# `command -v primitive` alone would fail every GUI build of an app with synced
# workflows or database types — telling the developer to install something they
# already have. So probe, the way `scripts/generate-models.sh` already reaches
# past the environment Xcode hands it.
#
# Order: an explicit PRIMITIVE_CLI, then an installed `primitive` (PATH first,
# then the well-known install locations), then `npx` running the pinned
# published package. Preferring the installed one keeps a developer's own
# version — including a locally built one — authoritative.
#
# Resolved lazily: an app that has synced neither class never needs any of it,
# on any path, and must not be told otherwise.
CLI_BIN=""
CLI_NPX_SPEC=""
CLI_EXEC_PATH=""

# The directories the probe searches when PATH comes up empty, most specific
# first: this developer's own installs (pnpm, volta, nvm, ~/.local/bin) before
# the machine-wide prefixes, because a user-level install is the more specific
# answer about which CLI THIS developer means. PATH still beats all of them.
#
# `PRIMITIVE_TOOLCHAIN_PATH` REPLACES this list — a colon-separated set of
# directories, for a machine whose toolchain lives somewhere this script does
# not know about (a managed install, a container image). It is the node-side
# counterpart of `PRIMITIVE_CLI`, and it exists so nobody has to edit Xcode's
# build environment to make a build work.
toolchain_dirs() {
    local dir
    if [ -n "${PRIMITIVE_TOOLCHAIN_PATH:-}" ]; then
        printf '%s\n' "$PRIMITIVE_TOOLCHAIN_PATH" | tr ':' '\n'
        return 0
    fi
    for dir in \
        "${PNPM_HOME:-}" \
        "$HOME/Library/pnpm" \
        "$HOME/.volta/bin" \
        "$HOME/.local/bin"
    do
        [ -n "$dir" ] && echo "$dir"
    done
    # nvm keeps one bin dir per installed node. Glob order is lexicographic, so
    # taking them in reverse prefers the highest-looking version — good enough
    # to pick a working node, and any of them can run npx.
    for dir in "$HOME"/.nvm/versions/node/*/bin; do
        [ -d "$dir" ] && echo "$dir"
    done | sort -r
    # The machine-wide prefixes last, for the reason above.
    echo /opt/homebrew/bin
    echo /usr/local/bin
}

probe_bin() {
    local name="$1"
    local dir

    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    # A while-read loop, not `for dir in $(…)`: an install path may contain a
    # space, and word splitting would break it into two directories that exist
    # nowhere.
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        if [ -x "$dir/$name" ]; then
            echo "$dir/$name"
            return 0
        fi
    done <<EOF
$(toolchain_dirs)
EOF
    return 1
}

resolve_cli() {
    [ -z "$CLI_BIN" ] || return 0

    if [ -n "${PRIMITIVE_CLI:-}" ]; then
        if [ ! -x "${PRIMITIVE_CLI}" ]; then
            echo "Error: PRIMITIVE_CLI points at ${PRIMITIVE_CLI}, which is not executable." >&2
            exit 1
        fi
        CLI_BIN="$PRIMITIVE_CLI"
        return 0
    fi

    CLI_BIN="$(probe_bin primitive || true)"
    [ -z "$CLI_BIN" ] || return 0

    # The npx fallback, so the phase works regardless of how (or whether) the
    # developer installed the CLI. The version is PINNED in a file this
    # template owns and `deploy-primitive --publish` bumps: a bare
    # `npx primitive-admin` resolves to whatever is latest, which would change
    # the committed emission with nothing in the repo saying so — the exact
    # un-reviewable change this issue exists to remove.
    local pin=""
    [ -f .primitive-cli-version ] && pin="$(tr -d '[:space:]' < .primitive-cli-version)"
    if [ -n "$pin" ]; then
        CLI_BIN="$(probe_bin npx || true)"
        if [ -n "$CLI_BIN" ]; then
            CLI_NPX_SPEC="primitive-admin@$pin"
            return 0
        fi
    fi

    echo "Error: this app has synced $1 under primitive/<env>/, but no \`primitive\` CLI could be found." >&2
    echo "  Install it with: pnpm add -g primitive-admin   (or: npm install -g primitive-admin)" >&2
    echo "  Or install node, so this build can run: npx -y primitive-admin@${pin:-<pin>}" >&2
    echo "  Or point PRIMITIVE_CLI at the executable." >&2
    exit 1
}

# Finding the executable is only half of it. Both the published CLI and `npx`
# are node scripts (`#!/usr/bin/env node`), and that shebang is resolved by the
# kernel through the PATH the CHILD gets — not by the absolute path we invoke
# them with. Under Xcode's minimal PATH a Homebrew/nvm/volta/pnpm CLI found by
# the probe would still die on `env: node: No such file or directory`, which is
# the very environment the probe exists for.
#
# So the child also gets the directories that make it runnable: the CLI's own
# first — the node beside an install is the node that install was made for —
# then wherever the probe finds `node`. Prepending, so a developer's own PATH
# still wins for everything else the child may shell out to. A CLI that is not
# node-backed (a compiled binary, a locally built wrapper) is unaffected.
cli_exec_path() {
    local dirs node_bin
    dirs="$(dirname "$CLI_BIN")"
    node_bin="$(probe_bin node || true)"
    [ -n "$node_bin" ] && dirs="$dirs:$(dirname "$node_bin")"
    printf '%s' "$dirs"
}

# One call shape for both, so the two halves below read the same either way.
run_cli() {
    [ -n "$CLI_EXEC_PATH" ] || CLI_EXEC_PATH="$(cli_exec_path)"
    if [ -n "$CLI_NPX_SPEC" ]; then
        PATH="$CLI_EXEC_PATH:$PATH" "$CLI_BIN" -y "$CLI_NPX_SPEC" "$@"
    else
        PATH="$CLI_EXEC_PATH:$PATH" "$CLI_BIN" "$@"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Which schema
# ────────────────────────────────────────────────────────────────────────────
# Two lines from the model half: the schema it resolved, and the app source
# directory it resolved it for. Both go into the declared input list below.
# Asking rather than repeating the resolution keeps ONE implementation of the
# `bao-codegen.json` indirection that lets several clients share a schema.
SCHEMA_INFO="$(bash scripts/generate-models.sh --print-schema)"
SCHEMA_TOML="$(printf '%s\n' "$SCHEMA_INFO" | sed -n '1p')"
SCHEMA_APP_SOURCES="$(printf '%s\n' "$SCHEMA_INFO" | sed -n '2p')"

# ────────────────────────────────────────────────────────────────────────────
# Models
# ────────────────────────────────────────────────────────────────────────────
# Emitted into the source tree (not just the SPM plugin work dir) so SourceKit
# — Xcode and VS Code both read the tree, not the build graph — can resolve the
# generated types, and so xcodegen scans them into the .pbxproj.
#
# Delegated to `scripts/generate-models.sh` rather than invoking the codegen
# tool here, so this path and the Xcode target's pre-build phase (#2886) share
# one implementation — including clearing the iOS SDK environment Xcode
# exports, and finding the app directory from wherever the schema actually is
# rather than assuming the template's own name.
#
# `--verify-project` is deliberately off here: verification runs at the END of
# this script, across all three directories at once.
#
# DERIVED_FILE_DIR is cleared for the child: with it set, the inner script
# writes its own `models-codegen.stamp` at its own end, which on a run that then
# fails in the workflow half would leave a mark of progress behind. This script
# owns the one stamp the phase declares, and writes it last (#3078).
DERIVED_FILE_DIR="" bash scripts/generate-models.sh

# ────────────────────────────────────────────────────────────────────────────
# Workflow factories
# ────────────────────────────────────────────────────────────────────────────
# Only when this app has synced workflows: a freshly scaffolded app has no
# `<project root>/primitive/<env>/workflows/*.toml` at all, and
# `primitive workflows codegen` exits non-zero with "No workflows/*.toml files
# found" — which must not fail a build that has nothing to generate. Same guard
# shape the Vue template's `codegen` script uses.
#
# The tree sits beside `primitive/config.json`, which is NOT always this
# directory: one Primitive app can have several clients (this one and a web
# client in a sibling directory), and then the project config and its
# export live at the repo root. So walk up for it, the way git finds `.git` and
# the way the CLI resolves the project — a standalone app's nearest ancestor is
# itself, which is the old behavior exactly.
#
# No config anywhere is a scaffold that is not a project yet: nothing to
# generate, and nothing to fail about.
PROJECT_ROOT=""
dir="$(pwd)"
while :; do
    if [ -f "$dir/primitive/config.json" ]; then
        PROJECT_ROOT="$dir"
        break
    fi
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
done

# WHICH environment (#3078). The guard has to ask the same question the CLI
# will: a class synced only under `alpha` while `dev` is selected must be
# SKIPPED, not generated from the wrong backend and not failed on. Resolving it
# here rather than globbing every environment is what keeps an ordinary build —
# including Xcode's Run button, which now runs this script — from failing on an
# environment it was never asked about.
RESOLVED_ENV=""
if [ -n "$PROJECT_ROOT" ]; then
    SELECTION="$(bash scripts/codegen-env.sh \
        "$PROJECT_ROOT/primitive/config.json" \
        "$PROJECT_ROOT/.primitive/local.json")"
    RESOLVED_ENV="$(printf '%s\n' "$SELECTION" | sed -n '1p')"
fi

# True when the SELECTED environment has this artifact class synced.
#
# The fallback is deliberate: when no single environment resolves at all —
# several defined, none selected — the guard widens back to every environment,
# so an app that really does have TOMLs invokes the CLI and gets the CLI's own
# resolver error, in the CLI's words, rather than a silent skip of work the
# developer asked for. `primitive/config.json` is a file, so the widened glob
# `primitive/*/<kind>/*.toml` never reads it as an environment.
synced_tomls() {
    local kind="$1"
    [ -n "$PROJECT_ROOT" ] || return 0
    if [ -n "$RESOLVED_ENV" ]; then
        ls "$PROJECT_ROOT/primitive/$RESOLVED_ENV/$kind"/*.toml \
            2>/dev/null || true
    else
        ls "$PROJECT_ROOT/primitive"/*/"$kind"/*.toml 2>/dev/null || true
    fi
}

has_synced() {
    [ -n "$(synced_tomls "$1")" ]
}

if has_synced workflows; then
    resolve_cli "workflows"

    echo "Running primitive workflows codegen..." >&2
    mkdir -p "$WORKFLOW_GEN_DIR"
    run_cli workflows codegen --lang swift -o "$WORKFLOW_GEN_DIR"
fi

# ────────────────────────────────────────────────────────────────────────────
# Database types
# ────────────────────────────────────────────────────────────────────────────
# Record structs, per-operation params/result types and the typed ops factory
# for each synced database type — committed, like the workflow factories and
# the models, and rewritten here on every build path.
#
# Guarded exactly like the workflow half: with no synced
# `primitive/<env>/database-type-configs/*.toml`, `primitive
# databases codegen` exits non-zero with "No database-type-configs/*.toml files
# found", which must not fail a build that has nothing to generate.
if has_synced database-type-configs; then
    resolve_cli "database types"

    echo "Running primitive databases codegen..." >&2
    mkdir -p "$DATABASE_GEN_DIR"
    run_cli databases codegen --lang swift -o "$DATABASE_GEN_DIR"
fi

# ────────────────────────────────────────────────────────────────────────────
# The declared file lists
# ────────────────────────────────────────────────────────────────────────────
# The Xcode phase declares its inputs and outputs through these two committed
# lists, refreshed here on every run. What a codegen reads and writes depends on
# the app's configuration — which schema, which environment, which synced TOMLs
# — and none of that can be spelled statically in `project.yml`. File-list
# PATHS, not their contents, are what the pbxproj embeds, so the declarations
# stay valid while the lists change.
#
# Entries are `$(SRCROOT)`-relative, so a client whose project config lives at an
# ancestor repository root spells it `$(SRCROOT)/../primitive/config.json`.
# Sorted, so two consecutive runs write identical bytes and the redundant second
# pass on the project-regenerating paths leaves no diff.

# `$(SRCROOT)/<path from the app root to $1>`, for a path that may sit above it.
srcroot_relative() {
    local target="$1"
    local base
    base="$(pwd -P)"
    case "$target" in
        /*) ;;
        *) target="$base/$target" ;;
    esac
    # python3 rather than `realpath --relative-to`, which macOS does not ship.
    # Both sides are canonicalised: on macOS the app can be reached through a
    # symlink (/tmp, /var), and a relative path computed across one is wrong.
    TARGET="$target" BASE="$base" python3 -c '
import os
target = os.path.realpath(os.environ["TARGET"])
base = os.path.realpath(os.environ["BASE"])
print("$(SRCROOT)/" + os.path.relpath(target, base))
'
}

# Functions, not brace groups: `set -o pipefail` would fail the whole script on
# a group whose last command is a `[ -f … ]` that came out false.
codegen_inputs() {
    if [ -n "$PROJECT_ROOT" ]; then
        srcroot_relative "$PROJECT_ROOT/primitive/config.json"
        # Declared whether or not it exists: `primitive env use` creates it, and
        # a phase may only read what was declared before it ran.
        srcroot_relative "$PROJECT_ROOT/.primitive/local.json"
    fi
    [ -f .primitive-cli-version ] && srcroot_relative .primitive-cli-version
    [ -f "$SCHEMA_APP_SOURCES/bao-codegen.json" ] &&
        srcroot_relative "$SCHEMA_APP_SOURCES/bao-codegen.json"
    [ -n "$SCHEMA_TOML" ] && srcroot_relative "$SCHEMA_TOML"
    for kind in workflows database-type-configs; do
        while IFS= read -r toml; do
            [ -n "$toml" ] && srcroot_relative "$toml"
        done <<EOF
$(synced_tomls "$kind")
EOF
    done
    return 0
}

codegen_outputs() {
    for dir in "$MODELS_GEN_DIR" "$WORKFLOW_GEN_DIR" "$DATABASE_GEN_DIR"; do
        for generated in "$dir"/*.swift; do
            [ -f "$generated" ] && echo "\$(SRCROOT)/$generated"
        done
    done
    return 0
}

codegen_inputs | sort -u > "$INPUTS_LIST"

codegen_outputs | sort -u > "$OUTPUTS_LIST"

# ────────────────────────────────────────────────────────────────────────────
# Verification, then the stamp
# ────────────────────────────────────────────────────────────────────────────
# Everything has been emitted and every list refreshed by now, so a failure here
# still leaves the reviewable diff behind — and covers all three directories in
# one pass, by full group-resolved path (#3078).
if [ "$VERIFY_PROJECT" = true ]; then
    bash scripts/verify-generated-project.sh \
        --label "$SCHEMA_TOML" \
        "$MODELS_GEN_DIR" "$WORKFLOW_GEN_DIR" "$DATABASE_GEN_DIR"
fi

# The phase declares this stamp as its output. Written LAST, and by this script
# alone: no failure path may mark the phase clean, and the inner model script's
# own stamp is suppressed above for the same reason.
if [ -n "${DERIVED_FILE_DIR:-}" ]; then
    mkdir -p "$DERIVED_FILE_DIR"
    touch "$DERIVED_FILE_DIR/codegen.stamp"
fi
