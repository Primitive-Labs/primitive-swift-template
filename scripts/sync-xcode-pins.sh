#!/bin/bash
# Copy the app's SPM package pin into the Xcode project so both build paths
# resolve the same package revisions.
#
# The app has two pins that nothing keeps in step:
#
#   Package.resolved
#       written and read by `swift build`, `swift run` and
#       `swift package update` — the SPM path, including the codegen step
#       `run-ios.sh` runs before the Xcode build.
#
#   <App>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
#       written and read by xcodebuild and the Xcode UI.
#
# With branch-pinned dependencies (the Primitive packages track a branch, not a
# version) the two drift apart as soon as upstream pushes: `swift package
# update` moves the root pin while Xcode keeps resolving the revision it pinned
# on its last build. The app then compiles against a client the codegen output
# no longer matches — a confusing compile error at best, and at worst a green
# build still running the old library code. `xcodebuild
# -resolvePackageDependencies` does not fix it: that re-reads Xcode's own pin,
# not the root one.
#
# Copying the root pin over Xcode's makes xcodebuild re-resolve to the same
# revisions on its next run. Every build script that shells out to xcodebuild
# calls this first.
#
# Usage:
#   bash scripts/sync-xcode-pins.sh [<App>.xcodeproj | <App>.xcworkspace]
#
# With no argument the first .xcodeproj beside the app root is used. Paths are
# resolved from the app root (this script's parent directory), not the caller's
# working directory, so fastlane can call it from `fastlane/`.
#
# Every "nothing to do" path exits 0 and prints nothing: the callers run under
# `set -e`, and an unchanged pin must not be rewritten — a fresh mtime alone
# makes Xcode re-resolve and rebuild.
#
# The status line goes to stderr, and stdout stays empty on every path: callers
# capture this script's stdout in places — `scripts/smoke-test.sh` runs it inside
# `build_for_simulator()`, whose stdout is the built .app path the caller reads.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_PIN="Package.resolved"
# Nothing has been resolved yet — the next `swift build` will create it.
[ -f "$ROOT_PIN" ] || exit 0

CONTAINER="${1:-}"
if [ -z "$CONTAINER" ]; then
    for candidate in *.xcodeproj; do
        # Under `set -u` an unmatched glob stays literal; skip it.
        [ -d "$candidate" ] || continue
        CONTAINER="$candidate"
        break
    done
fi
# An SPM-only checkout has no Xcode project to sync into.
[ -n "$CONTAINER" ] && [ -d "$CONTAINER" ] || exit 0

# A workspace holds its pin one level shallower than a project does.
case "$CONTAINER" in
    *.xcworkspace) XCODE_PIN="$CONTAINER/xcshareddata/swiftpm/Package.resolved" ;;
    *)             XCODE_PIN="$CONTAINER/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ;;
esac

# Already in step. The -f guard keeps cmp from reporting a missing file the
# first time Xcode has never resolved.
if [ -f "$XCODE_PIN" ] && cmp -s "$ROOT_PIN" "$XCODE_PIN"; then
    exit 0
fi

mkdir -p "$(dirname "$XCODE_PIN")"
cp "$ROOT_PIN" "$XCODE_PIN"
echo "Synced Xcode package pins from $ROOT_PIN (xcodebuild will re-resolve)." >&2
