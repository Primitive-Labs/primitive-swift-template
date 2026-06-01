#!/bin/bash
# Build and run the Primitive app template (macOS)
set -euo pipefail
cd "$(dirname "$0")"

# ────────────────────────────────────────────────────────────────────────────
# Model codegen — mirror to source tree for SourceKit
# ────────────────────────────────────────────────────────────────────────────
# `swift run` below triggers `swift build`, which runs `JsBaoCodegenPlugin`
# automatically and emits into the SPM plugin work dir — fine for the
# compiler. SourceKit (Xcode / VS Code) reads the *source tree* though, so
# without a checked-in `Models/Generated/<Type>.swift`, editor diagnostics
# can't find generated types and surface confusing errors like
# "No such module 'PrimitiveApp'" against companion `+Extensions.swift`
# files. Run codegen explicitly into `Models/Generated/` so the source
# tree stays the source of truth for tooling. Mirrors `run-ios.sh`.
GEN_DIR="Sources/PrimitiveAppTemplate/Models/Generated"
SCHEMA_TOML="Sources/PrimitiveAppTemplate/Models/schema.toml"
mkdir -p "$GEN_DIR"
swift run --package-path . swift-bao-codegen \
    --input  "$SCHEMA_TOML" \
    --output "$GEN_DIR"

swift run primitive-app-template "$@"
