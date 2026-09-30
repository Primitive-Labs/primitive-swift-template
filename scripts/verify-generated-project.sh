#!/bin/bash
# Does the committed Xcode project compile exactly the generated files that are
# on disk?
#
# Codegen can refresh a CHANGED file in place, but ADDING one emits a file the
# `.pbxproj` does not compile, and REMOVING one sweeps a file the `.pbxproj`
# still compiles; only `xcodegen generate` moves that list. Inside a build phase
# there is no regenerating the project we are already building, so the build
# stops with the fix rather than compiling an app quietly missing the type
# (added) or dying on a "build input file cannot be found" that names a path and
# not the schema (removed).
#
# Usage:
#   bash scripts/verify-generated-project.sh --label <text> <dir> [<dir>…]
#
# Each <dir> is a generated directory, relative to the app root. `--label` names
# the thing that declares those files, for the error message.
#
# WHY FULL PATHS (#3078). This check used to compare BASENAMES. Both CLI
# generators emit `<key>.generated.swift` — the workflow one into
# `Workflows/Generated`, the database one into `Databases/Generated` — so an app
# with a workflow and a database type sharing a key has two files with the same
# name in different directories. With a basename check, one of them missing from
# a target's Sources phase was satisfied by the other's presence, and Xcode
# silently omitted a generated source. So resolve identities properly:
# PBXBuildFile → its fileRef → the PBXFileReference's own name, prefixed by its
# group's position in the group tree.
#
# Progress and errors go to stderr; stdout stays empty.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LABEL="the schema"
DIRS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --label) LABEL="${2:-}"; shift 2 ;;
        -*) echo "Unknown argument: $1" >&2; exit 1 ;;
        *) DIRS="$DIRS $1"; shift ;;
    esac
done

PBXPROJ=""
for container in *.xcodeproj; do
    [ -f "$container/project.pbxproj" ] || continue
    PBXPROJ="$container/project.pbxproj"
    break
done
# No project to check against — the SPM-only paths, and the scratch trees the
# repo's own gates build. Nothing to disagree with.
[ -n "$PBXPROJ" ] || exit 0

# Everything the project knows about our generated directories, as full paths.
#
# Two answers come out of one pass, tagged so the shell can tell them apart:
#
#   compiled <phase-index> <path>   the file is in that Sources phase
#   listed <path>                   the file reference exists in the group tree
#
# A `PBXFileReference` xcodegen left in a group compiles nothing, so membership
# in a phase is the question for the ADDED half; the group listing is what
# answers the REMOVED half, since codegen has already swept the file itself.
PROJECT_FACTS="$(awk -v want="$DIRS" '
    function unquote(value) { gsub(/^"|"$/, "", value); return value }

    # Where a group sits: its ancestors, outermost first. A group contributes
    # its own `path`, if it has one — a `name`-only group is a folder that
    # exists in the navigator alone. Groups form a tree, so the walk
    # terminates; the cap is belt and braces.
    function resolve(id,   path, hops) {
        path = ""
        for (hops = 0; id != "" && hops < 64; hops++) {
            if (id in group_path && group_path[id] != "") {
                path = (path == "" ? group_path[id] : group_path[id] "/" path)
            }
            id = parent[id]
        }
        return path
    }

    function wanted(path,   i, n, parts, dir) {
        n = split(want, parts, " ")
        for (i = 1; i <= n; i++) {
            if (parts[i] == "") continue
            dir = parts[i]
            sub(/\/$/, "", dir)
            if (index(path, dir "/") == 1) return 1
        }
        return 0
    }

    # One-line objects carry their whole body after the brace. Both kinds this
    # check needs are one-liners, and neither opens a multi-line object.
    /isa = PBXFileReference;/ {
        line = $0
        id = unquote($1)
        if (match(line, /path = [^;]+;/)) {
            value = substr(line, RSTART + 7, RLENGTH - 8)
            file_name[id] = unquote(value)
        }
        next
    }
    /isa = PBXBuildFile;/ {
        line = $0
        id = unquote($1)
        if (match(line, /fileRef = [^ ;]+/)) {
            build_ref[id] = unquote(substr(line, RSTART + 10, RLENGTH - 10))
        }
        next
    }

    # `<id> /* comment */ = {` opens a multi-line object: a group, or a phase.
    /=[[:space:]]*\{[[:space:]]*$/ { current = unquote($1); next }
    /^[[:space:]]*\{[[:space:]]*$/ { next }
    /^[[:space:]]*\};/ { current = ""; in_phase = 0; next }
    current == "" { next }

    /^[[:space:]]*isa = PBXGroup;/ { is_group[current] = 1; next }
    /^[[:space:]]*isa = PBXSourcesBuildPhase;/ {
        in_phase = 1
        phase_index++
        next
    }
    /^[[:space:]]*path = / {
        value = $0
        sub(/^[[:space:]]*path = /, "", value)
        sub(/;[[:space:]]*$/, "", value)
        group_path[current] = unquote(value)
        next
    }

    # A child entry: `<id> /* name */,`. Inside a group it records parentage;
    # inside a Sources phase it records what that target compiles.
    /^[[:space:]]*[^[:space:]]+ \/\* .* \*\/,[[:space:]]*$/ {
        child = unquote($1)
        if (in_phase) {
            phase_of[child] = phase_index
            compiled_order[++compiled_count] = child
        } else {
            parent[child] = current
            listed_order[++listed_count] = child
        }
    }

    END {
        for (i = 1; i <= listed_count; i++) {
            id = listed_order[i]
            if (!(id in file_name)) continue
            path = resolve(parent[id]) "/" file_name[id]
            if (wanted(path)) print "listed " path
        }
        for (i = 1; i <= compiled_count; i++) {
            id = compiled_order[i]
            ref = build_ref[id]
            if (ref == "" || !(ref in file_name)) continue
            path = resolve(parent[ref]) "/" file_name[ref]
            if (wanted(path)) print "compiled " phase_of[id] " " path
        }
    }
' "$PBXPROJ")"

# Space-separated strings rather than arrays: bash 3.2 ships with macOS, and
# `${#array[@]}` on an empty array trips `set -u` there.
ON_DISK=""
for dir in $DIRS; do
    for generated in "$dir"/*.swift; do
        [ -f "$generated" ] || continue
        ON_DISK="$ON_DISK $generated"
    done
done

LISTED="$(printf '%s\n' "$PROJECT_FACTS" | sed -n 's/^listed //p')"

# A phase compiling none of our files (a test target) is not in the generated-
# code business; one compiling some of them has to compile all, which is also
# how a file listed for the iOS target but not the macOS one gets caught. A
# project compiling none of them at all lists nothing yet — every emitted file
# is missing from it.
MISSING=""
COMPILING_PHASES=0
PHASE_INDEXES="$(printf '%s\n' "$PROJECT_FACTS" | sed -n 's/^compiled \([0-9][0-9]*\) .*/\1/p' | sort -u)"
for index in $PHASE_INDEXES; do
    phase=" $(printf '%s\n' "$PROJECT_FACTS" | sed -n "s/^compiled $index //p" | tr '\n' ' ')"
    compiles_ours=false
    for path in $ON_DISK; do
        case "$phase " in *" $path "*) compiles_ours=true; break ;; esac
    done
    [ "$compiles_ours" = true ] || continue
    COMPILING_PHASES=$((COMPILING_PHASES + 1))
    for path in $ON_DISK; do
        case "$phase " in
            *" $path "*) ;;
            *) case " $MISSING " in
                   *" $path "*) ;;
                   *) MISSING="$MISSING $path" ;;
               esac ;;
        esac
    done
done
if [ "$COMPILING_PHASES" -eq 0 ]; then
    MISSING="$ON_DISK"
fi

OBSOLETE=""
for path in $LISTED; do
    case " $ON_DISK " in
        *" $path "*) ;;
        *) OBSOLETE="$OBSOLETE $path" ;;
    esac
done

if [ -n "$MISSING" ] || [ -n "$OBSOLETE" ]; then
    if [ -n "$MISSING" ]; then
        echo "error: $LABEL declares generated files the Xcode project does not compile yet:$MISSING" >&2
    fi
    if [ -n "$OBSOLETE" ]; then
        echo "error: the Xcode project still compiles files $LABEL no longer declares:$OBSOLETE" >&2
    fi
    echo "  Codegen refreshes a changed file in place, but adding or removing one changes" >&2
    echo "  the set of files, and the Xcode project lists its sources explicitly." >&2
    echo "  Regenerate the project:" >&2
    echo "      bash scripts/regenerate-project.sh" >&2
    echo "  (or run ./run-ios.sh, which does it for you), then build again." >&2
    exit 1
fi
