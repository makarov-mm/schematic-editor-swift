#!/bin/sh
# Assembles a proper SchematicApp.app bundle from the SPM release build.
# A bundle gives the process a bundle identifier, which silences the
# com.apple.linkd / Process Instance Registry console noise and puts a real
# icon into the Dock. Run from the package root:  ./make-app.sh
set -e

swift build -c release

APP=SchematicApp.app
BIN=.build/release/SchematicApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SchematicApp"
cp -r examples "$APP/Contents/Resources/examples"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SchematicApp</string>
    <key>CFBundleIdentifier</key><string>dev.makarov.schematic-editor</string>
    <key>CFBundleName</key><string>Schematic Editor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP — open it with:  open $APP"
