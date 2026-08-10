#!/bin/bash
# Regenerate the Xcode project from project.yml, then re-sync the Xcode SPM pin.
#
# Those two steps are always one operation, in this order:
#
#   xcodegen generate
#       rewrites <App>.xcodeproj from project.yml, so newly added sources
#       (including freshly codegen'd Models/Generated/*.swift) and edited build
#       settings reach the Xcode build.
#
#   scripts/sync-xcode-pins.sh
#       copies the app's Package.resolved back into the project container.
#       xcodegen rewrites the container the Xcode SPM pin lives inside, so a
#       sync that ran earlier is discarded along with the old container.
#
# Every caller that regenerates — run-ios.sh, archive.sh, scripts/smoke-test.sh
# and the fastlane lanes — goes through this script instead of repeating the
# pair, so the order and the error policy are defined in one place.
#
# Policy: xcodegen is required. An earlier version of this pair warned and
# carried on when xcodegen was missing, which leaves the build compiling an
# .xcodeproj that does not list the files codegen just wrote — a confusing
# compile error, or a build and upload of a stale project. Failing here with
# install instructions is the one behaviour everywhere.
#
# Usage:
#   bash scripts/regenerate-project.sh [<App>.xcodeproj | <App>.xcworkspace]
#
# With no argument the pin sync picks the first .xcodeproj beside the app root.
# Paths are resolved from the app root (this script's parent directory), not the
# caller's working directory, so fastlane can call it from `fastlane/`.
#
# stdout stays empty on every path — progress goes to stderr. Callers capture
# this script's stdout in places (scripts/smoke-test.sh runs it inside
# build_for_simulator()).
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen is not installed, and the Xcode project is generated from project.yml." >&2
    echo "  Install it with: brew install xcodegen" >&2
    exit 1
fi

# The quiet attempt covers the common case. A failure there can be a spec error
# worth reading — or just an xcodegen too old to know `--quiet` — so retry
# without it and let the real output through. Both attempts write to stderr so
# stdout stays empty.
if ! xcodegen generate --quiet >/dev/null 2>&1; then
    xcodegen generate >&2
fi

bash scripts/sync-xcode-pins.sh ${1:+"$1"}
