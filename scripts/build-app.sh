#!/bin/bash
# Builds pwnd.app in ./build from the Swift package: release build,
# hand-written Info.plist, ad-hoc signature (no Developer ID, no notarisation).
# Regenerate the icon with `swift scripts/make-icon.swift`.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Pwnd
APP=build/pwnd.app
rm -rf "$APP" build/Pwnd.app   # earlier builds used the capitalised name
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pwnd "$APP/Contents/MacOS/pwnd"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>pwnd</string>
  <key>CFBundleDisplayName</key><string>pwnd</string>
  <key>CFBundleIdentifier</key><string>local.orangesurf.pwnd</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>pwnd</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.news</string>
</dict>
</plist>
PLIST
if [ -f scripts/AppIcon.icns ]; then cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# Ad-hoc signature: enough for Gatekeeper on this Mac and for notifications.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
