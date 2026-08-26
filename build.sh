#!/bin/bash
# Build L42Config.app (no Xcode project needed, just Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")"

APP="L42Config.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] || python3 make_icon.py
cp AppIcon.icns "$APP/Contents/Resources/"


swiftc -O -o "$APP/Contents/MacOS/L42Config" main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>L42Config</string>
    <key>CFBundleIdentifier</key><string>com.thiagoennes.dotlabel</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>L42Config</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>dotlabel</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "Built $APP — launch with: open $(pwd)/$APP"

if [[ "${1:-}" == "--dist" ]]; then
    VER="1.0"
    rm -f "L42Config-$VER.dmg"
    hdiutil create -volname L42Config -srcfolder "$APP" -ov -quiet \
        -format UDZO "L42Config-$VER.dmg"
    echo "Packed L42Config-$VER.dmg ($(du -h "L42Config-$VER.dmg" | cut -f1 | tr -d ' '))"
fi
