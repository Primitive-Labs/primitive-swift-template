#!/bin/bash
# Archive the Primitive template app through Xcode's account session.
#
# Usage:
#   ./archive.sh ios          -- Archive an iOS build with Xcode automatic signing and hand it to App Store Connect
#   ./archive.sh mac          -- Archive a macOS build with Xcode automatic signing and hand it to App Store Connect
#   ./archive.sh dmg          -- Build a standalone macOS .app (for direct distribution / notarization)
#
# The TestFlight path is `bundle exec fastlane ios beta` (docs/README.md,
# "Distribution"). This script signs through the Apple ID added in Xcode's
# Accounts pane and never sees the App Store Connect API key, so on a machine
# set up as fastlane/.env.example prescribes — the key, no Apple ID in Xcode,
# no distribution certificate — it fails with `No Accounts` (#3416). The beta
# lane authenticates the archive with that key and fetches the certificate and
# profile through it (#3008), so it uploads from exactly that machine.
#
# Add `--primitive-env <name>` to any of the above to archive against a named
# Primitive environment instead of the one `primitive env use` selected. The
# archived bundle carries only that environment's values (#2873).
#
# This is not a special case (#3078): it regenerates and builds like every
# other path. `scripts/regenerate-project.sh` runs the full codegen — models,
# workflow factories, database types — before xcodegen scans for sources, and a
# failing codegen stops the archive. There is no release-time drift check: a
# schema change shows up as a working-tree diff on the developer's ordinary
# build, which is where it gets reviewed and committed.
#
# Prerequisites:
#   - Apple Developer account ($99/year)
#   - Set DEVELOPMENT_TEAM in project.yml to your Team ID (this script regenerates
#     the Xcode project from project.yml on every run, so no extra step)
#   - An Apple ID on that team added in Xcode -> Settings -> Accounts: every
#     mode signs through it (an App Store Connect API key is not a substitute)
#   - For App Store Connect uploads: app must be registered in App Store Connect
#   - For notarized DMG: requires Developer ID certificate
#
set -e
cd "$(dirname "$0")"

PROJECT="PrimitiveAppTemplate.xcodeproj"
BUILD_DIR=".build/archives"
mkdir -p "$BUILD_DIR"

# `--primitive-env <name>` is pulled out before anything else so the resolve
# step inside regenerate-project.sh (below) sees it. Everything else keeps its
# position, so `./archive.sh ios` is unchanged.
MODE_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --primitive-env)
            if [ -z "${2:-}" ]; then
                echo "--primitive-env requires an environment name" >&2
                exit 1
            fi
            export PRIMITIVE_ENV="$2"; shift 2 ;;
        --primitive-env=*)
            export PRIMITIVE_ENV="${1#--primitive-env=}"; shift ;;
        *) MODE_ARGS+=("$1"); shift ;;
    esac
done
set -- ${MODE_ARGS+"${MODE_ARGS[@]}"}

# Regenerate the Xcode project from project.yml, then re-copy the app's package
# pin into it. Without the pin sync an archive can ship the revision Xcode last
# resolved rather than the one the app is pinned to. See
# scripts/regenerate-project.sh.
bash scripts/regenerate-project.sh "$PROJECT"

# Check for team ID
check_team_id() {
    local team_id
    team_id=$(xcodebuild -project "$PROJECT" -scheme "$1" -showBuildSettings 2>/dev/null | grep "DEVELOPMENT_TEAM" | head -1 | awk '{print $3}')
    if [ -z "$team_id" ] || [ "$team_id" = "" ]; then
        echo "Error: DEVELOPMENT_TEAM is not set."
        echo ""
        echo "To fix this:"
        echo "  1. Get your Team ID from https://developer.apple.com/account -> Membership Details"
        echo "  2. Set DEVELOPMENT_TEAM in project.yml"
        echo "  3. Re-run this script — it regenerates the Xcode project from project.yml"
        echo ""
        echo "An Apple Developer account (\$99/year) is required for distribution."
        exit 1
    fi
}

# Why an archive or export here dies with `No Accounts` / `No profiles for
# '<bundle id>' were found`, and what to run instead. Both xcodebuild steps
# authenticate through Xcode's account session — there is no key to hand them
# — so the failure is the machine state, not the project (#3416).
ios_signing_failed() {
    echo "" >&2
    echo "The iOS archive failed. archive.sh signs through the Apple ID in" >&2
    echo "Xcode -> Settings -> Accounts and never reads fastlane/.env, so with only an" >&2
    echo "App Store Connect API key configured it fails like this:" >&2
    echo "  error: No Accounts: Add a new account in Accounts settings." >&2
    echo "" >&2
    echo "For TestFlight from the API key alone, run the beta lane instead:" >&2
    echo "  bundle exec fastlane ios beta" >&2
    echo "It authenticates the archive with the key and fetches the distribution" >&2
    echo "certificate and App Store profile through it. See docs/README.md, Distribution." >&2
    exit 1
}

# The macOS lanes still sign through Xcode's account too (`fastlane mac beta`
# is not the API-key path), so the only fix for a macOS `No Accounts` is the
# Accounts pane.
mac_signing_failed() {
    echo "" >&2
    echo "The macOS archive failed. archive.sh signs through the Apple ID in" >&2
    echo "Xcode -> Settings -> Accounts, so" >&2
    echo "  error: No Accounts: Add a new account in Accounts settings." >&2
    echo "means none is added: add your team's Apple ID there and re-run." >&2
    echo "(fastlane's macOS lanes sign the same way, so they are not a way around it.)" >&2
    exit 1
}

archive_ios() {
    local scheme="PrimitiveAppTemplate_iOS"
    check_team_id "$scheme"

    echo "Archiving for iOS..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "generic/platform=iOS" \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-iOS.xcarchive" \
        -quiet || ios_signing_failed

    echo "Exporting to App Store Connect..."
    cat > "$BUILD_DIR/ExportOptions-ios.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-iOS.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-ios.plist" \
        -exportPath "$BUILD_DIR/ios-export" \
        -quiet || ios_signing_failed

    # ExportOptions says `destination: upload`: the export step above handed
    # the build to App Store Connect itself, so there is no upload left to do.
    echo ""
    echo "Done! Uploaded to App Store Connect; export summary in $BUILD_DIR/ios-export/"
    echo "It appears in TestFlight after processing (5-30 min)."
    echo ""
    echo "The same upload without an Apple ID in Xcode (API key only):"
    echo "  bundle exec fastlane ios beta"
}

archive_mac() {
    local scheme="PrimitiveAppTemplate_macOS"
    check_team_id "$scheme"

    echo "Archiving for macOS..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "generic/platform=macOS" \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-macOS.xcarchive" \
        -quiet || mac_signing_failed

    echo "Exporting to App Store Connect..."
    cat > "$BUILD_DIR/ExportOptions-mac.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-macOS.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-mac.plist" \
        -exportPath "$BUILD_DIR/mac-export" \
        -quiet || mac_signing_failed

    # `destination: upload`, as for iOS: the export uploaded the build itself.
    echo ""
    echo "Done! Uploaded to App Store Connect; export summary in $BUILD_DIR/mac-export/"
    echo "It appears in TestFlight after processing (5-30 min)."
}

build_dmg() {
    local scheme="PrimitiveAppTemplate_macOS"
    check_team_id "$scheme"

    echo "Archiving for direct distribution..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "generic/platform=macOS" \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-macOS.xcarchive" \
        -quiet

    echo "Exporting with Developer ID signing..."
    cat > "$BUILD_DIR/ExportOptions-dmg.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-macOS.xcarchive" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-dmg.plist" \
        -exportPath "$BUILD_DIR/dmg-export" \
        -quiet

    local app_path="$BUILD_DIR/dmg-export/PrimitiveAppTemplate.app"

    if [ -d "$app_path" ]; then
        echo "Creating DMG..."
        local dmg_path="$BUILD_DIR/PrimitiveAppTemplate.dmg"
        rm -f "$dmg_path"
        hdiutil create -volname "Primitive Template" \
            -srcfolder "$app_path" \
            -ov -format UDZO \
            "$dmg_path" \
            -quiet

        echo ""
        echo "Done! DMG created at: $dmg_path"
        echo ""
        echo "To notarize (required for Gatekeeper):"
        echo "  xcrun notarytool submit $dmg_path --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD --wait"
        echo "  xcrun stapler staple $dmg_path"
    else
        echo ""
        echo "Done! Exported .app to: $BUILD_DIR/dmg-export/"
        echo "You can manually create a DMG or zip it for distribution."
    fi
}

case "${1:-}" in
    ios)
        archive_ios
        ;;
    mac)
        archive_mac
        ;;
    dmg)
        build_dmg
        ;;
    *)
        echo "Usage: ./archive.sh [ios|mac|dmg] [--primitive-env <name>]"
        echo ""
        echo "  ios  -- Archive an iOS build with Xcode automatic signing and upload it to App Store Connect"
        echo "  mac  -- Archive a macOS build with Xcode automatic signing and upload it to App Store Connect"
        echo "  dmg  -- Build a notarizable DMG for direct macOS distribution"
        echo ""
        echo "Every mode signs through the Apple ID in Xcode -> Settings -> Accounts, and needs"
        echo "an Apple Developer account (\$99/year) and DEVELOPMENT_TEAM set in project.yml."
        echo ""
        echo "For TestFlight from an App Store Connect API key alone (no Apple ID in Xcode):"
        echo "  bundle exec fastlane ios beta"
        echo "See docs/README.md, Distribution."
        exit 1
        ;;
esac
