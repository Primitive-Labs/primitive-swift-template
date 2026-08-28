#!/bin/bash
# Regenerate the Xcode project from project.yml, then re-sync the Xcode SPM pin.
#
# Those steps are always one operation, in this order:
#
#   scripts/generate-models.sh
#       emits Models/Generated/*.swift from models.toml. Those files are
#       gitignored build products, so on a fresh clone they do not exist yet —
#       and xcodegen can only list a file that is already on disk (#3009).
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
# sequence, so the order and the error policy are defined in one place.
#
# Only the MODEL codegen belongs here. Those files are gitignored and every
# build rewrites them, so emitting one more time costs nothing and can surprise
# nobody. The workflow factories and database types are COMMITTED: regenerating
# them is the developer's step, followed by a commit, and archive.sh checks them
# rather than rewriting them mid-release (#2911). `scripts/codegen.sh` is the
# entry point for all three; callers that run it (run-ios.sh, run.sh,
# smoke-test.sh) simply pay a second, byte-identical model pass here.
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

# primitive.json is a build product generated from the selected Primitive
# environment (#2873). It has to exist BEFORE xcodegen runs: project.yml
# declares it as a non-optional resource path, so a missing file is a project
# generation error rather than a build-time one. Every caller of this script —
# run-ios.sh, archive.sh, smoke-test.sh, the fastlane lanes — is covered by
# doing it here, once. Progress goes to stderr, so stdout stays empty.
bash scripts/resolve-primitive-config.sh

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen is not installed, and the Xcode project is generated from project.yml." >&2
    echo "  Install it with: brew install xcodegen" >&2
    exit 1
fi

# Emit the models BEFORE xcodegen scans for sources (#3009). Models/Generated/
# is gitignored, so on a fresh clone — or any machine that has not built this
# app yet — it is empty, and a project generated from it lists no model
# sources. The archive's pre-build phase then emits the files and its
# `--verify-project` guard correctly fails the build, telling the developer to
# run the regeneration their lane just ran. Because that failed run leaves the
# files behind, the second attempt succeeds: first-run-only, self-healing, and
# indistinguishable from a broken template.
#
# After the xcodegen check, not before: a missing xcodegen is the cheap failure
# and should not wait on a Swift build of the codegen tool.
#
# Progress goes to stderr in generate-models.sh, so stdout stays empty here.
bash scripts/generate-models.sh

# The quiet attempt covers the common case. A failure there can be a spec error
# worth reading — or just an xcodegen too old to know `--quiet` — so retry
# without it and let the real output through. Both attempts write to stderr so
# stdout stays empty.
if ! xcodegen generate --quiet >/dev/null 2>&1; then
    xcodegen generate >&2
fi

bash scripts/sync-xcode-pins.sh ${1:+"$1"}
