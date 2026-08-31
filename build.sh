#!/bin/sh
# Build "Claude Sessions.app" from App.swift.
set -e
cd "$(dirname "$0")"

APP="Claude Sessions.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/icons"

swiftc -O -parse-as-library App.swift -o "$APP/Contents/MacOS/ClaudeSessions"
cp icons/*.svg "$APP/Contents/Resources/icons/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.wagnersilva.claude-sessions</string>
    <key>CFBundleName</key><string>Claude Sessions</string>
    <key>CFBundleExecutable</key><string>ClaudeSessions</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "Built: $APP"
