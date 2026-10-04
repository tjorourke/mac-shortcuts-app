#!/usr/bin/env bash
# Builds ~/Applications/EKS Lab.app from EKSLab.swift + commands.json. The Dock entry points at that path.
set -euo pipefail
cd "$(dirname "$0")/app"
APP="$HOME/Applications/EKS Lab.app"
python3 -m json.tool commands.json >/dev/null || { echo "commands.json is not valid JSON" >&2; exit 1; }
B=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macos14 EKSLab.swift -o "$B/EKSLab"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$B/EKSLab" "$APP/Contents/MacOS/EKSLab"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp commands.json "$APP/Contents/Resources/commands.json"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>EKS Lab</string>
  <key>CFBundleDisplayName</key><string>EKS Lab</string>
  <key>CFBundleIdentifier</key><string>com.tomorourke.ekslab</string>
  <key>CFBundleExecutable</key><string>EKSLab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
rm -rf "$B"
touch "$APP"
echo "built $APP"
