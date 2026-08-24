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
while [ $# -gt 0 ]; do
    case "$1" in
        --verify-project) VERIFY_PROJECT=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# The app's source directory is whichever one holds the schema, so a renamed
# app (`primitive init` scaffolds under your own name) needs no edit here.
SCHEMA_TOML=""
for candidate in Sources/*/Models/models.toml; do
    [ -f "$candidate" ] || continue
    SCHEMA_TOML="$candidate"
    break
done
if [ -z "$SCHEMA_TOML" ]; then
    echo "error: no models.toml found under Sources/<App>/Models/ — codegen has no schema to read." >&2
    exit 1
fi
GEN_DIR="$(dirname "$SCHEMA_TOML")/Generated"
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
    PBXPROJ=""
    for container in *.xcodeproj; do
        [ -f "$container/project.pbxproj" ] || continue
        PBXPROJ="$container/project.pbxproj"
        break
    done

    if [ -n "$PBXPROJ" ]; then
        # Space-separated strings rather than arrays: bash 3.2 ships with
        # macOS, and `${#array[@]}` on an empty array trips `set -u` there.
        ON_DISK=""
        for generated in "$GEN_DIR"/*.swift; do
            [ -f "$generated" ] || continue
            ON_DISK="$ON_DISK $(basename "$generated")"
        done

        # The files each `Sources` build phase compiles, one phase per line.
        # Membership there is the question, not a mention anywhere in the file:
        # a `PBXFileReference` xcodegen left in a group compiles nothing.
        SOURCES_PHASES="$(awk '
            /isa = PBXSourcesBuildPhase;/ { inside = 1; files = ""; next }
            inside {
                if ($0 ~ /^[[:space:]]*\};/) { print files; inside = 0; next }
                if (match($0, /\/\* [^*]+ in Sources \*\/,/)) {
                    files = files " " substr($0, RSTART + 3, RLENGTH - 18)
                }
            }
        ' "$PBXPROJ")"

        # What the project's `Generated` group still lists. Codegen has already
        # swept the file of a model dropped from the schema, so a name here
        # with nothing on disk is an entry only xcodegen can drop.
        LISTED="$(awk '
            /\/\* Generated \*\/ = \{/ { inside = 1; block = ""; children = ""; next }
            inside {
                block = block $0
                if ($0 ~ /^[[:space:]]*\};/) {
                    if (block ~ /isa = PBXGroup;/ && block ~ /path = Generated;/) print children
                    inside = 0
                    next
                }
                if (match($0, /\/\* [^*]+\.swift \*\/,/)) {
                    children = children " " substr($0, RSTART + 3, RLENGTH - 7)
                }
            }
        ' "$PBXPROJ")"

        # A phase compiling none of our files (a test target) is not in the
        # model business; one compiling some of them has to compile all, which
        # is also how a file listed for the iOS target but not the macOS one
        # gets caught. A project compiling none of them at all lists nothing
        # yet — every emitted file is missing from it.
        MISSING=""
        COMPILING_PHASES=0
        while IFS= read -r phase; do
            compiles_ours=false
            for name in $ON_DISK; do
                case " $phase " in *" $name "*) compiles_ours=true; break ;; esac
            done
            [ "$compiles_ours" = true ] || continue
            COMPILING_PHASES=$((COMPILING_PHASES + 1))
            for name in $ON_DISK; do
                case " $phase " in
                    *" $name "*) ;;
                    *) case " $MISSING " in
                           *" $name "*) ;;
                           *) MISSING="$MISSING $name" ;;
                       esac ;;
                esac
            done
        done <<EOF
$SOURCES_PHASES
EOF
        if [ "$COMPILING_PHASES" -eq 0 ]; then
            MISSING="$ON_DISK"
        fi

        OBSOLETE=""
        for name in $LISTED; do
            case " $ON_DISK " in
                *" $name "*) ;;
                *) OBSOLETE="$OBSOLETE $name" ;;
            esac
        done

        if [ -n "$MISSING" ] || [ -n "$OBSOLETE" ]; then
            if [ -n "$MISSING" ]; then
                echo "error: $SCHEMA_TOML declares models the Xcode project does not compile yet:$MISSING" >&2
            fi
            if [ -n "$OBSOLETE" ]; then
                echo "error: the Xcode project still compiles files $SCHEMA_TOML no longer declares:$OBSOLETE" >&2
            fi
            echo "  Codegen refreshes a changed model in place, but adding or removing one changes" >&2
            echo "  the set of files, and the Xcode project lists its sources explicitly." >&2
            echo "  Regenerate the project:" >&2
            echo "      bash scripts/regenerate-project.sh" >&2
            echo "  (or run ./run-ios.sh, which does it for you), then build again." >&2
            exit 1
        fi
    fi
fi

# The phase declares this stamp as its output file, so Xcode skips the whole
# phase while models.toml is untouched. Writing it last keeps a failed codegen
# from marking the phase up to date.
if [ -n "${DERIVED_FILE_DIR:-}" ]; then
    mkdir -p "$DERIVED_FILE_DIR"
    touch "$DERIVED_FILE_DIR/models-codegen.stamp"
fi
