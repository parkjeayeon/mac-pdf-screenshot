#!/bin/zsh
# PageCap.app 번들을 만든다. 결과: build/PageCap.app
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product PageCapApp
swift build -c release --product pagecap

APP=build/PageCap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PageCapApp "$APP/Contents/MacOS/PageCap"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PageCap</string>
    <key>CFBundleDisplayName</key><string>PageCap</string>
    <key>CFBundleIdentifier</key><string>kr.novaair.pagecap</string>
    <key>CFBundleExecutable</key><string>PageCap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Adobe Acrobat 의 쪽을 넘기기 위해 필요합니다.</string>
</dict>
</plist>
PLIST

# 로컬 실행용 ad-hoc 서명 (다시 빌드하면 권한을 다시 켜야 할 수 있음)
codesign --force --deep --sign - "$APP"
echo "완료: $PWD/$APP"
