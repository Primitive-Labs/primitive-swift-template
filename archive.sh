#!/bin/bash
# Archive and export the Primitive template app for distribution.
#
# Usage:
#   ./archive.sh ios          -- Archive for iOS (TestFlight / App Store)
#   ./archive.sh mac          -- Archive for macOS (TestFlight / Mac App Store)
#   ./archive.sh dmg          -- Build a standalone macOS .app (for direct distribution / notarization)
#
# Add `--primitive-env <name>` to any of the above to archive against a named
# Primitive environment instead of the one `primitive env use` selected. The
# archived bundle carries only that environment's values (#2873).
#
# Prerequisites:
#   - Apple Developer account ($99/year)
#   - Set DEVELOPMENT_TEAM in project.yml to your Team ID (this script regenerates
#     the Xcode project from project.yml on every run, so no extra step)
#   - For TestFlight/App Store: app must be registered in App Store Connect
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

archive_ios() {
    local scheme="PrimitiveAppTemplate_iOS"
    check_team_id "$scheme"

    echo "Archiving for iOS..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "generic/platform=iOS" \
        -archivePath "$BUILD_DIR/PrimitiveAppTemplate-iOS.xcarchive" \
        -quiet

    echo "Exporting for App Store / TestFlight..."
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
        -quiet

    echo ""
    echo "Done! Exported to: $BUILD_DIR/ios-export/"
    echo ""
    echo "To upload to TestFlight:"
    echo "  Option 1: Open Xcode -> Window -> Organizer -> select archive -> Distribute App"
    echo "  Option 2: xcrun altool --upload-app -f $BUILD_DIR/ios-export/*.ipa -t ios -u YOUR_APPLE_ID"
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
        -quiet

    echo "Exporting for Mac App Store / TestFlight..."
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
        -quiet

    echo ""
    echo "Done! Exported to: $BUILD_DIR/mac-export/"
    echo ""
    echo "To upload to TestFlight:"
    echo "  Option 1: Open Xcode -> Window -> Organizer -> select archive -> Distribute App"
    echo "  Option 2: xcrun altool --upload-app -f \"$BUILD_DIR/mac-export/*.pkg\" -t macos -u YOUR_APPLE_ID"
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
        echo "  ios  -- Archive for iOS TestFlight / App Store"
        echo "  mac  -- Archive for macOS TestFlight / Mac App Store"
        echo "  dmg  -- Build a notarizable DMG for direct macOS distribution"
        echo ""
        echo "Requires an Apple Developer account (\$99/year) and DEVELOPMENT_TEAM set in project.yml."
        exit 1
        ;;
esac
