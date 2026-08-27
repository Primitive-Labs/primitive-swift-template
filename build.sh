#!/bin/bash
# Build and run the Primitive template app as a proper macOS .app bundle
# Gives you: correct app name in Dock, app icon, standard macOS app behavior
# Tradeoff: no terminal log output (use Console.app or `log stream` instead)
set -e
cd "$(dirname "$0")"

APP_NAME="Primitive Template"
BUNDLE_ID="com.primitive.app-template"
EXECUTABLE="primitive-app-template"
ASSETS_DIR="Assets.xcassets"
BUILD_DIR=".build/app-bundle"

# primitive.json is a build product resolved from the selected Primitive
# environment (#2873), and it is copied into the bundle below — so generate it
# before the bundle is assembled, not after.
bash scripts/resolve-primitive-config.sh

echo "Building $APP_NAME..."
swift build

echo "Creating app bundle..."
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy executable
cp ".build/debug/$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE"

# Copy primitive.json into bundle Resources so the app can find it
cp primitive.json "$CONTENTS/Resources/primitive.json"

# Compile asset catalog (icon)
if [ -d "$ASSETS_DIR" ]; then
    actool "$ASSETS_DIR" \
        --compile "$CONTENTS/Resources" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$BUILD_DIR/assets-info.plist" \
        2>/dev/null || echo "Warning: actool failed, app will use default icon"
fi

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Launching $APP_NAME..."
open "$APP_BUNDLE"
