#!/bin/bash
# The DEVELOPER_DIR to run `idb_companion` under, printed on stdout.
#
# Why this exists: `idb_companion` loads SimulatorKit — the framework behind
# every HID command (`idb ui tap`, `ui text`, `ui key`) — from
#
#     $DEVELOPER_DIR/Library/PrivateFrameworks/SimulatorKit.framework
#
# Xcode 27 moved it to `Xcode.app/Contents/SharedFrameworks/` and ships no
# `Contents/Developer/Library/PrivateFrameworks` at all, so on that Xcode the
# companion reads the accessibility tree happily and fails every tap with
#
#     SimulatorKit is required for HID interactions: … "Attempting to load a
#     file at path '…/Developer/Library/PrivateFrameworks/SimulatorKit.framework',
#     but it does not exist"
#
# The fix is a symlink mirror of the Xcode bundle — every entry a link to the
# real one, with SimulatorKit restored to the path the companion looks in —
# and a DEVELOPER_DIR pointed at its `Contents/Developer`. Nothing inside
# `Xcode.app` is touched and nothing needs root, which is what makes this
# safe to do automatically.
#
# The mirror is of the whole BUNDLE, not just the developer directory: the
# companion also resolves frameworks relative to DEVELOPER_DIR with `..`
# (`../SharedFrameworks/DVTFoundation.framework`), so a mirror that stopped at
# `Developer` would trade one missing framework for several.
#
# Usage:
#   bash scripts/idb-developer-dir.sh
#   DEVELOPER_DIR="$(bash scripts/idb-developer-dir.sh)" \
#       idb_companion --udid <UDID> --grpc-port 10882 &
#
#   DEVELOPER_DIR               the Xcode to use, either the bundle
#                               (`/Applications/Xcode.app`) or the developer
#                               directory inside it, as Apple's own tools take
#                               it. Default: `xcode-select -p`.
#   PRIMITIVE_XCODE_SHIM_DIR    where mirrors live. Defaults to
#                               ~/.local/share/primitive/xcode-hid-shim,
#                               outside any one app, so apps scaffolded from
#                               this template share one mirror per Xcode.
#
# On an Xcode that still has the framework where idb looks (26 and earlier),
# this prints that developer directory unchanged and creates nothing: the
# mirror is only ever built for an Xcode that needs it. Exits non-zero with a
# message naming the actual problem when it cannot produce a usable
# DEVELOPER_DIR — `scripts/smoke-test.sh ui_signin` reports that in its
# preflight rather than letting it resurface as a failed tap.
#
# `scripts/smoke-test.sh` calls this itself, so `ui_signin` needs no setup
# beyond `scripts/setup-idb.sh`.

set -euo pipefail
# Bundle entries like `.DS_Store` are mirrored too, and a directory with no
# entries expands to nothing instead of a literal `*`.
shopt -s dotglob nullglob

log()  { printf '[idb-developer-dir] %s\n' "$*" >&2; }
note() { printf '[idb-developer-dir]   %s\n' "$*" >&2; }
fail() { printf '[idb-developer-dir] FAIL: %s\n' "$*" >&2; }

FRAMEWORK="SimulatorKit.framework"
# Where idb_companion loads it from, relative to DEVELOPER_DIR.
OLD_REL="Library/PrivateFrameworks/$FRAMEWORK"
# Written into a mirror this script creates. Nothing without this marker is
# ever deleted, so an unrelated directory in the way is reported, not removed.
MARKER=".primitive-xcode-hid-shim"

if [ -n "${PRIMITIVE_XCODE_SHIM_DIR:-}" ]; then
    SHIM_ROOT="$PRIMITIVE_XCODE_SHIM_DIR"
elif [ -n "${HOME:-}" ]; then
    SHIM_ROOT="$HOME/.local/share/primitive/xcode-hid-shim"
else
    fail "neither PRIMITIVE_XCODE_SHIM_DIR nor HOME is set, so there is nowhere to put the mirror."
    exit 1
fi

# ────────────────────────────────────────────────────────────────────────
# 1. The Xcode this run is about.
# ────────────────────────────────────────────────────────────────────────

base="${DEVELOPER_DIR:-}"
if [ -z "$base" ]; then
    base="$(xcode-select -p 2>/dev/null || true)"
    if [ -z "$base" ]; then
        fail "no active Xcode: 'xcode-select -p' reported none."
        note "Select one, e.g.:  sudo xcode-select -s /Applications/Xcode.app"
        note "Or point DEVELOPER_DIR at the Xcode to use."
        exit 1
    fi
fi
# A trailing slash would make every path built below double up, and
# "${base%/Developer}" would not match at all.
while [ "$base" != "/" ] && [ "${base%/}" != "$base" ]; do base="${base%/}"; done
if [ ! -d "$base" ]; then
    fail "the developer directory does not exist: $base"
    note "Select an Xcode ('sudo xcode-select -s /Applications/Xcode.app') or fix DEVELOPER_DIR."
    exit 1
fi
# `DEVELOPER_DIR=/Applications/Xcode.app` is a configuration xcodebuild, xcrun
# and simctl all accept — `DEVELOPER_DIR=/Applications/Xcode.app xcode-select -p`
# prints the developer directory inside it — so it is normalized here rather
# than rejected below as "not an Xcode.app developer directory". Everything
# after this point works in the developer directory's terms.
if [ -d "$base/Contents/Developer" ]; then
    base="$base/Contents/Developer"
fi

# ────────────────────────────────────────────────────────────────────────
# 2. Nothing to do when this Xcode keeps the framework where idb looks.
# ────────────────────────────────────────────────────────────────────────

if [ -e "$base/$OLD_REL" ]; then
    printf '%s\n' "$base"
    exit 0
fi

# ────────────────────────────────────────────────────────────────────────
# 3. Where Xcode 27 keeps it instead.
# ────────────────────────────────────────────────────────────────────────

case "$base" in
    */Contents/Developer) ;;
    *)
        fail "$base is not an Xcode.app developer directory, and it has no $OLD_REL."
        note "idb needs a full Xcode (the Command Line Tools have no simulator frameworks)."
        note "Select one:  sudo xcode-select -s /Applications/Xcode.app"
        exit 1
        ;;
esac
contents="${base%/Developer}"          # …/Xcode.app/Contents
bundle="${contents%/Contents}"         # …/Xcode.app
bundle_name="${bundle##*/}"            # Xcode.app
framework="$contents/SharedFrameworks/$FRAMEWORK"

if [ ! -e "$framework" ]; then
    fail "$FRAMEWORK is in neither place idb can be pointed at:"
    note "$base/$OLD_REL"
    note "$framework"
    note "Without it idb cannot tap, type or send keys (the AX tree still reads)."
    note "Check this is a full Xcode install:  xcode-select -p"
    exit 1
fi

# ────────────────────────────────────────────────────────────────────────
# 4. The mirror for this Xcode.
# ────────────────────────────────────────────────────────────────────────

# Keyed on the bundle's path, so two Xcodes on one machine get two mirrors and
# a re-run finds the one it built last time. Not a hash: the directory name
# says which Xcode it mirrors, which matters when someone goes looking.
key="$(printf '%s' "${bundle#/}" | tr -c 'A-Za-z0-9._-' '-')"
mirror="$SHIM_ROOT/$key"
developer="$mirror/$bundle_name/Contents/Developer"
lock="$mirror.lock"

# Checked before anything is created, mirror or lock, so a shim root that this
# script must not own is reported rather than made.
case "$SHIM_ROOT" in
    /*) ;;
    *) fail "PRIMITIVE_XCODE_SHIM_DIR must be an absolute path (got: $SHIM_ROOT)."; exit 1 ;;
esac
if [ "$SHIM_ROOT" = "/" ] || [ "$SHIM_ROOT" = "${HOME:-}" ]; then
    fail "PRIMITIVE_XCODE_SHIM_DIR must be a dedicated directory, not $SHIM_ROOT."
    exit 1
fi

# How long a run waits for another run's lock, and the age at which a lock
# belongs to no one. Building the mirror is a few dozen symlinks; a lock older
# than this is one a killed run left behind.
LOCK_WAIT_SECONDS=120
LOCK_STALE_MINUTES=5
LOCK_HELD=""

release_lock() {
    [ -n "$LOCK_HELD" ] || return 0
    LOCK_HELD=""
    rm -rf "$lock"
}

# One run at a time per mirror. The shim root is shared by every app scaffolded
# from this template, so two smoke tests on one machine can reach a first run
# at the same moment: without this, one run rebuilds the directory the other is
# reading, and — because `ln -s X link-to-dir` writes THROUGH the link — an
# overlapping build could create an entry inside the real `Xcode.app`, the one
# thing this script must never do. `mkdir` is the atomic test-and-set.
acquire_lock() {
    if ! mkdir -p "$SHIM_ROOT"; then
        fail "could not create $SHIM_ROOT."
        exit 1
    fi
    local waited=0 broke=""
    while ! mkdir "$lock" 2>/dev/null; do
        # Broken at most once per run, so a lock this script cannot remove ends
        # in the timeout below rather than in a loop.
        if [ -z "$broke" ] &&
           [ -n "$(find "$lock" -maxdepth 0 -mmin "+$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
            log "Removing a lock left behind by an interrupted run: $lock"
            broke=1
            rm -rf "$lock" 2>/dev/null || true
            continue
        fi
        if [ "$waited" -ge "$LOCK_WAIT_SECONDS" ]; then
            fail "waited ${LOCK_WAIT_SECONDS}s for another run to finish with $mirror."
            note "Its lock is $lock. If no run holds it, remove that directory."
            exit 1
        fi
        if [ "$waited" = 0 ]; then
            log "Waiting for another run to finish with $mirror..."
        fi
        sleep 1
        waited=$((waited + 1))
    done
    LOCK_HELD=1
    trap release_lock EXIT
}

# Symlink every entry of $1 into $2, skipping the one named $3 (the level the
# next call mirrors in turn).
link_entries() {
    local real="$1" mir="$2" skip="${3:-}" path name
    mkdir -p "$mir"
    for path in "$real"/*; do
        name="${path##*/}"
        if [ "$name" = "$skip" ]; then continue; fi
        # -n so that a destination which is somehow already a symlink to a
        # directory is an error here, never a link written inside that
        # directory — which, for this mirror, is inside Xcode.app.
        ln -sn "$path" "$mir/$name"
    done
}

# True when every entry of $1 is a symlink to itself in $2 and $2 has nothing
# else — the check that makes an Xcode upgrade in place rebuild the mirror
# instead of hiding the new Xcode's entries behind the old one's links.
links_match() {
    local real="$1" mir="$2" skip="${3:-}" path name
    [ -d "$mir" ] || return 1
    for path in "$real"/*; do
        name="${path##*/}"
        if [ "$name" = "$skip" ]; then continue; fi
        [ "$(readlink "$mir/$name" 2>/dev/null)" = "$path" ] || return 1
    done
    for path in "$mir"/*; do
        name="${path##*/}"
        if [ "$name" = "$skip" ]; then continue; fi
        [ -e "$real/$name" ] || [ -L "$real/$name" ] || return 1
    done
    return 0
}

mirror_is_current() {
    [ -f "$mirror/$MARKER" ] || return 1
    links_match "$contents" "$mirror/$bundle_name/Contents" "Developer" || return 1
    links_match "$base" "$developer" "Library" || return 1
    links_match "$base/Library" "$developer/Library" "PrivateFrameworks" || return 1
    links_match "$base/Library/PrivateFrameworks" \
                "$developer/Library/PrivateFrameworks" "$FRAMEWORK" || return 1
    [ "$(readlink "$developer/$OLD_REL" 2>/dev/null)" = "$framework" ] || return 1
    # The link exists; make sure it still resolves (the framework could have
    # moved again under it).
    [ -e "$developer/$OLD_REL" ] || return 1
    return 0
}

# Taken before the mirror is even inspected and held until this script exits:
# the state `mirror_is_current` reads is exactly what another run rebuilds.
acquire_lock

if mirror_is_current; then
    printf '%s\n' "$developer"
    exit 0
fi

# Rebuilt from scratch rather than patched: the mirror is cheap (symlinks) and
# a partial repair is how a mirror ends up half describing an Xcode that is no
# longer installed.
if [ -L "$mirror" ]; then
    fail "$mirror is a symlink; this script will not write through one."
    note "Remove it, or point PRIMITIVE_XCODE_SHIM_DIR somewhere else."
    exit 1
fi
if [ -e "$mirror" ] && [ ! -d "$mirror" ]; then
    fail "$mirror exists and is not a directory."
    note "Remove it, or point PRIMITIVE_XCODE_SHIM_DIR somewhere else."
    exit 1
fi
if [ -d "$mirror" ] && [ ! -f "$mirror/$MARKER" ]; then
    fail "$mirror already exists and was not created by this script (no $MARKER marker)."
    note "Nothing was deleted. Remove that directory yourself, or set"
    note "PRIMITIVE_XCODE_SHIM_DIR to a path this script can own."
    exit 1
fi

log "Mirroring $bundle for idb (this Xcode keeps $FRAMEWORK in SharedFrameworks)..."
rm -rf "$mirror"
if ! mkdir -p "$mirror"; then
    fail "could not create $mirror."
    exit 1
fi
# The marker goes in before the links, so an interrupted run still leaves a
# directory this script recognises as its own and can rebuild.
if ! touch "$mirror/$MARKER"; then
    fail "could not write the ownership marker $mirror/$MARKER."
    rm -rf "$mirror"
    exit 1
fi
link_entries "$contents" "$mirror/$bundle_name/Contents" "Developer"
link_entries "$base" "$developer" "Library"
link_entries "$base/Library" "$developer/Library" "PrivateFrameworks"
link_entries "$base/Library/PrivateFrameworks" \
             "$developer/Library/PrivateFrameworks" "$FRAMEWORK"
ln -sfn "$framework" "$developer/$OLD_REL"

# Verified rather than assumed: a mirror that cannot be read back is reported
# here, not as a mysterious failed tap later.
if [ ! -e "$developer/$OLD_REL" ]; then
    fail "the mirror at $mirror does not resolve $OLD_REL — not using it."
    exit 1
fi
log "idb DEVELOPER_DIR: $developer"
printf '%s\n' "$developer"
